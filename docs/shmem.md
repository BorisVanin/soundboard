# Soundboard shared-memory ring — driver-owned protocol

How the **driver** (AudioServerPlugIn, runs inside `coreaudiod` as user
`_coreaudiod`) creates a POSIX shared-memory block, hands it to a **client**
(SoundboardApp, runs as the login user), and how the two move audio through it
safely. This is the implementation contract; everything here is verified by the
`CreatePOC` (driver can `shm_open(O_CREAT)` + share across the uid boundary).

Roles:
- **Owner = the driver.** Creates, sizes, permissions, owns the geometry, destroys.
- **Client = the app.** Discovers, attaches (read/write), produces audio. Never
  creates, resizes, or unlinks.

---

## 0. Design & sizing

**One lane, by design.** The ring carries a single finished mix. *What* goes into
that mix — microphone, captured system audio, soundboard clips, anything the
operator dials in — is entirely the **app's** concern: the app mixes its sources
internally (on a single clock) and presents one stream. The shared memory and the
driver stay dumb: one producer, one stream, one consumer.

**Canonical interior format — fixed, and decoupled from the device format.** The
block has its *own* format, chosen once and never renegotiated:

- samples are **`float32`** (`bytesPerSample = 4`, always);
- a fixed **`channels`** count (e.g. 2);
- a fixed, power-of-two **`frameCapacity`** in *frames*, sized for worst-case slack
  at the **highest** sample rate we support (e.g. 65536 frames ≈ 0.34 s @ 192 kHz,
  ≈ 1.3 s @ 48 kHz).

Because capacity is in **frames**, a sample-rate change does **not** resize the
block. Because samples are always `float32` at a fixed channel count, a bit-depth
or channel change on the device does **not** resize it either: the device's
negotiated format (int16/24/float, mono/stereo, rate) is absorbed **at the edges**
— the consumer converts `canonical → ReadInput format` (it already does this), and
the app converts each source `→ canonical` on the way in. The ring runs at a
canonical rate (48 kHz, what VPIO and most consumers use); the `sampleRate` header
field is informational.

**Therefore the byte size is computed once from compile-time constants** —
`sizeof(header) + frameCapacity * channels * 4` — a single `ftruncate` at create,
and **never reallocated** for the life of the driver. No format change touches the
mapping.

---

## 1. How the owner creates the block

Done once, when the driver is asked to `Initialize` (device load). Kept mapped for
the driver's whole life.

```c
shm_unlink(kRingName);                       // clear any stale region

mode_t old = umask(0);                        // ← REQUIRED: umask would strip the
int fd = shm_open(kRingName,                  //   group/other bits otherwise, and
                  O_CREAT | O_RDWR, 0666);    //   fchmod() on a shm object is EINVAL
umask(old);                                   //   on macOS. So clear umask here.
//  fd >= 0 verified to work from inside coreaudiod (CreatePOC: createErrno=0).

ftruncate(fd, SoundboardRingTotalBytes());    // header + frameCapacity*ch*sizeof(float)
void* base = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
close(fd);                                     // the mapping survives the closed fd

// Initialise the header (driver-defined geometry; see §3), then publish:
hdr->frameCapacity = kFrameCapacity;  hdr->channels = kChannels;
hdr->sampleRate    = kSampleRate;     hdr->dataOffset = sizeof(SoundboardRingHeader);
hdr->driverState   = RING_ALIVE;      hdr->appSession = 0;  hdr->heartbeat = 0;
atomic_store(&hdr->writeIndex, 0);    atomic_store(&hdr->readIndex, 0);
hdr->version = kVersion;
hdr->magic   = kRingMagic;            // written LAST — magic present ⇒ header valid
```

Key points:
- **`0666` via `umask(0)`**, not `fchmod` (`fchmod` on a shm object returns
  `EINVAL` on macOS). 0666 is what lets the login-user app open it `O_RDWR`.
- **The driver owns the geometry.** `frameCapacity`, `channels`, `dataOffset` are
  compile-time constants the driver writes once. The realtime consumer therefore
  *trusts* them — a buggy/hostile client cannot make the driver read out of bounds.
- The region exists for the driver's life; on teardown the driver sets
  `driverState = RING_CLOSING` (so clients detach), then `munmap`+`shm_unlink`.

---

## 2. How the owner shares the block with clients

Sharing is brokered through two **custom HAL properties** on the device object,
read/written cross-process with `AudioObjectGetPropertyData` /
`AudioObjectSetPropertyData`. The driver marshals CFData payloads across the HAL.

| Property | Selector | Access | Payload | Purpose |
|----------|----------|--------|---------|---------|
| `RingInfo`    | `'sbni'` | **GET** (client reads) | `SoundboardRingInfo` | discover the shm name + geometry + `driverState` |
| `RingSession` | `'sbns'` | **SET** (client writes) / **GET** (client reads) | `uint64` | claim/release ownership; read back the granted session |

