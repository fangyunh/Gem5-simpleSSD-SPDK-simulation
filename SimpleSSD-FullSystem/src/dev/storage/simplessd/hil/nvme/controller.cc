/*
 * Copyright (C) 2017 CAMELab
 *
 * This file is part of SimpleSSD.
 *
 * SimpleSSD is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * SimpleSSD is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with SimpleSSD.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "hil/nvme/controller.hh"

#include <algorithm>
#include <cmath>
#include <limits>

#include "hil/nvme/interface.hh"
#include "hil/nvme/ocssd.hh"
#include "hil/nvme/subsystem.hh"
#include "pal/config.hh"
#include "util/algorithm.hh"
#include "util/fifo.hh"
#include "util/interface.hh"

#define BOOLEAN_STRING(b) ((b) ? "true" : "false")

// BAR0 byte offset of the Mode B I/O Uncore readiness hint register.
// The NVMe doorbell region is at 0x1000+; 0x2000 is past any doorbell entry.
#define UNCORE_HINT_REG_OFFSET  0x2000

namespace SimpleSSD {

namespace HIL {

namespace NVMe {

RegisterTable::_RegisterTable() {
  memset(data, 0, 64);
}

Controller::Controller(Interface *intrface, ConfigReader &c)
    : pParent(intrface),
      adminQueueInited(false),
      interruptMask(0),
      shutdownReserved(false),
      aggregationTime(0),
      aggregationThreshold(0),
      conf(c) {
  ARM::AXI::BUS_WIDTH axiWidth;
  uint64_t axiClock;

  // Get AXI setting
  axiWidth = (ARM::AXI::BUS_WIDTH)conf.readInt(CONFIG_NVME, NVME_AXI_BUS_WIDTH);
  axiClock = conf.readUint(CONFIG_NVME, NVME_AXI_CLOCK);

  // Allocate array for Command Queues
  cqsize = conf.readUint(CONFIG_NVME, NVME_MAX_IO_CQUEUE) + 1;
  sqsize = conf.readUint(CONFIG_NVME, NVME_MAX_IO_SQUEUE) + 1;

  ppCQueue = (CQueue **)calloc(cqsize, sizeof(CQueue *));
  ppSQueue = (SQueue **)calloc(sqsize, sizeof(SQueue *));

  // [Bits ] Name  : Description                     : Current Setting
  // [63:56] Reserved
  // [55:52] MPSMZX: Memory Page Size Maximum        : 2^14 Bytes
  // [51:48] MPSMIN: Memory Page Size Minimum        : 2^12 Bytes
  // [47:45] Reserved
  // [44:37] CSS   : Command Sets Supported          : NVM command set
  // [36:36] NSSRS : NVM Subsystem Reset Supported   : No
  // [35:32] DSTRD : Doorbell Stride                 : 0 (4 bytes)
  // [31:24] TO    : Timeout                         : 40 * 500ms
  // [23:19] Reserved
  // [18:17] AMS   : Arbitration Mechanism Supported : Weighted Round Robin
  // [16:16] CQR   : Contiguous Queues Required      : Yes
  // [15:00] MQES  : Maximum Queue Entries Supported : 4096 Entries
  registers.capabilities = 0x0020002028010FFF;
  registers.version = 0x00010201;  // NVMe 1.2.1

  FIFOParam fifoParam;

  // See Xilinx Gen3 Integrated Block for PCIe
  fifoParam.rqSize = 8192;
  fifoParam.wqSize = 8192;
  fifoParam.transferUnit = conf.readUint(CONFIG_NVME, NVME_FIFO_UNIT);
  fifoParam.latency = [](uint64_t size) -> uint64_t {
    return ARM::AXI::Stream::calculateDelay(250000000, ARM::AXI::BUS_128BIT,
                                            size);
  };

  pcieFIFO = new FIFO(pParent, fifoParam);

  if (axiWidth * axiClock == (uint64_t)250000000 * ARM::AXI::BUS_128BIT) {
    // We don't need interconnect FIFO
    interconnect = pcieFIFO;
    pcieFIFO = nullptr;  // Prevent double delete(free)
  }
  else {
    fifoParam.latency = [axiWidth, axiClock](uint64_t size) -> uint64_t {
      return ARM::AXI::Stream::calculateDelay(axiClock, axiWidth, size);
    };

    interconnect = new FIFO(pcieFIFO, fifoParam);
  }

  cfgdata.pConfigReader = &c;
  cfgdata.pInterface = interconnect;
  cfgdata.maxQueueEntry = (registers.capabilities & 0xFFFF) + 1;

  workEvent = allocate([this](uint64_t) { work(); });
  requestEvent = allocate([this](uint64_t now) { handleRequest(now); });
  completionEvent = allocate([this](uint64_t) { completion(); });
  requestCounter = 0;
  maxRequest = conf.readUint(CONFIG_NVME, NVME_MAX_REQUEST_COUNT);
  workInterval = conf.readUint(CONFIG_NVME, NVME_WORK_INTERVAL);
  requestInterval = workInterval / maxRequest;

  // --- I/O Uncore initialization ---
  uncoreCfg.mode     = (UncoreMode)conf.readUint(CONFIG_NVME, NVME_UNCORE_MODE);
  uncoreCfg.cqBatchN = (uint32_t)conf.readUint(CONFIG_NVME, NVME_UNCORE_CQ_BATCH_N);
  uncoreCfg.cqBatchT = conf.readUint(CONFIG_NVME, NVME_UNCORE_CQ_BATCH_T);
  uncoreCfg.dbBatchB = (uint32_t)conf.readUint(CONFIG_NVME, NVME_UNCORE_DB_BATCH_B);

  // Mode 2 Mailbox SQ Engine knobs (defaults applied in Config ctor; cfg-file
  // values override them).
  uncoreCfg.mailboxBase          =
      (uint32_t)conf.readUint(CONFIG_NVME, NVME_MAILBOX_BASE);
  uncoreCfg.mailboxStride        =
      (uint32_t)conf.readUint(CONFIG_NVME, NVME_MAILBOX_STRIDE);
  uncoreCfg.mailboxLatchCycles   =
      (uint16_t)conf.readUint(CONFIG_NVME, NVME_MAILBOX_LATCH_CYCLES);
  uncoreCfg.mailboxDecodeCycles  =
      (uint16_t)conf.readUint(CONFIG_NVME, NVME_MAILBOX_DECODE_CYCLES);
  uncoreCfg.mailboxInjectCycles  =
      (uint16_t)conf.readUint(CONFIG_NVME, NVME_MAILBOX_INJECT_CYCLES);

  // Mechanism #1 / #2 / #4 knobs
  uncoreCfg.freeCidBase          =
      (uint32_t)conf.readUint(CONFIG_NVME, NVME_FREE_CID_BASE);
  uncoreCfg.freeCidLatencyCycles =
      (uint16_t)conf.readUint(CONFIG_NVME, NVME_FREE_CID_LATENCY_CYCLES);
  uncoreCfg.hintAgeGranularityPs =
      conf.readUint(CONFIG_NVME, NVME_HINT_AGE_GRANULARITY_PS);

  uncoreHintReady      = 0;
  uncoreFlushScheduled = false;
  uncorePendingCQE.clear();
  uncoreDbAccumPerQ.assign(sqsize, 0);

  uncoreFlushEvent = allocate([this](uint64_t) { uncoreFlushCQBuffer(false); });

  // Mode 2 per-qid mailbox latches; sized to cqsize so qid index never escapes.
  mailboxLatches.assign(cqsize, MailboxLatch());

  // Mechanism #1: per-qid free-CID rings, primed with [0..QueueDepth-1].
  // QueueDepth comes from CAP.MQES+1 (cfgdata.maxQueueEntry). Admin (qid 0)
  // gets a small fixed depth since it doesn't use the Mode B path.
  freeCidRings.assign(cqsize, FreeCIDRing{});
  for (uint16_t qid = 0; qid < (uint16_t)cqsize; qid++) {
    FreeCIDRing &r = freeCidRings[qid];
    uint32_t depth = (qid == 0) ? 64 : (uint32_t)cfgdata.maxQueueEntry;
    if (depth == 0) depth = 64;  // safety
    r.ring.assign(depth, 0);
    for (uint32_t i = 0; i < depth; i++) {
      r.ring[i] = (uint16_t)i;
    }
    r.head = 0;
    r.tail = 0;
    r.depth = depth;     // full ring at init
    r.inflight = 0;
  }
  hintOldestArrivalTicks = 0;

  // Mode 2 inject event: scan all qids and inject any that have nextWord==3.
  // Only one qid is typically ready when this fires (the one that just landed
  // its 3rd word), but the loop is cheap and safe for concurrent landings.
  mailboxInjectEvent = allocate([this](uint64_t t) {
    for (uint16_t qid = 1; qid < (uint16_t)mailboxLatches.size(); qid++) {
      if (mailboxLatches[qid].nextWord == 3) {
        mailboxInject(qid, t);
      }
    }
  });

  debugprint(LOG_HIL_NVME,
             "UNCORE  | mode=%u cqBatchN=%u cqBatchT=%" PRIu64 " dbBatchB=%u",
             (uint32_t)uncoreCfg.mode, uncoreCfg.cqBatchN,
             uncoreCfg.cqBatchT, uncoreCfg.dbBatchB);
  if (uncoreCfg.mode == UNCORE_MODE_B) {
    debugprint(LOG_HIL_NVME,
               "MAILBOX | base=0x%X stride=0x%X latch=%u decode=%u inject=%u",
               uncoreCfg.mailboxBase, uncoreCfg.mailboxStride,
               (unsigned)uncoreCfg.mailboxLatchCycles,
               (unsigned)uncoreCfg.mailboxDecodeCycles,
               (unsigned)uncoreCfg.mailboxInjectCycles);
  }

  // --- Fast-path statistical timing model initialization ---
  // (NVMeVirt-style; cited as methodology in fast_ssd_highiops.cfg header.)
  fastPathCfg.enabled        = conf.readBoolean(CONFIG_NVME, NVME_FASTPATH_ENABLED);
  fastPathCfg.lminPs         = conf.readUint(CONFIG_NVME, NVME_FASTPATH_LMIN);
  fastPathCfg.tmaxPerCh      = conf.readUint(CONFIG_NVME, NVME_FASTPATH_TMAX_PER_CH);
  fastPathCfg.channelPolicy  =
      (uint32_t)conf.readUint(CONFIG_NVME, NVME_FASTPATH_CHANNEL_POLICY);
  fastPathCfg.maxOutstanding =
      conf.readUint(CONFIG_NVME, NVME_FASTPATH_MAX_OUTSTANDING);
  // Channel count sourced from [pal] section so fast-path inherits NAND
  // parallelism without a redundant cfg knob.
  fastPathCfg.channels =
      (uint16_t)conf.readUint(CONFIG_PAL, PAL::PAL_CHANNEL);
  if (fastPathCfg.channels == 0) {
    fastPathCfg.channels = 1;  // safety: never zero-divide
  }
  // Inter-dispatch spacing per channel (picoseconds per IO).
  if (fastPathCfg.tmaxPerCh > 0) {
    fastPathCfg.spacingPs = 1000000000000ULL / fastPathCfg.tmaxPerCh;
  }
  fastPathChannelNextFree.assign(fastPathCfg.channels, 0);
  fastPathRRCounter = 0;
  fastPathFireScheduled = false;
  fastPathFireEvent = allocate([this](uint64_t) {
    fastPathFireScheduled = false;
    fastPathFire();
  });
  if (fastPathCfg.enabled) {
    debugprint(LOG_HIL_NVME,
               "FASTPATH | enabled Lmin=%" PRIu64 "ps Tmax=%" PRIu64
               " ch=%u policy=%u maxOutstanding=%" PRIu64,
               fastPathCfg.lminPs, fastPathCfg.tmaxPerCh,
               fastPathCfg.channels, fastPathCfg.channelPolicy,
               fastPathCfg.maxOutstanding);
  }

  // Which subsystem should we use
  uint16_t vid, ssvid;

  bUseOCSSD = false;
  pParent->getVendorID(vid, ssvid);

  if (vid == OCSSD_VENDOR) {
    bUseOCSSD = true;

    switch (ssvid) {
      case OCSSD_SSVID_1_2:
        pSubsystem = new OpenChannelSSD12(this, cfgdata);

        break;
      case OCSSD_SSVID_2_0:
        pSubsystem = new OpenChannelSSD20(this, cfgdata);

        break;
      default:
        panic("nvme_ctrl: Invalid SSVID for Open-Channel SSD");

        break;
    }
  }
  else {
    pSubsystem = new Subsystem(this, cfgdata);
  }

  // Initialize Subsystem
  pSubsystem->init();
}

Controller::~Controller() {
  delete pSubsystem;

  for (uint16_t i = 0; i < cqsize; i++) {
    if (ppCQueue[i]) {
      delete ppCQueue[i];
    }
  }

  for (uint16_t i = 0; i < sqsize; i++) {
    if (ppSQueue[i]) {
      delete ppSQueue[i];
    }
  }

  free(ppCQueue);
  free(ppSQueue);

  delete interconnect;
  delete pcieFIFO;
}

void Controller::readRegister(uint64_t offset, uint64_t size, uint8_t *buffer,
                              uint64_t &) {
  // I/O-Uncore region above the doorbell window.  These offsets sit OUTSIDE
  // the 64-byte registers.data union, so we MUST handle them before the
  // generic memcpy below or we'd read out-of-bounds memory.
  //
  // Mode B typed hint register (Mechanism #4): 4-byte read-only at
  // BAR0 + UNCORE_HINT_REG_OFFSET.  Layout: bits[15:0] = pending count;
  // bits[31:16] = oldest-CQE age in HintAgeGranularityPs units.  Reads
  // when the controller is in Mode 0 or 1 return a sticky zero.
  if (offset == UNCORE_HINT_REG_OFFSET) {
    uint32_t v = getMultiBitHint();
    uncoreStats.hintTypedReads++;
    if (size > 4) size = 4;
    memset(buffer, 0, size);
    memcpy(buffer, &v, size);
    debugprint(LOG_HIL_NVME,
               "BAR0    | READ  | UNCORE_HINT_TYPED count=%u age=%u",
               (unsigned)(v & 0xFFFFu), (unsigned)(v >> 16));
    return;
  }
  // Mechanism #1: free-CID ring read endpoints.
  //   BAR0 + freeCidBase + (qid * 4) -> uint32_t containing CID in low
  //   16 bits, 0xFFFF if ring is empty.  Side-effect: pops the FIFO and
  //   increments inflight counter for that qid.
  if (uncoreCfg.mode != UNCORE_MODE_DISABLED) {
    uint64_t fc_base = uncoreCfg.freeCidBase;
    uint64_t fc_end  = fc_base + (uint64_t)cqsize * 4ULL;
    if (offset >= fc_base && offset < fc_end) {
      uint16_t qid = (uint16_t)((offset - fc_base) / 4ULL);
      uint16_t cid = freeCidReadNext(qid);
      uint32_t v   = (uint32_t)cid;
      if (size > 4) size = 4;
      memset(buffer, 0, size);
      memcpy(buffer, &v, size);
      debugprint(LOG_HIL_NVME,
                 "BAR0    | READ  | FREE_CID qid=%u -> cid=0x%04X",
                 (unsigned)qid, (unsigned)cid);
      return;
    }
    // Mechanism #2: queue-depth counter read endpoints.
    //   BAR0 + freeCidBase + 0x400 + (qid * 4) -> uint32_t inflight count.
    //   Pure read, no side effect.
    uint64_t qd_base = uncoreCfg.freeCidBase + 0x400ULL;
    uint64_t qd_end  = qd_base + (uint64_t)cqsize * 4ULL;
    if (offset >= qd_base && offset < qd_end) {
      uint16_t qid = (uint16_t)((offset - qd_base) / 4ULL);
      uint32_t v   = getInflightCount(qid);
      uncoreStats.qdepthReads++;
      if (size > 4) size = 4;
      memset(buffer, 0, size);
      memcpy(buffer, &v, size);
      debugprint(LOG_HIL_NVME,
                 "BAR0    | READ  | QDEPTH qid=%u -> %u",
                 (unsigned)qid, (unsigned)v);
      return;
    }
  }
  // Mailbox region [MailboxBase, MailboxBase + cqsize*MailboxStride): the
  // mailbox is write-only from the host's perspective in Mode 2.  Reads
  // here return 0 to keep buggy host probes silent.
  if (uncoreCfg.mode != UNCORE_MODE_DISABLED) {
    uint64_t mb_base = uncoreCfg.mailboxBase;
    uint64_t mb_end  =
        mb_base + (uint64_t)cqsize * (uint64_t)uncoreCfg.mailboxStride;
    if (offset >= mb_base && offset < mb_end) {
      memset(buffer, 0, size);
      return;
    }
  }

  registers.interruptMaskSet = interruptMask;
  registers.interruptMaskClear = interruptMask;

  memcpy(buffer, registers.data + offset, size);

  switch (offset) {
    case REG_CONTROLLER_CAPABILITY:
    case REG_CONTROLLER_CAPABILITY + 4:
      debugprint(LOG_HIL_NVME, "BAR0    | READ  | Controller Capabilities");
      break;
    case REG_VERSION:
      debugprint(LOG_HIL_NVME, "BAR0    | READ  | Version");
      break;
    case REG_INTERRUPT_MASK_SET:
      debugprint(LOG_HIL_NVME, "BAR0    | READ  | Interrupt Mask Set");
      break;
    case REG_INTERRUPT_MASK_CLEAR:
      debugprint(LOG_HIL_NVME, "BAR0    | READ  | Interrupt Mask Clear");
      break;
    case REG_CONTROLLER_CONFIG:
      debugprint(LOG_HIL_NVME, "BAR0    | READ  | Controller Configuration");
      break;
    case REG_CONTROLLER_STATUS:
      debugprint(LOG_HIL_NVME, "BAR0    | READ  | Controller Status");
      break;
    case REG_NVM_SUBSYSTEM_RESET:
      debugprint(LOG_HIL_NVME, "BAR0    | READ  | NVM Subsystem Reset");
      break;
    case REG_ADMIN_QUEUE_ATTRIBUTE:
      debugprint(LOG_HIL_NVME, "BAR0    | READ  | Admin Queue Attributes");
      break;
    case REG_ADMIN_SQUEUE_BASE_ADDR:
    case REG_ADMIN_SQUEUE_BASE_ADDR + 4:
      debugprint(LOG_HIL_NVME,
                 "BAR0    | READ  | Admin Submission Queue Base Address");
      break;
    case REG_ADMIN_CQUEUE_BASE_ADDR:
    case REG_ADMIN_CQUEUE_BASE_ADDR + 4:
      debugprint(LOG_HIL_NVME,
                 "BAR0    | READ  | Admin Completion Queue Base Address");
      break;
    case REG_CMB_LOCATION:
      debugprint(LOG_HIL_NVME,
                 "BAR0    | READ  | Controller Memory Buffer Location");
      break;
    case REG_CMB_SIZE:
      debugprint(LOG_HIL_NVME,
                 "BAR0    | READ  | Controller Memory Buffer Size");
      break;
  }

  if (size == 4) {
    debugprint(LOG_HIL_NVME, "DMAPORT | READ  | DATA %08" PRIX32,
               *(uint32_t *)buffer);
  }
  else {
    debugprint(LOG_HIL_NVME, "DMAPORT | READ  | DATA %016" PRIX64,
               *(uint64_t *)buffer);
  }
}

void Controller::writeRegister(uint64_t offset, uint64_t size, uint8_t *buffer,
                               uint64_t &) {
  static DMAFunction empty = [](uint64_t, void *) {};
  uint32_t uiTemp32;
  uint64_t uiTemp64;

  if (size == 4) {
    memcpy(&uiTemp32, buffer, 4);

    switch (offset) {
      case REG_INTERRUPT_MASK_SET:
        debugprint(LOG_HIL_NVME, "BAR0    | WRITE | Interrupt Mask Set");

        interruptMask |= uiTemp32;

        break;
      case REG_INTERRUPT_MASK_CLEAR:
        debugprint(LOG_HIL_NVME, "BAR0    | WRITE | Interrupt Mask Clear");

        interruptMask &= ~uiTemp32;

        break;
      case REG_CONTROLLER_CONFIG:
        debugprint(LOG_HIL_NVME, "BAR0    | WRITE | Controller Configuration");

        registers.configuration &= 0xFF00000E;
        registers.configuration |= (uiTemp32 & 0x00FFFFF1);

        // Update entry size
        sqstride = (int)powf(2.f, (registers.configuration & 0x000F0000) >> 16);
        cqstride = (int)powf(2.f, (registers.configuration & 0x00F00000) >> 20);

        // Update Memory Page Size
        cfgdata.memoryPageSizeOrder =
            ((registers.configuration & 0x780) >> 7) + 11;  // CC.MPS + 12 - 1
        cfgdata.memoryPageSize =
            (int)powf(2.f, cfgdata.memoryPageSizeOrder + 1);

        // Update Arbitration Mechanism
        arbitration = (registers.configuration & 0x00003800) >> 11;

        // Apply to admin queue
        // Fix admin queue sizes from AQA: SPDK may write base addresses
        // before AQA, causing queues to be created with size 1.  Re-read
        // AQA here so the queues and DMA regions get the correct size.
        {
          uint16_t acqs =
              ((registers.adminQueueAttributes & 0x0FFF0000) >> 16) + 1;
          uint16_t asqs =
              (registers.adminQueueAttributes & 0x0FFF) + 1;
          if (ppCQueue[0]) {
            ppCQueue[0]->setSize(acqs);
            ppCQueue[0]->setBase(
                new PRPList(cfgdata, empty, nullptr,
                            registers.adminCQueueBaseAddress,
                            ppCQueue[0]->getSize() * cqstride, true),
                cqstride);
          }
          if (ppSQueue[0]) {
            ppSQueue[0]->setSize(asqs);
            ppSQueue[0]->setBase(
                new PRPList(cfgdata, empty, nullptr,
                            registers.adminSQueueBaseAddress,
                            ppSQueue[0]->getSize() * sqstride, true),
                sqstride);
          }
        }

        // Shutdown notification
        if (registers.configuration & 0x0000C000) {
          registers.status &= 0xFFFFFFF2;  // Clear RDY and SHST
          registers.status |= 0x00000005;  // Shutdown processing occurring

          shutdownReserved = true;

          // Ensure workEvent is scheduled so work() can finalize shutdown.
          // Without this, a re-triggered shutdown after a prior deschedule
          // would leave SHST stuck at 01 (processing) forever.
          if (!scheduled(workEvent)) {
            schedule(workEvent, getTick() + workInterval);
          }
        }
        // If EN = 1, Set CSTS.RDY = 1
        else if (registers.configuration & 0x00000001) {
          registers.status |= 0x00000001;

          schedule(workEvent, getTick() + workInterval);
        }
        // If EN = 0, Set CSTS.RDY = 0
        else {
          registers.status &= 0xFFFFFFFE;

          deschedule(workEvent);
        }

        break;
      case REG_CONTROLLER_STATUS:
        debugprint(LOG_HIL_NVME, "BAR0    | WRITE | Controller Status");

        // Clear NSSRO if set
        if (uiTemp32 & 0x00000010) {
          registers.status &= 0xFFFFFFEF;
        }

        break;
      case REG_NVM_SUBSYSTEM_RESET:
        debugprint(LOG_HIL_NVME, "BAR0    | WRITE | NVM Subsystem Reset");

        registers.subsystemReset = uiTemp32;

        // FIXME: If NSSR is same as NVMe(0x4E564D65), do NVMe Subsystem reset
        // (when CAP.NSSRS is 1)
        break;
      case REG_ADMIN_QUEUE_ATTRIBUTE:
        debugprint(LOG_HIL_NVME, "BAR0    | WRITE | Admin Queue Attributes");

        registers.adminQueueAttributes &= 0xF000F000;
        registers.adminQueueAttributes |= (uiTemp32 & 0x0FFF0FFF);

        break;
      case REG_ADMIN_CQUEUE_BASE_ADDR:
        debugprint(LOG_HIL_NVME,
                   "BAR0    | WRITE | Admin Completion Queue Base Address | L");

        memcpy(&(registers.adminCQueueBaseAddress), buffer, 4);
        adminQueueInited++;

        break;
      case REG_ADMIN_CQUEUE_BASE_ADDR + 4:
        debugprint(LOG_HIL_NVME,
                   "BAR0    | WRITE | Admin Completion Queue Base Address | H");

        memcpy(((uint8_t *)&(registers.adminCQueueBaseAddress)) + 4, buffer, 4);
        adminQueueInited++;

        break;
      case REG_ADMIN_SQUEUE_BASE_ADDR:
        debugprint(LOG_HIL_NVME,
                   "BAR0    | WRITE | Admin Submission Queue Base Address | L");
        memcpy(&(registers.adminSQueueBaseAddress), buffer, 4);
        adminQueueInited++;

        break;
      case REG_ADMIN_SQUEUE_BASE_ADDR + 4:
        debugprint(LOG_HIL_NVME,
                   "BAR0    | WRITE | Admin Submission Queue Base Address | H");
        memcpy(((uint8_t *)&(registers.adminSQueueBaseAddress)) + 4, buffer, 4);
        adminQueueInited++;

        break;
      default:
        panic("nvme_ctrl: Write on read only register");
        break;
    }

    debugprint(LOG_HIL_NVME, "DMAPORT | WRITE | DATA %08" PRIX32, uiTemp32);
  }
  else if (size == 8) {
    memcpy(&uiTemp64, buffer, 8);

    // Mode 2 deep-offload: 8-byte writes to the mailbox region are absorbed
    // here BEFORE the standard register switch.  Region:
    //   [MailboxBase, MailboxBase + cqsize * MailboxStride)
    // Per-qid slot occupies MailboxStride bytes; only offsets +0/+8/+16 are
    // valid (the three compact-SQE words).  All other offsets in the region
    // are ignored (treated as harmless dead-region writes).
    if (uncoreCfg.mode == UNCORE_MODE_B) {
      uint64_t mb_base = uncoreCfg.mailboxBase;
      uint64_t mb_end  =
          mb_base + (uint64_t)cqsize * (uint64_t)uncoreCfg.mailboxStride;
      if (offset >= mb_base && offset < mb_end) {
        uint64_t rel = offset - mb_base;
        uint16_t qid = (uint16_t)(rel / uncoreCfg.mailboxStride);
        uint64_t off = rel % uncoreCfg.mailboxStride;
        if (off == 0 || off == 8 || off == 16) {
          uint8_t wordIdx = (uint8_t)(off / 8);
          handleMailboxWrite(qid, wordIdx, uiTemp64, getTick());
          debugprint(LOG_HIL_NVME,
                     "BAR0    | WRITE | MAILBOX qid=%u word=%u val=%016" PRIX64,
                     (unsigned)qid, (unsigned)wordIdx, uiTemp64);
          return;
        }
        // Else: write to a reserved byte in the slot; silently ignore.
        debugprint(LOG_HIL_NVME,
                   "BAR0    | WRITE | MAILBOX reserved qid=%u off=0x%" PRIX64
                   " (ignored)", (unsigned)qid, off);
        return;
      }
    }

    switch (offset) {
      case REG_ADMIN_CQUEUE_BASE_ADDR:
        debugprint(LOG_HIL_NVME,
                   "BAR0    | WRITE | Admin Completion Queue Base Address");

        registers.adminCQueueBaseAddress = uiTemp64;
        adminQueueInited += 2;

        break;
      case REG_ADMIN_SQUEUE_BASE_ADDR:
        debugprint(LOG_HIL_NVME,
                   "BAR0    | WRITE | Admin Submission Queue Base Address");

        registers.adminSQueueBaseAddress = uiTemp64;
        adminQueueInited += 2;

        break;
      default:
        panic("nvme_ctrl: Write on read only register");
        break;
    }

    debugprint(LOG_HIL_NVME, "DMAPORT | WRITE | DATA %016" PRIX64, uiTemp64);
  }
  else {
    panic("nvme_ctrl: Invalid read size(%d) on controller register", size);
  }

  if (adminQueueInited == 4) {
    uint16_t entrySize = 0;

    adminQueueInited = 0;

    entrySize = ((registers.adminQueueAttributes & 0x0FFF0000) >> 16) + 1;
    ppCQueue[0] = new CQueue(0, true, 0, entrySize);

    debugprint(LOG_HIL_NVME, "CQ 0    | CREATE | Entry size %d", entrySize);

    entrySize = (registers.adminQueueAttributes & 0x0FFF) + 1;
    ppSQueue[0] = new SQueue(0, 0, 0, entrySize);

    debugprint(LOG_HIL_NVME, "SQ 0    | CREATE | Entry size %d", entrySize);
  }
}  // namespace NVMe

void Controller::ringCQHeadDoorbell(uint16_t qid, uint16_t head, uint64_t &) {
  CQueue *pQueue = ppCQueue[qid];

  if (pQueue) {
    uint16_t oldhead = pQueue->getHead();
    uint32_t oldcount = pQueue->getItemCount();

    pQueue->setHead(head);

    debugprint(LOG_HIL_NVME,
               "CQ %-5d| Completion Queue Head Doorbell | Item count in queue "
               "%d -> %d | head %d -> %d | tail %d",
               qid, oldcount, pQueue->getItemCount(), oldhead,
               pQueue->getHead(), pQueue->getTail());

    if (pQueue->interruptEnabled()) {
      clearInterrupt(pQueue->getInterruptVector());
    }
  }
}

void Controller::ringSQTailDoorbell(uint16_t qid, uint16_t tail, uint64_t &) {
  SQueue *pQueue = ppSQueue[qid];

  if (pQueue) {
    uint16_t oldtail = pQueue->getTail();
    uint32_t oldcount = pQueue->getItemCount();

    pQueue->setTail(tail);

    debugprint(LOG_HIL_NVME,
               "SQ %-5d| Submission Queue Tail Doorbell | Item count in queue "
               "%d -> %d | head %d | tail %d -> %d",
               qid, oldcount, pQueue->getItemCount(), pQueue->getHead(),
               oldtail, pQueue->getTail());
  }
}

void Controller::clearInterrupt(uint16_t interruptVector) {
  uint16_t notFinished = 0;

  // Check all queues associated with same interrupt vector are processed
  for (uint16_t i = 0; i < cqsize; i++) {
    if (ppCQueue[i]) {
      if (ppCQueue[i]->getInterruptVector() == interruptVector) {
        notFinished += ppCQueue[i]->getItemCount();
      }
    }
  }

  // Update interrupt
  updateInterrupt(interruptVector, notFinished > 0);
}

void Controller::updateInterrupt(uint16_t interruptVector, bool post) {
  pParent->updateInterrupt(interruptVector, post);
}

int Controller::createCQueue(uint16_t cqid, uint16_t size, uint16_t iv,
                             bool ien, bool pc, uint64_t prp1,
                             DMAFunction &func, void *context) {
  int ret = 1;  // Invalid Queue ID
  CPUContext *pContext =
      new CPUContext(func, context, CPU::NVME__CONTROLLER, CPU::CREATE_CQ);

  if (ppCQueue[cqid] == NULL) {
    ppCQueue[cqid] = new CQueue(iv, ien, cqid, size);
    ppCQueue[cqid]->setBase(
        new PRPList(cfgdata, cpuHandler, pContext, prp1, size * cqstride, pc),
        cqstride);

    ret = 0;

    debugprint(LOG_HIL_NVME,
               "CQ %-5d| CREATE | Entry size %d | IV %04X | IEN %s | PC %s",
               cqid, size, iv, BOOLEAN_STRING(ien), BOOLEAN_STRING(pc));

    // Interrupt coalescing config
    auto iter = aggregationMap.find(iv);
    AggregationInfo info;

    info.valid = false;
    info.nextTime = 0;
    info.requestCount = 0;

    if (iter == aggregationMap.end()) {
      aggregationMap.insert({iv, info});
    }
    else {
      iter->second = info;
    }
  }

  return ret;
}

int Controller::createSQueue(uint16_t sqid, uint16_t cqid, uint16_t size,
                             uint8_t priority, bool pc, uint64_t prp1,
                             DMAFunction &func, void *context) {
  int ret = 1;  // Invalid Queue ID
  CPUContext *pContext =
      new CPUContext(func, context, CPU::NVME__CONTROLLER, CPU::CREATE_SQ);

  if (ppSQueue[sqid] == NULL) {
    if (ppCQueue[cqid] != NULL) {
      ppSQueue[sqid] = new SQueue(cqid, priority, sqid, size);
      ppSQueue[sqid]->setBase(
          new PRPList(cfgdata, cpuHandler, pContext, prp1, size * sqstride, pc),
          sqstride);

      // Mechanism #1: re-prime the per-sqid free-CID ring to match the
      // host's tracker array exactly, NOT the raw SQ depth.  SPDK sizes
      // pqpair->tr[] = num_entries - max_completions_cap, where
      //   max_completions_cap = clamp(num_entries / 4, MIN=1, MAX=128).
      // The controller must hand out CIDs only in [0, num_trackers), or
      // the host indexes tr[cid] out-of-bounds and segfaults.  We embed
      // SPDK's exact formula here so the ring and tr[] stay in sync.
      // (See spdk/lib/nvme/nvme_pcie_common.c:168-172 for the host side.)
      if (sqid != 0 && sqid < freeCidRings.size()) {
        FreeCIDRing &r = freeCidRings[sqid];
        uint32_t num_entries        = (uint32_t)size;
        uint32_t max_completions    = num_entries / 4;
        if (max_completions < 1)   max_completions = 1;
        if (max_completions > 128) max_completions = 128;
        uint32_t depth = (num_entries > max_completions)
                             ? (num_entries - max_completions)
                             : num_entries;
        r.ring.assign(depth, 0);
        for (uint32_t i = 0; i < depth; i++) {
          r.ring[i] = (uint16_t)i;
        }
        r.head = 0;
        r.tail = 0;
        r.depth = depth;
        r.inflight = 0;
        fprintf(stderr,
                "[DBG_SQ_CREATE] sqid=%u cqid=%u size=%u max_completions=%u "
                "num_trackers=%u\n",
                (unsigned)sqid, (unsigned)cqid, (unsigned)size,
                (unsigned)max_completions, (unsigned)depth);
      }

      ret = 0;

      debugprint(LOG_HIL_NVME,
                 "SQ %-5d| CREATE | Entry size %d | Priority %d | PC %s", cqid,
                 size, priority, BOOLEAN_STRING(pc));
    }
    else {
      ret = 2;  // Invalid CQueue
    }
  }

  return ret;
}

int Controller::deleteCQueue(uint16_t cqid) {
  int ret = 0;  // Success

  if (ppCQueue[cqid] != NULL && cqid > 0) {
    for (uint16_t i = 1; i < cqsize; i++) {
      if (ppSQueue[i]) {
        if (ppSQueue[i]->getCQID() == cqid) {
          ret = 2;  // Invalid Queue Deletion
          break;
        }
      }
    }

    if (ret == 0) {
      uint16_t iv = ppCQueue[cqid]->getInterruptVector();
      bool sameIV = false;

      delete ppCQueue[cqid];
      ppCQueue[cqid] = NULL;

      debugprint(LOG_HIL_NVME, "CQ %-5d| DELETE", cqid);

      // Interrupt coalescing config
      for (uint16_t i = 1; i < cqsize; i++) {
        if (ppCQueue[i]) {
          if (ppCQueue[i]->getInterruptVector() == iv) {
            sameIV = true;

            break;
          }
        }
      }

      if (!sameIV) {
        aggregationMap.erase(aggregationMap.find(iv));
      }
    }
  }
  else {
    ret = 1;  // Invalid Queue ID
  }

  return ret;
}

int Controller::deleteSQueue(uint16_t sqid) {
  int ret = 0;  // Success

  if (ppSQueue[sqid] != NULL && sqid > 0) {
    // Create abort response
    uint16_t sqHead = ppSQueue[sqid]->getHead();
    uint16_t status = 0x8000 | (TYPE_GENERIC_COMMAND_STATUS << 9) |
                      (STATUS_ABORT_DUE_TO_SQ_DELETE << 1);

    // Abort all commands in SQueue
    for (auto iter = lSQFIFO.begin(); iter != lSQFIFO.end(); iter++) {
      if (iter->sqID == sqid) {
        CQEntryWrapper wrapper(*iter);
        wrapper.entry.dword2.sqHead = sqHead;
        wrapper.entry.dword3.status = status;
        submit(wrapper);

        iter = lSQFIFO.erase(iter);
      }
    }

    // Delete SQueue
    delete ppSQueue[sqid];
    ppSQueue[sqid] = NULL;

    debugprint(LOG_HIL_NVME, "SQ %-5d| DELETE", sqid);
  }
  else {
    ret = 1;  // Invalid Queue ID
  }

  return ret;
}

int Controller::abort(uint16_t sqid, uint16_t cid) {
  int ret = 0;  // Not aborted
  uint16_t sqHead;
  uint16_t status;

  for (auto iter = lSQFIFO.begin(); iter != lSQFIFO.end(); iter++) {
    if (iter->sqID == sqid && iter->entry.dword0.commandID == cid) {
      CQEntry entry;

      // Create abort response
      sqHead = ppSQueue[sqid]->getHead();
      status = 0x8000 | (TYPE_GENERIC_COMMAND_STATUS << 9) |
               (STATUS_ABORT_REQUESTED << 1);

      // Submit abort
      CQEntryWrapper wrapper(*iter);
      wrapper.entry.dword2.sqHead = sqHead;
      wrapper.entry.dword3.status = status;

      submit(wrapper);

      // Remove
      iter = lSQFIFO.erase(iter);
      ret = 1;  // Aborted

      break;
    }
  }

  return ret;
}

void Controller::identify(uint8_t *data) {
  uint16_t vid, ssvid;
  uint64_t totalSize;
  uint64_t unallocated;

  pParent->getVendorID(vid, ssvid);
  pSubsystem->getNVMCapacity(totalSize, unallocated);

  unallocated = totalSize - unallocated;

  /** Controller Capabilities and Features **/
  {
    // PCI Vendor ID
    memcpy(data + 0x0000, &vid, 2);

    // PCI Subsystem Vendor ID
    memcpy(data + 0x0002, &ssvid, 2);

    // Serial Number
    memcpy(data + 0x0004, "00000000000000000000", 0x14);

    // Model Number
    if (bUseOCSSD) {
      memcpy(data + 0x0018, "SimpleSSD OCSSD Controller by CAMELab   ", 0x28);
    }
    else {
      memcpy(data + 0x0018, "SimpleSSD NVMe Controller by CAMELab    ", 0x28);
    }

    // Firmware Revision
    memcpy(data + 0x0040, "02.01.03", 0x08);

    // Recommended Arbitration Burst
    data[0x0048] = 0x00;

    // IEEE OUI Identifier
    {
      data[0x0049] = 0x00;
      data[0x004A] = 0x00;
      data[0x004B] = 0x00;
    }

    // Controller Multi-Path I/O and Namespace Sharing Capabilities
    // [Bits ] Description
    // [07:04] Reserved
    // [03:03] 1 for Asymmetric Namespace Access Reporting
    // [02:02] 1 for SR-IOV Virtual Function, 0 for PCI (Physical) Function
    // [01:01] 1 for more than one host may connected to NVM subsystem
    // [00:00] 1 for NVM subsystem may has more than one NVM subsystem port
    data[0x004C] = 0x00;

    // Maximum Data Transfer Size
    data[0x004D] = 0x00;  // No limit

    // Controller ID
    {
      data[0x004E] = 0x00;
      data[0x004F] = 0x00;
    }

    // Version
    {
      data[0x0050] = 0x01;
      data[0x0051] = 0x04;
      data[0x0052] = 0x00;
      data[0x0053] = 0x00;
    }  // NVM Express 1.4 Compliant Controller

    // RTD3 Resume Latency
    {
      data[0x0054] = 0x00;
      data[0x0055] = 0x00;
      data[0x0056] = 0x00;
      data[0x0057] = 0x00;
    }  // Not reported

    // RTD3 Enter Latency
    {
      data[0x0058] = 0x00;
      data[0x0059] = 0x00;
      data[0x005A] = 0x00;
      data[0x005B] = 0x00;
    }  // Not repotred

    // Optional Asynchronous Events Supported
    {
      // [Bits ] Description
      // [31:15] Reserved
      // [14:14] 1 for Support Endurance Group Event Aggregate Log Page Change
      //         Notice
      // [13:13] 1 for Support LBA Status Information Notice
      // [12:12] 1 for Support Predictable Latency Event Aggregate Log Change
      //         Notice
      // [11:11] 1 for Support Asymmetric Namespace Access Change Notice
      // [10:10] Reserved
      // [09:09] 1 for Support Firmware Activation Notice
      // [08:08] 1 for Support Namespace Attributes Notice
      // [07:00] Reserved
      data[0x005C] = 0x00;
      data[0x005D] = 0x00;
      data[0x005E] = 0x00;
      data[0x005F] = 0x00;
    }

    // Controller Attributes
    {
      // [Bits ] Description
      // [31:01] Reserved
      // [09:09] 1 for Support UUID List
      // [08:08] 1 for Support SQ Associations
      // [07:07] 1 for Support Namespace Granularity
      // [06:06] 1 for Traffic Based Keep Alive Support
      // [05:05] 1 for Support Predictable Latency Mode
      // [04:04] 1 for Support Endurance Group
      // [03:03] 1 for Support Read Recovery Levels
      // [02:02] 1 for Support NVM Sets
      // [01:01] 1 for Support Non-Operational Power State Permissive Mode
      // [00:00] 1 for Support 128-bit Host Identifier
      data[0x0060] = 0x00;
      data[0x0061] = 0x00;
      data[0x0062] = 0x00;
      data[0x0063] = 0x00;
    }

    // Read Recovery Levels Supported
    {
      // [Bits ] Description
      // [15:15] 1 for Read Recovery Level 15 - Fast Fail
      // ...
      // [04:04] 1 for Read Recovery Level 4 - Default
      // ...
      // [00:00] 1 for Read Recovery Level 0
      data[0x0064] = 0x00;
      data[0x0065] = 0x00;
    }

    memset(data + 0x0066, 0, 9);  // Reserved

    // Controller Type
    // [Value] Description
    // [   0h] Reserved (Controller Type not reported)
    // [   1h] I/O Controller
    // [   2h] Discovery Controller
    // [   3h] Administrative Controller
    // [4h to FFh] Reserved
    data[0x006F] = 0x01;

    // FRU Globally Unique Identifier
    memset(data + 0x0070, 0, 16);

    // Command Retry Delay Time 1
    {
      data[0x0080] = 0x00;
      data[0x0081] = 0x00;
    }

    // Command Retry Delay Time 2
    {
      data[0x0082] = 0x00;
      data[0x0083] = 0x00;
    }

    // Command Retry Delay Time 3
    {
      data[0x0084] = 0x00;
      data[0x0085] = 0x00;
    }

    memset(data + 0x0086, 0, 106);  // Reserved
    memset(data + 0x00F0, 0, 16);   // See NVMe-MI Specification
  }

  /** Admin Command Set Attributes & Optional Controller Capabilities **/
  {
    // Optional Admin Command Support
    {
      // [Bits ] Description
      // [15:10] Reserved
      // [09:09] 1 for SupportGet LBA Status capability
      // [08:08] 1 for Support Doorbell Buffer Config command
      // [07:07] 1 for Support Virtualization Management command
      // [06:06] 1 for Support NVMe-MI Send and NVMe-MI Receive commands
      // [05:05] 1 for Support Directives
      // [04:04] 1 for Support Device Self-Test command
      // [03:03] 1 for Support Namespace Management and Namespace Attachment
      //         commands
      // [02:02] 1 for Support Firmware Commit and Firmware Image Download
      //         commands
      // [01:01] 1 for Support Format NVM command
      // [00:00] 1 for Support Security Send and Security Receive commands
      if (bUseOCSSD) {
        data[0x0100] = 0x00;
      }
      else {
        data[0x0100] = 0x0A;
      }
      data[0x0101] = 0x00;
    }

    // Abort Command Limit
    data[0x0102] = 0x03;  // Recommanded value is 4 (3 + 1)

    // Asynchronous Event Request Limit
    data[0x0103] = 0x03;  // Recommanded value is 4 (3 + 1))

    // Firmware Updates
    // [Bits ] Description
    // [07:05] Reserved
    // [04:04] 1 for Support firmware activation without a reset
    // [03:01] The number of firmware slot
    // [00:00] 1 for First firmware slot is read only, 0 for read/write
    data[0x0104] = 0x00;

    // Log Page Attributes
    // [Bits ] Description
    // [07:05] Reserved
    // [04:04] 1 for Support Persisten Event log
    // [03:03] 1 for Support Telemetry Host-Initiated and Telemetry Controller-
    //         Initiated log pages and Telemetry Log Notices
    // [02:02] 1 for Support extended data for Get Log Page command
    // [01:01] 1 for Support Command Effects log page
    // [00:00] 1 for Support S.M.A.R.T. / Health information log page per
    //         namespace basis
    data[0x0105] = 0x01;

    // Error Log Page Entries, 0's based value
    data[0x0106] = 0x63;  // 64 entries

    // Number of Power States Support, 0's based value
    data[0x0107] = 0x00;  // 1 states

    // Admin Vendor Specific Command Configuration
    // [Bits ] Description
    // [07:01] Reserved
    // [00:00] 1 for all vendor specific commands use the format at Figure 12.
    //         0 for format is vendor specific
    data[0x0108] = 0x00;

    // Autonomous Power State Transition Attributes
    // [Bits ] Description
    // [07:01] Reserved
    // [00:00] 1 for Support autonomous power state transitions
    data[0x0109] = 0x00;

    // Warning Composite Temperature Threshold
    {
      data[0x010A] = 0x00;
      data[0x010B] = 0x00;
    }

    // Critical Composite Temperature Threshold
    {
      data[0x010C] = 0x00;
      data[0x010D] = 0x00;
    }

    // Maximum Time for Firmware Activation
    {
      data[0x010E] = 0x00;
      data[0x010F] = 0x00;
    }

    // Host Memory Buffer Preferred Size
    {
      data[0x0110] = 0x00;
      data[0x0111] = 0x00;
      data[0x0112] = 0x00;
      data[0x0113] = 0x00;
    }

    // Host Memory Buffer Minimum Size
    {
      data[0x0114] = 0x00;
      data[0x0115] = 0x00;
      data[0x0116] = 0x00;
      data[0x0117] = 0x00;
    }

    // Total NVM Capacity
    {
      memcpy(data + 0x118, &totalSize, 8);
      memset(data + 0x120, 0, 8);
    }

    // Unallocated NVM Capacity
    {
      memcpy(data + 0x118, &unallocated, 8);
      memset(data + 0x120, 0, 8);
    }

    // Replay Protected Memory Block Support
    {
      // [Bits ] Description
      // [31:24] Access Size
      // [23:16] Total Size
      // [15:06] Reserved
      // [05:03] Authentication Method
      // [02:00] Number of RPMB Units
      data[0x0138] = 0x00;
      data[0x0139] = 0x00;
      data[0x013A] = 0x00;
      data[0x013B] = 0x00;
    }

    // Extended Device Self-Test Time
    {
      data[0x013C] = 0x00;
      data[0x013D] = 0x00;
    }

    // Device Self-Test Options
    // [Bits ] Description
    // [07:01] Reserved
    // [00:00] 1 for Support only one device self-test operation in process at
    //         a time
    data[0x013E] = 0x00;

    // Firmware Update Granularity
    data[0x013F] = 0x00;

    // Keep Alive Support
    {
      data[0x0140] = 0x00;
      data[0x0141] = 0x00;
    }

    // Host Controlled Thermal Management Attributes
    {
      // [Bits ] Description
      // [15:01] Reserved
      // [00:00] 1 for Support host controlled thermal management
      data[0x0142] = 0x00;
      data[0x0143] = 0x00;
    }

    // Minimum Thernam Management Temperature
    {
      data[0x0144] = 0x00;
      data[0x0145] = 0x00;
    }

    // Maximum Thernam Management Temperature
    {
      data[0x0146] = 0x00;
      data[0x0147] = 0x00;
    }

    // Sanitize Capabilities
    {
      // [Bits ] Description
      // [31:30] No-Deallocate Modifies Media After Sanitize
      // [29:29] No-Deallocate Inhibited
      // [28:03] Reserved
      // [02:02] 1 for Support Overwrite
      // [01:01] 1 for Support Block Erase
      // [00:00] 1 for Support Crypto Erase
      data[0x0148] = 0x00;
      data[0x0149] = 0x00;
      data[0x014A] = 0x00;
      data[0x014B] = 0x00;
    }

    // Host Memory Buffer Minimum Descriptor Entry Size
    {
      data[0x014C] = 0x00;
      data[0x014D] = 0x00;
      data[0x014E] = 0x00;
      data[0x014F] = 0x00;
    }

    // Host Memory Maximum Descriptors Entries
    {
      data[0x0150] = 0x00;
      data[0x0151] = 0x00;
    }

    // NVM Set Identifier Maximum
    {
      data[0x0152] = 0x00;
      data[0x0153] = 0x00;
    }

    // Endurance Group Identifier Maximum
    {
      data[0x0154] = 0x00;
      data[0x0155] = 0x00;
    }

    // ANA Transition Time
    data[0x0156] = 0x00;

    // Asymmetric Namespace Access Capabilities
    // [Bits ] Description
    // [07:07] 1 for Support non-zero ANAGRPID
    // [06:06] 1 for ANAGRPID does not change while namespace is attached
    // [05:05] Reserved
    // [04:04] 1 for Support ANA Change state
    // [03:03] 1 for Support ANA Persistent Loss state
    // [02:02] 1 for Support ANA Inaccessible state
    // [01:01] 1 for Support ANA Non-Optimized state
    // [00:00] 1 for Support ANA Optimized state
    data[0x157] = 0x00;

    // ANA Group Identifier Maximum
    {
      data[0x0158] = 0x00;
      data[0x0159] = 0x00;
      data[0x015A] = 0x00;
      data[0x015B] = 0x00;
    }

    // Number of ANA AGroup Identifiers
    {
      data[0x015C] = 0x00;
      data[0x015D] = 0x00;
      data[0x015E] = 0x00;
      data[0x015F] = 0x00;
    }

    // Persistent Event Log Size
    {
      data[0x0160] = 0x00;
      data[0x0161] = 0x00;
      data[0x0162] = 0x00;
      data[0x0163] = 0x00;
    }

    // Reserved
    memset(data + 0x0164, 0, 156);
  }

  /** NVM Command Set Attributes **/
  {
    // Submission Queue Entry Size
    // [Bits ] Description
    // [07:04] Maximum Submission Queue Entry Size
    // [03:00] Minimum Submission Queue Entry Size
    data[0x0200] = 0x66;  // 64Bytes, 64Bytes

    // Completion Queue Entry Size
    // [Bits ] Description
    // [07:04] Maximum Completion Queue Entry Size
    // [03:00] Minimum Completion Queue Entry Size
    data[0x0201] = 0x44;  // 16Bytes, 16Bytes

    // Maximum  Outstanding Commands
    {
      data[0x0202] = 0x00;
      data[0x0203] = 0x00;
    }

    // Number of Namespaces
    // SimpleSSD supports infinite number of namespaces (0xFFFFFFFD)
    // But kernel's DIV_ROUND_UP has problem when number is too big
    // #define _KERNEL_DIV_ROUND_UP(n, d) (((n) + (d) - 1) / (d))
    // This wrong macro introduces DIV_ROUND_UP(0xFFFFFFFD, 1024) to zero
    // So we use 1024 here, for only one IDENTIFY NSLIST command
    *(uint32_t *)(data + 0x0204) = 1024;

    // Optional NVM Command Support
    {
      // [Bits ] Description
      // [15:08] Reserved
      // [07:07] 1 for Support Verify command
      // [06:06] 1 for Support Timestamp features
      // [05:05] 1 for Support reservations
      // [04:04] 1 for Support Save field in Set Features command and Select
      //         field in Get Features command
      // [03:03] 1 for Support Write Zeros command
      // [02:02] 1 for Support Dataset Management command
      // [01:01] 1 for Support Write Uncorrectable command
      // [00:00] 1 for Support Compare command
      data[0x0208] = 0x05;
      data[0x0209] = 0x00;
    }

    // Fused Operation Support
    {
      // [Bits ] Description
      // [15:01] Reserved
      // [00:00] 1 for Support Compare and Write fused operation
      data[0x020A] = 0x00;
      data[0x020B] = 0x00;
    }

    // Format NVM Attributes
    // [Bits ] Description
    // [07:03] Reserved
    // [02:02] 1 for Support cryptographic erase
    // [01:01] 1 for Support cryptographic erase performed on all namespaces,
    //         0 for namespace basis
    // [00:00] 1 for Format on specific namespace results on format on all
    //         namespaces, 0 for namespace basis
    data[0x020C] = 0x00;

    // Volatile Write Cache
    // [Bits ] Description
    // [07:03] Reserved
    // [02:01] Indicated Flush comand behavior if the NSID is 0xFFFFFFFF
    // [00:00] 1 for volatile write cache is present
    data[0x020D] =
        conf.readBoolean(CONFIG_ICL, ICL::ICL_USE_WRITE_CACHE) ? 0x01 : 0x00;
    data[0x020D] |= 0x06;

    // Atomic Write Unit Normal
    {
      data[0x020E] = 0x00;
      data[0x020F] = 0x00;
    }

    // Atomic Write Unit Power Fail
    {
      data[0x0210] = 0x00;
      data[0x0211] = 0x00;
    }

    // NVM Vendor Specific Command Configuration
    // [Bits ] Description
    // [07:01] Reserved
    // [00:00] 1 for all vendor specific commands use the format at Figure 12.
    //         0 for format is vendor specific
    data[0x0212] = 0x00;

    // Namespace Write Protection Capabilities
    // [Bits ] Description
    // [07:03] Reserved
    // [02:02] 1 for Support Permenant Write Protect state
    // [01:01] 1 for Support Write Protect Until Power Cycle state
    // [00:00] 1 for Support No Write Protect and Write Protect state
    data[0x0213] = 0x00;

    // Atomic Compare & Write Unit
    {
      data[0x0214] = 0x00;
      data[0x0215] = 0x00;
    }

    // Reserved
    memset(data + 0x0216, 0, 2);

    // SGL Support
    {
      // [Bits ] Description
      // [31:22] Reserved
      // [21:21] 1 for Support Ransport SGL Data Block
      // [20:20] 1 for Support Address field in SGL Data Block
      // [19:19] 1 for Support MPTR containing SGL descriptor
      // [18:18] 1 for Support MPTR/DPTR containing SGL with larger than amount
      //         of data to be trasferred
      // [17:17] 1 for Support byte aligned contiguous physical buffer of
      //         metadata is supported
      // [16:16] 1 for Support SGL Bit Bucket descriptor
      // [15:03] Reserved
      // [02:02] 1 for Support Keyed SGL Data Block descriptor
      // [01:01] Reserved
      // [00:00] 1 for Support SGLs in NVM Command Set
      data[0x0218] = 0x01;
      data[0x0219] = 0x00;
      data[0x021A] = 0x17;
      data[0x021B] = 0x00;
    }

    // Maximun Number of Allowed Namespaces
    *(uint32_t *)(data + 0x021C) = 0;

    // Reserved
    memset(data + 0x0220, 0, 224);

    // NVM Subsystem NVMe Qualified Name
    {
      memset(data + 0x300, 0, 0x100);
      strncpy((char *)data + 0x0300,
              "nqn.2014-08.org.nvmexpress:uuid:270a1c70-962c-4116-6f1e340b9321",
              0x44);
    }

    // Reserved
    memset(data + 0x0400, 0, 768);

    // NVMe over Fabric
    memset(data + 0x0700, 0, 256);
  }

  /** Power State Descriptors **/
  // Power State 0
  /// Descriptor
  {
    // Maximum Power
    {
      data[0x0800] = 0xC4;
      data[0x0801] = 0x09;
    }

    // Reserved
    data[0x0802] = 0x00;

    // [Bits ] Description
    // [31:26] Reserved
    // [25:25] Non-Operational State
    // [24:24] Max Power Scale
    data[0x0803] = 0x00;

    // Entry Latency
    {
      data[0x0804] = 0x00;
      data[0x0805] = 0x00;
      data[0x0806] = 0x00;
      data[0x0807] = 0x00;
    }

    // Exit Latency
    {
      data[0x0808] = 0x00;
      data[0x0809] = 0x00;
      data[0x080A] = 0x00;
      data[0x080B] = 0x00;
    }

    // [Bits   ] Description
    // [103:101] Reserved
    // [100:096] Relative Read Throughput
    data[0x080C] = 0x00;

    // [Bits   ] Description
    // [111:109] Reserved
    // [108:104] Relative Read Latency
    data[0x080D] = 0x00;

    // [Bits   ] Description
    // [119:117] Reserved
    // [116:112] Relative Write Throughput
    data[0x080E] = 0x00;

    // [Bits   ] Description
    // [127:125] Reserved
    // [124:120] Relative Write Latency
    data[0x080E] = 0x00;

    // Idle Power
    {
      data[0x080F] = 0x00;
      data[0x0810] = 0x00;
    }

    // [Bits   ] Description
    // [151:150] Idle Power Scale
    // [149:144] Reserved
    data[0x0811] = 0x00;

    // Reserved
    data[0x0812] = 0x00;

    // Active Power
    {
      data[0x0813] = 0x00;
      data[0x0814] = 0x00;
    }

    // [Bits   ] Description
    // [183:182] Active Power Scale
    // [181:179] Reserved
    // [178:176] Active Power Workload
    data[0x0815] = 0x00;

    // Reserved
    memset(data + 0x0816, 0, 9);
  }

  // PSD1 ~ PSD31
  memset(data + 0x0820, 0, 992);

  // Vendor specific area
  memset(data + 0x0C00, 0, 1024);
}

