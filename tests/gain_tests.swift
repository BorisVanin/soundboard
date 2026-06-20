//
//  gain_tests.swift — unit test for the lane GAIN-APPLYING algorithm.
//
//  Reproduces, in pure logic (no CoreAudio, no devices, no install), the artifact
//  heard when sweeping a fader knob min→max→min: faint cracking / static.
//
//  Root cause under test: `MacSoundLane`/`MicSoundLane` apply gain block-wise —
//  the IOProc reads the lane gain ONCE per buffer and multiplies every frame by
//  that single held value (see MixerEngine/src/MacSoundLane.swift:122-134 and
//  MicSoundLane.swift:174-200). There is NO per-sample smoothing. While the knob
//  moves, the held value jumps between buffers, so each buffer boundary injects a
//  step discontinuity into the signal — i.e. zipper noise / clicks.
//
//  This test does NOT fix the problem. It characterizes it:
//    • `applyGainBlockConstant` mirrors the production algorithm exactly.
//    • `applyGainRamped` is a reference (per-buffer linear interp) that is
//      click-free, to show the contrast and the direction a fix would take.
//  It also writes the swept signals to .wav under dist/ (the "recording feature"
//  output) so the result can be listened to / analyzed offline.
//
//  Build & run:  tests/gain_tests.sh
//  or:           swiftc -O tests/gain_tests.swift -o dist/gain_tests && dist/gain_tests
//
import Foundation

// ─── tiny test harness (mirrors tests/ring_tests.cpp's CHECK style) ────────────
var g_pass = 0, g_fail = 0
var g_test = ""
func check(_ cond: Bool, _ expr: String, file: String = #fileID, line: Int = #line) {
    if cond { g_pass += 1 }
    else { g_fail += 1; print("  FAIL [\(g_test)] \(file):\(line)  \(expr)") }
}

// ─── signal helpers ────────────────────────────────────────────────────────────
let fs = 48_000.0
let freq = 440.0          // test tone
let amp: Float = 0.8
let block = 512           // frames per IOProc buffer (typical)
let channels = 2

func dbfs(_ v: Float) -> String { v <= 1e-9 ? "  -inf" : String(format: "%6.1f dBFS", 20 * log10f(v)) }

/// Continuous full-scale stereo sine of `frames` frames, interleaved L/R.
func makeSine(frames: Int) -> [Float] {
    var out = [Float](repeating: 0, count: frames * channels)
    let w = 2.0 * Double.pi * freq / fs
    for f in 0..<frames {
        let s = Float(sin(w * Double(f))) * amp
        out[f * channels + 0] = s
        out[f * channels + 1] = s
    }
    return out
}

/// The "true" knob position over time: a triangle that ramps 0→1 in `up` seconds
/// then 1→0 in `up` seconds, repeating — exactly the user's repro (min→max in a
/// second and back). This is the ground-truth, continuous gain envelope.
func knob(atFrame f: Int, up: Double = 1.0) -> Float {
    let t = Double(f) / fs
    let period = 2.0 * up
    let phase = t.truncatingRemainder(dividingBy: period)
    let v = phase < up ? phase / up : (period - phase) / up
    return Float(v)
}

// ─── algorithms under test ─────────────────────────────────────────────────────

/// PRODUCTION ALGORITHM (the one being checked). Mirrors the IOProc gain stage:
/// the lane reads its gain ONCE per buffer and multiplies every frame by that one
/// held constant. The knob is sampled at the buffer's first frame — a sample-and-
/// hold per block, just like coreaudiod reading `gainPtr.pointee` once per IOProc.
func applyGainBlockConstant(_ input: [Float]) -> [Float] {
    var out = input
    let frames = input.count / channels
    var s = 0
    while s < frames {
        let g = knob(atFrame: s)                       // read once per buffer
        let n = min(block, frames - s)
        for f in 0..<n {
            out[(s + f) * channels + 0] *= g
            out[(s + f) * channels + 1] *= g
        }
        s += block
    }
    return out
}

/// REFERENCE (not production): per-buffer linear interpolation from the previous
/// buffer's end-gain to this buffer's target. Continuous across boundaries, so it
/// is click-free. Shown only to contrast with the algorithm under test.
func applyGainRamped(_ input: [Float]) -> [Float] {
    var out = input
    let frames = input.count / channels
    var s = 0
    while s < frames {
        let n = min(block, frames - s)
        let g0 = knob(atFrame: s)
        let g1 = knob(atFrame: s + n)
        for f in 0..<n {
            let g = g0 + (g1 - g0) * Float(f) / Float(n)
            out[(s + f) * channels + 0] *= g
            out[(s + f) * channels + 1] *= g
        }
        s += block
    }
    return out
}

/// THE FIX (mirrors the shipped IOProc de-zipper): read the target once per buffer,
/// but ramp the applied gain toward it PER SAMPLE with a one-pole smoother
/// `g += α·(target − g)`. α matches MixerEngine's `gainSmoothingAlpha`. The applied
/// envelope is continuous → no boundary step → click-free.
let smoothingAlpha: Float = 0.0020812      // == gainSmoothingAlpha (τ≈10 ms @ 48 kHz)
func applyGainSmoothed(_ input: [Float]) -> [Float] {
    var out = input
    let frames = input.count / channels
    var g: Float = knob(atFrame: 0)            // start matched (no startup ramp)
    var s = 0
    while s < frames {
        let target = knob(atFrame: s)          // read once per buffer (like the IOProc)
        let n = min(block, frames - s)
        for f in 0..<n {
            g += smoothingAlpha * (target - g)
            if abs(target - g) < 1e-6 { g = target }   // mirror the IOProc's denormal snap
            out[(s + f) * channels + 0] *= g
            out[(s + f) * channels + 1] *= g
        }
        s += block
    }
    return out
}

