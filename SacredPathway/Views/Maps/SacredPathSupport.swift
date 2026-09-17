import Foundation
import SwiftUI
import MapKit
import CoreLocation
import UIKit

// =============================================================================
// MARK: - Sacred Path support (GPS-free)
// -----------------------------------------------------------------------------
// Driver Hub's Sacred Path is a TRUCKING-RESOURCE LOCATOR and TRIP-PLANNING
// tool. It helps drivers find truck stops, rest areas, fuel, parking, scales,
// and repairs, and preview a planned route. It does NOT provide turn-by-turn
// navigation (removed 2026-09-17).
//
// This file holds the shared building blocks the rest of the feature uses:
//   * SacredPathDestination   — a resolved place (name + coordinate)
//   * SacredPathFormat        — distance / duration / clock formatting
//   * SacredPathExternalMaps  — deprecated compatibility shim; no external open
//   * SacredPathDisclaimer    — the required compliance disclaimer
// =============================================================================

/// A resolved destination or stop — just a name and a coordinate. Shared across
/// the hub, trip planner, AI planner, and the truck-stop map.
struct SacredPathDestination: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func mapItem() -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }
}

// MARK: - Formatting helpers

/// Pure formatting utilities (no location, no GPS). Replaces the static helpers
/// that used to live on the removed navigation engine.
enum SacredPathFormat {

    static func formatDistance(_ meters: CLLocationDistance) -> String {
        let miles = meters / 1609.344
        if miles >= 100 { return "\(Int(miles.rounded())) mi" }
        if miles >= 0.19 { return String(format: "%.1f mi", miles) }
        let feet = meters * 3.28084
        return "\(Int((feet / 50).rounded()) * 50) ft"
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours == 0 { return "\(minutes)m" }
        return "\(hours)h \(minutes)m"
    }

    static func formatClock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - External maps compatibility shim

/// Deprecated compatibility namespace. Sacred Path now keeps navigation inside
/// Driver Hub; these methods intentionally do not open external map apps.
enum SacredPathExternalMaps {

    /// Deprecated: external Apple Maps launch removed.
    static func openAppleMaps(name: String, latitude: Double, longitude: Double) {
    }

    /// Deprecated: external Apple Maps launch removed.
    static func openAppleMaps(stops: [SacredPathDestination]) {
    }

}

// MARK: - Compliance disclaimer

/// Required disclaimer shown wherever Sacred Path surfaces routes or stops.
struct SacredPathDisclaimer: View {
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle.fill")
                .font(.caption2)
                .foregroundStyle(Color.spTextSecondary)
            Text("Disclaimer: Sacred Path route previews and bid guidance are planning aids. Always follow posted signs, legal truck routes, broker terms, weather alerts, and your own professional judgment.")
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(Color.spTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
