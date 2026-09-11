import Cocoa

// Proof of concept: draw a live widget ON the notch.
// Computes the notch rectangle from the screen's auxiliary top areas
// (the menu-bar strips left and right of the notch) and pins a borderless,
// click-through, always-on-top window exactly there. Cycles green→yellow→red
// to prove it's a live process and to preview the meeting color states.

final class NotchView: NSView {
    var color: NSColor = .systemGreen
    override func draw(_ dirty: NSRect) {
        color.setFill()
        let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        r.fill()
        let label = "NUCLEUS ▸ notch POC"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                               y: (bounds.height - size.height) / 2),
                   withAttributes: attrs)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: NotchView!
    var phase = 0
    let colors: [NSColor] = [.systemGreen, .systemYellow, .systemRed]

    func notchRect(on screen: NSScreen) -> NSRect {
        let notchH = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 38
        let hang: CGFloat = 44   // extend below the notch so a visible strip shows
        let totalH = notchH + hang
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let x = left.maxX
            let w = right.minX - left.maxX
            let y = screen.frame.maxY - totalH
            return NSRect(x: x, y: y, width: w, height: totalH)
        }
        // Fallback: a centered strip at the top if this display has no notch.
        let w: CGFloat = 200
        return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - totalH, width: w, height: totalH)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // Target the built-in notched display specifically, not whichever
        // screen has focus (NSScreen.main). The notched screen is the one with
        // a top safe-area inset.
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
                ?? NSScreen.main else { return }
        let frame = notchRect(on: screen)
        window = NSWindow(contentRect: frame, styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        view = NotchView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        window.orderFrontRegardless()

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase = (self.phase + 1) % self.colors.count
            self.view.color = self.colors[self.phase]
            self.view.needsDisplay = true
        }

        FileHandle.standardError.write("notch POC up — rect \(frame)\n".data(using: .utf8)!)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
