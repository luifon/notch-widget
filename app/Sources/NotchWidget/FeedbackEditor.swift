import AppKit

/// A one-field text prompt that drops under the expanded panel when the reader
/// picks `other…` as a downvote reason.
///
/// The notch panel deliberately can't become key — it lives in a CGSSpace above
/// the menu bar and must never steal focus on hover. Typing needs a key window,
/// so the editor is a separate panel that sits just under the notch panel's
/// level: high enough to float over ordinary windows, low enough that the notch
/// panel still paints over it.
final class FeedbackPanel: NSPanel {
    /// Called when the reader clicks the editor while some other app holds
    /// focus. A non-activating panel won't take it back on its own, so the
    /// owner re-activates and re-focuses the field.
    var onClickWhileInactive: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown && !NSApp.isActive { onClickWhileInactive?() }
        super.sendEvent(event)
    }
}

/// Draws the editor's surface: the same tile treatment as the panel's own tiles,
/// plus the key hint. The text field is a subview; everything else is `draw()`.
final class FeedbackEditorView: NSView {
    static let hint = "↩ save · esc cancel"

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        Theme.surface.setFill()
        NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
        let b = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        b.lineWidth = 1
        Theme.border.setStroke()
        b.stroke()

        let a = NSAttributedString(string: Self.hint, attributes: [
            .font: Theme.mono(9), .foregroundColor: Theme.faint.withAlphaComponent(0.75), .kern: 0.6,
        ])
        a.draw(at: NSPoint(x: 14, y: 11))
    }
}

/// Owns the editor panel and its lifecycle. The caller decides when it opens and
/// gets exactly one of `onSave` / `onCancel` per session, never both.
final class FeedbackEditor: NSObject, NSTextFieldDelegate {
    static let size = NSSize(width: 380, height: 64)
    static let maxLength = 500

    private(set) var isOpen = false
    private(set) var itemId: String?

    /// Trimmed, length-capped note. Empty text cancels instead of saving a blank.
    var onSave: ((String, String) -> Void)?
    var onCancel: ((String) -> Void)?

    private var panel: FeedbackPanel?
    private var field: NSTextField?
    private var previousApp: NSRunningApplication?

    /// Show the editor centered under `anchor` (the expanded panel's frame).
    func open(itemId id: String, below anchor: NSRect) {
        if isOpen { close(save: false) }
        itemId = id
        isOpen = true

        let s = Self.size
        let frame = NSRect(x: anchor.midX - s.width / 2, y: anchor.minY - 8 - s.height,
                           width: s.width, height: s.height)
        let p = panel ?? makePanel()
        p.setFrame(frame, display: false)

        field?.stringValue = ""
        // Whoever was in front comes back when the editor closes — the widget is
        // an accessory, so activating it would otherwise leave the reader's
        // focus parked on an app with no windows.
        previousApp = NSWorkspace.shared.frontmostApplication
        p.makeKeyAndOrderFront(nil)
        takeFocus()
    }

    /// Bring the app forward and put the caret back in the field.
    private func takeFocus() {
        guard let p = panel else { return }
        activateSelf()
        if let f = field {
            p.makeFirstResponder(f)
            (p.fieldEditor(true, for: f) as? NSTextView)?.insertionPointColor = Theme.amber
        }
    }

    /// Close the editor. `save: true` commits the typed note (when non-empty).
    func close(save: Bool) {
        guard isOpen, let id = itemId else { return }
        let raw = field?.stringValue ?? ""
        isOpen = false
        itemId = nil
        panel?.orderOut(nil)
        field?.stringValue = ""
        restorePreviousApp()

        let note = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLength))
        if save && !note.isEmpty { onSave?(id, note) } else { onCancel?(id) }
    }

    // MARK: NSTextFieldDelegate

    /// Return and Escape arrive here as commands, so IME composition and
    /// dictation inserting text never read as a keypress we act on.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            close(save: true); return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(save: false); return true
        default:
            return false
        }
    }

    // MARK: construction

    private func makePanel() -> FeedbackPanel {
        let p = FeedbackPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovable = false
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.appearance = NSAppearance(named: .darkAqua)
        // Above ordinary windows, below the notch panel's own space.
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        p.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        p.onClickWhileInactive = { [weak self] in
            guard let self, self.isOpen else { return }
            DispatchQueue.main.async { self.takeFocus() }
        }

        let view = FeedbackEditorView(frame: NSRect(origin: .zero, size: Self.size))
        let f = NSTextField(frame: NSRect(x: 13, y: 30, width: Self.size.width - 26, height: 22))
        f.font = Theme.mono(12)
        f.textColor = Theme.ink
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.delegate = self
        f.placeholderAttributedString = NSAttributedString(string: "why?", attributes: [
            .font: Theme.mono(12), .foregroundColor: Theme.faint,
        ])
        view.addSubview(f)
        p.contentView = view

        panel = p
        field = f
        return p
    }

    // MARK: activation

    private func activateSelf() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func restorePreviousApp() {
        guard let prev = previousApp, prev != .current else { previousApp = nil; return }
        previousApp = nil
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: prev)
        }
        prev.activate(options: [])
    }
}
