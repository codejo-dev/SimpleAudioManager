import Foundation
import SAMKit

/// Cleanup the app does for `uninstall.sh` (run as
/// `Simple Audio Manager --prepare-uninstall [--purge]`).
enum Uninstaller {
    static func prepare(purge: Bool) {
        // A login item would point at a deleted app after uninstalling.
        if LoginItem.isEnabled {
            do {
                try LoginItem.setEnabled(false)
                print("Removed the login item.")
            } catch {
                print("Could not remove the login item: \(error.localizedDescription)")
            }
        }
        guard purge else { return }

        // Proxies live in the driver's storage; clear them while it is loaded.
        if DriverLink.isInstalled {
            do {
                try DriverLink.writeConfig([])
                print("Removed all proxies.")
            } catch {
                print("Could not remove proxies: \(error.localizedDescription)")
            }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SimpleAudioManager")
        try? FileManager.default.removeItem(at: support)
        try? FileManager.default.removeItem(at: IconRenderer.directory.deletingLastPathComponent())
        print("Removed settings and icons.")
    }
}
