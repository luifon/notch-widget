import AppKit
import QuartzCore

/// A page in the expanded carousel.
enum PageContent {
    case meetings([MeetingCard])
    case finance(FinanceSummary)
    case agents(AgentsSummary)
    case news(NewsSummary, votes: [String: NewsVoteState], opened: Set<String>)
    case weather(WeatherSummary)
    case simple(kicker: String, title: String, meta: String)

    /// Stable short name, used to select a page by name in mock mode.
    var name: String {
        switch self {
        case .meetings: return "meetings"
        case .finance: return "finance"
        case .agents: return "agents"
        case .news: return "news"
        case .weather: return "weather"
        case .simple: return "simple"
        }
    }
}

/// The panel that drops below the notch. Nucleus terminal×tiles look: near-black
/// panel, surface tiles, amber corner tag, mono type. One page at a time.
final class CarouselPanelView: NSView {
    var pages: [PageContent] = [] { didSet { clampIndex(); newsDataChanged(); needsDisplay = true } }
    var index: Int = 0 { didSet { newsScroll = 0; hoveredNewsID = nil; needsDisplay = true } }
    var cornerRadius: CGFloat = 18

    static let headerH: CGFloat = 54   // header bar + a clear gap before content
    static let cardH: CGFloat = 64
    static let cardGap: CGFloat = 10
    static let dotsH: CGFloat = 28
    static let arrowZone: CGFloat = 44

    // News metrics. The brief tile is measured from its text; the list below it
    // is a fixed viewport that scrolls, so the page height doesn't chase the
    // item count.
    static let briefPadX: CGFloat = 12
    static let briefPadY: CGFloat = 10
    static let briefLine: CGFloat = 16
    // The brief is the state of things, so the tile grows to fit it and the page
    // grows with the tile. A line holds 49 characters at 12pt mono in a 358pt
    // tile, so this cap is around 80 words; past that it ellipsizes rather than
    // pushing the list off the screen.
    static let briefMaxLines = 12
    static let briefMinLines = 3
    static let newsLabelH: CGFloat = 24     // "RANKED" caption + its divider
    static let newsViewportH: CGFloat = 292 // ≈ 5 rows before scrolling
    static let newsMinViewportH: CGFloat = 208 // ≥ 4 rows, whatever the brief costs
    static let newsPadY: CGFloat = 9
    static let newsTitleLine: CGFloat = 17
    static let newsTitleMaxLines = 2
    static let newsRankW: CGFloat = 22
    static let newsSublineH: CGFloat = 14
    static let voteSize: CGFloat = 28       // fixed hit target, always present
    static let voteGap: CGFloat = 2
    // Reason chips replace the meta line in place, so they have to fit the space
    // that line already occupies — between the title column and the vote squares.
    static let reasonFont: CGFloat = 9
    static let reasonPadX: CGFloat = 5
    static let reasonGap: CGFloat = 4
    static let readDotSize: CGFloat = 4

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
    static func newsHeight(_ s: NewsSummary, width: CGFloat) -> CGFloat {
        let brief = briefTileHeight(s.brief, width: width)
        return headerH + brief + (brief > 0 ? 12 : 0) + newsLabelH + newsViewportH + dotsH
    }
    static func briefTileHeight(_ brief: String?, width: CGFloat) -> CGFloat {
        guard let brief, !brief.isEmpty else { return 0 }
        let inner = width - arrowZone * 2 - briefPadX * 2
        let lines = wrapped(brief, width: inner, font: Theme.mono(12), maxLines: briefMaxLines)
        return briefPadY * 2 + CGFloat(max(1, lines.count)) * briefLine
    }

    var onCardClick: ((String) -> Void)?
    private var cardHits: [(rect: NSRect, id: String)] = []
    var onAgentClick: ((String) -> Void)?
    private var agentHits: [(rect: NSRect, id: String)] = []

