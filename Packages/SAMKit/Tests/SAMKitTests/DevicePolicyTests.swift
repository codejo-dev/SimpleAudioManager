import CoreAudio
import Testing
@testable import SAMKit

private let speakers = AudioDevice(id: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", transport: .builtIn, outputChannels: 2, hasOutputVolume: true)
private let spdif = AudioDevice(id: 2, uid: "usb-spdif", name: "USB SPDIF Adapter", transport: .usb, outputChannels: 2)
private let hdmi = AudioDevice(id: 3, uid: "benq", name: "BenQ PD3200Q", transport: .hdmi, outputChannels: 2)
private let mic = AudioDevice(id: 4, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn, inputChannels: 1)
private let webcam = AudioDevice(id: 5, uid: "logi", name: "Logi 4K", transport: .usb, inputChannels: 2)
private let proxyConfig = ProxyConfig(uid: "dev.codejo.sam.proxy.A", name: "Living Room", targetUID: "usb-spdif", targetName: "USB SPDIF Adapter")
private let proxy = AudioDevice(id: 10, uid: "dev.codejo.sam.proxy.A", name: "Living Room", transport: .virtual, outputChannels: 2, canBeDefaultInput: false, hasOutputVolume: true)

private func snapshot(_ devices: [AudioDevice], output: String?, system: String? = nil, input: String? = nil) -> HardwareSnapshot {
    HardwareSnapshot(devices: devices, defaultOutputUID: output, defaultSystemOutputUID: system ?? output, defaultInputUID: input)
}

private func settings(hidden: Set<String> = [], autoSelect: Set<String> = [], fallback: String? = nil) -> AppSettings {
    var s = AppSettings()
    s.hiddenDeviceUIDs = hidden
    s.autoSelectOutputUIDs = autoSelect
    s.fallbackOutputUID = fallback
    return s
}

@Suite("Hide by redirect")
struct HideRedirectTests {
    @Test func selectingHiddenDeviceSwitchesToItsProxy() {
        let old = snapshot([speakers, spdif, proxy], output: "dev.codejo.sam.proxy.A")
        let new = snapshot([speakers, spdif, proxy], output: "usb-spdif")
        let result = DevicePolicy.evaluate(old: old, new: new, settings: settings(hidden: ["usb-spdif"]), proxies: [proxyConfig])
        #expect(result.actions == [
            .setDefault(.output, uid: "dev.codejo.sam.proxy.A"),
            .setDefault(.systemOutput, uid: "dev.codejo.sam.proxy.A"),
        ])
    }

    @Test func waitsForProxyThatIsNotPublishedYet() {
        let old = snapshot([speakers], output: "BuiltInSpeakerDevice")
        let new = snapshot([speakers, spdif], output: "usb-spdif")
        let s = settings(hidden: ["usb-spdif"])
        let first = DevicePolicy.evaluate(old: old, new: new, settings: s, proxies: [proxyConfig])
        #expect(first.actions.isEmpty)
        #expect(first.waitingForProxy)

        // Proxy never showed up: go back to what the user had.
        let later = DevicePolicy.evaluate(old: old, new: new, settings: s, proxies: [proxyConfig], proxyGraceElapsed: true)
        #expect(later.actions.contains(.setDefault(.output, uid: "BuiltInSpeakerDevice")))
    }

    @Test func hiddenDeviceWithoutProxyFallsBackToPreviousChoice() {
        let old = snapshot([speakers, hdmi], output: "BuiltInSpeakerDevice")
        let new = snapshot([speakers, hdmi], output: "benq")
        let result = DevicePolicy.evaluate(old: old, new: new, settings: settings(hidden: ["benq"]), proxies: [])
        #expect(result.actions.first == .setDefault(.output, uid: "BuiltInSpeakerDevice"))
    }

    @Test func fallbackIsUsedWhenPreviousChoiceIsGone() {
        let new = snapshot([speakers, hdmi, spdif], output: "benq")
        let result = DevicePolicy.evaluate(old: nil, new: new, settings: settings(hidden: ["benq"], fallback: "usb-spdif"), proxies: [])
        #expect(result.actions.first == .setDefault(.output, uid: "usb-spdif"))
    }

    @Test func neverRedirectsToAnotherHiddenOrDeadDevice() {
        var deadSpeakers = speakers
        deadSpeakers.isAlive = false
        let new = snapshot([deadSpeakers, hdmi, spdif], output: "benq")
        let result = DevicePolicy.evaluate(old: nil, new: new, settings: settings(hidden: ["benq", "usb-spdif"]), proxies: [])
        #expect(result.actions.isEmpty)
    }

    @Test func hiddenInputRedirectsToVisibleInput() {
        let old = snapshot([speakers, mic, webcam], output: "BuiltInSpeakerDevice", input: "BuiltInMicrophoneDevice")
        let new = snapshot([speakers, mic, webcam], output: "BuiltInSpeakerDevice", input: "logi")
        let result = DevicePolicy.evaluate(old: old, new: new, settings: settings(hidden: ["logi"]), proxies: [])
        #expect(result.actions == [.setDefault(.input, uid: "BuiltInMicrophoneDevice")])
    }

    @Test func noActionWhenNothingHiddenIsSelected() {
        let state = snapshot([speakers, spdif, proxy], output: "dev.codejo.sam.proxy.A")
        let result = DevicePolicy.evaluate(old: state, new: state, settings: settings(hidden: ["usb-spdif"]), proxies: [proxyConfig])
        #expect(result == PolicyResult())
    }
}

