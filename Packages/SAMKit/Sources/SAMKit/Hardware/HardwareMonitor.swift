import CoreAudio
import Foundation
import Observation

/// Keeps a live `HardwareSnapshot` plus the default output's volume and mute,
/// driven by Core Audio property listeners (coalesced, main actor).
@Observable
@MainActor
public final class HardwareMonitor {
    public private(set) var snapshot = HardwareSnapshot()
    /// Volume of the default output (0...1), nil if it has no volume control.
    public private(set) var outputVolume: Float?
    public private(set) var outputMuted = false

    /// Called after every snapshot change with (old, new).
    @ObservationIgnored public var onSnapshotChange: ((HardwareSnapshot, HardwareSnapshot) -> Void)?

    @ObservationIgnored private var systemListeners: [Registration] = []
    @ObservationIgnored private var deviceListeners: [Registration] = []
    @ObservationIgnored private var volumeListeners: [Registration] = []
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var volumeDeviceID: AudioObjectID = kAudioObjectUnknown

    public init() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyServiceRestarted,
        ] {
            systemListeners += listen(system, selector) { [weak self] in self?.scheduleRefresh() }
        }
        refresh()
    }

    /// Re-reads everything now.
    public func refresh() {
        refreshScheduled = false
        let old = snapshot
        let new = AudioHardware.snapshot()
        if new != old {
            snapshot = new
            observeDevices(new.devices)
            onSnapshotChange?(old, new)
        }
        updateVolumeTarget()
    }

    // MARK: Volume of the default output

    public func setOutputVolume(_ volume: Float) {
        guard let device = snapshot.device(uid: snapshot.defaultOutputUID) else { return }
        AudioHardware.setVolume(volume, of: device.id)
        outputVolume = volume
        if outputMuted, volume > 0 {
            setOutputMuted(false)
        }
    }

    public func setOutputMuted(_ muted: Bool) {
        guard let device = snapshot.device(uid: snapshot.defaultOutputUID) else { return }
        AudioHardware.setMuted(muted, of: device.id)
        outputMuted = muted
    }

    private func updateVolumeTarget() {
        let id = snapshot.device(uid: snapshot.defaultOutputUID)?.id ?? kAudioObjectUnknown
        if id != volumeDeviceID {
            remove(&volumeListeners)
            volumeDeviceID = id
            if id != kAudioObjectUnknown {
                // Apple's virtual main volume derives from the main or channel
                // volumes, so listen to all of them.
                for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
                    volumeListeners += listen(id, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element) { [weak self] in
                        self?.readVolume()
                    }
                }
                volumeListeners += listen(id, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) { [weak self] in
                    self?.readVolume()
                }
            }
        }
        readVolume()
    }

    private func readVolume() {
        guard volumeDeviceID != kAudioObjectUnknown else {
            outputVolume = nil
            outputMuted = false
            return
        }
        let volume = AudioHardware.volume(of: volumeDeviceID)
        let muted = AudioHardware.isMuted(volumeDeviceID) ?? false
        if volume != outputVolume { outputVolume = volume }
        if muted != outputMuted { outputMuted = muted }
    }

    // MARK: Listeners

    private func observeDevices(_ devices: [AudioDevice]) {
        remove(&deviceListeners)
        for device in devices {
            for selector in [kAudioObjectPropertyName, kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyIsHidden, kAudioDevicePropertyStreamConfiguration] {
                deviceListeners += listen(device.id, selector) { [weak self] in self?.scheduleRefresh() }
            }
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            self?.refresh()
        }
    }

    private struct Registration {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        var block: AudioObjectPropertyListenerBlock
    }

    private func listen(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        _ handler: @escaping @MainActor () -> Void
    ) -> [Registration] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return [] }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return [] }
        return [Registration(object: object, address: address, block: block)]
    }

    private func remove(_ registrations: inout [Registration]) {
        for var registration in registrations {
            AudioObjectRemovePropertyListenerBlock(registration.object, &registration.address, .main, registration.block)
        }
        registrations.removeAll()
    }
}
