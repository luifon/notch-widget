import Foundation

/// Day-over-day finance summary, produced by an external tool and dropped at a
/// fixed neutral path. The widget only displays it — it never computes net
/// worth or reaches into any finance app. Absent file → no finance page.
struct FinanceSummary: Codable {
    let asOf: String?
    let since: String?
    let netWorth: Double
    let liquidNetWorth: Double
    let deltaAbs: Double?
    let deltaPct: Double?
    let movers: [Mover]
    let series: [Double]?   // recent net-worth values for the sparkline

    struct Mover: Codable {
        let name: String
        let deltaAbs: Double
        let deltaPct: Double
    }
}

/// Reads the finance summary from Application Support. The producer (whatever it
/// is) writes to this same path; the widget stays ignorant of its source.
final class FinanceSource {
    static let path = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/NotchWidget/finance.json")

    func load() -> FinanceSummary? {
        guard let data = try? Data(contentsOf: Self.path) else { return nil }
        return try? JSONDecoder().decode(FinanceSummary.self, from: data)
    }
}
