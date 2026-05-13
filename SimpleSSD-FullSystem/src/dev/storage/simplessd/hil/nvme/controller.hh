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

#pragma once

#ifndef __HIL_NVME_CONTROLLER__
#define __HIL_NVME_CONTROLLER__

#include <list>
#include <vector>
#include <unordered_map>

#include "hil/nvme/abstract_subsystem.hh"
#include "hil/nvme/def.hh"
#include "hil/nvme/dma.hh"
#include "hil/nvme/queue.hh"
#include "util/bitset.hh"
#include "util/def.hh"
#include "util/simplessd.hh"

namespace SimpleSSD {

namespace HIL {

namespace NVMe {

class Interface;

// ---------------------------------------------------------------------------
// I/O Uncore simulation types  (used by Controller private state below)
// ---------------------------------------------------------------------------

typedef enum {
  UNCORE_MODE_DISABLED = 0,  //!< No batching; baseline behaviour
  UNCORE_MODE_A        = 1,  //!< Transparent CQE batching + SQ threshold guard
  UNCORE_MODE_B        = 2,  //!< Mode A + SPDK cooperative hint register
} UncoreMode;

struct UncoreConfig {
  UncoreMode mode     = UNCORE_MODE_DISABLED;
  uint32_t   cqBatchN = 8;        //!< Flush staging buffer when N CQEs pending
  uint64_t   cqBatchT = 4000000;  //!< Flush timeout in picoseconds
  uint32_t   dbBatchB = 4;        //!< Min SQEs visible before SQ collection
  // --- Mode 2 deep-offload Mailbox SQ Engine ---
  uint32_t   mailboxBase         = 0x3000;
  uint32_t   mailboxStride       = 0x20;
  uint16_t   mailboxLatchCycles  = 1;
  uint16_t   mailboxDecodeCycles = 8;
  uint16_t   mailboxInjectCycles = 4;
  // --- Mechanism #1 + #2 + #4 (CQ-side deep offload) ---
  uint32_t   freeCidBase           = 0x3400;
  uint16_t   freeCidLatencyCycles  = 2;
  uint64_t   hintAgeGranularityPs  = 1024000ULL;
};

//! Per-qid free Command-ID ring (Mechanism #1).  Hardware maintains the
//! authoritative free-CID pool; the host pops one per submission via an
//! MMIO read.  Hardware automatically recycles the CID into the ring on
//! CQE flush.  `inflight` is the live in-flight count exposed via
//! Mechanism #2's queue-depth read endpoint.
struct FreeCIDRing {
  std::vector<uint16_t> ring;
  uint32_t head     = 0;
  uint32_t tail     = 0;
  uint32_t depth    = 0;  // current FIFO occupancy (number of free CIDs)
  uint32_t inflight = 0;  // CIDs currently issued to host, not yet recycled
};

//! Per-qid mailbox 3-word latch (compact-SQE assembly buffer).
//!   words[0..2]: the three 8-byte writes received in order
//!   nextWord   : 0/1/2 = which word the next incoming write fills; 3 = ready
//!   lastTick   : tick of the last accepted write (telemetry / stall detect)
struct MailboxLatch {
  uint64_t words[3] = {0, 0, 0};
  uint8_t  nextWord = 0;
  uint64_t lastTick = 0;
};

//! One entry in the CQE staging buffer (before published to host CQ memory).
//! CQEntryWrapper has no default constructor so we provide one explicitly.
struct UncoreCQPendingEntry {
  CQEntryWrapper wrapper;    //!< Complete CQE and all wrapper metadata
  uint64_t       arrivedAt;  //!< getTick() when submit() was called
  UncoreCQPendingEntry(const CQEntryWrapper &w, uint64_t t)
      : wrapper(w), arrivedAt(t) {}
};

//! All counters and histograms accumulated during a simulation run.
struct UncoreStats {
  uint64_t sqesVisible       = 0;  //!< Cumulative SQE count seen by Gate 1
  uint64_t collectDeferred   = 0;  //!< Gate 1 deferrals (threshold not met)
  uint64_t collectAllowed    = 0;  //!< Gate 1 pass-throughs (threshold met)
  uint64_t cqesGenerated     = 0;  //!< I/O CQEs entering staging buffer
  uint64_t cqesAdminBypassed = 0;  //!< Admin CQEs bypassing staging (immediate)
  uint64_t cqesPublished     = 0;  //!< CQEs flushed from staging to lCQFIFO
  uint64_t flushByCount      = 0;  //!< Flushes triggered by count threshold N
  uint64_t flushByTimeout    = 0;  //!< Flushes triggered by timeout T
  uint64_t flushByShutdown   = 0;  //!< Force-drain flushes on shutdown
  uint64_t flushDepthHist[64] = {}; //!< Histogram: CQEs per flush (bucket=depth)
  // --- Mode 2 Mailbox SQ-Engine stats ---
  uint64_t mailboxSubmissions     = 0;  //!< 3rd word received -> SQE injected
  uint64_t mailboxLatchResets     = 0;  //!< Mid-sequence word violations
  uint64_t mailboxOversizeFallbk  = 0;  //!< nlb > 1 page (rejected; SPDK falls back)
  uint64_t mailboxDecodeCyclesTot = 0;  //!< Cumulative S_DECODE cycles
  uint64_t mailboxInjectCyclesTot = 0;  //!< Cumulative S_INJECT cycles
  // --- Mechanism #1 / #2 / #4 stats ---
  uint64_t freeCidPops        = 0;  //!< Mech #1: successful free-CID pops
  uint64_t freeCidPushes      = 0;  //!< Mech #1: CIDs recycled on CQE flush
  uint64_t freeCidStarvations = 0;  //!< Mech #1: pop returned 0xFFFF (ring empty)
  uint64_t qdepthReads        = 0;  //!< Mech #2: MMIO reads of in-flight count
  uint64_t hintTypedReads     = 0;  //!< Mech #4: reads of typed hint register
};

// ---------------------------------------------------------------------------

typedef union _RegisterTable {
  uint8_t data[64];
  struct {
    uint64_t capabilities;
    uint32_t version;
    uint32_t interruptMaskSet;
    uint32_t interruptMaskClear;
    uint32_t configuration;
    uint32_t reserved;
    uint32_t status;
    uint32_t subsystemReset;
    uint32_t adminQueueAttributes;
    uint64_t adminSQueueBaseAddress;
    uint64_t adminCQueueBaseAddress;
    uint32_t memoryBufferLocation;
    uint32_t memoryBufferSize;
  };

  _RegisterTable();
} RegisterTable;

typedef struct {
  uint64_t nextTime;
  uint32_t requestCount;
  bool valid;
  bool pending;
} AggregationInfo;

class Controller : public StatObject {
 private:
  Interface *pParent;             //!< NVMe::Interface passed from constructor
  AbstractSubsystem *pSubsystem;  //!< NVMe::Subsystem allocate in constructor

