//
//  RingOwner.h — driver side of the shared-memory ring (SHMEM.md).
//
//  HAL-free so it is fully unit-testable without coreaudiod. The driver's HAL
//  property/IO trampolines are a thin shim that marshals to these methods; the
//  methods below ARE the protocol (#2 SHMEM.md) and the realtime consumer (§4).
//
#pragma once
#include "SoundboardRingProtocol.h"
#include <atomic>
#include <cstdint>

// Output format the realtime consumer converts the canonical float stream into
// (the device's negotiated ReadInput format). Kept HAL-free on purpose.
struct RingOutFormat {
    uint32_t channels;   // 1 = mono (downmix), 2+ = stereo into ch0/ch1, rest silent
    uint32_t bits;       // 16 | 24 | 32
    bool     isFloat;    // true => 32-bit float
};

class RingOwner {
public:
    RingOwner() = default;
    ~RingOwner();
    RingOwner(const RingOwner&) = delete;
    RingOwner& operator=(const RingOwner&) = delete;

    // Owner lifecycle.
    bool create(const char* name);     // create+map+init; false on failure (see lastErrno)
    void destroy();                    // mark CLOSING, munmap, unlink
    bool isCreated() const { return mHdr != nullptr; }
    int  lastErrno() const { return mCreateErrno; }

    // HAL property interface (SHMEM.md §2) — pure data, no HAL types.
    SoundboardRingInfo info() const;            // RingInfo GET
    void     setSession(uint64_t session);      // RingSession SET (grant); 0 = revoke
    uint64_t grantedSession() const { return mGranted.load(std::memory_order_acquire); }

    // Realtime consume (SHMEM.md §4): drain up to `frames` into `dst` (in `fmt`),
    // silencing any shortfall. Returns the frame count actually sourced from the
    // ring. Never blocks, allocates, or logs.
    uint32_t consume(void* dst, uint32_t frames, const RingOutFormat& fmt);

    // Liveness tuning + inspection (tests).
    void setHeartbeatStallLimit(uint32_t cycles) { mStallLimit = cycles; }
    SoundboardRingHeader* header() const { return mHdr; }

private:
    void silenceAll(void* dst, uint32_t frames, const RingOutFormat& fmt) const;
    void writeFrame(void* dst, uint32_t f, float L, float R, const RingOutFormat& fmt) const;

    char     mName[128] = {0};
    int      mFd        = -1;
    void*    mBase      = nullptr;
    SoundboardRingHeader* mHdr = nullptr;
    float*   mData      = nullptr;
    uint32_t mCap       = 0;   // cached, trusted (driver-created) geometry
    uint32_t mChannels  = 0;
    std::atomic<uint64_t> mGranted{0};   // set on the property thread, read on the RT thread
    uint64_t mSeenGrant = 0;   // RT-owned: last grant consume() acted on (liveness window)
    uint64_t mLastBeat  = 0;   // RT-owned
    uint32_t mStall     = 0;   // RT-owned
    uint32_t mStallLimit = 200;
    int      mCreateErrno = 0;
};
