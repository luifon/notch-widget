import AppKit

/// Meeting urgency drives the collapsed band's color. Thresholds (how many
/// minutes map to each state) live with the future meeting data source, not
/// here — this only defines the look of each state.
enum Urgency {
    case calm   // far off / nothing pressing
    case soon   // ~15 min out
    case now    // ~5 min / live

    var flankColor: NSColor {
        switch self {
        case .calm: return .black // pure black, seamless with the physical notch
        case .soon: return NSColor(red: 0.906, green: 0.714, blue: 0.180, alpha: 1) // amber
        case .now:  return NSColor(red: 0.843, green: 0.220, blue: 0.184, alpha: 1) // red
        }
    }

    var inkColor: NSColor {
        switch self {
        case .calm: return NSColor(white: 0.96, alpha: 1)
        case .soon: return NSColor(red: 0.10, green: 0.08, blue: 0.0, alpha: 1)
        case .now:  return .white
        }
    }

    /// Accent/border color: blue (neutral) → amber (~15 min) → red (≤5 min/live).
    /// Used for the collapsed bar's outline and the neutral card's left border.
    var borderColor: NSColor {
        switch self {
        case .calm: return NSColor(red: 0.29, green: 0.56, blue: 0.92, alpha: 1) // blue
        case .soon: return NSColor(red: 0.906, green: 0.714, blue: 0.180, alpha: 1) // amber
        case .now:  return NSColor(red: 0.843, green: 0.220, blue: 0.184, alpha: 1) // red
        }
    }

    /// Meeting-card background. Neutral is a dark card (color lives in the
    /// border); soon/now put the color on the whole background.
    var cardBackground: NSColor {
        switch self {
        case .calm: return NSColor(red: 0.09, green: 0.09, blue: 0.105, alpha: 1)
        case .soon: return NSColor(red: 0.906, green: 0.714, blue: 0.180, alpha: 1)
        case .now:  return NSColor(red: 0.843, green: 0.220, blue: 0.184, alpha: 1)
        }
    }

    /// Primary (title) text on a card.
    var cardInk: NSColor {
        switch self {
        case .calm: return .white
        case .soon: return NSColor(red: 0.12, green: 0.09, blue: 0, alpha: 1)
        case .now:  return .white
        }
    }

    /// Secondary (time / sender) text on a card.
    var cardSubtext: NSColor {
        switch self {
        case .calm: return NSColor(white: 0.55, alpha: 1)
        case .soon: return NSColor(red: 0.34, green: 0.26, blue: 0, alpha: 1)
        case .now:  return NSColor(red: 1, green: 0.85, blue: 0.83, alpha: 1)
        }
    }

    /// Only neutral cards show the accent border; colored cards don't need it.
    var showsCardBorder: Bool { self == .calm }
}
