

import SwiftUI

import SwiftUI
import Combine
import BackgroundTasks
import UIKit

// MARK: - Orientation manager
// Allows the video player to unlock landscape while keeping everything else portrait.
final class PlayerOrientationManager {
    static let shared = PlayerOrientationManager()
    private init() {}

    var allowsLandscape = false {
        didSet {
            // Tell every window's root view controller to re-query supported orientations.
            DispatchQueue.main.async {
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            }
        }
    }
}

// MARK: - App delegate
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        PlayerOrientationManager.shared.allowsLandscape
            ? [.portrait, .landscapeLeft, .landscapeRight]
            : .portrait
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
            if let refreshTask = task as? BGAppRefreshTask {
                self.handleAppRefresh(task: refreshTask)
            }
        }
    }
    
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskID)
        request.earliestBeginDate = getNextRunDate()
        
        do {
            try BGTaskScheduler.shared.submit(request)
            
        } catch {
            print("Could not schedule app refresh: \(error)")
        }
    }
    
    func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh() 
        
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        Task {
            let result = await ChannelViewModel.shared.backgroundFetch()
            task.setTaskCompleted(success: result != .noData)
        }
    }
    
    private func getNextRunDate() -> Date {
        let now = Date()
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        components.hour = 4
        components.minute = 30
        
        guard let scheduledDate = calendar.date(from: components) else { return now.addingTimeInterval(3600) }
        
        if scheduledDate <= now {
            return calendar.date(byAdding: .day, value: 1, to: scheduledDate) ?? now.addingTimeInterval(3600)
        }
        return scheduledDate
    }
}
