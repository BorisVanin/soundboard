# Architecture

How Soundboard captures, mixes, and delivers audio — and the macOS constraints
that shaped the design.

## How it works

The app is the **mixer**. It captures sources, sums them in software, and hands the
finished single stream to the driver over shared memory:

```
   mic ──► MicSoundLane ─┐
                         ├─► MixEngine (vDSP sum) ──► driver-owned shmem ring ──► "Soundboard" loopback (captured by any app)
system audio (tap) ──► MacSoundLane ┘                       │
                                                            ├─► MixMonitor  ──► chosen output device (what you hear)
                                                            └─► MixRecorder ──► ~/Music/Soundboard/*.wav
```

Each source is a **lane** (`MicSoundLane`, `MacSoundLane`) that captures on its own
clock, applies its own gain/mute and peak metering, and writes interleaved-stereo
float into a small per-lane SPSC ring. A high-QoS mix timer reads every active
lane, **vDSP-sums** them, and writes the result into the driver's shared-memory
ring (`shmem.md`). The same finished mix is *teed* to the monitor and
the recorder, so they stay byte-identical to the loopback feed and keep flowing even
when nothing is draining the ring.

System audio is captured with a **process tap** (`MacSoundLane`), so the app never
creates a Multi-Output Device or changes the system's default output — the Mac
picker only chooses which output device's audio to *read* (tapping is read-only).

The driver **owns** the shared-memory region: it creates, sizes, and destroys it,
and treats its geometry as trusted constants so a buggy client can't make the
realtime consumer read out of bounds. The app is a transient client that discovers
the region through custom HAL properties, attaches, and claims a session. See
[`shmem.md`](shmem.md) for the full protocol.

## Modules

Each module is a standalone XcodeGen project (its own `project.yml`), tied
together by `Soundboard.xcworkspace`.

| Module | Type | Responsibility |
|--------|------|----------------|
| `MixerModel` | framework | Serializable persistence (`PersistedConfig`, `ChannelSetting`) for levels/mutes, the tap source, mic + monitor selection, and window/meter state. |
| `MixerEngine` | framework | The mixer. `MixEngine` (shmem-ring client + vDSP mixer), the `SoundLane`s (`MicSoundLane`, `MacSoundLane`) and their per-lane buffers, `MixMonitor` (play the mix to an output device), `MixRecorder` (mix → `.wav`), plus device discovery (`AudioDevices`) and the system-output probe (`AudioProcesses`). |
| `MIDISurface` | framework | CoreMIDI client + UMP decoder. Emits every control as `(deviceID, controlID, value)` to one `onValue` callback; listens to all sources. |
| `DriverControl` | framework | Cross-process HAL client for the loopback device — reads its output level meters (`Levels`) via the custom HAL property. |
| `LoopbackDriver` | bundle (`.driver`) | From-scratch **AudioServerPlugIn** (C++) publishing the virtual "Soundboard" device. Owns the POSIX shared-memory mix ring (`RingOwner`) and exposes it via custom HAL properties; loaded out-of-process by `coreaudiod`. |
| `SoundboardApp` | application | SwiftUI menu-bar + window console. One `MIDIFader`/`MIDIButton` per control, a `MidiRouter`, per-line MIDI-learn (`AssignmentStore`), the clutch, media-key transport (`MediaControl`), and a `soundboardctl` remote-control listener. |

### Dependency graph

```
MixerModel ──┐
MixerEngine ─┼─► SoundboardApp
MIDISurface ─┤
DriverControl┘
LoopbackDriver  (standalone; loaded by coreaudiod, addressed by MixEngine/DriverControl over the HAL)
```

## Control flow

```
 fader / button (UI drag)            physical MIDI control
        │                                     │
        ▼                                     ▼
   MIDIFader.rawValue / MIDIButton.press()   MIDISurface.onValue(dev, ctrl, value)
        │                                     │
        │                              MidiRouter → the bound control
        ▼                                     ▼
   onAction  ──(clutch engaged?)──►  MixEngine (gain/mute, mic/tap) / MediaControl / record / monitor
                     │
                 disengaged → nothing reaches audio ("everything works, goes nowhere")
```

- **Clutch:** a single switch on the model gates every line's `onAction`. *Assign
  mode* disengages it, so MIDI/UI still move the on-screen controls but no audio
  changes; the pre-assign positions are restored on exit.
- **MIDI-learn:** in assign mode, double-click a control's chip, then move a MIDI
  control — it binds that `(deviceID, controlID)` to the line and persists it
  (`AssignmentStore`, keyed by a stable per-line id).
- **Buttons** (mutes / mic on-off / record / monitor / media) fire on the press
  edge; mutes/toggles are sticky, media keys are one-shot triggers.
- **Record** and **Monitor** are themselves assignable controls: a fader/button on
  the surface can start/stop the `.wav` recording or toggle monitoring, exactly like
  the on-screen buttons.

## Apple constraints baked into this design

- Virtual device uses **AudioServerPlugIn** (userspace), *not* kexts (dead) or
  AudioDriverKit (Apple won't grant virtual-device entitlements for it). No special
  entitlement is needed — only code signing + notarization for distribution, since
  the driver loads out-of-process in `coreaudiod`.
- The app delivers audio to the driver over **POSIX shared memory** the driver
  creates inside `coreaudiod`; no mach ports. Sharing across the uid boundary works
  because the region is created `0666` (via `umask(0)`, since `fchmod` on a shm
  object is `EINVAL` on macOS).
- Capturing **system audio** uses a Core Audio process tap, which requires the
  `NSAudioCaptureUsageDescription` (audio-capture TCC) — distinct from the mic grant.
- Monitoring the **microphone** triggers the audio-recording **TCC** prompt.
- Posting the system media keys may require granting the app
  **Accessibility / Input-Monitoring** the first time.

## Further reading

- [`shmem.md`](shmem.md) — the shared-memory ring contract.
- [protocol.md](protocol.md) — the driver↔app HAL protocol.
- [zipper-noise.md](zipper-noise.md) — the fader gain-smoothing fix and the signal theory behind it.
