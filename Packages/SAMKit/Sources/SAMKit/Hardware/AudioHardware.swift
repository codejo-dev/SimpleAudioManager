import AudioToolbox
import CoreAudio
import Foundation

/// Reads and changes system-wide audio state through Apple's Swift Core Audio
/// API (`AudioHardwareSystem`). Stateless; callable from any thread.
public enum AudioHardware {
    public static func snapshot() -> HardwareSnapshot {
        let system = AudioHardwareSystem.shared
        let devices = ((try? system.devices) ?? []).compactMap(makeDevice)
        return HardwareSnapshot(
            devices: devices,
            defaultOutputUID: try? system.defaultOutputDevice?.uid,
            defaultSystemOutputUID: try? system.defaultSoundEffectsDevice?.uid,
            defaultInputUID: try? system.defaultInputDevice?.uid
        )
    }

    public static func setDefault(_ role: DeviceRole, uid: String) throws {
        let system = AudioHardwareSystem.shared
        guard let device = try system.device(forUID: uid) else {
            throw AudioHardwareError(kAudioHardwareBadDeviceError)
        }
        switch role {
        case .output: try system.setDefaultOutputDevice(device)
        case .systemOutput: try system.setDefaultSoundEffectsDevice(device)
        case .input: try system.setDefaultInputDevice(device)
        }
    }

    // MARK: Volume
    // The "virtual main volume" is what Apple's own slider and keys use: it maps
    // onto a device's main volume or its per-channel volumes. Core Audio serves
    // it through the regular AudioObject API.

    public static func volume(of device: AudioObjectID) -> Float? {
        var address = virtualMainVolume
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    public static func setVolume(_ volume: Float, of device: AudioObjectID) {
        var address = virtualMainVolume
        var value = Float32(min(max(volume, 0), 1))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    public static func hasSettableVolume(_ device: AudioObjectID) -> Bool {
        var address = virtualMainVolume
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    public static func isMuted(_ device: AudioObjectID) -> Bool? {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value != 0 : nil
    }

    public static func setMuted(_ muted: Bool, of device: AudioObjectID) {
        var address = muteAddress
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: Private

    static let virtualMainVolume = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func makeDevice(_ device: AudioHardwareDevice) -> AudioDevice? {
        guard let uid = try? device.uid, !uid.isEmpty else { return nil }
        let outputs = ((try? device.outputStreamConfiguration) ?? []).reduce(0) { $0 + Int($1.mNumberChannels) }
        let inputs = ((try? device.inputStreamConfiguration) ?? []).reduce(0) { $0 + Int($1.mNumberChannels) }
        return AudioDevice(
            id: device.id,
            uid: uid,
            name: (try? device.name) ?? uid,
            manufacturer: (try? device.manufacturer) ?? "",
            transport: TransportType(rawValue: (try? device.transportType) ?? 0),
            outputChannels: outputs,
            inputChannels: inputs,
            nominalSampleRate: (try? device.nominalSampleRate) ?? 0,
            isAlive: (try? device.isAlive) ?? false,
            isHidden: (try? device.isHidden) ?? false,
            canBeDefaultOutput: (try? device.canBeDefaultOutputDevice) ?? false,
            canBeDefaultInput: (try? device.canBeDefaultInputDevice) ?? false,
            hasOutputVolume: outputs > 0 && hasSettableVolume(device.id)
        )
    }
}
