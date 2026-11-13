#if DEBUG
import AppKit
import SAMKit
import SwiftUI

/// Debug aid: renders the main views to PNGs without needing screen capture.
///   SimpleAudioManager --render-snapshots /path/to/dir
enum SnapshotRenderer {
    static func renderAll(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel.shared
        let outputs = model.snapshot.outputs.filter { !$0.isProxy }
        let fixed = outputs.first { !$0.hasOutputVolume } ?? outputs.first

        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render(MainWindow(initialSelection: .general), size: CGSize(width: 820, height: 560), appearance: appearance, to: directory.appending(path: "main-general-\(suffix).png"))
            renderWindow(selection: .about, scrolled: false, appearance: appearance, to: directory.appending(path: "window-about-\(suffix).png"))
            renderWindow(selection: .general, scrolled: true, appearance: appearance, to: directory.appending(path: "window-settings-scrolled-\(suffix).png"))
            if let fixed {
                render(MainWindow(initialSelection: .device(fixed.uid)), size: CGSize(width: 820, height: 560), appearance: appearance, to: directory.appending(path: "main-device-\(suffix).png"))
            }
            render(SoundPanel().background(.background), size: CGSize(width: 300, height: 420), appearance: appearance, to: directory.appending(path: "panel-\(suffix).png"))
            if let plain = outputs.first(where: { model.proxy(forTarget: $0.uid) == nil }) {
                renderWindow(selection: .device(plain.uid), scrolled: false, appearance: appearance, to: directory.appending(path: "window-plain-\(suffix).png"))
            }
            if let proxy = model.proxies.first {
                renderWindow(selection: .device(proxy.targetUID), scrolled: false, appearance: appearance, to: directory.appending(path: "window-proxy-\(suffix).png"))
                render(MainWindow(initialSelection: .device(proxy.targetUID)), size: CGSize(width: 820, height: 640), appearance: appearance, to: directory.appending(path: "main-proxy-\(suffix).png"))
            }
            render(
                HStack(spacing: 18) {
                    ForEach([0.1, 0.3, 0.5, 0.8, 1.0], id: \.self) { level in
                        Image(systemName: "speaker.wave.3.fill", variableValue: level)
                    }
                    Image(systemName: "speaker.slash.fill")
                }
                .font(.system(size: 15))
                .padding(8)
                .background(.background),
                size: CGSize(width: 220, height: 34), appearance: appearance,
                to: directory.appending(path: "menubar-icons-\(suffix).png")
            )
            render(
                SymbolGrid(selection: "soundbar", onSelect: { _ in })
                    .background(.background),
                size: CGSize(width: 470, height: 400), appearance: appearance,
                to: directory.appending(path: "symbols-\(suffix).png")
            )
            render(OnboardingView(done: {}).background(.background), size: CGSize(width: 520, height: 420), appearance: appearance, to: directory.appending(path: "onboarding-\(suffix).png"))
        }
    }

    /// Renders the actual settings window including its toolbar.
    static func renderWindow(selection: SidebarItem, scrolled: Bool, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingController(rootView: MainWindow(initialSelection: selection).environment(AppModel.shared))
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 820, height: 560))
        window.alphaValue = 0
        window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        if scrolled, let scroll = findScrollViews(in: window.contentView).last {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 160))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    private static func findScrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        var result: [NSScrollView] = []
        if let scroll = view as? NSScrollView { result.append(scroll) }
        for sub in view.subviews { result += findScrollViews(in: sub) }
        return result
    }

    private static func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.environment(AppModel.shared))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
