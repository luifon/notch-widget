import AppKit
import QuartzCore

/// A page in the expanded carousel.
enum PageContent {
    case meetings([MeetingCard])
    case finance(FinanceSummary)
    case agents(AgentsSummary)
    case weather(WeatherSummary)
    case simple(kicker: String, title: String, meta: String)
}

/// The panel that drops below the notch. Nucleus terminal×tiles look: near-black
/// panel, surface tiles, amber corner tag, mono type. One page at a time.
final class CarouselPanelView: NSView {
    var pages: [PageContent] = [] { didSet { clampIndex(); needsDisplay = true } }
    var index: Int = 0 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 18

    static let headerH: CGFloat = 54   // header bar + a clear gap before content
    static let cardH: CGFloat = 64
    static let cardGap: CGFloat = 10
    static let dotsH: CGFloat = 28
    static let arrowZone: CGFloat = 44

    static func panelHeight(meetingCards n: Int) -> CGFloat {
        let c = max(1, min(3, n))
        return headerH + CGFloat(c) * cardH + CGFloat(c - 1) * cardGap + dotsH
    }
    static func agentsHeight(_ n: Int) -> CGFloat { headerH + CGFloat(max(1, min(4, n))) * 52 + dotsH }
    static func financeHeight(_ s: FinanceSummary) -> CGFloat {
        var h: CGFloat = headerH + 34 + 22 + dotsH   // header + NW + liquid + dots
        if s.deltaAbs != nil { h += 28 }
        if (s.series?.count ?? 0) > 1 { h += 44 }
        h += CGFloat(min(3, s.movers.count)) * 22
        return h
    }
    static let weatherHeight: CGFloat = 222

    var onCardClick: ((String) -> Void)?
    private var cardHits: [(rect: NSRect, id: String)] = []
    var onAgentClick: ((String) -> Void)?
    private var agentHits: [(rect: NSRect, id: String)] = []

    private enum Side { case left, right }
    private var hoveredArrow: Side?
    private var leftTA: NSTrackingArea?
    private var rightTA: NSTrackingArea?

    override var isFlipped: Bool { false }

