import Foundation
import SwiftUI
import MapKit
import CoreLocation
import UIKit
import AVFoundation

// =============================================================================
// MARK: - Sacred Path support (GPS-free)
// -----------------------------------------------------------------------------
// Driver Hub's Sacred Path is a TRUCKING-RESOURCE LOCATOR, TRIP-PLANNING, and
// in-app truck navigation tool. It helps drivers find truck stops, rest areas,
// fuel, parking, scales, and repairs, then keeps navigation inside Driver Hub.
//
// This file (formerly the in-app turn-by-turn navigation engine) now holds only
// the shared, GPS-free building blocks the rest of the feature depends on:
//   * SacredPathDestination   — a resolved place (name + coordinate)
//   * SacredPathFormat        — distance / duration / clock formatting
//   * SacredPathExternalMaps  — deprecated compatibility shim; no external open
//   * OpenInMapsMenu / OpenInMapsButtons — reusable in-app navigation UI
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

// MARK: - Reusable in-app navigation UI

/// Compact in-app navigation action for a single stop. Use inside list rows.
struct OpenInMapsMenu: View {
    let name: String
    let latitude: Double
    let longitude: Double
    var label: String = "Get Directions"

    var body: some View {
        NavigationLink {
            SacredPathNavigationModeView(
                destination: SacredPathDestination(name: name, latitude: latitude, longitude: longitude),
                route: nil,
                profile: TruckProfileStore.shared.profile
            )
        } label: {
            Label(label, systemImage: "location.north.line.fill")
                .frame(maxWidth: .infinity)
        }
    }
}

/// Full-width in-app navigation button for route preview and trip planner.
struct OpenInMapsButtons: View {
    /// One or more stops. A single stop opens point-to-point directions; multiple
    /// stops open a multi-waypoint route in order.
    let stops: [SacredPathDestination]

    var body: some View {
        if !stops.isEmpty {
            NavigationLink {
                SacredPathNavigationModeView(stops: stops, route: nil, profile: TruckProfileStore.shared.profile)
            } label: {
                handoffLabel(text: stops.count == 1 ? "Start In-App Navigation" : "Start In-App Trip", system: "location.north.line.fill")
            }
            .buttonStyle(.plain)
        }
    }