    /// `(itemId, direction)` — the caller applies toggle semantics.
    var onNewsVote: ((String, Int) -> Void)?
    /// `(itemId, reasonKey)` — a chip was picked in reason mode. `other` is the
    /// caller's cue to ask for free text instead of saving straight away.
    var onNewsReason: ((String, String) -> Void)?
    /// The reader clicked the reason already showing in a row's meta line, to
    /// change it. The caller puts the row back into reason mode.
    var onNewsReasonEdit: ((String) -> Void)?
    /// Fired when a headline is clicked; the caller opens it and collapses.
    var onNewsOpen: ((String, URL) -> Void)?
    /// True while a scroll gesture (or its momentum) is running, so the app can
    /// hold off the pointer-exit collapse.
    var onScrollActivity: ((Bool) -> Void)?
    /// Fired after the visible page changed, so the panel can resize to it.
    var onPageChange: (() -> Void)?

    private var newsRowHits: [(rect: NSRect, id: String)] = []
    private var newsOpenHits: [(rect: NSRect, id: String, url: URL)] = []
    private var newsVoteHits: [(rect: NSRect, id: String, direction: Int)] = []
    private var newsReasonHits: [(rect: NSRect, id: String, key: String)] = []
    private var newsReasonEditHits: [(rect: NSRect, id: String)] = []
    private var hoveredNewsID: String?
    private var hoveredReasonKey: String?

    /// The one row showing the reason chip strip instead of its meta line, if
    /// any. The app owns the lifecycle (a vote, an open, a page change or a
    /// collapse all end it), so this is set from outside.
    var reasonRowID: String? { didSet { if reasonRowID != oldValue { hoveredReasonKey = nil; needsDisplay = true } } }

    // Scroll state for the news list.
    private var newsScroll: CGFloat = 0
    private var newsContentH: CGFloat = 0
    private var newsViewport: NSRect = .zero
    private var lastNewsAsOf: String?
    private enum ScrollAxis { case vertical, horizontal }
    private var scrollAxis: ScrollAxis?
    private var scrollAnchored = false
    private var lastScrollEvent: Date = .distantPast
    private var scrollActive = false
    private var scrollEndWork: DispatchWorkItem?
    private var scrollFadeUntil: Date?
    private var fadeTimer: Timer?

    private enum Side { case left, right }
    private var hoveredArrow: Side?
    private var leftTA: NSTrackingArea?
    private var rightTA: NSTrackingArea?
    private var moveTA: NSTrackingArea?

    override var isFlipped: Bool { false }

    private var currentPage: PageContent? { pages.indices.contains(index) ? pages[index] : nil }

