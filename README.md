# Soundboard

> [!IMPORTANT]
> **🤖 This entire project was written by Claude — Anthropic's Claude Opus 4.8 —
> working in Claude Code.** Every line of source, the build system, the docs, and
> this README were authored by the model under human direction. Keep that in mind
> when reading, reusing, or auditing the code.

A software + hardware audio mixing console for macOS. A physical MIDI control
surface (faders/buttons) drives a live mix: the app captures your microphone and
everything your Mac plays, blends them in software, and feeds the result to a
from-scratch virtual **loopback** device (so any app/recorder can pick up the mix),
to an optional **monitor** output (so you can hear it), and to an optional **`.wav`
recording**. Transport keys (Play/Pause, Next, Prev) and every fader/mute are
MIDI-assignable.

Everything here is written from scratch — no forks of BlackHole, deej, etc.

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
ring (`LoopbackDriver/SHMEM.md`). The same finished mix is *teed* to the monitor and
the recorder, so they stay byte-identical to the loopback feed and keep flowing even
when nothing is draining the ring.

System audio is captured with a **process tap** (`MacSoundLane`), so the app never
creates a Multi-Output Device or changes the system's default output — the Mac
picker only chooses which output device's audio to *read* (tapping is read-only).

The driver **owns** the shared-memory region: it creates, sizes, and destroys it,
and treats its geometry as trusted constants so a buggy client can't make the
realtime consumer read out of bounds. The app is a transient client that discovers
the region through custom HAL properties, attaches, and claims a session. See
[`LoopbackDriver/SHMEM.md`](LoopbackDriver/SHMEM.md) for the full protocol.

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

## Build

