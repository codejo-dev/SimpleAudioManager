import AppKit

/// Installs or removes the HAL driver bundled in the app's Resources. macOS
/// shows its standard administrator prompt; Core Audio restarts afterwards.
enum DriverInstaller {
    static let installPath = "/Library/Audio/Plug-Ins/HAL/SimpleAudioManager.driver"

    static var bundledDriver: URL? {
        Bundle.main.url(forResource: "SimpleAudioManager", withExtension: "driver")
    }

    static var isInstalledOnDisk: Bool {
        FileManager.default.fileExists(atPath: installPath)
    }

    enum InstallError: LocalizedError {
        case missingBundle
        case script(String)

        var errorDescription: String? {
            switch self {
            case .missingBundle: "The app does not contain the driver. Rebuild the app."
            case let .script(message): message
            }
        }
    }

    static func install() throws {
        guard let source = bundledDriver else { throw InstallError.missingBundle }
        let dest = shellQuote(installPath)
        let command = [
            "rm -rf \(dest)",
            "ditto \(shellQuote(source.path)) \(dest)",
            "chown -R root:wheel \(dest)",
            "chmod -R go-w \(dest)",
            // A downloaded app that was opened via "Open Anyway" is still
            // quarantined, and the copy would inherit the flag. Core Audio may
            // refuse to load a quarantined driver that is not notarized.
            "(xattr -dr com.apple.quarantine \(dest) || true)",
            restartCoreAudio,
        ].joined(separator: " && ")
        try runAsAdministrator(command)
    }

    static func uninstall() throws {
        try runAsAdministrator("rm -rf \(shellQuote(installPath)) && \(restartCoreAudio)")
    }

    private static let restartCoreAudio =
        "(launchctl kickstart -k system/com.apple.audio.coreaudiod || killall coreaudiod)"

    private static func runAsAdministrator(_ command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"Simple Audio Manager needs to install its audio driver.\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "The driver could not be installed."
            throw InstallError.script(message)
        }
    }

    private static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