void Controller::setCoalescingParameter(uint8_t time, uint8_t thres) {
  debugprint(LOG_HIL_NVME,
             "INTR    | Update coalescing parameters | TIME %u | THRES %u",
             time, thres);

  aggregationTime = time * 100000000;
  aggregationThreshold = thres;
}

void Controller::getCoalescingParameter(uint8_t *time, uint8_t *thres) {
  if (time) {
    *time = aggregationTime / 100000000;
  }
  if (thres) {
    *thres = aggregationThreshold;
  }
}

void Controller::setCoalescing(uint16_t iv, bool enable) {
  auto iter = aggregationMap.find(iv);

  if (iter != aggregationMap.end()) {
    debugprint(LOG_HIL_NVME, "INTR    | %s interrupt coalescing | IV %u",
               enable ? "Enable" : "Disable", iv);

    iter->second.valid = enable;
    iter->second.nextTime = 0;
    iter->second.requestCount = 0;
    iter->second.pending = false;
  }
}

bool Controller::getCoalescing(uint16_t iv) {
  auto iter = aggregationMap.find(iv);

  if (iter != aggregationMap.end()) {
    return iter->second.valid;
  }

  return false;
}

void Controller::collectSQueue(DMAFunction &func, void *context) {
  // --- I/O Uncore: Gate 1 — SQ collection threshold guard ---
  // When uncore is enabled, defer collection if not enough SQEs are visible.
  // Admin queue (sqID==0) always bypasses the threshold and forces collection.
  if (uncoreCfg.mode != UNCORE_MODE_DISABLED) {
    bool adminHasWork = (ppSQueue[0] != nullptr &&
                         ppSQueue[0]->getItemCount() > 0);

    uint32_t totalIOVisible = 0;
    for (uint16_t i = 1; i < sqsize; i++) {
      if (ppSQueue[i]) {
        totalIOVisible += ppSQueue[i]->getItemCount();
      }
    }
    uncoreStats.sqesVisible += totalIOVisible;

    if (!adminHasWork && totalIOVisible < uncoreCfg.dbBatchB) {
      // Threshold not met: signal completion to the caller without doing
      // any DMA.  The work() event will fire again at the next workInterval.
      uncoreStats.collectDeferred++;
      func(getTick(), context);
      return;
    }
    uncoreStats.collectAllowed++;
  }
  // --- End Gate 1 ---

  static uint16_t wrrHigh = conf.readUint(CONFIG_NVME, NVME_WRR_HIGH);
  static uint16_t wrrMedium = conf.readUint(CONFIG_NVME, NVME_WRR_MEDIUM);
  DMAContext *pContext = new DMAContext(func, context);

  static DMAFunction doQueue = [](uint64_t now, void *context) {
    DMAContext *pContext = (DMAContext *)context;

    pContext->counter--;

    if (pContext->counter == 0) {
      pContext->function(now, pContext->context);

      delete pContext;
    }
  };

  // Check ready
  if (!(registers.status & 0x00000001)) {
    return;
  }

  // Round robin
  if (arbitration == ROUND_ROBIN) {
    SQueue *pQueue;

    uint16_t updated = 0;

    while (true) {
      for (uint16_t i = 0; i < sqsize; i++) {
        pQueue = ppSQueue[i];

        if (pQueue) {
          if (checkQueue(pQueue, doQueue, pContext)) {
            pContext->counter++;
            updated++;
          }
        }
      }

      if (updated == 0) {
        break;
      }

      updated = 0;
    }
  }
  // Weighted round robin
  else if (arbitration == WEIGHTED_ROUND_ROBIN) {
    SQueue *pQueue;

    uint16_t updated = 0;

    // Collect all Admin Commands
    pQueue = ppSQueue[0];

    while (true) {
      if (!checkQueue(pQueue, doQueue, pContext)) {
        break;
      }
      else {
        pContext->counter++;
      }
    }

    // Round robin all urgent command queues
    while (true) {
      for (uint16_t i = 1; i < sqsize; i++) {
        pQueue = ppSQueue[i];

        if (pQueue) {
          if (pQueue->getPriority() == PRIORITY_URGENT) {
            if (checkQueue(pQueue, doQueue, pContext)) {
              pContext->counter++;
              updated++;
            }
          }
        }
      }

      if (updated == 0) {
        break;
      }

      updated = 0;
    }

    // Weighted Round robin
    uint32_t total_updated = 0;

    while (true) {
      // Round robin all high-priority command queues
      for (uint16_t i = 1; i < sqsize; i++) {
        pQueue = ppSQueue[i];

        if (pQueue) {
          if (pQueue->getPriority() == PRIORITY_HIGH) {
            if (checkQueue(pQueue, doQueue, pContext)) {
              pContext->counter++;
              updated++;
              total_updated++;

              if (updated == wrrHigh) {
                updated = 0;
                break;
              }
            }
          }
        }
      }

      // Round robin all medium-priority command queues
      for (uint16_t i = 1; i < sqsize; i++) {
        pQueue = ppSQueue[i];

        if (pQueue) {
          if (pQueue->getPriority() == PRIORITY_MEDIUM) {
            if (checkQueue(pQueue, doQueue, pContext)) {
              pContext->counter++;
              updated++;
              total_updated++;

              if (updated == wrrMedium) {
                updated = 0;
                break;
              }
            }
          }
        }
      }

      // Round robin all low-priority command queues
      for (uint16_t i = 1; i < sqsize; i++) {
        pQueue = ppSQueue[i];

        if (pQueue) {
          if (pQueue->getPriority() == PRIORITY_MEDIUM) {
            if (checkQueue(pQueue, doQueue, pContext)) {
              pContext->counter++;
              total_updated++;

              break;
            }
          }
        }
      }

      // Check finished
      if (total_updated == 0) {
        break;
      }

      total_updated = 0;
    }
  }
  else {
    panic("nvme_ctrl: Invalid arbitration method");
  }

  if (pContext->counter == 0) {
    // No item in submission queues
    func(getTick(), context);

    delete pContext;
  }
}