```c
typedef struct {            // RingInfo ('sbni') GET payload
    uint32_t protocolVersion;
    uint32_t driverState;   // RING_ALIVE (1) | RING_CLOSING (0)
    uint32_t frameCapacity; // power of two
    uint32_t channels;      // interleaved float channels
    uint32_t sampleRate;
    uint32_t _pad;
    char     name[64];      // POSIX shm name, NUL-terminated (e.g. "/soundboard.mix")
} SoundboardRingInfo;
```

### The access sequence (the protocol)

```
 CLIENT (app)                                   OWNER (driver, in coreaudiod)
 ────────────                                   ─────────────────────────────
                                                [Initialize] create + map region,
                                                driverState=ALIVE, appSession=0   (§1)

 1. GET RingInfo  ───────────────────────────►  return {version, driverState=ALIVE,
                  ◄───────────────────────────  geometry, name}
    if version mismatch or driverState!=ALIVE: abort/retry.

 2. shm_open(name, O_RDWR) + mmap               (no O_CREAT — client never creates)
    validate hdr.magic/version/geometry == RingInfo; else detach.

 3. pick sessionId (nonzero, unique, e.g. pid<<32|rand)
    write hdr.appSession = sessionId
    start hdr.heartbeat (++ each buffer)

 4. SET RingSession = sessionId ──────────────►  grantedSession = sessionId
                                                 (records the authoritative owner)

 5. produce: write samples → release-store      consume (RT): only while
    hdr.writeIndex; ++hdr.heartbeat              hdr.appSession==grantedSession AND
                                                 heartbeat advancing → drain ring;
                                                 else emit silence.                (§4,§5)

 6. (optional) GET RingSession ───────────────►  return grantedSession
    if != sessionId → you lost the grant (another client claimed); back off.

 7. release: SET RingSession = 0 ─────────────►  grantedSession = 0
    write hdr.appSession = 0; stop heartbeat

   [device teardown] driverState=CLOSING ─────►  client (sees it) detaches; driver
                                                 munmap + shm_unlink.
```

Notes:
- The **SET RingSession** is the single authoritative grant (serialized by the HAL
  in `setPropertyData`, off the realtime thread). **Last setter wins** → this is
  how competing/stuck instances are arbitrated; the new claimant becomes the owner
  and the old one detects it via step 6.
- `hdr.appSession` is the realtime-readable mirror the consumer checks each cycle
  (a cheap integer read) to confirm the producer it's draining is the granted one.
  The driver consumes only when `appSession == grantedSession`.

---

## 3. Memory structure

One mapping: a fixed header, then the interleaved-float sample ring. Little-endian,
native alignment. Index/`heartbeat` fields are accessed with acquire/release atomics
across the process boundary.

```c
#define kRingMagic   0x53424D58u   // 'SBMX'
#define kVersion     1
#define RING_ALIVE   1u
#define RING_CLOSING 0u

typedef struct {
    // ---- identity + geometry (owner writes once at create; immutable after) ----
    uint32_t magic;          // kRingMagic (written last at create)
    uint16_t version;        // kVersion
    uint16_t channels;       // e.g. 2
    uint32_t frameCapacity;  // power of two
    uint32_t sampleRate;     // e.g. 48000
    uint64_t dataOffset;     // bytes from base to sample data

    // ---- liveness / ownership ----
    uint32_t driverState;    // RING_ALIVE | RING_CLOSING
    uint32_t _pad0;
    uint64_t appSession;     // nonzero claimant id, 0 = released
    uint64_t heartbeat;      // client-incremented liveness counter

    // ---- SPSC ring indices (monotonic frame counts) ----
    uint64_t writeIndex;     // frames produced by the client
    uint64_t readIndex;      // frames consumed by the driver
} SoundboardRingHeader;       // sample data (float, interleaved) begins at dataOffset
```

Frame `f` occupies floats `[(f & (frameCapacity-1)) * channels ‥ +channels)`.

### Who can write / who can read / when

POSIX shm has **no per-field permissions** — both sides `mmap` the page `RW`. The
matrix is a *protocol contract*; safety comes from honoring it.

