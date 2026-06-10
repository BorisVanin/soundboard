//
//  soundboardctl.swift — control + log access for Soundboard (app & driver).
//
//  Lets you (and the assistant) drive the running app and read logs without
//  touching coreaudiod or risking a wedge. Control commands are delivered to the
//  app via DistributedNotificationCenter (one-way, no sockets/cleanup); the app
//  observes them and acts on the main actor.
//
//  Build:
//    swiftc -O tools/soundboardctl.swift -framework Foundation -o /tmp/soundboardctl
//  Examples:
//    soundboardctl logs all                 # stream app + driver logs
//    soundboardctl logs driver              # stream only the driver (coreaudiod) logs
//    soundboardctl logs app --last 5m       # last 5 minutes of app logs (history)
//    soundboardctl mic on | off
//    soundboardctl gain 0.6
//    soundboardctl status                   # ask the app to log its current state
//    soundboardctl quit
//
import Foundation

let kSubsystem = "ca.borisvanin.soundboard"
let kCmdName   = "ca.borisvanin.soundboard.cmd"

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    soundboardctl — control + logs for Soundboard
      logs [app|driver|all] [--last <dur>]   stream live logs, or show history with --last (e.g. 5m, 2h)
      mic  on|off                            turn the mic strip on/off
      gain <0..1>                            set the mic gain
      status                                 ask the app to log its current state
      quit                                   quit the app

    Notes: 'driver' = the in-coreaudiod plug-in (category=driver); 'app' = everything else.
    """.appending("\n").utf8))
    exit(2)
}

func post(_ object: String) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(kCmdName), object: object, userInfo: nil, deliverImmediately: true)
    print("sent: \(object)  (the app must be running to receive it)")
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

case "mic":
    guard args.count > 1, args[1] == "on" || args[1] == "off" else { usage() }
    post("mic:\(args[1])")

case "gain":
    guard args.count > 1, let v = Float(args[1]), v >= 0, v <= 1 else { usage() }
    post("gain:\(v)")

case "status":
    post("status")           // the app logs its state; read it with: soundboardctl logs app

case "quit":
    post("quit")

default:
    usage()
}
