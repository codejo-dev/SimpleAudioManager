import AppKit
import SAMKit
import SwiftUI

/// Entry point. Command-line modes run before any UI or audio monitoring
/// starts; otherwise the SwiftUI app launches normally.
@main
enum AppEntry {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--prepare-uninstall") {
            Uninstaller.prepare(purge: arguments.contains("--purge"))
            return
        }
        SimpleAudioManagerApp.main()
    }
}

struct SimpleAudioManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { model.settings.showMenuBarPicker },
            set: { model.setShowMenuBarPicker($0) }
        )) {
            SoundPanel()
                .environment(model)
        } label: {
            let icon = model.menuBarIcon
            Image(systemName: icon.name, variableValue: icon.level)
                .accessibilityLabel("Sound")
        }
        .menuBarExtraStyle(.window)
        .commands {
            // The app menu's About item opens the About page in the window.
            CommandGroup(replacing: .appInfo) {
                Button("About Simple Audio Manager") {
                    MainWindowController.shared.show()
                    NotificationCenter.default.post(name: .showAboutPage, object: nil)
                }
            }
        }
    }
}

extension Notification.Name {
    static let showAboutPage = Notification.Name("dev.codejo.SimpleAudioManager.showAboutPage")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppModel.shared
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-snapshots"),
           CommandLine.arguments.indices.contains(index + 1) {
            SnapshotRenderer.renderAll(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            NSApp.terminate(nil)
            return
        }
        #endif
        // Stay in the background when started at login; show the window when
        // the user opens the app themselves or setup is not finished.
        if !Self.launchedAsLoginItem || !AppModel.shared.settings.onboardingCompleted {
            MainWindowController.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication)
        else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}

/// The settings window, hosted in AppKit so it can be opened from anywhere
/// (reopen events, the menu bar picker). The Dock icon shows only while it is open.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MainWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Simple Audio Manager"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MainWindow")
        let hosting = NSHostingController(rootView: MainWindow().environment(AppModel.shared))
        // Let SwiftUI drive the window's toolbar and title (page headers,
        // sidebar toggle, toolbar background behind scrolled content).
        hosting.sceneBridgingOptions = [.title, .toolbars]
        window.contentViewController = hosting
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        AppModel.shared.isWindowVisible = true
        AppModel.shared.reloadDriver()
    }

    func windowWillClose(_ notification: Notification) {
        AppModel.shared.isWindowVisible = false
        NSApp.setActivationPolicy(.accessory)
    }
}