| Field | Writer (when) | Reader (when) |
|-------|---------------|----------------|
| `magic`, `version`, `channels`, `frameCapacity`, `sampleRate`, `dataOffset` | **driver**, once at create | both, at attach (client validates; driver trusts) |
| `driverState` | **driver**: `ALIVE` at create, `CLOSING` at teardown | client, at attach + while running (detach on `CLOSING`) |
| `appSession` | **client**: nonzero to claim (step 3), `0` to release (step 7) | driver, in RT consume (gate vs `grantedSession`) |
| `heartbeat` | **client**: ++ each produced buffer | driver, in RT consume (liveness; stalled ⇒ drop grant) |
| `writeIndex` | **client** (producer): release-store after writing samples | driver, acquire-load in RT consume |
| `readIndex` | **driver** (consumer): release-store after reading samples | client, relaxed-load to compute free space |
| sample data `[slot]` | **client** writes a frame **before** advancing `writeIndex` | driver reads a frame **after** observing `writeIndex` |

Invariants:
- **Exactly one** writer per field (single-producer / single-consumer). Two clients
  must not both write — arbitrated by `grantedSession` (§2) + a single-instance
  guard in the app.
- The producer writes sample data, then **release-stores** `writeIndex`; the
  consumer **acquire-loads** `writeIndex`, then reads the data. (Mirror for
  `readIndex`.) This is the only ordering that makes the data visible safely.
- The consumer reads `frameCapacity`/`dataOffset` **once at attach** into
  driver-local memory and never re-reads geometry from shared memory in the RT
  path — so a corrupt client cannot redirect the read.

### Synchronization — lock-free SPSC, reader-priority (no lock)

There is deliberately **no mutex or spinlock** on the data path. Both ends are
audio threads (the driver's realtime IO thread; the app's capture callback), and
the cardinal realtime rule is: *the RT thread must never block on a lock held by a
lower-priority thread.* A mutex would invite **priority inversion** across the
app ↔ `coreaudiod` boundary; a spinlock would make the RT thread burn a core
waiting on a descheduled producer. The synchronization **is** the acquire/release
ordering on the indices above — a memory barrier, not mutual exclusion. Reader and
writer work on disjoint regions of the ring, so they never need to exclude each
other.

**The reader has priority** — it is wait-free and never blocks; the writer yields:

| Ring state | Who yields | Behavior |
|------------|-----------|----------|
| **empty** (`avail == 0`, reader caught up) | reader does **not** wait | consumer emits **silence** and meets its deadline ← *reader priority* |
| **full** (`free == 0`, writer caught up) | **writer** yields | producer **drops** the new frames; it must **never** overwrite frames the reader hasn't consumed |

The consumer (delivering the mic to FaceTime/the recorder, on a hard deadline) is
never made to wait; a dropped *input* frame on a full ring is a momentary,
recoverable glitch. Reference designs to follow: PortAudio `pa_ringbuffer`, JACK
`jack_ringbuffer`, `boost::lockfree::spsc_queue`.

---

## 4. Realtime consume rules (driver, in `doIO`/ReadInput)

Per cycle, with `n` frames requested — **no logging, no allocation, no syscalls**:

```
binding = atomic_load_acquire(activeBinding)         // published by SET RingSession
if binding == NULL: silence; return
if hdr.driverState != ALIVE: silence; return
if hdr.appSession != grantedSession: silence; return
if heartbeat unchanged for > N cycles: silence; return   // client presumed dead

r = relaxed_load(readIndex)
w = acquire_load(writeIndex)
avail = w - r
if avail > frameCapacity: r = w - frameCapacity          // producer lapped us → skip stale
give = min(n, avail)
copy `give` frames from ring[r..] → device buffer (driver-trusted geometry/mask)
silence the remaining (n - give) frames                   // underflow
release_store(readIndex, r + give)
```

Every path is bounded and degrades to silence — never crash, never spin.

---

## 5. Failure handling (all degrade to silence, never to a crash/hang)

| Situation | Behavior |
|-----------|----------|
| No client attached / `appSession==0` | driver emits silence |
| Client crashed (heartbeat stalls) | driver emits silence, drops the grant; next claimant re-grants |
| Client lapped the consumer | driver skips stale frames (`r = w - frameCapacity`) |
| Corrupt indices (`r > w`) | `avail` clamps; reads stay within the trusted mask; bounded glitch only |
| Two clients claim | last `SET RingSession` wins; loser detects via GET (step 6) |
| Driver/coreaudiod restart | new region at load; clients re-run §2 (re-attach) |
| Driver teardown | `driverState=CLOSING`; clients detach before `munmap`/`shm_unlink` |

---

## 6. Concurrency / ordering summary

- Cross-process atomics on `writeIndex`/`readIndex`/`heartbeat` via `__atomic_*`
  (C/C++) and a tiny C shim from Swift; **release** on publish, **acquire** on read.
- The driver publishes its *binding* (mapped base + cached trusted geometry) to the
  RT consumer via an **atomic pointer**; the RT path loads it with acquire.
- Never `munmap` a region the RT path may be reading: the owner keeps the region
  mapped for life and swaps bindings atomically (old binding freed only after a
  grace period / never).
