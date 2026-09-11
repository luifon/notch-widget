import AppKit
import EventKit

/// One meeting.
struct Meeting {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let sender: String
}

/// A meeting rendered as a card in the expanded panel.
struct MeetingCard {
    let id: String
    let title: String
    let time: String        // "10:00 – 10:30 · in 14m"
    let sender: String
    let urgency: Urgency
}

/// What the collapsed band shows.
struct BandState {
    let left: String
    let right: String
    let urgency: Urgency
}

/// Reads meetings from EventKit (all calendars the macOS Calendar app knows)
/// and maps them to band/card view models. Color thresholds live here.
final class MeetingSource {
    private let store = EKEventStore()

    var soonMinutes: Double = 15
    var nowMinutes: Double = 5

    private lazy var hm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        let handler: (Bool, Error?) -> Void = { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
        if #available(macOS 14, *) {
            store.requestFullAccessToEvents(completion: handler)
        } else {
            store.requestAccess(to: .event, completion: handler)
        }
    }

    func observeChanges(_ block: @escaping () -> Void) {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { _ in block() }
    }

    /// The next `limit` meetings: upcoming or currently running, within 18h,
    /// skipping all-day events.
    func nextMeetings(limit: Int = 3, now: Date = Date()) -> [Meeting] {
        guard let end = Calendar.current.date(byAdding: .hour, value: 18, to: now) else { return [] }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-3600), end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .filter { ($0.endDate ?? now) > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { Meeting(id: $0.eventIdentifier ?? "\($0.title ?? "")-\($0.startDate.timeIntervalSince1970)",
                           title: $0.title ?? "Untitled", start: $0.startDate,
                           end: $0.endDate, sender: $0.organizer?.name ?? "") }
    }

    func nextMeeting(now: Date = Date()) -> Meeting? {
        nextMeetings(limit: 1, now: now).first
    }

    func urgency(for m: Meeting, now: Date = Date()) -> Urgency {
        if now >= m.start && now < m.end { return .now }          // live
        let mins = m.start.timeIntervalSince(now) / 60
        if mins <= nowMinutes { return .now }
        if mins <= soonMinutes { return .soon }
        return .calm
    }

    /// Cards for the expanded meeting page.
    func meetingCards(now: Date = Date()) -> [MeetingCard] {
        nextMeetings(now: now).map { m in
            MeetingCard(id: m.id,
                        title: m.title,
                        time: "\(hm.string(from: m.start)) – \(hm.string(from: m.end)) · \(countdown(m, now: now))",
                        sender: m.sender,
                        urgency: urgency(for: m, now: now))
        }
    }

    /// What the collapsed band shows (the single next meeting).
    func snapshot(now: Date = Date()) -> BandState {
        guard let m = nextMeeting(now: now) else {
            return BandState(left: "No meetings", right: "", urgency: .calm)
        }
        return BandState(left: shortTitle(m.title), right: countdown(m, now: now), urgency: urgency(for: m, now: now))
    }

    private func countdown(_ m: Meeting, now: Date) -> String {
        if now >= m.start && now < m.end { return "live" }
        let secs = Int(m.start.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        let mins = secs / 60
        if mins < 60 { return "in \(mins)m" }
        let hrs = mins / 60, rem = mins % 60
        return rem == 0 ? "in \(hrs)h" : "in \(hrs)h\(rem)m"
    }

    private func shortTitle(_ s: String, max: Int = 16) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}
