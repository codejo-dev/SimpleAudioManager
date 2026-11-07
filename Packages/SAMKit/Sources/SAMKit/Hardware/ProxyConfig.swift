import CoreAudio
import Foundation
import SAMDriverAPI

/// How a proxy controls loudness.
public enum VolumeMode: String, CaseIterable, Sendable, Codable {
    /// The driver scales the samples (for outputs without their own volume).
    case software
    /// The proxy forwards to the target's own hardware volume (rename only).
    case hardware
}

/// One proxy device as configured in the driver.
public struct ProxyConfig: Identifiable, Hashable, Sendable, Codable {
    public var uid: String
    public var name: String
    public var targetUID: String
    public var targetName: String
    public var iconURL: URL?
    public var transport: TransportType
    public var volumeMode: VolumeMode
    public var hidden: Bool

    public var id: String { uid }

    public init(
        uid: String = ProxyConfig.makeUID(),
        name: String,
        targetUID: String,
        targetName: String,
        iconURL: URL? = nil,
        transport: TransportType = .virtual,
        volumeMode: VolumeMode = .software,
        hidden: Bool = false
    ) {
        self.uid = uid
        self.name = name
        self.targetUID = targetUID
        self.targetName = targetName
        self.iconURL = iconURL
        self.transport = transport
        self.volumeMode = volumeMode
        self.hidden = hidden
    }

    public static func makeUID() -> String {
        SAMDriver.proxyUIDPrefix + UUID().uuidString
    }

    /// Builds a proxy for a physical output with sensible defaults.
    public static func proxy(for device: AudioDevice) -> ProxyConfig {
        ProxyConfig(
            name: device.name,
            targetUID: device.uid,
            targetName: device.name,
            transport: .virtual,
            volumeMode: device.hasOutputVolume ? .hardware : .software
        )
    }

    // MARK: Property list (matches SAMDriverAPI.h)

    init?(plist: [String: Any]) {
        guard let uid = plist[SAM_KEY_UID] as? String,
              let target = plist[SAM_KEY_TARGET_UID] as? String
        else { return nil }
        self.uid = uid
        self.name = plist[SAM_KEY_NAME] as? String ?? ""
        self.targetUID = target
        self.targetName = plist[SAM_KEY_TARGET_NAME] as? String ?? ""
        let icon = plist[SAM_KEY_ICON_URL] as? String ?? ""
        self.iconURL = icon.isEmpty ? nil : URL(string: icon)
        self.transport = TransportType(rawValue: (plist[SAM_KEY_TRANSPORT] as? NSNumber)?.uint32Value ?? TransportType.virtual.rawValue)
        self.volumeMode = VolumeMode(rawValue: plist[SAM_KEY_VOLUME_MODE] as? String ?? "") ?? .software
        self.hidden = (plist[SAM_KEY_HIDDEN] as? Bool) ?? false
    }

    var plist: [String: Any] {
        [
            SAM_KEY_UID: uid,
            SAM_KEY_NAME: name,
            SAM_KEY_TARGET_UID: targetUID,
            SAM_KEY_TARGET_NAME: targetName,
            SAM_KEY_ICON_URL: iconURL?.absoluteString ?? "",
            SAM_KEY_TRANSPORT: NSNumber(value: transport.rawValue),
            SAM_KEY_VOLUME_MODE: volumeMode.rawValue,
            SAM_KEY_HIDDEN: hidden,
        ]
    }

    static func configPlist(_ proxies: [ProxyConfig]) -> [String: Any] {
        [
            SAM_KEY_VERSION: Int(SAM_CONFIG_VERSION),
            SAM_KEY_PROXIES: proxies.map(\.plist),
        ]
    }

    static func proxies(fromConfig plist: [String: Any]) -> [ProxyConfig] {
        (plist[SAM_KEY_PROXIES] as? [[String: Any]] ?? []).compactMap(ProxyConfig.init(plist:))
    }
}

/// Live state of one proxy, reported by the driver.
public struct ProxyStatus: Hashable, Sendable {
    public var uid: String
    public var published: Bool
    public var targetPresent: Bool
    public var targetRunning: Bool
    public var sampleRate: Double
    public var channels: Int
    public var latencyFrames: Int
    public var underruns: Int
    public var overruns: Int
    public var resyncs: Int
    public var clockCorrectionPPM: Double
    public var hogPID: Int
    public var error: String?

    public var latencyMilliseconds: Double {
        sampleRate > 0 ? Double(latencyFrames) / sampleRate * 1000 : 0
    }

    init(plist: [String: Any]) {
        func int(_ key: String) -> Int { (plist[key] as? NSNumber)?.intValue ?? 0 }
        uid = plist[SAM_KEY_UID] as? String ?? ""
        published = plist[SAM_KEY_PUBLISHED] as? Bool ?? false
        targetPresent = plist[SAM_KEY_TARGET_PRESENT] as? Bool ?? false
        targetRunning = plist[SAM_KEY_TARGET_RUNNING] as? Bool ?? false
        sampleRate = (plist[SAM_KEY_SAMPLE_RATE] as? NSNumber)?.doubleValue ?? 0
        channels = int(SAM_KEY_CHANNELS)
        latencyFrames = int(SAM_KEY_LATENCY)
        underruns = int(SAM_KEY_UNDERRUNS)
        overruns = int(SAM_KEY_OVERRUNS)
        resyncs = int(SAM_KEY_RESYNCS)
        clockCorrectionPPM = (plist[SAM_KEY_CLOCK_PPM] as? NSNumber)?.doubleValue ?? 0
        hogPID = (plist[SAM_KEY_HOG_PID] as? NSNumber)?.intValue ?? -1
        error = plist[SAM_KEY_ERROR] as? String
    }
}