    private func handoffLabel(text: String, system: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: system)
            Text(text).font(.subheadline.weight(.bold))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .foregroundStyle(.white)
        .background(Color.spDarkGreen, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.spGold.opacity(0.5), lineWidth: 1))
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
            Text("Disclaimer: Sacred Path navigation and bid guidance are planning aids. Always follow posted signs, legal truck routes, broker terms, weather alerts, and your own professional judgment.")
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(Color.spTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


// =============================================================================
// MARK: - Sacred Path Navigation Engine (in-app turn-by-turn truck GPS)
// Restored from history. Drives heading-up navigation, voice prompts, off-route
// reroute, posted speed limits, and live truck-service intelligence.
// =============================================================================

@MainActor
final class SacredPathNavigationEngine: NSObject, ObservableObject {

    // Inputs — ordered trip stops (single-destination is a one-element trip).
    private(set) var stops: [SacredPathDestination]
    @Published private(set) var currentStopIndex = 0
    var profile: SacredPathTruckProfile

    /// The stop currently being navigated to. Bounds-safe: never subscripts an
    /// empty array or an out-of-range index (the per-fix `consume` path reads
    /// this on every GPS update).
    var destination: SacredPathDestination {
        guard !stops.isEmpty else {
            return SacredPathDestination(name: "Destination", latitude: 0, longitude: 0)
        }
        return stops[min(max(0, currentStopIndex), stops.count - 1)]
    }
    var stopsCount: Int { stops.count }
    var isMultiStop: Bool { stops.count > 1 }
    var nextStopName: String? { currentStopIndex + 1 < stops.count ? stops[currentStopIndex + 1].name : nil }
    var stopProgressText: String { "Stop \(min(currentStopIndex + 1, stops.count)) of \(stops.count)" }

    // Route + guidance state
    @Published private(set) var route: SacredPathNavigationRoute?
    @Published private(set) var remainingRouteCoordinates: [CLLocationCoordinate2D] = []
    @Published private(set) var traveledRouteCoordinates: [CLLocationCoordinate2D] = []
    @Published private(set) var currentStepIndex = 0
    @Published private(set) var maneuverSymbol = "location.north.line.fill"
    @Published private(set) var primaryInstruction = "Starting navigation…"
    @Published private(set) var secondaryInstruction: String?
    @Published private(set) var currentRoadName = ""
    @Published private(set) var distanceToManeuverText = "—"

    // Live trip metrics
    @Published private(set) var speedMph = 0
    @Published private(set) var remainingMiles = 0.0
    @Published private(set) var remainingTimeText = "—"
    @Published private(set) var etaText = "—"
    @Published private(set) var postedSpeedLimitMph: Int?
    @Published private(set) var routeProviderName = "Routing"
    @Published private(set) var routeLimitations: [String] = []

    // Heading + live coordinate (for a course-up truck puck) + debug telemetry
    @Published private(set) var currentCoordinate: CLLocationCoordinate2D?
    @Published private(set) var displayHeadingDeg: Double = 0
    @Published private(set) var truckRotationDeg: Double = 0
    @Published private(set) var debugCourse: Double = -1
    @Published private(set) var debugCameraHeadingDeg: Double = 0
    @Published private(set) var debugAccuracy: Double = -1
    @Published private(set) var lastRerouteReason = "—"

    // Status
    @Published private(set) var isRerouting = false
    @Published private(set) var arrived = false
    #if DEBUG
    @Published private(set) var isSimulationRunning = false
    #endif

    // Intelligence
    @Published private(set) var restrictions: [TruckRouteRestriction] = []
    @Published private(set) var upcomingPOIs: [SacredPathUpcomingPOI] = []

    // Camera + prefs
    @Published var cameraZoom: Double = 1.0
    @Published var followMode = true
    /// Bumped each time the driver taps Route Overview, so the UIKit map can
    /// frame the whole route once (follow stays off until Recenter).
    @Published private(set) var overviewRequestID = 0
    @Published var weatherLayerOn = false
    @Published var voiceEnabled = true {
        didSet { if !voiceEnabled { synthesizer.stopSpeaking(at: .immediate) } }
    }

    // Dependencies
    nonisolated(unsafe) private let locationManager = CLLocationManager()
    private let synthesizer = AVSpeechSynthesizer()
    private let routingService = SacredPathTruckRoutingService()
    private let speedLimitProvider: PostedSpeedLimitProvider = DefaultPostedSpeedLimitProvider()

    // Working state
    private var steps: [SacredPathNavigationStep] = []
    private var maneuverCoordinates: [CLLocationCoordinate2D] = []
    private var stepDistances: [CLLocationDistance] = []
    private var routeCoordinates: [CLLocationCoordinate2D] = []
    private var routeProgressIndex = 0
    private var routeTotalDistance: CLLocationDistance = 1
    private var routeExpectedTime: TimeInterval = 0
    private var spokenPrompts: Set<String> = []
    private var lastPOISearchLocation: CLLocation?
    private var isSearchingPOIs = false

    // Heading smoothing (course-based, low-pass)
    private var smoothedHeading: Double = 0
    private var hasHeading = false

    // Display coordinate (snapped to the route when close) for camera + puck.
    private var targetCoordinate: CLLocationCoordinate2D?
    #if DEBUG
    private var simulationTask: Task<Void, Never>?
    #endif

    // Multi-stop arrival de-dupe (one advance per stop)
    private var handledStops: Set<Int> = []

    // Off-route hysteresis
    private var offRouteSince: Date?
    private var lastOffRouteDistance: CLLocationDistance = 0
    private var lastRerouteAt: Date = .distantPast
    private let offRouteDistanceThreshold: CLLocationDistance = 130
    private let offRoutePersistenceSeconds: TimeInterval = 10
    private let rerouteCooldownSeconds: TimeInterval = 25
    private let rerouteAccuracyCeiling: CLLocationDistance = 45
    private var offRouteBadFixCount = 0

    init(destination: SacredPathDestination,
         route: SacredPathNavigationRoute?,
         profile: SacredPathTruckProfile = .defaultOwnerOperator) {
        self.stops = [destination]
        self.profile = profile
        super.init()
        configureLocationManager()
        configureAudioSession()
        if let route { ingest(route: route) }
    }

    init(stops: [SacredPathDestination],
         route: SacredPathNavigationRoute?,
         profile: SacredPathTruckProfile = .defaultOwnerOperator) {
        self.stops = stops.isEmpty
            ? [SacredPathDestination(name: "Destination", latitude: 0, longitude: 0)]
            : stops
        self.profile = profile
        super.init()
        configureLocationManager()
        configureAudioSession()
        if let route { ingest(route: route) }
    }

    // MARK: Lifecycle

    func start() {
        // Background navigation runs ONLY while active navigation is on. Enabled
        // here, torn down in stop(). Isolated to this engine's own manager so
        // Weather / Near Me / Rate Map (shared LocationManager) are unaffected.
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        // When-In-Use covers foreground maps; escalate to Always at the moment a
        // live trip starts so guidance + voice keep running in the background.
        if locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
        locationManager.startUpdatingLocation()
        startGPSWatchdog()
        if route == nil, let coordinate = locationManager.location?.coordinate {
            Task { await recalculateRoute(from: coordinate) }
        }
        if voiceEnabled {
            speak("Sacred Path navigation started.", key: "start")
        }
    }

    /// Immediately re-sync to the latest fix when the app returns to foreground.
    func resyncOnResume() {
        if let location = locationManager.location {
            consume(location)
        }
    }

    // MARK: Map controls (safe local actions)

    func recenter() {
        cameraZoom = 1.0
        followMode = true
    }

    func zoomIn() {
        cameraZoom = max(0.5, cameraZoom * 0.8)
    }

    func zoomOut() {
        cameraZoom = min(2.5, cameraZoom * 1.25)
    }

    func toggleWeatherLayer() {
        weatherLayerOn.toggle()
    }

    /// Frames the whole route; pauses follow until the driver recenters.
    func routeOverview() {
        followMode = false
        overviewRequestID += 1
    }

    /// Sacred Path AI: manual reroute from the live position.
    func requestReroute() {
        let now = Date()
        guard !isRerouting else {
            #if DEBUG
            print("[SacredPath][REROUTE] manual request ignored: already rerouting")
            #endif
            return
        }
        guard now.timeIntervalSince(lastRerouteAt) >= rerouteCooldownSeconds else {
            #if DEBUG
            print("[SacredPath][REROUTE] manual request ignored: cooldown active")
            #endif
            return
        }
        if let coordinate = locationManager.location?.coordinate {
            lastRerouteAt = now
            Task { await recalculateRoute(from: coordinate) }
        }
    }

    func nearestPOI(_ kind: SacredPathPOIKind) -> SacredPathUpcomingPOI? {
        upcomingPOIs.first { $0.kind == kind }
    }

    func stop() {
        // Tear down background tracking the instant navigation ends — battery and
        // App Store safety. Background location never runs outside active nav.
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.stopUpdatingLocation()
        gpsWatchdogTask?.cancel()
        gpsWatchdogTask = nil
        #if DEBUG
        stopSimulation()
        #endif
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    #if DEBUG
    func toggleRouteSimulation(offRoute: Bool = false) {
        if isSimulationRunning {
            stopSimulation()
        } else {
            startSimulation(offRoute: offRoute)
        }
    }

    private func startSimulation(offRoute: Bool) {
        guard routeCoordinates.count >= 2 else {
            if let origin = locationManager.location?.coordinate ?? currentCoordinate {
                Task { await recalculateRoute(from: origin) }
            }
            return
        }
        isSimulationRunning = true
        simulationTask?.cancel()
        let coords = routeCoordinates
        simulationTask = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                await MainActor.run {
                    guard let self else { return }
                    let base = coords[min(index, coords.count - 1)]
                    let next = coords[min(index + 1, coords.count - 1)]
                    let bearing = Self.bearing(from: base, to: next)
                    let coordinate = offRoute && index > max(8, coords.count / 4)
                        ? Self.project(base, distanceMeters: 330, bearing: bearing + 90)
                        : base
                    let simulated = CLLocation(
                        coordinate: coordinate,
                        altitude: 0,
                        horizontalAccuracy: 8,
                        verticalAccuracy: 8,
                        course: bearing,
                        speed: 24.6,
                        timestamp: Date()
                    )
                    self.consume(simulated)
                }
                index = min(index + 1, coords.count - 1)
                if index >= coords.count - 1 { break }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            await MainActor.run {
                self?.isSimulationRunning = false
            }
        }
    }

    private func stopSimulation() {
        simulationTask?.cancel()
        simulationTask = nil
        isSimulationRunning = false
    }
    #endif

    deinit {
        // Belt-and-suspenders teardown: if this engine is released without an
        // explicit stop() (view torn down mid-trip, force-quit, etc.) make sure
        // background location + heading updates never keep running. nonisolated
        // deinit only touches the CLLocationManager, which is thread-safe here.
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        locationManager.delegate = nil
    }

    // MARK: Configuration

    private func configureLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        // No distance filter: turn-by-turn wants every fix at the natural ~1 Hz
        // hardware rate. Uniform fix intervals matter — the map follow animation
        // glides across one interval, so suppressing fixes would make the glide
        // timing uneven. (Smoothness is handled by the follow animation, not by
        // throttling fixes.)
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.requestWhenInUseAuthorization()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback,
            mode: .voicePrompt,
            options: [.duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]
        )
    }

    // MARK: Route ingestion

    private func ingest(route: SacredPathNavigationRoute) {
        self.route = route
        self.steps = route.steps
        self.routeExpectedTime = route.expectedTravelTime
        self.routeTotalDistance = max(1, route.distance)
        self.routeCoordinates = route.coordinates
        self.routeProgressIndex = 0
        self.remainingRouteCoordinates = route.coordinates
        self.traveledRouteCoordinates = []
        self.routeProviderName = route.providerName
        SacredPathMapDiagnosticsStore.shared.routingProviderName = route.providerName
        self.routeLimitations = route.limitations
        // Force the clip-gap overlays to rebuild against the new route.
        self.lastRemainStart = -1
        self.lastTraveledEnd = -1
        self.stepDistances = route.steps.map { $0.distance }
        self.maneuverCoordinates = route.steps.map(\.coordinate)
        self.currentStepIndex = 0
        self.spokenPrompts.removeAll()
        self.remainingMiles = route.distance / 1609.344
        self.remainingTimeText = Self.formatDuration(route.expectedTravelTime)
        self.etaText = Self.formatClock(Date().addingTimeInterval(route.expectedTravelTime))
        updateBannerForCurrentStep()
    }

    // MARK: Per-fix update

    /// Last fix actually processed — for "distance moved" telemetry.
    private var lastConsumedLocation: CLLocation?
    private var lastLocationUpdateAt: Date?
    private var gpsWatchdogTask: Task<Void, Never>?

    private func consume(_ location: CLLocation) {
        lastLocationUpdateAt = Date()
        SacredPathMapDiagnosticsStore.shared.lastGPSUpdateAt = lastLocationUpdateAt
        #if DEBUG
        let movedMeters = lastConsumedLocation.map { location.distance(from: $0) } ?? 0
        lastConsumedLocation = location
        print(String(format: "[SacredPath][GPS] received · acc=%.0fm · spd=%.1f m/s · course=%.0f° · moved=%.0fm",
                     location.horizontalAccuracy, max(0, location.speed), location.course, movedMeters))
        #endif
        speedMph = Int((max(0, location.speed) * 2.236936).rounded())
        debugCourse = location.course
        debugAccuracy = location.horizontalAccuracy

        targetCoordinate = location.coordinate
        updateHeading(from: location)
        updateRouteProgress(location)   // may snap targetCoordinate to the route
        updateCamera(location)

        guard !maneuverCoordinates.isEmpty, currentStepIndex < maneuverCoordinates.count else { return }

        // Distance to the current maneuver point (end of current step).
        let maneuver = maneuverCoordinates[currentStepIndex]
        let maneuverLocation = CLLocation(latitude: maneuver.latitude, longitude: maneuver.longitude)
        let toManeuver = location.distance(from: maneuverLocation)
        distanceToManeuverText = Self.formatDistance(toManeuver)

        // Advance to the next step once we pass the maneuver.
        if toManeuver < 25, currentStepIndex < steps.count - 1 {
            currentStepIndex += 1
            updateBannerForCurrentStep()
        }

        // Arrival / automatic advance to the next stop.
        let destinationLocation = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
        if location.distance(from: destinationLocation) < 60 {
            handleArrival(at: location)
        }

        updateProgress(toCurrentManeuver: toManeuver)
        evaluateOffRoute(location)
        maybeSpeakManeuver(distance: toManeuver)
        refreshSpeedLimit(at: location.coordinate)
        maybeRefreshPOIs(around: location)
    }

    private func startGPSWatchdog() {
        gpsWatchdogTask?.cancel()
        gpsWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    let age = self.lastLocationUpdateAt.map { Date().timeIntervalSince($0) } ?? .infinity
                    if age > 8 {
                        let text = age.isFinite ? String(format: "%.0fs", age) : "no fixes yet"
                        print("[SacredPath][GPS] warning: no location update for \(text)")
                    }
                }
            }
        }
    }

    /// Trims the route geometry to what's ahead: the traveled portion is split
    /// from the remaining portion so the map visibly shows progress as the truck
    /// moves (remaining stays bright; traveled is dimmed). Progress only moves
    /// forward (monotonic index) so GPS jitter can't rewind the line.
    private func updateRouteProgress(_ location: CLLocation) {
        guard routeCoordinates.count >= 2 else { return }
        let maxIndex = routeCoordinates.count - 1
        // Defensive clamp: a stale index from a previous (longer) route must
        // never drive an out-of-bounds subscript or an inverted Range below.
        if routeProgressIndex < 0 || routeProgressIndex > maxIndex {
            routeProgressIndex = min(max(0, routeProgressIndex), maxIndex)
        }
        let previousIndex = routeProgressIndex
        let here = location
        var bestIndex = routeProgressIndex
        var bestDistance = Double.greatestFiniteMagnitude
        let windowEnd = min(maxIndex, routeProgressIndex + 80)
        guard routeProgressIndex <= windowEnd else { return }
        for index in routeProgressIndex...windowEnd {
            let coord = routeCoordinates[index]
            let distance = here.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        routeProgressIndex = bestIndex
        _ = previousIndex
        // The remaining/traveled overlays are now built in rebuildRoutePolylines()
        // (called from updateCamera) so they can be anchored to the EXTRAPOLATED
        // puck position with a clean clip-gap — preventing the gold route from
        // bleeding through/under the truck marker.

        // Route snapping: within a lane's width of the line, drive the displayed
        // position along the route (not the jittery raw GPS point) so the truck
        // visually stays on the road and doesn't appear to wander off-route.
        if bestDistance <= 22 {
            targetCoordinate = routeCoordinates[bestIndex]
        }
    }

    /// One advance per stop: mark complete, move to the next stop, and reroute
    /// from the live position. Final stop ends navigation.
    private func handleArrival(at location: CLLocation) {
        guard !handledStops.contains(currentStopIndex) else { return }
        handledStops.insert(currentStopIndex)
        if currentStopIndex < stops.count - 1 {
            let completed = stops[currentStopIndex].name
            currentStopIndex += 1
            guard currentStopIndex < stops.count else { return }
            let next = stops[currentStopIndex].name
            arrived = false
            speak("Arrived at \(completed). Continuing to \(next).", key: "advance-\(currentStopIndex)")
            Task { await recalculateRoute(from: location.coordinate) }
        } else if !arrived {
            arrived = true
            primaryInstruction = "You have arrived"
            distanceToManeuverText = "Arrived"
            maneuverSymbol = "flag.checkered"
            secondaryInstruction = nil
            speak("You have arrived at \(destination.name).", key: "arrived-final")
        }
    }

    private func updateProgress(toCurrentManeuver toManeuver: CLLocationDistance) {
        var remaining = toManeuver
        if currentStepIndex + 1 < stepDistances.count {
            for index in (currentStepIndex + 1)..<stepDistances.count {
                remaining += stepDistances[index]
            }
        }
        remainingMiles = remaining / 1609.344
        let fraction = routeTotalDistance > 0 ? min(1.0, remaining / routeTotalDistance) : 0
        let remainingTime = routeExpectedTime * fraction
        remainingTimeText = Self.formatDuration(remainingTime)
        etaText = Self.formatClock(Date().addingTimeInterval(remainingTime))
    }

    private func updateBannerForCurrentStep() {
        guard currentStepIndex < steps.count else { return }
        let instruction = steps[currentStepIndex].instruction
        let resolved = instruction.isEmpty ? "Continue ahead" : instruction
        primaryInstruction = resolved
        maneuverSymbol = Self.maneuverSymbol(for: resolved)
        currentRoadName = Self.roadName(from: resolved)
        if currentStepIndex + 1 < steps.count {
            let next = steps[currentStepIndex + 1].instruction
            secondaryInstruction = next.isEmpty ? nil : "Then \(next)"
        } else {
            secondaryInstruction = "Then arrive at \(destination.name)"
        }
    }

    // MARK: Off-route + reroute

    /// Reroute only on a real departure: far enough off, for long enough, moving
    /// AWAY from the line, with a good fix, and outside the cooldown window.
    private func evaluateOffRoute(_ location: CLLocation) {
        guard !routeCoordinates.isEmpty, !isRerouting else { return }

        // Never reroute on a poor fix — GPS jitter is the #1 false trigger.
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= rerouteAccuracyCeiling else {
            offRouteSince = nil
            offRouteBadFixCount = 0
            lastRerouteReason = "ignored poor GPS"
            return
        }

        let distance = Self.minDistance(from: location.coordinate, to: routeCoordinates)
        let speed = max(0, location.speed)
        #if DEBUG
        print(String(format: "[SacredPath][OFFROUTE] dist=%.0fm acc=%.0fm speed=%.1fm/s bad=%d", distance, location.horizontalAccuracy, speed, offRouteBadFixCount))
        #endif

        // Still on (or near) the route — clear any pending off-route timer.
        if distance <= offRouteDistanceThreshold {
            offRouteSince = nil
            offRouteBadFixCount = 0
            lastOffRouteDistance = distance
            return
        }

        // Warehouse lots, truck stops, exit ramps, and traffic lights often put
        // the fix off the route while the truck is stopped or creeping. Wait for
        // confident movement before treating this as a true departure.
        if speed < 1.5 && distance < 250 {
            offRouteSince = nil
            offRouteBadFixCount = 0
            lastOffRouteDistance = distance
            lastRerouteReason = "holding while stopped"
            return
        }

        let routeBearing = Self.routeBearing(at: routeProgressIndex, coordinates: routeCoordinates)
        let headingMismatch: Bool
        if location.course >= 0, speed >= 4.0, let routeBearing {
            headingMismatch = Self.angleDifference(location.course, routeBearing) > 70
        } else {
            headingMismatch = false
        }

        // If the truck is only moderately outside the line and still pointed
        // with the route, treat it as GPS lag/snap error instead of a miss.
        if distance < 220 && !headingMismatch {
            offRouteSince = nil
            offRouteBadFixCount = 0
            lastOffRouteDistance = distance
            lastRerouteReason = String(format: "held %.0fm off but aligned", distance)
            return
        }

        let now = Date()
        if offRouteSince == nil {
            offRouteSince = now
            lastOffRouteDistance = distance
            offRouteBadFixCount = 1
            return
        }

        guard let offRouteStart = offRouteSince else { return }
        let movingAway = distance > lastOffRouteDistance + 4
        lastOffRouteDistance = distance
        offRouteBadFixCount += 1
        let persisted = now.timeIntervalSince(offRouteStart) >= offRoutePersistenceSeconds
        let cooldownClear = now.timeIntervalSince(lastRerouteAt) >= rerouteCooldownSeconds

        guard persisted, offRouteBadFixCount >= 4, (movingAway || headingMismatch), cooldownClear else { return }

        lastRerouteAt = now
        lastRerouteReason = String(
            format: "%.0fm off for %.0fs, moving away",
            distance, now.timeIntervalSince(offRouteStart)
        )
        print("[SacredPath] Reroute triggered — \(lastRerouteReason)")
        Task { await recalculateRoute(from: location.coordinate) }
    }

    private func recalculateRoute(from coordinate: CLLocationCoordinate2D) async {
        guard !isRerouting else { return }
        isRerouting = true
        print("[SacredPath][REROUTE] start provider route from \(coordinate.latitude),\(coordinate.longitude) to \(destination.latitude),\(destination.longitude)")
        if voiceEnabled { speak("Rerouting.", key: "reroute-\(Int(Date().timeIntervalSince1970))") }
        do {
            if let newRoute = try await routingService.calculateRoute(
                from: coordinate, to: destination.coordinate, profile: profile
            ) {
                ingest(route: newRoute)
                restrictions = await routingService.restrictionProvider.restrictions(along: newRoute, profile: profile)
                print("[SacredPath][REROUTE] finish provider=\(newRoute.providerName) distance=\(Int(newRoute.distance))m")
            }
        } catch {
            // Keep the existing route on failure.
            SacredPathMapDiagnosticsStore.shared.lastRouteError = error.localizedDescription
            print("[SacredPath][REROUTE] provider error: \(error.localizedDescription)")
        }
        offRouteSince = nil
        offRouteBadFixCount = 0
        isRerouting = false
    }

    // MARK: Voice

    private func maybeSpeakManeuver(distance: CLLocationDistance) {
        guard voiceEnabled, currentStepIndex < steps.count else { return }
        let instruction = steps[currentStepIndex].instruction
        guard !instruction.isEmpty else { return }

        let far = "s\(currentStepIndex)-2mi"
        let near = "s\(currentStepIndex)-1000ft"
        let now = "s\(currentStepIndex)-now"

        if distance <= 3218, distance > 800, !spokenPrompts.contains(far) {
            spokenPrompts.insert(far)
            speak("In 2 miles, \(instruction).", key: far)
        } else if distance <= 305, distance > 60, !spokenPrompts.contains(near) {
            spokenPrompts.insert(near)
            speak("In one thousand feet, \(instruction).", key: near)
        } else if distance <= 60, !spokenPrompts.contains(now) {
            spokenPrompts.insert(now)
            speak("\(instruction) now.", key: now)
        }
    }

    private func speak(_ text: String, key: String) {
        guard voiceEnabled else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.preUtteranceDelay = 0.05
        synthesizer.speak(utterance)
    }

    // MARK: Posted speed limit (provider seam)

    private func refreshSpeedLimit(at coordinate: CLLocationCoordinate2D) {
        Task {
            let limit = await speedLimitProvider.speedLimitMph(at: coordinate)
            if limit != postedSpeedLimitMph { postedSpeedLimitMph = limit }
        }
    }

    // MARK: Camera (heading-up, pitched, speed-zoomed, truck in lower third)

    /// Heading comes from GPS course ONLY when the fix is trustworthy and the
    /// truck is actually moving; otherwise we hold the last heading so the puck
    /// never spins or flips while stopped, creeping, or on a noisy fix.
    private func updateHeading(from location: CLLocation) {
        guard location.course >= 0,
              location.speed >= 2.0,                 // ~4.5 mph
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 30 else { return }
        let target = location.course
        if !hasHeading {
            smoothedHeading = target
            hasHeading = true
        } else {
            var delta = target - smoothedHeading
            while delta > 180 { delta -= 360 }
            while delta < -180 { delta += 360 }
            smoothedHeading = Self.normalizeAngle(smoothedHeading + delta * 0.25)
        }
        displayHeadingDeg = smoothedHeading
    }

    /// One camera update per GPS fix, animated over ~1s so it glides smoothly
    /// between the ~1Hz fixes — SwiftUI interpolates the camera, with none of
    /// the memory cost of per-frame Map updates. Heading is low-pass smoothed.
    private func updateCamera(_ location: CLLocation) {
        guard let coordinate = targetCoordinate, CLLocationCoordinate2DIsValid(coordinate) else { return }
        let heading = hasHeading ? smoothedHeading : (location.course >= 0 ? location.course : 0)
        displayHeadingDeg = heading
        debugCameraHeadingDeg = heading
        // Map is course-up; billboarded puck points screen-up == travel.
        truckRotationDeg = 0

        let mps = max(0, location.speed)
        // FORWARD EXTRAPOLATION (kills the "lagging behind" trail): a fix is ~1 s
        // old by the time it's processed, and the puck then animates toward it
        // over ~1 s — so at speed the puck sits ~2 fix-intervals (~90–180 ft)
        // behind the truck. Project the displayed position one fix-interval ahead
        // along the heading so the puck shows where the truck IS NOW. Capped and
        // disabled below ~4.5 mph so it never overshoots a stop or a turn.
        let leadMeters = min(140, mps * 1.0)
        let displayCoordinate = mps >= 2.0
            ? Self.project(coordinate, distanceMeters: leadMeters, bearing: heading)
            : coordinate
        currentCoordinate = displayCoordinate

        // Re-anchor the route overlays to the puck with a clean clip-gap so no
        // gold renders under/through the truck marker.
        rebuildRoutePolylines(anchor: displayCoordinate, heading: heading)

        // In route-overview the camera is frozen on the whole route until recenter.
        guard followMode else { return }
        let baseDistance = min(2600, max(620, 600 + mps * 55))
        let distance = min(6000, max(400, baseDistance * cameraZoom))
        #if DEBUG
        print(String(format: "[SacredPath][CAM] follow · heading=%.0f° · lead=%.0fm · camDist=%.0fm · spd=%d mph",
                     heading, leadMeters, distance, speedMph))
        #endif
    }

    // MARK: Route overlays (clean clip-gap around the truck marker)

    /// Distance (m) kept clear of route line on each side of the truck puck so
    /// the gold route never bleeds through / under the circular marker.
    private let routeClipRadius: CLLocationDistance = 30
    private var lastRemainStart = -1
    private var lastTraveledEnd = -1

    /// Rebuilds the bright "remaining" (ahead) and dim "traveled" (behind) route
    /// overlays so they start/stop a clip-radius away from the truck puck.
    /// The route is anchored to the EXTRAPOLATED puck — not the raw GPS, which
    /// now trails the puck — so no route segment renders inside the marker. The
    /// big "remaining" polyline is only rebuilt when the puck crosses a new
    /// clip boundary (a vertex), never per-fix, so long routes stay smooth.
    private func rebuildRoutePolylines(anchor: CLLocationCoordinate2D, heading: Double) {
        guard routeCoordinates.count >= 2 else {
            remainingRouteCoordinates = []
            traveledRouteCoordinates = []
            return
        }
        let maxIndex = routeCoordinates.count - 1
        let pivot = min(max(0, routeProgressIndex), maxIndex)
        let puck = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)

        // REMAINING (bright, ahead): first route vertex that is > clip ahead of
        // the puck. Everything between the puck and that vertex stays clear.
        var start = pivot
        while start < maxIndex,
              puck.distance(from: CLLocation(latitude: routeCoordinates[start].latitude,
                                             longitude: routeCoordinates[start].longitude)) < routeClipRadius {
            start += 1
        }
        if start != lastRemainStart || remainingRouteCoordinates.isEmpty {
            lastRemainStart = start
            let coords = Array(routeCoordinates[start...])
            remainingRouteCoordinates = coords.count >= 2 ? coords : []
        }

        // TRAVELED (dim, behind): last route vertex that is > clip behind the puck.
        var end = pivot
        while end > 0,
              puck.distance(from: CLLocation(latitude: routeCoordinates[end].latitude,
                                             longitude: routeCoordinates[end].longitude)) < routeClipRadius {
            end -= 1
        }
        if end != lastTraveledEnd || traveledRouteCoordinates.isEmpty {
            lastTraveledEnd = end
            let coords = Array(routeCoordinates[0...end])
            traveledRouteCoordinates = coords.count >= 2 ? coords : []
        }
    }

    // MARK: Upcoming intelligence (truck services + weather)

    private func maybeRefreshPOIs(around location: CLLocation) {
        if let last = lastPOISearchLocation, location.distance(from: last) < 4800 { return }
        guard !isSearchingPOIs else { return }
        lastPOISearchLocation = location
        Task { await refreshUpcomingPOIs(around: location) }
    }

    private func refreshUpcomingPOIs(around location: CLLocation) async {
        isSearchingPOIs = true
        var found: [SacredPathUpcomingPOI] = []

        let kinds: [SacredPathPOIKind] = [.fuel, .parking, .restArea, .scales, .service]
        let region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000)

        for kind in kinds {
            guard let query = kind.searchQueries.first else { continue }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = region
            request.resultTypes = .pointOfInterest
            if let response = try? await MKLocalSearch(request: request).start() {
                let nearest = response.mapItems
                    .compactMap { item -> SacredPathUpcomingPOI? in
                        let coord = item.placemark.coordinate
                        guard CLLocationCoordinate2DIsValid(coord), let name = item.name else { return nil }
                        let miles = location.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude)) / 1609.344
                        return SacredPathUpcomingPOI(
                            kind: kind,
                            name: name,
                            detail: item.placemark.locality ?? "",
                            latitude: coord.latitude,
                            longitude: coord.longitude,
                            distanceMiles: miles
                        )
                    }
                    .sorted { $0.distanceMiles < $1.distanceMiles }
                    .first
                if let nearest { found.append(nearest) }
            }
        }

        // Inject an active severe-weather alert as a high-priority card.
        if let alert = ForecastService.shared.activeSevereAlerts.first {
            found.insert(
                SacredPathUpcomingPOI(
                    kind: .weather,
                    name: alert.event,
                    detail: "On your route",
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    distanceMiles: -1
                ),
                at: 0
            )
        }

        upcomingPOIs = found
        isSearchingPOIs = false
    }

    // MARK: - Static helpers

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

    static func maneuverSymbol(for instruction: String) -> String {
        let text = instruction.lowercased()
        if text.contains("arrive") || text.contains("arrived") { return "flag.checkered" }
        if text.contains("u-turn") || text.contains("u turn") { return "arrow.uturn.down" }
        if text.contains("keep left") || text.contains("bear left") { return "arrow.up.left" }
        if text.contains("keep right") || text.contains("bear right") { return "arrow.up.right" }
        if text.contains("slight left") { return "arrow.up.left" }
        if text.contains("slight right") { return "arrow.up.right" }
        if text.contains("exit") { return "arrow.up.right.circle.fill" }
        if text.contains("merge") { return "arrow.merge" }
        if text.contains("roundabout") || text.contains("rotary") { return "arrow.triangle.2.circlepath" }
        if text.contains("left") { return "arrow.turn.up.left" }
        if text.contains("right") { return "arrow.turn.up.right" }
        if text.contains("continue") || text.contains("head") || text.contains("straight") { return "arrow.up" }
        return "location.north.line.fill"
    }

    static func roadName(from instruction: String) -> String {
        // Provider step text often reads like "Turn right onto US-82 E". Pull the road.
        if let range = instruction.range(of: " onto ") {
            return String(instruction[range.upperBound...])
        }
        if let range = instruction.range(of: " on ") {
            return String(instruction[range.upperBound...])
        }
        return ""
    }

    static func minDistance(from coordinate: CLLocationCoordinate2D, to coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var minimum = CLLocationDistance.greatestFiniteMagnitude
        for coord in coordinates {
            let distance = here.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            if distance < minimum { minimum = distance }
        }
        return minimum
    }

    static func normalizeAngle(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let diff = abs(normalizeAngle(a) - normalizeAngle(b))
        return min(diff, 360 - diff)
    }

    static func routeBearing(at index: Int, coordinates: [CLLocationCoordinate2D]) -> CLLocationDirection? {
        guard coordinates.count >= 2 else { return nil }
        let startIndex = min(max(0, index), coordinates.count - 2)
        let endIndex = min(coordinates.count - 1, startIndex + 1)
        return bearing(from: coordinates[startIndex], to: coordinates[endIndex])
    }

    static func bearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let deltaLon = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        return normalizeAngle(atan2(y, x) * 180 / .pi)
    }

    static func project(_ coordinate: CLLocationCoordinate2D, distanceMeters: CLLocationDistance, bearing: CLLocationDirection) -> CLLocationCoordinate2D {
        let earthRadius = 6_371_000.0
        let bearingRad = bearing * .pi / 180
        let lat1 = coordinate.latitude * .pi / 180
        let lon1 = coordinate.longitude * .pi / 180
        let angular = distanceMeters / earthRadius
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearingRad))
        let lon2 = lon1 + atan2(sin(bearingRad) * sin(angular) * cos(lat1),
                                cos(angular) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }
}

// MARK: - CLLocationManagerDelegate

extension SacredPathNavigationEngine: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // Drop only clearly-bad fixes (negative/huge accuracy). 100 m ceiling is
        // generous so the truck keeps following through brief GPS degradation
        // (tunnels, urban canyons) instead of appearing to "stop updating".
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 100 else { return }
        // Staleness window widened 2s → 5s: at the previous 2s a single delayed
        // fix (common right after movement resumes) was discarded, which read as
        // "updates stopped after I started moving".
        guard abs(location.timestamp.timeIntervalSinceNow) < 5.0 else { return }
        Task { @MainActor in self.consume(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        MainActor.assumeIsolated {
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.locationManager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Non-fatal; keep last route + last position.
    }
}