  bool bUseOCSSD;

  SimpleSSD::DMAInterface *pcieFIFO;
  SimpleSSD::DMAInterface *interconnect;

  RegisterTable registers;   //!< Table for NVMe Controller Registers
  uint64_t sqstride;         //!< Calculated SQ Stride
  uint64_t cqstride;         //!< Calculated CQ stride
  uint8_t adminQueueInited;  //!< Flag for initialization of Admin CQ/SQ
  uint16_t arbitration;      //!< Selected Arbitration Mechanism
  uint32_t interruptMask;    //!< Variable to store current interrupt mask

  uint32_t cqsize;
  uint32_t sqsize;
  CQueue **ppCQueue;  //!< Completion Queue array
  SQueue **ppSQueue;  //!< Submission Queue array

  std::list<SQEntryWrapper> lSQFIFO;  //!< Internal FIFO queue for submission
  std::list<CQEntryWrapper> lCQFIFO;  //!< Internal FIFO queue for completion

  bool shutdownReserved;

  uint64_t aggregationTime;
  uint32_t aggregationThreshold;
  std::unordered_map<uint16_t, AggregationInfo> aggregationMap;

  ConfigData cfgdata;
  ConfigReader &conf;

  Event workEvent;
  Event requestEvent;
  Event completionEvent;
  uint32_t requestCounter;
  uint32_t maxRequest;
  uint64_t requestInterval;
  uint64_t workInterval;
  uint64_t lastWorkAt;

