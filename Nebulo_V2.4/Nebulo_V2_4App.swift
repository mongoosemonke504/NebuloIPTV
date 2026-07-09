

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

    var allowsLandscape = false {
        didSet {
            // UIKit ignores orientation invalidation that lands mid-transition
            // (e.g. while a fullScreenCover is still presenting), so re-assert
            // once more after the presentation has settled.
            notifyWindows()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.notifyWindows()
            }
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
struct Nebulo_V2_4App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var channelViewModel = ChannelViewModel.shared
    @StateObject private var scoreViewModel = ScoreViewModel()
    @Environment(\.scenePhase) var scenePhase


    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init() {
        AppDefaults.register()
        BackgroundManager.shared.register()
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
                    } else if phase == .background {
                        BackgroundManager.shared.scheduleAppRefresh()
                    }
                }
                .onReceive(timer) { _ in
                    
                    Task {
                        await scoreViewModel.fetchScores(silent: true)
                    }
                }
        }
    }
}

class BackgroundManager {
    static let shared = BackgroundManager()
    let backgroundTaskID = "com.nebulo.epgUpdate"

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskID, using: nil) { task in
            self.handleEPGRefresh(task: task)
        }
    }

    /// A PROCESSING task, not an app-refresh task: a full guide download and
    /// parse takes minutes, and app-refresh tasks get killed after ~30s.
    /// Earliest run = 12 hours after the last successful update, so the
    /// guide refreshes on the same cadence whether or not the app is open.
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
