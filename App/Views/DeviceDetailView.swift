import SAMKit
import SwiftUI

struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    let device: AudioDevice
    var role: DeviceRole = .output

    /// The proxy standing in for this output, if any.
    private var proxy: ProxyConfig? {
        role == .input ? nil : model.proxy(forTarget: device.uid)
    }

    private var selectRole: DeviceRole { role == .input ? .input : .output }

    /// What "Use Now" selects: the proxy when there is one.
    private var selectable: AudioDevice? {
        if let proxy { return model.snapshot.device(uid: proxy.uid) }
        return device
    }

    private var isInUse: Bool {
        guard let selectable else { return false }
        return model.snapshot.defaultUID(for: selectRole) == selectable.uid
    }

    var body: some View {
        Form {
            identitySection

            if role != .input && device.isOutput {
                if let proxy {
                    ProxySections(proxy: proxy, target: device)
                } else {
                    createProxySection
                }
            }

            if proxy == nil {
                visibilitySection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(proxy?.name ?? model.displayName(for: device))
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let selectable {
                        model.select(selectable, role: selectRole)
                    }
                } label: {
                    Label(isInUse ? "In Use" : "Use Now", systemImage: isInUse ? "checkmark.circle.fill" : "speaker.wave.2.circle")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(isInUse || !(selectable?.canBeDefault(for: selectRole) ?? false) || (proxy == nil && model.settings.isHidden(device.uid)))
                .help(isInUse ? "This is the current \(selectRole == .input ? "input" : "output")." : "Make this the \(selectRole == .input ? "input" : "output") device.")
            }
        }
    }

    // MARK: Sections

    private var identitySection: some View {
        Section {
            NameField(
                name: proxy?.name ?? model.displayName(for: device),
                placeholder: device.name
            ) { newName in
                if var proxy {
                    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        proxy.name = trimmed
                        model.updateProxy(proxy)
                    }
                    return model.proxy(forTarget: device.uid)?.name ?? proxy.name
                }
                model.setDisplayName(newName, for: device)
                return model.displayName(for: device)
            }
            LabeledContent("Icon") {
                SymbolPicker(selection: Binding(
                    get: {
                        if let proxy { return model.symbol(forProxy: proxy, target: device) }
                        return model.symbol(for: device)
                    },
                    set: { model.setSymbol($0, for: proxy?.uid ?? device.uid) }
                ))
            }
            Toggle("Select automatically when connected", isOn: Binding(
                get: { model.settings.autoSelects(proxy?.uid ?? device.uid, for: selectRole) },
                set: { model.setAutoSelect($0, uid: proxy?.uid ?? device.uid, role: selectRole) }
            ))
        } footer: {
            Group {
                if let proxy {
                    Text("macOS lists this output as “\(proxy.name)”.")
                } else if role != .input && device.isOutput {
                    Text("Name and icon show in Simple Audio Manager and its menu bar picker; macOS keeps calling it “\(device.name)”. Create a proxy to rename it everywhere.")
                } else {
                    Text("Name and icon show in Simple Audio Manager and its menu bar picker; macOS keeps calling it “\(device.name)”.")
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var createProxySection: some View {
        Section {
            if device.hasOutputVolume {
                Text("This device has its own volume control. A proxy renames it in macOS too; volume changes are passed through to the device.")
            } else {
                Text("macOS cannot change the volume of this device. A proxy adds a volume control that works with the volume keys, the menu bar and Control Center.")
            }
            HStack {
                Text("The proxy takes the device's place; the original is hidden.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Create Proxy") {
                    model.createProxy(for: device)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.driverInstalled)
            }
        } header: {
            Text(device.hasOutputVolume ? "Proxy" : "Volume Control")
        }
    }

    private var visibilitySection: some View {
        Section {
            Toggle("Hide from device lists", isOn: Binding(
                get: { model.settings.isHidden(device.uid) },
                set: { model.setHidden($0, uid: device.uid) }
            ))
        } footer: {
            Text("Hidden devices are grayed out here and left out of the menu bar picker. macOS doesn't let apps remove a device from its own lists, so if it gets selected there, Simple Audio Manager switches to your fallback right away.")
                .foregroundStyle(.secondary)
        }
    }

    /// "→ USB SPDIF Adapter · USB · 2 channels · 48 kHz · No volume control"
    private var subtitle: String {
        var parts: [String] = []
        if proxy != nil {
            parts.append("→ \(device.name)")
        } else if model.displayName(for: device) != device.name {
            parts.append(device.name)
        }
        parts.append(device.transport.displayName)
        let channels = role == .input ? device.inputChannels : max(device.outputChannels, device.inputChannels)
        parts.append(channels == 1 ? "1 channel" : "\(channels) channels")
        if device.nominalSampleRate > 0 {
            parts.append(kilohertz(device.nominalSampleRate))
        }
        if device.isOutput && role != .input && proxy == nil {
            parts.append(device.hasOutputVolume ? "Volume control" : "No volume control")
        }
        return parts.joined(separator: " · ")
    }
}

/// Text field that commits on Return or when it loses focus. `commit` returns
/// the name that actually applies (it may reject or normalize the input).
struct NameField: View {
    let name: String
    let placeholder: String
    let commit: (String) -> String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text, prompt: Text(placeholder))
            .focused($focused)
            .onSubmit { text = commit(text) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { text = commit(text) }
            }
            .onAppear { text = name }
            .onChange(of: name) { _, newValue in
                if !focused { text = newValue }
            }
    }
}

