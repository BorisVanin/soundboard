# Soundboard shared-memory mix-ring protocol

Status: **draft** (gated on the "driver can create + share a region" POC).
Scope: the contract between the **Soundboard driver** (an AudioServerPlugIn loaded
inside `coreaudiod`) and a **client app** (SoundboardApp) for delivering the app's
mixed audio to the driver's virtual-mic input over POSIX shared memory.

## 1. Ownership model — the driver owns the region

The **driver creates, sizes, permissions, and destroys** the shared-memory region.
The app is a transient **client** that discovers and attaches to it. Rationale:

- `coreaudiod` is long-lived and stable; the app is the volatile party (crashes,
  restarts, multiple launches). The stable party owning the resource means an app
  restart is a re-attach, never a re-create — no stale-mapping, no create-race.
- Only one creator ⇒ no two-instances-race-to-`shm_unlink`+create.
- **The driver defines the geometry**, so the driver treats capacity/offsets as
  trusted constants. A buggy/hostile client cannot make the realtime consumer read
  out of bounds. This removes an entire class of `coreaudiod` crashes.

The client never creates, resizes, or unlinks the region. It only `open`s (O_RDWR)
and `mmap`s it, and writes **only** the fields the protocol assigns to it.

## 2. Discovery — custom HAL properties

The driver publishes the contract through custom HAL properties on the device
object (read/written cross-process via `AudioObjectGet/SetPropertyData`). Selectors
are defined in the shared control header.

| Property | Dir | Type | Meaning |
|----------|-----|------|---------|
| `RingName` (`'sbnm'`) | driver→app, **read-only** | CFString | POSIX name of the shm region (e.g. `/soundboard.mix.<token>`). |
| `RingSession` (`'sbss'`) | app→driver, **settable** | CFData(uint64) | The app registers/claims ownership with its session id; `0` releases. |

The driver creates the region **before** advertising the name (name is valid only
when `driverState == DRIVER_ALIVE`).

## 3. Shared-memory layout

One page-aligned region: a fixed header followed by the interleaved-float sample
ring. All multi-byte fields are little-endian, native alignment. **The driver
writes the geometry once at creation; it is immutable for the region's life.**

```c
#define kSoundboardRingMagic   0x53424752u   // 'SBGR'
#define kSoundboardRingVersion 1

typedef struct {
    // --- identity + geometry: driver-written at create, immutable, RO to all after ---
    uint32_t magic;          // kSoundboardRingMagic
    uint16_t version;        // kSoundboardRingVersion
    uint16_t channels;       // interleaved float channels (e.g. 2)
    uint32_t frameCapacity;  // power of two
    uint32_t sampleRate;     // e.g. 48000
    uint64_t dataOffset;     // byte offset from base to sample data

    // --- liveness / ownership ---
    uint32_t driverState;    // 1 = DRIVER_ALIVE, 0 = DRIVER_CLOSING/invalid
    uint32_t _pad0;
    uint64_t appSession;     // nonzero session id of the claiming app, 0 = released
    uint64_t heartbeat;      // app-incremented liveness counter

    // --- SPSC ring indices (in frames, monotonic) ---
    uint64_t writeIndex;     // total frames produced by the app
    uint64_t readIndex;      // total frames consumed by the driver
    // sample data (float, interleaved) begins at `dataOffset`
} SoundboardRingHeader;
```

Sample data: `frameCapacity * channels` floats at `dataOffset`. Slot for frame `f`
is `(f & (frameCapacity-1)) * channels`.

## 4. Field ownership (the RO/RW discipline)

POSIX shared memory has **no per-field permissions** — both sides `mmap` the whole
page `PROT_READ|PROT_WRITE`. The table below is a **protocol contract** both sides
must honor; safety derives from the discipline, not the kernel.

| Field | Driver | App | Notes |
|-------|--------|-----|-------|
| `magic`, `version`, `channels`, `frameCapacity`, `sampleRate`, `dataOffset` | **RW at create**, RO after | RO | Geometry. App must validate `magic`/`version` and otherwise trust it. |
| `driverState` | **RW** | RO | Driver sets `1` at create, `0` before tearing the region down. |
| `appSession` | RO | **RW** | App writes its session id to claim, `0` to release. Driver only reads it. |
| `heartbeat` | RO | **RW** | App increments while alive. Exactly **one** app writes it. |
| `writeIndex` | RO | **RW** (producer) | App advances after writing audio. Release-store. |
| `readIndex` | **RW** (consumer) | RO | Driver advances after reading audio. Release-store. |
| sample data | RO (reads) | **RW** (writes) | App produces, driver consumes. |

