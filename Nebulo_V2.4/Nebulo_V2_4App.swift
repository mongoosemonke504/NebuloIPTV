

import SwiftUI

import SwiftUI
import Combine

@main
struct Nebulo_V2_4App: App {
    
    @StateObject private var channelViewModel = ChannelViewModel.shared
    @StateObject private var scoreViewModel = ScoreViewModel()
    @Environment(\.scenePhase) var scenePhase
    
    
    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    
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
                        Task { await channelViewModel.checkReloadNeeded() }
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
