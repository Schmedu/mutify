#!/usr/bin/env swift
// Draws Mutify's app icon: a muted speaker on a rounded gradient tile.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Big Sur-style content area: inset, heavily rounded.
let inset: CGFloat = 96
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tile = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.35, blue: 0.85, alpha: 1),
    NSColor(calibratedRed: 0.36, green: 0.20, blue: 0.68, alpha: 1),
])!
gradient.draw(in: tile, angle: -90)

if let symbol = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil) {
    // Palette colours render the glyph white directly; compositing tricks on top
    // of an opaque tile just paint a rectangle.
    let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let glyph = symbol.withSymbolConfiguration(config) ?? symbol
    let maxSide: CGFloat = 470
    let scale = min(maxSide / glyph.size.width, maxSide / glyph.size.height)
    let drawSize = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
    let origin = NSPoint(x: (size - drawSize.width) / 2, y: (size - drawSize.height) / 2)
    glyph.draw(in: NSRect(origin: origin, size: drawSize), from: .zero, operation: .sourceOver, fraction: 1)
}

image.unlockFocus()

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not render icon\n".utf8))
    exit(1)
}
try png.write(to: output)
