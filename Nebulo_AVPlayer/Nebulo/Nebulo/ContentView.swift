

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