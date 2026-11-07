import AppKit
import SwiftUI

/// Renders an SF Symbol into a PNG that Core Audio can hand out as a device
/// icon (kAudioDevicePropertyIcon is a file URL). Icons live in /Users/Shared
/// so every process that shows device icons can read them.
enum IconRenderer {
    static let directory = URL(fileURLWithPath: "/Users/Shared/SimpleAudioManager/Icons", isDirectory: true)

    /// Curated symbols for the icon picker.
    static let symbols: [String] = [
        "hifispeaker", "hifispeaker.2", "soundbar", "homepod", "homepod.2",
        "speaker.wave.2", "tv", "display", "headphones", "earbuds",
        "amplifier", "radio", "laptopcomputer", "desktopcomputer", "airplayaudio",
        "waveform", "music.note", "guitars", "pianokeys", "mic",
    ]

    /// Symbols drawn for this app (asset catalog), not part of SF Symbols.
    static let customSymbols: Set<String> = ["soundbar"]

    /// The symbol as an NSImage, from SF Symbols or the app's own symbols.
    static func symbolImage(_ name: String) -> NSImage? {
        if customSymbols.contains(name) {
            return NSImage(symbolName: name, bundle: .main, variableValue: 1)
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Returns the icon file for a symbol, rendering it on first use.
    static func iconURL(for symbol: String) -> URL? {
        let url = directory.appending(path: "\(symbol).png")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        guard let data = render(symbol: symbol) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func render(symbol: String, size: CGFloat = 512) -> Data? {
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        guard let glyph = symbolImage(symbol)?.withSymbolConfiguration(config)
        else { return nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        // A neutral round badge, like macOS device icons.
        let inset = size * 0.04
        let circle = NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset))
        NSGradient(starting: NSColor(white: 0.55, alpha: 1), ending: NSColor(white: 0.32, alpha: 1))?
            .draw(in: circle, angle: -90)

        let glyphSize = glyph.size
        let origin = NSPoint(x: (size - glyphSize.width) / 2, y: (size - glyphSize.height) / 2)
        glyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)

        return rep.representation(using: .png, properties: [:])
    }
}

extension Image {
    /// A device symbol: SF Symbol, or one of the app's custom symbols.
    init(deviceSymbol name: String) {
        if IconRenderer.customSymbols.contains(name) {
            self.init(name)
        } else {
            self.init(systemName: name)
        }
    }
}
