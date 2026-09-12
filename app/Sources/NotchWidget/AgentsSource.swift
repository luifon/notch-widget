import Foundation

/// Agents that have stopped and need attention, produced by an external emitter
/// and dropped at a fixed neutral path. The widget only displays it.
struct AgentsSummary: Codable {
    let asOf: String?
    let count: Int
    let needsAttention: [Item]

    struct Item: Codable {
        let id: String       // worktree id, used to acknowledge
        let label: String    // project (repo) — the primary identifier
        let detail: String   // branch / worktree, when it adds information
        let engine: String   // "claude" | "codex"
        let state: String    // "review" | "needs approval" | "finished" | "interrupted"
        let since: Double?   // epoch milliseconds
    }
}

final class AgentsSource {
    private static let dir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/NotchWidget")
    static let path = dir.appendingPathComponent("agents.json")
    private static let ackPath = dir.appendingPathComponent("agents-ack.json")

    func load() -> AgentsSummary? {
        guard let data = try? Data(contentsOf: Self.path) else { return nil }
        return try? JSONDecoder().decode(AgentsSummary.self, from: data)
    }

    /// Record that the user acknowledged a worktree; the emitter reads this file
    /// and stops flagging that worktree's finish.
    static func acknowledge(_ id: String) {
        var acked: [String: Double] = [:]
        if let data = try? Data(contentsOf: ackPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let existing = obj["acked"] as? [String: Double] {
            acked = existing
        }
        acked[id] = Date().timeIntervalSince1970 * 1000
        if let data = try? JSONSerialization.data(withJSONObject: ["acked": acked]) {
            try? data.write(to: ackPath)
        }
    }
}
