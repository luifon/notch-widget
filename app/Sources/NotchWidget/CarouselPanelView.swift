import AppKit
import QuartzCore

/// A page in the expanded carousel.
enum PageContent {
    case meetings([MeetingCard])
    case finance(FinanceSummary)
    case agents(AgentsSummary)
    case simple(kicker: String, title: String, meta: String)
}

/// The panel that drops below the notch when expanded. One page at a time;
/// click the left/right edge (or the arrows) to page. Black with rounded bottom
/// corners so it joins the collapsed band above it.
final class CarouselPanelView: NSView {
    var pages: [PageContent] = [] { didSet { clampIndex(); needsDisplay = true } }
    var index: Int = 0 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 16

    // Shared layout constants (the app uses these to size the window).
    static let headerH: CGFloat = 34
    static let cardH: CGFloat = 64
    static let cardGap: CGFloat = 10
    static let dotsH: CGFloat = 28
    static let arrowZone: CGFloat = 44

    static func panelHeight(meetingCards n: Int) -> CGFloat {
        let c = max(1, min(3, n))
        return headerH + CGFloat(c) * cardH + CGFloat(c - 1) * cardGap + dotsH
    }

    /// Fixed height the finance page needs (NW + delta + liquid + 3 movers).
    static let financeHeight: CGFloat = 200

    /// Height the agents page needs for `n` rows (up to 4 shown).
    static func agentsHeight(_ n: Int) -> CGFloat {
        let c = max(1, min(4, n))
        return headerH + CGFloat(c) * 42 + dotsH
    }

    /// Called with a meeting id when its card is clicked (used to acknowledge
    /// an alerting meeting and stop the flash).
    var onCardClick: ((String) -> Void)?
    private var cardHits: [(rect: NSRect, id: String)] = []

    private enum Side { case left, right }
    private var hoveredArrow: Side?
    private var leftTA: NSTrackingArea?
    private var rightTA: NSTrackingArea?

