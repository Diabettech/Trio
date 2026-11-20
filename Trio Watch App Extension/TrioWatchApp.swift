import SwiftUI
import UserNotifications

@main struct TrioWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = WatchState.shared
        WatchNotificationHandler.shared.configure()
        // At every launch, background ones included: HealthKit's observers must be registered before
        // it can deliver the samples that woke the app.
        WatchActivityReader.shared.start()
        WatchLogger.shared.info(.lifecycle, "App launched")
    }

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            WatchState.shared.setAppActive(newScenePhase == .active)
            if newScenePhase == .background {
                WatchLogger.shared.info(.lifecycle, "App moved to background")
                WatchLogger.shared.didEnterBackground()
            } else if newScenePhase == .active {
                WatchState.shared.refreshIfNeeded()
            }
        }
    }
}
