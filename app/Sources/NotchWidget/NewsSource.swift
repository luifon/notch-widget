import Foundation

/// Ranked news produced by an external fetcher and dropped at a fixed neutral
/// path. The widget never fetches or ranks anything — it displays the summary
/// and records the reader's votes. Absent file → no news page.
struct NewsSummary: Codable {
    let asOf: String?
    let brief: String?
    let count: Int?
    let items: [Item]

    /// Items arrive ordered by score, best first.
    struct Item: Codable {
        let id: String
        let title: String
        let source: String?
        let url: String?
        let publishedAt: String?   // ISO-8601
        let score: Double?
        let reason: String?        // why the producer RANKED it here — not a vote reason
        let event: String?         // the story this item belongs to, when known
        let vote: Int?             // producer's last known effective vote: 1 / -1 / 0
        let voteReason: String?    // …and the reason key the reader attached to it
        let voteNote: String?      // …and their free text, for `other`
        let opened: Bool?          // producer's last known read state

        init(id: String, title: String, source: String? = nil, url: String? = nil,
             publishedAt: String? = nil, score: Double? = nil, reason: String? = nil,
             event: String? = nil, vote: Int? = nil, voteReason: String? = nil,
             voteNote: String? = nil, opened: Bool? = nil) {
            self.id = id; self.title = title; self.source = source; self.url = url
            self.publishedAt = publishedAt; self.score = score; self.reason = reason
            self.event = event; self.vote = vote; self.voteReason = voteReason
            self.voteNote = voteNote; self.opened = opened
        }
    }
}

/// The reason keys a downvote can carry. The widget writes only these; anything
/// else in the file is shown verbatim but never produced here.
enum VoteReason: String, CaseIterable {
    case dup, old
    case knewIt = "knew-it"
    case offTopic = "off-topic"
    case weakPiece = "weak-piece"
    case other

    /// What the chip says. The keys stay machine-stable; the labels don't.
    var label: String {
        switch self {
        case .dup: return "dup"
        case .old: return "old"
        case .knewIt: return "knew it"
        case .offTopic: return "off-topic"
        case .weakPiece: return "weak piece"
        case .other: return "other…"
        }
    }

    /// How the key reads back in the meta line once it's been picked.
    static func chipLabel(_ key: String) -> String {
        VoteReason(rawValue: key)?.label.replacingOccurrences(of: "…", with: "") ?? key
    }
}

/// One recorded vote. The outbox is append-only from the widget's side; the
/// producer only ever reads it, so the widget also owns pruning. A reason is
/// recorded as a second entry for the same item, never by rewriting the first.
struct NewsVote: Codable {
    let voteId: String
    let itemId: String
    let vote: Int
    let at: String                 // ISO-8601, fractional seconds
    let voteReason: String?
    let voteNote: String?

    init(voteId: String, itemId: String, vote: Int, at: String,
         voteReason: String? = nil, voteNote: String? = nil) {
        self.voteId = voteId; self.itemId = itemId; self.vote = vote; self.at = at
        self.voteReason = voteReason; self.voteNote = voteNote
    }
}

/// One recorded open. Same outbox contract as votes: the widget appends and
/// prunes, the producer only reads.
struct NewsOpen: Codable {
    let openId: String
    let itemId: String
    let url: String
    let at: String                 // ISO-8601, fractional seconds
}

/// What the UI shows for an item: the vote plus whatever reason came with it.
struct NewsVoteState {
    var vote: Int
    var reason: String?
    var note: String?
    static let none = NewsVoteState(vote: 0, reason: nil, note: nil)
}

/// ISO-8601 with and without fractional seconds — producers write both.
enum ISODate {
    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Always fractional: two clicks inside the same second are ordinary here
    /// (vote, then reason), and a whole-second stamp makes them indistinguishable.
    static func string(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone.current
        return f.string(from: d)
    }
}

/// Reads `news.json` from Application Support and owns `news-votes.json` and
/// `news-opens.json`, the widget's outboxes. The three files are independent:
/// the producer may rewrite the summary at any time and never touches an outbox.
final class NewsSource {
    private static let dir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/NotchWidget")
    static let path = dir.appendingPathComponent("news.json")
    static let votesPath = dir.appendingPathComponent("news-votes.json")
    static let opensPath = dir.appendingPathComponent("news-opens.json")

