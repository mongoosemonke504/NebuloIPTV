

import SwiftUI

import SwiftUI
import Combine
import BackgroundTasks

@main
struct Nebulo_V2_4App: App {
    
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
