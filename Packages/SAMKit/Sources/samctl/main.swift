// samctl: inspect and configure the SimpleAudioManager driver from the shell.
//
//   swift run samctl devices
//   swift run samctl status
//   swift run samctl add <target-uid> [name] [--hardware]
//   swift run samctl rename <proxy-uid> <name>
//   swift run samctl remove <proxy-uid>
//   swift run samctl select <device-uid>

import Foundation
import SAMKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func printDevices() {
    let snapshot = AudioHardware.snapshot()
    for device in snapshot.devices {
        var flags: [String] = []
        if device.uid == snapshot.defaultOutputUID { flags.append("default-out") }
        if device.uid == snapshot.defaultSystemOutputUID { flags.append("system-out") }
        if device.uid == snapshot.defaultInputUID { flags.append("default-in") }
        if device.isProxy { flags.append("proxy") }
        if device.isOutput { flags.append(device.hasOutputVolume ? "volume" : "NO-VOLUME") }
        print("\(device.name)  [\(device.transport.displayName), out \(device.outputChannels), in \(device.inputChannels), \(Int(device.nominalSampleRate)) Hz] \(flags.joined(separator: " "))")
        print("    uid: \(device.uid)")
    }
}

func printStatus() throws {
    let config = try DriverLink.readConfig()
    let status = try DriverLink.readStatus()
    if config.isEmpty { print("No proxies configured.") }
    for proxy in config {
        print("\(proxy.name)  (\(proxy.uid))")
        print("    target: \(proxy.targetName) — \(proxy.targetUID)")
        print("    volume: \(proxy.volumeMode.rawValue)\(proxy.hidden ? ", hidden" : "")")
        if let s = status.first(where: { $0.uid == proxy.uid }) {
            print("    published: \(s.published), forwarding: \(s.targetRunning), \(Int(s.sampleRate)) Hz, \(s.channels) ch, latency \(String(format: "%.1f", s.latencyMilliseconds)) ms")
            print("    underruns: \(s.underruns), overruns: \(s.overruns), resyncs: \(s.resyncs), clock: \(String(format: "%+.1f", s.clockCorrectionPPM)) ppm")
            if let error = s.error { print("    error: \(error)") }
        }
    }
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "status" : args.removeFirst()

do {
    switch command {
    case "devices":
        printDevices()
    case "status":
        guard DriverLink.isInstalled else { fail("Driver not loaded. Install it first (make install).") }
        try printStatus()
    case "add":
        guard let targetUID = args.first else { fail("usage: samctl add <target-uid> [name] [--hardware]") }
        guard let target = AudioHardware.snapshot().device(uid: targetUID), target.isOutput else {
            fail("No output device with UID \(targetUID). Run `samctl devices`.")
        }
        var proxy = ProxyConfig.proxy(for: target)
        if args.count > 1, !args[1].hasPrefix("--") { proxy.name = args[1] }
        if args.contains("--hardware") { proxy.volumeMode = .hardware }
        try DriverLink.writeConfig(try DriverLink.readConfig() + [proxy])
        print("Added \(proxy.name) (\(proxy.uid))")
    case "rename":
        guard args.count == 2 else { fail("usage: samctl rename <proxy-uid> <name>") }
        var config = try DriverLink.readConfig()
        guard let index = config.firstIndex(where: { $0.uid == args[0] }) else { fail("Unknown proxy \(args[0])") }
        config[index].name = args[1]
        try DriverLink.writeConfig(config)
    case "remove":
        guard let uid = args.first else { fail("usage: samctl remove <proxy-uid>") }
        try DriverLink.writeConfig(try DriverLink.readConfig().filter { $0.uid != uid })
    case "select":
        guard let uid = args.first else { fail("usage: samctl select <device-uid>") }
        try AudioHardware.setDefault(.output, uid: uid)
        try AudioHardware.setDefault(.systemOutput, uid: uid)
    default:
        fail("unknown command \(command)")
    }
} catch {
    fail("error: \(error.localizedDescription)")
}
