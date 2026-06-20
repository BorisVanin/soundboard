//
//  engine_harness — a headless CLI that drives the real MixerEngine code paths
//  (the same `MixEngine` / `MacSoundLane` / `MicSoundLane` the app uses) without
//  launching the GUI app. Compiled by linking ALL of MixerEngine/src together
//  with this driver, so it exercises the production capture/mix logic directly.
//
//  Build/run:  tests/engine_harness.sh <mode> [seconds] [micUID]
//
//  Modes:
//    mac            isolated system-audio tap (MacSoundLane → a LaneBuffer, no ring)
//    engine         full MixEngine: attaches the driver ring + runs the Mac lane
//    mic <uid>      isolated mic capture (MicSoundLane → a LaneBuffer, no ring)
//
//  Purpose: reproduce/diagnose "Mac VU shows no activity" in a fast, app-free loop.
//  Run it, play some system audio, and watch the printed VU.
//
import Foundation
import AVFoundation

// When launched detached (e.g. as an .app bundle via `open`), stdout goes nowhere;
// mirror every line to the file named by EH_OUT so the run is still observable.
private let outFile: FileHandle? = ProcessInfo.processInfo.environment["EH_OUT"].flatMap { path in
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}
private func say(_ s: String) {
    print(s)
    outFile?.write(Data((s + "\n").utf8))
}

private func dbfs(_ v: Float) -> String { v <= 1e-7 ? "  -inf" : String(format: "%6.1f", 20 * log10f(v)) }

private func drain(_ buffer: LaneBuffer) {
    let avail = buffer.available
    guard avail > 0 else { return }
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: avail * 2)
    scratch.initialize(repeating: 0, count: avail * 2)
    buffer.readAdd(into: scratch, frames: avail)
    scratch.deallocate()
}

private func poll(_ name: String, _ meters: () -> LaneMeters,
                  seconds: Double, drainTo buffer: LaneBuffer?) {
    say("== \(name): running \(seconds)s — play system audio now ==")
    var peakSeen: Float = 0
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.25)
        if let buffer { drain(buffer) }            // mimic the mixer consuming the lane
        let m = meters()
        peakSeen = max(peakSeen, max(m.left, m.right))
        say("VU \(name): count=\(m.count)  L=\(dbfs(m.left)) dBFS  R=\(dbfs(m.right)) dBFS")
    }
    say("== \(name): done. max peak over run = \(dbfs(peakSeen)) dBFS "
          + (peakSeen > 1e-5 ? "→ CAPTURED AUDIO ✅" : "→ SILENCE ❌"))
}

let args = Array(CommandLine.arguments.dropFirst())
let mode = args.first ?? "mac"
let seconds = (args.count > 1 ? Double(args[1]) : nil) ?? 8

// The system-audio tap is gated by the AudioCapture TCC service (kTCCServiceAudioCapture),
// NOT the microphone — the host bundle needs NSAudioCaptureUsageDescription in its
// Info.plist or coreaudiod silently feeds the tap zeros (no prompt). Creating the tap
// triggers that prompt when the key is present. Mic status is shown only for contrast.
say("mic TCC status: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) "
    + "(0=notDetermined 1=restricted 2=denied 3=authorized) — irrelevant to the tap")

switch mode {
case "mac":
    // mac [seconds] [gain 0..1] [mute 0|1] — gain/mute let you confirm the VU is post-fader.
    // EH_DEV=<output-device-UID> scopes the tap to one device ("" = all system output).
    let gain = (args.count > 2 ? Float(args[2]) : nil) ?? 1
    let muted = args.count > 3 && (args[3] == "1" || args[3] == "mute")
    let source = ProcessInfo.processInfo.environment["EH_DEV"] ?? ""
    let buffer = LaneBuffer(frames: 8192)
    let lane = MacSoundLane()
    do { try lane.start(source: source, channels: [], sink: buffer.sink) }
    catch { FileHandle.standardError.write(Data("MacSoundLane.start failed: \(error)\n".utf8)); exit(1) }
    lane.setGain(gain, muted: muted)
    say("mac source=\(source.isEmpty ? "<all system output>" : source) gain=\(gain) muted=\(muted)")
    poll("mac", lane.consumeMeters, seconds: seconds, drainTo: buffer)
    lane.stop()

case "mic":
    guard args.count > 2 else { FileHandle.standardError.write(Data("usage: mic <seconds> <micUID>\n".utf8)); exit(2) }
    let uid = args[2]
    let chans = Array(0..<max(AudioDevices.deviceID(forUID: uid).map(AudioDevices.inputChannelCount) ?? 1, 1))
    let buffer = LaneBuffer(frames: 8192)
    let lane = MicSoundLane()
    do { try lane.start(source: uid, channels: chans, sink: buffer.sink) }
    catch { FileHandle.standardError.write(Data("MicSoundLane.start failed: \(error)\n".utf8)); exit(1) }
    lane.setGain(1, muted: false)
    poll("mic", lane.consumeMeters, seconds: seconds, drainTo: buffer)
    lane.stop()

case "engine":
    // EH_DEV=<output-device-UID> scopes the tap; default "" = all system output.
    let engine = MixEngine()
    engine.setMacSource(ProcessInfo.processInfo.environment["EH_DEV"] ?? "")
    engine.setMacGain(1, muted: false)
    say("MixEngine.isRunning = \(engine.isRunning) (false ⇒ ring attach or tap start failed — check logs)")
    poll("engine-mac", engine.consumeMacMeters, seconds: seconds, drainTo: nil)
    engine.stop()

default:
    FileHandle.standardError.write(Data("unknown mode '\(mode)'. use: mac | engine | mic\n".utf8)); exit(2)
}