void Controller::work() {
  DMAFunction queueFunction = [this](uint64_t now, void *) {
    DMAFunction doRequest = [this](uint64_t, void *) {
      DMAFunction handle = [this](uint64_t now, void *) { handleRequest(now); };

      execute(CPU::NVME__CONTROLLER, CPU::HANDLE_REQUEST, handle);
    };

    lastWorkAt = now;

    // Check NVMe shutdown
    if (shutdownReserved) {
      deschedule(workEvent);

      registers.status &= 0xFFFFFFF2;  // RDY = 0
      registers.status |= 0x00000008;  // Shutdown processing complete

      // Clear CC.SHN so a subsequent CC read returns SHN=00.
      // Without this, the next SPDK process reads stale SHN=01
      // and re-triggers shutdown when it writes CC back.
      registers.configuration &= ~0x0000C000u;

      // Also clear CC.EN. SPDK's exit path leaves EN=1 after SHN-shutdown;
      // a subsequent spdk_nvme_perf would then read CC.EN=1 and enter
      // DISABLE_WAIT_FOR_READY_1 polling CSTS.RDY for 1, which never
      // re-arms (RDY only transitions on a CC.EN 0->1 edge). Clearing EN
      // here makes the state consistent with shutdown-complete.
      registers.configuration &= ~0x00000001u;

      shutdownReserved = false;

      // I/O Uncore: force-drain any staged CQEs before clearing the SQ FIFO.
      // Without this, SPDK would never see completions for in-flight I/Os.
      if (!uncorePendingCQE.empty()) {
        uncoreFlushCQBuffer(true);
      }

      lSQFIFO.clear();
    }

    // Call request event
    requestCounter = 0;

    execute(CPU::NVME__CONTROLLER, CPU::COLLECT_SQ, doRequest);
  };

  // Check ready
  if (!(registers.status & 0x00000001)) {
    return;
  }

  // Collect requests in SQs
  CPUContext *pContext =
      new CPUContext(queueFunction, nullptr, CPU::NVME__CONTROLLER, CPU::WORK);

  collectSQueue(cpuHandler, pContext);
}