  // --- I/O Uncore state ---
  UncoreConfig  uncoreCfg;    //!< Knobs read from fast_ssd.cfg at construction
  UncoreStats   uncoreStats;  //!< Accumulated counters (exported via getStatValues)

  //! Staging buffer: I/O CQEs held here until count- or time-threshold fires.
  //! Empty when uncoreCfg.mode == UNCORE_MODE_DISABLED.
  std::vector<UncoreCQPendingEntry> uncorePendingCQE;

  //! Per-SQueue SQE visibility snapshot for Gate 1 logging.
  //! Sized to sqsize in the constructor.
  std::vector<uint32_t> uncoreDbAccumPerQ;

  //! Mode B hint value: reflects lCQFIFO.size() after each flush.
  //! Exposed as a 4-byte read-only register at BAR0+UNCORE_HINT_REG_OFFSET.
  uint32_t uncoreHintReady;

  //! Guard to prevent double-scheduling of uncoreFlushEvent.
  bool uncoreFlushScheduled;

  //! Timeout-driven CQE flush event (fires cqBatchT ps after first staging CQE).
  Event uncoreFlushEvent;

  // --- Mode 2 deep-offload Mailbox SQ Engine state ---
  //! Per-qid latch (sized to cqsize in ctor; admin qid=0 also allocated but
  //! unused by the Mode B SPDK path).
  std::vector<MailboxLatch> mailboxLatches;
  //! Scheduled event that fires (decode+inject)*1ns after the 3rd word lands.
  //! On fire it scans the latches and injects any qid whose nextWord==3.
  Event mailboxInjectEvent;

  // --- Mechanism #1 + #2 + #4 state ---
  //! Per-qid free-CID ring; sized to cqsize in ctor.
  std::vector<FreeCIDRing> freeCidRings;
  //! Mechanism #4: getTick() when the oldest currently-pending CQE arrived
  //! in the staging buffer.  Used to compute the age field of the typed hint.
  uint64_t hintOldestArrivalTicks = 0;

  // --- Fast-path statistical timing model (NVMeVirt-style) ---
  // When enabled, bypasses the HIL/ICL/FTL/PAL pipeline. Each I/O is
  // mapped to a NAND channel, assigned target_completion_time from a
  // per-channel statistical timer, and routed through Controller::submit()
  // at that time. submit() preserves all I/O-Uncore mechanisms, so
  // Mode 0/1/2B continue to differentiate at the host PCIe boundary.
  struct FastPathConfig {
    bool     enabled        = false;
    uint64_t lminPs         = 3000000;    // 3 us
    uint64_t tmaxPerCh      = 1000000;    // 1 M IOPS / channel
    uint64_t spacingPs      = 1000;       // 1e12 / tmaxPerCh, computed in ctor
    uint16_t channels       = 32;         // sourced from [pal] Channel
    uint32_t channelPolicy  = 1;          // 0 = round-robin, 1 = LBA-hash
    uint64_t maxOutstanding = 8192;
  } fastPathCfg;

  std::vector<uint64_t>      fastPathChannelNextFree;
  uint16_t                   fastPathRRCounter;