Requires [Mint](https://github.com/yonaskolb/Mint) + XcodeGen (pinned in `Mintfile`).

**Set your Apple Developer Team ID first.** Every module signs against the
`DEVELOPMENT_TEAM` environment variable (and `BUNDLE_IDENTIFIER`, which defaults
to `ca.borisvanin.soundboard`); XcodeGen substitutes both into each `project.yml`
at generation time. `make generate` **refuses to run** with an empty team, so
projects are never emitted with a blank signing identity.

These build vars are loaded from a gitignored `.envrc` via
[direnv](https://direnv.net), so every `make` invocation shares one source of truth.
Install direnv (`brew install direnv`, then add the shell hook, e.g.
`eval "$(direnv hook zsh)"` in `~/.zshrc`), then:

```sh
cp .envrc.default .envrc   # then edit: set DEVELOPMENT_TEAM (Xcode ▸ Settings ▸ Accounts ▸ Team ID)
direnv allow               # one-time approval; direnv auto-loads .envrc on cd from now on
```

(Not using direnv? Just `export DEVELOPMENT_TEAM=ABCDE12345` in your shell instead
— `.envrc` is a plain `export` script, so `source .envrc` also works as a fallback.)

You need a team because the loopback driver loads out-of-process in `coreaudiod`
and must be code-signed (and notarized for distribution). Then:

```sh
make              # bootstrap Mint, then generate every module's .xcodeproj + the workspace
make open         # open Soundboard.xcworkspace
make scratch      # clean + regenerate + open
make install-driver   # build, sign, and install the loopback driver (sudo; restarts coreaudiod)
make installer    # build a signed double-clickable .pkg into dist/ (app → /Applications, driver → HAL)
make test         # unit tests for the driver's shared-memory ring + protocol
make tools        # build the dev CLI tools (soundboardctl, tap_feed, make_icon) into dist/
```

Frameworks are generated before their consumers (projectReferences need the
referenced `.xcodeproj` on disk). Order is encoded in the `Makefile`.

## Codesigning

Every target uses **manual signing** (`CODE_SIGN_STYLE: Manual` in each
`project.yml`), and Xcode picks the certificate per build configuration:

| Configuration | `CODE_SIGN_IDENTITY` | Used for |
|---------------|----------------------|----------|
| **Debug**     | `Apple Development`   | local build + run in Xcode |
| **Release**   | `Developer ID Application` | the distributable `.app` + loopback driver |

Because the app bundles a CoreAudio HAL driver it ships **Developer ID** (direct
distribution + notarization) — it cannot go through the Mac App Store. The two
identities you need in your keychain:

- **Developer ID Application** — signs the Release `.app` and the loopback driver
- **Developer ID Installer** — signs the distributable `.pkg`

Get them from the [Apple Developer portal](https://developer.apple.com/account/resources/certificates)
(Certificates ▸ +) or via Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates, then
verify they're installed:

```sh
security find-identity -v -p codesigning     # should list both Developer ID certs + Apple Development
```

`make installer` (→ `installer/build-pkg.sh`) builds Release, signs the `.app` +
driver with **Developer ID Application** (hardened runtime + secure timestamp),
signs the `.pkg` with **Developer ID Installer**, and writes it to `dist/`. The
identities default to a prefix match against the single Developer ID certs in your
keychain; if you have more than one, override them:

```sh
APP_SIGN_ID="Developer ID Application: NAME (TEAMID)" \
  INSTALLER_SIGN_ID="Developer ID Installer: NAME (TEAMID)" \
  make installer
```

To distribute to other Macs, notarize + staple the finished `.pkg` — see the
NOTARIZATION note at the bottom of `installer/build-pkg.sh`.

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

## Fader gain smoothing (zipper-noise fix)

Sweeping a lane fader (e.g. min→max in ~1 s) used to produce faint cracking/static —
a textbook **zipper noise** artifact, not a bug in the capture path. The lanes now
de-zipper gain per sample; this section records the diagnosis and the fix.

**Cause.** The lane IOProcs originally applied gain *block-wise*: they read the lane
gain **once per buffer** and multiplied every frame in that buffer by that single held
value, with no per-sample smoothing. While the fader moves, the held value jumps
between buffers, so the *applied gain envelope* is a staircase — a step discontinuity
at every buffer boundary.

**Fix.** Both lanes (`MixerEngine/Sources/MacSoundLane.swift`, `MicSoundLane.swift`)
now ramp the applied gain toward the target **per sample** with a one-pole smoother
`g += α·(target − g)` (`gainSmoothingAlpha` in `SoundLane.swift`, τ ≈ 10 ms). The
applied-gain envelope is continuous, so the discontinuity — and its broadband
splatter — is gone. `gainPtr` holds the target; a separate smoothed value, owned by
the RT IOProc, is what actually multiplies the audio. This also de-clicks mute/unmute.

**Why a step is audible (the science).** Applying a time-varying gain `g[n]` to a
signal `x[n]` is multiplication in time, i.e. **convolution in frequency**:
`Y(f) = X(f) ∗ G(f)`. A smooth, slowly-varying gain has its spectral energy packed
near DC, so it only adds a narrow skirt around the signal. A *staircase* gain is
discontinuous: a step's spectrum rolls off only as ~`1/f`, and a periodic staircase
(period = one buffer) puts energy at the buffer rate `fs/N` **and all its harmonics**.
Convolving that comb with the signal splatters energy across the whole band — the
broadband "spray" heard as clicks. This is spectral splatter from a discontinuity,
the same family as the Gibbs phenomenon. The standard fix is **de-zippering**:
interpolate gain per sample (a linear ramp across the block, or a one-pole smoother
`g += α·(target − g)`), which removes the discontinuity and its high-frequency energy.

**Measured evidence.** Detected with ffmpeg's research-backed `adeclick` filter (no
home-grown detector): `residual = original − adeclick(original)` isolates the clicks
it removed.

| signal | click bursts | burst spacing |
|---|---|---|
| real fader-sweep recording (old build) | 467 | 10.67 ms → **93.8 Hz** |
| synthetic block-constant (old algorithm) | 70 | 10.67 ms → **93.8 Hz** |
| synthetic one-pole de-zipper (shipped fix) | 1 | — (click-free) |

The clicks land at exactly `48000 / 512 = 93.75 Hz` — the IOProc's 512-frame buffer
rate — in both the real recording and the synthetic reproduction, confirming the
diagnosis; the de-zipper drops them to none. `tests/gain_tests.sh` regenerates the
WAVs and runs the `adeclick` gate (shipped sweep must be click-free; the old algorithm
is kept as a negative control that the detector still fires on).

**References.**
- U. Zölzer (ed.), *DAFX: Digital Audio Effects*, 2nd ed., Wiley, 2011 — parameter
  smoothing / control-rate interpolation to avoid zipper noise.
- J. O. Smith III, *Physical Audio Signal Processing*, CCRMA, Stanford — click-free
  gain changes via one-pole amplitude smoothing.
- A. J. E. M. Janssen, R. N. J. Veldhuis, L. B. Vries, "Adaptive interpolation of
  discrete-time signals that can be modeled as autoregressive processes," *IEEE
  Trans. ASSP* 34(2), 1986 — the AR click-interpolation model behind `adeclick`.
- S. J. Godsill, P. J. W. Rayner, *Digital Audio Restoration: A Statistical Model
  Based Approach*, Springer, 1998.

## Contributing

Contributions are welcome. To get a clean build going:

1. Install [Mint](https://github.com/yonaskolb/Mint) (`brew install mint`); the
   pinned XcodeGen comes from `Mintfile`.
2. `export DEVELOPMENT_TEAM=<your Apple Developer Team ID>` (see **Build** above) —
   generation fails without it, and the driver can't be signed/loaded without one.
3. `make scratch` to regenerate every module and open the workspace.
4. `make test` to run the shared-memory ring + protocol unit tests. Please keep
   these green and add coverage for protocol or ring changes.

Notes:
- The repo tracks **only sources** — generated `.xcodeproj`/`.xcworkspace`, `dist/`
  (build artifacts + the installer `.pkg`), and `.bin/` are git-ignored and recreated
  by `make`.
- Architecture lives in `docs/protocol.md` and `LoopbackDriver/SHMEM.md`; read the
  shmem-ring contract before touching the driver↔app boundary.
- Driver/HAL changes need `make install-driver` (sudo; restarts `coreaudiod`) to
  test end-to-end.
- Open an issue to discuss larger changes (new lanes, protocol revisions) before a PR.

## License

Licensed under the [Apache License 2.0](LICENSE). © 2026 Boris Vanin.

The code in this repository was written by Anthropic's **Claude Opus 4.8** via
Claude Code, under human direction.
