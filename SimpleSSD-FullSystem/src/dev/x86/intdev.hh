/*
 * Copyright (c) 2012 ARM Limited
 * All rights reserved
 *
 * The license below extends only to copyright in the software and shall
 * not be construed as granting a license to any other intellectual
 * property including but not limited to intellectual property relating
 * to a hardware implementation of the functionality of the software
 * licensed hereunder.  You may use the software subject to the license
 * terms below provided that you ensure that this notice is replicated
 * unmodified and in its entirety in all distributions of the software,
 * modified or unmodified, in source code or in binary form.
 *
 * Copyright (c) 2008 The Regents of The University of Michigan
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met: redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer;
 * redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution;
 * neither the name of the copyright holders nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * Authors: Gabe Black
 */

#ifndef __DEV_X86_INTDEV_HH__
#define __DEV_X86_INTDEV_HH__

#include <cassert>
#include <functional>
#include <string>
#include <unordered_map>

#include "base/logging.hh"
#include "mem/tport.hh"
#include "sim/sim_object.hh"

namespace X86ISA
{

template <class Device>
class IntSlavePort : public SimpleTimingPort
{
    Device * device;

  public:
    IntSlavePort(const std::string& _name, SimObject* _parent,
                 Device* dev) :
        SimpleTimingPort(_name, _parent), device(dev)
    {
    }

    AddrRangeList
    getAddrRanges() const
    {
        return device->getIntAddrRange();
    }

    Tick
    recvAtomic(PacketPtr pkt)
    {
        panic_if(pkt->cmd != MemCmd::WriteReq,
                "%s received unexpected command %s from %s.\n",
                name(), pkt->cmd.toString(), getPeer());
        pkt->headerDelay = pkt->payloadDelay = 0;
        return device->recvMessage(pkt);
    }
};

template<class T>
PacketPtr
buildIntPacket(Addr addr, T payload)
{
    RequestPtr req = std::make_shared<Request>(
        addr, sizeof(T), Request::UNCACHEABLE, Request::intMasterId);
    PacketPtr pkt = new Packet(req, MemCmd::WriteReq);
    pkt->allocate();
    pkt->setRaw<T>(payload);
    return pkt;
}

template <class Device>
class IntMasterPort : public QueuedMasterPort
{
  private:
    ReqPacketQueue reqQueue;
    SnoopRespPacketQueue snoopRespQueue;

    Device* device;
    Tick latency;

    typedef std::function<void(PacketPtr)> OnCompletionFunc;
    // Per-packet completion callbacks.  Upstream gem5 stored a SCALAR
    // onCompletion here, which is correct only when at most one IPI is
    // in-flight at a time.  With NUM_CPUS >= 4 + TimingSimpleCPU + caches,
    // a CPU's APIC can have multiple IPIs in-flight (e.g. broadcast IPI
    // targeting all-other-CPUs generates one packet per target).  The
    // scalar got overwritten by the second sendMessage; when the first
    // response arrived, onCompletion fired the wrong callback, and when
    // the second arrived, onCompletion was nullptr -> bad_function_call.
    // Keying by PacketPtr is safe: each Packet is unique and lives until
    // its completion callback runs (which then deletes/transfers it).
    std::unordered_map<PacketPtr, OnCompletionFunc> onCompletionMap;
    // If nothing extra needs to happen, just clean up the packet.
    static void defaultOnCompletion(PacketPtr pkt) { delete pkt; }

  public:
    IntMasterPort(const std::string& _name, SimObject* _parent,
                  Device* dev, Tick _latency) :
        QueuedMasterPort(_name, _parent, reqQueue, snoopRespQueue),
        reqQueue(*_parent, *this), snoopRespQueue(*_parent, *this),
        device(dev), latency(_latency)
    {
    }

    bool
    recvTimingResp(PacketPtr pkt) override
    {
        assert(pkt->isResponse());
        auto it = onCompletionMap.find(pkt);
        if (it != onCompletionMap.end()) {
            OnCompletionFunc func = std::move(it->second);
            onCompletionMap.erase(it);
            inform("IPI_DBG[%s]: recv MATCH pkt=%p mapsize=%zu",
                   name(), (void*)pkt, onCompletionMap.size());
            func(pkt);
        } else {
            inform("IPI_DBG[%s]: recv UNMATCHED pkt=%p mapsize=%zu",
                   name(), (void*)pkt, onCompletionMap.size());
            delete pkt;
        }
        return true;
    }

    void
    sendMessage(PacketPtr pkt, bool timing,
            OnCompletionFunc func=defaultOnCompletion)
    {
        if (timing) {
            onCompletionMap[pkt] = func;
            inform("IPI_DBG[%s]: send pkt=%p mapsize=%zu",
                   name(), (void*)pkt, onCompletionMap.size());
            schedTimingReq(pkt, curTick() + latency);
        } else {
            sendAtomic(pkt);
            func(pkt);
        }
    }
};

} // namespace X86ISA

#endif //__DEV_X86_INTDEV_HH__