  struct FastPathPending {
    CQEntryWrapper entry;
    uint64_t       target_time;
    FastPathPending(CQEntryWrapper &e, uint64_t t) : entry(e), target_time(t) {}
  };
  std::list<FastPathPending> fastPathQueue;

  Event                      fastPathFireEvent;
  bool                       fastPathFireScheduled;

  uint64_t fastPathStats_dispatched   = 0;
  uint64_t fastPathStats_completed    = 0;
  uint64_t fastPathStats_dropped_full = 0;

  void fastPathEnqueue(SQEntryWrapper &req);
  void fastPathFire();
  void fastPathRescheduleNext();

  // --- Mode 2 Mailbox SQ Engine handlers ---
  //! S_LATCH_0/1/2 plus arming of mailboxInjectEvent when nextWord reaches 3.
  void handleMailboxWrite(uint16_t qid, uint8_t wordIdx,
                          uint64_t value, uint64_t tick);
  //! S_DECODE + S_INJECT: synthesize SQEntryWrapper, push into lSQFIFO,
  //! schedule requestEvent so handleRequest picks it up via the Path-E
  //! fast-path (or pSubsystem if fast-path is disabled).
  void mailboxInject(uint16_t qid, uint64_t tick);

  // --- Mechanism #1 / #2 / #4 ---
  //! Pop the next free CID for `qid`; returns 0xFFFF if the ring is empty.
  //! Side-effect: decrements depth, increments inflight, bumps freeCidPops.
  uint16_t freeCidReadNext(uint16_t qid);
  //! Push `cid` back into the ring for `qid` (CQE flush side).
  void freeCidRecycle(uint16_t qid, uint16_t cid);
  //! Return the current in-flight count (Mechanism #2's qdepth surface).
  uint32_t getInflightCount(uint16_t qid) const;
  //! Compute the typed hint register value (count:16, age_units:16).
  uint32_t getMultiBitHint() const;

  bool checkQueue(SQueue *, DMAFunction &, void *);

 public:
  Controller(Interface *, ConfigReader &);
  ~Controller();

  void readRegister(uint64_t, uint64_t, uint8_t *, uint64_t &);
  void writeRegister(uint64_t, uint64_t, uint8_t *, uint64_t &);
  void ringCQHeadDoorbell(uint16_t, uint16_t, uint64_t &);
  void ringSQTailDoorbell(uint16_t, uint16_t, uint64_t &);

  void clearInterrupt(uint16_t);
  void updateInterrupt(uint16_t, bool);

  int createCQueue(uint16_t, uint16_t, uint16_t, bool, bool, uint64_t,
                   DMAFunction &, void *);
  int createSQueue(uint16_t, uint16_t, uint16_t, uint8_t, bool, uint64_t,
                   DMAFunction &, void *);
  int deleteCQueue(uint16_t);
  int deleteSQueue(uint16_t);
  int abort(uint16_t, uint16_t);
  void identify(uint8_t *);
  void setCoalescingParameter(uint8_t, uint8_t);
  void getCoalescingParameter(uint8_t *, uint8_t *);
  void setCoalescing(uint16_t, bool);
  bool getCoalescing(uint16_t);

  void collectSQueue(DMAFunction &, void *);
  void handleRequest(uint64_t);
  void work();

  void submit(CQEntryWrapper &);
  void reserveCompletion();
  void completion();

  // --- I/O Uncore public interface ---
  //! Drain all staged CQEs to lCQFIFO and call reserveCompletion().
  //! isShutdown=true records the flush as a shutdown drain in statistics.
  void uncoreFlushCQBuffer(bool isShutdown = false);
  //! Return the Mode B readiness hint value (mirrors lCQFIFO.size()).
  uint32_t getUncoreHintReady() const { return uncoreHintReady; }

  void getStatList(std::vector<Stats> &, std::string) override;
  void getStatValues(std::vector<double> &) override;
  void resetStatValues() override;
};

}  // namespace NVMe

}  // namespace HIL

}  // namespace SimpleSSD

#endif