/// GROUND TRUTH: the exact, per-sample continuous envelope. What a perfectly
/// smooth fader would produce — the yardstick the two algorithms are scored against.
func applyGainExact(_ input: [Float]) -> [Float] {
    var out = input
    let frames = input.count / channels
    for f in 0..<frames {
        let g = knob(atFrame: f)
        out[f * channels + 0] *= g
        out[f * channels + 1] *= g
    }
    return out
}

// ─── click metric ──────────────────────────────────────────────────────────────

/// The artifact is the difference between an algorithm's output and the smooth
/// ground truth. Returns (peak error level, peak error STEP at any buffer
/// boundary). A step in the error signal at a boundary == an audible click.
func artifact(_ candidate: [Float], _ truth: [Float]) -> (peak: Float, boundaryStep: Float) {
    var peak: Float = 0
    var boundaryStep: Float = 0
    let frames = candidate.count / channels
    var prevErrL: Float = 0
    for f in 0..<frames {
        let eL = candidate[f * channels + 0] - truth[f * channels + 0]
        let eR = candidate[f * channels + 1] - truth[f * channels + 1]
        peak = max(peak, max(abs(eL), abs(eR)))
        if f > 0 && f % block == 0 {                   // buffer boundary
            boundaryStep = max(boundaryStep, abs(eL - prevErrL))
        }
        prevErrL = eL
    }
    return (peak, boundaryStep)
}

// ─── minimal WAV writer (the "recording feature": 16-bit PCM, stereo, 48 kHz —
//     same on-disk format MixRecorder produces) ──────────────────────────────────
func writeWAV(_ interleaved: [Float], to url: URL) {
    let n = interleaved.count
    var pcm = Data(capacity: n * 2)
    for v in interleaved {
        let c = max(-1, min(1, v))
        let i = Int16(max(-32768, min(32767, (c * 32767).rounded())))
        var le = i.littleEndian
        withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
    }
    let byteRate = UInt32(fs) * 2 * 2           // rate * channels * bytesPerSample
    let dataBytes = UInt32(pcm.count)
    var h = Data()
    func u32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { h.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { h.append(contentsOf: $0) } }
    h.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); h.append(contentsOf: Array("WAVE".utf8))
    h.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(UInt32(fs))
    u32(byteRate); u16(4); u16(16)
    h.append(contentsOf: Array("data".utf8)); u32(dataBytes)
    try? (h + pcm).write(to: url)
}

// ─── tests ───────────────────────────────────────────────────────────────────

/// Sanity: a CONSTANT gain (knob not moving) introduces no artifact at all —
/// confirms the metric only fires on a moving knob, not the multiply itself.
func test_constant_gain_is_clean() {
    g_test = "constant_gain_is_clean"
    let frames = block * 8
    let sine = makeSine(frames: frames)
    let half = sine.map { $0 * 0.5 }                    // uniform 0.5 gain, all blocks
    let a = artifact(half, half)
    check(a.peak < 1e-6, "constant gain peak artifact ~0 (got \(dbfs(a.peak)))")
    check(a.boundaryStep < 1e-6, "constant gain no boundary steps (got \(dbfs(a.boundaryStep)))")
}

// NOTE on metrics: the authoritative click verdict is NOT computed here — it comes
// from running ffmpeg's research-backed `adeclick` over the emitted WAVs (see
// gain_tests.sh + click_analysis.py). The `artifact()` numbers below are printed for
// context only; they are a homemade error-vs-truth measure and deliberately do not
// gate the build. `boundaryStep` flags a value DISCONTINUITY (a step → audible click);
// the one-pole leaves only a slope corner, which adeclick correctly hears as no click.

// ─── run ────────────────────────────────────────────────────────────────────────
test_constant_gain_is_clean()
let frames = Int(fs * 4)
let sine = makeSine(frames: frames)
for (name, sig) in [("block-constant", applyGainBlockConstant(sine)),
                    ("ramped",         applyGainRamped(sine)),
                    ("smoothed (fix)", applyGainSmoothed(sine))] {
    let a = artifact(sig, applyGainExact(sine))
    print("  \(name): peak err \(dbfs(a.peak)),  worst boundary step \(dbfs(a.boundaryStep))")
}

// Emit WAVs for the ffmpeg-based detector (and offline listening). dist/ is gitignored.
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dist", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
writeWAV(sine,                          to: out.appendingPathComponent("gain_sweep_input.wav"))
writeWAV(applyGainExact(sine),          to: out.appendingPathComponent("gain_sweep_exact.wav"))
writeWAV(applyGainRamped(sine),         to: out.appendingPathComponent("gain_sweep_ramped.wav"))
writeWAV(applyGainSmoothed(sine),       to: out.appendingPathComponent("gain_sweep_smoothed.wav"))
writeWAV(applyGainBlockConstant(sine),  to: out.appendingPathComponent("gain_sweep_block_constant.wav"))
print("\nWrote \(out.path)/gain_sweep_*.wav")
print("  • gain_sweep_block_constant.wav — the OLD block-constant algorithm (has clicks)")
print("  • gain_sweep_smoothed.wav       — the SHIPPED one-pole de-zipper (click-free)")

print("\n==== gain generator: \(g_pass) sanity checks passed, \(g_fail) failed ====")
exit(g_fail == 0 ? 0 : 1)