    // MARK: hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        [leftTA, rightTA, moveTA].forEach { if let t = $0 { removeTrackingArea(t) } }
        let z = Self.arrowZone
        let l = NSTrackingArea(rect: NSRect(x: 0, y: 0, width: z, height: bounds.height),
                               options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: ["side": "left"])
        let r = NSTrackingArea(rect: NSRect(x: bounds.maxX - z, y: 0, width: z, height: bounds.height),
                               options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: ["side": "right"])
        // Full-bounds move tracking drives per-row hover on the news list.
        let m = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(l); addTrackingArea(r); addTrackingArea(m)
        leftTA = l; rightTA = r; moveTA = m
    }
    override func mouseEntered(with e: NSEvent) {
        guard let s = e.trackingArea?.userInfo?["side"] as? String else { return }
        hoveredArrow = (s == "left") ? .left : .right; NSCursor.pointingHand.set(); needsDisplay = true
    }
    override func mouseExited(with e: NSEvent) {
        if e.trackingArea?.userInfo?["side"] != nil {
            hoveredArrow = nil; NSCursor.arrow.set(); needsDisplay = true
            return
        }
        // Leaving the panel drops row hover, but NOT reason mode: the reader may
        // be reaching for the free-text editor below.
        hoveredNewsID = nil; hoveredReasonKey = nil; NSCursor.arrow.set(); needsDisplay = true
    }
    override func mouseMoved(with e: NSEvent) {
        updateRowHover(at: convert(e.locationInWindow, from: nil))
    }

    private func updateRowHover(at p: NSPoint) {
        let id = newsRowHits.first(where: { $0.rect.contains(p) })?.id
        if id != hoveredNewsID { hoveredNewsID = id; needsDisplay = true }
        let key = newsReasonHits.first(where: { $0.rect.contains(p) })?.key
        if key != hoveredReasonKey { hoveredReasonKey = key; needsDisplay = true }
        guard hoveredArrow == nil else { return }
        let clickable = key != nil
            || newsReasonEditHits.contains { $0.rect.contains(p) }
            || newsOpenHits.contains { $0.rect.contains(p) }
        (clickable ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    // MARK: clicks

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if pages.count > 1 && p.x < Self.arrowZone { page(-1); return }
        if pages.count > 1 && p.x > bounds.maxX - Self.arrowZone { page(1); return }
        // Votes and reason chips sit inside a headline row, so they must win the
        // hit test against the row's own open target.
        if let v = newsVoteHits.first(where: { $0.rect.contains(p) }) { onNewsVote?(v.id, v.direction); return }
        if let c = newsReasonHits.first(where: { $0.rect.contains(p) }) { onNewsReason?(c.id, c.key); return }
        if let e = newsReasonEditHits.first(where: { $0.rect.contains(p) }) { onNewsReasonEdit?(e.id); return }
        if let hit = newsOpenHits.first(where: { $0.rect.contains(p) }) { onNewsOpen?(hit.id, hit.url); return }
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
        onPageChange?()
    }

    // MARK: scrolling (news list only)

    override func scrollWheel(with e: NSEvent) {
        guard case .news? = currentPage, newsViewport.height > 0 else { super.scrollWheel(with: e); return }

        // A gesture begins on `.began`, or — for legacy wheels, which carry no
        // phase at all — after a pause long enough to count as a new one.
        let isNewGesture = e.phase.contains(.began)
            || (e.phase.isEmpty && e.momentumPhase.isEmpty && Date().timeIntervalSince(lastScrollEvent) > 0.25)
        if isNewGesture {
            scrollAxis = nil
            scrollAnchored = newsViewport.contains(convert(e.locationInWindow, from: nil))
        }
        lastScrollEvent = Date()
        guard scrollAnchored else { super.scrollWheel(with: e); return }

        var dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if !e.hasPreciseScrollingDeltas { dx *= 10; dy *= 10 }
        if scrollAxis == nil && (abs(dx) > 1 || abs(dy) > 1) {
            scrollAxis = abs(dy) >= abs(dx) ? .vertical : .horizontal
        }
        // Horizontal gestures are ignored outright — paging stays click-only, and
        // the axis lock keeps a diagonal swipe from leaking into either.
        guard scrollAxis == .vertical else { return }

        beginScrollActivity()
        let maxOffset = max(0, newsContentH - newsViewport.height)
        let next = min(max(0, newsScroll - dy), maxOffset)
        if next != newsScroll {
            newsScroll = next
            updateRowHover(at: convert(e.locationInWindow, from: nil))
            needsDisplay = true
        }
        showScrollIndicator()
        scheduleScrollEnd()
    }

    private func beginScrollActivity() {
        guard !scrollActive else { return }
        scrollActive = true
        onScrollActivity?(true)
    }
    /// Momentum arrives in bursts; a short idle window is the reliable end of a
    /// gesture across trackpads and legacy wheels alike.
    private func scheduleScrollEnd() {
        scrollEndWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.scrollActive else { return }
            self.scrollActive = false
            self.onScrollActivity?(false)
        }
        scrollEndWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func showScrollIndicator() {
        scrollFadeUntil = Date().addingTimeInterval(0.6)
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if let until = self.scrollFadeUntil, Date() < until { self.needsDisplay = true; return }
            t.invalidate(); self.fadeTimer = nil; self.scrollFadeUntil = nil; self.needsDisplay = true
        }
    }
    private func scrollIndicatorAlpha() -> CGFloat {
        guard let until = scrollFadeUntil else { return 0 }
        let left = until.timeIntervalSinceNow
        return left <= 0 ? 0 : min(1, CGFloat(left / 0.25))
    }

    /// Reset the list when the producer publishes a different snapshot; a plain
    /// vote round-trip reuses the same `asOf` and keeps the reader's position.
    private func newsDataChanged() {
        var asOf: String?
        for p in pages { if case .news(let s, _, _) = p { asOf = s.asOf ?? ""; break } }
        if asOf != lastNewsAsOf { lastNewsAsOf = asOf; newsScroll = 0 }
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
        newsRowHits.removeAll(); newsOpenHits.removeAll(); newsVoteHits.removeAll()
        newsReasonHits.removeAll(); newsReasonEditHits.removeAll()

        switch pages[index] {
        case .meetings(let cards): tag("NEXT MEETINGS"); drawMeetings(cards)
        case .finance(let s): tag("NET WORTH"); drawFinance(s)
        case .agents(let a): tag("AGENTS", right: a.count == 0 ? nil : "\(a.count) need you"); drawAgents(a)
        case .news(let n, let votes, let opened):
            tag("NEWS", right: Self.newsHeaderRight(n)); drawNews(n, votes: votes, opened: opened)
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

    // MARK: news

    /// One prepared row: the item plus its wrapped title, so the height is known
    /// before anything is drawn (the scroll math needs the total up front).
    private struct NewsRow {
        let item: NewsSummary.Item
        let titleLines: [String]
        let titleWidth: CGFloat
        var height: CGFloat {
            Self.padding + CGFloat(titleLines.count) * CarouselPanelView.newsTitleLine
                + 3 + CarouselPanelView.newsSublineH
        }
        static let padding = CarouselPanelView.newsPadY * 2
    }

    private func newsRows(_ items: [NewsSummary.Item], width: CGFloat) -> [NewsRow] {
        let titleW = width - Self.newsRankW - (Self.voteSize * 2 + Self.voteGap) - 12
        let font = Theme.mono(12.5, .semibold)
        return items.map {
            NewsRow(item: $0,
                    titleLines: Self.wrapped($0.title, width: titleW, font: font, maxLines: Self.newsTitleMaxLines),
                    titleWidth: titleW)
        }
    }

    private func drawNews(_ s: NewsSummary, votes: [String: NewsVoteState], opened: Set<String>) {
        let c = content()
        var top = bounds.maxY - Self.headerH

        // Brief: the state of things. Always visible, never scrolls. The page
        // asked for the full tile, but the frame may have been clamped to the
        // screen — in that case the brief gives up lines so the list keeps at
        // least its minimum viewport.
        if let brief = s.brief, !brief.isEmpty {
            let headroom = (bounds.maxY - Self.headerH) - 12 - Self.newsLabelH
                - (Self.dotsH + 4) - Self.newsMinViewportH - Self.briefPadY * 2
            let allowed = max(Self.briefMinLines, min(Self.briefMaxLines, Int(floor(headroom / Self.briefLine))))
            let lines = Self.wrapped(brief, width: c.width - Self.briefPadX * 2,
                                     font: Theme.mono(12), maxLines: allowed)
            let h = Self.briefPadY * 2 + CGFloat(lines.count) * Self.briefLine
            let r = NSRect(x: c.minX, y: top - h, width: c.width, height: h)
            tile(r)
            var ty = r.maxY - Self.briefPadY - Self.briefLine
            for line in lines {
                text(line, NSPoint(x: r.minX + Self.briefPadX, y: ty), Theme.mono(12), Theme.ink)
                ty -= Self.briefLine
            }
            top = r.minY - 12
        }

        // Caption + divider introducing the scrollable list.
        text("RANKED", NSPoint(x: c.minX, y: top - 15), Theme.mono(9, .semibold), Theme.faint, kern: 1.3)
        let divY = top - Self.newsLabelH + 2
        let d = NSBezierPath()
        d.move(to: NSPoint(x: c.minX, y: divY)); d.line(to: NSPoint(x: c.maxX, y: divY)); d.lineWidth = 1
        Theme.border.setStroke(); d.stroke()

        let vpBottom = Self.dotsH + 4
        let vp = NSRect(x: c.minX, y: vpBottom, width: c.width, height: max(0, divY - 9 - vpBottom))
        newsViewport = vp
        guard vp.height > 0 else { return }

        if s.items.isEmpty {
            text("Nothing ranked yet", NSPoint(x: c.minX, y: vp.maxY - 22), Theme.mono(13), Theme.faint)
            newsContentH = 0
            return
        }

        let rows = newsRows(s.items, width: vp.width)
        newsContentH = rows.reduce(0) { $0 + $1.height }
        newsScroll = min(max(0, newsScroll), max(0, newsContentH - vp.height))

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: vp).setClip()
        var offset: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let r = NSRect(x: vp.minX, y: vp.maxY + newsScroll - offset - row.height,
                           width: vp.width, height: row.height)
            offset += row.height
            guard r.maxY > vp.minY && r.minY < vp.maxY else { continue }
            drawNewsRow(row, r, rank: i + 1, state: votes[row.item.id] ?? .none,
                        read: opened.contains(row.item.id), last: i == rows.count - 1, clip: vp)
        }
        NSGraphicsContext.restoreGraphicsState()

        drawScrollAffordances(vp)
    }

    private func drawNewsRow(_ row: NewsRow, _ r: NSRect, rank: Int, state: NewsVoteState,
                             read: Bool, last: Bool, clip: NSRect) {
        let id = row.item.id
        let hovered = hoveredNewsID == id
        if hovered {
            Theme.surface2.setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 0, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        if !last {
            let sep = NSBezierPath()
            sep.move(to: NSPoint(x: r.minX, y: r.minY + 0.5)); sep.line(to: NSPoint(x: r.maxX, y: r.minY + 0.5))
            sep.lineWidth = 1; Theme.border.setStroke(); sep.stroke()
        }

        let firstLineY = r.maxY - Self.newsPadY - Self.newsTitleLine
        let rk = NSAttributedString(string: "\(rank)", attributes: [.font: Theme.mono(10), .foregroundColor: Theme.faint])
        rk.draw(at: NSPoint(x: r.minX + Self.newsRankW - 4 - rk.size().width, y: firstLineY + 2))
        // Read state: a dot in the gutter. The headline keeps its full weight —
        // having read something doesn't make it less worth ranking first.
        if read {
            let d = Self.readDotSize
            Theme.faint.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX, y: firstLineY + 7 - d / 2, width: d, height: d)).fill()
        }

        // A downvoted headline fades but stays where the ranker put it, so the
        // list doesn't reshuffle under the reader's cursor mid-pass.
        let titleInk = state.vote == -1 ? Theme.ink.withAlphaComponent(0.55) : Theme.ink
        let x = r.minX + Self.newsRankW
        var ty = firstLineY
        for line in row.titleLines {
            text(line, NSPoint(x: x, y: ty), Theme.mono(12.5, .semibold), titleInk)
            ty -= Self.newsTitleLine
        }

        // Vote controls: fixed squares at the right edge, well inside the arrow
        // column, so the hit targets never move with the text.
        let vy = r.midY - Self.voteSize / 2
        let downR = NSRect(x: r.maxX - Self.voteSize, y: vy, width: Self.voteSize, height: Self.voteSize)
        let upR = NSRect(x: downR.minX - Self.voteGap - Self.voteSize, y: vy, width: Self.voteSize, height: Self.voteSize)
        drawVote(upR, up: true, active: state.vote == 1, rowHovered: hovered)
        drawVote(downR, up: false, active: state.vote == -1, rowHovered: hovered)

        let sy = r.minY + Self.newsPadY
        let metaMaxX = upR.minX - 4
        if reasonRowID == id {
            drawReasonStrip(id: id, x: x, y: sy, maxX: metaMaxX, clip: clip)
        } else {
            drawNewsMeta(row, id: id, x: x, y: sy, maxX: metaMaxX, reason: state.reason, clip: clip)
        }

        // Hit rects, trimmed to the viewport so a half-scrolled row can't be hit
        // where it isn't drawn. Votes only count while fully visible.
        newsRowHits.append((r.intersection(clip), id))
        if clip.contains(upR) { newsVoteHits.append((upR, id, 1)) }
        if clip.contains(downR) { newsVoteHits.append((downR, id, -1)) }
        if let raw = row.item.url, let url = URL(string: raw) {
            let open = NSRect(x: r.minX, y: r.minY, width: upR.minX - 4 - r.minX, height: r.height)
            newsOpenHits.append((open.intersection(clip), id, url))
        }
    }

    /// Source chip · age · the reader's reason, if any · why it ranked — in
    /// whatever order still fits.
    private func drawNewsMeta(_ row: NewsRow, id: String, x: CGFloat, y: CGFloat, maxX: CGFloat,
                              reason: String?, clip: NSRect) {
        var sx = x
        if let src = row.item.source, !src.isEmpty { sx = chip(src, at: NSPoint(x: sx, y: y + 1)) + 7 }
        let age = Self.relativeAge(row.item.publishedAt)
        if !age.isEmpty {
            text(age, NSPoint(x: sx, y: y), Theme.mono(10), Theme.faint)
            sx += (age as NSString).size(withAttributes: [.font: Theme.mono(10)]).width + 10
        }
        // The key comes from the producer, so it isn't necessarily one the widget
        // writes — show it verbatim, but never let it run into the vote squares.
        if let reason, !reason.isEmpty, maxX - sx > 30 {
            let label = truncate(VoteReason.chipLabel(reason), min(96, maxX - sx - 10), Theme.mono(9.5))
            let r = chipRect(label, at: NSPoint(x: sx, y: y + 1), font: Theme.mono(9.5), padX: 5)
            drawChip(label, in: r, font: Theme.mono(9.5), ink: Theme.down, border: Theme.down.withAlphaComponent(0.45))
            if clip.contains(r) { newsReasonEditHits.append((r, id)) }
            sx = r.maxX + 7
        }
        if let why = row.item.reason, !why.isEmpty {
            let avail = maxX - sx
            if avail > 48 { text(truncate(why, avail, Theme.mono(10)), NSPoint(x: sx, y: y), Theme.mono(10), Theme.faint) }
        }
    }

    /// Reason mode: the meta line is swapped for the chip strip in place, so the
    /// row keeps its height and the list underneath never moves.
    private func drawReasonStrip(id: String, x: CGFloat, y: CGFloat, maxX: CGFloat, clip: NSRect) {
        let font = Theme.mono(Self.reasonFont)
        var sx = x
        for reason in VoteReason.allCases {
            let r = chipRect(reason.label, at: NSPoint(x: sx, y: y + 1), font: font, padX: Self.reasonPadX)
            guard r.maxX <= maxX else { break }
            let hot = hoveredReasonKey == reason.rawValue
            drawChip(reason.label, in: r, font: font,
                     ink: hot ? Theme.ink : Theme.faint,
                     border: hot ? Theme.ink : Theme.border,
                     fill: hot ? Theme.surface2 : nil)
            if clip.contains(r) { newsReasonHits.append((r, id, reason.rawValue)) }
            sx = r.maxX + Self.reasonGap
        }
    }

    private func drawVote(_ r: NSRect, up: Bool, active: Bool, rowHovered: Bool) {
        let color = up ? Theme.amber : Theme.down
        if active {
            let box = r.insetBy(dx: 3, dy: 3)
            color.withAlphaComponent(0.14).setFill(); NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
            let b = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7); b.lineWidth = 1
            color.withAlphaComponent(0.4).setStroke(); b.stroke()
        }
        let ink = active ? color : Theme.faint.withAlphaComponent(rowHovered ? 1 : 0.35)
        let g = NSAttributedString(string: up ? "▲" : "▼", attributes: [.font: Theme.mono(10), .foregroundColor: ink])
        let sz = g.size()
        g.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }

    /// Thin scrollbar while the gesture is live, plus a fade at whichever edge
    /// still has list beyond it, so a clipped row reads as cut-off rather than
    /// broken.
    private func drawScrollAffordances(_ vp: NSRect) {
        guard newsContentH > vp.height else { return }
        let alpha = scrollIndicatorAlpha()
        if alpha > 0 {
            let thumbH = max(24, vp.height * vp.height / newsContentH)
            let t = newsScroll / max(1, newsContentH - vp.height)
            let y = vp.maxY - thumbH - t * (vp.height - thumbH)
            Theme.faint.withAlphaComponent(alpha * 0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: vp.maxX - 2, y: y, width: 2, height: thumbH),
                         xRadius: 1, yRadius: 1).fill()
        }
        guard let g = NSGradient(starting: Theme.bg.withAlphaComponent(0), ending: Theme.bg) else { return }
        if newsScroll < newsContentH - vp.height - 0.5 {
            g.draw(in: NSRect(x: vp.minX, y: vp.minY, width: vp.width, height: 12), angle: 270)
        }
        if newsScroll > 0.5 {
            g.draw(in: NSRect(x: vp.minX, y: vp.maxY - 12, width: vp.width, height: 12), angle: 90)
        }
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
        let f = Theme.mono(9.5)
        let r = chipRect(s, at: p, font: f, padX: 5)
        drawChip(s, in: r, font: f, ink: Theme.faint, border: Theme.border)
        return r.maxX
    }

    /// Where a chip lands, measured before it's drawn — the reason strip needs
    /// the rect for hit-testing and for deciding whether the next chip still fits.
    private func chipRect(_ s: String, at p: NSPoint, font: NSFont, padX: CGFloat) -> NSRect {
        let sz = (s as NSString).size(withAttributes: [.font: font])
        return NSRect(x: p.x, y: p.y - 2, width: ceil(sz.width) + padX * 2, height: ceil(sz.height) + 4)
    }

    private func drawChip(_ s: String, in r: NSRect, font: NSFont, ink: NSColor, border: NSColor, fill: NSColor? = nil) {
        if let fill { fill.setFill(); NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill() }
        let b = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5); b.lineWidth = 1
        border.setStroke(); b.stroke()
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: ink])
        a.draw(at: NSPoint(x: r.minX + (r.width - a.size().width) / 2, y: r.minY + 2))
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
    /// Greedy word wrap, ellipsizing the last line when the text outruns
    /// `maxLines`. Static so page heights can be measured before drawing.
    static func wrapped(_ s: String, width: CGFloat, font: NSFont, maxLines: Int) -> [String] {
        guard width > 0, maxLines > 0 else { return [] }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        func w(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: attrs).width }

        var lines: [String] = []
        var line = ""
        for word in s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init) {
            let candidate = line.isEmpty ? word : line + " " + word
            if w(candidate) <= width { line = candidate; continue }
            if !line.isEmpty { lines.append(line); line = "" }
            var rest = word                       // a single word wider than the line
            while w(rest) > width && rest.count > 1 {
                var head = rest
                while head.count > 1 && w(head) > width { head.removeLast() }
                lines.append(head)
                rest = String(rest.dropFirst(head.count))
            }
            line = rest
        }
        if !line.isEmpty { lines.append(line) }
        guard lines.count > maxLines else { return lines }

        var clipped = Array(lines.prefix(maxLines))
        var last = clipped.removeLast()
        while last.count > 1 && w(last + "…") > width { last.removeLast() }
        clipped.append(last + "…")
        return clipped
    }

    /// Compact age of a publication timestamp: `now`, `42m`, `3h`, `2d`.
    static func relativeAge(_ iso: String?) -> String {
        guard let d = ISODate.date(iso) else { return "" }
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
    }

    /// Header right-hand text: how many items, and how fresh the snapshot is —
    /// a clock time when it was built today, an age in days otherwise.
    static func newsHeaderRight(_ s: NewsSummary) -> String? {
        let n = s.count ?? s.items.count
        guard let d = ISODate.date(s.asOf) else { return n == 0 ? nil : "\(n)" }
        let stamp: String
        if Calendar.current.isDateInToday(d) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            stamp = f.string(from: d)
        } else {
            stamp = "\(max(1, Int(Date().timeIntervalSince(d) / 86400)))d"
        }
        return "\(n) · \(stamp)"
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
