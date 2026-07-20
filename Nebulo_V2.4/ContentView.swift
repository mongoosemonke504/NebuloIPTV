

import SwiftUI

extension Notification.Name {
    /// Posted right before the deep-link stats sheet presents; MainView
    /// dismisses any full-screen cover (player, search, multi-view) so the
    /// sheet has somewhere to appear.
    static let nebuloDeepLinkWillPresent = Notification.Name("nebuloDeepLinkWillPresent")
    /// Posted when the user taps the PiP window's "back to full screen"
    /// button; MainView re-presents the full player for the last channel.
    static let nebuloPiPRestore = Notification.Name("nebuloPiPRestore")
}

struct ContentView: View {
    @ObservedObject private var accountManager = AccountManager.shared
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @AppStorage("customAccentHex") private var customAccentHex = "#FFFFFF"

    var body: some View {
        Group {
            if accountManager.isLoggedIn {
                MainView(viewModel: viewModel, scoreViewModel: scoreViewModel)
            } else {
                LoginView()
            }
        }
        .preferredColorScheme(.dark)
        // Live Activity tap: nebulo://game/<id> → the game's detail page.
        // Presented from the root so it opens over whatever screen is up.
        .onOpenURL { url in
            guard url.scheme == "nebulo", url.host == "game" else { return }
            let id = url.lastPathComponent
            guard !id.isEmpty, id != "/" else { return }
            // Ask MainView to close the video player / search / multi-view
            // first — a sheet can't present under a fullScreenCover — then
            // open the stats page once the dismissal has cleared.
            NotificationCenter.default.post(name: .nebuloDeepLinkWillPresent, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                scoreViewModel.openGameFromDeepLink(id: id)
            }
        }
        .sheet(item: $scoreViewModel.deepLinkRequest) { request in
            GameDetailView(
                request: request,
                viewModel: viewModel,
                scoreViewModel: scoreViewModel,
                accentColor: Color(hex: customAccentHex) ?? .white
            )
        }
    }
}

#Preview {
    ContentView(viewModel: ChannelViewModel(), scoreViewModel: ScoreViewModel())
}