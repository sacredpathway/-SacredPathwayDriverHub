import Foundation
import CoreLocation
import MapKit
import SwiftUI

// =============================================================================
// MARK: - Sacred Path truck profile
// -----------------------------------------------------------------------------
// The driver's saved truck profile (dimensions, weight, equipment) and its
// settings screen. The turn-by-turn navigation engine and its routing
// providers were removed 2026-09-17; the profile stays as saved driver data.
// =============================================================================

// MARK: Truck profile

enum TruckTrailerType: String, Codable, CaseIterable, Identifiable {
    case dryVan
    case reefer
    case flatbed
    case stepDeck
    case tanker
    case lowboy
    case carHauler
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dryVan:    return "Dry Van"
        case .reefer:    return "Reefer"
        case .flatbed:   return "Flatbed"
        case .stepDeck:  return "Step Deck"
        case .tanker:    return "Tanker"
        case .lowboy:    return "Lowboy"
        case .carHauler: return "Car Hauler"
        case .other:     return "Other"
        }
    }
}

struct SacredPathTruckProfile: Codable, Equatable {
    var heightFeet: Int
    var heightInches: Int
    var lengthFeet: Int
    var widthFeet: Int = 8
    var widthInches: Int = 6
    var grossWeightLbs: Int
    var axles: Int
    var hasHazmat: Bool
    // New routing inputs (defaulted so existing initializers keep compiling).
    var trailerType: TruckTrailerType = .dryVan
    var avoidTolls: Bool = false
    var avoidFerries: Bool = false
    var preferTruckStops: Bool = true
    var preferHighways: Bool = true

    static let defaultOwnerOperator = SacredPathTruckProfile(
        heightFeet: 13,
        heightInches: 6,
        lengthFeet: 53,
        grossWeightLbs: 80_000,
        axles: 5,
        hasHazmat: false
    )

    var heightTotalFeet: Double { Double(heightFeet) + Double(heightInches) / 12.0 }
    var widthTotalFeet: Double { Double(widthFeet) + Double(widthInches) / 12.0 }
    var heightMeters: Double { heightTotalFeet * 0.3048 }
    var widthMeters: Double { widthTotalFeet * 0.3048 }
    var weightMetricTons: Double { Double(grossWeightLbs) * 0.00045359237 }

    var summaryLine: String {
        var parts = ["\(heightFeet)′\(heightInches)″ H", "\(widthFeet)′\(widthInches)″ W", "\(grossWeightLbs / 1000)k lb", "\(lengthFeet)′"]
        if hasHazmat { parts.append("Hazmat") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Local truck-profile store (persisted, no network)

@MainActor
final class TruckProfileStore: ObservableObject {
    static let shared = TruckProfileStore()

    @Published var profile: SacredPathTruckProfile {
        didSet { persist() }
    }

    private let key = "sph.truckProfile.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(SacredPathTruckProfile.self, from: data) {
            profile = decoded
        } else {
            profile = .defaultOwnerOperator
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: MKPolyline helper

extension MKPolyline {
    /// Safe extraction of the polyline's coordinates via getCoordinates.
    func sacredPathCoordinates() -> [CLLocationCoordinate2D] {
        guard pointCount > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: pointCount
        )
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

// =============================================================================
// MARK: - Truck Profile settings UI (Task 5)
// =============================================================================

struct TruckProfileSettingsView: View {
    @ObservedObject private var store = TruckProfileStore.shared

    var body: some View {
        Form {
            Section("Dimensions") {
                Stepper(value: $store.profile.heightFeet, in: 8...16) {
                    labeled("Height (ft)", "\(store.profile.heightFeet)")
                }
                Stepper(value: $store.profile.heightInches, in: 0...11) {
                    labeled("Height (in)", "\(store.profile.heightInches)")
                }
                Stepper(value: $store.profile.lengthFeet, in: 20...80) {
                    labeled("Length (ft)", "\(store.profile.lengthFeet)")
                }
                Stepper(value: $store.profile.widthFeet, in: 7...10) {
                    labeled("Width (ft)", "\(store.profile.widthFeet)")
                }
                Stepper(value: $store.profile.widthInches, in: 0...11) {
                    labeled("Width (in)", "\(store.profile.widthInches)")
                }
                Stepper(value: $store.profile.grossWeightLbs, in: 10_000...105_000, step: 1_000) {
                    labeled("Gross weight", "\(store.profile.grossWeightLbs / 1000)k lb")
                }
                Stepper(value: $store.profile.axles, in: 2...9) {
                    labeled("Axles", "\(store.profile.axles)")
                }
            }
            Section("Equipment") {
                Picker("Trailer", selection: $store.profile.trailerType) {
                    ForEach(TruckTrailerType.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Hazmat", isOn: $store.profile.hasHazmat)
            }
            Section("Routing Preferences") {
                Toggle("Avoid tolls", isOn: $store.profile.avoidTolls)
                Toggle("Avoid ferries", isOn: $store.profile.avoidFerries)
                Toggle("Prefer truck stops", isOn: $store.profile.preferTruckStops)
                Toggle("Prefer highways", isOn: $store.profile.preferHighways)
            }
            Section {
                Text("Your truck profile is stored on this device. Sacred Path is a planning aid and does not provide turn-by-turn navigation.")
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
            }
        }
        .navigationTitle("Truck Profile")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.spGold)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.spTextSecondary)
            Spacer()
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(Color.spTextPrimary)
        }
    }
}
