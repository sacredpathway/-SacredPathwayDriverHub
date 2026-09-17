import Foundation
import CoreLocation
import MapKit

// =============================================================================
// MARK: - AI Trip Planner (HOS + fuel aware) — NOT GPS navigation
// -----------------------------------------------------------------------------
// Sacred Path Driver Hub is a TRIP PLANNING tool. It does NOT provide live
// turn-by-turn navigation and is not an FMCSA-certified ELD. This engine takes
// a driver's trip, hours-of-service (HOS) status, and fuel status, then plans
// when/where to fuel, take the 30-minute break, and take the 10-hour and
// 34-hour resets so the load can be delivered legally and on time.
//
// Everything here is pure Swift with no networking, so the planner works fully
// in MANUAL mode even when Motive ELD is not connected. When Motive is
// connected, HOS/fuel values are pre-filled from Motive (see MotiveIntegration)
// but the planning math is identical.
// =============================================================================

// MARK: Inputs

/// Hours-of-service clocks the driver has left, in hours. These mirror the
/// federal property-carrying limits but Sacred Path only PLANS against them —
/// the official log of record stays in Motive (or the driver's certified ELD).
struct HOSStatus: Codable, Equatable {
    /// 11-hour driving limit remaining.
    var driveTimeLeftHours: Double
    /// 14-hour on-duty window remaining.
    var shiftTimeLeftHours: Double
    /// 60/70-hour cycle remaining.
    var cycleTimeLeftHours: Double
    /// Hours of driving accumulated since the last qualifying 30-minute break.
    /// A 30-minute break is required before 8 cumulative hours of driving.
    var hoursDrivenSinceBreak: Double

    static let fullDay = HOSStatus(
        driveTimeLeftHours: 11,
        shiftTimeLeftHours: 14,
        cycleTimeLeftHours: 70,
        hoursDrivenSinceBreak: 0
    )

    /// Hours of driving allowed before the next required 30-minute break.
    var hoursUntilBreakRequired: Double { max(0, 8 - hoursDrivenSinceBreak) }
}

/// Fuel status used to plan fuel stops. Level is a fraction 0...1 of tank.
struct FuelStatus: Codable, Equatable {
    /// Current fuel level as a fraction of the tank (0.0 empty … 1.0 full).
    var level: Double
    /// Usable tank size in gallons (both tanks combined).
    var tankSizeGallons: Double
    /// Estimated fuel economy in miles per gallon.
    var mpg: Double
    /// Reserve fraction the driver never wants to drop below (default 1/8 tank).
    var reserveFraction: Double = 0.125

    static let typical = FuelStatus(level: 0.5, tankSizeGallons: 200, mpg: 6.5)

    /// Miles of range available before hitting the reserve threshold.
    var usableRangeMiles: Double {
        let usableFraction = max(0, level - reserveFraction)
        return usableFraction * tankSizeGallons * mpg
    }

    /// Miles between fuel stops once refueled (full tank down to reserve).
    var milesPerTank: Double {
        max(1, (1.0 - reserveFraction) * tankSizeGallons * mpg)
    }
}

/// Everything the planner needs to build a plan. Locations are free text plus
/// optional resolved coordinates (resolved in the UI via MKLocalSearch).
struct TripPlanRequest: Equatable {
    var pickupName: String
    var deliveryName: String
    var pickupCoordinate: CLLocationCoordinate2D?
    var deliveryCoordinate: CLLocationCoordinate2D?
    var pickupDate: Date
    var deliveryDate: Date
    /// Total driving distance in miles (resolved from the route, editable).
    var distanceMiles: Double
    /// Planning average speed (mph). 55 is a safe default for trucks.
    var averageSpeedMph: Double = 55
    var hos: HOSStatus
    var fuel: FuelStatus

    static func == (lhs: TripPlanRequest, rhs: TripPlanRequest) -> Bool {
        lhs.pickupName == rhs.pickupName &&
        lhs.deliveryName == rhs.deliveryName &&
        lhs.pickupDate == rhs.pickupDate &&
        lhs.deliveryDate == rhs.deliveryDate &&
        lhs.distanceMiles == rhs.distanceMiles &&
        lhs.averageSpeedMph == rhs.averageSpeedMph &&
        lhs.hos == rhs.hos &&
        lhs.fuel == rhs.fuel
    }
}

// MARK: Output

enum TripPlanEventKind: String, Codable {
    case start
    case fuelStop
    case break30
    case reset10
    case reset34
    case delivery

