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
            let mock: [MeetingCard] = [
                MeetingCard(id: "m1", title: "Daily RJ", time: "10:00 – 10:30 · in 3m", sender: "Rafael J.", urgency: .now),
                MeetingCard(id: "m2", title: "Client sync — a longer title that should truncate", time: "11:00 – 11:45 · in 12m", sender: "Marina Alves", urgency: .soon),
                MeetingCard(id: "m3", title: "Design review", time: "15:00 – 15:30 · in 5h", sender: "", urgency: .calm),
            ]
            meetingCount = mock.count
            carousel.pages = [.meetings(mock)]
            bandView.apply(BandState(left: "Daily RJ", right: "in 3m", urgency: .now))
            lastCards = mock
            applyCollapsedFrame()
            updateFlash()
            if ProcessInfo.processInfo.environment["NOTCH_MOCK_EXPAND"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.setExpanded(true) }
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
        var pages = carousel.pages
        pages[0] = .meetings(cards)
        carousel.pages = pages
        if isExpanded { setExpanded(true, force: true) } else { applyCollapsedFrame() }
        updateFlash()
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
        bandView.cornerRadius = expanded ? 0 : 11

        let frame: NSRect
        if expanded {
            carousel.isHidden = false
            let ph = CarouselPanelView.panelHeight(meetingCards: meetingCount)
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