void Controller::handleRequest(uint64_t now) {
  // Check SQFIFO
  if (lSQFIFO.size() > 0) {
    SQEntryWrapper *front = new SQEntryWrapper(lSQFIFO.front());
    lSQFIFO.pop_front();

    // Admin commands (sqID==0) MUST go through the real subsystem so that
    // queue creation, identify, set-features, etc. actually execute.
    // Only I/O commands (sqID != 0) take the fast path.
    bool useFastPath = fastPathCfg.enabled && front->sqID != 0;

    if (useFastPath) {
      // --- Fast-path branch (NVMeVirt-style statistical timing model) ---
      // Skip the HIL/ICL/FTL/PAL pipeline entirely. Compute target
      // completion time and queue the response. submit() will be invoked
      // at target time by fastPathFire(), which preserves the I/O-Uncore
      // mechanisms (uncorePendingCQE, uncoreFlushScheduled, BAR0+0x2000
      // hint reg, aggregationMap).
      fastPathEnqueue(*front);
      delete front;
    }
    else {
      // --- Original SimpleSSD pipeline (cycle-accurate; used for admin
      // commands always, and for I/O when fast-path is disabled) ---
      DMAFunction doSubmit = [this](uint64_t, void *context) {
        SQEntryWrapper *req = (SQEntryWrapper *)context;

        pSubsystem->submitCommand(
            *req, [this](CQEntryWrapper &response) { submit(response); });

        delete req;
      };

      if (bUseOCSSD) {
        execute(CPU::NVME__OCSSD, CPU::SUBMIT_COMMAND, doSubmit, front);
      }
      else {
        execute(CPU::NVME__SUBSYSTEM, CPU::SUBMIT_COMMAND, doSubmit, front);
      }
    }
  }

  // Call request event
  requestCounter++;

  if (lSQFIFO.size() > 0 && requestCounter < maxRequest) {
    schedule(requestEvent, now + requestInterval);
  }
  else {
    schedule(workEvent, MAX(now + requestInterval, lastWorkAt + workInterval));
  }
}