    var title: String {
        switch self {
        case .start:    return "Depart Pickup"
        case .fuelStop: return "Fuel Stop"
        case .break30:  return "30-Minute Break"
        case .reset10:  return "10-Hour Reset"
        case .reset34:  return "34-Hour Restart"
        case .delivery: return "Arrive Delivery"
        }
    }

    var symbol: String {
        switch self {
        case .start:    return "shippingbox.fill"
        case .fuelStop: return "fuelpump.fill"
        case .break30:  return "cup.and.saucer.fill"
        case .reset10:  return "bed.double.fill"
        case .reset34:  return "moon.zzz.fill"
        case .delivery: return "house.fill"
        }
    }
}

/// One planned event along the trip. `mileMark` is miles from the pickup;
/// `clockTime` is the projected wall-clock time at that point.
struct TripPlanEvent: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: TripPlanEventKind
    var mileMark: Double
    var clockTime: Date
    var detail: String

    // Route-aware recommendation (populated by TripRouteService after the plan
    // is generated). All optional with defaults so existing saved plans decode
    // unchanged and the engine's memberwise init keeps working.
    var recommendedStopName: String? = nil
    var recommendedStopBrand: String? = nil
    var recommendedLatitude: Double? = nil
    var recommendedLongitude: Double? = nil

    var mileText: String {
        mileMark <= 0 ? "Start" : "Mile \(Int(mileMark.rounded()))"
    }

    var recommendedCoordinate: CLLocationCoordinate2D? {
        guard let lat = recommendedLatitude, let lon = recommendedLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

enum TripPlanSeverity: String, Codable {
    case info
    case caution
    case blocker
}

struct TripPlanWarning: Identifiable, Codable, Hashable {
    var id = UUID()
    var severity: TripPlanSeverity
    var message: String
}

/// The complete, saveable plan.
struct TripPlan: Identifiable, Codable, Hashable {
    var id = UUID()
    var pickupName: String
    var deliveryName: String
    var pickupDate: Date
    var deliveryDate: Date
    var distanceMiles: Double
    var totalDriveHours: Double
    /// Projected arrival including all planned breaks/resets.
    var projectedArrival: Date
    var events: [TripPlanEvent]
    var warnings: [TripPlanWarning]
    var createdAt: Date = Date()

    var fuelStopCount: Int { events.filter { $0.kind == .fuelStop }.count }
    var isFeasible: Bool { !warnings.contains { $0.severity == .blocker } }

    /// Plain-text summary used by "Copy route plan" and saved exports.
    func summaryText() -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE MMM d, h:mm a"
        var lines: [String] = []
        lines.append("SACRED PATH — TRIP PLAN")
        lines.append("(Planning aid only — not turn-by-turn navigation or an ELD)")
        lines.append("")
        lines.append("\(pickupName)  →  \(deliveryName)")
        lines.append("Distance: \(Int(distanceMiles.rounded())) mi · Drive time: \(TripTime.duration(hours: totalDriveHours))")
        lines.append("Pickup:   \(df.string(from: pickupDate))")
        lines.append("Delivery: \(df.string(from: deliveryDate))")
        lines.append("Projected arrival: \(df.string(from: projectedArrival))")
        lines.append("")
        lines.append("PLAN:")
        for e in events {
            lines.append("• \(e.mileText) — \(e.kind.title) (\(df.string(from: e.clockTime)))")
            if !e.detail.isEmpty { lines.append("    \(e.detail)") }
        }
        if !warnings.isEmpty {
            lines.append("")
            lines.append("HEADS UP:")
            for w in warnings {
                let tag = w.severity == .blocker ? "[BLOCKER] " : (w.severity == .caution ? "[CAUTION] " : "")
                lines.append("• \(tag)\(w.message)")
            }
        }
        lines.append("")
        lines.append("Official hours of service remain in your certified ELD (Motive).")
        return lines.joined(separator: "\n")
    }
}

// MARK: Time helpers (replaces the old turn-by-turn engine's formatter)

enum TripTime {
    /// Formats a duration given in HOURS as e.g. "6 hr 30 min".
    static func duration(hours: Double) -> String {
        duration(seconds: hours * 3600)
    }

    /// Formats a duration given in SECONDS as e.g. "45 min" / "6 hr 30 min".
    static func duration(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }
}

// MARK: - The planner engine

/// Pure-Swift HOS + fuel trip planner. Walks the trip mile-by-segment in time,
/// inserting fuel stops, the 30-minute break, and 10/34-hour resets exactly
/// when the clocks require them, then reports feasibility against the delivery
/// appointment. No networking — works entirely in manual mode.
enum TripPlannerEngine {

