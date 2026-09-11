import Foundation

/// Agents that have stopped and need attention, produced by an external emitter
/// and dropped at a fixed neutral path. The widget only displays it.
struct AgentsSummary: Codable {
    let asOf: String?
    let count: Int
    let needsAttention: [Item]

    struct Item: Codable {
        let label: String
        let repo: String
        let engine: String   // "claude" | "codex"
        let state: String    // "done" | "interrupted"
        let since: Double?   // epoch milliseconds
    }
}

final class AgentsSource {
    static let path = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/NotchWidget/agents.json")

    func load() -> AgentsSummary? {
        guard let data = try? Data(contentsOf: Self.path) else { return nil }
        return try? JSONDecoder().decode(AgentsSummary.self, from: data)
    }
}
