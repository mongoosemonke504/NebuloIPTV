import SwiftUI

struct ContentView: View {
    @AppStorage("isLoggedIn") private var isLoggedIn = false; @StateObject private var viewModel = ChannelViewModel()
    var body: some View { ZStack { if isLoggedIn { MainView(viewModel: viewModel).transition(.blurFade) } else { LoginView().transition(.blurFade) } }.animation(.easeInOut(duration: 0.5), value: isLoggedIn) }
}