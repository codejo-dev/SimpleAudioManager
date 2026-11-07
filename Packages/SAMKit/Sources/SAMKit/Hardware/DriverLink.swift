import CoreAudio
import Foundation
import SAMDriverAPI

/// Talks to the SimpleAudioManager HAL driver through its custom properties.
public enum DriverLink {
    public enum LinkError: LocalizedError {
        case notInstalled
        case coreAudio(OSStatus)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .notInstalled: "The SimpleAudioManager audio driver is not installed."
            case let .coreAudio(status): "Core Audio error \(status)."
            case .malformed: "The driver returned unexpected data."
            }
        }
    }

    /// The driver's plug-in object, if coreaudiod loaded it.
    public static func pluginID() -> AudioObjectID? {
        guard let plugin = try? AudioHardwareSystem.shared.plugin(forBundleID: SAMDriver.bundleID) else {
            return nil
        }
        return plugin.id == kAudioObjectUnknown ? nil : plugin.id
    }

    public static var isInstalled: Bool { pluginID() != nil }

    public static func readConfig() throws -> [ProxyConfig] {
        let plist = try read(SAMDriver.configProperty)
        return ProxyConfig.proxies(fromConfig: plist)
    }

    public static func writeConfig(_ proxies: [ProxyConfig]) throws {
        guard let plugin = pluginID() else { throw LinkError.notInstalled }
        var address = AudioObjectPropertyAddress(
            mSelector: SAMDriver.configProperty,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFPropertyList = ProxyConfig.configPlist(proxies) as CFDictionary
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(plugin, &address, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), pointer)
        }
        guard status == noErr else { throw LinkError.coreAudio(status) }
    }

    public static func readStatus() throws -> [ProxyStatus] {
        let plist = try read(SAMDriver.statusProperty)
        let items = plist[SAM_KEY_PROXIES] as? [[String: Any]] ?? []
        return items.map(ProxyStatus.init(plist:))
    }

    private static func read(_ selector: AudioObjectPropertySelector) throws -> [String: Any] {
        guard let plugin = pluginID() else { throw LinkError.notInstalled }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        var value: Unmanaged<CFPropertyList>?
        let status = AudioObjectGetPropertyData(plugin, &address, 0, nil, &size, &value)
        guard status == noErr else { throw LinkError.coreAudio(status) }
        guard let object = value?.takeRetainedValue(), let dict = object as? [String: Any] else {
            throw LinkError.malformed
        }
        return dict
    }
}