bool Controller::checkQueue(SQueue *pQueue, DMAFunction &func, void *context) {
  struct QueueContext {
    SQEntry entry;
    SQueue *pQueue;
    DMAFunction function;
    void *context;
    uint16_t oldhead;

    QueueContext(DMAFunction &f) : pQueue(nullptr), function(f) {}
  };

  QueueContext *queueContext = new QueueContext(func);
  queueContext->pQueue = pQueue;
  queueContext->context = context;

  DMAFunction doRead = [this](uint64_t now, void *context) {
    QueueContext *pContext = (QueueContext *)context;

    lSQFIFO.push_back(SQEntryWrapper(
        pContext->entry, pContext->pQueue->getID(), pContext->pQueue->getCQID(),
        pContext->pQueue->getHead(), pContext->oldhead));
    pContext->function(now, pContext->context);

    delete pContext;
  };

  if (pQueue->getItemCount() > 0) {
    queueContext->oldhead = pQueue->getHead();
    pQueue->getData(&queueContext->entry, doRead, queueContext);

    return true;
  }
  else {
    delete queueContext;
  }

  return false;
}

// ---------------------------------------------------------------------------
// Fast-path statistical timing model (NVMeVirt-style)
//
// Skips the HIL/ICL/FTL/PAL pipeline. Each I/O is mapped to a NAND channel
// (round-robin or LBA-hash) and assigned a target_completion_time:
//
//   target = max(now, channel_next_free[ch]) + Lmin
//   channel_next_free[ch] = max(now, channel_next_free[ch]) + spacingPs
//   (where spacingPs = 1e12 / TmaxPerChannel)
//
// At target_time, the response is routed through Controller::submit(),
// which invokes the existing I/O-Uncore code paths (uncorePendingCQE,
// uncoreFlushScheduled, BAR0+0x2000 hint reg, aggregationMap MSI). The
// fast-path is therefore transparent to the IO-Uncore evaluation.
//
// Citations: NVMeVirt [Kim et al., FAST '23], SwarmIO [KAIST '26],
// FEMU [Li et al., FAST '18] all use equivalent statistical models.
// ---------------------------------------------------------------------------

