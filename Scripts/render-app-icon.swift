#!/usr/bin/env swift
// Builds the app icon as an Icon Composer document (App/AppIcon.icon).
// Usage: swift Scripts/render-app-icon.swift
//
// The icon has no background color of its own: "fill": "automatic" lets macOS
// draw a light tile in Light mode and a dark one in Dark mode (and handle Clear
// and Tinted). The speaker body and its sound waves are two layers whose color
// flips with the appearance; "automatic-gradient" adds subtle shading, and the
// system adds its glass highlights and shadow on top.

import AppKit

let canvas: CGFloat = 1024

/// Renders speaker.wave.3.fill in black on a transparent 1024 pt canvas and
/// splits it at the empty column between the speaker body and the first wave.
func renderLayers() -> (speaker: Data, waves: Data) {
    let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
    else { fatalError("SF Symbols unavailable") }

    func blankCanvas() -> NSBitmapImageRep {
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
    }

    let full = blankCanvas()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: full)
    // Centered, a touch to the right so the speaker looks optically centered.
    let size = symbol.size
    symbol.draw(in: NSRect(x: (canvas - size.width) / 2 + 10, y: (canvas - size.height) / 2, width: size.width, height: size.height))
    NSGraphicsContext.restoreGraphicsState()

    // Find the gap: first transparent column after the body's opaque columns.
    let width = full.pixelsWide, height = full.pixelsHigh
    func columnIsEmpty(_ x: Int) -> Bool {
        (0..<height).allSatisfy { (full.colorAt(x: x, y: $0)?.alphaComponent ?? 0) < 0.01 }
    }
    guard let bodyStart = (0..<width).first(where: { !columnIsEmpty($0) }),
          let gap = (bodyStart..<width).first(where: columnIsEmpty)
    else { fatalError("could not split the symbol") }

    func copy(columns: Range<Int>) -> Data {
        let rep = blankCanvas()
        for x in columns {
            for y in 0..<height {
                if let color = full.colorAt(x: x, y: y), color.alphaComponent > 0 {
                    rep.setColor(color, atX: x, y: y)
                }
            }
        }
        return rep.representation(using: .png, properties: [:])!
    }
    return (copy(columns: 0..<gap), copy(columns: gap..<width))
}

func colorLayer(name: String, image: String, light: String, dark: String) -> [String: Any] {
    [
        "name": name,
        "image-name": image,
        "fill-specializations": [
            ["value": ["automatic-gradient": light]],
            ["appearance": "dark", "value": ["automatic-gradient": dark]],
        ],
        "position": ["scale": 1, "translation-in-points": [0, 0]],
    ]
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconURL = root.appending(path: "App/AppIcon.icon")
let assets = iconURL.appending(path: "Assets")
try? FileManager.default.removeItem(at: iconURL)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
let layers = renderLayers()
try layers.speaker.write(to: assets.appending(path: "Speaker.png"))
try layers.waves.write(to: assets.appending(path: "Waves.png"))

let document: [String: Any] = [
    "fill": "automatic",
    "groups": [
        [
            // Listed front to back: waves sit a little lighter than the body.
            "layers": [
                colorLayer(name: "Waves", image: "Waves.png",
                           light: "srgb:0.36000,0.37500,0.42000,1.00000",
                           dark: "srgb:0.78000,0.80000,0.85000,1.00000"),
                colorLayer(name: "Speaker", image: "Speaker.png",
                           light: "srgb:0.15000,0.15500,0.18000,1.00000",
                           dark: "srgb:0.95000,0.95500,0.97000,1.00000"),
            ],
            "shadow": ["kind": "neutral", "opacity": 0.45],
            "translucency": ["enabled": true, "value": 0.25],
            "specular": true,
        ],
    ],
    "supported-platforms": ["squares": ["macOS"]],
]
try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconURL.appending(path: "icon.json"))
print("Wrote \(iconURL.path)")
