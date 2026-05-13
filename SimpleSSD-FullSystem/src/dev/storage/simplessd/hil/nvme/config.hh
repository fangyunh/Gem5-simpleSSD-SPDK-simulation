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

#ifndef __HIL_NVME_CONFIG__
#define __HIL_NVME_CONFIG__

#include <unordered_map>

#include "sim/base_config.hh"
#include "util/interface.hh"

namespace SimpleSSD {

namespace HIL {

namespace NVMe {

typedef enum {
  NVME_PCIE_GEN,
  NVME_PCIE_LANE,
  NVME_AXI_BUS_WIDTH,
  NVME_AXI_CLOCK,
  NVME_FIFO_UNIT,
  NVME_WORK_INTERVAL,
  NVME_MAX_REQUEST_COUNT,
  NVME_MAX_IO_CQUEUE,
  NVME_MAX_IO_SQUEUE,
  NVME_WRR_HIGH,
  NVME_WRR_MEDIUM,
  NVME_ENABLE_DEFAULT_NAMESPACE,
  NVME_LBA_SIZE,
  NVME_ENABLE_DISK_IMAGE,
  NVME_STRICT_DISK_SIZE,
  NVME_DISK_IMAGE_PATH,
  NVME_USE_COW_DISK,
  // --- I/O Uncore knobs ---
  NVME_UNCORE_MODE,        //!< UncoreMode: 0=disabled, 1=Mode A, 2=Mode B
  NVME_UNCORE_CQ_BATCH_N,  //!< CQBatchN: flush staging buffer after N CQEs
  NVME_UNCORE_CQ_BATCH_T,  //!< CQBatchT: flush timeout in picoseconds
  NVME_UNCORE_DB_BATCH_B,  //!< DBBatchB: min SQEs visible before SQ collection
  // --- Mode 2 deep-offload (Mailbox SQ Engine) knobs ---
  NVME_MAILBOX_BASE,           //!< MailboxBase: BAR0 offset of mailbox region
  NVME_MAILBOX_STRIDE,         //!< MailboxStride: bytes between per-qid slots
  NVME_MAILBOX_LATCH_CYCLES,   //!< MailboxLatchCycles: cycles per S_LATCH_i
  NVME_MAILBOX_DECODE_CYCLES,  //!< MailboxDecodeCycles: S_DECODE (PRP+opcode)
  NVME_MAILBOX_INJECT_CYCLES,  //!< MailboxInjectCycles: S_INJECT (SRAM write)
  // --- Mechanism #1 / #2 / #4 (CQ-side deep offload) knobs ---
  NVME_FREE_CID_BASE,            //!< FreeCIDBase: BAR0 offset of free-CID ring
  NVME_FREE_CID_LATENCY_CYCLES,  //!< FreeCIDLatencyCycles: cycles per free-CID pop
  NVME_HINT_AGE_GRANULARITY_PS,  //!< HintAgeGranularityPs: ps per typed-hint age unit
  // --- Fast-path statistical timing model knobs (NVMeVirt-style) ---
  NVME_FASTPATH_ENABLED,       //!< 0=disabled (use SimpleSSD pipeline), 1=enabled
  NVME_FASTPATH_LMIN,          //!< Minimum per-IO service time (picoseconds)
  NVME_FASTPATH_TMAX_PER_CH,   //!< Per-channel max IOPS
  NVME_FASTPATH_CHANNEL_POLICY,//!< 0=round-robin, 1=LBA-hash
  NVME_FASTPATH_MAX_OUTSTANDING//!< Cap on in-flight; 0 = uncapped
} NVME_CONFIG;

class Config : public BaseConfig {
 private:
  PCIExpress::PCIE_GEN pcieGen;  //!< Default: PCIE_3_X
  uint8_t pcieLane;              //!< Default: 4
  ARM::AXI::BUS_WIDTH axiWidth;  //!< Default: BUS_128BIT
  uint64_t axiClock;             //!< Default: 250000000 (250MHz)
  uint64_t fifoUnit;             //!< Default: 4096
  uint64_t workInterval;         //!< Default: 50000 (50ns)
  uint64_t maxRequestCount;      //!< Default: 4
  uint16_t maxIOCQueue;          //!< Default: 16
  uint16_t maxIOSQueue;          //!< Default: 16
  uint16_t wrrHigh;              //!< Default: 2
  uint16_t wrrMedium;            //!< Default: 2
  uint64_t lbaSize;              //!< Default: 512
  uint16_t defaultNamespace;     //!< Default: 1
  bool enableDiskImage;          //!< Default: False
  bool strictDiskSize;           //!< Default: False
  bool useCopyOnWriteDisk;       //!< Default: False
  std::unordered_map<uint16_t, std::string> diskImagePaths;  //!< Default: ""
  // --- I/O Uncore knobs ---
  uint32_t uncoreMode;       //!< Default: 0 (disabled)
  uint32_t uncoreCQBatchN;   //!< Default: 8
  uint64_t uncoreCQBatchT;   //!< Default: 4000000 ps (= 4 µs)
  uint32_t uncoreDBBatchB;   //!< Default: 4
  // --- Mode 2 deep-offload Mailbox SQ-Engine knobs ---
  uint32_t mailboxBase;          //!< Default: 0x3000 (BAR0 byte offset)
  uint32_t mailboxStride;        //!< Default: 0x20 (32 B per qid slot)
  uint16_t mailboxLatchCycles;   //!< Default: 1 (cycles per S_LATCH_i, ×3)
  uint16_t mailboxDecodeCycles;  //!< Default: 8 (PRP-simple expansion)
  uint16_t mailboxInjectCycles;  //!< Default: 4 (SRAM write of 64B SQE)
  // --- Mechanism #1/#2/#4 CQ-side offload knobs ---
  uint32_t freeCidBase;          //!< Default: 0x3400 (BAR0 byte offset)
  uint16_t freeCidLatencyCycles; //!< Default: 2 (cycles charged per free-CID pop)
  uint64_t hintAgeGranularityPs; //!< Default: 1024000 (1 µs per age unit)
  // --- Fast-path statistical timing model (NVMeVirt-style) ---
  // When fastPathEnabled = 1, Controller::handleRequest skips the
  // HIL/ICL/FTL/PAL pipeline and uses a per-channel statistical timer:
  //   target_completion = max(now, channel_next_free[ch]) + Lmin
  //   channel_next_free[ch] = target + (1e12 / TmaxPerChannel)
  // The CQE is then routed through Controller::submit() at target time,
  // which preserves all I/O-Uncore mechanisms (uncorePendingCQE,
  // uncoreFlushScheduled, BAR0+0x2000 hint reg, aggregationMap MSI).
  bool     fastPathEnabled;       //!< Default: false
  uint64_t fastPathLmin;          //!< Default: 3000000 ps (= 3 µs)
  uint64_t fastPathTmaxPerCh;     //!< Default: 1000000 (= 1 M IOPS/ch)
  uint32_t fastPathChannelPolicy; //!< Default: 1 (LBA-hash)
  uint64_t fastPathMaxOutstanding;//!< Default: 8192

 public:
  Config();

  bool setConfig(const char *, const char *) override;
  void update() override;

  int64_t readInt(uint32_t) override;
  uint64_t readUint(uint32_t) override;
  std::string readString(uint32_t) override;
  bool readBoolean(uint32_t) override;
};

}  // namespace NVMe

}  // namespace HIL

}  // namespace SimpleSSD

#endif
