import Foundation

/// Current weather + today's high/low from Open-Meteo (keyless). Location comes
/// from a local config file so the public repo never hardcodes a personal
/// location; the committed default is a generic city.
struct WeatherSummary {
    let tempC: Double
    let feelsC: Double
    let code: Int
    let maxC: Double
    let minC: Double
    let place: String

    var label: String { WeatherSummary.labels[code] ?? "—" }

    /// WMO weather-code → short label.
    static let labels: [Int: String] = [
        0: "Clear", 1: "Mainly clear", 2: "Partly cloudy", 3: "Overcast",
        45: "Fog", 48: "Fog",
        51: "Light drizzle", 53: "Drizzle", 55: "Heavy drizzle",
        56: "Freezing drizzle", 57: "Freezing drizzle",
        61: "Light rain", 63: "Rain", 65: "Heavy rain",
        66: "Freezing rain", 67: "Freezing rain",
        71: "Light snow", 73: "Snow", 75: "Heavy snow", 77: "Snow grains",
        80: "Showers", 81: "Showers", 82: "Heavy showers",
        85: "Snow showers", 86: "Snow showers",
        95: "Thunderstorm", 96: "Thunderstorm", 99: "Thunderstorm",
    ]
}

struct WeatherConfig: Codable {
    let latitude: Double
    let longitude: Double
    let place: String?
}

final class WeatherSource {
    static let configPath = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/NotchWidget/weather-config.json")

    // Generic committed default (São Paulo) — the local config overrides it.
    private var config: WeatherConfig {
        if let data = try? Data(contentsOf: Self.configPath),
           let c = try? JSONDecoder().decode(WeatherConfig.self, from: data) {
            return c
        }
        return WeatherConfig(latitude: -23.5505, longitude: -46.6333, place: "São Paulo")
    }

    func fetch(_ done: @escaping (WeatherSummary?) -> Void) {
        let cfg = config
        let place = cfg.place ?? "—"
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(cfg.latitude)),
            .init(name: "longitude", value: String(cfg.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "1"),
        ]
        URLSession.shared.dataTask(with: comps.url!) { data, _, _ in
            let summary = data.flatMap { Self.parse($0, place: place) }
            DispatchQueue.main.async { done(summary) }
        }.resume()
    }

    private static func parse(_ data: Data, place: String) -> WeatherSummary? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = obj["current"] as? [String: Any],
              let daily = obj["daily"] as? [String: Any],
              let t = (cur["temperature_2m"] as? NSNumber)?.doubleValue,
              let f = (cur["apparent_temperature"] as? NSNumber)?.doubleValue,
              let code = (cur["weather_code"] as? NSNumber)?.intValue,
              let mx = (daily["temperature_2m_max"] as? [NSNumber])?.first?.doubleValue,
              let mn = (daily["temperature_2m_min"] as? [NSNumber])?.first?.doubleValue
        else { return nil }
        return WeatherSummary(tempC: t, feelsC: f, code: code, maxC: mx, minC: mn, place: place)
    }
}