@Suite("Proxy hides its target")
struct ProxyHidesTargetTests {
    @Test func proxiedDeviceRedirectsWithoutExplicitHide() {
        let old = snapshot([speakers, spdif, proxy], output: "BuiltInSpeakerDevice")
        let new = snapshot([speakers, spdif, proxy], output: "usb-spdif")
        let result = DevicePolicy.evaluate(old: old, new: new, settings: AppSettings(), proxies: [proxyConfig])
        #expect(result.actions.first == .setDefault(.output, uid: proxy.uid))
    }

    @Test func proxiedDeviceIsNotInThePicker() {
        let state = snapshot([speakers, spdif, proxy], output: nil)
        let visible = DevicePolicy.visibleDevices(for: .output, in: state, settings: AppSettings(), proxies: [proxyConfig])
        #expect(!visible.map(\.uid).contains("usb-spdif"))
        #expect(visible.map(\.uid).contains(proxy.uid))
    }
}

@Suite("Auto-select")
struct AutoSelectTests {
    @Test func proxyIsSelectedWhenItAppears() {
        let old = snapshot([speakers], output: "BuiltInSpeakerDevice")
        let new = snapshot([speakers, spdif, proxy], output: "BuiltInSpeakerDevice")
        let result = DevicePolicy.evaluate(old: old, new: new, settings: settings(autoSelect: [proxy.uid]), proxies: [proxyConfig])
        #expect(result.actions == [
            .setDefault(.output, uid: proxy.uid),
            .setDefault(.systemOutput, uid: proxy.uid),
        ])
    }

    @Test func systemOutputStaysWhenItDidNotFollowTheDefault() {
        let old = snapshot([speakers, hdmi], output: "BuiltInSpeakerDevice", system: "benq")
        let new = snapshot([speakers, hdmi, proxy], output: "BuiltInSpeakerDevice", system: "benq")
        let result = DevicePolicy.evaluate(old: old, new: new, settings: settings(autoSelect: [proxy.uid]), proxies: [proxyConfig])
        #expect(result.actions == [.setDefault(.output, uid: proxy.uid)])
    }

    @Test func physicalDeviceCanAutoSelectToo() {
        let old = snapshot([speakers], output: "BuiltInSpeakerDevice")
        let new = snapshot([speakers, hdmi], output: "BuiltInSpeakerDevice")
        let result = DevicePolicy.evaluate(old: old, new: new, settings: settings(autoSelect: ["benq"]), proxies: [])
        #expect(result.actions.first == .setDefault(.output, uid: "benq"))
    }

    @Test func inputAutoSelect() {
        var s = AppSettings()
        s.autoSelectInputUIDs = ["logi"]
        let old = snapshot([speakers, mic], output: "BuiltInSpeakerDevice", input: "BuiltInMicrophoneDevice")
        let new = snapshot([speakers, mic, webcam], output: "BuiltInSpeakerDevice", input: "BuiltInMicrophoneDevice")
        let result = DevicePolicy.evaluate(old: old, new: new, settings: s, proxies: [])
        #expect(result.actions == [.setDefault(.input, uid: "logi")])
    }

    @Test func doesNotFightTheUserAfterwards() {
        let state = snapshot([speakers, proxy], output: "BuiltInSpeakerDevice")
        let result = DevicePolicy.evaluate(old: state, new: state, settings: settings(autoSelect: [proxy.uid]), proxies: [proxyConfig])
        #expect(result.actions.isEmpty)
    }
}

@Suite("Picker list")
struct VisibleDevicesTests {
    @Test func displayNamesSortTheList() {
        var s = AppSettings()
        s.deviceNames = ["benq": "Monitor"]
        let state = snapshot([hdmi, speakers, proxy], output: nil)
        let visible = DevicePolicy.visibleDevices(for: .output, in: state, settings: s)
        #expect(visible.map { s.displayName(for: $0) } == ["MacBook Pro Speakers", "Living Room", "Monitor"])
    }

    @Test func hidesHiddenAndSortsBuiltInFirst() {
        let state = snapshot([spdif, proxy, speakers, hdmi], output: nil)
        let visible = DevicePolicy.visibleDevices(for: .output, in: state, settings: settings(hidden: ["usb-spdif"]))
        #expect(visible.map(\.uid) == ["BuiltInSpeakerDevice", "benq", "dev.codejo.sam.proxy.A"])
    }

    @Test func inputsExcludeOutputOnlyDevices() {
        let state = snapshot([speakers, mic, proxy], output: nil)
        let visible = DevicePolicy.visibleDevices(for: .input, in: state, settings: AppSettings())
        #expect(visible.map(\.uid) == ["BuiltInMicrophoneDevice"])
    }
}
