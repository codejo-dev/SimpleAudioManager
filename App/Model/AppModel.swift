import AppKit
import Observation
import SAMKit

/// App state: live hardware, the driver's proxies, app settings, and the
/// policy that keeps hidden devices from being selected.
@Observable
final class AppModel {
    static let shared = AppModel()

    let hardware = HardwareMonitor()
    private(set) var settings: AppSettings
    private(set) var proxies: [ProxyConfig] = []
    private(set) var statuses: [String: ProxyStatus] = [:]
    private(set) var driverInstalled = false
    var lastError: String?

    /// Status polling runs while the settings window is visible.
    var isWindowVisible = false {
        didSet { updateStatusPolling() }
    }

    @ObservationIgnored private let store = SettingsStore()
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    private init() {
        settings = store.load()
        hardware.onSnapshotChange = { [weak self] old, new in
            self?.snapshotChanged(old: old, new: new)
        }
        reloadDriver()
        applyPolicy(old: nil, new: hardware.snapshot)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                model.hardware.refresh()
                model.reloadDriver()
            }
        }
    }

    var snapshot: HardwareSnapshot { hardware.snapshot }

    // MARK: Policy

    private func snapshotChanged(old: HardwareSnapshot, new: HardwareSnapshot) {
        if driverInstalled != DriverLink.isInstalled || old.devices.map(\.uid) != new.devices.map(\.uid) {
            reloadDriver()
        }
        applyPolicy(old: old, new: new)
    }

    private func applyPolicy(old: HardwareSnapshot?, new: HardwareSnapshot, graceElapsed: Bool = false) {
        let result = DevicePolicy.evaluate(
            old: old, new: new, settings: settings, proxies: proxies, proxyGraceElapsed: graceElapsed
        )
        for case let .setDefault(role, uid) in result.actions {
            try? AudioHardware.setDefault(role, uid: uid)
        }
        graceTask?.cancel()
        if result.waitingForProxy {
            graceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                self.applyPolicy(old: old, new: self.hardware.snapshot, graceElapsed: true)
            }
        }
    }

    // MARK: Driver

    func reloadDriver() {
        driverInstalled = DriverLink.isInstalled
        proxies = driverInstalled ? ((try? DriverLink.readConfig()) ?? []) : []
        refreshIconFiles()
        refreshStatus()
    }

    /// Points each proxy at its current icon file. A redrawn custom symbol
    /// gets a new file name, and missing files are rendered again.
    private func refreshIconFiles() {
        let updated = proxies.map { proxy in
            guard let symbol = settings.deviceSymbols[proxy.uid] else { return proxy }
            var proxy = proxy
            proxy.iconURL = IconRenderer.iconURL(for: symbol)
            return proxy
        }
        if updated != proxies {
            saveProxies(updated)
        }
        if driverInstalled {
            IconRenderer.removeStaleIcons(keeping: Set(proxies.compactMap(\.iconURL)))
        }
    }

    private func refreshStatus() {
        guard driverInstalled, let list = try? DriverLink.readStatus() else {
            statuses = [:]
            return
        }
        statuses = Dictionary(list.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func updateStatusPolling() {
        statusTask?.cancel()
        guard isWindowVisible else { return }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func saveProxies(_ list: [ProxyConfig]) {
        do {
            try DriverLink.writeConfig(list)
            proxies = list
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Proxies

    func proxy(forTarget uid: String) -> ProxyConfig? {
        proxies.first { $0.targetUID == uid }
    }

    func status(for proxy: ProxyConfig) -> ProxyStatus? {
        statuses[proxy.uid]
    }

    /// Creates a proxy for an output. The original is hidden from then on (the
    /// proxy stands in for it); its display name and icon carry over.
    func createProxy(for device: AudioDevice) {
        var proxy = ProxyConfig.proxy(for: device)
        proxy.name = settings.displayName(for: device)
        let symbol = settings.deviceSymbols[device.uid] ?? device.transport.symbolName()
        proxy.iconURL = IconRenderer.iconURL(for: symbol)
        saveProxies(proxies + [proxy])
        updateSettings {
            $0.deviceSymbols[proxy.uid] = symbol
            $0.deviceNames[device.uid] = nil
            // The proxy takes over: it is selected when its device connects.
            $0.autoSelectOutputUIDs.remove(device.uid)
            $0.autoSelectOutputUIDs.insert(proxy.uid)
        }
        // Use it right away when the original was the selected output.
        if snapshot.defaultOutputUID == device.uid {
            Task { [weak self] in
                for _ in 0..<20 where self?.snapshot.device(uid: proxy.uid) == nil {
                    try? await Task.sleep(for: .milliseconds(150))
                }
                if let self, let published = self.snapshot.device(uid: proxy.uid) {
                    self.select(published, role: .output)
                }
            }
        }
    }

    func updateProxy(_ proxy: ProxyConfig) {
        guard let index = proxies.firstIndex(where: { $0.uid == proxy.uid }), proxies[index] != proxy else { return }
        var list = proxies
        list[index] = proxy
        saveProxies(list)
    }

    func removeProxy(_ proxy: ProxyConfig) {
        saveProxies(proxies.filter { $0.uid != proxy.uid })
        updateSettings {
            $0.autoSelectOutputUIDs.remove(proxy.uid)
            $0.deviceSymbols[proxy.uid] = nil
            // Un-hide the original so it is reachable again.
            $0.hiddenDeviceUIDs.remove(proxy.targetUID)
        }
    }

    /// "Select automatically when connected" for any device (or proxy UID).
    func setAutoSelect(_ enabled: Bool, uid: String, role: DeviceRole) {
        updateSettings {
            if role == .input {
                if enabled { $0.autoSelectInputUIDs.insert(uid) } else { $0.autoSelectInputUIDs.remove(uid) }
            } else {
                if enabled { $0.autoSelectOutputUIDs.insert(uid) } else { $0.autoSelectOutputUIDs.remove(uid) }
            }
        }
    }

    /// Display name for a device without a proxy; empty restores its own name.
    func setDisplayName(_ name: String, for device: AudioDevice) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSettings {
            $0.deviceNames[device.uid] = (trimmed.isEmpty || trimmed == device.name) ? nil : trimmed
        }
    }

    func displayName(for device: AudioDevice) -> String {
        settings.displayName(for: device)
    }

    // MARK: Devices

    func setHidden(_ hidden: Bool, uid: String) {
        updateSettings {
            if hidden { $0.hiddenDeviceUIDs.insert(uid) } else { $0.hiddenDeviceUIDs.remove(uid) }
        }
        applyPolicy(old: nil, new: snapshot)
    }

    func setSymbol(_ symbol: String, for uid: String) {
        updateSettings { $0.deviceSymbols[uid] = symbol }
        if var proxy = proxies.first(where: { $0.uid == uid }) {
            proxy.iconURL = IconRenderer.iconURL(for: symbol)
            updateProxy(proxy)
        }
    }

    func symbol(for device: AudioDevice) -> String {
        if let symbol = settings.deviceSymbols[device.uid] {
            return symbol
        }
        if device.isProxy, let proxy = proxies.first(where: { $0.uid == device.uid }),
           let target = snapshot.device(uid: proxy.targetUID) {
            return target.transport.symbolName()
        }
        return device.transport.symbolName(isInput: !device.isOutput)
    }

    func symbol(forProxy proxy: ProxyConfig, target: AudioDevice) -> String {
        settings.deviceSymbols[proxy.uid] ?? target.transport.symbolName()
    }

    /// Selects a device like Apple's Sound menu does.
    func select(_ device: AudioDevice, role: DeviceRole) {
        do {
            if role == .output {
                // Sound effects follow the output when they did before.
                let follows = snapshot.defaultSystemOutputUID == snapshot.defaultOutputUID
                try AudioHardware.setDefault(.output, uid: device.uid)
                if follows {
                    try AudioHardware.setDefault(.systemOutput, uid: device.uid)
                }
            } else {
                try AudioHardware.setDefault(role, uid: device.uid)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func visibleDevices(for role: DeviceRole) -> [AudioDevice] {
        DevicePolicy.visibleDevices(for: role, in: snapshot, settings: settings, proxies: proxies)
    }

    // MARK: Settings

    func setFallback(_ uid: String?, for role: DeviceRole) {
        updateSettings {
            if role == .input { $0.fallbackInputUID = uid } else { $0.fallbackOutputUID = uid }
        }
    }

    func setShowMenuBarPicker(_ show: Bool) {
        updateSettings { $0.showMenuBarPicker = show }
    }

    func setShowInputsInPicker(_ show: Bool) {
        updateSettings { $0.showInputsInPicker = show }
    }

    func completeOnboarding() {
        updateSettings { $0.onboardingCompleted = true }
    }

    private func updateSettings(_ change: (inout AppSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        do {
            try store.save(copy)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Menu bar icon

    /// Like Apple's Sound icon: speaker.wave.3 with a variable value, so the
    /// waves above the current level are drawn dimmed.
    var menuBarIcon: (name: String, level: Double?) {
        guard let volume = hardware.outputVolume else { return ("speaker.wave.3.fill", nil) }
        if hardware.outputMuted || volume <= 0.001 { return ("speaker.slash.fill", nil) }
        return ("speaker.wave.3.fill", Double(volume))
    }
}
