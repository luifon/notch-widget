import AppKit

/// Fills the window and reports hover in/out so the app can expand or collapse.
/// The tracking area covers the whole current bounds, so once expanded, moving
/// down into the panel still counts as "inside" and it stays open.
final class NotchContainerView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}
