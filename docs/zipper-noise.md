# Fader gain smoothing (zipper-noise fix)

Sweeping a lane fader (e.g. min→max in ~1 s) used to produce faint cracking/static —
a textbook **zipper noise** artifact, not a bug in the capture path. The lanes now
de-zipper gain per sample; this document records the diagnosis and the fix.

**Cause.** The lane IOProcs originally applied gain *block-wise*: they read the lane
gain **once per buffer** and multiplied every frame in that buffer by that single held
value, with no per-sample smoothing. While the fader moves, the held value jumps
between buffers, so the *applied gain envelope* is a staircase — a step discontinuity
at every buffer boundary.

**Fix.** Both lanes (`MixerEngine/src/MacSoundLane.swift`, `MicSoundLane.swift`)
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