    /// Hours added to the trip for each event type (planning estimates).
    private static let fuelStopHours = 0.75      // ~45 min to fuel + walk
    private static let break30Hours = 0.5        // 30-minute break
    private static let reset10Hours = 10.0       // 10-hour off-duty reset
    private static let reset34Hours = 34.0       // 34-hour restart

    static func plan(_ req: TripPlanRequest) -> TripPlan {
        let speed = max(20, req.averageSpeedMph)
        let totalMiles = max(0, req.distanceMiles)
        let totalDriveHours = totalMiles / speed

        var events: [TripPlanEvent] = []
        var warnings: [TripPlanWarning] = []

        // Mutable running clocks.
        var clock = req.pickupDate
        var milesDone = 0.0
        var driveLeft = req.hos.driveTimeLeftHours          // 11-hr
        var shiftLeft = req.hos.shiftTimeLeftHours          // 14-hr
        var cycleLeft = req.hos.cycleTimeLeftHours          // 60/70-hr
        var hoursUntilBreak = req.hos.hoursUntilBreakRequired
        var rangeLeft = req.fuel.usableRangeMiles           // miles until reserve

        // Depart.
        events.append(TripPlanEvent(
            kind: .start, mileMark: 0, clockTime: clock,
            detail: "Fuel \(Int((req.fuel.level * 100).rounded()))% · range ~\(Int(rangeLeft.rounded())) mi to reserve"
        ))

        // Up-front feasibility on the long clocks.
        if cycleLeft + 0.01 < totalDriveHours {
            warnings.append(TripPlanWarning(
                severity: .blocker,
                message: "Your \(Int(req.hos.cycleTimeLeftHours))-hr cycle has \(TripTime.duration(hours: cycleLeft)) left but the trip needs \(TripTime.duration(hours: totalDriveHours)) of driving. A 34-hour restart is required to complete this load."
            ))
        }

        // Guard against pathological loops.
        var guardCounter = 0
        let maxEvents = 200

        while milesDone < totalMiles - 0.01 && guardCounter < maxEvents {
            guardCounter += 1

            let milesRemaining = totalMiles - milesDone

            // How far can we drive before SOMETHING forces a stop?
            // Limit candidates (in miles):
            let byDrive = driveLeft * speed
            let byShift = shiftLeft * speed
            let byBreak = hoursUntilBreak * speed
            let byFuel = rangeLeft
            let segment = max(0, min(milesRemaining, byDrive, byShift, byBreak, byFuel))

            // If we're pinned at zero, a clock is exhausted — insert the
            // controlling stop and reset it, then continue.
            if segment <= 0.01 {
                // Decide which limit hit zero first; prefer the most-restrictive.
                if rangeLeft <= 0.01 {
                    insertFuel(&events, &clock, milesDone, &rangeLeft, req)
                } else if hoursUntilBreak <= 0.01 {
                    insertBreak(&events, &clock, milesDone, &hoursUntilBreak, &shiftLeft, &cycleLeft)
                } else if driveLeft <= 0.01 || shiftLeft <= 0.01 {
                    insertReset10(&events, &clock, milesDone, &driveLeft, &shiftLeft,
                                  &hoursUntilBreak, req, &cycleLeft, &warnings)
                } else {
                    // Shouldn't happen, but break to avoid infinite loop.
                    break
                }
                continue
            }

            // Drive the segment.
            let segHours = segment / speed
            milesDone += segment
            clock = clock.addingTimeInterval(segHours * 3600)
            driveLeft -= segHours
            shiftLeft -= segHours
            cycleLeft -= segHours
            hoursUntilBreak -= segHours
            rangeLeft -= segment

            // Arrived?
            if milesDone >= totalMiles - 0.01 { break }

            // Insert whichever limit we just hit (the binding one).
            if rangeLeft <= 0.01 {
                insertFuel(&events, &clock, milesDone, &rangeLeft, req)
            } else if hoursUntilBreak <= 0.01 {
                insertBreak(&events, &clock, milesDone, &hoursUntilBreak, &shiftLeft, &cycleLeft)
            } else if driveLeft <= 0.01 || shiftLeft <= 0.01 {
                insertReset10(&events, &clock, milesDone, &driveLeft, &shiftLeft,
                              &hoursUntilBreak, req, &cycleLeft, &warnings)
            }
        }

        // Arrival event.
        events.append(TripPlanEvent(
            kind: .delivery, mileMark: totalMiles, clockTime: clock,
            detail: "Appointment \(shortTime(req.deliveryDate))"
        ))

        // Delivery-window feasibility.
        if clock > req.deliveryDate.addingTimeInterval(15 * 60) {
            let late = clock.timeIntervalSince(req.deliveryDate)
            warnings.append(TripPlanWarning(
                severity: .blocker,
                message: "With required rest, projected arrival is \(shortTime(clock)) — about \(TripTime.duration(seconds: late)) past the \(shortTime(req.deliveryDate)) appointment. Reschedule, add a team driver, or adjust the start time."
            ))
        } else if req.deliveryDate.timeIntervalSince(clock) < 60 * 60 {
            warnings.append(TripPlanWarning(
                severity: .caution,
                message: "Projected arrival \(shortTime(clock)) leaves under an hour of cushion before the appointment. Plan for traffic and detention."
            ))
        }

        if events.contains(where: { $0.kind == .reset34 }) {
            warnings.append(TripPlanWarning(
                severity: .caution,
                message: "This trip needs a 34-hour restart. Confirm a safe place to park for the full restart before you commit."
            ))
        }

        return TripPlan(
            pickupName: req.pickupName.isEmpty ? "Pickup" : req.pickupName,
            deliveryName: req.deliveryName.isEmpty ? "Delivery" : req.deliveryName,
            pickupDate: req.pickupDate,
            deliveryDate: req.deliveryDate,
            distanceMiles: totalMiles,
            totalDriveHours: totalDriveHours,
            projectedArrival: clock,
            events: events,
            warnings: warnings
        )
    }

