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
        let reason: String?        // why the producer ranked it here
        let event: String?         // the story this item belongs to, when known
        let vote: Int?             // producer's last known effective vote: 1 / -1 / 0
    }
}

/// One recorded vote. The outbox is append-only from the widget's side; the
/// producer only ever reads it, so the widget also owns pruning.
struct NewsVote: Codable {
    let voteId: String
    let itemId: String
    let vote: Int
    let at: String                 // ISO-8601
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

    static func string(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f.string(from: d)
    }
}

/// Reads `news.json` from Application Support and owns `news-votes.json`, the
/// widget's outbox. The two files are independent: the producer may rewrite the
/// summary at any time and never touches the outbox.
final class NewsSource {
    private static let dir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/NotchWidget")
    static let path = dir.appendingPathComponent("news.json")
    static let votesPath = dir.appendingPathComponent("news-votes.json")

    /// How long a vote stays in the outbox. The producer reads on its own
    /// cadence and never clears entries, so the widget drops only the ones old
    /// enough that nothing could still be waiting on them.
    static let retention: TimeInterval = 14 * 24 * 3600

    func load() -> NewsSummary? {
        guard let data = try? Data(contentsOf: Self.path) else { return nil }
        return try? JSONDecoder().decode(NewsSummary.self, from: data)
    }

    // MARK: vote overlay

    /// Latest recorded vote per item, rebuilt from the outbox (on launch, and
    /// kept in memory afterwards).
    static func overlay() -> [String: NewsVote] {
        var latest: [String: NewsVote] = [:]
        for v in readVotes() {
            guard let at = ISODate.date(v.at) else { continue }
            if let cur = latest[v.itemId], let curAt = ISODate.date(cur.at), curAt >= at { continue }
            latest[v.itemId] = v
        }
        return latest
    }

    /// The vote to display per item: the local outbox wins over the producer's
    /// value when it was recorded after the summary was generated.
    static func effectiveVotes(_ s: NewsSummary, overlay: [String: NewsVote]) -> [String: Int] {
        let asOf = ISODate.date(s.asOf) ?? .distantPast
        var out: [String: Int] = [:]
        for it in s.items {
            var v = it.vote ?? 0
            if let o = overlay[it.id], let at = ISODate.date(o.at), at > asOf { v = o.vote }
            out[it.id] = v
        }
        return out
    }

    /// Append a vote to the outbox, pruning expired entries in the same write.
    /// Returns the entry so the caller can update its in-memory overlay without
    /// re-reading the file.
    @discardableResult
    static func vote(itemId: String, vote: Int) -> NewsVote {
        let entry = NewsVote(voteId: UUID().uuidString, itemId: itemId, vote: vote, at: ISODate.string(Date()))
        let cutoff = Date().addingTimeInterval(-retention)
        var kept = readVotes().filter { (ISODate.date($0.at) ?? .distantPast) >= cutoff }
        kept.append(entry)
        write(kept)
        return entry
    }

    // MARK: outbox file

    private struct VoteBox: Codable { let votes: [NewsVote] }

    private static func readVotes() -> [NewsVote] {
        guard let data = try? Data(contentsOf: votesPath),
              let box = try? JSONDecoder().decode(VoteBox.self, from: data) else { return [] }
        return box.votes
    }

    private static func write(_ votes: [NewsVote]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(VoteBox(votes: votes)) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `.atomic` writes a sibling temp file and renames it over the target, so
        // a producer reading concurrently never sees a half-written outbox.
        try? data.write(to: votesPath, options: .atomic)
    }
}