/// Proxy-only settings: volume mode, live status, removal.
struct ProxySections: View {
    @Environment(AppModel.self) private var model
    let proxy: ProxyConfig
    let target: AudioDevice

    var body: some View {
        Section {
            Picker("Volume", selection: Binding(
                get: { proxy.volumeMode },
                set: { mode in
                    var copy = proxy
                    copy.volumeMode = mode
                    model.updateProxy(copy)
                }
            )) {
                Text("Volume control in the proxy").tag(VolumeMode.software)
                Text("Device's own volume").tag(VolumeMode.hardware)
                    .selectionDisabled(!target.hasOutputVolume)
            }
        } header: {
            Text("Proxy")
        } footer: {
            Text("Play audio to “\(proxy.name)” and the volume keys work as usual. The original device is hidden while the proxy exists.")
                .foregroundStyle(.secondary)
        }

        ProxyStatusSection(proxy: proxy)

        Section {
            HStack {
                Spacer()
                Button("Remove Proxy", role: .destructive) {
                    model.removeProxy(proxy)
                }
            }
        }
    }
}

struct ProxyStatusSection: View {
    @Environment(AppModel.self) private var model
    let proxy: ProxyConfig

    var body: some View {
        Section("Status") {
            if let status = model.status(for: proxy) {
                LabeledContent("Forwarding") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(status.targetRunning ? .green : .secondary)
                            .frame(width: 8, height: 8)
                        Text(status.targetRunning ? "Playing" : (status.published ? "Idle" : "Unavailable"))
                    }
                }
                if status.published {
                    LabeledContent("Format", value: "\(kilohertz(status.sampleRate)) · \(status.channels) ch")
                    LabeledContent("Added latency", value: String(format: "%.1f ms", status.latencyMilliseconds))
                    LabeledContent("Dropouts", value: "\(status.underruns + status.overruns)")
                    LabeledContent("Clock correction", value: String(format: "%+.1f ppm", status.clockCorrectionPPM))
                }
                if let error = status.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Waiting for the driver…").foregroundStyle(.secondary)
            }
        }
    }
}

struct SymbolPicker: View {
    @Binding var selection: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(deviceSymbol: selection)
                .frame(width: 22, height: 18)
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SymbolGrid(selection: selection) { symbol in
                selection = symbol
                isPresented = false
            }
        }
    }
}

/// The icon picker's content: one titled row per kind of device.
struct SymbolGrid: View {
    let selection: String
    let onSelect: (String) -> Void

    private static let columns = Array(
        repeating: GridItem(.fixed(40), spacing: 4),
        count: IconRenderer.symbolGroups.map(\.symbols.count).max() ?? 8
    )

    var body: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 4) {
            ForEach(IconRenderer.symbolGroups) { group in
                Section {
                    ForEach(group.symbols, id: \.self) { symbol in
                        SymbolCell(symbol: symbol, isSelected: symbol == selection) {
                            onSelect(symbol)
                        }
                    }
                } header: {
                    Text(group.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                        .padding(.top, group.id == IconRenderer.symbolGroups.first?.id ? 0 : 6)
                }
            }
        }
        .padding(12)
    }
}

/// One cell of the icon grid; the whole cell is clickable and highlights on hover.
private struct SymbolCell: View {
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(deviceSymbol: symbol)
                .font(.system(size: 17))
                .frame(width: 40, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(isHovered ? 0.08 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(symbol)
        .accessibilityLabel(symbol)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 48000 -> "48 kHz", 44100 -> "44.1 kHz" (localized decimal separator).
func kilohertz(_ rate: Double) -> String {
    (rate / 1000).formatted(.number.precision(.fractionLength(0...1))) + " kHz"
}