    private let dim = NSColor(white: 0.55, alpha: 1)
    private let amber = NSColor(red: 0.949, green: 0.710, blue: 0.227, alpha: 1)
    private let cardBG = NSColor(red: 0.09, green: 0.09, blue: 0.105, alpha: 1)
    private let up = NSColor(red: 0.30, green: 0.72, blue: 0.42, alpha: 1)
    private let down = NSColor(red: 0.85, green: 0.32, blue: 0.29, alpha: 1)
    private lazy var brl: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "pt_BR")
        f.maximumFractionDigits = 0
        return f
    }()

    override var isFlipped: Bool { false }

    // MARK: hover on arrows

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        [leftTA, rightTA].forEach { if let t = $0 { removeTrackingArea(t) } }
        let z = Self.arrowZone
        let l = NSTrackingArea(rect: NSRect(x: 0, y: 0, width: z, height: bounds.height),
                               options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: ["side": "left"])
        let r = NSTrackingArea(rect: NSRect(x: bounds.maxX - z, y: 0, width: z, height: bounds.height),
                               options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: ["side": "right"])
        addTrackingArea(l); addTrackingArea(r); leftTA = l; rightTA = r
    }

    override func mouseEntered(with event: NSEvent) {
        guard let side = event.trackingArea?.userInfo?["side"] as? String else { return }
        hoveredArrow = (side == "left") ? .left : .right
        NSCursor.pointingHand.set()
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hoveredArrow = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    // MARK: paging

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if pages.count > 1 && p.x < Self.arrowZone { page(-1); return }
        if pages.count > 1 && p.x > bounds.maxX - Self.arrowZone { page(1); return }
        // click on a meeting card → acknowledge it
        if let hit = cardHits.first(where: { $0.rect.contains(p) }) {
            onCardClick?(hit.id)
        }
    }

    /// Page with a horizontal push transition.
    func page(_ delta: Int) {
        guard pages.count > 1 else { return }
        let t = CATransition()
        t.type = .push
        t.subtype = delta > 0 ? .fromRight : .fromLeft
        t.duration = 0.22
        t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(t, forKey: "page")
        index = (index + delta + pages.count) % pages.count
    }

    private func clampIndex() {
        if pages.isEmpty { index = 0 }
        else if index >= pages.count { index = pages.count - 1 }
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bottomRounded(bounds, radius: cornerRadius).fill()
        guard !pages.isEmpty else { return }

        switch pages[index] {
        case .meetings(let cards): drawMeetings(cards)
        case .finance(let s): drawFinance(s)
        case .agents(let a): drawAgents(a)
        case .simple(let k, let t, let m): drawSimple(k, t, m)
        }

        if pages.count > 1 { drawArrowsAndDots() }
    }

    private func contentRect() -> NSRect {
        NSRect(x: Self.arrowZone, y: Self.dotsH,
               width: bounds.width - Self.arrowZone * 2, height: bounds.height - Self.dotsH)
    }

    private func drawMeetings(_ cards: [MeetingCard]) {
        let c = contentRect()
        draw("NEXT MEETINGS", at: NSPoint(x: c.minX, y: bounds.maxY - 24),
             font: mono(10, .semibold), color: dim, kern: 1.4)

        if cards.isEmpty {
            draw("No meetings in the next 18h", at: NSPoint(x: c.minX, y: bounds.maxY - 52),
                 font: sans(14, .medium), color: dim)
            return
        }

        cardHits.removeAll()
        var top = bounds.maxY - Self.headerH
        for card in cards.prefix(3) {
            let rect = NSRect(x: c.minX, y: top - Self.cardH, width: c.width, height: Self.cardH)
            drawCard(card, in: rect)
            cardHits.append((rect, card.id))
            top -= Self.cardH + Self.cardGap
        }
    }

    private func drawCard(_ card: MeetingCard, in rect: NSRect) {
        let u = card.urgency
        u.cardBackground.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()

        // Neutral cards carry the color as a left border; colored cards don't.
        let hasBorder = u.showsCardBorder
        if hasBorder {
            u.borderColor.setFill()
            let bar = NSRect(x: rect.minX + 10, y: rect.minY + 10, width: 4, height: rect.height - 20)
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        }

        let x = rect.minX + (hasBorder ? 28 : 18)
        let w = rect.width - x - 16
        let hasSender = !card.sender.isEmpty
        let titleY = hasSender ? rect.maxY - 23 : rect.maxY - 24
        let timeY  = hasSender ? rect.maxY - 45 : rect.maxY - 46
        draw(truncate(card.title, w: w, font: sans(13, .semibold)),
             at: NSPoint(x: x, y: titleY), font: sans(13, .semibold), color: u.cardInk)
        draw(card.time, at: NSPoint(x: x, y: timeY), font: mono(11, .regular), color: u.cardSubtext)
        if hasSender {
            draw(truncate("with \(card.sender)", w: w, font: sans(10, .regular)),
                 at: NSPoint(x: x, y: rect.minY + 9), font: sans(10, .regular), color: u.cardSubtext)
        }
    }

    private func drawFinance(_ s: FinanceSummary) {
        let c = contentRect()
        draw("NET WORTH", at: NSPoint(x: c.minX, y: bounds.maxY - 24),
             font: mono(10, .semibold), color: dim, kern: 1.4)

        let nwStr = brl.string(from: NSNumber(value: s.netWorth)) ?? "—"
        draw(nwStr, at: NSPoint(x: c.minX, y: bounds.maxY - 54), font: sans(21, .bold), color: .white)

        if let dAbs = s.deltaAbs, let dPct = s.deltaPct {
            let pos = dAbs >= 0
            let sign = pos ? "+" : "−"
            let absStr = brl.string(from: NSNumber(value: abs(dAbs))) ?? ""
            let line = "\(pos ? "▲" : "▼") \(sign)\(absStr)  (\(sign)\(String(format: "%.2f", abs(dPct)))%)"
            draw(line, at: NSPoint(x: c.minX, y: bounds.maxY - 80), font: mono(12, .medium), color: pos ? up : down)
        } else {
            draw("no change yet", at: NSPoint(x: c.minX, y: bounds.maxY - 80),
                 font: mono(12, .regular), color: dim)
        }

        let liq = brl.string(from: NSNumber(value: s.liquidNetWorth)) ?? "—"
        draw("Liquid  \(liq)", at: NSPoint(x: c.minX, y: bounds.maxY - 104),
             font: mono(11, .regular), color: NSColor(white: 0.62, alpha: 1))

        var y = bounds.maxY - 134
        for m in s.movers.prefix(3) {
            let pos = m.deltaAbs >= 0
            draw(truncate(m.name, w: c.width - 70, font: sans(11, .regular)),
                 at: NSPoint(x: c.minX, y: y), font: sans(11, .regular), color: NSColor(white: 0.72, alpha: 1))
            let pct = "\(pos ? "+" : "−")\(String(format: "%.1f", abs(m.deltaPct)))%"
            draw(pct, at: NSPoint(x: c.maxX - 52, y: y), font: mono(11, .regular), color: pos ? up : down)
            y -= 20
        }
    }

    private func drawAgents(_ s: AgentsSummary) {
        let c = contentRect()
        let head = s.count == 0 ? "AGENTS" : "AGENTS · \(s.count) NEED YOU"
        draw(head, at: NSPoint(x: c.minX, y: bounds.maxY - 24), font: mono(10, .semibold), color: dim, kern: 1.4)

        if s.needsAttention.isEmpty {
            draw("All agents clear", at: NSPoint(x: c.minX, y: bounds.maxY - 52),
                 font: sans(14, .medium), color: dim)
            return
        }

        let codexBlue = NSColor(red: 0.36, green: 0.62, blue: 0.90, alpha: 1)
        var y = bounds.maxY - 46
        for it in s.needsAttention.prefix(4) {
            (it.engine == "codex" ? codexBlue : amber).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.minX + 1, y: y - 2, width: 7, height: 7)).fill()
            draw(truncate(it.label, w: c.width - 24, font: sans(13, .semibold)),
                 at: NSPoint(x: c.minX + 16, y: y - 6), font: sans(13, .semibold), color: .white)
            let repoPart = it.repo.isEmpty ? "" : "\(it.repo) · "
            draw("\(repoPart)\(it.engine) · \(it.state)\(ago(it.since))",
                 at: NSPoint(x: c.minX + 16, y: y - 22), font: mono(10, .regular), color: dim)
            y -= 42
        }
    }

    private func ago(_ sinceMs: Double?) -> String {
        guard let ms = sinceMs else { return "" }
        let secs = Int(Date().timeIntervalSince1970 - ms / 1000)
        if secs < 60 { return " · now" }
        let m = secs / 60
        if m < 60 { return " · \(m)m" }
        return " · \(m / 60)h\(m % 60)m"
    }

    private func drawSimple(_ kicker: String, _ title: String, _ meta: String) {
        let c = contentRect()
        draw(kicker.uppercased(), at: NSPoint(x: c.minX, y: bounds.maxY - 24),
             font: mono(10, .semibold), color: dim, kern: 1.4)
        draw(title, at: NSPoint(x: c.minX, y: bounds.maxY - 50), font: sans(16, .semibold), color: .white)
        draw(meta, at: NSPoint(x: c.minX, y: bounds.maxY - 74), font: mono(12, .regular), color: dim)
    }

    private func drawArrowsAndDots() {
        drawArrow("‹", side: .left, centerX: Self.arrowZone / 2)
        drawArrow("›", side: .right, centerX: bounds.maxX - Self.arrowZone / 2)

        let n = pages.count, gap: CGFloat = 12, rr: CGFloat = 3
        var dx = bounds.midX - CGFloat(n - 1) * gap / 2
        for i in 0..<n {
            (i == index ? amber : NSColor(white: 0.25, alpha: 1)).setFill()
            NSBezierPath(ovalIn: NSRect(x: dx - rr, y: 11, width: rr * 2, height: rr * 2)).fill()
            dx += gap
        }
    }

    private func drawArrow(_ glyph: String, side: Side, centerX: CGFloat) {
        let hovered = hoveredArrow == side
        let cy = bounds.midY
        if hovered {
            NSColor(white: 1, alpha: 0.14).setFill()
            NSBezierPath(ovalIn: NSRect(x: centerX - 15, y: cy - 15, width: 30, height: 30)).fill()
        }
        draw(glyph, centeredX: centerX, y: cy, font: mono(20, .regular),
             color: hovered ? .white : dim)
    }

    // MARK: text helpers

    private func mono(_ s: CGFloat, _ w: NSFont.Weight) -> NSFont {
        NSFont(name: "JetBrains Mono", size: s) ?? .monospacedSystemFont(ofSize: s, weight: w)
    }
    private func sans(_ s: CGFloat, _ w: NSFont.Weight) -> NSFont { .systemFont(ofSize: s, weight: w) }

    private func draw(_ s: String, at p: NSPoint, font: NSFont, color: NSColor, kern: CGFloat = 0) {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern]).draw(at: p)
    }
    private func draw(_ s: String, centeredX cx: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let sz = str.size()
        str.draw(at: NSPoint(x: cx - sz.width / 2, y: y - sz.height / 2))
    }
    private func truncate(_ s: String, w: CGFloat, font: NSFont) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (s as NSString).size(withAttributes: attrs).width <= w { return s }
        var t = s
        while t.count > 1 && ((t + "…") as NSString).size(withAttributes: attrs).width > w {
            t.removeLast()
        }
        return t + "…"
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
