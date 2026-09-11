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
    private var externalTimer: Timer?
    private var mockMode = false

    private let expandedWidth: CGFloat = 470
    private let barExtra: CGFloat = 2            // bottom edge hangs below the notch
    private var bandHeight: CGFloat { geo.topInset + barExtra }

    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?

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

        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: bandHeight))
        panel.contentView = container
        panel.orderFrontRegardless()

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
                ])
            let nowMs = Date().timeIntervalSince1970 * 1000
            agentsSummary = AgentsSummary(asOf: nil, count: 3, needsAttention: [
                .init(label: "Review the diff", repo: "acme-web", engine: "claude", state: "done", since: nowMs - 320_000),
                .init(label: "Fix the migration", repo: "toolkit", engine: "codex", state: "interrupted", since: nowMs - 1_500_000),
                .init(label: "Draft release notes", repo: "demo-app", engine: "claude", state: "done", since: nowMs - 60_000),
            ])
            rebuildPages()
            bandView.apply(BandState(left: "Daily RJ", right: "in 3m", urgency: .now))
            lastCards = mock
            applyCollapsedFrame()
            updateFlash()
            if ProcessInfo.processInfo.environment["NOTCH_MOCK_EXPAND"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.setExpanded(true)
                    if let p = ProcessInfo.processInfo.environment["NOTCH_MOCK_PAGE"], let i = Int(p) {
                        self?.carousel.index = i
                    }
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

    /// Compose the carousel pages: meetings always first, finance if we have a
    /// summary. Preserves the current page index when still valid.
    private func rebuildPages() {
        var pages: [PageContent] = [.meetings(lastCards)]
        if let a = agentsSummary { pages.append(.agents(a)) }
        if let f = financeSummary { pages.append(.finance(f)) }
        let keep = min(carousel.index, pages.count - 1)
        carousel.pages = pages
        carousel.index = max(0, keep)
    }

    private func refreshExternal() {
        guard !mockMode else { return }
        financeSummary = finance.load()
        agentsSummary = agentsSource.load()
        rebuildPages()
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
            let w = DispatchWorkItem { [weak self] in self?.setExpanded(true) }
            openWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: w)
        } else {
            openWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
            closeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: w)
        }
    }

    private func setExpanded(_ expanded: Bool, force: Bool = false) {
        guard expanded != isExpanded || force else { return }
        isExpanded = expanded
        if expanded { refreshExternal() }       // pick up the latest summaries on open
        bandView.cornerRadius = expanded ? 0 : 11

        let frame: NSRect
        if expanded {
            carousel.isHidden = false
            var ph = CarouselPanelView.panelHeight(meetingCards: meetingCount)
            if let a = agentsSummary { ph = max(ph, CarouselPanelView.agentsHeight(a.needsAttention.count)) }
            if financeSummary != nil { ph = max(ph, CarouselPanelView.financeHeight) }
            let (f, gapMinX) = geo.expandedFrame(width: expandedWidth, panelHeight: ph, barExtra: barExtra)
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
        }, completionHandler: { [weak self] in
            guard let self else { return }
            let w = frame.width
            if self.isExpanded {
                self.bandView.frame = NSRect(x: 0, y: frame.height - self.bandHeight, width: w, height: self.bandHeight)
                self.carousel.frame = NSRect(x: 0, y: 0, width: w, height: frame.height - self.bandHeight)
            } else {
                self.bandView.frame = NSRect(x: 0, y: 0, width: w, height: self.bandHeight)
                self.carousel.frame = NSRect(x: 0, y: 0, width: w, height: 0)
                self.carousel.isHidden = true
            }
        })
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
