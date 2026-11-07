import Foundation
import Testing
@testable import SAMKit

@Suite("Config")
struct ConfigTests {
    @Test func proxyConfigRoundTripsThroughDriverPlist() {
        let proxy = ProxyConfig(
            name: "Living Room",
            targetUID: "AppleUSBAudioEngine:Generic:USB SPDIF Adapter:202110200032:1",
            targetName: "USB SPDIF Adapter",
            iconURL: URL(fileURLWithPath: "/Users/Shared/SimpleAudioManager/Icons/a b.png"),
            transport: .hdmi,
            volumeMode: .hardware,
            hidden: true
        )
        let plist = ProxyConfig.configPlist([proxy])
        // The driver receives the same structure as a CFDictionary.
        let bridged = plist as NSDictionary as! [String: Any]
        let decoded = ProxyConfig.proxies(fromConfig: bridged)
        #expect(decoded == [proxy])
    }

    @Test func newUIDsUseTheDriverPrefix() {
        let device = AudioDevice(id: 1, uid: "x", name: "BenQ", outputChannels: 2)
        let proxy = ProxyConfig.proxy(for: device)
        #expect(proxy.uid.hasPrefix(SAMDriver.proxyUIDPrefix))
        #expect(proxy.volumeMode == .software)
        #expect(proxy.name == "BenQ")
    }

    @Test func settingsTolerateMissingKeys() throws {
        let json = #"{"hiddenDeviceUIDs":["benq"]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.hiddenDeviceUIDs == ["benq"])
        #expect(settings.showMenuBarPicker)
        #expect(!settings.onboardingCompleted)
    }

    @Test func legacyAutoSelectKeyStillLoads() throws {
        let json = #"{"autoSelectProxyUIDs":["dev.codejo.sam.proxy.A"]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.autoSelectOutputUIDs == ["dev.codejo.sam.proxy.A"])
        #expect(settings.autoSelects("dev.codejo.sam.proxy.A", for: .output))
    }

    @Test func settingsStoreRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "sam-\(UUID().uuidString)/Settings.json")
        let store = SettingsStore(url: url)
        var settings = AppSettings()
        settings.fallbackOutputUID = "BuiltInSpeakerDevice"
        settings.deviceSymbols = ["a": "tv"]
        try store.save(settings)
        #expect(store.load() == settings)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
