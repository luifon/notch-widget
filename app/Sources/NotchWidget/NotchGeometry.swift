import AppKit

/// Position of the built-in notch, in screen coordinates (bottom-left origin).
/// The window frames are computed from this: the collapsed bar hugs its content,
/// the expanded panel is a fixed wider width centered on the notch.
struct NotchGeometry {
    let screenFrame: NSRect
    let visibleFrame: NSRect   // screen minus menu bar and Dock — the expansion limit
    let topInset: CGFloat
    let notchLeftX: CGFloat
    let notchRightX: CGFloat

    var gapWidth: CGFloat { notchRightX - notchLeftX }
    var notchCenterX: CGFloat { (notchLeftX + notchRightX) / 2 }
    var topY: CGFloat { screenFrame.maxY }

    static func current() -> NotchGeometry? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
        else { return nil }
        let inset = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 32
        let f = screen.frame
        let lx: CGFloat, rx: CGFloat
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            lx = l.maxX; rx = r.minX
        } else {
            lx = f.midX - 90; rx = f.midX + 90   // no notch — fake a centered gap for testing
        }
        return NotchGeometry(screenFrame: f, visibleFrame: screen.visibleFrame,
                             topInset: inset, notchLeftX: lx, notchRightX: rx)
    }

    /// Collapsed bar: hugs the given flank widths around the notch, clamped to
    /// the screen. `barExtra` makes it taller than the menu bar so its rounded
    /// bottom edge hangs below the notch line (otherwise it's clipped).
    func collapsedFrame(leftFlank: CGFloat, rightFlank: CGFloat, barExtra: CGFloat) -> (frame: NSRect, gapMinX: CGFloat) {
        let x = max(screenFrame.minX, notchLeftX - leftFlank)
        let maxX = min(screenFrame.maxX, notchRightX + rightFlank)
        let h = topInset + barExtra
        let frame = NSRect(x: x, y: topY - h, width: maxX - x, height: h)
        return (frame, notchLeftX - x)
    }

    /// Expanded panel: fixed width centered on the notch. `barExtra` keeps the
    /// band portion the same height as the collapsed bar. The total height is
    /// clamped to the visible frame, so a tall page stops above the Dock instead
    /// of running off the screen; the page then draws into whatever it got.
    func expandedFrame(width: CGFloat, panelHeight: CGFloat, barExtra: CGFloat) -> (frame: NSRect, gapMinX: CGFloat) {
        let x = max(screenFrame.minX, min(notchCenterX - width / 2, screenFrame.maxX - width))
        let bar = topInset + barExtra
        let h = max(bar, min(bar + panelHeight, topY - visibleFrame.minY))
        let frame = NSRect(x: x, y: topY - h, width: width, height: h)
        return (frame, notchLeftX - x)
    }
}
