//
//  RingClient.h — app side of the shared-memory ring (SHMEM.md), reference impl.
//
//  The production producer is SoundboardApp (Swift); this C++ class is the
//  protocol reference and the unit-test producer. It only ATTACHES (never creates
//  or unlinks) and writes only client-owned fields.
//
#pragma once
#include "SoundboardRingProtocol.h"
#include <cstdint>

class RingClient {
public:
    RingClient() = default;
    ~RingClient();
    RingClient(const RingClient&) = delete;
    RingClient& operator=(const RingClient&) = delete;

    bool attach(const char* name);          // open O_RDWR + map + validate; false on failure
    void detach();
    bool valid() const { return mHdr != nullptr; }
    int  lastErrno() const { return mErrno; }

    SoundboardRingInfo readHeader() const;  // geometry/state read back from the header

    void claim(uint64_t session);           // write appSession = session
    void release();                         // write appSession = 0
    void beat();                            // heartbeat++

    // Write interleaved-stereo float frames. Returns frames written; drops the
    // remainder on a full ring (reader priority — never overwrites unread data).
    uint32_t produce(const float* stereo, uint32_t frames);

    SoundboardRingHeader* header() const { return mHdr; }

private:
    int      mFd       = -1;
    void*    mBase     = nullptr;
    SoundboardRingHeader* mHdr = nullptr;
    float*   mData     = nullptr;
    uint32_t mCap      = 0;
    uint32_t mChannels = 0;
    int      mErrno    = 0;
};
