import Foundation
import CoreLocation
import UserNotifications
import Combine

// =============================================================================
// MARK: - AlertEngine
// -----------------------------------------------------------------------------
// Combines the live weather snapshot + the truck's location into actionable
// DriverAlerts. Three delivery surfaces, per spec:
//   1. Dashboard card  — `latestActive` drives the "Weather Near Me" card badge.
//   2. Push notification — local UNUserNotification (no APNs / server needed).
//   3. Alert center     — `history` is the persisted, de-duplicated log.
//
// Alert sources:
//   * Provider alerts (NWS events via OWM One Call) → mapped to categories.
//   * Derived alerts from current conditions (wind, snow/ice, heavy rain,
//     extreme heat) so the engine still warns even without a One Call sub.
//
// Notifications are LOCAL only, so this needs notification permission but NOT
// the Push Notifications capability. Authorization is requested the first time
// the user enables alerts (or opens the Weather Map), never at launch.
// =============================================================================

@MainActor
final class AlertEngine: ObservableObject {
    static let shared = AlertEngine()

    @Published private(set) var history: [DriverAlert] = []
    @Published var notificationsEnabled: Bool

    private static let notifPrefKey = "sp.maps.alerts.notifications_enabled"
    private static let historyLimit = 100

    private var hydrated = false
    private var cancellables = Set<AnyCancellable>()

    /// Active (last 6h) alerts, newest first — used by the dashboard card.
    var activeAlerts: [DriverAlert] {
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        return history.filter { $0.createdAt >= cutoff }
                      .sorted { $0.createdAt > $1.createdAt }
    }

    var latestActive: DriverAlert? { activeAlerts.first }

    private init() {
        notificationsEnabled = UserDefaults.standard.bool(forKey: Self.notifPrefKey)
    }

    func hydrateFromCacheIfNeeded() async {
        guard !hydrated else { return }
        hydrated = true
        if let cached = await MapCacheStore.shared.load([DriverAlert].self,
                                                        key: MapCacheKey.alertHistory) {
            history = cached
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.notifPrefKey)
        if enabled { requestNotificationAuthorization() }
    }

    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Core entry point — call whenever a fresh weather snapshot lands. Builds
    /// candidate alerts, de-duplicates against history, appends new ones, and
    /// notifies for anything at `.warning` severity (or provider warnings).
    func evaluate(snapshot: WeatherSnapshot, at coordinate: CLLocationCoordinate2D) async {
        await hydrateFromCacheIfNeeded()

        var candidates: [DriverAlert] = []
        let coord = CodableCoordinate(coordinate)
        let place = snapshot.conditions.placeName

        // 1) Provider-issued alerts (NWS events) → category mapping.
        for event in snapshot.alerts {
            let category = Self.category(forEvent: event.event)
            candidates.append(DriverAlert(
                category: category,
                severity: .warning,
                title: event.event,
                message: Self.condense(event.description, fallback: event.event),
                coordinate: coord,
                placeName: place
            ))
        }

        // 2) Derived alerts from current conditions.
        let c = snapshot.conditions
        candidates.append(contentsOf: Self.derivedAlerts(from: c, coordinate: coord, place: place))

        // De-duplicate by dedupeKey against existing history.
        let existingKeys = Set(history.map { $0.dedupeKey })
        let fresh = candidates.filter { !existingKeys.contains($0.dedupeKey) }
        guard !fresh.isEmpty else { return }

        for alert in fresh {
            history.insert(alert, at: 0)
            if notificationsEnabled, alert.severity >= .warning {
                postNotification(for: alert)
                if let idx = history.firstIndex(where: { $0.id == alert.id }) {
                    history[idx].didNotify = true
                }
            }
        }

        if history.count > Self.historyLimit {
            history = Array(history.prefix(Self.historyLimit))
        }
        await MapCacheStore.shared.save(history, key: MapCacheKey.alertHistory)
    }