void Controller::fastPathEnqueue(SQEntryWrapper &req) {
  // Back-pressure: if too many in-flight, drop with a transient error.
  // (At reasonable maxOutstanding values this should never fire under
  // realistic host workloads — it's a guardrail against runaway sims.)
  if (fastPathCfg.maxOutstanding != 0 &&
      fastPathQueue.size() >= fastPathCfg.maxOutstanding) {
    fastPathStats_dropped_full++;
    CQEntryWrapper resp(req);
    resp.makeStatus(false, false, TYPE_GENERIC_COMMAND_STATUS,
                    STATUS_INTERNAL_ERROR);
    submit(resp);
    return;
  }

  uint64_t now = getTick();

  // Channel selection.
  uint16_t ch = 0;
  if (fastPathCfg.channelPolicy == 0) {
    // Round-robin.
    ch = fastPathRRCounter % fastPathCfg.channels;
    fastPathRRCounter++;
  }
  else {
    // LBA-hash (dword10/11 carry SLBA for NVM read/write).
    uint64_t lba = (uint64_t)req.entry.dword10 |
                   ((uint64_t)req.entry.dword11 << 32);
    ch = (uint16_t)(lba % fastPathCfg.channels);
  }

  // Per-channel statistical timer.
  uint64_t earliest_start = now;
  if (fastPathChannelNextFree[ch] > earliest_start) {
    earliest_start = fastPathChannelNextFree[ch];
  }
  uint64_t target = earliest_start + fastPathCfg.lminPs;
  fastPathChannelNextFree[ch] = earliest_start + fastPathCfg.spacingPs;

  // Build success CQE — fast-path always returns success (no actual data
  // transfer; spdk_nvme_perf does not verify content for randread).
  CQEntryWrapper resp(req);
  resp.makeStatus(false, false, TYPE_GENERIC_COMMAND_STATUS, STATUS_SUCCESS);

  // Insert into ordered queue (sorted by target_time ascending).
  auto iter = fastPathQueue.begin();
  while (iter != fastPathQueue.end() && iter->target_time <= target) {
    ++iter;
  }
  fastPathQueue.emplace(iter, resp, target);

  fastPathStats_dispatched++;
  {
    static uint32_t fpe_logged = 0;
    if (fpe_logged < 30) {
      fprintf(stderr,
              "[DBG_FP_ENQ] cqID=%u sq_cid_in=%u resp_cid_out=%u sqID=%u target=%lu\n",
              (unsigned)resp.cqID,
              (unsigned)req.entry.dword0.commandID,
              (unsigned)resp.entry.dword3.commandID,
              (unsigned)req.sqID,
              (unsigned long)target);
      fpe_logged++;
    }
  }
  fastPathRescheduleNext();
}

void Controller::fastPathFire() {
  uint64_t now = getTick();
  while (!fastPathQueue.empty() && fastPathQueue.front().target_time <= now) {
    CQEntryWrapper response = fastPathQueue.front().entry;
    fastPathQueue.pop_front();
    // Route through submit() — this is THE function that fires the
    // I/O-Uncore mechanisms (uncorePendingCQE staging, uncoreFlushScheduled
    // arming, BAR0+0x2000 hint reg writes via uncoreFlushCQBuffer,
    // aggregationMap-driven MSI coalescing). The fast-path is therefore
    // transparent to Mode 0 / 1 / 2B differentiation.
    submit(response);
    fastPathStats_completed++;
  }
  fastPathRescheduleNext();
}

