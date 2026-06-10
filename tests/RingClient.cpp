#include "RingClient.h"

#include <sys/mman.h>
#include <sys/fcntl.h>
#include <unistd.h>
#include <cerrno>

RingClient::~RingClient() { detach(); }

bool RingClient::attach(const char* name)
{
    if (mHdr) return true;
    int fd = shm_open(name, O_RDWR);              // no O_CREAT — the client never creates
    if (fd < 0) { mErrno = errno; return false; }
    const uint64_t total = SoundboardRingTotalBytes();
    void* base = mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (base == MAP_FAILED) { mErrno = errno; return false; }

    auto* h = static_cast<SoundboardRingHeader*>(base);
    // Validate the region the owner advertised before trusting it.
    if (__atomic_load_n(&h->magic, __ATOMIC_ACQUIRE) != kSoundboardRingMagic ||
        h->version != kSoundboardRingVersion ||
        h->channels != kSoundboardRingChannels ||
        h->frameCapacity == 0 || (h->frameCapacity & (h->frameCapacity - 1)) != 0) {
        munmap(base, total); mErrno = EINVAL; return false;
    }
    mBase = base; mHdr = h; mData = SoundboardRingData(h);
    mCap = h->frameCapacity; mChannels = h->channels;
    mErrno = 0;
    return true;
}

void RingClient::detach()
{
    if (!mHdr) return;
    munmap(mBase, SoundboardRingTotalBytes());
    mBase = nullptr; mHdr = nullptr; mData = nullptr; mCap = mChannels = 0;
}

SoundboardRingInfo RingClient::readHeader() const
{
    SoundboardRingInfo i{};
    if (!mHdr) return i;
    i.protocolVersion = mHdr->version;
    i.driverState     = __atomic_load_n(&mHdr->driverState, __ATOMIC_ACQUIRE);
    i.frameCapacity   = mHdr->frameCapacity;
    i.channels        = mHdr->channels;
    i.sampleRate      = mHdr->sampleRate;
    return i;
}

void RingClient::claim(uint64_t session) { if (mHdr) __atomic_store_n(&mHdr->appSession, session, __ATOMIC_RELEASE); }
void RingClient::release()               { if (mHdr) __atomic_store_n(&mHdr->appSession, (uint64_t)0, __ATOMIC_RELEASE); }
void RingClient::beat()                  { if (mHdr) __atomic_store_n(&mHdr->heartbeat,
                                                      __atomic_load_n(&mHdr->heartbeat, __ATOMIC_RELAXED) + 1, __ATOMIC_RELEASE); }

uint32_t RingClient::produce(const float* stereo, uint32_t frames)
{
    if (!mHdr) return 0;
    uint64_t w = __atomic_load_n(&mHdr->writeIndex, __ATOMIC_RELAXED);
    uint64_t r = __atomic_load_n(&mHdr->readIndex,  __ATOMIC_ACQUIRE);
    uint64_t freeFrames = mCap - (w - r);
    uint32_t give = freeFrames < frames ? (uint32_t)freeFrames : frames;   // drop on full
    for (uint32_t f = 0; f < give; ++f) {
        uint64_t slot = ((w + f) & (mCap - 1)) * mChannels;
        mData[slot + 0] = stereo[f * 2 + 0];
        mData[slot + 1] = stereo[f * 2 + 1];
    }
    __atomic_store_n(&mHdr->writeIndex, w + give, __ATOMIC_RELEASE);
    return give;
}