    /// How long an outbox entry stays. The producer reads on its own cadence and
    /// never clears entries, so the widget drops only the ones old enough that
    /// nothing could still be waiting on them.
    static let retention: TimeInterval = 14 * 24 * 3600

    func load() -> NewsSummary? {
        guard let data = try? Data(contentsOf: Self.path) else { return nil }
        return try? JSONDecoder().decode(NewsSummary.self, from: data)
    }

    // MARK: vote overlay

    /// Latest recorded vote per item, rebuilt from the outbox (on launch, and
    /// kept in memory afterwards). Entries written in the same instant are
    /// ordered by their position in the file, so the newer one wins.
    static func overlay() -> [String: NewsVote] {
        var latest: [String: NewsVote] = [:]
        for v in readVotes() {
            guard let at = ISODate.date(v.at) else { continue }
            if let cur = latest[v.itemId], let curAt = ISODate.date(cur.at), curAt > at { continue }
            latest[v.itemId] = v
        }
        return latest
    }

    /// The state to display per item: the local outbox wins over the producer's
    /// values when it was recorded after the summary was generated.
    static func effectiveVotes(_ s: NewsSummary, overlay: [String: NewsVote]) -> [String: NewsVoteState] {
        let asOf = ISODate.date(s.asOf) ?? .distantPast
        var out: [String: NewsVoteState] = [:]
        for it in s.items {
            var st = NewsVoteState(vote: it.vote ?? 0, reason: it.voteReason, note: it.voteNote)
            if let o = overlay[it.id], let at = ISODate.date(o.at), at > asOf {
                st = NewsVoteState(vote: o.vote, reason: o.voteReason, note: o.voteNote)
            }
            out[it.id] = st
        }
        return out
    }

    /// Items the reader has opened: the producer's flag, plus everything in the
    /// local outbox (which the producer may not have consumed yet).
    static func effectiveOpens(_ s: NewsSummary, opens: Set<String>) -> Set<String> {
        var out = opens
        for it in s.items where it.opened == true { out.insert(it.id) }
        return out
    }

    /// Append a vote to the outbox, pruning expired entries in the same write.
    /// Returns the entry so the caller can update its in-memory overlay without
    /// re-reading the file.
    @discardableResult
    static func vote(itemId: String, vote: Int, reason: String? = nil, note: String? = nil) -> NewsVote {
        let entry = NewsVote(voteId: UUID().uuidString, itemId: itemId, vote: vote,
                             at: ISODate.string(Date()), voteReason: reason, voteNote: note)
        let cutoff = Date().addingTimeInterval(-retention)
        var kept = readVotes().filter { (ISODate.date($0.at) ?? .distantPast) >= cutoff }
        kept.append(entry)
        write(VoteBox(votes: kept), to: votesPath)
        return entry
    }

    // MARK: opens outbox

    /// Item ids recorded as opened locally.
    static func openedIDs() -> Set<String> { Set(readOpens().map(\.itemId)) }

    /// Record that a headline was actually opened. Called only after the open
    /// succeeded, so the outbox can't claim a read the reader never got.
    static func recordOpen(itemId: String, url: URL) {
        let entry = NewsOpen(openId: UUID().uuidString, itemId: itemId,
                             url: url.absoluteString, at: ISODate.string(Date()))
        let cutoff = Date().addingTimeInterval(-retention)
        var kept = readOpens().filter { (ISODate.date($0.at) ?? .distantPast) >= cutoff }
        kept.append(entry)
        write(OpenBox(opens: kept), to: opensPath)
    }

    // MARK: outbox files

    private struct VoteBox: Codable { let votes: [NewsVote] }
    private struct OpenBox: Codable { let opens: [NewsOpen] }

    private static func readVotes() -> [NewsVote] {
        guard let data = try? Data(contentsOf: votesPath),
              let box = try? JSONDecoder().decode(VoteBox.self, from: data) else { return [] }
        return box.votes
    }

    private static func readOpens() -> [NewsOpen] {
        guard let data = try? Data(contentsOf: opensPath),
              let box = try? JSONDecoder().decode(OpenBox.self, from: data) else { return [] }
        return box.opens
    }

    private static func write<T: Encodable>(_ box: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(box) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `.atomic` writes a sibling temp file and renames it over the target, so
        // a producer reading concurrently never sees a half-written outbox.
        try? data.write(to: url, options: .atomic)
    }
}
