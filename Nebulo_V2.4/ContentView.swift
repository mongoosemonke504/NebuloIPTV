//
//  ContentView.swift
//  Nebulo_V2.4
//
//  Created by Robert Hillhouse on 1/5/26.
//

import SwiftUI

struct ContentView: View {
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    @StateObject private var viewModel = ChannelViewModel()
    @StateObject private var scoreViewModel = ScoreViewModel()
    
    var body: some View {
        Group {
            if isLoggedIn {
                MainView(viewModel: viewModel)
            } else {
                LoginView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}