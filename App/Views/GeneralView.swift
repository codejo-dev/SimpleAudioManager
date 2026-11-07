import SAMKit
import SwiftUI

struct GeneralView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var busy = false

    var body: some View {
        Form {
            Section("Menu Bar") {
                Toggle("Show Sound picker in the menu bar", isOn: Binding(
                    get: { model.settings.showMenuBarPicker },
                    set: { model.setShowMenuBarPicker($0) }
                ))
                Toggle(isOn: Binding(
                    get: { model.settings.showInputsInPicker },
                    set: { model.setShowInputsInPicker($0) }
                )) {
                    Text("Always show input devices")
                    Text("Lists inputs in the menu bar picker. Without this, Option-click the icon to see them, like Apple's Sound menu.")
                }
                LabeledContent {
                    Button("Open Control Center Settings…") { SystemSettings.open(.controlCenter) }
                } label: {
                    Text("Replace Apple's Sound item")
                    Text("Set Control Center › Sound to “Don't Show in Menu Bar”, so only this picker remains. Volume keys and the volume indicator stay Apple's.")
                }
            }

            Section("Fallback Devices") {
                Picker("Output", selection: Binding(
                    get: { model.settings.fallbackOutputUID },
                    set: { model.setFallback($0, for: .output) }
                )) {
                    Text("Previous device").tag(String?.none)
                    ForEach(model.visibleDevices(for: .output)) { device in
                        Text(model.displayName(for: device)).tag(Optional(device.uid))
                    }
                }
                Picker("Input", selection: Binding(
                    get: { model.settings.fallbackInputUID },
                    set: { model.setFallback($0, for: .input) }
                )) {
                    Text("Previous device").tag(String?.none)
                    ForEach(model.visibleDevices(for: .input)) { device in
                        Text(model.displayName(for: device)).tag(Optional(device.uid))
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.setEnabled(enabled)
                        } catch {
                            model.lastError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
            }

            Section {
                LabeledContent("Audio driver") {
                    Text(model.driverInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(model.driverInstalled ? .green : .secondary)
                }
                HStack {
                    Button(model.driverInstalled ? "Reinstall Driver…" : "Install Driver…") {
                        run { try DriverInstaller.install() }
                    }
                    if model.driverInstalled || DriverInstaller.isInstalledOnDisk {
                        Button("Uninstall Driver…", role: .destructive) {
                            run { try DriverInstaller.uninstall() }
                        }
                    }
                }
                .disabled(busy)
            } header: {
                Text("Driver")
            } footer: {
                Text("Installing restarts Core Audio, which interrupts sound for a moment.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private func run(_ action: @escaping () throws -> Void) {
        busy = true
        Task {
            do {
                try action()
                try? await Task.sleep(for: .seconds(2))
            } catch {
                model.lastError = error.localizedDescription
            }
            model.reloadDriver()
            model.hardware.refresh()
            busy = false
        }
    }
}

enum SystemSettings {
    enum Pane: String {
        case sound = "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        case controlCenter = "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: pane.rawValue) {
            NSWorkspace.shared.open(url)
        }
    }
}