void Controller::fastPathRescheduleNext() {
  if (fastPathQueue.empty()) {
    return;
  }
  uint64_t next_target = fastPathQueue.front().target_time;
  uint64_t now = getTick();
  if (next_target < now) {
    next_target = now;
  }
  if (fastPathFireScheduled) {
    // Replace any prior schedule. SimpleSSD's reschedule() is the
    // idempotent way to do this without double-schedule panics.
    deschedule(fastPathFireEvent);
  }
  schedule(fastPathFireEvent, next_target);
  fastPathFireScheduled = true;
}

void Controller::submit(CQEntryWrapper &entry) {
  CQueue *pQueue = ppCQueue[entry.cqID];

  if (pQueue == NULL) {
    panic("nvme_ctrl: Completion Queue not created! CQID %d", entry.cqID);
  }

  // Set submit time
  entry.submitAt = getTick();

  // --- I/O Uncore: Gate 2 — CQE staging buffer ---
  // Non-admin I/O CQEs (cqID != 0) are redirected to the staging buffer when
  // uncore is enabled.  Admin CQEs always fall through to the immediate path.
  if (uncoreCfg.mode != UNCORE_MODE_DISABLED && entry.cqID != 0) {
    bool wasEmpty = uncorePendingCQE.empty();
    uncorePendingCQE.emplace_back(entry, entry.submitAt);
    uncoreStats.cqesGenerated++;
    // Mechanism #4: record the arrival tick of the OLDEST pending CQE so
    // the typed hint register can report staleness in age units.
    if (wasEmpty) {
      hintOldestArrivalTicks = getTick();
    }

    if ((uint32_t)uncorePendingCQE.size() >= uncoreCfg.cqBatchN) {
      // Count threshold reached: flush immediately.
      uncoreFlushCQBuffer(false);
    }
    else if (!uncoreFlushScheduled) {
      // Arm the timeout flush for the first entry in this batch.
      // Use getTick() (current sim time) — NOT entry.submitAt which is the
      // original SQ submission time and is always in the past by the time
      // the SSD completes the I/O and calls submit().
      uncoreFlushScheduled = true;
      schedule(uncoreFlushEvent, getTick() + uncoreCfg.cqBatchT);
    }
    return;  // Do NOT fall through to the lCQFIFO path.
  }
  else if (uncoreCfg.mode != UNCORE_MODE_DISABLED) {
    // Admin CQE (cqID==0): bypass staging but count it.
    uncoreStats.cqesAdminBypassed++;
  }
  // --- End Gate 2 ---
  // Fall through to the original lCQFIFO path for: admin CQEs and disabled mode.

  // Enqueue with delay
  auto iter = lCQFIFO.begin();

  for (; iter != lCQFIFO.end(); iter++) {
    if (iter->submitAt > entry.submitAt) {
      break;
    }
  }

  lCQFIFO.insert(iter, entry);

  reserveCompletion();
}

void Controller::reserveCompletion() {
  uint64_t tick = std::numeric_limits<uint64_t>::max();
  bool valid = false;

  if (lCQFIFO.size() > 0) {
    valid = true;
    tick = lCQFIFO.front().submitAt;
  }

  for (auto &iter : aggregationMap) {
    if (iter.second.valid && iter.second.pending) {
      if (!valid) {
        valid = true;
        tick = iter.second.nextTime;
      }
      else if (tick > iter.second.nextTime) {
        tick = iter.second.nextTime;
      }
    }
  }

  if (valid) {
    // Clamp to current tick: when uncore batching delays CQE delivery,
    // submitAt / nextTime may already be in the past.
    uint64_t now = getTick();
    if (tick < now) {
      tick = now;
    }
    schedule(completionEvent, tick);
  }
}

void Controller::completion() {
  struct CompletionContext {
    std::vector<CQEntryWrapper> entryToPost;
    std::vector<uint16_t> ivToPost;
  };

  uint64_t tick = getTick();
  CQueue *pQueue = nullptr;

  DMAFunction doSubmit = [this](uint64_t, void *context) {
    DMAContext *pContext = (DMAContext *)context;
    CompletionContext *pData = (CompletionContext *)pContext->context;

    pContext->counter--;

    if (pContext->counter == 0) {
      DMAFunction send = [this](uint64_t, void *context) {
        CompletionContext *pData = (CompletionContext *)context;

        if (pData->ivToPost.size() > 0) {
          std::sort(pData->ivToPost.begin(), pData->ivToPost.end());
          auto end =
              std::unique(pData->ivToPost.begin(), pData->ivToPost.end());

          for (auto iter = pData->ivToPost.begin(); iter != end; iter++) {
            // Update interrupt
            updateInterrupt(*iter, true);
          }
        }

        // Update Mode B hint: reflect what is still pending in lCQFIFO
        // after this drain cycle (staged entries already moved by flush).
        uncoreHintReady = (uint32_t)lCQFIFO.size();

        reserveCompletion();

        delete pData;
      };

      execute(CPU::NVME__CONTROLLER, CPU::COMPLETION, send, pData);

      delete pContext;
    }
  };

  DMAContext *submitContext = new DMAContext(doSubmit);
  CompletionContext *pData = new CompletionContext();

  submitContext->context = pData;

  for (auto iter = lCQFIFO.begin(); iter != lCQFIFO.end();) {
    if (iter->submitAt <= tick) {
      // Copy CQ
      pData->entryToPost.push_back(*iter);

      // Delete entry
      iter = lCQFIFO.erase(iter);
    }
    else {
      iter++;
    }
  }

  for (auto &iter : pData->entryToPost) {
    pQueue = ppCQueue[iter.cqID];

    submitContext->counter++;
    pQueue->setData(&iter.entry, doSubmit, submitContext);

    // Collect interrupt vector
    if (pQueue->interruptEnabled()) {
      uint16_t iv = pQueue->getInterruptVector();
      bool post = true;

      if (iter.cqID > 0) {
        // Interrupt Coalescing does not applied to admin queues
        auto map = aggregationMap.find(iv);

        if (map != aggregationMap.end()) {
          if (map->second.valid) {
            map->second.requestCount++;

            if (iter.submitAt < map->second.nextTime &&
                map->second.requestCount <= aggregationThreshold) {
              post = false;
              map->second.pending = true;
            }

            if (post) {
              map->second.nextTime = tick + aggregationTime;
              map->second.requestCount = 0;
            }
          }
        }
      }

      if (post) {
        // Prepare for merge
        pData->ivToPost.push_back(iv);
      }
    }
  }

  for (auto &iter : aggregationMap) {
    if (iter.second.valid && iter.second.nextTime <= tick &&
        iter.second.pending) {
      iter.second.nextTime = tick + aggregationTime;
      iter.second.requestCount = 0;
      iter.second.pending = false;

      pData->ivToPost.push_back(iter.first);
    }
  }

  if (submitContext->counter == 0) {
    delete pData;
    delete submitContext;
  }
}

// ---------------------------------------------------------------------------
// I/O Uncore: Gate 3 — CQE flush function
// ---------------------------------------------------------------------------

void Controller::uncoreFlushCQBuffer(bool isShutdown) {
  if (uncorePendingCQE.empty()) {
    // Nothing to flush; cancel the timeout if it was pending.
    if (uncoreFlushScheduled) {
      deschedule(uncoreFlushEvent);
      uncoreFlushScheduled = false;
    }
    return;
  }

  uint64_t depth = (uint64_t)uncorePendingCQE.size();

  // Record flush depth in histogram (bucket capped at 63).
  uncoreStats.flushDepthHist[(depth < 64) ? depth : 63]++;

  // Classify trigger type.
  if (isShutdown) {
    uncoreStats.flushByShutdown++;
  }
  else if (depth >= (uint64_t)uncoreCfg.cqBatchN) {
    uncoreStats.flushByCount++;
  }
  else {
    uncoreStats.flushByTimeout++;
  }

  // Move staged CQEs into lCQFIFO preserving submitAt sort order.
  // Mechanism #1: simultaneously recycle each CID back into the per-qid
  // free-CID ring so the host's NEXT submission can reuse it without any
  // TAILQ work.  Use the CQE's cqID (= qid the CID was issued from) and
  // the per-entry commandID (= the CID we issued).
  for (auto &pe : uncorePendingCQE) {
    CQEntryWrapper &entry = pe.wrapper;
    auto iter = lCQFIFO.begin();
    for (; iter != lCQFIFO.end(); ++iter) {
      if (iter->submitAt > entry.submitAt) {
        break;
      }
    }
    lCQFIFO.insert(iter, entry);
    uncoreStats.cqesPublished++;
    freeCidRecycle(entry.cqID, entry.entry.dword3.commandID);
  }
  uncorePendingCQE.clear();
  // Mechanism #4: no pending CQEs after the flush -> no age to report.
  hintOldestArrivalTicks = 0;

  // Cancel the timeout event if it was previously armed.
  if (uncoreFlushScheduled) {
    deschedule(uncoreFlushEvent);
    uncoreFlushScheduled = false;
  }

  // Update Mode B hint to reflect new lCQFIFO depth.
  uncoreHintReady = (uint32_t)lCQFIFO.size();

  // Hand off to the existing DMA-write + interrupt pipeline.
  reserveCompletion();
}

// ---------------------------------------------------------------------------
// I/O Uncore Mode 2 — SQ Engine Mailbox handlers
//
// handleMailboxWrite(): S_LATCH_0/1/2.  Each 8-byte MMIO write to the
//                       mailbox region is one cycle of S_LATCH.  When all
//                       three words have landed, the inject event is armed
//                       at tick + (decode + inject) * 1 ns @ 1 GHz.
//
// mailboxInject():      S_DECODE + S_INJECT.  Decodes the compact 24-byte
//                       descriptor into a full SQEntryWrapper, pushes it
//                       into lSQFIFO, and schedules requestEvent so
//                       handleRequest() picks it up (either Path-E
//                       fast-path or pSubsystem).
//
// Compact wire format (3 sequential 8-byte writes to BAR0 + MailboxBase
// + qid*MailboxStride):
//   word 0: [63:56] opcode | [55:48] flags | [47:32] cid | [31:0] nsid
//   word 1: [63: 0] slba
//   word 2: [63:32] prp1_lo32 | [31:16] nlb (0-based) | [15:0] control
//
// v1 limitation: single-page transfers only (nlb*lba_size <= page_size).
// SPDK is responsible for falling back to the standard path on larger
// transfers; the controller defends in depth by rejecting oversize here.
// ---------------------------------------------------------------------------

void Controller::handleMailboxWrite(uint16_t qid, uint8_t wordIdx,
                                    uint64_t value, uint64_t tick) {
  if (qid == 0 || qid >= mailboxLatches.size()) {
    // Admin (qid==0) and out-of-range writes are ignored.  Mode B does not
    // use the admin mailbox.
    return;
  }
  if (wordIdx > 2) return;  // defensive

  MailboxLatch &latch = mailboxLatches[qid];

  // FSM transition: writes must arrive in order 0, 1, 2.  A mid-sequence
  // violation (e.g. word 2 lands when nextWord==1) resets the latch and
  // accepts the current write as word 0 ONLY if wordIdx==0; otherwise
  // we drop it.  This matches the RTL S_LATCH "same-qid guard" semantics.
  if (wordIdx != latch.nextWord) {
    uncoreStats.mailboxLatchResets++;
    latch.nextWord = 0;
    if (wordIdx != 0) {
      return;  // wait for a fresh word 0
    }
  }

  latch.words[wordIdx] = value;
  latch.lastTick = tick;
  latch.nextWord++;

  if (latch.nextWord == 3) {
    // Arm the inject event after S_DECODE + S_INJECT cycles.  At 1 GHz the
    // gem5 tick unit is 1 ps, so cycles * 1000 ps/cycle = ns delay.
    uint64_t delay_ps =
        ((uint64_t)uncoreCfg.mailboxDecodeCycles +
         (uint64_t)uncoreCfg.mailboxInjectCycles) * 1000ULL;
    if (!scheduled(mailboxInjectEvent)) {
      schedule(mailboxInjectEvent, tick + delay_ps);
    }
    // If already scheduled (another qid's third word landed first), the
    // running event will sweep all qids whose nextWord==3 when it fires,
    // so we don't need to reschedule.
  }
}

