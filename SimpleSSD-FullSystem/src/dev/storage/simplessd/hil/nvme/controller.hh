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
