//
//  SoundboardRingProtocol.h — the driver-owned shared-memory ring layout.
//  Implements LoopbackDriver/SHMEM.md. Plain C struct; no CoreAudio/HAL types so
//  it compiles into both the driver and the standalone unit tests.
//
#ifndef SoundboardRingProtocol_h
#define SoundboardRingProtocol_h

#include <stdint.h>
#include <stddef.h>

#define kSoundboardRingName          "/soundboard.mix"
#define kSoundboardRingMagic         0x53424D58u   // 'SBMX'
#define kSoundboardRingVersion       1u
#define kSoundboardRingChannels      2u            // canonical interior channels
#define kSoundboardRingSampleRate    48000u        // canonical interior rate
#define kSoundboardRingFrameCapacity 65536u        // power of two (frames); sized once, never realloc'd

enum { kSoundboardRingClosing = 0u, kSoundboardRingAlive = 1u };

// Fixed header, then frameCapacity*channels canonical float32 samples at dataOffset.
typedef struct {
    // identity + geometry — driver writes once at create, immutable after (RO to all)
    uint32_t magic;          // kSoundboardRingMagic (written last at create)
    uint16_t version;        // kSoundboardRingVersion
    uint16_t channels;       // canonical interleaved float channels
    uint32_t frameCapacity;  // power of two
    uint32_t sampleRate;     // informational
    uint32_t driverState;    // kSoundboardRingAlive | kSoundboardRingClosing   (driver RW)
    uint32_t _pad0;
    uint64_t dataOffset;     // bytes from base to sample data
    // liveness / ownership
    uint64_t appSession;     // claimant id, 0 = released   (client RW, driver RO)
    uint64_t heartbeat;      // client liveness counter      (client RW, driver RO)
    // SPSC ring indices (frames, monotonic)
    uint64_t writeIndex;     // produced by the client       (client RW, driver RO)
    uint64_t readIndex;      // consumed by the driver        (driver RW, client RO)
} SoundboardRingHeader;

// RingInfo property payload (SHMEM.md §2: the client's discovery GET).
typedef struct {
    uint32_t protocolVersion;
    uint32_t driverState;
    uint32_t frameCapacity;
    uint32_t channels;
    uint32_t sampleRate;
    uint32_t _pad;
    char     name[64];       // POSIX shm name, NUL-terminated
} SoundboardRingInfo;

// Custom HAL property selectors (SHMEM.md §2).
#define kSoundboardCustomProperty_RingInfo    'sbni'   // GET: SoundboardRingInfo (discovery)
#define kSoundboardCustomProperty_RingSession 'sbns'   // SET/GET: uint64 session (claim/grant)

static inline uint64_t SoundboardRingTotalBytes(void) {
    return (uint64_t)sizeof(SoundboardRingHeader)
         + (uint64_t)kSoundboardRingFrameCapacity * kSoundboardRingChannels * sizeof(float);
}

static inline float* SoundboardRingData(SoundboardRingHeader* h) {
    return (float*)((unsigned char*)h + h->dataOffset);
}

#endif /* SoundboardRingProtocol_h */
