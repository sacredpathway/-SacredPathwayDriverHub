import Foundation
import BackgroundTasks
import CoreLocation

// =============================================================================
// MARK: - BackgroundRefreshManager
// -----------------------------------------------------------------------------
// Opportunistic background refresh for the freight + weather snapshots so the
// maps and "Near Me" cards are fresh when the user reopens the app. Uses
// BGAppRefreshTask (no special entitlement — `fetch`/`processing` in
// UIBackgroundModes is sufficient).
//
// Registration MUST happen before the app finishes launching; it is called
// from the existing app delegate (DriverPushRegistrar). The task identifier is
// declared in Info.plist → BGTaskSchedulerPermittedIdentifiers. If Background
// App Refresh is disabled by the user, scheduling simply no-ops — the in-app
// 15-minute timers still keep data current while the app is active.
// =============================================================================

enum BackgroundRefreshManager {
    static let taskIdentifier = "org.sacredpathway.driverhub.maps.refresh"

    /// Call once, before app launch completes.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            handle(task as! BGAppRefreshTask)
        }
    }

    /// Ask the system to wake us in ~20 minutes (system decides actual timing).
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Non-fatal: Background App Refresh likely disabled. In-app timers
            // continue to refresh while the app is active.
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        // Always schedule the next one first so the chain continues.
        schedule()

        let work = Task {
            let coordinate = await MainActor.run { LocationManager.shared.coordinate }
            // Refresh freight (provider-agnostic) and weather (if configured).
            await FreightRateService.shared.refresh(around: coordinate, force: true)
            if let coordinate {
                await WeatherService.shared.refresh(at: coordinate, force: true)
            }
            // Give the network a brief window to settle the caches.
            try? await Task.sleep(nanoseconds: 8_000_000_000)
        }

        task.expirationHandler = { work.cancel() }

        Task {
            _ = await work.result
            task.setTaskCompleted(success: true)
        }
    }
}
