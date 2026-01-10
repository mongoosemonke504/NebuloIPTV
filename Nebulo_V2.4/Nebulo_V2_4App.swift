//
//  Nebulo_V2_4App.swift
//  Nebulo_V2.4
//
//  Created by Robert Hillhouse on 1/5/26.
//

import SwiftUI

import SwiftUI
import Combine

@main
struct Nebulo_V2_4App: App {
    // Initialize ViewModels here to start data fetching immediately
    @StateObject private var channelViewModel = ChannelViewModel.shared
    @StateObject private var scoreViewModel = ScoreViewModel()
    
    // Timer for periodic updates (every 60 seconds)
    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: channelViewModel, scoreViewModel: scoreViewModel)
                .environmentObject(channelViewModel)
                .environmentObject(scoreViewModel)
                .onAppear {
                    UIApplication.shared.beginReceivingRemoteControlEvents()
                }
                .onReceive(timer) { _ in
                    // Periodically refresh scores
                    Task {
                        await scoreViewModel.fetchScores(silent: true)
                    }
                }
        }
    }
}
