

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
        // Game detail is a custom in-hierarchy overlay, not a sheet, so the
        // Sports Hub renders live and undimmed behind the cards and they run
        // flush to the screen edges. Both the hub tap (`detailRequest`) and
        // the Live-Activity deep link (`deepLinkRequest`, which first
        // dismisses any full-screen player) route through the one presenter.
        .overlay {
            if let request = scoreViewModel.detailRequest ?? scoreViewModel.deepLinkRequest {
                GameDetailPresenter(
                    request: request,
                    viewModel: viewModel,
                    scoreViewModel: scoreViewModel,
                    accentColor: Color(hex: customAccentHex) ?? .white,
                    onDismiss: closeDetail
                )
                .transition(.move(edge: .bottom))
                .zIndex(50)
            }
        }
        // Smooth (no-bounce) present — the open slides the live view up. The
        // drag-close animates the card off-screen itself (in the presenter),
        // then calls closeDetail to drop the view once it's already gone, so
        // this animation only ever drives the OPEN.
        .animation(.smooth(duration: 0.3), value: scoreViewModel.detailRequest)
        .animation(.smooth(duration: 0.3), value: scoreViewModel.deepLinkRequest)
    }

    /// Removes the game detail. The drag-close has already animated the card
    /// off-screen by the time this runs, so the removal itself is instant and
    /// unanimated (any teardown hitch is off-screen). Non-drag closes (Watch
    /// button, deep link) just remove it.
    private func closeDetail() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scoreViewModel.detailRequest = nil
            scoreViewModel.deepLinkRequest = nil
        }
    }
}

#Preview {
    ContentView(viewModel: ChannelViewModel(), scoreViewModel: ScoreViewModel())
}