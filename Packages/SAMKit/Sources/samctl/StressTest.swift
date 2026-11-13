// samctl stress-removal: regression test for the driver's device teardown.
//
// Creates a temporary aggregate device over the built-in speakers, points a
// test proxy at it, plays silence through the proxy (so the driver forwards to
// the aggregate) and destroys the aggregate while it runs, like unplugging a
// device mid-playback. After each removal the driver must still answer: its
// status has to show the test proxy as unpublished within a few seconds. A
// driver whose control queue deadlocks during teardown (fixed in 0.1.2) never
// updates its status again.

import CoreAudio
import Foundation
import SAMKit

private let aggregateUID = "dev.codejo.sam.stress.target"
private let aggregateName = "SAM Stress Target"

func stressTargetRemoval(cycles: Int) throws {
    guard DriverLink.isInstalled else { fail("Driver not loaded. Install it first.") }
    guard let speakers = AudioHardware.snapshot().devices.first(where: { $0.transport == .builtIn && $0.isOutput })
    else { fail("No built-in output to build the test device from.") }

    destroyAggregateIfPresent()
    var aggregate = try createAggregate(over: speakers.uid)
    let proxy = try addTestProxy()
    defer {
        destroyAggregateIfPresent()
        if let config = try? DriverLink.readConfig() {
            try? DriverLink.writeConfig(config.filter { $0.uid != proxy.uid })
        }
        print("Removed the test device and proxy.")
    }

    for cycle in 1...cycles {
        if cycle > 1 {
            aggregate = try createAggregate(over: speakers.uid)
        }
        guard let proxyID = waitFor(seconds: 5, { deviceID(uid: proxy.uid) }) else {
            fail("cycle \(cycle): the test proxy was not published")
        }
        let client = try SilentClient(device: proxyID)
        guard waitFor(seconds: 5, { status(of: proxy.uid)?.targetRunning == true ? true : nil }) != nil else {
            client.stop()
            fail("cycle \(cycle): the driver did not start forwarding")
        }

        // Pull the device away while audio flows through the proxy.
        let destroyed = AudioHardwareDestroyAggregateDevice(aggregate)
        guard destroyed == noErr else { fail("could not destroy the test device: \(destroyed)") }

        let alive = waitFor(seconds: 5, { status(of: proxy.uid)?.published == false ? true : nil }) != nil
        client.stop()
        guard alive else {
            fail("cycle \(cycle): the driver stopped responding after the device was removed (control queue stuck)")
        }
        print("cycle \(cycle)/\(cycles): forwarding, removed, driver responsive")
    }
    print("Passed: \(cycles) removals while forwarding.")
}

private func status(of uid: String) -> ProxyStatus? {
    (try? DriverLink.readStatus())?.first { $0.uid == uid }
}

private func addTestProxy() throws -> ProxyConfig {
    let proxy = ProxyConfig(
        uid: ProxyConfig.makeUID(),
        name: "SAM Stress Proxy",
        targetUID: aggregateUID,
        targetName: aggregateName
    )
    try DriverLink.writeConfig(try DriverLink.readConfig() + [proxy])
    return proxy
}

private func createAggregate(over subDeviceUID: String) throws -> AudioObjectID {
    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: aggregateName,
        kAudioAggregateDeviceUIDKey: aggregateUID,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: subDeviceUID]],
        kAudioAggregateDeviceMainSubDeviceKey: subDeviceUID,
        kAudioAggregateDeviceIsPrivateKey: 0,
        kAudioAggregateDeviceIsStackedKey: 0,
    ]
    var id = AudioObjectID(kAudioObjectUnknown)
    let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
    guard status == noErr else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "could not create the test device (\(status))"])
    }
    return id
}

private func destroyAggregateIfPresent() {
    if let id = deviceID(uid: aggregateUID) {
        AudioHardwareDestroyAggregateDevice(id)
    }
}

private func deviceID(uid: String) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var cfUID = uid as CFString
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafePointer(to: &cfUID) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                   UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
    }
    return status == noErr && id != kAudioObjectUnknown ? id : nil
}

private func waitFor<T>(seconds: Double, _ check: () -> T?) -> T? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let value = check() {
            return value
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return check()
}

/// Plays silence to a device through an IOProc, like any audio app would.
private final class SilentClient {
    private let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    init(device: AudioObjectID) throws {
        self.device = device
        let queue = DispatchQueue(label: "dev.codejo.samctl.silence")
        // The HAL clears output buffers before calling the IOProc.
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { _, _, _, _, _ in }
        if status == noErr, let procID {
            status = AudioDeviceStart(device, procID)
        }
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "could not play to the test proxy (\(status))"])
        }
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }
}
