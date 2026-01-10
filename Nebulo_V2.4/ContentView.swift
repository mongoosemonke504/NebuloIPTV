//
//  ContentView.swift
//  Nebulo_V2.4
//
//  Created by Robert Hillhouse on 1/5/26.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject private var accountManager = AccountManager.shared
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    
    var body: some View {
        Group {
            if accountManager.isLoggedIn {
                MainView(viewModel: viewModel, scoreViewModel: scoreViewModel)
            } else {
                LoginView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView(viewModel: ChannelViewModel(), scoreViewModel: ScoreViewModel())
}