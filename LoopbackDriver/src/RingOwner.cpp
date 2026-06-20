#include "RingOwner.h"

#include <sys/mman.h>
#include <sys/fcntl.h>
#include <sys/stat.h>     // umask
#include <unistd.h>
#include <cerrno>
#include <cstring>

RingOwner::~RingOwner() { destroy(); }

bool RingOwner::create(const char* name)
{
    if (mHdr) return true;                                  // already created
    std::strncpy(mName, name, sizeof(mName) - 1);
    shm_unlink(mName);                                      // clear any stale region

    // fchmod on a shm object is EINVAL on macOS; clear umask so 0666 sticks and
    // the user-uid client can open it O_RDWR (SHMEM.md §1).
    mode_t old = umask(0);
    int fd = shm_open(mName, O_CREAT | O_RDWR, 0666);
    umask(old);
    if (fd < 0) { mCreateErrno = errno; return false; }

    const uint64_t total = SoundboardRingTotalBytes();
    if (ftruncate(fd, (off_t)total) != 0) { mCreateErrno = errno; close(fd); return false; }
    void* base = mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (base == MAP_FAILED) { mCreateErrno = errno; return false; }

    auto* h = static_cast<SoundboardRingHeader*>(base);
    std::memset(h, 0, sizeof(*h));
    h->version       = (uint16_t)kSoundboardRingVersion;
    h->channels      = (uint16_t)kSoundboardRingChannels;
    h->frameCapacity = kSoundboardRingFrameCapacity;
    h->sampleRate    = kSoundboardRingSampleRate;
    h->dataOffset    = sizeof(SoundboardRingHeader);
    h->driverState   = kSoundboardRingAlive;
    __atomic_store_n(&h->appSession, (uint64_t)0, __ATOMIC_RELAXED);
    __atomic_store_n(&h->heartbeat,  (uint64_t)0, __ATOMIC_RELAXED);
    __atomic_store_n(&h->writeIndex, (uint64_t)0, __ATOMIC_RELEASE);
    __atomic_store_n(&h->readIndex,  (uint64_t)0, __ATOMIC_RELEASE);
    __atomic_store_n(&h->magic, (uint32_t)kSoundboardRingMagic, __ATOMIC_RELEASE);  // publish last

    mBase = base; mHdr = h; mData = SoundboardRingData(h);
    mCap = h->frameCapacity; mChannels = h->channels;     // cache trusted geometry
    mCreateErrno = 0;
    return true;
}

void RingOwner::destroy()
{
    if (!mHdr) return;
    __atomic_store_n(&mHdr->driverState, (uint32_t)kSoundboardRingClosing, __ATOMIC_RELEASE);
    munmap(mBase, SoundboardRingTotalBytes());
    shm_unlink(mName);
    mBase = nullptr; mHdr = nullptr; mData = nullptr;
    mCap = mChannels = 0;
    mGranted.store(0, std::memory_order_release);
    mSeenGrant = 0; mLastBeat = 0; mStall = 0;
}

SoundboardRingInfo RingOwner::info() const
{
    SoundboardRingInfo i{};
    i.protocolVersion = kSoundboardRingVersion;
    i.driverState     = mHdr ? mHdr->driverState : kSoundboardRingClosing;
    i.frameCapacity   = mCap;
    i.channels        = mChannels;
    i.sampleRate      = kSoundboardRingSampleRate;
    std::strncpy(i.name, mName, sizeof(i.name) - 1);
    return i;
}

void RingOwner::setSession(uint64_t session)
{
    // Property thread. Just publish the grant; consume() (RT thread) owns the
    // liveness window and resets it itself when it observes a new grant.
    mGranted.store(session, std::memory_order_release);
}

void RingOwner::silenceAll(void* dst, uint32_t frames, const RingOutFormat& fmt) const
{
    for (uint32_t f = 0; f < frames; ++f) writeFrame(dst, f, 0.0f, 0.0f, fmt);
}

uint32_t RingOwner::consume(void* dst, uint32_t frames, const RingOutFormat& fmt)
{
    SoundboardRingHeader* h = mHdr;
    if (!h) { /* not created: nothing to write into */ return 0; }

    // Gate: a granted, alive, live producer must be present, else silence.
    uint64_t granted = mGranted.load(std::memory_order_acquire);
    if (granted == 0 ||
        __atomic_load_n(&h->driverState, __ATOMIC_ACQUIRE) != kSoundboardRingAlive ||
        __atomic_load_n(&h->appSession,  __ATOMIC_ACQUIRE) != granted) {
        silenceAll(dst, frames, fmt);
        return 0;
    }
    // Liveness (RT-owned): a heartbeat that hasn't advanced for too many cycles ⇒
    // producer dead. A freshly observed grant opens a new window.
    uint64_t beat = __atomic_load_n(&h->heartbeat, __ATOMIC_ACQUIRE);
    if (granted != mSeenGrant) {
        mSeenGrant = granted; mLastBeat = beat; mStall = 0;
    } else if (beat == mLastBeat) {
        if (++mStall > mStallLimit) { silenceAll(dst, frames, fmt); return 0; }
    } else {
        mLastBeat = beat; mStall = 0;
    }

    // Lock-free SPSC drain with reader priority (SHMEM.md §4).
    uint64_t r = __atomic_load_n(&h->readIndex,  __ATOMIC_RELAXED);
    uint64_t w = __atomic_load_n(&h->writeIndex, __ATOMIC_ACQUIRE);
    uint64_t avail = w - r;
    if (avail > mCap) { r = w - mCap; avail = mCap; }      // producer lapped us → skip stale
    uint32_t give = avail < frames ? (uint32_t)avail : frames;

    for (uint32_t f = 0; f < give; ++f) {
        uint64_t slot = ((r + f) & (mCap - 1)) * mChannels;
        writeFrame(dst, f, mData[slot + 0], mData[slot + 1], fmt);
    }
    for (uint32_t f = give; f < frames; ++f) writeFrame(dst, f, 0.0f, 0.0f, fmt);  // underrun → silence
    __atomic_store_n(&h->readIndex, r + give, __ATOMIC_RELEASE);
    return give;
}

void RingOwner::writeFrame(void* dst, uint32_t f, float L, float R, const RingOutFormat& fmt) const
{
    const uint32_t ch = fmt.channels;
    auto* base = static_cast<unsigned char*>(dst) + (size_t)f * ch * (fmt.bits / 8);
    for (uint32_t c = 0; c < ch; ++c) {
        float s = (ch == 1) ? 0.5f * (L + R) : (c == 0 ? L : (c == 1 ? R : 0.0f));
        void* slot = base + c * (fmt.bits / 8);
        if (fmt.isFloat && fmt.bits == 32)       *static_cast<float*>(slot)   = s;
        else if (!fmt.isFloat && fmt.bits == 16) *static_cast<int16_t*>(slot) = (int16_t)(s * 32767.0f);
        else if (!fmt.isFloat && fmt.bits == 32) *static_cast<int32_t*>(slot) = (int32_t)(s * 2147483647.0f);
        else if (!fmt.isFloat && fmt.bits == 24) {
            int32_t v = (int32_t)(s * 8388607.0f);
            auto* b = static_cast<unsigned char*>(slot);
            b[0] = v & 0xFF; b[1] = (v >> 8) & 0xFF; b[2] = (v >> 16) & 0xFF;
        }
    }
}