    // MARK: Event inserters

    private static func insertFuel(_ events: inout [TripPlanEvent], _ clock: inout Date,
                                   _ mile: Double, _ rangeLeft: inout Double, _ req: TripPlanRequest) {
        events.append(TripPlanEvent(
            kind: .fuelStop, mileMark: mile, clockTime: clock,
            detail: "Refuel here — next ~\(Int(req.fuel.milesPerTank.rounded())) mi of range. Search truck stops near this mile in the Parking & Fuel map."
        ))
        clock = clock.addingTimeInterval(fuelStopHours * 3600)
        rangeLeft = req.fuel.milesPerTank
    }

    private static func insertBreak(_ events: inout [TripPlanEvent], _ clock: inout Date,
                                    _ mile: Double, _ hoursUntilBreak: inout Double,
                                    _ shiftLeft: inout Double, _ cycleLeft: inout Double) {
        events.append(TripPlanEvent(
            kind: .break30, mileMark: mile, clockTime: clock,
            detail: "Required 30-minute break before 8 hours of driving."
        ))
        clock = clock.addingTimeInterval(break30Hours * 3600)
        // The 30-min break burns the 14-hr window but not driving time.
        shiftLeft = max(0, shiftLeft - break30Hours)
        cycleLeft = max(0, cycleLeft - break30Hours)
        hoursUntilBreak = 8
    }

    private static func insertReset10(_ events: inout [TripPlanEvent], _ clock: inout Date,
                                      _ mile: Double, _ driveLeft: inout Double, _ shiftLeft: inout Double,
                                      _ hoursUntilBreak: inout Double, _ req: TripPlanRequest,
                                      _ cycleLeft: inout Double, _ warnings: inout [TripPlanWarning]) {
        // If the 60/70 cycle is also gone, a 10-hour reset won't restore driving
        // time — escalate to a 34-hour restart.
        if cycleLeft <= 0.5 {
            events.append(TripPlanEvent(
                kind: .reset34, mileMark: mile, clockTime: clock,
                detail: "Cycle hours exhausted — a 34-hour restart is required before driving can continue."
            ))
            clock = clock.addingTimeInterval(reset34Hours * 3600)
            cycleLeft = req.hos.cycleTimeLeftHours > 0 ? max(60, req.hos.cycleTimeLeftHours) : 70
        } else {
            events.append(TripPlanEvent(
                kind: .reset10, mileMark: mile, clockTime: clock,
                detail: "Daily driving/shift clock used up — take a 10-hour reset, then continue."
            ))
            clock = clock.addingTimeInterval(reset10Hours * 3600)
        }
        driveLeft = 11
        shiftLeft = 14
        hoursUntilBreak = 8
    }

    private static func shortTime(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE h:mm a"
        return df.string(from: date)
    }
}

// MARK: - Saved trip plan store

@MainActor
final class TripPlanStore: ObservableObject {
    static let shared = TripPlanStore()

    @Published private(set) var saved: [TripPlan] = []

    private let key = "sph.tripPlans.v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func save(_ plan: TripPlan) {
        saved.insert(plan, at: 0)
        persist()
    }

    func delete(_ plan: TripPlan) {
        saved.removeAll { $0.id == plan.id }
        persist()
    }

    private func persist() {
        if let data = try? encoder.encode(saved) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? decoder.decode([TripPlan].self, from: data) else { return }
        saved = decoded
    }
}

