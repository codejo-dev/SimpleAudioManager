import Foundation

/// A change the app should make to the system's device selection.
public enum PolicyAction: Equatable, Sendable {
    case setDefault(DeviceRole, uid: String)
}

public struct PolicyResult: Equatable, Sendable {
    public var actions: [PolicyAction] = []
    /// A hidden device is selected and its proxy is configured but not
    /// published yet. Re-evaluate shortly with `proxyGraceElapsed: true`.
    public var waitingForProxy = false
}

/// Pure decision logic: given the old and new system state, which default
/// devices should change? Side effects are applied by the caller.
public enum DevicePolicy {
    public static func evaluate(
        old: HardwareSnapshot?,
        new: HardwareSnapshot,
        settings: AppSettings,
        proxies: [ProxyConfig],
        proxyGraceElapsed: Bool = false
    ) -> PolicyResult {
        var result = PolicyResult()
        var chosen: [DeviceRole: String] = [:]
        let settings = settings.hidingProxyTargets(proxies)

        // 1. A hidden device became a default: move away from it.
        for role in DeviceRole.allCases {
            guard let current = new.defaultUID(for: role), settings.isHidden(current) else { continue }

            if role != .input, let proxy = proxies.first(where: { $0.targetUID == current }) {
                if let device = new.device(uid: proxy.uid), device.canBeDefault(for: role) {
                    chosen[role] = proxy.uid
                    continue
                }
                if !proxyGraceElapsed {
                    // The driver publishes the proxy right after its target appears.
                    result.waitingForProxy = true
                    continue
                }
            }
            if let replacement = replacement(for: role, avoiding: current, old: old, new: new, settings: settings) {
                chosen[role] = replacement
            }
        }

        // 2. A device marked "select when connected" just appeared.
        if let old {
            for uid in settings.autoSelectOutputUIDs where appeared(uid, for: .output, old: old, new: new) {
                if chosen[.output] == nil {
                    chosen[.output] = uid
                }
                // macOS's "selected output device" for sound effects follows the
                // default output; keep it that way when it did before.
                if chosen[.systemOutput] == nil, old.defaultSystemOutputUID == old.defaultOutputUID {
                    chosen[.systemOutput] = uid
                }
            }
            for uid in settings.autoSelectInputUIDs where appeared(uid, for: .input, old: old, new: new) {
                if chosen[.input] == nil {
                    chosen[.input] = uid
                }
            }
        }

        for role in DeviceRole.allCases {
            if let uid = chosen[role], uid != new.defaultUID(for: role) {
                result.actions.append(.setDefault(role, uid: uid))
            }
        }
        return result
    }

    /// Devices the picker shows for a role, in display order.
    public static func visibleDevices(
        for role: DeviceRole,
        in snapshot: HardwareSnapshot,
        settings: AppSettings,
        proxies: [ProxyConfig] = []
    ) -> [AudioDevice] {
        let settings = settings.hidingProxyTargets(proxies)
        return snapshot.devices
            .filter { $0.canBeDefault(for: role) && !settings.isHidden($0.uid) }
            .sorted { lhs, rhs in
                // Built-in first (like macOS), then alphabetical.
                if (lhs.transport == .builtIn) != (rhs.transport == .builtIn) {
                    return lhs.transport == .builtIn
                }
                return settings.displayName(for: lhs)
                    .localizedStandardCompare(settings.displayName(for: rhs)) == .orderedAscending
            }
    }

    /// The device is usable for the role now and was not before.
    private static func appeared(_ uid: String, for role: DeviceRole, old: HardwareSnapshot, new: HardwareSnapshot) -> Bool {
        guard let device = new.device(uid: uid), device.canBeDefault(for: role) else { return false }
        return !(old.device(uid: uid)?.canBeDefault(for: role) ?? false)
    }

    private static func replacement(
        for role: DeviceRole,
        avoiding current: String,
        old: HardwareSnapshot?,
        new: HardwareSnapshot,
        settings: AppSettings
    ) -> String? {
        func usable(_ uid: String?) -> String? {
            guard let uid, uid != current, !settings.isHidden(uid),
                  let device = new.device(uid: uid), device.canBeDefault(for: role)
            else { return nil }
            return uid
        }
        // The user's previous choice, then their fallback, then anything visible.
        return usable(old?.defaultUID(for: role))
            ?? usable(settings.fallbackUID(for: role))
            ?? visibleDevices(for: role, in: new, settings: settings).first { $0.uid != current }?.uid
    }
}
