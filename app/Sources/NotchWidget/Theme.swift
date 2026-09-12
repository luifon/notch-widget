import AppKit

/// Nucleus's visual tokens (terminal × tiles, near-black + amber).
enum Theme {
    static let bg = NSColor(hex: 0x0a0a0a)
    static let surface = NSColor(hex: 0x141414)
    static let surface2 = NSColor(hex: 0x191919)
    static let border = NSColor(hex: 0x2a2a2a)
    static let ink = NSColor(hex: 0xe5e5e5)
    static let faint = NSColor(hex: 0x707070)
    static let amber = NSColor(hex: 0xe6b450)
    static let claude = NSColor(hex: 0xd97757)
    static let ok = NSColor(hex: 0x2fa96b)
    static let down = NSColor(hex: 0xd24b3b)
    static let blue = NSColor(hex: 0x4d9fff)
    static let warn = NSColor(hex: 0xe6b450)

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont(name: "JetBrains Mono", size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }
    static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        // Nucleus uses mono everywhere; keep display type mono too for consistency.
        mono(size, weight)
    }
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
    /// Mix this color with another by `t` (0…1 toward `other`).
    func mixed(with other: NSColor, _ t: CGFloat) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? self
        let b = other.usingColorSpace(.sRGB) ?? other
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                       alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t)
    }
}