A party MUST NOT write a field the table marks RO for it. Violations are protocol
bugs; the consumer is allowed to ignore a region that looks inconsistent.

## 5. Lifecycle / handshake

1. **Driver load.** `shm_unlink` any stale name → create with the mode forced to
   `0666` so the user-uid app (the driver runs as `_coreaudiod`) can open it RW.
   **`fchmod` on a POSIX shm object returns `EINVAL` on macOS**, so the mode must
   be set at creation with the umask cleared:
   `mode_t old = umask(0); fd = shm_open(name, O_CREAT|O_RDWR, 0666); umask(old);`
   → `ftruncate` → write geometry, `driverState=1`, `appSession=0`, `heartbeat=0`,
   indices `0`. Advertise `RingName`.
2. **App start.** Read `RingName` → `shm_open(O_RDWR)` (no `O_CREAT`) → `mmap` →
   validate `magic`/`version`/`channels` and `driverState==1`.
3. **Claim.** App `SetPropertyData(RingSession, id)` **and** writes `appSession=id`.
   The driver records the granted session (most-recent registrant wins).
4. **Run.** App: write samples → release-store `writeIndex`; increment `heartbeat`
   each buffer. Driver: drain (see §6) only while granted + alive (see §7).
5. **App release.** On clean exit, app writes `appSession=0` (and stops the
   heartbeat). Driver reverts to emitting silence.
6. **Driver close.** On `coreaudiod` unload / device teardown, the driver sets
   `driverState=0` (so any app detaches cleanly), then unmaps/unlinks.

## 6. SPSC ring semantics

Single producer (app), single consumer (driver). Indices are monotonic frame
counts; capacity is a power of two.

- **Producer (app):** `free = frameCapacity - (writeIndex - readIndex)`; write
  `min(n, free)` frames, then release-store `writeIndex`. Drop on `free==0`.
- **Consumer (driver):** `avail = writeIndex - readIndex`; read `min(n, avail)`
  frames into the device buffer, **silence the remainder** (underflow), then
  release-store `readIndex`. If `avail > frameCapacity` (producer lapped a stalled
  consumer), skip stale frames: `readIndex = writeIndex - frameCapacity`.
- Exactly one producer and one consumer at a time. Two simultaneous consumers
  would steal each other's frames — out of scope (single-consumer assumption).

## 7. Liveness

- **Driver → app:** `driverState`. `1` = region valid; `0` = the app must detach
  and not touch the region (it may be unmapped/unlinked imminently).
- **App → driver:** `heartbeat`. The app increments it continuously while alive.
  The driver consumes only while `appSession == grantedSession` **and** the
  heartbeat has advanced recently. A stalled heartbeat ⇒ app presumed dead ⇒ the
  driver emits silence and drops the grant; the next registrant re-claims. (The
  driver detects this by reading an integer in the IO path — no syscall/log/alloc.)

## 8. Concurrency & memory ordering

- Cross-process atomics use C11/`__atomic` (or `std::atomic`) on the shared
  `uint64_t` index/heartbeat fields. Producer publishes data with a **release**
  store to `writeIndex`; consumer reads it with an **acquire** load (and vice-versa
  for `readIndex`). The Swift side uses a tiny C shim for acquire/release.
- The driver publishes its *binding* (mapped pointer + cached trusted geometry) to
  the realtime consumer via an **atomic pointer**; the realtime path loads it with
  acquire and never re-reads geometry from shared memory.

## 9. Safety rules (non-negotiable — these caused real coreaudiod wedges)

- The realtime/timing paths (`doIO`, `getZeroTimeStamp`) do **zero** logging,
  allocation, or syscalls. No `os_log` on hot or frequently-polled paths
  (`GetProperty` for unimplemented selectors is polled constantly by the HAL).
- Never `munmap` a region the realtime path may still be reading. Prefer
  never-unmap-during-life, or RCU-style deferred free on re-attach.
- The consumer treats all client-written fields as untrusted: bound every loop,
  validate the region once at attach, and degrade to silence on anything unexpected
  — never crash, never spin.

## 10. Versioning

`version` gates the layout. A consumer/producer that sees a `version` it doesn't
understand refuses to attach (silence) rather than guessing.
