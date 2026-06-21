//
//  soundboardctl.swift — log access + driver control for Soundboard.
//
//  Reads the unified logs and reads/writes the driver's custom HAL control
//  properties directly (cross-process, via the public Core Audio API) — no
//  coreaudiod risk. (An older DistributedNotificationCenter remote-control path
//  was removed: macOS didn't deliver it reliably.)
//
//  Build:
//    swiftc -O tools/soundboardctl.swift -framework Foundation -framework CoreAudio -o /tmp/soundboardctl
//  Examples:
//    soundboardctl logs all                 # stream app + driver logs
//    soundboardctl logs driver              # stream only the driver (coreaudiod) logs
//    soundboardctl logs app --last 5m       # last 5 minutes of app logs (history)
//    soundboardctl stats on | off           # toggle the app's occupancy logging
//    soundboardctl get                      # print the driver state + current values
//
import Foundation
import CoreAudio

let kSubsystem = "ca.borisvanin.soundboard"
let kSystemDeviceUID = "ca.borisvanin.soundboard.system"   // the "Soundboard System" output device
let kProp_StatsLog: AudioObjectPropertySelector  = 0x73626C67  // 'sblg'

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    soundboardctl — logs + driver control for Soundboard
      logs [app|driver|all] [--last <dur>]   stream live logs, or show history with --last (e.g. 5m, 2h)
      stats on|off                           toggle the app's per-second buffer-occupancy logging
      get                                    print the driver state + current values

    Notes: 'driver' = the in-coreaudiod plug-in (category=driver); 'app' = everything else.
           stats/get talk to the driver directly via the HAL (the driver must be installed);
           the app must be running for 'stats' to take effect.
    """.appending("\n").utf8))
    exit(2)
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}

/// Resolve the "Soundboard System" device by UID via the HAL.
func systemDeviceID() -> AudioDeviceID {
    var uid = kSystemDeviceUID as CFString
    var dev = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    let status = withUnsafeMutablePointer(to: &uid) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   UInt32(MemoryLayout<CFString>.size), $0, &size, &dev)
    }
    guard status == noErr, dev != AudioDeviceID(kAudioObjectUnknown) else {
        die("‘Soundboard System’ device not found — is the driver installed?")
    }
    return dev
}

/// Read a custom UInt32 control property (marshaled as CFData) from a device.
func readCustomU32(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: selector,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var unmanaged: Unmanaged<CFData>?
    var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
    let status = withUnsafeMutablePointer(to: &unmanaged) {
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
    }
    guard status == noErr, let data = unmanaged?.takeRetainedValue(), CFDataGetLength(data) >= 4 else { return nil }
    var value: UInt32 = 0
    withUnsafeMutableBytes(of: &value) { CFDataGetBytes(data, CFRange(location: 0, length: 4),
                                                        $0.bindMemory(to: UInt8.self).baseAddress) }
    return value
}

/// Read a plain scalar property of type `T` from a device in the given scope.
func readScalar<T>(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                   scope: AudioObjectPropertyScope, _ initial: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

/// Set a custom UInt32 control property (marshaled as CFData) on the system device.
func setControl(_ selector: AudioObjectPropertySelector, _ value: UInt32) {
    let dev = systemDeviceID()
    var v = value
    guard let data = withUnsafeBytes(of: &v, {
        CFDataCreate(nil, $0.bindMemory(to: UInt8.self).baseAddress, 4)
    }) else { die("failed to allocate property payload") }
    var cfData: CFData = data
    var addr = AudioObjectPropertyAddress(mSelector: selector,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    let status = withUnsafePointer(to: &cfData) {
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<CFData>.size), $0)
    }
    if status != noErr { die("set property failed: OSStatus \(status)") }
}

guard let cmd = args.first else { usage() }

switch cmd {
case "logs":
    let target = args.count > 1 && !args[1].hasPrefix("-") ? args[1] : "all"
    var predicate = "subsystem == \"\(kSubsystem)\""
    switch target {
    case "driver": predicate += " && category == \"driver\""
    case "app":    predicate += " && category != \"driver\""
    case "all":    break
    default:       usage()
    }
    var logArgs: [String]
    if let i = args.firstIndex(of: "--last"), i + 1 < args.count {
        logArgs = ["show", "--last", args[i + 1], "--predicate", predicate, "--info", "--color", "always"]
    } else {
        print("== streaming \(target) logs (subsystem \(kSubsystem)); Ctrl-C to stop ==")
        logArgs = ["stream", "--predicate", predicate, "--info", "--color", "always"]
    }
    // exec `log` directly, replacing this process — so Ctrl-C reaches `log` itself
    // and can never leave an orphaned `log stream` behind. (A child Process would
    // be spawned in its own process group, which Ctrl-C in the terminal misses.)
    let argv = ["/usr/bin/log"] + logArgs
    var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cargs.append(nil)
    execv("/usr/bin/log", cargs)
    perror("execv /usr/bin/log")            // only reached if exec fails
    exit(1)

case "stats":
    guard args.count > 1, args[1] == "on" || args[1] == "off" else { usage() }
    setControl(kProp_StatsLog, args[1] == "on" ? 1 : 0)
    print("occupancy logging \(args[1])")

case "get", "show":
    let dev = systemDeviceID()
    let stats = readCustomU32(dev, kProp_StatsLog)
    let size  = readScalar(dev, kAudioDevicePropertyBufferFrameSize, scope: kAudioObjectPropertyScopeGlobal, UInt32(0))
    let range = readScalar(dev, kAudioDevicePropertyBufferFrameSizeRange, scope: kAudioObjectPropertyScopeGlobal, AudioValueRange())
    let vol   = readScalar(dev, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, Float32(0))
    func na<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "n/a" }
    print("Soundboard System (\(kSystemDeviceUID)) — device id \(dev)")
    if let range {
        print(String(format: "  IO buffer size    : %@ frames   (range %.0f–%.0f, set by coreaudiod)",
                     na(size), range.mMinimum, range.mMaximum))
    } else {
        print("  IO buffer size    : \(na(size)) frames")
    }
    print(String(format: "  system volume     : %@", vol.map { String(format: "%.2f", $0) } ?? "n/a"))
    print("  occupancy logging : \((stats ?? 0) != 0 ? "on" : "off")")

default:
    usage()
}
