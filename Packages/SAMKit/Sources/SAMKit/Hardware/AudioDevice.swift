import CoreAudio
import SAMDriverAPI

/// Value snapshot of one Core Audio device.
public struct AudioDevice: Identifiable, Hashable, Sendable {
    public var id: AudioObjectID
    public var uid: String
    public var name: String
    public var manufacturer: String
    public var transport: TransportType
    public var outputChannels: Int
    public var inputChannels: Int
    public var nominalSampleRate: Double
    public var isAlive: Bool
    public var isHidden: Bool
    public var canBeDefaultOutput: Bool
    public var canBeDefaultInput: Bool
    /// The device has a settable output volume (hardware or proxy).
    public var hasOutputVolume: Bool

    public init(
        id: AudioObjectID,
        uid: String,
        name: String,
        manufacturer: String = "",
        transport: TransportType = .unknown,
        outputChannels: Int = 0,
        inputChannels: Int = 0,
        nominalSampleRate: Double = 48_000,
        isAlive: Bool = true,
        isHidden: Bool = false,
        canBeDefaultOutput: Bool = true,
        canBeDefaultInput: Bool = true,
        hasOutputVolume: Bool = false
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.transport = transport
        self.outputChannels = outputChannels
        self.inputChannels = inputChannels
        self.nominalSampleRate = nominalSampleRate
        self.isAlive = isAlive
        self.isHidden = isHidden
        self.canBeDefaultOutput = canBeDefaultOutput
        self.canBeDefaultInput = canBeDefaultInput
        self.hasOutputVolume = hasOutputVolume
    }

    public var isOutput: Bool { outputChannels > 0 }
    public var isInput: Bool { inputChannels > 0 }

    /// A proxy published by the SimpleAudioManager driver.
    public var isProxy: Bool { uid.hasPrefix(SAMDriver.proxyUIDPrefix) }

    /// Usable as a default device for the given role.
    public func canBeDefault(for role: DeviceRole) -> Bool {
        guard isAlive, !isHidden else { return false }
        switch role {
        case .output, .systemOutput: return isOutput && canBeDefaultOutput
        case .input: return isInput && canBeDefaultInput
        }
    }
}

/// The three system-wide device selections macOS keeps.
public enum DeviceRole: String, CaseIterable, Sendable, Codable {
    case output
    case systemOutput
    case input
}

/// Core Audio transport type (a four-char code).
public struct TransportType: RawRepresentable, Hashable, Sendable, Codable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let unknown = TransportType(rawValue: 0)
    public static let builtIn = TransportType(rawValue: kAudioDeviceTransportTypeBuiltIn)
    public static let aggregate = TransportType(rawValue: kAudioDeviceTransportTypeAggregate)
    public static let virtual = TransportType(rawValue: kAudioDeviceTransportTypeVirtual)
    public static let pci = TransportType(rawValue: kAudioDeviceTransportTypePCI)
    public static let usb = TransportType(rawValue: kAudioDeviceTransportTypeUSB)
    public static let fireWire = TransportType(rawValue: kAudioDeviceTransportTypeFireWire)
    public static let bluetooth = TransportType(rawValue: kAudioDeviceTransportTypeBluetooth)
    public static let bluetoothLE = TransportType(rawValue: kAudioDeviceTransportTypeBluetoothLE)
    public static let hdmi = TransportType(rawValue: kAudioDeviceTransportTypeHDMI)
    public static let displayPort = TransportType(rawValue: kAudioDeviceTransportTypeDisplayPort)
    public static let airPlay = TransportType(rawValue: kAudioDeviceTransportTypeAirPlay)
    public static let avb = TransportType(rawValue: kAudioDeviceTransportTypeAVB)
    public static let thunderbolt = TransportType(rawValue: kAudioDeviceTransportTypeThunderbolt)
    public static let continuityCapture = TransportType(rawValue: kAudioDeviceTransportTypeContinuityCaptureWired)

    public var displayName: String {
        switch self {
        case .builtIn: "Built-in"
        case .aggregate: "Aggregate"
        case .virtual: "Virtual"
        case .pci: "PCI"
        case .usb: "USB"
        case .fireWire: "FireWire"
        case .bluetooth, .bluetoothLE: "Bluetooth"
        case .hdmi: "HDMI"
        case .displayPort: "DisplayPort"
        case .airPlay: "AirPlay"
        case .avb: "AVB"
        case .thunderbolt: "Thunderbolt"
        default: "Other"
        }
    }

    /// A fitting SF Symbol for device lists.
    public func symbolName(isInput: Bool = false) -> String {
        if isInput {
            switch self {
            case .builtIn: return "laptopcomputer"
            case .bluetooth, .bluetoothLE: return "headphones"
            case .usb: return "mic"
            default: return "mic"
            }
        }
        switch self {
        case .builtIn: return "laptopcomputer"
        case .hdmi, .displayPort, .thunderbolt: return "display"
        case .bluetooth, .bluetoothLE: return "headphones"
        case .airPlay: return "airplayaudio"
        case .usb: return "hifispeaker"
        case .virtual: return "waveform"
        case .aggregate: return "square.stack.3d.up"
        default: return "speaker.wave.2"
        }
    }
}

/// Everything the app needs to know about the audio system at one moment.
public struct HardwareSnapshot: Equatable, Sendable {
    public var devices: [AudioDevice]
    public var defaultOutputUID: String?
    public var defaultSystemOutputUID: String?
    public var defaultInputUID: String?

    public init(
        devices: [AudioDevice] = [],
        defaultOutputUID: String? = nil,
        defaultSystemOutputUID: String? = nil,
        defaultInputUID: String? = nil
    ) {
        self.devices = devices
        self.defaultOutputUID = defaultOutputUID
        self.defaultSystemOutputUID = defaultSystemOutputUID
        self.defaultInputUID = defaultInputUID
    }

    public func device(uid: String?) -> AudioDevice? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }
    }

    public func defaultUID(for role: DeviceRole) -> String? {
        switch role {
        case .output: defaultOutputUID
        case .systemOutput: defaultSystemOutputUID
        case .input: defaultInputUID
        }
    }

    public var outputs: [AudioDevice] { devices.filter(\.isOutput) }
    public var inputs: [AudioDevice] { devices.filter(\.isInput) }
}

/// Constants shared with the driver (see SAMDriverAPI.h).
public enum SAMDriver {
    public static let bundleID = SAM_DRIVER_BUNDLE_ID
    public static let proxyUIDPrefix = SAM_PROXY_UID_PREFIX
    public static let configProperty = AudioObjectPropertySelector(SAM_PROPERTY_CONFIG)
    public static let statusProperty = AudioObjectPropertySelector(SAM_PROPERTY_STATUS)
}
