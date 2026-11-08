import SAMKit
import SwiftUI

enum SidebarItem: Hashable {
    case device(String)          // physical device UID (output role)
    case inputDevice(String)     // physical device UID (input role)
    case disconnectedProxy(String) // proxy UID whose target is not connected
    case general
    case about
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem?
    @State private var showOnboarding = false

    init(initialSelection: SidebarItem = .general) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Outputs") {
                    ForEach(outputs) { device in
                        DeviceSidebarRow(device: device, isSelected: selection == .device(device.uid))
                            .tag(SidebarItem.device(device.uid))
                    }
                    ForEach(disconnectedProxies) { proxy in
                        SidebarRow(
                            title: proxy.name,
                            subtitle: "→ \(proxy.targetName.isEmpty ? "Device" : proxy.targetName) · Not connected",
                            symbol: model.settings.deviceSymbols[proxy.uid] ?? "powerplug",
                            dimmed: true,
                            isSelected: selection == .disconnectedProxy(proxy.uid)
                        )
                        .tag(SidebarItem.disconnectedProxy(proxy.uid))
                    }
                }
                Section("Inputs") {
                    ForEach(inputs) { device in
                        DeviceSidebarRow(device: device, role: .input, isSelected: selection == .inputDevice(device.uid))
                            .tag(SidebarItem.inputDevice(device.uid))
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 2) {
                    SidebarFooterButton(title: "Settings", symbol: "gearshape", isSelected: selection == .general) {
                        selection = .general
                    }
                    SidebarFooterButton(title: "About", symbol: "info.circle", isSelected: selection == .about) {
                        selection = .about
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if !model.driverInstalled {
                    DriverBanner()
                }
                if let error = model.lastError {
                    ErrorBanner(message: error) { model.lastError = nil }
                }
                detail
            }
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
        }
        .onAppear {
            showOnboarding = !model.settings.onboardingCompleted
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAboutPage)) { _ in
            selection = .about
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case let .device(uid):
            if let device = model.snapshot.device(uid: uid) {
                DeviceDetailView(device: device)
                    .id(uid)
            } else {
                ContentUnavailableView("Device Disconnected", systemImage: "powerplug")
            }
        case let .inputDevice(uid):
            if let device = model.snapshot.device(uid: uid) {
                DeviceDetailView(device: device, role: .input)
                    .id("in-" + uid)
            } else {
                ContentUnavailableView("Device Disconnected", systemImage: "powerplug")
            }
        case let .disconnectedProxy(uid):
            if let proxy = model.proxies.first(where: { $0.uid == uid }) {
                DisconnectedProxyView(proxy: proxy)
            } else {
                ContentUnavailableView("Proxy Removed", systemImage: "trash")
            }
        case .general, nil:
            GeneralView()
        case .about:
            AboutView()
        }
    }

    private var outputs: [AudioDevice] {
        model.snapshot.outputs.filter { !$0.isProxy }
    }

    private var inputs: [AudioDevice] {
        model.snapshot.inputs.filter { !$0.isProxy }
    }

    private var disconnectedProxies: [ProxyConfig] {
        model.proxies.filter { model.snapshot.device(uid: $0.targetUID) == nil }
    }
}

/// Settings and About, pinned to the bottom of the sidebar.
struct SidebarFooterButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    .frame(width: 20)
                Text(title)
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(isHovered ? 0.07 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Sidebar row: icon centered against one or two lines of text.
struct SidebarRow: View {
    let title: String
    let subtitle: String?
    let symbol: String
    var dimmed = false
    var isSelected = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(deviceSymbol: symbol)
                .font(.system(size: 14))
                // On the selection highlight the icon takes the text color
                // (white on blue, dark on gray); otherwise the accent color.
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, subtitle == nil ? 0 : 1)
        .opacity(dimmed && !isSelected ? 0.45 : 1)
    }
}

struct DeviceSidebarRow: View {
    @Environment(AppModel.self) private var model
    let device: AudioDevice
    var role: DeviceRole = .output
    var isSelected = false

    var body: some View {
        if role != .input, let proxy = model.proxy(forTarget: device.uid) {
            // The proxy is what macOS shows; the physical device sits below.
            SidebarRow(
                title: proxy.name,
                subtitle: "→ \(device.name)",
                symbol: model.symbol(forProxy: proxy, target: device),
                isSelected: isSelected
            )
        } else {
            SidebarRow(
                title: model.displayName(for: device),
                subtitle: role != .input && device.isOutput && !device.hasOutputVolume ? "No volume control" : nil,
                symbol: model.symbol(for: device),
                // Hidden devices stay listed, grayed out.
                dimmed: model.settings.isHidden(device.uid),
                isSelected: isSelected
            )
        }
    }
}

struct DriverBanner: View {
    @Environment(AppModel.self) private var model
    @State private var installing = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio driver not installed").font(.headline)
                Text("Proxies with volume control need the Simple Audio Manager driver.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(installing ? "Installing…" : "Install Driver…") {
                install()
            }
            .disabled(installing)
        }
        .padding(12)
        .background(.orange.opacity(0.12))
        .background(.background)
    }

    private func install() {
        installing = true
        Task {
            do {
                try DriverInstaller.install()
                // coreaudiod needs a moment to load the plug-in.
                for _ in 0..<20 where !DriverLink.isInstalled {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            } catch {
                model.lastError = error.localizedDescription
            }
            model.reloadDriver()
            model.hardware.refresh()
            installing = false
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.callout)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(10)
        .background(.yellow.opacity(0.12))
        .background(.background)
    }
}

struct DisconnectedProxyView: View {
    @Environment(AppModel.self) private var model
    let proxy: ProxyConfig

    var body: some View {
        Form {
            Section {
                Text("“\(proxy.name)” appears again as soon as \(proxy.targetName.isEmpty ? "its device" : proxy.targetName) is connected.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Remove Proxy", role: .destructive) {
                    model.removeProxy(proxy)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(proxy.name)
    }
}