    // MARK: arrow hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        [leftTA, rightTA].forEach { if let t = $0 { removeTrackingArea(t) } }
        let z = Self.arrowZone
        let l = NSTrackingArea(rect: NSRect(x: 0, y: 0, width: z, height: bounds.height),
                               options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: ["side": "left"])
        let r = NSTrackingArea(rect: NSRect(x: bounds.maxX - z, y: 0, width: z, height: bounds.height),
                               options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: ["side": "right"])
        addTrackingArea(l); addTrackingArea(r); leftTA = l; rightTA = r
    }
    override func mouseEntered(with e: NSEvent) {
        guard let s = e.trackingArea?.userInfo?["side"] as? String else { return }
        hoveredArrow = (s == "left") ? .left : .right; NSCursor.pointingHand.set(); needsDisplay = true
    }
    override func mouseExited(with e: NSEvent) { hoveredArrow = nil; NSCursor.arrow.set(); needsDisplay = true }

    // MARK: clicks

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if pages.count > 1 && p.x < Self.arrowZone { page(-1); return }
        if pages.count > 1 && p.x > bounds.maxX - Self.arrowZone { page(1); return }
        if let hit = cardHits.first(where: { $0.rect.contains(p) }) { onCardClick?(hit.id); return }
        if let hit = agentHits.first(where: { $0.rect.contains(p) }) { onAgentClick?(hit.id) }
    }

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
        if pages.isEmpty { index = 0 } else if index >= pages.count { index = pages.count - 1 }
    }

    // MARK: draw

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill()
        bottomRounded(bounds, radius: cornerRadius).fill()
        guard !pages.isEmpty else { return }
        cardHits.removeAll(); agentHits.removeAll()

        switch pages[index] {
        case .meetings(let cards): tag("NEXT MEETINGS"); drawMeetings(cards)
        case .finance(let s): tag("NET WORTH"); drawFinance(s)
        case .agents(let a): tag("AGENTS", right: a.count == 0 ? nil : "\(a.count) need you"); drawAgents(a)
        case .weather(let w): tag("WEATHER", right: w.place); drawWeather(w)
        case .simple(let k, let t, let m): tag(k.uppercased()); drawSimple(t, m)
        }
        if pages.count > 1 { drawArrowsAndDots() }
    }

    private func content() -> NSRect {
        NSRect(x: Self.arrowZone, y: Self.dotsH,
               width: bounds.width - Self.arrowZone * 2, height: bounds.height - Self.dotsH - 36)
    }

    // MARK: pages

    private func drawMeetings(_ cards: [MeetingCard]) {
        let c = content()
        if cards.isEmpty { text("No meetings in the next 18h", NSPoint(x: c.minX, y: bounds.maxY - 60), Theme.mono(13), Theme.faint); return }
        var top = bounds.maxY - Self.headerH
        for card in cards.prefix(3) {
            let r = NSRect(x: c.minX, y: top - Self.cardH, width: c.width, height: Self.cardH)
            drawMeetingCard(card, r); cardHits.append((r, card.id))
            top -= Self.cardH + Self.cardGap
        }
    }

    private func drawMeetingCard(_ card: MeetingCard, _ r: NSRect) {
        let u = card.urgency
        u.cardBackground.setFill(); NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11).fill()
        if u.showsCardBorder {   // neutral: blue border
            let b = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
            b.lineWidth = 1; Theme.border.setStroke(); b.stroke()
            u.borderColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX + 10, y: r.minY + 12, width: 3, height: r.height - 24), xRadius: 2, yRadius: 2).fill()
        }
        let x = r.minX + (u.showsCardBorder ? 26 : 18); let w = r.width - x - 16
        let hasSender = !card.sender.isEmpty
        text(truncate(card.title, w, Theme.mono(13, .semibold)), NSPoint(x: x, y: r.maxY - 24), Theme.mono(13, .semibold), u.cardInk)
        text(card.time, NSPoint(x: x, y: r.maxY - 42), Theme.mono(11), u.cardSubtext)
        if hasSender { text(truncate("with \(card.sender)", w, Theme.mono(10)), NSPoint(x: x, y: r.minY + 10), Theme.mono(10), u.cardSubtext) }
    }

    private func drawAgents(_ s: AgentsSummary) {
        let c = content()
        if s.needsAttention.isEmpty { text("All agents clear", NSPoint(x: c.minX, y: bounds.maxY - 60), Theme.mono(13), Theme.faint); return }
        var top = bounds.maxY - Self.headerH
        for it in s.needsAttention.prefix(4) {
            let r = NSRect(x: c.minX, y: top - 46, width: c.width, height: 46)
            drawAgentTile(it, r); agentHits.append((r, it.id))
            top -= 52
        }
    }

    private func drawAgentTile(_ it: AgentsSummary.Item, _ r: NSRect) {
        tile(r)
        // avatar chip + engine mark
        let av = NSRect(x: r.minX + 8, y: r.midY - 15, width: 30, height: 30)
        Theme.surface2.setFill(); NSBezierPath(roundedRect: av, xRadius: 9, yRadius: 9).fill()
        let b = NSBezierPath(roundedRect: av.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9); b.lineWidth = 1; Theme.border.setStroke(); b.stroke()
        if let icon = Icons.engine(it.engine) {
            icon.draw(in: NSRect(x: av.midX - 8.5, y: av.midY - 8.5, width: 17, height: 17))
        }
        let x = r.minX + 48
        text(truncate(it.label, r.width - 130, Theme.mono(13, .semibold)), NSPoint(x: x, y: r.maxY - 22), Theme.mono(13, .semibold), Theme.ink)
        // branch chip + ago
        var sx = x
        if !it.detail.isEmpty { sx = chip(it.detail, at: NSPoint(x: x, y: r.minY + 9)) + 6 }
        text(ago(it.since), NSPoint(x: sx, y: r.minY + 11), Theme.mono(10), Theme.faint)
        // state pill
        pill(it.state, color: stateColor(it.state), rightOf: r)
    }

    private func drawWeather(_ w: WeatherSummary) {
        let c = content()
        let top = bounds.maxY - Self.headerH   // content top, clear of the header
        drawWeatherIcon(NSRect(x: c.minX, y: top - 48, width: 48, height: 48), code: w.code)
        let temp = "\(Int(round(w.tempC)))°"
        text(temp, NSPoint(x: c.minX + 58, y: top - 36), Theme.mono(34, .bold), Theme.ink)
        let tw = (temp as NSString).size(withAttributes: [.font: Theme.mono(34, .bold)]).width
        text(w.label, NSPoint(x: c.minX + 58 + tw + 14, y: top - 26), Theme.mono(14), Theme.ink)
        let sub = "feels \(Int(round(w.feelsC)))°     H \(Int(round(w.maxC)))°     L \(Int(round(w.minC)))°"
        text(sub, NSPoint(x: c.minX, y: top - 62), Theme.mono(12), Theme.faint)

        // hourly strip
        guard !w.hourly.isEmpty else { return }
        let divY = top - 78
        Theme.border.setStroke()
        let div = NSBezierPath(); div.move(to: NSPoint(x: c.minX, y: divY)); div.line(to: NSPoint(x: c.maxX, y: divY)); div.lineWidth = 1; div.stroke()
        let cols = Array(w.hourly.prefix(5)); let colW = c.width / CGFloat(cols.count)
        for (i, h) in cols.enumerated() {
            let cx = c.minX + colW * CGFloat(i) + colW / 2
            centerText(h.label, cx: cx, y: divY - 20, Theme.mono(10), Theme.faint)
            hourDotColor(h.code).setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - 3.5, y: divY - 36, width: 7, height: 7)).fill()
            centerText("\(Int(round(h.tempC)))°", cx: cx, y: divY - 56, Theme.mono(11, .semibold), Theme.ink)
        }
    }

    private func centerText(_ s: String, cx: CGFloat, y: CGFloat, _ font: NSFont, _ color: NSColor) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        a.draw(at: NSPoint(x: cx - a.size().width / 2, y: y))
    }
    private func hourDotColor(_ code: Int) -> NSColor {
        switch code {
        case 0, 1: return Theme.amber
        case 51...67, 80...82, 95...99: return Theme.blue
        case 71...77, 85, 86: return Theme.ink
        default: return Theme.faint
        }
    }

    private func drawFinance(_ s: FinanceSummary) {
        let c = content()
        var y = bounds.maxY - 82   // NW baseline, clear of the header divider

        text(brl(s.netWorth), NSPoint(x: c.minX, y: y), Theme.mono(28, .bold), Theme.ink)
        y -= 30

        if let d = s.deltaAbs, let p = s.deltaPct {
            let up = d >= 0; let col = up ? Theme.ok : Theme.down
            let s2 = "\(up ? "▲" : "▼") \(up ? "+" : "−")\(brl(abs(d)))  \(up ? "+" : "−")\(String(format: "%.2f", abs(p)))%"
            let f = Theme.mono(12, .semibold); let sz = (s2 as NSString).size(withAttributes: [.font: f])
            let pr = NSRect(x: c.minX, y: y - 3, width: sz.width + 16, height: 20)
            col.withAlphaComponent(0.13).setFill(); NSBezierPath(roundedRect: pr, xRadius: 6, yRadius: 6).fill()
            text(s2, NSPoint(x: pr.minX + 8, y: pr.midY - sz.height / 2), f, col)
            y -= 28
        }

        text("Liquid · \(brl(s.liquidNetWorth))", NSPoint(x: c.minX, y: y), Theme.mono(11), Theme.faint)
        y -= 22

        if let series = s.series, series.count > 1 {
            drawSparkline(series, in: NSRect(x: c.minX, y: y - 34, width: c.width, height: 34))
            y -= 44
        }
        for m in s.movers.prefix(3) { drawMover(m, at: y, width: c.width, x: c.minX); y -= 22 }
    }

    private func drawSimple(_ title: String, _ meta: String) {
        let c = content(); let top = bounds.maxY - Self.headerH
        text(title, NSPoint(x: c.minX, y: top - 24), Theme.mono(16, .semibold), Theme.ink)
        text(meta, NSPoint(x: c.minX, y: top - 48), Theme.mono(12), Theme.faint)
    }

    // MARK: components

    private func tag(_ label: String, right: String? = nil) {
        // Header bar: tag pill + optional count, with a full-width divider below.
        let f = Theme.mono(9.5, .semibold)
        let a = NSAttributedString(string: label, attributes: [.font: f, .foregroundColor: Theme.amber, .kern: 1.3])
        let sz = a.size(); let padX: CGFloat = 7
        // Align the header to the same left/right margins as the tiles below
        // (which are inset by the arrow column), so the badge lines up with them.
        let r = NSRect(x: Self.arrowZone, y: bounds.maxY - 26, width: ceil(sz.width) + padX * 2, height: 17)
        Theme.amber.withAlphaComponent(0.09).setFill(); NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        let b = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5); b.lineWidth = 1; Theme.amber.withAlphaComponent(0.4).setStroke(); b.stroke()
        a.draw(at: NSPoint(x: r.minX + padX, y: r.midY - sz.height / 2))
        if let right {
            let rs = NSAttributedString(string: right, attributes: [.font: Theme.mono(10), .foregroundColor: Theme.faint])
            let z = rs.size(); rs.draw(at: NSPoint(x: bounds.maxX - Self.arrowZone - z.width, y: r.midY - z.height / 2))
        }
        let divY = bounds.maxY - 36
        let d = NSBezierPath(); d.move(to: NSPoint(x: 0, y: divY)); d.line(to: NSPoint(x: bounds.width, y: divY)); d.lineWidth = 1
        Theme.border.setStroke(); d.stroke()
    }

    private func tile(_ r: NSRect) {
        Theme.surface.setFill(); NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11).fill()
        let b = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11); b.lineWidth = 1
        Theme.border.setStroke(); b.stroke()
    }

    @discardableResult
    private func chip(_ s: String, at p: NSPoint) -> CGFloat {
        let f = Theme.mono(9.5); let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: Theme.faint])
        let sz = a.size(); let padX: CGFloat = 5
        let r = NSRect(x: p.x, y: p.y - 2, width: sz.width + padX * 2, height: sz.height + 4)
        let b = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5); b.lineWidth = 1; Theme.border.setStroke(); b.stroke()
        a.draw(at: NSPoint(x: r.minX + padX, y: r.minY + 2))
        return r.maxX
    }

    private func pill(_ s: String, color: NSColor, rightOf r: NSRect) {
        let f = Theme.mono(9.5, .semibold); let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color])
        let sz = a.size(); let padX: CGFloat = 7
        let pr = NSRect(x: r.maxX - 12 - sz.width - padX * 2, y: r.midY - 9, width: sz.width + padX * 2, height: 18)
        color.withAlphaComponent(0.14).setFill(); NSBezierPath(roundedRect: pr, xRadius: 5, yRadius: 5).fill()
        let b = NSBezierPath(roundedRect: pr, xRadius: 5, yRadius: 5); b.lineWidth = 1; color.withAlphaComponent(0.4).setStroke(); b.stroke()
        a.draw(at: NSPoint(x: pr.minX + padX, y: pr.midY - sz.height / 2))
    }

    private func stateColor(_ state: String) -> NSColor {
        switch state {
        case "needs approval": return Theme.down
        case "finished": return Theme.ok
        case "review": return Theme.warn
        default: return Theme.faint
        }
    }

    private func drawMover(_ m: FinanceSummary.Mover, at y: CGFloat, width: CGFloat, x: CGFloat) {
        text(truncate(m.name, 70, Theme.mono(11)), NSPoint(x: x, y: y), Theme.mono(11), Theme.ink)
        let up = m.deltaAbs >= 0; let col = up ? Theme.ok : Theme.down
        let barX = x + 66, barW = width - 66 - 52, barMid = barX + barW / 2
        let track = NSRect(x: barX, y: y + 2, width: barW, height: 6)
        Theme.surface2.setFill(); NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let frac = min(0.5, abs(m.deltaPct) / 6)   // scale: 3% ≈ full half
        let len = barW / 2 * frac
        let fill = up ? NSRect(x: barMid, y: y + 2, width: len, height: 6) : NSRect(x: barMid - len, y: y + 2, width: len, height: 6)
        col.setFill(); NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        let pct = "\(up ? "+" : "−")\(String(format: "%.1f", abs(m.deltaPct)))%"
        let a = NSAttributedString(string: pct, attributes: [.font: Theme.mono(11), .foregroundColor: col])
        a.draw(at: NSPoint(x: x + width - a.size().width, y: y))
    }

    private func drawSparkline(_ series: [Double], in rect: NSRect) {
        let mn = series.min()!, mx = series.max()!, span = (mx - mn) == 0 ? 1 : (mx - mn)
        let n = series.count, pad: CGFloat = 2
        func X(_ i: Int) -> CGFloat { rect.minX + pad + CGFloat(i) * (rect.width - 2 * pad) / CGFloat(n - 1) }
        func Y(_ v: Double) -> CGFloat { rect.minY + pad + CGFloat((v - mn) / span) * (rect.height - 2 * pad) }
        let line = NSBezierPath(); line.move(to: NSPoint(x: X(0), y: Y(series[0])))
        for i in 1..<n { line.line(to: NSPoint(x: X(i), y: Y(series[i]))) }
        // soft fill under the line
        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: X(n - 1), y: rect.minY)); fill.line(to: NSPoint(x: X(0), y: rect.minY)); fill.close()
        Theme.amber.withAlphaComponent(0.16).setFill(); fill.fill()
        line.lineWidth = 2; line.lineJoinStyle = .round; Theme.amber.setStroke(); line.stroke()
        let end = NSRect(x: X(n - 1) - 3, y: Y(series[n - 1]) - 3, width: 6, height: 6)
        Theme.amber.setFill(); NSBezierPath(ovalIn: end).fill()
    }

    private func drawWeatherIcon(_ r: NSRect, code: Int) {
        // sun
        let sunR: CGFloat = 11, sc = NSPoint(x: r.minX + 16, y: r.maxY - 16)
        for i in 0..<8 {
            let a = CGFloat(i) / 8 * .pi * 2
            let p = NSBezierPath()
            p.move(to: NSPoint(x: sc.x + cos(a) * (sunR + 3), y: sc.y + sin(a) * (sunR + 3)))
            p.line(to: NSPoint(x: sc.x + cos(a) * (sunR + 7), y: sc.y + sin(a) * (sunR + 7)))
            p.lineWidth = 2; p.lineCapStyle = .round; Theme.amber.setStroke(); p.stroke()
        }
        Theme.amber.setFill(); NSBezierPath(ovalIn: NSRect(x: sc.x - sunR, y: sc.y - sunR, width: sunR * 2, height: sunR * 2)).fill()
        // cloud (a couple of overlapping circles + base) if not clear
        if code != 0 && code != 1 {
            let cloud = NSColor(hex: 0x3a3a3d)
            cloud.setFill()
            let base = NSRect(x: r.minX + 6, y: r.minY + 4, width: 40, height: 20)
            NSBezierPath(roundedRect: base, xRadius: 10, yRadius: 10).fill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + 12, y: r.minY + 10, width: 18, height: 18)).fill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + 24, y: r.minY + 12, width: 20, height: 20)).fill()
        }
    }

    private func drawArrowsAndDots() {
        drawArrow("‹", side: .left, cx: Self.arrowZone / 2)
        drawArrow("›", side: .right, cx: bounds.maxX - Self.arrowZone / 2)
        let n = pages.count, gap: CGFloat = 12, rr: CGFloat = 3
        var dx = bounds.midX - CGFloat(n - 1) * gap / 2
        for i in 0..<n {
            (i == index ? Theme.amber : Theme.border).setFill()
            NSBezierPath(ovalIn: NSRect(x: dx - rr, y: 11, width: rr * 2, height: rr * 2)).fill()
            dx += gap
        }
    }
    private func drawArrow(_ g: String, side: Side, cx: CGFloat) {
        let hov = hoveredArrow == side; let cy = bounds.midY
        if hov { NSColor(white: 1, alpha: 0.12).setFill(); NSBezierPath(ovalIn: NSRect(x: cx - 15, y: cy - 15, width: 30, height: 30)).fill() }
        let a = NSAttributedString(string: g, attributes: [.font: Theme.mono(20), .foregroundColor: hov ? Theme.ink : Theme.faint])
        let sz = a.size(); a.draw(at: NSPoint(x: cx - sz.width / 2, y: cy - sz.height / 2))
    }

    // MARK: text helpers

    private func text(_ s: String, _ p: NSPoint, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0) {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern]).draw(at: p)
    }
    private func truncate(_ s: String, _ w: CGFloat, _ font: NSFont) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (s as NSString).size(withAttributes: attrs).width <= w { return s }
        var t = s
        while t.count > 1 && ((t + "…") as NSString).size(withAttributes: attrs).width > w { t.removeLast() }
        return t + "…"
    }
    private func brl(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.locale = Locale(identifier: "pt_BR"); f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "—"
    }
    private func ago(_ ms: Double?) -> String {
        guard let ms else { return "" }
        let secs = Int(Date().timeIntervalSince1970 - ms / 1000)
        if secs < 60 { return "now" }
        let m = secs / 60
        return m < 60 ? "\(m)m" : "\(m / 60)h\(m % 60)m"
    }

    private func bottomRounded(_ r: NSRect, radius: CGFloat) -> NSBezierPath {
        let rad = min(radius, r.width / 2, r.height / 2)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX, y: r.maxY))
        p.line(to: NSPoint(x: r.maxX, y: r.maxY))
        p.line(to: NSPoint(x: r.maxX, y: r.minY + rad))
        p.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: r.minY + rad), radius: rad, startAngle: 0, endAngle: 270, clockwise: true)
        p.line(to: NSPoint(x: r.minX + rad, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.minX + rad, y: r.minY + rad), radius: rad, startAngle: 270, endAngle: 180, clockwise: true)
        p.line(to: NSPoint(x: r.minX, y: r.maxY))
        p.close()
        return p
    }
}
