import AppKit

/// Loads the bundled engine brand marks and tints them.
enum Icons {
    static let claude = load("claude", tint: Theme.claude)
    static let openai = load("openai", tint: Theme.ink)

    static func engine(_ name: String) -> NSImage? {
        name == "codex" ? openai : (name == "claude" ? claude : nil)
    }

    private static func load(_ name: String, tint: NSColor) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        return tinted(img, tint)
    }

    /// qlmanage rendered the marks as a dark shape on an opaque (white)
    /// background, so a plain source-atop tint fills the whole square. Instead
    /// key on darkness: output = tint color with alpha = srcAlpha × (1 − luma).
    /// Black shape → opaque tint; white/transparent background → clear. Works
    /// whether the source background is white-opaque or already transparent.
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let src = NSBitmapImageRep(data: tiff) else { return image }
        let w = src.pixelsWide, h = src.pixelsHigh
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32) else { return image }
        let c = color.usingColorSpace(.deviceRGB) ?? color
        for y in 0..<h {
            for x in 0..<w {
                let p = src.colorAt(x: x, y: y) ?? .clear
                let luma = p.redComponent * 0.299 + p.greenComponent * 0.587 + p.blueComponent * 0.114
                let a = p.alphaComponent * (1 - luma)
                out.setColor(NSColor(deviceRed: c.redComponent, green: c.greenComponent,
                                     blue: c.blueComponent, alpha: a), atX: x, y: y)
            }
        }
        let img = NSImage(size: NSSize(width: w, height: h))
        img.addRepresentation(out)
        return img
    }
}
