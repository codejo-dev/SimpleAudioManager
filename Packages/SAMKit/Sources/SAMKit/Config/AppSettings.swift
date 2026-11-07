import Foundation

/// App-side preferences. Proxy definitions live in the driver; everything that
/// only the app needs (hiding, fallbacks, names and icons) lives here.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Devices the user hid. They vanish from the picker, and when macOS
    /// selects one anyway the app switches to its proxy or a fallback.
    /// Devices that have a proxy are hidden implicitly (see `hidingProxyTargets`).
    public var hiddenDeviceUIDs: Set<String> = []
    public var fallbackOutputUID: String?
    public var fallbackInputUID: String?
    /// Devices that become the default output / input whenever they (re)appear.
    public var autoSelectOutputUIDs: Set<String> = []
    public var autoSelectInputUIDs: Set<String> = []
    /// Display names for devices without a proxy (macOS keeps their own name).
    public var deviceNames: [String: String] = [:]
    /// SF Symbol per device UID, shown in the app and the menu bar picker.
    public var deviceSymbols: [String: String] = [:]
    public var showMenuBarPicker = true
    /// Always list inputs in the picker (Option-click shows them regardless).
    public var showInputsInPicker = false
    public var onboardingCompleted = false

    public init() {}

    private enum LegacyKeys: String, CodingKey {
        case autoSelectProxyUIDs
    }

    public init(from decoder: any Decoder) throws {
        // Tolerate missing keys so older settings files keep working.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        hiddenDeviceUIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenDeviceUIDs) ?? []
        fallbackOutputUID = try c.decodeIfPresent(String.self, forKey: .fallbackOutputUID)
        fallbackInputUID = try c.decodeIfPresent(String.self, forKey: .fallbackInputUID)
        autoSelectOutputUIDs = try c.decodeIfPresent(Set<String>.self, forKey: .autoSelectOutputUIDs)
            ?? legacy.decodeIfPresent(Set<String>.self, forKey: .autoSelectProxyUIDs) ?? []
        autoSelectInputUIDs = try c.decodeIfPresent(Set<String>.self, forKey: .autoSelectInputUIDs) ?? []
        deviceNames = try c.decodeIfPresent([String: String].self, forKey: .deviceNames) ?? [:]
        deviceSymbols = try c.decodeIfPresent([String: String].self, forKey: .deviceSymbols) ?? [:]
        showMenuBarPicker = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarPicker) ?? true
        showInputsInPicker = try c.decodeIfPresent(Bool.self, forKey: .showInputsInPicker) ?? false
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
    }

    public func isHidden(_ uid: String) -> Bool { hiddenDeviceUIDs.contains(uid) }

    public func fallbackUID(for role: DeviceRole) -> String? {
        role == .input ? fallbackInputUID : fallbackOutputUID
    }

    public func autoSelects(_ uid: String, for role: DeviceRole) -> Bool {
        role == .input ? autoSelectInputUIDs.contains(uid) : autoSelectOutputUIDs.contains(uid)
    }

    /// The name the app shows: a custom display name, else the device's own.
    public func displayName(for device: AudioDevice) -> String {
        deviceNames[device.uid] ?? device.name
    }

    /// A device with a proxy is always hidden: the proxy stands in for it.
    public func hidingProxyTargets(_ proxies: [ProxyConfig]) -> AppSettings {
        var copy = self
        copy.hiddenDeviceUIDs.formUnion(proxies.map(\.targetUID))
        return copy
    }
}

/// Loads and saves `AppSettings` as JSON in Application Support.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = base.appending(path: "SimpleAudioManager/Settings.json")
        }
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
