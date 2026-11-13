import SAMKit
import SwiftUI

/// First-run checklist: driver, proxies for fixed-volume outputs, menu bar.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var installing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to Simple Audio Manager")
                .font(.title2.weight(.semibold))
            Text("Give every output a working volume control, and keep your device list tidy.")
                .foregroundStyle(.secondary)

            step(1, "Install the audio driver", done: model.driverInstalled) {
                Button(installing ? "Installing…" : "Install…") {
                    installing = true
                    Task {
                        do {
                            try DriverInstaller.install()
                            for _ in 0..<20 where !DriverLink.isInstalled {
                                try? await Task.sleep(for: .milliseconds(250))
                            }
                        } catch {
                            model.lastError = error.localizedDescription
                        }
                        model.reloadDriver()
                        installing = false
                    }
                }
                .disabled(installing)
            }

            step(2, "Add volume control to these outputs", done: fixedVolumeOutputs.isEmpty) {
                EmptyView()
            }
            if !fixedVolumeOutputs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(fixedVolumeOutputs) { device in
                        HStack {
                            Image(deviceSymbol: model.symbol(for: device)).frame(width: 20)
                            Text(device.name)
                            Spacer()
                            Button("Create Proxy") {
                                model.createProxy(for: device)
                            }
                            .disabled(!model.driverInstalled)
                        }
                    }
                }
                .padding(.leading, 34)
            }

            step(3, "Turn off Apple's Sound item in the menu bar", done: false) {
                Button("Open Settings…") { SystemSettings.open(.controlCenter) }
            }
            Text("The Simple Audio Manager picker replaces it; volume keys and the on-screen volume stay Apple's.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 34)

            HStack {
                Spacer()
                Button("Done") {
                    model.completeOnboarding()
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var fixedVolumeOutputs: [AudioDevice] {
        model.snapshot.outputs.filter {
            !$0.isProxy && !$0.hasOutputVolume && $0.transport != .aggregate && model.proxy(forTarget: $0.uid) == nil
        }
    }

    private func step(_ number: Int, _ title: String, done: Bool, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor).frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.white)
                }
            }
            Text(title).font(.headline)
            Spacer()
            if !done { action() }
        }
    }
}