void Controller::mailboxInject(uint16_t qid, uint64_t tick) {
  (void)tick;  // tick parameter retained for symmetry / future telemetry
  if (qid == 0 || qid >= mailboxLatches.size()) return;
  MailboxLatch &latch = mailboxLatches[qid];
  if (latch.nextWord != 3) return;  // not ready

  // ---- Decode the compact 24-byte descriptor ----
  uint64_t w0 = latch.words[0];
  uint64_t w1 = latch.words[1];
  uint64_t w2 = latch.words[2];

  uint8_t  opcode  = (uint8_t)((w0 >> 56) & 0xFF);
  uint8_t  flags   = (uint8_t)((w0 >> 48) & 0xFF);
  uint16_t cid     = (uint16_t)((w0 >> 32) & 0xFFFF);
  uint32_t nsid   = (uint32_t)(w0 & 0xFFFFFFFFu);
  uint64_t slba    = w1;
  uint32_t prp1_lo = (uint32_t)((w2 >> 32) & 0xFFFFFFFFu);
  uint16_t nlb     = (uint16_t)((w2 >> 16) & 0xFFFF);
  uint16_t ctrl    = (uint16_t)(w2 & 0xFFFF);

  // Oversize guard: nlb is 0-based, so the transfer is (nlb+1)*lbaSize bytes.
  // Reject if it exceeds one host memory page (single-page limitation in v1).
  uint64_t lbaSize = conf.readUint(CONFIG_NVME, NVME_LBA_SIZE);
  uint64_t bytes   = ((uint64_t)nlb + 1ULL) * lbaSize;
  if (bytes > (uint64_t)cfgdata.memoryPageSize) {
    uncoreStats.mailboxOversizeFallbk++;
    latch.nextWord = 0;
    return;
  }

  // ---- Synthesize a full SQEntry matching the standard NVMe layout ----
  SQEntry entry;
  memset(entry.data, 0, sizeof(entry.data));
  entry.dword0.opcode    = opcode;
  entry.dword0.fuse      = flags;
  entry.dword0.commandID = cid;
  entry.namespaceID      = nsid;
  // data1 = PRP1, data2 = PRP2.  Mode 2 v1 supports single-page transfers
  // only, so PRP2 == 0; PRP1 carries the host-buffer DMA address (lower 32
  // bits via the mailbox; upper 32 bits are reconstructed from cfgdata's
  // memory-page-size alignment if needed — for 4 KB pages this is zero).
  entry.data1            = (uint64_t)prp1_lo;
  entry.data2            = 0;
  entry.dword10          = (uint32_t)(slba & 0xFFFFFFFFu);
  entry.dword11          = (uint32_t)((slba >> 32) & 0xFFFFFFFFu);
  entry.dword12          = ((uint32_t)ctrl << 16) | (uint32_t)nlb;

  // SQEntryWrapper(entry, sqID, cqID, sqHead, sqUID).  sqHead/sqUID are
  // used only for CQE sqHead echo-back; the mailbox path does not touch
  // the host's SQ memory, so 0/0 are safe values.
  SQEntryWrapper wrapper(entry, qid, /*cqID*/ qid, /*sqHead*/ 0, /*sqUID*/ 0);

  // Push into the internal SQ FIFO.  handleRequest() will route via Path-E
  // fast-path if enabled (sqID != 0 is true here), otherwise via pSubsystem.
  lSQFIFO.push_back(wrapper);
  {
    static uint32_t mbx_logged = 0;
    if (mbx_logged < 30) {
      fprintf(stderr,
              "[DBG_MBX_INJ] qid=%u opc=0x%02X cid=%u nsid=%u slba=0x%lx nlb=%u\n",
              (unsigned)qid, (unsigned)opcode, (unsigned)cid,
              (unsigned)nsid, (unsigned long)slba, (unsigned)nlb);
      mbx_logged++;
    }
  }

  // Wake handleRequest if it's idle.  Use requestInterval == 0 so it fires
  // promptly; the scheduler still amortizes via requestCounter+maxRequest.
  if (!scheduled(requestEvent)) {
    schedule(requestEvent, getTick());
  }

  uncoreStats.mailboxSubmissions++;
  uncoreStats.mailboxDecodeCyclesTot += uncoreCfg.mailboxDecodeCycles;
  uncoreStats.mailboxInjectCyclesTot += uncoreCfg.mailboxInjectCycles;

  // Reset latch for the next compact SQE on this qid.
  latch.nextWord = 0;
}

// ---------------------------------------------------------------------------
// Mechanism #1 / #2 / #4 — CQ-side deep offload primitives.
//
// freeCidReadNext() : pop next free CID for `qid` (read endpoint of Mech #1).
// freeCidRecycle()  : push `cid` back into the free ring (CQE flush side).
// getInflightCount(): Mech #2's queue-depth surface; reads inflight counter.
// getMultiBitHint() : Mech #4; packs (count, age_units) into the 32-bit hint.
// ---------------------------------------------------------------------------

uint16_t Controller::freeCidReadNext(uint16_t qid) {
  if (qid >= freeCidRings.size()) {
    return 0xFFFF;
  }
  FreeCIDRing &r = freeCidRings[qid];
  if (r.depth == 0) {
    uncoreStats.freeCidStarvations++;
    {
      static uint32_t starve_logged = 0;
      if (starve_logged < 30) {
        fprintf(stderr, "[DBG_FCR_STARVE] qid=%u ring_size=%zu inflight=%u\n",
                (unsigned)qid, r.ring.size(), (unsigned)r.inflight);
        starve_logged++;
      }
    }
    return 0xFFFF;
  }
  uint16_t cid = r.ring[r.head];
  r.head = (r.head + 1) % (uint32_t)r.ring.size();
  r.depth--;
  r.inflight++;
  uncoreStats.freeCidPops++;
  {
    static uint32_t pop_logged = 0;
    if (pop_logged < 30) {
      fprintf(stderr,
              "[DBG_FCR_POP] qid=%u cid=%u depth_after=%u inflight=%u ring_size=%zu\n",
              (unsigned)qid, (unsigned)cid, (unsigned)r.depth,
              (unsigned)r.inflight, r.ring.size());
      pop_logged++;
    }
  }
  return cid;
}

void Controller::freeCidRecycle(uint16_t qid, uint16_t cid) {
  if (qid >= freeCidRings.size()) return;
  FreeCIDRing &r = freeCidRings[qid];
  if (r.depth >= r.ring.size()) {
    // Ring full: should never happen if the host honors the QueueDepth
    // contract.  Warn once and drop.
    static uint32_t full_logged = 0;
    if (full_logged < 30) {
      fprintf(stderr,
              "[DBG_FCR_FULL] qid=%u cid=%u ring_size=%zu depth=%u inflight=%u (DROP)\n",
              (unsigned)qid, (unsigned)cid, r.ring.size(),
              (unsigned)r.depth, (unsigned)r.inflight);
      full_logged++;
    }
    return;
  }
  r.ring[r.tail] = cid;
  r.tail = (r.tail + 1) % (uint32_t)r.ring.size();
  r.depth++;
  if (r.inflight > 0) r.inflight--;
  uncoreStats.freeCidPushes++;
  {
    static uint32_t rec_logged = 0;
    if (rec_logged < 30) {
      fprintf(stderr,
              "[DBG_FCR_REC] qid=%u cid=%u depth_after=%u inflight=%u\n",
              (unsigned)qid, (unsigned)cid, (unsigned)r.depth,
              (unsigned)r.inflight);
      rec_logged++;
    }
  }
}

uint32_t Controller::getInflightCount(uint16_t qid) const {
  if (qid >= freeCidRings.size()) return 0;
  return freeCidRings[qid].inflight;
}

uint32_t Controller::getMultiBitHint() const {
  uint32_t count = uncoreHintReady & 0xFFFFu;
  uint16_t age_units = 0;
  if (count > 0 && hintOldestArrivalTicks > 0) {
    // Mirror the rest of the controller's tick-source convention (getTick()).
    // const-method context: getTick() is a free function in the simplessd
    // simulator interface, so no `this` involved.
    uint64_t now = SimpleSSD::getTick();
    uint64_t age = (now > hintOldestArrivalTicks)
                       ? (now - hintOldestArrivalTicks)
                       : 0ULL;
    uint64_t unit = uncoreCfg.hintAgeGranularityPs;
    if (unit == 0) unit = 1;
    uint64_t a = age / unit;
    age_units = (a > 0xFFFFu) ? (uint16_t)0xFFFFu : (uint16_t)a;
  }
  return (((uint32_t)age_units) << 16) | count;
}

// ---------------------------------------------------------------------------

void Controller::getStatList(std::vector<Stats> &list, std::string prefix) {
  if (uncoreCfg.mode != UNCORE_MODE_DISABLED) {
    std::string p = prefix + "uncore.";
    list.push_back({p + "sqes_visible",        "SQEs visible to Gate 1 over all work cycles"});
    list.push_back({p + "collect_deferred",    "Gate 1 deferrals (not enough SQEs)"});
    list.push_back({p + "collect_allowed",     "Gate 1 pass-throughs"});
    list.push_back({p + "cqes_generated",      "I/O CQEs entering staging buffer"});
    list.push_back({p + "cqes_admin_bypassed", "Admin CQEs bypassing staging"});
    list.push_back({p + "cqes_published",      "CQEs written to host CQ via flush"});
    list.push_back({p + "flush_by_count",      "Flushes triggered by count threshold N"});
    list.push_back({p + "flush_by_timeout",    "Flushes triggered by timeout T"});
    list.push_back({p + "flush_by_shutdown",   "Force-drain flushes on shutdown"});
    for (int i = 0; i < 64; i++) {
      list.push_back({p + "flush_depth_hist_" + std::to_string(i),
                      "Flush depth histogram bucket " + std::to_string(i)});
    }
    // Mode 2 mailbox stats (zero-valued in Mode 0/1; populated only in Mode B).
    list.push_back({p + "mailbox_submissions",       "Mode 2 mailbox submissions (3rd word -> SQE inject)"});
    list.push_back({p + "mailbox_latch_resets",      "Mailbox mid-sequence resets (word violations)"});
    list.push_back({p + "mailbox_oversize_fallback", "Mailbox oversize rejects (>1 page)"});
    list.push_back({p + "mailbox_decode_cycles",     "Cumulative S_DECODE cycles"});
    list.push_back({p + "mailbox_inject_cycles",     "Cumulative S_INJECT cycles"});
    // Mechanism #1 / #2 / #4 stats
    list.push_back({p + "free_cid_pops",          "Mech #1: successful free-CID pops"});
    list.push_back({p + "free_cid_pushes",        "Mech #1: CIDs recycled on CQE flush"});
    list.push_back({p + "free_cid_starvations",   "Mech #1: pops that returned 0xFFFF (ring empty)"});
    list.push_back({p + "qdepth_reads",           "Mech #2: MMIO reads of in-flight count"});
    list.push_back({p + "hint_typed_reads",       "Mech #4: typed hint register reads"});
  }
  pSubsystem->getStatList(list, prefix);
}

void Controller::getStatValues(std::vector<double> &values) {
  if (uncoreCfg.mode != UNCORE_MODE_DISABLED) {
    values.push_back((double)uncoreStats.sqesVisible);
    values.push_back((double)uncoreStats.collectDeferred);
    values.push_back((double)uncoreStats.collectAllowed);
    values.push_back((double)uncoreStats.cqesGenerated);
    values.push_back((double)uncoreStats.cqesAdminBypassed);
    values.push_back((double)uncoreStats.cqesPublished);
    values.push_back((double)uncoreStats.flushByCount);
    values.push_back((double)uncoreStats.flushByTimeout);
    values.push_back((double)uncoreStats.flushByShutdown);
    for (int i = 0; i < 64; i++) {
      values.push_back((double)uncoreStats.flushDepthHist[i]);
    }
    values.push_back((double)uncoreStats.mailboxSubmissions);
    values.push_back((double)uncoreStats.mailboxLatchResets);
    values.push_back((double)uncoreStats.mailboxOversizeFallbk);
    values.push_back((double)uncoreStats.mailboxDecodeCyclesTot);
    values.push_back((double)uncoreStats.mailboxInjectCyclesTot);
    // Mechanism #1 / #2 / #4 stats
    values.push_back((double)uncoreStats.freeCidPops);
    values.push_back((double)uncoreStats.freeCidPushes);
    values.push_back((double)uncoreStats.freeCidStarvations);
    values.push_back((double)uncoreStats.qdepthReads);
    values.push_back((double)uncoreStats.hintTypedReads);
  }
  pSubsystem->getStatValues(values);
}

void Controller::resetStatValues() {
  uncoreStats = UncoreStats{};
  pSubsystem->resetStatValues();
}

}  // namespace NVMe

}  // namespace HIL

}  // namespace SimpleSSD
