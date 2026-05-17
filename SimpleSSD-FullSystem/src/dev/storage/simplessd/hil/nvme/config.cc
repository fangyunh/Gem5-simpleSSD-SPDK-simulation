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

#include "hil/nvme/config.hh"

#include "util/algorithm.hh"
#include "util/simplessd.hh"

namespace SimpleSSD {

namespace HIL {

namespace NVMe {

const char NAME_PCIE_GEN[] = "PCIEGeneration";
const char NAME_PCIE_LANE[] = "PCIELane";
const char NAME_AXI_BUS_WIDTH[] = "AXIBusWidth";
const char NAME_AXI_CLOCK[] = "AXIClock";
const char NAME_FIFO_UNIT[] = "FIFOTransferUnit";
const char NAME_WORK_INTERVAL[] = "WorkInterval";
const char NAME_MAX_REQUEST_COUNT[] = "MaxRequestCount";
const char NAME_MAX_IO_CQUEUE[] = "MaxIOCQueue";
const char NAME_MAX_IO_SQUEUE[] = "MaxIOSQueue";
const char NAME_WRR_HIGH[] = "WRRHigh";
const char NAME_WRR_MEDIUM[] = "WRRMedium";
const char NAME_ENABLE_DEFAULT_NAMESPACE[] = "DefaultNamespace";
const char NAME_LBA_SIZE[] = "LBASize";
const char NAME_ENABLE_DISK_IMAGE[] = "EnableDiskImage";
const char NAME_STRICT_DISK_SIZE[] = "StrictSizeCheck";
const char NAME_DISK_IMAGE_PATH[] = "DiskImageFile";
const char NAME_USE_COW_DISK[] = "UseCopyOnWriteDisk";
// I/O Uncore config key names
const char NAME_UNCORE_MODE[]       = "UncoreMode";
const char NAME_UNCORE_CQ_BATCH_N[] = "CQBatchN";
const char NAME_UNCORE_CQ_BATCH_T[] = "CQBatchT";
const char NAME_UNCORE_DB_BATCH_B[] = "DBBatchB";
// Mode 2 deep-offload Mailbox SQ Engine
const char NAME_MAILBOX_BASE[]          = "MailboxBase";
const char NAME_MAILBOX_STRIDE[]        = "MailboxStride";
const char NAME_MAILBOX_LATCH_CYCLES[]  = "MailboxLatchCycles";
const char NAME_MAILBOX_DECODE_CYCLES[] = "MailboxDecodeCycles";
const char NAME_MAILBOX_INJECT_CYCLES[] = "MailboxInjectCycles";
// Mechanism #1/#2/#4 (CQ-side deep offload)
const char NAME_FREE_CID_BASE[]            = "FreeCIDBase";
const char NAME_FREE_CID_LATENCY_CYCLES[]  = "FreeCIDLatencyCycles";
const char NAME_HINT_AGE_GRANULARITY_PS[]  = "HintAgeGranularityPs";

const char NAME_FASTPATH_ENABLED[]        = "FastPathEnabled";
const char NAME_FASTPATH_LMIN[]           = "FastPathLmin";
const char NAME_FASTPATH_TMAX_PER_CH[]    = "FastPathTmaxPerChannel";
const char NAME_FASTPATH_CHANNEL_POLICY[] = "FastPathChannelPolicy";
const char NAME_FASTPATH_MAX_OUTSTANDING[]= "FastPathMaxOutstanding";

Config::Config() {
  pcieGen = PCIExpress::PCIE_3_X;
  pcieLane = 4;
  axiWidth = ARM::AXI::BUS_128BIT;
  axiClock = 250000000;
  fifoUnit = 4096;
  workInterval = 50000;
  maxRequestCount = 4;
  maxIOCQueue = 16;
  maxIOSQueue = 16;
  wrrHigh = 2;
  wrrMedium = 2;
  lbaSize = 512;
  defaultNamespace = 1;
  enableDiskImage = false;
  strictDiskSize = false;
  useCopyOnWriteDisk = false;
  // I/O Uncore defaults
  uncoreMode     = 0;
  uncoreCQBatchN = 8;
  uncoreCQBatchT = 4000000;  // 4 µs in picoseconds
  uncoreDBBatchB = 4;
  // Mode 2 Mailbox SQ Engine defaults
  // (matches RTL spec §4 SQ-Engine FSM @ 1 GHz: 3 latch + 8 decode + 4 inject)
  mailboxBase          = 0x3000;
  mailboxStride        = 0x20;
  mailboxLatchCycles   = 1;
  mailboxDecodeCycles  = 8;
  mailboxInjectCycles  = 4;
  // Mechanism #1/#2/#4 defaults
  // freeCidBase moved 0x3400 -> 0x4000 (2026-05-14) so the mailbox region
  // (MailboxBase + cqsize*MailboxStride; up to 0x3820 at MaxIOCQueue=64)
  // does not collide.  Must match spdk/lib/nvme/nvme_pcie_internal.h
  // FREE_CID_BASE_OFFSET and QDEPTH_BASE_OFFSET (= freeCidBase + 0x400).
  freeCidBase           = 0x4000;
  freeCidLatencyCycles  = 2;
  hintAgeGranularityPs  = 1024000ULL;  // 1 µs per age unit

  // Fast-path defaults (disabled unless cfg sets FastPathEnabled = 1)
  fastPathEnabled        = false;
  fastPathLmin           = 3000000;  // 3 µs in ps
  fastPathTmaxPerCh      = 1000000;  // 1 M IOPS / channel
  fastPathChannelPolicy  = 1;        // LBA-hash
  fastPathMaxOutstanding = 8192;
}

bool Config::setConfig(const char *name, const char *value) {
  bool ret = true;

  if (MATCH_NAME(NAME_PCIE_GEN)) {
    switch (strtoul(value, nullptr, 10)) {
      case 0:
        pcieGen = PCIExpress::PCIE_1_X;
        break;
      case 1:
        pcieGen = PCIExpress::PCIE_2_X;
        break;
      case 2:
        pcieGen = PCIExpress::PCIE_3_X;
        break;
      case 3:
        pcieGen = PCIExpress::PCIE_4_X;
        break;
      case 4:
        pcieGen = PCIExpress::PCIE_5_X;
        break;
      default:
        panic("Invalid PCI Express Generation");
        break;
    }
  }
  else if (MATCH_NAME(NAME_PCIE_LANE)) {
    pcieLane = (uint8_t)strtoul(value, nullptr, 10);
  }
  else if (MATCH_NAME(NAME_AXI_BUS_WIDTH)) {
    switch (strtoul(value, nullptr, 10)) {
      case 0:
        axiWidth = ARM::AXI::BUS_32BIT;
        break;
      case 1:
        axiWidth = ARM::AXI::BUS_64BIT;
        break;
      case 2:
        axiWidth = ARM::AXI::BUS_128BIT;
        break;
      case 3:
        axiWidth = ARM::AXI::BUS_256BIT;
        break;
      case 4:
        axiWidth = ARM::AXI::BUS_512BIT;
        break;
      case 5:
        axiWidth = ARM::AXI::BUS_1024BIT;
        break;
      default:
        panic("Invalid AXI Stream Bus Width");
        break;
    }
  }
  else if (MATCH_NAME(NAME_AXI_CLOCK)) {
    axiClock = strtoul(value, nullptr, 10);
  }
  else if (MATCH_NAME(NAME_FIFO_UNIT)) {
    fifoUnit = strtoul(value, nullptr, 10);
  }
  else if (MATCH_NAME(NAME_WORK_INTERVAL)) {
    workInterval = strtoul(value, nullptr, 10);
  }
  else if (MATCH_NAME(NAME_MAX_REQUEST_COUNT)) {
    maxRequestCount = strtoul(value, nullptr, 10);
  }
  else if (MATCH_NAME(NAME_MAX_IO_CQUEUE)) {
    maxIOCQueue = (uint16_t)strtoul(value, nullptr, 10);
  }
  else if (MATCH_NAME(NAME_MAX_IO_SQUEUE)) {
    maxIOSQueue = (uint16_t)strtoul(value, nullptr, 10);
  }
  else if (MATCH_NAME(NAME_WRR_HIGH)) {
    wrrHigh = (uint16_t)strtoul(value, nullptr, 10);
  }
  else if (MATCH_NAME(NAME_WRR_MEDIUM)) {
    wrrMedium = (uint16_t)strtoul(value, nullptr, 10);
  }
  else if (MATCH_NAME(NAME_ENABLE_DEFAULT_NAMESPACE)) {
    defaultNamespace = (uint16_t)strtoul(value, nullptr, 10);
  }
  else if (MATCH_NAME(NAME_LBA_SIZE)) {
    lbaSize = strtoul(value, nullptr, 10);
  }
  else if (MATCH_NAME(NAME_ENABLE_DISK_IMAGE)) {
    enableDiskImage = convertBool(value);
  }
  else if (MATCH_NAME(NAME_STRICT_DISK_SIZE)) {
    strictDiskSize = convertBool(value);
  }
  else if (strncmp(name, NAME_DISK_IMAGE_PATH, strlen(NAME_DISK_IMAGE_PATH)) ==
           0) {
    uint16_t index =
        (uint16_t)strtoul(name + strlen(NAME_DISK_IMAGE_PATH), nullptr, 10);

    if (index > 0) {
      auto find = diskImagePaths.find(index);

      if (find == diskImagePaths.end()) {
        diskImagePaths.insert({index, value});
      }
      else {
        find->second = value;
      }
    }
  }
  else if (MATCH_NAME(NAME_USE_COW_DISK)) {
    useCopyOnWriteDisk = convertBool(value);
  }
  else if (MATCH_NAME(NAME_UNCORE_MODE)) {
    uncoreMode = (uint32_t)strtoul(value, nullptr, 10);
    if (uncoreMode > 2) {
      panic("UncoreMode must be 0 (disabled), 1 (Mode A), or 2 (Mode B)");
    }
  }
  else if (MATCH_NAME(NAME_UNCORE_CQ_BATCH_N)) {
    uncoreCQBatchN = (uint32_t)strtoul(value, nullptr, 10);
    if (uncoreCQBatchN == 0) {
      panic("CQBatchN must be >= 1");
    }
  }
  else if (MATCH_NAME(NAME_UNCORE_CQ_BATCH_T)) {
    uncoreCQBatchT = strtoull(value, nullptr, 10);
  }
  else if (MATCH_NAME(NAME_UNCORE_DB_BATCH_B)) {
    uncoreDBBatchB = (uint32_t)strtoul(value, nullptr, 10);
    if (uncoreDBBatchB == 0) {
      panic("DBBatchB must be >= 1");
    }
  }
  else if (MATCH_NAME(NAME_MAILBOX_BASE)) {
    uint32_t v = (uint32_t)strtoul(value, nullptr, 0);
    if (v < 0x2004 || v > 0xF000 || (v & 0x1F) != 0) {
      panic("MailboxBase must be 0x2004..0xF000 and 32-byte aligned");
    }
    mailboxBase = v;
  }
  else if (MATCH_NAME(NAME_MAILBOX_STRIDE)) {
    uint32_t v = (uint32_t)strtoul(value, nullptr, 0);
    if (v < 0x20 || (v & 0x1F) != 0) {
      panic("MailboxStride must be >= 0x20 and 32-byte aligned");
    }
    mailboxStride = v;
  }
  else if (MATCH_NAME(NAME_MAILBOX_LATCH_CYCLES)) {
    mailboxLatchCycles = (uint16_t)strtoul(value, nullptr, 0);
  }
  else if (MATCH_NAME(NAME_MAILBOX_DECODE_CYCLES)) {
    mailboxDecodeCycles = (uint16_t)strtoul(value, nullptr, 0);
  }
  else if (MATCH_NAME(NAME_MAILBOX_INJECT_CYCLES)) {
    mailboxInjectCycles = (uint16_t)strtoul(value, nullptr, 0);
  }
  else if (MATCH_NAME(NAME_FREE_CID_BASE)) {
    uint32_t v = (uint32_t)strtoul(value, nullptr, 0);
    if (v < 0x2004 || v > 0xF000 || (v & 0x3) != 0) {
      panic("FreeCIDBase must be 0x2004..0xF000 and 4-byte aligned");
    }
    freeCidBase = v;
  }
  else if (MATCH_NAME(NAME_FREE_CID_LATENCY_CYCLES)) {
    freeCidLatencyCycles = (uint16_t)strtoul(value, nullptr, 0);
  }
  else if (MATCH_NAME(NAME_HINT_AGE_GRANULARITY_PS)) {
    hintAgeGranularityPs = strtoull(value, nullptr, 0);
    if (hintAgeGranularityPs == 0) {
      panic("HintAgeGranularityPs must be > 0");
    }
  }
  else if (MATCH_NAME(NAME_FASTPATH_ENABLED)) {
    fastPathEnabled = (strtoul(value, nullptr, 10) != 0);
  }
  else if (MATCH_NAME(NAME_FASTPATH_LMIN)) {
    fastPathLmin = strtoull(value, nullptr, 10);
    if (fastPathLmin == 0) {
      panic("FastPathLmin must be > 0 picoseconds");
    }
  }
  else if (MATCH_NAME(NAME_FASTPATH_TMAX_PER_CH)) {
    fastPathTmaxPerCh = strtoull(value, nullptr, 10);
    if (fastPathTmaxPerCh == 0) {
      panic("FastPathTmaxPerChannel must be > 0");
    }
  }
  else if (MATCH_NAME(NAME_FASTPATH_CHANNEL_POLICY)) {
    fastPathChannelPolicy = (uint32_t)strtoul(value, nullptr, 10);
    if (fastPathChannelPolicy > 1) {
      panic("FastPathChannelPolicy must be 0 (RR) or 1 (LBA-hash)");
    }
  }
  else if (MATCH_NAME(NAME_FASTPATH_MAX_OUTSTANDING)) {
    fastPathMaxOutstanding = strtoull(value, nullptr, 10);
  }
  else {
    ret = false;
  }

  return ret;
}

void Config::update() {
  if (popcount(lbaSize) != 1 || lbaSize < 512) {
    panic("Invalid LBA size");
  }
  if (maxRequestCount == 0) {
    panic("MaxRequestCount should be larger then 0");
  }
  if (fifoUnit > 4096) {
    panic("FIFOTransferUnit should be less than or equal to 4096");
  }
}

int64_t Config::readInt(uint32_t idx) {
  int64_t ret = 0;

  switch (idx) {
    case NVME_PCIE_GEN:
      ret = pcieGen;
      break;
    case NVME_AXI_BUS_WIDTH:
      ret = axiWidth;
      break;
  }

  return ret;
}

uint64_t Config::readUint(uint32_t idx) {
  uint64_t ret = 0;

  switch (idx) {
    case NVME_PCIE_LANE:
      ret = pcieLane;
      break;
    case NVME_AXI_CLOCK:
      ret = axiClock;
      break;
    case NVME_FIFO_UNIT:
      ret = fifoUnit;
      break;
    case NVME_WORK_INTERVAL:
      ret = workInterval;
      break;
    case NVME_MAX_REQUEST_COUNT:
      ret = maxRequestCount;
      break;
    case NVME_MAX_IO_CQUEUE:
      ret = maxIOCQueue;
      break;
    case NVME_MAX_IO_SQUEUE:
      ret = maxIOSQueue;
      break;
    case NVME_WRR_HIGH:
      ret = wrrHigh;
      break;
    case NVME_WRR_MEDIUM:
      ret = wrrMedium;
      break;
    case NVME_ENABLE_DEFAULT_NAMESPACE:
      ret = defaultNamespace;
      break;
    case NVME_LBA_SIZE:
      ret = lbaSize;
      break;
    case NVME_UNCORE_MODE:
      ret = uncoreMode;
      break;
    case NVME_UNCORE_CQ_BATCH_N:
      ret = uncoreCQBatchN;
      break;
    case NVME_UNCORE_CQ_BATCH_T:
      ret = uncoreCQBatchT;
      break;
    case NVME_UNCORE_DB_BATCH_B:
      ret = uncoreDBBatchB;
      break;
    case NVME_MAILBOX_BASE:
      ret = mailboxBase;
      break;
    case NVME_MAILBOX_STRIDE:
      ret = mailboxStride;
      break;
    case NVME_MAILBOX_LATCH_CYCLES:
      ret = mailboxLatchCycles;
      break;
    case NVME_MAILBOX_DECODE_CYCLES:
      ret = mailboxDecodeCycles;
      break;
    case NVME_MAILBOX_INJECT_CYCLES:
      ret = mailboxInjectCycles;
      break;
    case NVME_FREE_CID_BASE:
      ret = freeCidBase;
      break;
    case NVME_FREE_CID_LATENCY_CYCLES:
      ret = freeCidLatencyCycles;
      break;
    case NVME_HINT_AGE_GRANULARITY_PS:
      ret = hintAgeGranularityPs;
      break;
    case NVME_FASTPATH_LMIN:
      ret = fastPathLmin;
      break;
    case NVME_FASTPATH_TMAX_PER_CH:
      ret = fastPathTmaxPerCh;
      break;
    case NVME_FASTPATH_CHANNEL_POLICY:
      ret = fastPathChannelPolicy;
      break;
    case NVME_FASTPATH_MAX_OUTSTANDING:
      ret = fastPathMaxOutstanding;
      break;
  }

  return ret;
}

std::string Config::readString(uint32_t idx) {
  std::string ret("");

  if (idx >= NVME_DISK_IMAGE_PATH) {
    idx -= NVME_DISK_IMAGE_PATH;

    auto find = diskImagePaths.find((uint16_t)idx);

    if (find != diskImagePaths.end()) {
      ret = find->second;
    }
  }

  return ret;
}

bool Config::readBoolean(uint32_t idx) {
  bool ret = false;

  switch (idx) {
    case NVME_ENABLE_DISK_IMAGE:
      ret = enableDiskImage;
      break;
    case NVME_STRICT_DISK_SIZE:
      ret = strictDiskSize;
      break;
    case NVME_USE_COW_DISK:
      ret = useCopyOnWriteDisk;
      break;
    case NVME_FASTPATH_ENABLED:
      ret = fastPathEnabled;
      break;
  }

  return ret;
}

}  // namespace NVMe

}  // namespace HIL

}  // namespace SimpleSSD