    /// Severe-weather forecast alerts (One Call `alerts` or 2.5 heuristics)
    /// flowing in from ForecastService. Maps onto the existing categories via
    /// the same event-name mapping NWS alerts use, then runs the identical
    /// dedupe + notify + persist pipeline as `evaluate`. Purely additive —
    /// the snapshot-driven path above is untouched.
    func ingestSevereWeather(_ events: [WeatherAlertEvent],
                             at coordinate: CLLocationCoordinate2D,
                             placeName: String?) async {
        await hydrateFromCacheIfNeeded()
        guard !events.isEmpty else { return }

        let coord = CodableCoordinate(coordinate)
        let candidates = events.map { event in
            DriverAlert(
                category: Self.category(forEvent: event.event),
                severity: .warning,
                title: event.event,
                message: Self.condense(event.description, fallback: event.event),
                coordinate: coord,
                placeName: placeName
            )
        }

        let existingKeys = Set(history.map { $0.dedupeKey })
        let fresh = candidates.filter { !existingKeys.contains($0.dedupeKey) }
        guard !fresh.isEmpty else { return }

        for alert in fresh {
            history.insert(alert, at: 0)
            if notificationsEnabled, alert.severity >= .warning {
                postNotification(for: alert)
                if let idx = history.firstIndex(where: { $0.id == alert.id }) {
                    history[idx].didNotify = true
                }
            }
        }
        if history.count > Self.historyLimit {
            history = Array(history.prefix(Self.historyLimit))
        }
        await MapCacheStore.shared.save(history, key: MapCacheKey.alertHistory)
    }

    func clearHistory() {
        history = []
        Task { await MapCacheStore.shared.save(history, key: MapCacheKey.alertHistory) }
    }

    // MARK: - Local notification
    private func postNotification(for alert: DriverAlert) {
        let content = UNMutableNotificationContent()
        content.title = "\(alert.category.title) — \(alert.severity.label)"
        content.body = alert.message
        content.sound = .default
        if let place = alert.placeName { content.subtitle = place }

        let request = UNNotificationRequest(
            identifier: alert.id.uuidString,
            content: content,
            trigger: nil // deliver now
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Derivation rules
    private static func derivedAlerts(from c: WeatherConditions,
                                      coordinate: CodableCoordinate,
                                      place: String?) -> [DriverAlert] {
        var out: [DriverAlert] = []

        func make(_ cat: DriverAlertCategory, _ sev: DriverAlertSeverity, _ msg: String) {
            out.append(DriverAlert(category: cat, severity: sev,
                                   title: cat.title, message: msg,
                                   coordinate: coordinate, placeName: place))
        }

        // High wind — sustained or gusts.
        let gust = c.windGustMph ?? c.windSpeedMph
        if gust >= 45 {
            make(.highWind, .warning,
                 "High wind near you — gusts ~\(Int(gust)) mph. Use caution with empty or high-profile trailers.")
        } else if c.windSpeedMph >= 30 || gust >= 35 {
            make(.highWind, .watch,
                 "Breezy to windy — sustained \(Int(c.windSpeedMph)) mph. Watch for crosswinds on exposed lanes.")
        }

        // Snow / ice.
        if c.kind == .snow {
            let sev: DriverAlertSeverity = c.visibilityMiles < 1 ? .warning : .watch
            make(.snowIce, sev,
                 "Snow reported near you. Visibility ~\(String(format: "%.1f", c.visibilityMiles)) mi. Reduce speed; watch for ice on ramps and bridges.")
        }

        // Heavy rain.
        if c.kind == .rain && c.visibilityMiles < 2 {
            make(.heavyRain, .watch,
                 "Heavy rain near you — visibility ~\(String(format: "%.1f", c.visibilityMiles)) mi. Increase following distance; risk of hydroplaning.")
        }

        // Thunderstorms.
        if c.kind == .thunderstorm {
            make(.severeStorm, .warning,
                 "Thunderstorms near you. Lightning, downpours, and gusty winds possible. Consider delaying through the cell.")
        }

        // Extreme heat.
        if c.temperatureF >= 100 || c.kind == .extremeHeat {
            make(.extremeHeat, .watch,
                 "Extreme heat — \(Int(c.temperatureF))°F. Check tire pressure and reefer load temps; hydrate.")
        }

        // Fog / low visibility (road-impact, surfaced as severe storm-adjacent advisory).
        if c.kind == .fog && c.visibilityMiles < 0.5 {
            make(.heavyRain, .watch,
                 "Dense fog — visibility under half a mile. Use low beams and reduce speed.")
        }

        return out
    }

    private static func category(forEvent event: String) -> DriverAlertCategory {
        let e = event.lowercased()
        if e.contains("flood") { return .flood }
        if e.contains("wind")  { return .highWind }
        if e.contains("snow") || e.contains("ice") || e.contains("winter") || e.contains("blizzard") { return .snowIce }
        if e.contains("heat")  { return .extremeHeat }
        if e.contains("thunder") || e.contains("storm") || e.contains("tornado") || e.contains("hurricane") { return .severeStorm }
        if e.contains("rain")  { return .heavyRain }
        return .severeStorm
    }

    private static func condense(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.count <= 180 { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: 180)
        return String(trimmed[..<idx]) + "…"
    }
}
