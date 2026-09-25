

import SwiftUI

import SwiftUI
import Combine
import BackgroundTasks
import UIKit
import UserNotifications

// MARK: - Orientation manager
// Allows the video player to unlock landscape while keeping everything else portrait.
final class PlayerOrientationManager {
    static let shared = PlayerOrientationManager()
    private init() {}

    /// Screens that currently want landscape available. Ownership instead
    /// of one shared bool: opening Multi-View from the video player had the
    /// player's dismissal land AFTER Multi-View's appearance, yanking
    /// landscape straight back off.
    private var owners = Set<String>()

    var allowsLandscape: Bool { !owners.isEmpty }

    func enableLandscape(_ owner: String) {
        owners.insert(owner)
        invalidate()
    }

    func disableLandscape(_ owner: String) {
        owners.remove(owner)
        invalidate()
    }

    private func invalidate() {
        // UIKit ignores orientation invalidation that lands mid-transition
        // (e.g. while a fullScreenCover is still presenting), so re-assert
        // once more after the presentation has settled.
        notifyWindows()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.notifyWindows()
        }
    }

    private func notifyWindows() {
        DispatchQueue.main.async {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .forEach { window in
                    // The system asks the TOPMOST presented controller for its
                    // supported orientations — invalidating only the root does
                    // nothing while a cover (recording player) or sheet
                    // (settings → recordings) is up. Walk the whole chain.
                    var vc = window.rootViewController
                    vc?.setNeedsUpdateOfSupportedInterfaceOrientations()
                    while let presented = vc?.presentedViewController {
                        presented.setNeedsUpdateOfSupportedInterfaceOrientations()
                        vc = presented
                    }
                }
        }
    }
}

// MARK: - App delegate
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        PlayerOrientationManager.shared.allowsLandscape
            ? [.portrait, .landscapeLeft, .landscapeRight]
            : .portrait
    }

    // Game reminders should still banner when the app is open — without this,
    // foreground notifications are silently dropped.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

@main
struct OnsideTVApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var channelViewModel = ChannelViewModel.shared
    @StateObject private var scoreViewModel = ScoreViewModel()
    @Environment(\.scenePhase) var scenePhase


    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    /// Faster tick used only while Live Activities are running — a game
    /// clock that moves once a minute reads as frozen on the Lock Screen.
    let liveActivityTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    init() {
        AppDefaults.register()
        // NOTE: `UIScrollView.appearance().delaysContentTouches = false` used to
        // be set here, to restore the instant press feedback the old UIKit shelf
        // wrapper had. It was costing far more than it bought: with the delay
        // off, a list's own pan recogniser claims a touch immediately, and the
        // screen-edge pop gesture then has to wait for that pan to fail before
        // it can begin — which is why swiping back out of a Settings sub-page
        // sat still for about a second before it started following the finger.
        // Cards taking the system's standard highlight delay is the better
        // trade.
        BackgroundManager.shared.register()
        // Re-arm at every launch too, not just on backgrounding — a reboot,
        // app update, or force-quit wipes pending BGTask submissions, and
        // an app that's opened then killed would otherwise never refresh.
        BackgroundManager.shared.scheduleAppRefresh()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: channelViewModel, scoreViewModel: scoreViewModel)
                .environmentObject(channelViewModel)
                .environmentObject(scoreViewModel)
                .onAppear {
                    UIApplication.shared.beginReceivingRemoteControlEvents()
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        Task { await channelViewModel.handleAppActivation() }
                        // Live Activities froze while the app was away —
                        // push fresh scores into them immediately.
                        if !GameActivityManager.shared.trackedGameIDs.isEmpty {
                            Task { await scoreViewModel.fetchScores(forceRefresh: true, silent: true) }
                        }
                    } else if phase == .background {
                        BackgroundManager.shared.scheduleAppRefresh()
                    }
                }
                .onReceive(timer) { _ in

                    Task {
                        await scoreViewModel.fetchScores(silent: true)
                    }
                }
                .onReceive(liveActivityTimer) { _ in
                    let tracked = GameActivityManager.shared.trackedGameIDs
                    guard !tracked.isEmpty else { return }
                    // Explicitly forced: a tracked Live Activity is the one case
                    // that genuinely wants a refresh faster than the freshness
                    // window allows, and it only runs while one is on screen.
                    // Limited to the feeds those games are actually in — see
                    // `fetchScores(limitedTo:)`. (Empty when a tracked game is
                    // not in any table, in which case everything is fetched.)
                    let sports = scoreViewModel.sports(carrying: tracked)
                    Task {
                        await scoreViewModel.fetchScores(forceRefresh: true, silent: true,
                                                         limitedTo: sports.isEmpty ? nil : sports)
                    }
                }
        }
    }
}

class BackgroundManager {
    static let shared = BackgroundManager()
    /// Long-form PROCESSING task: minutes of runtime for the full guide
    /// download + parse, but iOS mostly grants it overnight on charge.
    let backgroundTaskID = "com.nebulo.epgUpdate"
    /// Short APP-REFRESH task: ~30s budget, but the system runs these far
    /// more often (whenever it predicts the app might be used). Acts as the
    /// day-time trigger so a stale guide doesn't wait for the charger.
    let quickRefreshTaskID = "com.nebulo.epgQuickRefresh"

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskID, using: nil) { task in
            self.handleEPGRefresh(task: task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: quickRefreshTaskID, using: nil) { task in
            self.handleEPGRefresh(task: task)
        }
    }

    /// Arms BOTH background triggers, earliest run = 12 hours after the
    /// last successful update. Whichever the system grants first refreshes
    /// the guide; the other becomes a no-op (the fetch checks staleness).
    func scheduleAppRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskID)
        let request = BGProcessingTaskRequest(identifier: backgroundTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = nextRunDate()

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule EPG background refresh: \(error)")
        }

        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: quickRefreshTaskID)
        let quick = BGAppRefreshTaskRequest(identifier: quickRefreshTaskID)
        quick.earliestBeginDate = nextRunDate()
        do {
            try BGTaskScheduler.shared.submit(quick)
        } catch {
            print("Could not schedule EPG quick refresh: \(error)")
        }
    }

    func handleEPGRefresh(task: BGTask) {
        scheduleAppRefresh()

        let work = Task {
            let result = await ChannelViewModel.shared.backgroundFetch()
            task.setTaskCompleted(success: result != .noData)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    private func nextRunDate() -> Date {
        let last = ChannelViewModel.shared.lastEPGUpdateDate ?? .distantPast
        let next = last.addingTimeInterval(ChannelViewModel.epgMaxAge)
        // Never sooner than 15 minutes out — the system ignores immediate
        // dates anyway, and the update would be redundant right after use.
        return max(next, Date().addingTimeInterval(15 * 60))
    }
}
