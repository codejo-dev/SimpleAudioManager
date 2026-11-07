import SAMKit
import SwiftUI

/// The menu bar Sound picker. Modeled on Control Center's Sound module and
/// built from standard controls, so it follows the system look (materials,
/// accent color, light/dark, VoiceOver).
struct SoundPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showInputs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sound")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.top, 12)

            VolumeRow()
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            PanelDivider()
            PanelSectionHeader("Output")
            ForEach(model.visibleDevices(for: .output)) { device in
                DeviceRow(
                    name: model.displayName(for: device),
                    symbol: model.symbol(for: device),
                    isSelected: device.uid == model.snapshot.defaultOutputUID
                ) {
                    model.select(device, role: .output)
                }
            }

            if showInputs || model.settings.showInputsInPicker {
                PanelDivider()
                PanelSectionHeader("Input")
                ForEach(model.visibleDevices(for: .input)) { device in
                    DeviceRow(
                        name: model.displayName(for: device),
                        symbol: model.symbol(for: device),
                        isSelected: device.uid == model.snapshot.defaultInputUID
                    ) {
                        model.select(device, role: .input)
                    }
                }
            }

            PanelDivider()
            PanelLink("Sound Settings…") {
                SystemSettings.open(.sound)
                dismiss()
            }
            PanelLink("Manage Devices…") {
                MainWindowController.shared.show()
                dismiss()
            }
        }
        .padding(.bottom, 8)
        .frame(width: 300)
        .onAppear {
            // Like Apple's Sound menu: Option-click also shows inputs.
            showInputs = NSEvent.modifierFlags.contains(.option)
        }
    }
}

private struct VolumeRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let volume = model.hardware.outputVolume
        HStack(spacing: 8) {
            Button {
                model.hardware.setOutputMuted(!model.hardware.outputMuted)
            } label: {
                Image(systemName: model.hardware.outputMuted ? "speaker.slash.fill" : "speaker.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(model.hardware.outputMuted ? "Unmute" : "Mute")
            .disabled(volume == nil)

            Slider(
                value: Binding(
                    get: { Double(model.hardware.outputMuted ? 0 : (volume ?? 0)) },
                    set: { model.hardware.setOutputVolume(Float($0)) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .disabled(volume == nil)
            .accessibilityLabel("Output volume")

            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .frame(width: 20)
        }
        .help(volume == nil ? "The selected output has no volume control. Create a proxy for it in Manage Devices." : "")
    }
}

private struct DeviceRow: View {
    let name: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(deviceSymbol: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.1)))
                Text(name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PanelSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 2)
    }
}

private struct PanelDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 16).padding(.vertical, 4)
    }
}

private struct PanelLink: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
    }
}
