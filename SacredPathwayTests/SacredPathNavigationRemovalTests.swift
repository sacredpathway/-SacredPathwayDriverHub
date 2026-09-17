import XCTest
import CoreLocation
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif

// =============================================================================
//  SacredPathNavigationRemovalTests (2026-09-17)
// -----------------------------------------------------------------------------
//  In-app Sacred Path turn-by-turn navigation was removed. These tests prove:
//    * the app asks for When-In-Use location only (no Always, no background
//      location or audio mode, no navigation-only keys);
//    * Maps, Near Me cards, current location, Sacred Path search and trip
//      planning are still in the app;
//    * no navigation engine, voice guidance, or "start navigation" UI is left
//      in the app sources.
// =============================================================================

@MainActor
final class SacredPathNavigationRemovalTests: XCTestCase {

    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    // MARK: Permissions

    func testWhenInUseLocationIsStillDeclared() throws {
        let text = try XCTUnwrap(info["NSLocationWhenInUseUsageDescription"] as? String)
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testNoAlwaysLocationPermission() {
        XCTAssertNil(info["NSLocationAlwaysAndWhenInUseUsageDescription"])
        XCTAssertNil(info["NSLocationAlwaysUsageDescription"])
    }

    func testNoBackgroundLocationOrAudioMode() {
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        XCTAssertFalse(modes.contains("location"), "background location is only for navigation")
        XCTAssertFalse(modes.contains("audio"), "background audio is only for voice guidance")
        // Retained: maps/weather background refresh and push.
        XCTAssertTrue(modes.contains("fetch"))
        XCTAssertTrue(modes.contains("processing"))
        XCTAssertTrue(modes.contains("remote-notification"))
    }

    func testNoNavigationOnlyProviderKeys() {
        XCTAssertNil(info["MapboxAccessToken"])
        XCTAssertNil(info["MapTilerAPIKey"])
        XCTAssertNil(info["MapLibreTileURLTemplate"])
    }

    // MARK: Retained features

    func testMapsAndNearMeCardsStillEnabled() {
        XCTAssertTrue(MapFeatureFlags.enabled)
        XCTAssertTrue(MapFeatureFlags.dashboardCardsEnabled)
        XCTAssertEqual(MapsMode.allCases, [.rate, .weather, .stops, .both])
        // Compile-time proof the retained screens still exist.
        let screens: [Any.Type] = [
            MapsHubView.self, WeatherNearMeCard.self, RateNearMeCard.self,
            SacredPathHubView.self, SacredPathMapView.self, SacredPathRoutePreviewView.self,
            SacredPathTripPlannerView.self, AITripPlannerView.self, TruckProfileSettingsView.self,
        ]
        XCTAssertEqual(screens.count, 9)
    }

    func testCurrentLocationServiceIsForegroundOnly() {
        let location = LocationManager.shared
        // Foreground updates only start when a map/card asks for them; nothing
        // runs at rest. (Authorized = When-In-Use, or a previously granted Always.)
        _ = location.isAuthorized
        _ = location.isDenied
        _ = location.coordinate
        XCTAssertFalse(location.isUpdating)
    }

    func testRoutePreviewSamplingStillWorks() {
        // Planning-only route preview keeps its along-route sampling.
        let line = (0...100).map { CLLocationCoordinate2D(latitude: 35 + Double($0) * 0.01, longitude: -97) }
        let samples = SacredPathRouteModel.sample(line, spacingMeters: 20_000, maxSamples: 7)
        XCTAssertGreaterThanOrEqual(samples.count, 2)
        XCTAssertLessThanOrEqual(samples.count, 7)
        XCTAssertEqual(samples.first?.latitude, 35)
    }

    func testSharedPlanningTypesStillWork() {
        let destination = SacredPathDestination(name: "Dallas, TX", latitude: 32.7767, longitude: -96.797)
        XCTAssertEqual(destination.coordinate.latitude, 32.7767, accuracy: 0.0001)
        XCTAssertEqual(SacredPathFormat.formatDuration(3_900), "1h 5m")
    }

    // MARK: Navigation is gone

    func testAppSourcesHaveNoTurnByTurnNavigation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("SacredPathway")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw XCTSkip("app sources not reachable from this test run")
        }
        let forbidden = [
            "SacredPathNavigationEngine", "SacredPathNavigationModeView", "SacredPathActiveTruckMapView",
            "SacredPathMapDiagnosticsView", "OpenInMapsButtons", "OpenInMapsMenu", "TruckRoutingResolver",
            "MapboxTruckRoutingProvider", "AVSpeechSynthesizer", "requestAlwaysAuthorization",
            "allowsBackgroundLocationUpdates", "\"Start Navigation\"", "Start In-App",
            "NSLocationAlwaysAndWhenInUseUsageDescription",
        ]
        var hits: [String] = []
        var scanned = 0
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard ["swift", "plist"].contains(url.pathExtension),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for token in forbidden where text.contains(token) {
                hits.append("\(url.lastPathComponent): \(token)")
            }
            if url.lastPathComponent == "Info.plist" {
                XCTAssertFalse(text.contains("<string>location</string>"), "background location mode in Info.plist")
                XCTAssertFalse(text.contains("<string>audio</string>"), "background audio mode in Info.plist")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "expected to scan the app sources")
        XCTAssertEqual(hits, [], "navigation code left in the app")
    }
}
