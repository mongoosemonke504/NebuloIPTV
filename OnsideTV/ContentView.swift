

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
    // Plain references, NOT observed. Nothing in this body reads either
    // model; they are handed down to MainView, which observes them itself.
    // Observed here, every score refresh and guide tick re-ran the root's
    // body — and with it a re-diff of the entire app.
    let viewModel: ChannelViewModel
    let scoreViewModel: ScoreViewModel

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
            GameDetailHost(viewModel: viewModel, scoreViewModel: scoreViewModel)
        }
    }
}

/// Mounts the game card. The only view that observes `GameDetailRoute`, so
/// a tap re-renders this — an overlay with one child — and nothing above it.
private struct GameDetailHost: View {
    let viewModel: ChannelViewModel
    let scoreViewModel: ScoreViewModel
    @ObservedObject private var route: GameDetailRoute
    @AppStorage("customAccentHex") private var customAccentHex = "#FFFFFF"

    init(viewModel: ChannelViewModel, scoreViewModel: ScoreViewModel) {
        self.viewModel = viewModel
        self.scoreViewModel = scoreViewModel
        _route = ObservedObject(wrappedValue: scoreViewModel.detailRoute)
    }

    var body: some View {
        if let request = route.current {
            GameDetailPresenter(
                request: request,
                viewModel: viewModel,
                scoreViewModel: scoreViewModel,
                accentColor: Color(hex: customAccentHex) ?? .white,
                onDismiss: closeDetail
            )
            // Identity, NOT a move transition: sliding the presenter would
            // carry its black backdrop up with the card. The backdrop must
            // be there the instant the overlay mounts, so the presenter
            // appears in place and animates only the card up itself.
            .transition(.identity)
            .zIndex(50)
        }
    }

    /// Removes the game detail. The drag-close has already animated the card
    /// off-screen by the time this runs, so the removal itself is instant and
    /// unanimated (any teardown hitch is off-screen). Non-drag closes (Watch
    /// button, deep link) just remove it.
    private func closeDetail() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            route.request = nil
            route.deepLinkRequest = nil
        }
    }
}

#Preview {
    ContentView(viewModel: ChannelViewModel(), scoreViewModel: ScoreViewModel())
}