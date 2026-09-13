import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel!
    private var space: CGSSpace!
    private var container: NotchContainerView!
    private var bandView: CollapsedBandView!
    private var carousel: CarouselPanelView!
    private let meetings = MeetingSource()
    private var tick: Timer?

    private var geo: NotchGeometry!
    private var isExpanded = false
    private var meetingCount = 0

    private var lastCards: [MeetingCard] = []
    private var acknowledged: Set<String> = []
    private var flashTimer: Timer?

    private let finance = FinanceSource()
    private var financeSummary: FinanceSummary?
    private let agentsSource = AgentsSource()
    private var agentsSummary: AgentsSummary?
    private let weather = WeatherSource()
    private var weatherSummary: WeatherSummary?
    private let newsSource = NewsSource()
    private var newsSummary: NewsSummary?
    private var newsVotes: [String: NewsVote] = [:]
    private var weatherTimer: Timer?
    private var externalTimer: Timer?
    private var mockMode = false

    private let expandedWidth: CGFloat = 470
    private let barExtra: CGFloat = 2            // bottom edge hangs below the notch
    private var bandHeight: CGFloat { geo.topInset + barExtra }

    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var scrollActive = false        // a list gesture is running
    private var collapsePending = false     // the pointer left mid-gesture

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let g = NotchGeometry.current() else {
            log("no notched display found"); NSApp.terminate(nil); return
        }
        geo = g

        container = NotchContainerView(frame: .zero)
        container.autoresizesSubviews = true
        bandView = CollapsedBandView(frame: .zero)
        bandView.gapWidth = geo.gapWidth
        bandView.autoresizingMask = [.width, .minYMargin]     // pinned to the top, fixed height
        carousel = CarouselPanelView(frame: .zero)
        carousel.wantsLayer = true
        carousel.autoresizingMask = [.width, .height]         // fills the space below the band
        carousel.isHidden = true
        carousel.pages = defaultPages()
        container.addSubview(bandView)
        container.addSubview(carousel)
        container.onHoverChange = { [weak self] hovering in self?.hoverChanged(hovering) }
        carousel.onCardClick = { [weak self] id in self?.acknowledge(id) }
        carousel.onAgentClick = { [weak self] id in self?.ackAgent(id) }
        carousel.onNewsVote = { [weak self] id, direction in self?.voteNews(id, direction) }
        carousel.onNewsOpen = { [weak self] url in
            NSWorkspace.shared.open(url)
            self?.setExpanded(false)
        }
        carousel.onScrollActivity = { [weak self] active in self?.scrollActivityChanged(active) }
        carousel.onPageChange = { [weak self] in self?.resizeToCurrentPage() }

        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: bandHeight))
        panel.contentView = container
        panel.acceptsMouseMovedEvents = true
        panel.orderFrontRegardless()

        newsVotes = NewsSource.overlay()   // the outbox is the record of what the reader voted

        space = CGSSpace(level: 2_147_483_647)
        space.windows = [panel]

        applyCollapsedFrame()

        if ProcessInfo.processInfo.environment["NOTCH_MOCK"] == "1" {
            mockMode = true
            let mock: [MeetingCard] = [
                MeetingCard(id: "m1", title: "Daily RJ", time: "10:00 – 10:30 · in 3m", sender: "Rafael J.", urgency: .now),
                MeetingCard(id: "m2", title: "Client sync — a longer title that should truncate", time: "11:00 – 11:45 · in 12m", sender: "Marina Alves", urgency: .soon),
                MeetingCard(id: "m3", title: "Design review", time: "15:00 – 15:30 · in 5h", sender: "", urgency: .calm),
            ]
            meetingCount = mock.count
            lastCards = mock
            financeSummary = FinanceSummary(asOf: nil, since: "2026-09-09", netWorth: 1_234_567,
                liquidNetWorth: 456_789, deltaAbs: 3210, deltaPct: 0.26, movers: [
                    .init(name: "PETR4", deltaAbs: 1200, deltaPct: 1.8),
                    .init(name: "BTC", deltaAbs: -800, deltaPct: -0.9),
                    .init(name: "IVVB11", deltaAbs: 600, deltaPct: 0.4),
                ], series: [1_180_000, 1_192_000, 1_188_000, 1_205_000, 1_210_000, 1_202_000,
                            1_221_000, 1_218_000, 1_229_000, 1_224_000, 1_231_000, 1_240_000,
                            1_236_000, 1_247_000, 1_231_000, 1_234_567])
            let nowMs = Date().timeIntervalSince1970 * 1000
            agentsSummary = AgentsSummary(asOf: nil, count: 3, needsAttention: [
                .init(id: "wt1", label: "acme-web", detail: "main", engine: "claude", state: "review", since: nowMs - 320_000),
                .init(id: "wt2", label: "toolkit", detail: "fix-migration", engine: "codex", state: "interrupted", since: nowMs - 1_500_000),
                .init(id: "wt3", label: "demo-app", detail: "release", engine: "claude", state: "finished", since: nowMs - 60_000),
            ])
            weatherSummary = WeatherSummary(tempC: 24.6, feelsC: 25.9, code: 3, maxC: 29.6, minC: 17.8, place: "São Paulo",
                hourly: [.init(label: "15h", tempC: 26, code: 1), .init(label: "17h", tempC: 24, code: 2),
                         .init(label: "19h", tempC: 21, code: 3), .init(label: "21h", tempC: 19, code: 61),
                         .init(label: "23h", tempC: 18, code: 3)])
            newsSummary = Self.mockNews()
            rebuildPages()
            bandView.apply(BandState(left: "Daily RJ", right: "in 3m", urgency: .now))
            lastCards = mock
            applyCollapsedFrame()
            updateFlash()
            if ProcessInfo.processInfo.environment["NOTCH_MOCK_EXPAND"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    if let p = ProcessInfo.processInfo.environment["NOTCH_MOCK_PAGE"] {
                        if let i = Int(p) {
                            self.carousel.index = i
                        } else if let i = self.carousel.pages.firstIndex(where: { $0.name == p.lowercased() }) {
                            self.carousel.index = i
                        }
                    }
                    self.setExpanded(true)
                }
            }
            return
        }

        meetings.requestAccess { [weak self] granted in
            guard let self else { return }
            if granted {
                self.refresh()
                self.meetings.observeChanges { [weak self] in self?.refresh() }
                self.tick = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                    self?.refresh()
                }
            } else {
                self.bandView.leftText = "No calendar access"
                self.applyCollapsedFrame()
                self.log("calendar access denied")
            }
        }

        refreshExternal()
        externalTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshExternal()
        }
        refreshWeather()
        weatherTimer = Timer.scheduledTimer(withTimeInterval: 1200, repeats: true) { [weak self] _ in
            self?.refreshWeather()
        }

        log("notch widget up")
    }

    private func defaultPages() -> [PageContent] {
        [ .meetings([]) ]
    }

    private func refresh() {
        bandView.apply(meetings.snapshot())
        let cards = meetings.meetingCards()
        meetingCount = cards.count
        lastCards = cards
        rebuildPages()
        if isExpanded { setExpanded(true, force: true) } else { applyCollapsedFrame() }
        updateFlash()
    }

    /// Compose the carousel pages: meetings always first, then whichever
    /// summaries exist. Preserves the current page index when still valid.
    private func rebuildPages() {
        var pages: [PageContent] = [.meetings(lastCards)]
        if let a = agentsSummary { pages.append(.agents(a)) }
        if let n = newsSummary {
            pages.append(.news(n, votes: NewsSource.effectiveVotes(n, overlay: newsVotes)))
        }
        if let w = weatherSummary { pages.append(.weather(w)) }
        if let f = financeSummary { pages.append(.finance(f)) }
        let keep = min(carousel.index, pages.count - 1)
        carousel.pages = pages
        carousel.index = max(0, keep)
        resizeToCurrentPage()   // a page can change height between refreshes
    }

    private func refreshExternal() {
        guard !mockMode else { return }
        financeSummary = finance.load()
        agentsSummary = agentsSource.load()
        newsSummary = newsSource.load()
        rebuildPages()
    }

    /// Toggle semantics: voting the same way twice clears the vote. The outbox
    /// records every click, including the clearing one.
    private func voteNews(_ id: String, _ direction: Int) {
        guard let s = newsSummary else { return }
        let current = NewsSource.effectiveVotes(s, overlay: newsVotes)[id] ?? 0
        newsVotes[id] = NewsSource.vote(itemId: id, vote: current == direction ? 0 : direction)
        rebuildPages()
    }

    /// Hold the pointer-exit collapse while a scroll gesture or its momentum is
    /// running, and re-arm it once the gesture settles.
    private func scrollActivityChanged(_ active: Bool) {
        scrollActive = active
        if active {
            closeWork?.cancel()
        } else if collapsePending {
            collapsePending = false
            scheduleCollapse()
        }
    }

    private func refreshWeather() {
        guard !mockMode else { return }
        weather.fetch { [weak self] summary in
            guard let self, let summary else { return }
            self.weatherSummary = summary
            self.rebuildPages()
        }
    }

    /// Acknowledge an agent worktree: record it (the emitter stops flagging it)
    /// and drop it from the current view immediately.
    private func ackAgent(_ id: String) {
        AgentsSource.acknowledge(id)
        guard let s = agentsSummary else { return }
        let remaining = s.needsAttention.filter { $0.id != id }
        agentsSummary = AgentsSummary(asOf: s.asOf, count: remaining.count, needsAttention: remaining)
        rebuildPages()
    }

    // MARK: mock news

    /// A plausible ranked set for `NOTCH_MOCK=1`: varied sources and ages, one
    /// title long enough to wrap, and a couple already voted.
    private static func mockNews() -> NewsSummary {
        func at(_ hoursAgo: Double) -> String { ISODate.string(Date().addingTimeInterval(-hoursAgo * 3600)) }
        typealias I = NewsSummary.Item
        let items: [I] = [
            I(id: "n1", title: "Swift 6.2 ships typed throws for the standard library",
              source: "Swift Forums", url: "https://forums.swift.org/", publishedAt: at(2.1),
              score: 0.94, reason: "matches your Swift + compiler interest", event: "swift-6.2", vote: 1),
            I(id: "n2", title: "Apple opens the notch area to third-party widgets in the next macOS point release, with a new entitlement",
              source: "Ars Technica", url: "https://arstechnica.com/", publishedAt: at(4.6),
              score: 0.91, reason: "directly relevant to this project", event: "macos-widgets", vote: 0),
            I(id: "n3", title: "Postgres 18 beta lands asynchronous I/O",
              source: "LWN", url: "https://lwn.net/", publishedAt: at(7.0),
              score: 0.88, reason: "you read the 17 release notes", event: nil, vote: 0),
            I(id: "n4", title: "Rust 1.90 stabilises async closures",
              source: "Hacker News", url: "https://news.ycombinator.com/", publishedAt: at(9.5),
              score: 0.86, reason: "your main hobby language", event: "rust-1.90", vote: -1),
            I(id: "n5", title: "A field guide to debugging CoreGraphics window levels",
              source: "Hacker News", url: "https://news.ycombinator.com/", publishedAt: at(13.0),
              score: 0.83, reason: "same private API this widget uses", event: nil, vote: 0),
            I(id: "n6", title: "Central bank holds rates, signals one cut before year end",
              source: "Reuters", url: "https://www.reuters.com/", publishedAt: at(18.0),
              score: 0.79, reason: "affects your projection assumptions", event: "rates", vote: 0),
            I(id: "n7", title: "Wayland finally gets colour management",
              source: "Phoronix", url: "https://www.phoronix.com/", publishedAt: at(23.0),
              score: 0.74, reason: "recurring topic in your reading", event: nil, vote: 0),
            I(id: "n8", title: "GitHub Actions adds native ARM runners for open-source repos",
              source: "GitHub", url: "https://github.blog/", publishedAt: at(30.0),
              score: 0.71, reason: "your CI runs on macOS ARM", event: "ci", vote: 0),
            I(id: "n9", title: "The Verge reviews the new mini PCs for home servers",
              source: "The Verge", url: "https://www.theverge.com/", publishedAt: at(38.0),
              score: 0.68, reason: "you shortlisted one last month", event: nil, vote: 0),
            I(id: "n10", title: "SQLite adds a JSONB storage format",
              source: "Hacker News", url: "https://news.ycombinator.com/", publishedAt: at(46.0),
              score: 0.64, reason: "used by three of your side projects", event: nil, vote: 0),
            I(id: "n11", title: "Study finds sleep regularity beats duration for cardiovascular risk",
              source: "Nature", url: "https://www.nature.com/", publishedAt: at(55.0),
              score: 0.60, reason: "wellbeing thread", event: nil, vote: 0),
            I(id: "n12", title: "Vercel drops per-seat pricing for hobby projects",
              source: "TechCrunch", url: "https://techcrunch.com/", publishedAt: at(69.0),
              score: 0.57, reason: "you deploy there", event: nil, vote: 0),
            I(id: "n13", title: "A minimal terminal multiplexer in 900 lines of C",
              source: "Hacker News", url: "https://news.ycombinator.com/", publishedAt: at(80.0),
              score: 0.53, reason: "weekend-read shape", event: nil, vote: 0),
        ]
        return NewsSummary(
            asOf: ISODate.string(Date().addingTimeInterval(-1800)),
            brief: "Quiet morning overall. The one thing worth your time is Apple's widget entitlement, "
                 + "which would replace the private-API trick this widget relies on. Rates held, so the "
                 + "projection is unchanged.",
            count: items.count, items: items)
    }

    // MARK: ≤5-minute flash

    private func acknowledge(_ id: String) {
        acknowledged.insert(id)
        updateFlash()
    }

    private func updateFlash() {
        let triggering = lastCards.first { $0.urgency == .now && !acknowledged.contains($0.id) }
        if triggering != nil {
            if flashTimer == nil {
                flashTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    self?.bandView.flashDark.toggle()
                }
            }
        } else {
            flashTimer?.invalidate()
            flashTimer = nil
            bandView.flashDark = false
        }
    }

    // MARK: text-hugging collapsed size

    private func flankWidths() -> (left: CGFloat, right: CGFloat) {
        let pad = CollapsedBandView.textPad, minFlank: CGFloat = 40
        return (max(minFlank, textWidth(bandView.leftText) + pad * 2),
                max(minFlank, textWidth(bandView.rightText) + pad * 2))
    }

    private func textWidth(_ s: String) -> CGFloat {
        let f = NSFont(name: "JetBrains Mono", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .medium)
        return (s as NSString).size(withAttributes: [.font: f]).width
    }

    private func applyCollapsedFrame() {
        let (l, r) = flankWidths()
        let (frame, gapMinX) = geo.collapsedFrame(leftFlank: l, rightFlank: r, barExtra: barExtra)
        bandView.gapMinX = gapMinX
        panel.setFrame(frame, display: true, animate: false)
        bandView.frame = NSRect(x: 0, y: 0, width: frame.width, height: bandHeight)
        carousel.frame = NSRect(x: 0, y: 0, width: frame.width, height: 0)
    }

    // MARK: expand / collapse (animated)

    private func hoverChanged(_ hovering: Bool) {
        if hovering {
            closeWork?.cancel()
            collapsePending = false
            let w = DispatchWorkItem { [weak self] in self?.setExpanded(true) }
            openWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: w)
        } else {
            openWork?.cancel()
            // Mid-scroll the pointer can drift out; defer rather than collapse
            // under the reader's hand.
            if scrollActive { collapsePending = true; return }
            scheduleCollapse()
        }
    }

    private func scheduleCollapse() {
        let w = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: w)
    }

    /// Each page states its own height; the panel is sized to whichever one is
    /// showing rather than to the tallest.
    private func pageHeight(_ page: PageContent) -> CGFloat {
        switch page {
        case .meetings(let cards): return CarouselPanelView.panelHeight(meetingCards: cards.count)
        case .agents(let a): return CarouselPanelView.agentsHeight(a.needsAttention.count)
        case .news(let n, _): return CarouselPanelView.newsHeight(n, width: expandedWidth)
        case .weather: return CarouselPanelView.weatherHeight
        case .finance(let f): return CarouselPanelView.financeHeight(f)
        case .simple: return CarouselPanelView.panelHeight(meetingCards: 1)
        }
    }

    private func currentPanelHeight() -> CGFloat {
        guard carousel.pages.indices.contains(carousel.index) else {
            return CarouselPanelView.panelHeight(meetingCards: meetingCount)
        }
        return pageHeight(carousel.pages[carousel.index])
    }

    /// Grow or shrink the open panel to the page the user just navigated to.
    private func resizeToCurrentPage() {
        guard isExpanded else { return }
        let (frame, gapMinX) = geo.expandedFrame(width: expandedWidth,
                                                 panelHeight: currentPanelHeight(), barExtra: barExtra)
        guard frame.height != panel.frame.height else { return }
        bandView.gapMinX = gapMinX
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in self?.layoutBandAndCarousel(in: frame) })
    }

    private func layoutBandAndCarousel(in frame: NSRect) {
        let w = frame.width
        if isExpanded {
            bandView.frame = NSRect(x: 0, y: frame.height - bandHeight, width: w, height: bandHeight)
            carousel.frame = NSRect(x: 0, y: 0, width: w, height: frame.height - bandHeight)
        } else {
            bandView.frame = NSRect(x: 0, y: 0, width: w, height: bandHeight)
            carousel.frame = NSRect(x: 0, y: 0, width: w, height: 0)
            carousel.isHidden = true
        }
    }

    private func setExpanded(_ expanded: Bool, force: Bool = false) {
        guard expanded != isExpanded || force else { return }
        if expanded { refreshExternal() }       // pick up the latest summaries on open
        isExpanded = expanded
        bandView.cornerRadius = expanded ? 0 : 11

        let frame: NSRect
        if expanded {
            carousel.isHidden = false
            let (f, gapMinX) = geo.expandedFrame(width: expandedWidth,
                                                 panelHeight: currentPanelHeight(), barExtra: barExtra)
            bandView.gapMinX = gapMinX
            frame = f
        } else {
            let (l, r) = flankWidths()
            let (f, gapMinX) = geo.collapsedFrame(leftFlank: l, rightFlank: r, barExtra: barExtra)
            bandView.gapMinX = gapMinX
            frame = f
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in self?.layoutBandAndCarousel(in: frame) })
    }

    private func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