// =============================================================================
// MARK: - TripRouteService (route-corridor stop recommendations)
// -----------------------------------------------------------------------------
// Turns the planner's distance-based mile marks into REAL, route-aware stop
// suggestions. The engine already decides WHEN to fuel / break / rest (by mile);
// this service decides WHERE, by walking the actual driving polyline to each
// mile mark and searching truck stops in a tight corridor around that point —
// preferring the driver's chosen brands. No new SDK or API key (pure MapKit).
// =============================================================================
enum TripRouteService {

    struct StopSuggestion: Equatable {
        let name: String
        let brand: String?
        let latitude: Double
        let longitude: Double
    }

    /// Flatten an MKRoute polyline into coordinates for interpolation.
    static func coordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }

    /// Interpolate the coordinate at `targetMile` miles along the route.
    static func coordinate(atMile targetMile: Double, along route: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard route.count > 1 else { return route.first }
        if targetMile <= 0 { return route.first }
        let targetMeters = targetMile * 1609.344
        var acc = 0.0
        for i in 1..<route.count {
            let a = CLLocation(latitude: route[i - 1].latitude, longitude: route[i - 1].longitude)
            let b = CLLocation(latitude: route[i].latitude, longitude: route[i].longitude)
            let seg = b.distance(from: a)
            if acc + seg >= targetMeters {
                let t = seg > 0 ? (targetMeters - acc) / seg : 0
                let lat = route[i - 1].latitude + (route[i].latitude - route[i - 1].latitude) * t
                let lon = route[i - 1].longitude + (route[i].longitude - route[i - 1].longitude) * t
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            acc += seg
        }
        return route.last
    }

    /// Find one good stop near `coord`, preferring chosen brands, within the
    /// route corridor. `category` selects the search query (fuel vs truck stop).
    static func recommendStop(near coord: CLLocationCoordinate2D,
                              category: SacredPathCategory,
                              preferredBrands: Set<TruckStopBrand>,
                              corridorMiles: Double = 6) async -> StopSuggestion? {
        guard CLLocationCoordinate2DIsValid(coord) else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = category.searchQueries.first ?? "truck stop"
        request.region = MKCoordinateRegion(center: coord,
                                            latitudinalMeters: 28_000,
                                            longitudinalMeters: 28_000)
        request.resultTypes = .pointOfInterest
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }

        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let corridorMeters = corridorMiles * 1609.344

        let candidates: [(name: String, brand: TruckStopBrand?, coord: CLLocationCoordinate2D, dist: Double)] =
            response.mapItems.compactMap { item in
                guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { return nil }
                let c = item.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(c) else { return nil }
                let d = here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                guard d <= corridorMeters else { return nil }
                return (name, TruckStopBrand.detect(from: name), c, d)
            }
        guard !candidates.isEmpty else { return nil }

        // Prefer a chosen brand when one is in range; otherwise take the nearest.
        let preferred = candidates.filter { c in
            guard let b = c.brand else { return false }
            return preferredBrands.contains(b)
        }
        guard let pick = (preferred.isEmpty ? candidates : preferred).min(by: { $0.dist < $1.dist }) else { return nil }
        return StopSuggestion(name: pick.name, brand: pick.brand?.label,
                              latitude: pick.coord.latitude, longitude: pick.coord.longitude)
    }

    /// Populate fuel / break / rest events with a concrete recommended stop
    /// along the actual route. Returns a new plan; leaves events untouched when
    /// no suitable stop is found.
    static func enrich(_ plan: TripPlan,
                       along route: [CLLocationCoordinate2D],
                       preferredBrands: Set<TruckStopBrand>) async -> TripPlan {
        guard route.count > 1 else { return plan }
        var updated = plan
        for i in updated.events.indices {
            let category: SacredPathCategory?
            switch updated.events[i].kind {
            case .fuelStop:            category = .fuel
            case .break30:             category = .truckStops
            case .reset10, .reset34:   category = .truckStops   // overnight parking
            case .start, .delivery:    category = nil
            }
            guard let category,
                  let coord = coordinate(atMile: updated.events[i].mileMark, along: route),
                  let s = await recommendStop(near: coord, category: category, preferredBrands: preferredBrands)
            else { continue }
            updated.events[i].recommendedStopName = s.name
            updated.events[i].recommendedStopBrand = s.brand
            updated.events[i].recommendedLatitude = s.latitude
            updated.events[i].recommendedLongitude = s.longitude
        }
        return updated
    }
}
