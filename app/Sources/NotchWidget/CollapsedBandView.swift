import AppKit

/// The collapsed bar: one solid rounded shape filling its window, with the
/// meeting title on the left flank and the countdown on the right, positioned
/// around the notch gap. The window itself is sized to hug this content, so the
/// bar is snug rather than a fixed wide slab. The camera cutout stays physically
/// black inside it. Calm is pure black to be seamless with the notch.
final class CollapsedBandView: NSView {
    var urgency: Urgency = .calm { didSet { needsDisplay = true } }
    var leftText = "No meetings"
    var rightText = ""
    var cornerRadius: CGFloat = 11

    /// Where the notch gap sits inside this view, in local coordinates.
    var gapMinX: CGFloat = 0 { didSet { needsDisplay = true } }
    var gapWidth: CGFloat = 0

    /// When true, the bar fills black regardless of urgency — the app toggles
    /// this to flash a ≤5-minute meeting red↔black.
    var flashDark = false { didSet { needsDisplay = true } }

    /// Padding between text and the notch / outer edge — the app uses this to
    /// size the window to the text.
    static let textPad: CGFloat = 14

    override var isFlipped: Bool { false }

    func apply(_ state: BandState) {
        leftText = state.left
        rightText = state.right
        urgency = state.urgency
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        (flashDark ? NSColor.black : urgency.flankColor).setFill()
        bottomRounded(bounds, radius: cornerRadius).fill()

        // Calm is black; give it a thin colored edge (blue) so it isn't a dead
        // slab. Only when collapsed (cornerRadius > 0); when expanded it flows
        // into the panel and an outline would cut across the middle.
        if urgency == .calm && cornerRadius > 0 {
            let stroke = bottomRounded(bounds.insetBy(dx: 1, dy: 1), radius: max(1, cornerRadius - 1))
            stroke.lineWidth = 1.5
            urgency.borderColor.setStroke()
            stroke.stroke()
        }

        let h = bounds.height
        let font = NSFont(name: "JetBrains Mono", size: 11)
            ?? .monospacedSystemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: urgency.inkColor]

        let l = NSAttributedString(string: leftText, attributes: attrs)
        let ls = l.size()
        l.draw(at: NSPoint(x: gapMinX - Self.textPad - ls.width, y: h / 2 - ls.height / 2))

        let r = NSAttributedString(string: rightText, attributes: attrs)
        let rs = r.size()
        r.draw(at: NSPoint(x: gapMinX + gapWidth + Self.textPad, y: h / 2 - rs.height / 2))
    }

    private func bottomRounded(_ r: NSRect, radius: CGFloat) -> NSBezierPath {
        let rad = min(radius, r.width / 2, r.height / 2)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX, y: r.maxY))
        p.line(to: NSPoint(x: r.maxX, y: r.maxY))
        p.line(to: NSPoint(x: r.maxX, y: r.minY + rad))
        p.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: r.minY + rad),
                    radius: rad, startAngle: 0, endAngle: 270, clockwise: true)
        p.line(to: NSPoint(x: r.minX + rad, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.minX + rad, y: r.minY + rad),
                    radius: rad, startAngle: 270, endAngle: 180, clockwise: true)
        p.line(to: NSPoint(x: r.minX, y: r.maxY))
        p.close()
        return p
    }
}
