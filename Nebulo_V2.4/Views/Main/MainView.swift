import SwiftUI
import UIKit
import AVFoundation
import Combine

extension View {
    @ViewBuilder
    func matchedTransitionSourceIfAvailable(id: some Hashable, in ns: Namespace.ID?) -> some View {
        if let ns {
            if #available(iOS 18.0, *) {
                self.matchedTransitionSource(id: id, in: ns)
            } else {
                self
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func navigationZoomTransitionIfAvailable(sourceID: some Hashable, in ns: Namespace.ID?) -> some View {
        if let ns {
            if #available(iOS 18.0, *) {
                self.navigationTransition(.zoom(sourceID: sourceID, in: ns))
            } else {
                self
            }
        } else {
            self
        }
    }

    /// Defers iOS edge system gestures (Control Center, Notification Center) so taps on
    /// buttons positioned at screen edges aren't intercepted by the OS. Used for the
    /// fullscreen player so the close (top-left) and multiview (top-right) buttons work.
    /// Top edge ONLY: deferring the bottom edge made the home-indicator swipe require
    /// two swipes to leave the app (first swipe just revealed the indicator).
    @ViewBuilder
    func defersSystemGesturesIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            self.defersSystemGestures(on: .top)
        } else {
            self
        }
    }
}

struct MainView: SwiftUI.View {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @AppStorage("xstreamURL") private var xstreamURL = ""; @AppStorage("username") private var username = ""; @AppStorage("password") private var password = ""; @AppStorage("loginTypeRaw") private var loginTypeRaw = LoginType.xtream.rawValue; @AppStorage("viewMode") private var viewMode = ViewMode.automatic.rawValue; @AppStorage("customAccentHex") private var customAccentHex = "#FFFFFF"
    @AppStorage("showSupportPopup") private var showSupportPopup = true
    @AppStorage("lastSupportPopupTime") private var lastSupportPopupTime: Double = 0
    
    @State private var selectedCategory: StreamCategory?
    @State private var selectedChannel: StreamChannel?
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showMultiView = false

    /// Mirrors `MainViewModifiers.dockVisible`: the bottom bar is only on the
    /// root surfaces. The Multi-View pill anchors itself to that bar, so it
    /// has to come and go with it rather than float over a drill-down page.
    private var dockShowing: Bool {
        guard let cat = selectedCategory else { return true }
        return cat.id == -3 || cat.id == -4 || cat.id == -6
    }

    @State private var showQuickSwitcher = false
    @State private var showSupportAlert = false
    @State private var selectedRecording: Recording?
    @State private var isPlayerActive: Bool = false
    @Namespace private var zoomNS

    // Once-a-day full reload. Held as a static publisher so the Timer
    // subscription isn't rebuilt every time MainView's body re-evaluates --
    // SwiftUI re-initialises this struct on every state mutation, and the
    // previous instance-level `let` was creating (and discarding) a fresh
    // autoconnected publisher each render.
    /// Multi-view's slide on and off, matched to a navigation push — which is
    /// what the Settings sub-pages get from UIKit, and the pace the rest of the
    /// app is measured against. 0.35s on an ease-in-out curve is that
    /// animation. Not a spring: a spring overshoots a `.move` transition past
    /// the screen edge and back, baring the content underneath for a frame.
    static let multiViewSlide: Animation = .easeInOut(duration: 0.35)

    private static let refreshTimer = Timer.publish(every: 86400, on: .main, in: .common).autoconnect()
    var accentColor: Color { Color(hex: customAccentHex) ?? .blue }
    
    var body: some SwiftUI.View {
        GeometryReader { geo in
            let isL = geo.size.width > geo.size.height
            ZStack {
                // Nebula is drawn inside mainNavigationStack (see comment
                // there) — a copy out here would be occluded by the nav
                // container's opaque background and just waste GPU.
                mainNavigationStack(isL: isL)
                    .zIndex(1)
                    .interactivePopGesture(isEnabled: !isPlayerActive)
                    .onChangeCompat(of: selectedChannel) { newValue in
                        isPlayerActive = (newValue != nil || viewModel.miniPlayerChannel != nil)
                    }
                    .onChangeCompat(of: viewModel.miniPlayerChannel) { newValue in
                        isPlayerActive = (selectedChannel != nil || newValue != nil)
                    }
                
                overlays(isL: isL)
            }
        }
        // `.container`, NOT all regions. A bare `ignoresSafeArea()` also drops
        // the KEYBOARD region, and everything drawn by `overlays` above is a
        // SIBLING of the navigation stack — so those overlays inherited a
        // hierarchy with no keyboard inset and nothing in them could ever lift
        // above the keyboard. (The app's own dock was fine either way: it lives
        // inside the navigation stack, which re-establishes its own safe area.)
        // Multi-view's search bar is the case that exposed it.
        .ignoresSafeArea(.container)
        .task { 
            if viewModel.channels.isEmpty { 
                await viewModel.loadData(url: xstreamURL, user: username, pass: password, type: LoginType(rawValue: loginTypeRaw) ?? .xtream) 
            }
            if showSupportPopup { 
                let now = Date().timeIntervalSince1970
                if now - lastSupportPopupTime > 43200 { 
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    showSupportAlert = true
                    lastSupportPopupTime = now 
                } 
            } 
        }
        .onReceive(Self.refreshTimer) { _ in
            Task { 
                await viewModel.loadData(url: xstreamURL, user: username, pass: password, type: LoginType(rawValue: loginTypeRaw) ?? .xtream, silent: true) 
            } 
        }
        .onChangeCompat(of: viewModel.channelToAutoPlay) { nc in
            if let c = nc {
                // Same bookkeeping as playChannel — a stream found via a
                // game tap belongs in Continue Watching too.
                viewModel.addToRecent(c.id)
                viewModel.lastPlayedChannelID = c.id
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { selectedChannel = c }
                viewModel.channelToAutoPlay = nil
            }
        }
        .onChangeCompat(of: viewModel.triggerMultiView) { nv in
            if nv {
                selectedChannel = nil
                withAnimation(MainView.multiViewSlide) { showMultiView = true }
                viewModel.triggerMultiView = false
            }
        }
        // PiP window's "back to full screen" button: the on-screen player
        // was dismissed behind the float, so re-present it for the channel
        // that's playing. If the cover is still up, there's nothing to do —
        // the system just brings the app forward.
        .onReceive(NotificationCenter.default.publisher(for: .nebuloPiPRestore)) { _ in
            guard selectedChannel == nil,
                  let id = viewModel.lastPlayedChannelID,
                  let c = viewModel.channels.first(where: { $0.id == id }) else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { selectedChannel = c }
        }
        // Search now lives IN the main hierarchy (as a section overlay inside
        // MainViewModifiers) so the bottom bar can perform the Liquid Glass
        // morph between its dock and search states. The keyboard never rises
        // during the section transition (no auto-focus), so the historic
        // keyboard-relayout artifact that once forced a fullScreenCover
        // cannot occur.
    }


    private var backgroundLayer: some View {
        AppBackground()
            .ignoresSafeArea()
            .zIndex(0)
    }
    
    @ViewBuilder
    private func mainNavigationStack(isL: Bool) -> some View {
        NavigationStack {
            ZStack {
                // The nebula must live INSIDE the NavigationStack: the nav
                // container's hosting view paints an opaque system background
                // (pure black in dark mode) over anything rendered behind the
                // stack, which is why the home screen showed no gradient when
                // the background only existed at the outer ZStack.
                backgroundLayer

                contentLayout(isL: isL)

                if viewModel.activeMultiViewCount > 0 && !showMultiView && selectedChannel == nil && dockShowing {
                    MultiViewIndicator(count: viewModel.activeMultiViewCount, accentColor: nil, action: { withAnimation(MainView.multiViewSlide) { showMultiView = true } }).zIndex(5)
                }
            }
            .modifier(MainViewModifiers(
                viewModel: viewModel,
                scoreViewModel: scoreViewModel,
                showMultiView: $showMultiView,
                showSettings: $showSettings,
                showSearch: $showSearch,
                showSupportAlert: $showSupportAlert,
                showSupportPopup: $showSupportPopup,
                selectedRecording: $selectedRecording,
                selectedChannel: $selectedChannel,
                selectedCategory: $selectedCategory,
                showQuickSwitcher: $showQuickSwitcher,
                accentColor: accentColor,
                playAction: playChannel,
                zoomNS: zoomNS
            ))
        }
    }

    @ViewBuilder
    private func contentLayout(isL: Bool) -> some View {
        Group {
            if shouldUseSidebar(isLandscape: isL) { 
                SidebarLayout(viewModel: viewModel, scoreViewModel: scoreViewModel, selectedCategory: $selectedCategory, selectedChannel: $selectedChannel, searchText: $viewModel.searchText, isLandscape: isL, accentColor: accentColor, playAction: playChannel, showMultiView: $showMultiView, showSettings: $showSettings, zoomNS: zoomNS)
            } else { 
                StandardLayout(viewModel: viewModel, scoreViewModel: scoreViewModel, selectedCategory: $selectedCategory, selectedChannel: $selectedChannel, searchText: $viewModel.searchText, accentColor: accentColor, playAction: playChannel, showMultiView: $showMultiView, showSettings: $showSettings, selectedRecording: $selectedRecording, zoomNS: zoomNS, searchOverlayOpen: showSearch)
            }
        }
        .zIndex(1)
    }
}

/// One hero page's position and alpha, straight out of Nuvio's `graphicsLayer`
/// block: `offset = -rel + fraction`, `alpha = 1 - |offset|`, and a sideways
/// shift of `offset x width x parallax` — 0.055 for the artwork, 0.18 for the
/// title block, which is the difference in speed that reads as depth.
///
/// An `@ObservedObject` on the modifier rather than on the carousel, so a frame
/// of a swipe re-renders this transform alone and never the hero's content.
struct HeroPageTransform: ViewModifier {
    @ObservedObject var fraction: ScrollProgress
    /// 0 for the current page, ±1 for a neighbour.
    let rel: Int
    let width: CGFloat
    let parallax: CGFloat

    func body(content: Content) -> some SwiftUI.View {
        let offset = CGFloat(-rel) + fraction.value
        return content
            .offset(x: -offset * width * parallax)
            .opacity(Double(max(0, min(1, 1 - abs(offset)))))
    }
}

/// The lock screen's artwork for a live game: the same diagonal split the Live
/// Now card uses, with the two crests and nothing else.
///
/// Deliberately NOT that card. It carries a LIVE pill, the score and the clock
/// because it is built to be read in a shelf, and the lock screen draws its own
/// controls and elapsed time over the top. The colours, the split and the way
/// each crest sits centred in its OWN half are taken from it exactly.
///
/// The crests arrive as already-decoded images rather than URLs: this view is
/// rendered by `ImageRenderer`, which draws in one synchronous pass, so
/// anything still loading would come out blank.
struct NowPlayingMatchupArt: View {
    let game: ESPNEvent
    let awayCrest: UIImage?
    let homeCrest: UIImage?
    /// The tour's own emblem, for field events. The away/home crests are the
    /// leaders' flags there, which is not what the event looks like.
    var tourEmblem: UIImage? = nil
    /// The square this is drawn into; the crests size themselves from it.
    var edge: CGFloat = 512

    private var isFieldEvent: Bool { game.isFieldEvent }

    private func teamColor(_ c: ESPNCompetitor?) -> Color {
        guard let hex = c?.team?.color, !hex.isEmpty,
              let col = Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)") else {
            return Color(white: 0.16)
        }
        return col
    }

    var body: some View {
        if isFieldEvent {
            fieldEventArt
        } else {
            matchupArt
        }
    }

    /// A tournament or a race weekend. There is no matchup here: the two
    /// "competitors" are whoever happens to lead, and their flags say nothing
    /// about the event. One emblem for the tour, on a plain ground.
    private var fieldEventArt: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.16), Color(white: 0.07)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            if let emblem = tourEmblem {
                Image(uiImage: emblem)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: edge * 0.52, height: edge * 0.52)
                    .shadow(color: .black.opacity(0.45), radius: edge * 0.02, x: 0, y: edge * 0.01)
            } else {
                Image(systemName: game.isRaceEvent ? "flag.checkered" : "figure.golf")
                    .font(.system(size: edge * 0.34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private var matchupArt: some View {
        ZStack {
            // Hard diagonal split: away's colour on the left, home's on the
            // right, meeting on a steep edge across the middle.
            LinearGradient(
                stops: [
                    .init(color: teamColor(game.awayCompetitor), location: 0.5),
                    .init(color: teamColor(game.homeCompetitor), location: 0.5)
                ],
                startPoint: UnitPoint(x: 0.02, y: 0),
                endPoint: UnitPoint(x: 0.98, y: 1)
            )

            // Each crest centred in its own half, so neither crosses the seam
            // onto the other club's colour.
            HStack(spacing: 0) {
                crest(awayCrest)
                crest(homeCrest)
            }

            // The same soft floor the card has, so a pale kit never leaves the
            // artwork looking washed out.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.35), location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    @ViewBuilder
    private func crest(_ image: UIImage?) -> some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        // A share of the canvas rather than a fixed size, so the crests keep
        // their proportions whatever the artwork is rendered at.
        .frame(width: edge * 0.32, height: edge * 0.32)
        .shadow(color: .black.opacity(0.45), radius: edge * 0.02, x: 0, y: edge * 0.01)
        .frame(maxWidth: .infinity)
    }
}

/// Blocking "finding a stream" spinner, shown while a smart search or a
/// stream-list build is running.
struct StreamSearchOverlay: SwiftUI.View {
    var body: some SwiftUI.View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 15) {
                CustomSpinner(color: .white, lineWidth: 4, size: 40)
                Text("Finding best stream...").font(.caption).bold().foregroundStyle(.primary)
            }
            .padding(25)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .shadow(radius: 20)
        }
        .transition(.opacity)
    }
}

/// Renders whichever detail page the router has open, and owns the
/// swipe-to-close gesture for it.
///
/// Mounted ABOVE the bottom dock (see where it is applied in
/// `MainViewModifiers`) so the page covers the whole screen the way a
/// full-screen cover used to — but as part of the same view tree, so the
/// screen it is covering is still there to slide back into view behind it.
struct DetailPageHost: SwiftUI.View {
    @ObservedObject private var router = DetailRouter.shared
    // Passed straight through to the page, which subscribes to them itself —
    // observing them here as well would re-render the host on every unrelated
    // publish from either model.
    let viewModel: ChannelViewModel
    let scoreViewModel: ScoreViewModel
    let playAction: (StreamChannel) -> Void

    /// The drag has been claimed as a close gesture.
    @State private var dragging = false
    /// Started at the edge but read as something else — a vertical scroll, or
    /// a leftward drag — and is ignored for the rest of this drag.
    @State private var rejected = false

    /// Only the far edge closes the page: everything inboard of this belongs
    /// to the page itself, whose own tab paging starts at 44.
    private static let edgeWidth: CGFloat = 32

    var body: some SwiftUI.View {
        ZStack {
            if let route = router.route {
                page(for: route)
                    .id(route.id)
                    .modifier(DetailSlideOffset(slide: router.slide))
                    .transition(.move(edge: .trailing))
                    .simultaneousGesture(closeDrag)
            }
        }
    }

    @ViewBuilder
    private func page(for route: DetailRoute) -> some SwiftUI.View {
        switch route {
        case let .team(team, sport, leagueLabel):
            // Drivers aren't teams — ESPN's team endpoints 404 for racing,
            // so they get their own page.
            if sport == .f1 {
                DriverDetailPage(
                    driver: team,
                    viewModel: viewModel,
                    scoreViewModel: scoreViewModel,
                    playAction: playAction
                )
            } else {
                TeamDetailPage(
                    team: team,
                    leagueLabel: leagueLabel,
                    sport: sport,
                    viewModel: viewModel,
                    scoreViewModel: scoreViewModel
                )
            }
        case let .league(sport, leagueLabel, displayName):
            LeagueDetailPage(
                sport: sport,
                leagueLabel: leagueLabel,
                displayName: displayName,
                viewModel: viewModel,
                scoreViewModel: scoreViewModel
            )
        }
    }

    private var closeDrag: some Gesture {
        let width = max(UIScreen.main.bounds.width, 1)
        return DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard value.startLocation.x <= Self.edgeWidth else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if !dragging && !rejected {
                    // Judged once, on the first reported movement.
                    guard dx > 0, abs(dx) > abs(dy) else { rejected = true; return }
                    dragging = true
                    SwipeTapGuard.suppress()
                    // Freeze the page's own scroll for the rest of the gesture:
                    // a close swipe should travel sideways only, not drift the
                    // content up or down as it goes.
                    router.dragLock.set(true)
                }
                guard dragging else { return }
                router.trackSwipe(min(max(dx / width, 0), 1))
            }
            .onEnded { value in
                let wasDragging = dragging
                dragging = false
                rejected = false
                router.dragLock.set(false)
                guard wasDragging else { return }
                let travelled = max(0, value.translation.width)
                let flick = value.predictedEndTranslation.width - value.translation.width
                if travelled > width * 0.3 || travelled + flick > width * 0.6 {
                    router.finishSwipe()
                } else {
                    router.cancelSwipe()
                }
            }
    }
}

/// Eases the screen UNDERNEATH a detail page in from part-way across as the
/// page is swiped off, rather than leaving it sitting still — the parallax a
/// navigation pop gives you, which is what the Settings sub-pages get for free
/// from UIKit. Observes the router's leaf, so a drag frame moves this one
/// offset and re-renders none of the app beneath it.
/// Reveals the bottom bar exactly as far as a drill-down page has slid off.
///
/// The bar is an overlay on everything, so a page rendered inside the content
/// cannot draw over it the way `DetailPageHost` does — a team page is applied
/// AFTER this overlay and so simply covers the bar. Masking to the width the
/// page has vacated gets the same picture from the layer order we have: the
/// bar sits behind the page and is uncovered from the leading edge as it goes,
/// instead of being pulled out of the tree and put back in one frame.
///
/// A leaf, so a frame of the drag re-renders this mask and nothing else.
struct DockCoverMask: ViewModifier {
    @ObservedObject var cover: ScrollProgress
    /// A second, independent cover, resolved together with the first. A
    /// drill-down page and multi-view are never up at once, but each owns its
    /// own progress and the bar has to answer to whichever is over it.
    @ObservedObject var other: ScrollProgress

    func body(content: Content) -> some View {
        let covered = max(cover.value, other.value)
        let uncovered = 1 - min(max(covered, 0), 1)
        return content
            .mask(alignment: .leading) {
                Rectangle()
                    // Constrained in X only. Given the mask's own height it
                    // clipped the bar's bottom edge: the bar deliberately
                    // draws OUTSIDE its layout bounds (it ignores the bottom
                    // safe area to sit 20pt off the physical edge), and a mask
                    // is clipped to those bounds. A full-screen height covers
                    // everything it paints, however far past its frame that
                    // goes.
                    .frame(width: UIScreen.main.bounds.width * uncovered,
                           height: UIScreen.main.bounds.height)
            }
            // A masked-away bar must not take taps meant for the page over it.
            .allowsHitTesting(uncovered > 0.5)
    }
}

struct DetailUnderlayParallax: ViewModifier {
    @ObservedObject var cover: ScrollProgress

    func body(content: Content) -> some SwiftUI.View {
        content.offset(x: -UIScreen.main.bounds.width * DetailRouter.underlayParallax * cover.value)
    }
}

/// Slides the page sideways from the router's drag progress. An
/// `@ObservedObject` on the modifier rather than on the host, so each frame
/// of the drag re-renders this offset and nothing else — the page's body is
/// never re-evaluated while it travels.
struct DetailSlideOffset: ViewModifier {
    @ObservedObject var slide: ScrollProgress

    func body(content: Content) -> some SwiftUI.View {
        content.offset(x: slide.value * UIScreen.main.bounds.width)
    }
}

/// Holds an expensive subtree still while its parent re-renders.
///
/// SwiftUI re-evaluates a child's body whenever it cannot prove the child
/// unchanged, and a single closure among its inputs is enough to make that
/// impossible — which is why a screen that is already built and mounted still
/// paid full price on every unrelated parent update. Compared on `key` alone,
/// the body is evaluated when that changes and not otherwise; the subtree's own
/// observed objects and state still drive it normally.
struct StableSubtree<Content: View>: SwiftUI.View, Equatable {
    let key: AnyHashable
    @ViewBuilder var content: () -> Content

    static func == (lhs: StableSubtree, rhs: StableSubtree) -> Bool { lhs.key == rhs.key }

    var body: some SwiftUI.View { content() }
}

struct MainViewModifiers: ViewModifier {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Binding var showMultiView: Bool
    @Binding var showSettings: Bool
    @Binding var showSearch: Bool
    @Binding var showSupportAlert: Bool
    @Binding var showSupportPopup: Bool
    @Binding var selectedRecording: Recording?
    @Binding var selectedChannel: StreamChannel?
    @Binding var selectedCategory: StreamCategory?
    @Binding var showQuickSwitcher: Bool
    let accentColor: Color
    let playAction: (StreamChannel) -> Void
    var zoomNS: Namespace.ID? = nil

    /// What the user is typing into the Rename alert.
    ///
    /// Deliberately LOCAL. It used to bind straight to `viewModel.renameInput`,
    /// which is `@Published`: every keystroke republished the view model and
    /// re-evaluated this whole modifier, alert content included — and SwiftUI
    /// rebuilding an alert's body out from under a live `TextField` throws the
    /// edit away. The field looked like it accepted the new name, then Save
    /// wrote back whatever `renameInput` still held, which was the ORIGINAL
    /// name. Renaming a channel appeared to do nothing at all.
    ///
    /// Kept here, typing touches no published state, and Save hands the final
    /// string over once.
    @State private var renameDraft: String = ""

    /// The search field's text lives HERE (the field is part of the bottom
    /// bar so it can morph out of the dock); SearchView receives a binding
    /// and keeps its own debounce.
    @State private var searchQuery = ""
    @FocusState private var searchFieldFocused: Bool

    /// Watched so the dock can reappear while a back-swipe is in flight — see
    /// `dockVisible`. Publishes once at each end of the drag, never per frame.
    @ObservedObject private var backSwipe = BackSwipeState.shared

    /// Tab switches carry NO animation at all — Nuvio's tab host swaps the
    /// selected screen in a single frame, and copying that is what makes the
    /// switch feel instant instead of clunky. The state changes below are
    /// therefore plain assignments; the bottom bar animates its own selection
    /// pill and glass morph internally, so the chrome still glides.

    /// The bar shows on the root surfaces (Home, Sports hub, Favorites hub,
    /// Settings, Search). Drill-down pages (plain categories, Recently
    /// Watched, Recordings) hide it and show a circular back chevron
    /// instead — same as the reference app's catalog pages.
    /// The bar is in the tree on every one of these surfaces, drill-downs
    /// included. It is not hidden and re-shown any more — a drill-down COVERS
    /// it (see `DockCoverMask`), so a swipe uncovers it progressively, the
    /// same way a favourite team's page reveals it on the way out. Taking it
    /// out of the tree instead is what made it snap: gone for the whole
    /// gesture, then back in one frame at the end.
    private var dockVisible: Bool { true }

    private var activeDockTab: NuvioTab {
        if showSearch { return .search }
        switch selectedCategory?.id {
        case -3: return .sports
        case -4: return .favorites
        case -6: return .profile
        default: return .home
        }
    }

    /// Leaves search: clears the query and cuts back, then navigates.
    private func closeSearch() {
        searchFieldFocused = false
        searchQuery = ""
        viewModel.searchText = ""
        showSearch = false
    }

    private func handleDockTap(_ tab: NuvioTab) {
        if showSearch && tab != .search {
            closeSearch()
        }
        switch tab {
        case .home:
            guard selectedCategory != nil else { return }
            selectedCategory = nil
        case .search:
            guard !showSearch else { return }
            showSearch = true
        case .sports:
            guard selectedCategory?.id != -3 else { return }
            viewModel.lastSelectedHomeID = -3
            selectedCategory = StreamCategory(id: -3, name: "Sports")
        case .favorites:
            guard selectedCategory?.id != -4 else { return }
            viewModel.lastSelectedHomeID = -4
            selectedCategory = StreamCategory(id: -4, name: "Favorites")
        case .profile:
            guard selectedCategory?.id != -6 else { return }
            selectedCategory = StreamCategory(id: -6, name: "Settings")
        }
    }

    func body(content: Content) -> some View {
        let showRenameAlert = Binding<Bool>(get: { viewModel.showRenameAlert }, set: { viewModel.showRenameAlert = $0 })
        let showNoStreamsAlert = Binding<Bool>(get: { viewModel.showNoStreamsAlert }, set: { viewModel.showNoStreamsAlert = $0 })
        let categories = Binding<[StreamCategory]>(get: { viewModel.categories }, set: { viewModel.categories = $0 })

        content
            // The system navigation bar is permanently hidden in this stack:
            // toggling it per-screen made UIKit animate the bar in (Back + gear
            // visibly sliding down) every time a section opened. All chrome is
            // drawn in-view instead — the shared gear, and each section's Back
            // pill via StandardLayout.
            //
            // These modifiers are applied UNCONDITIONALLY, and only the search
            // bar's presence is gated inside the inset. Previously the whole
            // block was wrapped in `applyIf(!showMultiView)`, an if/else
            // ViewBuilder — so opening multi-view changed `content`'s structural
            // identity and rebuilt the home ScrollView underneath, throwing away
            // its scroll position. Entering a section (Sports, etc.) never
            // toggled this, which is why those kept their scroll and multi-view
            // didn't.
            .toolbar(.hidden, for: .navigationBar)
            // Search section — IN the main hierarchy (not a cover) so the
            // bottom bar can morph its glass between dock and search states,
            // and so section switches into/out of search are the same quick
            // crossfade as every other tab.
            .overlay {
                if showSearch {
                    SearchView(
                        viewModel: viewModel,
                        scoreViewModel: scoreViewModel,
                        accentColor: accentColor,
                        queryText: $searchQuery,
                        playAction: { channel in
                            closeSearch()
                            playAction(channel)
                        },
                        onCategorySelect: { cat in
                            viewModel.lastSelectedHomeID = cat.id
                            viewModel.lastSourceCategory = cat
                            closeSearch()
                            selectedCategory = cat
                        },
                        onDismiss: { closeSearch() }
                    )
                    .ignoresSafeArea()
                }
            }
            // The bottom bar: dock on the root sections, morphing into the
            // Home-circle + search-field pair while search is open. Content
            // scrolls BEHIND the glass; each screen pads its own scrollable
            // bottom instead. Hidden on drill-down pages (plain categories,
            // Recently Watched, Recordings) — those show the circular back
            // chevron, matching the reference's catalog pages.
            .overlay(alignment: .bottom) {
                if dockVisible || showSearch {
                    NuvioBottomBar(
                        active: activeDockTab,
                        // The reference bar's exact selected-tab blue, sampled
                        // from a screenshot of it: #55AFF9.
                        tint: Color(red: 0.333, green: 0.686, blue: 0.976),
                        searchMode: showSearch,
                        queryText: $searchQuery,
                        fieldFocused: $searchFieldFocused,
                        onSelect: { handleDockTap($0) },
                        onClearQuery: {
                            viewModel.triggerSelectionHaptic()
                            searchQuery = ""
                            viewModel.searchText = ""
                        },
                        onCancelSearch: {
                            // ✕ beside the field: just collapses the keyboard
                            // (the ✕ then melts back into the bar). The
                            // query keeps its results — the in-field clear
                            // handles erasing.
                            searchFieldFocused = false
                        }
                    )
                    // The system's keyboard avoidance lifts the bar exactly
                    // to the keyboard top — no manual padding on top of it,
                    // which was double-lifting the bar.
                    // Invisible host for the keyboard pre-warm field — keeps
                    // the system keyboard process warm so the search field's
                    // first focus is instant.
                    .background(
                        KeyboardPrewarmField()
                            .frame(width: 1, height: 1)
                            .opacity(0.01)
                            .allowsHitTesting(false)
                    )
                    // Covered by a drill-down rather than removed, so the page
                    // sliding off uncovers it under your finger.
                    .modifier(DockCoverMask(cover: backSwipe.cover,
                                            other: MultiViewDismiss.shared.cover))
                }
            }
            // Pushed aside while a detail page covers this. At rest the value
            // is 0, so this is an offset of zero and costs nothing.
            .modifier(DetailUnderlayParallax(cover: DetailRouter.shared.cover))
            // The same, for multi-view's close swipe. Additive, and each is 0
            // unless its own screen is up.
            .modifier(DetailUnderlayParallax(cover: MultiViewDismiss.shared.cover))
            // "Finding best stream..." — root level for the same reason as
            // the picker below it: the search is kicked off from home shelves
            // and search results too, and used to give no feedback at all
            // anywhere outside the Sports hub.
            .overlay {
                if viewModel.isSearchingGame { StreamSearchOverlay() }
            }
            // Manual stream picker for "Stream List". Presented at the root
            // so it works from the home shelves and search too, not only from
            // inside the Sports hub.
            .sheet(isPresented: Binding(
                get: { viewModel.showSelectionSheet },
                set: { viewModel.showSelectionSheet = $0 }
            )) {
                ManualSelectionSheet(viewModel: viewModel, accentColor: accentColor, playAction: playAction)
            }
            // Team / league / driver pages. Applied AFTER the dock overlay
            // above, so it renders over the bar exactly like the full-screen
            // cover this replaced — while leaving the screen underneath in
            // the hierarchy, which is what lets the close swipe reveal it.
            .overlay {
                DetailPageHost(
                    viewModel: viewModel,
                    scoreViewModel: scoreViewModel,
                    playAction: playAction
                )
            }
            // Plays a recording over the HOME screen (transparent cover). A
            // recording tapped inside the live player routes here after that
            // player is dismissed, so minimising the recording drops back to
            // home rather than the old live player.
            .fullScreenCover(item: $selectedRecording) { recording in
                RecordingPlayerView(recording: recording, viewModel: viewModel, onPlayChannel: { channel in
                    // The mirror of `onPlayRecording` below: leave the
                    // recording entirely, then open the channel live once the
                    // cover has dismissed.
                    selectedRecording = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { playAction(channel) }
                })
                .ignoresSafeArea()
            }

            // isPresented stays true while ANY channel is selected, so
            // switching channels from inside the player only updates the
            // `channel` prop — CustomVideoPlayerView's .onChangeCompat(of: channel)
            // calls setupPlayer() in-place with no dismiss/re-present animation.
            .fullScreenCover(isPresented: Binding(
                get: { selectedChannel != nil },
                set: { if !$0 { selectedChannel = nil } }
            )) {
                if let channel = selectedChannel {
                    CustomVideoPlayerView(channel: channel, viewModel: viewModel, scoreViewModel: scoreViewModel, epgTime: viewModel.currentTime, onDismiss: {
                        selectedChannel = nil
                        showQuickSwitcher = false
                        if viewModel.miniPlayerChannel == nil {
                            NebuloPlayerEngine.shared.stop()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            viewModel.scrollRestoreTrigger = UUID()
                        }
                    }, onPlayChannel: { newChannel in
                        playAction(newChannel)
                    }, onPlayRecording: { rec in
                        // Leave the live player entirely, then present the
                        // recording over home once it has dismissed.
                        selectedChannel = nil
                        showQuickSwitcher = false
                        if viewModel.miniPlayerChannel == nil {
                            NebuloPlayerEngine.shared.stop()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            selectedRecording = rec
                        }
                    }, showQuickSwitcher: $showQuickSwitcher)
                    .ignoresSafeArea()
                    // Transparent cover: while the player card is dragged
                    // down, the page underneath shows through instead of the
                    // cover's black backdrop.
                    .presentationBackground(.clear)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(categories: categories, accentColor: accentColor, viewModel: viewModel, scoreViewModel: scoreViewModel, playAction: playAction, onSave: { viewModel.saveCategorySettings() })
                    .presentationDragIndicator(.visible)
            }
            // A Live Activity deep link is about to present the stats sheet
            // from the root — anything covering it full-screen (the video
            // player, search, multi-view) must step aside first.
            .onReceive(NotificationCenter.default.publisher(for: .nebuloDeepLinkWillPresent)) { _ in
                if selectedChannel != nil {
                    selectedChannel = nil
                    showQuickSwitcher = false
                    if viewModel.miniPlayerChannel == nil {
                        NebuloPlayerEngine.shared.stop()
                    }
                }
                selectedRecording = nil
                showMultiView = false
                if showSearch {
                    searchQuery = ""
                    viewModel.searchText = ""
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { showSearch = false }
                }
            }
            .alert("No Streams Found", isPresented: showNoStreamsAlert) { Button("OK", role: .cancel) { } } message: { Text("No streams were found. Please search for the channel manually.") }
            .alert("Rename", isPresented: showRenameAlert) {
                TextField("New Name", text: $renameDraft)
                Button("Save") {
                    viewModel.confirmRename(with: renameDraft)
                }
                Button("Cancel", role: .cancel) {}
            }
            // Seed the field from whatever opened the alert (the channel's or
            // category's current name), once, as it appears.
            .onChangeCompat(of: viewModel.showRenameAlert) { showing in
                if showing { renameDraft = viewModel.renameInput }
            }
            .alert("Support Project", isPresented: $showSupportAlert) {
                Button("Donate") { if let url = URL(string: "https://buymeacoffee.com/mongoosemonke") { UIApplication.shared.open(url) } }
                Button("Join Discord") { if let url = URL(string: "https://discord.gg/QkBUjsGCJ2") { UIApplication.shared.open(url) } }
                Button("Don't Show Again") { showSupportPopup = false }
                Button("Close", role: .cancel) {}
            } message: { Text("This is a free, open-source project that is constantly being worked on. If you enjoy using it, please consider donating to support development!") }
    }
}

extension MainView {
    @ViewBuilder
    private func overlays(isL: Bool) -> some View {
        if showMultiView {
            MultiViewScreen(viewModel: viewModel, scoreViewModel: scoreViewModel, showMultiView: $showMultiView, accentColor: accentColor, onOpenSettings: { showSettings = true })
                // Slides in from the trailing edge, the way the detail pages
                // arrive, rather than fading over what is already there.
                .transition(.move(edge: .trailing))
                .zIndex(50)
        }

        if let miniChannel = viewModel.miniPlayerChannel, selectedChannel == nil { 
            VStack { 
                Spacer()
                HStack { 
                    Spacer()
                    MiniPlayerView(channel: miniChannel, viewModel: viewModel, onExpand: { 
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { 
                            // A minimised recording comes back as the
                            // recording player; `miniChannel` is only its
                            // file dressed up as a channel.
                            if let recording = viewModel.miniPlayerRecording {
                                selectedRecording = recording
                            } else {
                                selectedChannel = miniChannel
                            }
                            viewModel.miniPlayerChannel = nil 
                        } 
                    }, onClose: { 
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { 
                            viewModel.miniPlayerChannel = nil 
                        } 
                    })
                    .padding(.trailing, 20)
                    .padding(.bottom, shouldUseSidebar(isLandscape: isL) ? 20 : 100) 
                } 
            }
            .zIndex(15)
            // Apple-style: miniplayer rises into the corner with a gentle
            // scale-in, while the player view above is sliding off the bottom.
            // Two distinct motions in opposite directions read as one fluid
            // hand-off (same pattern as Apple Music's Now Playing → Mini bar).
            .transition(.asymmetric(
                insertion: .scale(scale: 0.7, anchor: .bottomTrailing).combined(with: .opacity),
                removal: .opacity
            ))
        }
        
        
        // Show a full blocking skeleton only on the very first cold load (no channels yet).
        // During EPG guide updates when channels are already available, show a non-blocking
        // pill indicator so the user can keep browsing.
        // EPGProgressBanner observes epgState directly so 10-fps progress ticks
        // never cause MainView or any channel list to re-render.
        // NOTE: the search overlay is presented via .fullScreenCover on the
        // MainView body, NOT here — presenting it inside this ZStack let the
        // keyboard-driven relayout of everything underneath animate across
        // the overlay as a full-screen sliding cover on open.

        let isInitialLoad = viewModel.isLoading
        if isInitialLoad || viewModel.isUpdatingEPG {
            EPGProgressBanner(
                epgState: viewModel.epgState,
                status: viewModel.loadingStatus,
                accentColor: accentColor,
                isBlocking: isInitialLoad,
                onDismiss: {
                    withAnimation {
                        viewModel.isLoading = false
                        viewModel.isUpdatingEPG = false
                    }
                }
            )
            .transition(.opacity)
            .zIndex(100)
        }
    }
    
    func playChannel(_ channel: StreamChannel) { 
        hideKeyboard()
        if viewModel.multiViewModeActive { 
            viewModel.addToMultiView(channel)
            viewModel.multiViewModeActive = false
            withAnimation(MainView.multiViewSlide) { showMultiView = true } 
        } else { 
            viewModel.addToRecent(channel.id)
            viewModel.lastPlayedChannelID = channel.id
            viewModel.lastSourceCategory = selectedCategory
            selectedChannel = channel

        } 
    }
    // Automatic must NOT flip to the sidebar layout on device rotation: the
    // home UI is portrait-only, and swapping the layout branch while a video
    // is fullscreen-landscape tears down whatever that branch is presenting
    // (the recordings player fullScreenCover dismissed itself mid-rotation).
    func shouldUseSidebar(isLandscape: Bool) -> Bool { if selectedCategory?.id == -3 { return false }; switch ViewMode(rawValue: viewMode) ?? .automatic { case .automatic: return false; case .sidebar: return true; case .standard: return false } }
}

struct StandardLayout: SwiftUI.View {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Binding var selectedCategory: StreamCategory?; @Binding var selectedChannel: StreamChannel?; @Binding var searchText: String
    let accentColor: Color; let playAction: (StreamChannel) -> Void; @Binding var showMultiView: Bool; @Binding var showSettings: Bool
    @Binding var selectedRecording: Recording?
    var zoomNS: Namespace.ID? = nil
    /// True while the Search section is showing over this layout. The results
    /// list below (`searchView`) predates that section and is what the SIDEBAR
    /// layout still uses; under the overlay it was being built and drawn for
    /// nothing — glass cards and blurred thumbnails for every hit, behind an
    /// opaque page — on every keystroke.
    var searchOverlayOpen: Bool = false

    /// Push/pop tempo for DRILL-DOWNS (open a category, Recently Watched,
    /// Recordings, and the way back). Tab switches deliberately don't use it —
    /// see the note on the missing implicit animation at the end of `body`.
    static let pageAnimation: Animation = .easeOut(duration: DetailRouter.travel)

    /// When `false` the active detail view doesn't intercept touches.
    /// Set to `false` the moment a back navigation fires so the departing
    /// view (still visible at opacity > 0 during its blurFade removal
    /// transition) can't block taps on the Quick Access buttons beneath it.
    /// Automatically reset to `true` whenever a new category is selected.
    @State private var isDetailInteractive: Bool = true
    /// Home is the visible screen: no section open and not showing results.
    private var homeVisible: Bool { searchText.isEmpty && selectedCategory == nil }

    // groupedCategories is cheap (O(categories) ≈ few hundred) but still
    // cached so the ForEach never re-evaluates on every viewModel publish.
    @State private var cachedGrouped: [(HomeCategoryGroup, [StreamCategory])] = []
    /// `cachedGrouped` flattened into shelf order. Derived alongside it rather
    /// than in the body, so scrolling never re-runs the flatMap.
    @State private var shelfCategories: [StreamCategory] = []

    /// Selected chip filter at the top of the home screen.
    /// `nil` means "For You" (default mixed view).
    @State private var selectedHomeGroup: HomeCategoryGroup? = nil

    // ── Cached lookups ───────────────────────────────────────────────────
    // Recomputing these on every body render burns frames and produces a hot
    // device. They're populated once via `.task(id:)` modifiers below and
    // refreshed only when their inputs actually change.

    /// O(1) lookup from channel id → StreamChannel. Used by Continue Watching
    /// (`recentIDs` resolution) instead of `first(where:)` which is O(n*m).
    @State private var idToChannel: [Int: StreamChannel] = [:]

    /// Featured carousel content for the active chip — cached to avoid
    /// rebuilding the category Dictionary on every render.
    @State private var cachedDisplayedFeatured: [FeaturedItem] = []

    /// Continue Watching channel objects, resolved from `recentIDs` once.
    @State private var cachedRecent: [StreamChannel] = []

    /// Channels grouped per category for the home shelves — capped per shelf
    /// so a giant playlist can't flood the home page. Rebuilt only when the
    /// channel list or hidden set actually changes.
    @State private var channelsByCategory: [Int: [StreamChannel]] = [:]

    private var categoryShelfCacheKey: String {
        // channelRevision included because a rename changes a channel's NAME
        // without changing how many there are — and these shelves hold copies
        // of the structs, so without it they keep rendering the old name.
        "\(viewModel.channels.count)|\(viewModel.hiddenIDs.count)|\(viewModel.channelRevision)"
    }

    private func computeChannelsByCategory() -> [Int: [StreamChannel]] {
        var dict: [Int: [StreamChannel]] = [:]
        for c in viewModel.channels {
            if viewModel.hiddenIDs.contains(c.id) { continue }
            if dict[c.categoryID, default: []].count < 10 {
                dict[c.categoryID, default: []].append(c)
            }
        }
        return dict
    }

    /// Live games shelf content for the home page — cached snapshot.
    @State private var cachedHomeLiveGames: [ESPNEvent] = []

    /// Count of today's games that haven't started yet — drives the
    /// "M starting today" subtitle in the adaptive home header.
    @State private var startingTodayCount: Int = 0

    /// Favorite-team override for the adaptive header. When a favorited team
    /// is live or plays today, the header shows the matchup instead of the
    /// generic live counts — e.g. "White Sox at 7:10 PM" / "Today · vs Guardians".
    @State private var favHeader: (title: String, subtitle: String)? = nil

    /// Live-game count for the adaptive header, read from the cached snapshot.
    private var liveGameCount: Int { cachedHomeLiveGames.count }

    /// 0 at rest, 1 once the big header has fully scrolled past. Tracks the
    /// live scroll offset directly (no withAnimation) so the compact overlay
    /// crossfades in lockstep with the user's finger instead of snapping in
    /// after a fixed-duration animation once a threshold is crossed. Held in
    /// its own object (observed only by the two crossfading headers) so
    /// scrolling the home screen doesn't re-render its whole body each frame.
    @State private var homeHeaderProgress = ScrollProgress()

    /// Top-overscroll distance (rubber-band pull past the top). Drives the
    /// hero's stretch so no black gap ever opens above it.
    @State private var heroPull = ScrollProgress()

    /// Downward scroll distance, clamped to the hero's height. Drives the
    /// hero artwork's scroll parallax — Nuvio's `HERO_SCROLL_PARALLAX`.
    @State private var heroScroll = ScrollProgress()

    /// Channel tapped anywhere on the home screen. Opens the same preview
    /// popup a channel tap in a category does, rather than starting playback
    /// straight away.
    @State private var homePreviewChannel: StreamChannel?

    // ── My Teams shelf ───────────────────────────────────────────────────
    /// Resolved favourites, cached off the body: resolving them walks the
    /// whole team catalog, which must not happen on every render.
    @State private var cachedFavTeams: [(team: ESPNTeam, sport: SportType?, leagueLabel: String?)] = []
    @State private var cachedFavLeagues: [(sport: SportType, leagueLabel: String?, displayName: String)] = []

    /// Favourite teams, resolved on the spot for the same reason as the
    /// leagues below: through the cache, the shelf only changed when one of
    /// several `.task(id:)` writes fired, and those keys are COUNTS — removing
    /// one favourite and adding another leaves the count identical, so the
    /// shelf kept showing the old pair. Resolving here is a walk over a handful
    /// of ids and updates the moment a favourite changes.
    private var homeFavTeams: [(team: ESPNTeam, sport: SportType?, leagueLabel: String?)] {
        scoreViewModel.resolvedFavoriteTeams()
    }

    /// Favourite leagues, resolved on the spot rather than read from a cache.
    ///
    /// There are only ever a handful of them — the work is a map over a few
    /// keys — and going through `cachedFavLeagues` meant the shelf depended on
    /// one of several `.task(id:)` writes having fired first. The Favorites hub
    /// reads them directly and always showed them; home did not, and did not.
    private var homeFavLeagues: [(sport: SportType, leagueLabel: String?, displayName: String)] {
        scoreViewModel.resolvedFavoriteLeagues()
    }
    /// The interleaved body of the home page: category shelves in threes with
    /// a themed row of big cards between them. Rebuilt only when the shelves
    /// or the themed rows change.
    @State private var homeRows: [HomeRow] = []

    struct HomeRow: Identifiable {
        enum Kind {
            case category(StreamCategory)
            case spotlight(ChannelViewModel.SpotlightGroup)
        }
        let id: String
        let kind: Kind
    }


    /// Compact-title progress for the two mounted hubs, one each.
    ///
    /// These cannot share `sectionTitleProgress` with the sections that come
    /// and go. That one is reset to 0 on every tab change, and `.onPreferenceChange`
    /// only fires when its value CHANGES — a mounted hub's layout doesn't move
    /// while it is hidden, so returning to one scrolled past its big title left
    /// the progress at 0 with nothing to re-fire it, and the name was missing
    /// from the top of the screen entirely. Held per hub, the value persists
    /// alongside the scroll position it describes.
    @State private var sportsTitleProgress = ScrollProgress()
    @State private var favoritesTitleProgress = ScrollProgress()

    /// Which mounted hub is on screen, delivered as leaf boxes so switching
    /// tabs doesn't change either hub's inputs — see `SportsHubView.active`.
    @State private var sportsActive = FlagBox()
    @State private var favoritesActive = FlagBox()
    /// Home is the screen you are actually looking at. Home stays MOUNTED
    /// behind search results and category pages (it is faded to zero, not
    /// removed), so without this the hero kept counting down and sliding its
    /// full-screen artwork behind an invisible layer.
    ///
    /// Starts true — home IS the first screen, so the hero must not depend on
    /// an `onAppear` landing before its own countdown starts.
    @State private var homeActive = FlagBox(true)

    /// Drives the interactive back-swipe out of a category page or the search
    /// results, and the home screen's parallax behind it.
    @ObservedObject private var backSwipe = BackSwipeState.shared
    /// True while that swipe is in flight. Home is normally faded out whenever
    /// a page is over it; during the drag it has to be VISIBLE, because the
    /// whole point is watching it come in behind your finger.
    private var backSwipeActive: Bool { backSwipe.isActive }

    /// The hub the dock is currently on, or nil. Search hides a hub exactly as
    /// it hides home: the old chain put `searchView` ahead of the section, so
    /// opening search destroyed it.
    private var activeHubID: Int? { searchText.isEmpty ? selectedCategory?.id : nil }

    /// Tab sections that are built once and then kept alive, hidden, rather
    /// than rebuilt on every visit.
    private static let mountedHubIDs: Set<Int> = [-3, -4]

    /// The dock's own tabs: Sports, Favorites and Settings. Selecting one is a
    /// TAB SWITCH — instant, nothing slides. Everything else reached through
    /// `selectedCategory` is a drill-down that pushes in over the home screen
    /// and can be swiped back out of, exactly like a favourite team's page.
    private static let dockTabIDs: Set<Int> = [-3, -4, -6]

    static func isDrillDown(_ cat: StreamCategory) -> Bool {
        !dockTabIDs.contains(cat.id)
    }

    /// Hubs the user has actually opened. Nothing is built until its tab is
    /// chosen for the first time, so opening the app costs no more than before.
    @State private var visitedHubs: Set<Int> = []

    /// Sports and Favorites, mounted on first visit and hidden afterwards.
    ///
    /// Rebuilding one of these from scratch is a screen's worth of view
    /// construction, and it lands SYNCHRONOUSLY on the frame the dock is
    /// animating — which is what the bar was stuttering through. Kept mounted,
    /// every visit after the first has almost nothing to build. They sit below
    /// home in z-order while hidden, and their reactive work is gated by
    /// `isActive` so an off-screen hub is not filtering on every keystroke or
    /// driving a spinner nobody can see.
    @ViewBuilder
    private var persistentHubs: some View {
        // `visitedHubs` is written from an onChange, which lands AFTER the
        // render that selected the tab — so the active hub has to count as
        // mounted here too, or its first appearance is a blank frame.
        let activeID = activeHubID
        if visitedHubs.contains(-3) || activeID == -3 {
            let isActive = activeID == -3
            // Wrapped so a parent re-render does NOT re-evaluate this screen.
            // Everything the hub needs from out here is either an object it
            // observes itself or a leaf box it reads, so the only input that
            // can genuinely change it is the accent colour — which is the key.
            //
            // Without this, mounting made switching WORSE: the closures below
            // are new values on every render, SwiftUI cannot prove the view
            // unchanged, and both hubs had their whole bodies re-evaluated on
            // every tab change on top of home's.
            StableSubtree(key: accentColor) {
                SportsHubView(viewModel: viewModel,
                              accentColor: accentColor,
                              playAction: playAction,
                              onBack: handleBackNavigation,
                              scoreViewModel: scoreViewModel,
                              titleProgress: sportsTitleProgress,
                              active: sportsActive)
            }
            .equatable()
            // Chrome, preference reading and visibility all sit OUTSIDE the
            // memo, so they keep updating while the screen itself holds still.
            .safeAreaInset(edge: .top, spacing: 0) {
                sectionChromeRow(for: StreamCategory(id: -3, name: "Sports"),
                                 titleProgress: sportsTitleProgress)
            }
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive && isDetailInteractive)
            .zIndex(isActive ? 1 : -1)
        }
        if visitedHubs.contains(-4) || activeID == -4 {
            let isActive = activeID == -4
            StableSubtree(key: accentColor) {
                FavoritesView(viewModel: viewModel,
                              scoreViewModel: scoreViewModel,
                              accentColor: accentColor,
                              playAction: playAction,
                              onBack: handleBackNavigation,
                              titleProgress: favoritesTitleProgress)
            }
            .equatable()
            // Chrome, preference reading and visibility all sit OUTSIDE the
            // memo, so they keep updating while the screen itself holds still.
            .safeAreaInset(edge: .top, spacing: 0) {
                sectionChromeRow(for: StreamCategory(id: -4, name: "Favorites"),
                                 titleProgress: favoritesTitleProgress)
            }
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive && isDetailInteractive)
            .zIndex(isActive ? 1 : -1)
        }
    }

    /// The chrome row over a section: the back chevron on drill-down pages,
    /// and the compact title that crossfades in as the big in-scroll one
    /// departs. Shared by the sections that come and go and by the two hubs
    /// that now stay mounted, so there is one definition of this row.
    @ViewBuilder
    private func sectionChromeRow(for cat: StreamCategory,
                                  titleProgress: ScrollProgress) -> some View {
            // Nuvio chrome: drill-down pages (plain categories,
            // Recently Watched, Recordings) get the reference
            // catalog page's circular back chevron + centred title.
            // The hub TABS (Sports, Favorites) have no back button —
            // the dock owns navigation — just the compact title that
            // crossfades in as their big in-scroll title departs.
            HStack {
                if cat.id != -3 && cat.id != -4 && cat.id != -6 {
                    NuvioCircleButton(systemName: "chevron.left") {
                        viewModel.triggerSelectionHaptic()
                        handleBackNavigation()
                    }
                }
                Spacer()
            }
            // The row must RESERVE the compact title's height even on
            // the hub tabs, which have no back button. Without this the
            // row was only as tall as its 8pt padding, the safe-area
            // inset reserved almost nothing, and the title — drawn in
            // an overlay, which doesn't contribute height — spilled
            // over the pinned chip row beneath it. That's what read as
            // the scrunched, overlapping compact header on Sports and
            // Favorites. 40pt is the circular back button's size, so
            // drill-down pages keep it; the hub tabs have no button to clear
            // and only need to fit their two-line compact title, which is
            // about 31pt, so they run tighter.
            .frame(height: Self.chromeRowHeight(for: cat))
            .overlay {
                if cat.id >= 0 || cat.id == -2 {
                    Text(cat.name)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    .padding(.horizontal, 64)
                } else if cat.id == -3 || cat.id == -4 || cat.id == -5 || cat.id == -6 {
                    // Hub sections: the compact title crossfades in
                    // as the big in-scroll title departs — pure
                    // opacity, no layout shift, so the transition
                    // stays perfectly smooth.
                    VStack(spacing: 0) {
                        Text(cat.name)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                        if let detail = sectionChromeDetail(for: cat) {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 64)
                    .scrollProgressOpacity(titleProgress) { Double($0) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, Self.chromeRowHeight(for: cat) < 40 ? 2 : 4)
    }

    /// Row height by section. The hub tabs draw no back button, so they only
    /// have to clear the compact title itself.
    private static func chromeRowHeight(for cat: StreamCategory) -> CGFloat {
        (cat.id == -3 || cat.id == -4 || cat.id == -6) ? 32 : 40
    }

    /// The loading state, laid out to the same measurements as the real home
    /// screen so nothing shifts when the content lands.
    ///
    /// Every number here is read from the thing it stands in for — the hero's
    /// own height, each card type's own `cardWidth`/`cardHeight` — rather than
    /// approximated, so the two cannot drift apart as those change. The order
    /// is the page's order too: hero, Continue Watching, Live Now, Favorites,
    /// then category shelves with a row of big cards among them.
    private var homeSkeleton: some SwiftUI.View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                // Hero — full bleed, dots OVER the artwork rather than below
                // it, which is where the carousel draws them.
                SkeletonBox(height: FeaturedCarousel.heroHeight, cornerRadius: 0)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottom) {
                        HStack(spacing: 8) {
                            ForEach(0..<4, id: \.self) { i in
                                SkeletonBox(width: i == 0 ? 26 : 7, height: 7, cornerRadius: 4)
                            }
                        }
                        .padding(.bottom, 14)
                    }

                skeletonShelf(titleWidth: 210,
                              cardWidth: ContinueWatchingCard.cardWidth,
                              cardHeight: ContinueWatchingCard.cardHeight,
                              cornerRadius: 12, spacing: 14)

                skeletonShelf(titleWidth: 120,
                              cardWidth: LiveGameCard.cardWidth,
                              cardHeight: LiveGameCard.cardHeight,
                              cornerRadius: 16, spacing: 12)

                skeletonShelf(titleWidth: 140,
                              cardWidth: FavoriteBadge.cardWidth,
                              cardHeight: FavoriteBadge.cardHeight,
                              cornerRadius: 12, spacing: 16)

                skeletonShelf(titleWidth: 160,
                              cardWidth: HorizontalChannelCardArt.cardWidth,
                              cardHeight: HorizontalChannelCardArt.cardHeight,
                              cornerRadius: 12, spacing: 10)

                // A row of big cards, which the page interleaves between the
                // category shelves.
                VStack(alignment: .leading, spacing: 14) {
                    SkeletonBox(width: 150, height: 24).padding(.horizontal, 20)
                    SkeletonBox(width: SpotlightCard.cardWidth,
                                height: SpotlightCard.cardHeight,
                                cornerRadius: 18)
                        .padding(.horizontal, 20)
                        .frame(width: Self.screenWidth, alignment: .leading)
                        .clipped()
                }

                skeletonShelf(titleWidth: 130,
                              cardWidth: HorizontalChannelCardArt.cardWidth,
                              cardHeight: HorizontalChannelCardArt.cardHeight,
                              cornerRadius: 12, spacing: 10)
            }
            .padding(.bottom, 120)
            .frame(width: Self.screenWidth, alignment: .leading)
        }
        // The hero bleeds behind the status bar, exactly as the loaded one does.
        .ignoresSafeArea(.container, edges: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// One shelf: the section header, then a row of cards at that shelf's own
    /// size. Static — a skeleton never scrolls, so there is no scroll view to
    /// pay for; the row is simply clipped at the screen edge like the real one.
    private func skeletonShelf(titleWidth: CGFloat,
                               cardWidth: CGFloat,
                               cardHeight: CGFloat,
                               cornerRadius: CGFloat,
                               spacing: CGFloat) -> some SwiftUI.View {
        VStack(alignment: .leading, spacing: 14) {
            // 24pt is the section title's own line height at 22pt bold.
            SkeletonBox(width: titleWidth, height: 24).padding(.horizontal)
            HStack(spacing: spacing) {
                ForEach(0..<5, id: \.self) { _ in
                    SkeletonBox(width: cardWidth, height: cardHeight, cornerRadius: cornerRadius)
                }
            }
            .padding(.horizontal)
            // Pinned to the screen's width and clipped there. Five full-size
            // cards are much wider than the screen, and left to itself that row
            // widens the enclosing scroll view's CONTENT — every sibling then
            // lays out at that width too, which is what blew the whole skeleton
            // up and pushed the bar off the bottom.
            .frame(width: Self.screenWidth, alignment: .leading)
            .clipped()
        }
        .frame(width: Self.screenWidth, alignment: .leading)
    }

    private static var screenWidth: CGFloat { UIScreen.main.bounds.width }

    /// Promotes the logos home is about to draw into the memory image cache,
    /// off the main thread.
    ///
    /// `ImageLoader` only consults memory during view construction now (see
    /// the note there), so without this a card scrolling into view for the
    /// first time in a session would show its placeholder for a frame or two
    /// while the disk decode ran. Warming the shelves in the background keeps
    /// the first paint exactly as it was, with none of the main-thread cost.
    private func warmHomeArtwork() {
        // The order shelves are drawn in, so the ones nearest the top of the
        // page are resident first.
        var icons: [String] = cachedRecent.compactMap(\.icon)
        for row in homeRows {
            guard case let .category(cat) = row.kind,
                  let channels = channelsByCategory[cat.id] else { continue }
            icons.append(contentsOf: channels.prefix(12).compactMap(\.icon))
        }
        ImageCache.prewarm(icons)
    }

    /// Opens a featured hero page's destination: a live matchup goes to its
    /// game card, a plain channel to the channel preview popup.
    private func openFeatured(_ item: FeaturedItem) {
        if let game = item.game {
            let sport = scoreViewModel.sportType(for: game)
            if sport == .f1 {
                scoreViewModel.presentRaceCard(game)
            } else if sport == .golf {
                scoreViewModel.presentGolfCard(game)
            } else {
                scoreViewModel.deepLinkRequest = scoreViewModel.makeDetailRequest(for: game, sport: sport)
            }
        } else {
            homePreviewChannel = item.channel
        }
    }

    /// Same idea for the hub sections (Sports/Favorites/Recordings): their
    /// scroll probes bubble up via preference, and this drives the compact
    /// title shown in the chrome row between the Back pill and the gear.
    /// Scoped the same way so scrolling a hub doesn't re-render this layout
    /// (which would in turn re-render the whole hub view inside it).
    @State private var sectionTitleProgress = ScrollProgress()
    /// 0 at the top, 1 once the search results scroll — reveals the vignette.
    @State private var searchHeaderProgress: CGFloat = 0

    /// One-line info shown under the compact chrome title for hubs.
    private func sectionChromeDetail(for cat: StreamCategory) -> String? {
        switch cat.id {
        case -3:
            return "\(scoreViewModel.allLiveGames.count) live"
        case -4:
            let c = viewModel.favoriteIDs.count
            let t = scoreViewModel.favoriteTeamIDs.count
            return "\(c) channel\(c == 1 ? "" : "s") · \(t) team\(t == 1 ? "" : "s")"
        default:
            return nil
        }
    }

    private static let headerTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// Walks the user's favorite teams (in their chosen order) and returns the
    /// header override: a live favorite game wins; otherwise the first favorite
    /// with a game later today. Returns nil when no favorite plays today.
    private func computeFavoriteHeader() -> (title: String, subtitle: String)? {
        let ids = scoreViewModel.favoriteTeamOrder.filter { scoreViewModel.favoriteTeamIDs.contains($0) }
            + scoreViewModel.favoriteTeamIDs.subtracting(scoreViewModel.favoriteTeamOrder).sorted()
        guard !ids.isEmpty else { return nil }

        let cal = Calendar.current
        var todayResult: (title: String, subtitle: String)? = nil

        for id in ids {
            guard let game = scoreViewModel.liveOrNextGame(forTeamID: id) else { continue }
            let isHome = game.homeCompetitor?.team?.id == id
            let mine = isHome ? game.homeCompetitor : game.awayCompetitor
            let opp  = isHome ? game.awayCompetitor : game.homeCompetitor
            guard let myName = mine?.team?.shortDisplayName ?? mine?.team?.displayName else { continue }
            let oppName = opp?.team?.shortDisplayName ?? opp?.team?.displayName ?? ""

            switch game.status.type.state {
            case "in":
                // Live favorite game — top priority, return immediately.
                let myScore = mine?.score ?? "0"
                let oppScore = opp?.score ?? "0"
                return (title: "\(myName) \(myScore)–\(oppScore)",
                        subtitle: "LIVE · vs \(oppName)")
            case "pre" where cal.isDateInToday(game.gameDate):
                if todayResult == nil {
                    let time = Self.headerTimeFormatter.string(from: game.gameDate)
                    todayResult = (title: "\(myName) at \(time)",
                                   subtitle: "Today · vs \(oppName)")
                }
            default:
                break
            }
        }
        return todayResult
    }

    /// Recompute the "starting today" count: today's games still in the
    /// pre-game state. Walks the cached score maps once, off the body.
    private func computeStartingToday() -> Int {
        let cal = Calendar.current
        var ids = Set<String>()
        for games in scoreViewModel.filteredGames.values {
            for g in games where g.status.type.state == "pre" && cal.isDateInToday(g.gameDate) {
                ids.insert(g.id)
            }
        }
        for sections in scoreViewModel.filteredSectionsMap.values {
            for s in sections {
                for g in s.games where g.status.type.state == "pre" && cal.isDateInToday(g.gameDate) {
                    ids.insert(g.id)
                }
            }
        }
        return ids.count
    }

    var body: some SwiftUI.View {
        ZStack(alignment: .bottom) {
            if viewModel.isLoading {
                homeSkeleton
            } else if !searchText.isEmpty, !searchOverlayOpen {
                searchView
                    .modifier(SwipeBackModifier(
                        onBack: {
                            // Removed with animation OFF for the same reason
                            // the category page is: the swipe has already
                            // carried it off-screen, so a removal animation
                            // has nowhere to travel and only gives the page a
                            // chance to flash back over the screen.
                            var t = Transaction()
                            t.disablesAnimations = true
                            withTransaction(t) { searchText = "" }
                        },
                        state: backSwipe,
                        onDragChange: { backSwipe.isActive = $0 }
                    ))
                    .zIndex(2)
            } else if let cat = selectedCategory, !Self.mountedHubIDs.contains(cat.id) {
                // `.allowsHitTesting(isDetailInteractive)` is the key fix for
                // Quick Access buttons becoming unresponsive after navigation.
                // During the blurFade removal animation the departing view stays
                // in the hierarchy at opacity > 0, which normally lets it swallow
                // taps meant for the home screen below. Setting this to `false`
                // (via handleBackNavigation) before the animation starts removes
                // `userInteractionEnabled` from UIKit so the home screen is
                // immediately tappable the moment the user navigates back.
                Group {
                    // The hub TABS have no swipe-back: each section is its
                    // own place — you're in it or you're not, and the dock
                    // is the only way between them.
                    // Sports and Favorites are NOT here — they are mounted
                    // once and kept (see `persistentHubs`).
                    if cat.id == -5 {
                        RecordingsView(viewModel: viewModel, playAction: playAction, onBack: handleBackNavigation)
                            .transition(.opacity)
                    } else if cat.id == -6 {
                        // Settings is a real SECTION now (Profile tab) —
                        // in-hierarchy with the bar visible, crossfading
                        // exactly like the other tabs.
                        SettingsView(
                            categories: Binding(
                                get: { viewModel.categories },
                                set: { viewModel.categories = $0 }
                            ),
                            accentColor: accentColor,
                            viewModel: viewModel,
                            scoreViewModel: scoreViewModel,
                            playAction: playAction,
                            onSave: { viewModel.saveCategorySettings() },
                            isSection: true,
                            openMultiView: { withAnimation(MainView.multiViewSlide) { showMultiView = true } }
                        )
                        .transition(.opacity)
                    } else {
                        CategoryDetailView(title: cat.name, channels: getChannelsToShow(for: cat), accentColor: accentColor, playAction: playAction, toggleFav: viewModel.toggleFavorite, promptRename: viewModel.triggerRenameChannel, hideChannel: viewModel.hideChannel, favoriteIDs: viewModel.favoriteIDs, viewModel: viewModel, showMultiView: $showMultiView, onBack: handleBackNavigation, onCategorySelect: { cat in withAnimation(Self.pageAnimation) { selectedCategory = cat; searchText = "" } }, zoomNS: zoomNS)
                    }
                }
                // The hubs publish their scroll offset via preference (the
                // probe rides on each big title). Reading it here lets the
                // chrome row itself host the compact title — level with the
                // Back pill and gear — instead of a separate bar below them.
                .onPreferenceChange(SectionScrollOffsetsKey.self) { offsets in
                    let key: String? = cat.id == -3 ? "sports" : cat.id == -4 ? "fav" : cat.id == -5 ? "rec" : cat.id == -6 ? "settings" : nil
                    guard let key, let y = offsets[key] else { return }
                    sectionTitleProgress.set(min(max(-y / 40, 0), 1))
                }
                // Static chrome row: the Back pill (and, for plain categories,
                // a centred title) lives OUTSIDE the transition group so it
                // appears instantly — no slide-in — while the section content
                // blur-fades beneath it. The system nav bar is permanently
                // hidden (see MainViewModifiers), so this is the only chrome.
                .safeAreaInset(edge: .top, spacing: 0) {
                    sectionChromeRow(for: cat, titleProgress: sectionTitleProgress)
                }
                // OUTSIDE the chrome inset on purpose: the swipe has to carry
                // the Back pill and the category's name off with the page.
                // Applied to the content alone, the title sat there unmoved
                // until the page had gone and then vanished on its own.
                //
                // Settings is a dock tab rather than a drill-down, so it has
                // nowhere to swipe back to.
                .modifier(SwipeBackModifier(
                    onBack: handleSwipeBackNavigation,
                    isEnabled: cat.id != -6,
                    state: backSwipe,
                    onDragChange: { backSwipe.isActive = $0 }
                ))
                // On the OUTERMOST layer, because this is what actually gets
                // inserted and removed — the page, its chrome row and the
                // swipe wrapper together.
                //
                // With the transition on the page alone, the container around
                // it fell back to SwiftUI's default, which is `.opacity`: the
                // page slid in while everything wrapping it faded, which is
                // the fade-and-slide that looked wrong. One transition on the
                // whole thing makes it a single push, the same as a detail
                // page. Settings is a dock tab rather than a drill-down, so it
                // keeps the crossfade the other tabs use.
                .transition(Self.isDrillDown(cat)
                            ? AnyTransition.move(edge: .trailing)
                            : AnyTransition.opacity)
                .allowsHitTesting(isDetailInteractive)
                .zIndex(1)
            }

            persistentHubs

            // Home stays MOUNTED (hidden) underneath every section instead of
            // being torn down: recreating the ScrollView reset its offset, so
            // returning from a section always snapped back to the top. It
            // sits at zIndex 0 below the section overlays, with opacity and
            // hit-testing gated while a section is open.
            if !viewModel.isLoading {
                ScrollView(showsIndicators: false) {
                    // NOTE: the GlassEffectContainer used to wrap this ENTIRE
                    // stack. Nuvio's home list has no glass in it at all, and a
                    // container spanning the whole scrolling page has to track
                    // and coordinate glass geometry across every frame of a
                    // scroll — for the sake of the two Quick Access buttons,
                    // which are the only glass on the screen. The container now
                    // wraps just those two (see below), so the shelves scroll
                    // as cheaply as the solid-fill Favorites and Sports pages.
                    VStack(alignment: .leading, spacing: 30) {

                            // 1. Full-bleed hero carousel — the artwork bleeds
                            //    behind the status bar exactly like the
                            //    reference recording. Uses the cached snapshot;
                            //    updated by the `.task` modifiers below whenever
                            //    the chip selection or underlying featured list
                            //    changes. When a favorite team is live, the
                            //    channel broadcasting their game leads.
                            if !cachedDisplayedFeatured.isEmpty {
                                FeaturedCarousel(
                                    items: cachedDisplayedFeatured,
                                    viewModel: viewModel,
                                    accentColor: accentColor,
                                    openAction: openFeatured,
                                    scroll: heroScroll,
                                    visible: homeActive
                                )
                                .id(selectedHomeGroup?.rawValue ?? "for-you")
                                // Rubber-banding past the top stretches the
                                // hero from its bottom edge, so the artwork
                                // keeps covering the screen instead of
                                // revealing black above it.
                                .modifier(HeroStretch(pull: heroPull,
                                                      height: FeaturedCarousel.heroHeight))
                            } else {
                                // No featured content — clear the (ignored)
                                // top safe area so the chips don't sit under
                                // the status bar.
                                Color.clear.frame(height: 52)
                            }

                            // 2. Continue Watching shelf — uses cached resolved channels
                            //    instead of `first(where:)` per recent id (O(n*m) → O(n)).
                            if !cachedRecent.isEmpty {
                                VStack(alignment: .leading, spacing: 14) {
                                    NuvioSectionHeader(
                                        title: "Continue Watching",
                                        showsChevron: true
                                    ) {
                                        viewModel.lastSelectedHomeID = -2
                                        withAnimation(Self.pageAnimation) { selectedCategory = StreamCategory(id: -2, name: "Recently Watched") }
                                    }

                                    HorizontalPreviewList(
                                        channels: cachedRecent,
                                        isRecent: true,
                                        accentColor: accentColor,
                                        viewModel: viewModel,
                                        playAction: playAction,
                                        promptRenameChannel: viewModel.triggerRenameChannel,
                                        hideChannel: viewModel.hideChannel,
                                        removeFromRecent: viewModel.removeFromRecent,
                                        onSelect: { homePreviewChannel = $0 }
                                    )
                                }
                            }

                            // 3. Quick Access is GONE from here. Recordings and
                            //    Multi-View are utilities, not things to
                            //    browse, and they read as clutter between the
                            //    shelves — both now live as rows in the Profile
                            //    tab alongside the other library tools.

                            // 6. Below the favourites:
                            //    • "For You" view → "Live Now" sports games shelf, then all
                            //      genre category shelves.
                            //    • Specific chip selected → only the subcategory shelves
                            //      that belong to that chip's group.
                            if selectedHomeGroup == nil && !cachedHomeLiveGames.isEmpty {
                                // Live Now shelf — uses cached snapshot of live games to
                                // avoid the O(games × sports) walk on every render.
                                VStack(alignment: .leading, spacing: 14) {
                                    NuvioSectionHeader(
                                        title: "Live Now",
                                        showsChevron: true
                                    ) {
                                        viewModel.lastSelectedHomeID = -3
                                        withAnimation(Self.pageAnimation) { selectedCategory = StreamCategory(id: -3, name: "Sports") }
                                    }

                                    LiveGamesPreviewList(
                                        games: cachedHomeLiveGames,
                                        scoreViewModel: scoreViewModel,
                                        viewModel: viewModel,
                                        accentColor: accentColor
                                    )
                                }
                            }

                            // 4. Favorites — every favourited team and league
                            //    as a poster tile. A team opens the full team
                            //    page; a league opens its own page.
                            if selectedHomeGroup == nil && !(homeFavTeams.isEmpty && homeFavLeagues.isEmpty) {
                                VStack(alignment: .leading, spacing: 14) {
                                    NuvioSectionHeader(
                                        title: "Favorites",
                                        showsChevron: true
                                    ) {
                                        viewModel.lastSelectedHomeID = -4
                                        withAnimation(Self.pageAnimation) { selectedCategory = StreamCategory(id: -4, name: "Favorites") }
                                    }

                                    FavoriteTeamsShelf(
                                        teams: homeFavTeams,
                                        leagues: homeFavLeagues,
                                        onTeam: { team, sport, league in
                                            DetailRouter.shared.open(.team(team: team, sport: sport, leagueLabel: league))
                                        },
                                        onLeague: { sport, label, name in
                                            DetailRouter.shared.open(.league(sport: sport, leagueLabel: label, displayName: name))
                                        }
                                    )
                                }
                            }

                            // 5. The rest of the page: category shelves in
                            //    threes, with a row of BIG cards after each
                            //    three, until the themed rows run out — then
                            //    the remaining categories run on uninterrupted.
                            //    Lazy so off-screen rows never build.
                            LazyVStack(alignment: .leading, spacing: 30) {
                                ForEach(homeRows) { row in
                                    switch row.kind {
                                    case .category(let cat):
                                        if let chans = channelsByCategory[cat.id], !chans.isEmpty {
                                            HomeCategoryShelf(
                                                category: cat,
                                                channels: chans,
                                                viewModel: viewModel,
                                                playAction: playAction,
                                                onSelect: { homePreviewChannel = $0 },
                                                openCategory: {
                                                    viewModel.lastSelectedHomeID = cat.id
                                                    withAnimation(Self.pageAnimation) { selectedCategory = cat }
                                                },
                                                promptRename: { viewModel.triggerRenameCategory(cat) }
                                            )
                                        }
                                    case .spotlight(let group):
                                        VStack(alignment: .leading, spacing: 14) {
                                            NuvioSectionHeader(title: group.title, inset: 20)
                                            SpotlightShelf(
                                                items: spotlightItems(for: group),
                                                viewModel: viewModel,
                                                onSelect: { homePreviewChannel = $0 }
                                            )
                                        }
                                    }
                                }
                            }

                        }
                        // Clearance for the floating dock: content scrolls
                        // behind the translucent slab, but the last row can
                        // still be pulled fully above it.
                        .padding(.bottom, 118)
                    }
                    // The hero bleeds behind the status bar — the scroll
                    // content owns the full screen height.
                    .ignoresSafeArea(.container, edges: .top)
                    .onAppear {
                        // Populate every cache synchronously so the first
                        // frame of the home screen has the carousel, recent
                        // channels and live games already in place — no
                        // flicker / empty state on appear.
                        if cachedGrouped.isEmpty { setGroupedCategories(groupedCategories) }
                        if idToChannel.isEmpty {
                            var map = [Int: StreamChannel]()
                            map.reserveCapacity(viewModel.channels.count)
                            for c in viewModel.channels { map[c.id] = c }
                            idToChannel = map
                        }
                        if cachedDisplayedFeatured.isEmpty {
                            cachedDisplayedFeatured = computeDisplayedFeatured()
                        }
                        if cachedRecent.isEmpty {
                            cachedRecent = viewModel.recentIDs.compactMap { idToChannel[$0] }
                        }
                        if channelsByCategory.isEmpty {
                            channelsByCategory = computeChannelsByCategory()
                        }
                        if cachedHomeLiveGames.isEmpty {
                            cachedHomeLiveGames = scoreViewModel.allLiveGames
                        }
                        startingTodayCount = computeStartingToday()
                        favHeader = computeFavoriteHeader()
                        if homeRows.isEmpty { homeRows = computeHomeRows() }
                        // Favourites were only filled in by the tasks below, so
                        // the shelf — leagues included — was missing from the
                        // very first render of the page.
                        if cachedFavTeams.isEmpty { cachedFavTeams = scoreViewModel.resolvedFavoriteTeams() }
                        if cachedFavLeagues.isEmpty { cachedFavLeagues = scoreViewModel.resolvedFavoriteLeagues() }

                        viewModel.lastSelectedHomeID = nil
                    }
                    // ── Cache refresh tasks ──────────────────────────────
                    // Each `.task(id:)` only re-fires when its key actually
                    // changes. Without these, the body would do all of these
                    // computations on every viewModel/scoreViewModel publish.
                    .task(id: viewModel.categories.count) {
                        setGroupedCategories(groupedCategories)
                    }
                    // A rename changes a name but not the count, so refresh the
                    // cached shelves on the rename signal too — otherwise the
                    // new name only showed after a relaunch.
                    //
                    // `homeRows` has to be rebuilt HERE, in the same task, not
                    // left to the spotlight/shelf-count task below: that task's
                    // key is built from two counts, and a rename changes
                    // neither, so it never re-fired. The rows kept the
                    // StreamCategory values captured when they were first
                    // built, and every shelf header went on drawing the old
                    // name no matter how many times shelfCategories refreshed.
                    // Doing both here also fixes the ordering — computeHomeRows
                    // reads shelfCategories, so it must run after
                    // setGroupedCategories, which two independent tasks could
                    // not guarantee.
                    .task(id: viewModel.categoryRevision) {
                        setGroupedCategories(groupedCategories)
                        homeRows = computeHomeRows()
                    }
                    .task(id: "\(viewModel.channels.count)-\(viewModel.channelRevision)") {
                        // Build the id → channel lookup. Done off the body so
                        // recent/featured filtering can use O(1) lookups.
                        var map = [Int: StreamChannel]()
                        map.reserveCapacity(viewModel.channels.count)
                        for c in viewModel.channels { map[c.id] = c }
                        idToChannel = map
                    }
                    .task(id: featuredCacheKey) {
                        cachedDisplayedFeatured = computeDisplayedFeatured()
                    }
                    // The themed rows land from a background task after the
                    // first render, so rebuild the page when they do — and
                    // whenever the category shelves themselves change.
                    .task(id: "\(viewModel.spotlightGroups.count)-\(shelfCategories.count)") {
                        homeRows = computeHomeRows()
                    }
                    // Reordering the sections in Settings has to show up here
                    // without a relaunch.
                    .task(id: viewModel.homeRowOrder) {
                        homeRows = computeHomeRows()
                        warmHomeArtwork()
                    }
                    .task(id: categoryShelfCacheKey) {
                        channelsByCategory = computeChannelsByCategory()
                        warmHomeArtwork()
                    }
                    .task(id: recentCacheKey) {
                        cachedRecent = viewModel.recentIDs.compactMap { idToChannel[$0] }
                        warmHomeArtwork()
                    }
                    .task(id: scoreViewModel.allLiveGameIDsKey) {
                        cachedHomeLiveGames = scoreViewModel.allLiveGames
                        startingTodayCount = computeStartingToday()
                        favHeader = computeFavoriteHeader()
                        // The catalog these resolve against streams in with the
                        // scores, so refresh the crests on the same signal.
                        cachedFavTeams = scoreViewModel.resolvedFavoriteTeams()
                        cachedFavLeagues = scoreViewModel.resolvedFavoriteLeagues()
                    }
                    // Adding or removing a favourite has to show up immediately,
                    // not on the next score refresh.
                    .task(id: "\(scoreViewModel.favoriteTeamIDs.count)-\(scoreViewModel.favoriteLeagueKeys.count)") {
                        cachedFavTeams = scoreViewModel.resolvedFavoriteTeams()
                        cachedFavLeagues = scoreViewModel.resolvedFavoriteLeagues()
                        // A favourite that will not resolve means the cached
                        // team catalog is missing its league — rebuild it now
                        // rather than let the badge sit blank for a week.
                        scoreViewModel.refreshCatalogIfFavoritesUnresolved()
                    }
                    // Header counts depend on the score maps, which stream in
                    // sport-by-sport after launch. `filteredGames.count` bumps
                    // as each sport lands, so the "N starting today" number and
                    // the favorite-team headline fill in without needing a
                    // live-set change to trigger them.
                    .task(id: scoreViewModel.filteredGames.count) {
                        startingTodayCount = computeStartingToday()
                        favHeader = computeFavoriteHeader()
                    }
                    .task(id: scoreViewModel.favoriteTeamIDs) {
                        favHeader = computeFavoriteHeader()
                    }
                    // Read the scroll offset directly instead of routing it
                    // through a GeometryReader probe + preference key. The
                    // preference pipeline recomputes across the home screen's
                    // large view tree every frame, which is what made the header
                    // crossfade hitch at the very start of a scroll; this reads
                    // the offset synchronously with no tree-wide propagation.
                    .onScrollGeometryChange(for: CGFloat.self) { geo in
                        geo.contentOffset.y + geo.contentInsets.top
                    } action: { _, scrolled in
                        // The scrim waits until the hero is mostly gone —
                        // fading it in over the hero itself would darken the
                        // artwork, which the reference never does.
                        let start = UIScreen.main.bounds.height * 0.38
                        homeHeaderProgress.set(min(max((scrolled - start) / 60, 0), 1))
                        // Top rubber-band distance → hero stretch.
                        heroPull.set(max(0, -scrolled))
                        // Downward distance → the artwork's scroll parallax.
                        // Clamped at the hero's height, exactly as Nuvio stops
                        // tracking once the hero has left the viewport.
                        heroScroll.set(min(max(0, scrolled), FeaturedCarousel.heroHeight))
                    }
                    // Status-bar scrim — fades in once the hero has scrolled
                    // away so the clock/battery stay legible over passing
                    // content. Pure black wash (no pinned title text) to
                    // match the reference recording's scrolled state.
                    .overlay(alignment: .top) {
                        GeometryReader { proxy in
                            CompactHeaderScrim(height: proxy.safeAreaInsets.top + 70,
                                               fadeStart: 0.3,
                                               tintOverride: .black)
                                .frame(width: proxy.size.width)
                                // CULLED while invisible, not merely faded.
                                // This scrim is a `.regularMaterial`, and a
                                // material samples and blurs whatever is behind
                                // it on every frame even at opacity 0 — so a
                                // full-width backdrop blur was being computed
                                // for the entire length of every scroll from the
                                // top of the page, for something nobody could
                                // see. `ScrollProgressReveal` documents this
                                // exact case; home was the one screen still
                                // paying for it.
                                //
                                // The cull is INSIDE the GeometryReader on
                                // purpose: culling stops layout, and the reader
                                // has to keep measuring so the scrim comes back
                                // at the right size instead of at zero for a
                                // frame.
                                .scrollProgressReveal(homeHeaderProgress,
                                                      cullWhenHidden: true)
                        }
                        .ignoresSafeArea(.container, edges: .top)
                        .allowsHitTesting(false)
                    }
                    .modifier(DetailUnderlayParallax(cover: backSwipe.cover))
                    .opacity(homeVisible || backSwipeActive ? 1 : 0)
                    .allowsHitTesting(homeVisible)
                    .zIndex(0)
            }
        }
        // Channel preview popup for a home tap — the same sheet a channel tap
        // in a category opens, so playback always starts from the preview.
        .sheet(item: $homePreviewChannel) { channel in
            ChannelPreviewSheet(
                channel: channel,
                viewModel: viewModel,
                accentColor: accentColor,
                playAction: { playAction($0) }
            )
        }
        // Racing's game card, presented here rather than inside the Sports hub
        // so a race opens the same page from the hub, the home Live Now shelf
        // and the hero. A full-screen page rather than the overlay the team
        // sports use: a weekend is five sessions with their own tabs, closer to
        // a team page than to a scoreline sheet.
        // NO implicit animation on `selectedCategory` — deliberately.
        //
        // Nuvio's tab host is a bare `when (selectedTab)` switch: the outgoing
        // screen is gone and the incoming one is on screen in the SAME frame,
        // with nothing animating. That is the whole reason its tab switching
        // feels instant. A crossfade here did the opposite — it kept two
        // full-screen hierarchies alive and compositing for its whole
        // duration, and the arriving screen ran its first layout, image
        // decodes and glass blurs DURING the fade, which is exactly what read
        // as clunky.
        //
        // Drill-downs still fade, via the explicit `pageAnimation` at their
        // call sites; only the tab switches (which never wrap their state
        // change in `withAnimation`) cut straight over. The bottom bar's own
        // pill glide and glass morph are unaffected — it animates those from
        // inside itself with `.animation(_:value:)`, independent of whatever
        // transaction changed the tab.
        // Re-enable detail interaction the moment any forward navigation fires,
        // so the arriving view is always fully tappable even if the user
        // navigates back and forward again within the 0.8 s reset window.
        // A guide update takes over the screen with its banner and rebuilds
        // every list underneath it, so it starts from home rather than leaving
        // the user deep in a category whose contents are being replaced.
        .onChangeCompat(of: viewModel.isUpdatingEPG) { updating in
            guard updating, selectedCategory != nil || !searchText.isEmpty else { return }
            searchText = ""
            withAnimation(Self.pageAnimation) { selectedCategory = nil }
        }
        .onChangeCompat(of: selectedCategory) { cat in
            // ONLY a drill-down pushes the home screen aside.
            //
            // Driving this on every category change swept the dock tabs in
            // too: switching to Home ran the parallax 1 → 0, so the home
            // screen eased in from a quarter of the way off to the left.
            // Tab switches carry no animation in this app — they swap in a
            // single frame — and that slide was the whole of what looked
            // wrong about them.
            if let cat, Self.isDrillDown(cat) {
                isDetailInteractive = true
                // Start from covering, whatever a previous swipe left behind,
                // and push the home screen aside as the page arrives.
                backSwipe.slide.set(0)
                withAnimation(Self.pageAnimation) { backSwipe.cover.set(1) }
            } else {
                // A hub tab, or home. `set` assigns only on a real change, so
                // this is a no-op while a chevron close is already animating
                // the cover down — that animation survives — and instant when
                // arriving from a tab that never pushed anything aside.
                backSwipe.slide.set(0)
                backSwipe.cover.set(0)
            }
            sectionTitleProgress.set(0)
            // First visit to a hub mounts it; it stays for the rest of the
            // session. Nothing is built for a tab that is never opened.
            if let id = cat?.id, Self.mountedHubIDs.contains(id) {
                visitedHubs.insert(id)
            }
        }
        .onChangeCompat(of: activeHubID) { id in
            sportsActive.set(id == -3)
            favoritesActive.set(id == -4)
        }
        .onChangeCompat(of: homeVisible) { visible in
            homeActive.set(visible)
        }
        .onAppear { homeActive.set(homeVisible) }
    }

    private var searchView: some SwiftUI.View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                if viewModel.isSearching {
                    VStack(alignment: .leading, spacing: 20) {
                        SkeletonBox(width: 150, height: 14).padding(.horizontal)
                        ScrollView(.horizontal) { HStack { ForEach(0..<4) { _ in HorizontalCardSkeleton() } } }.padding(.horizontal)
                        SkeletonBox(width: 150, height: 14).padding(.horizontal)
                        ScrollView(.horizontal) { HStack { ForEach(0..<4) { _ in HorizontalCardSkeleton() } } }.padding(.horizontal)
                    }.padding(.top, 20)
                } else {
                    if !viewModel.filteredEPGChannels.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("EPG GUIDE RESULTS")
                                .font(.caption2.weight(.black))
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                            HorizontalSearchList(channels: viewModel.filteredEPGChannels, viewModel: viewModel, accentColor: accentColor, playAction: playAction)
                        }
                    }
                    if !viewModel.filteredNameChannels.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("CHANNEL NAME RESULTS")
                                .font(.caption2.weight(.black))
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                            HorizontalSearchList(channels: viewModel.filteredNameChannels, viewModel: viewModel, accentColor: accentColor, playAction: playAction)
                        }
                    }
                    
                    if !viewModel.filteredCategories.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("EXPLORE CATEGORIES")
                                .font(.caption2.weight(.black))
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(viewModel.filteredCategories) { cat in
                                        Button(action: { withAnimation(Self.pageAnimation) { selectedCategory = cat; searchText = "" } }) {
                                            CategoryCard(title: cat.name, color: .secondary, lineLimit: 1)
                                                .multilineTextAlignment(.leading)
                                                .frame(width: 200, height: 85)
                                        }.buttonStyle(.plain)
                                    }
                                }.padding(.horizontal)
                            }
                        }
                    }
                    
                    RecentSearchesView(viewModel: viewModel, accentColor: accentColor)
                        .padding(.top, 10)
                    
                    if viewModel.filteredEPGChannels.isEmpty && viewModel.filteredNameChannels.isEmpty && viewModel.filteredCategories.isEmpty {
                        EmptyStateView(title: "No Results", systemImage: "magnifyingglass", description: "Try searching for a show or channel.")
                            .padding(.top, 100)
                    }
                }
            }
            .padding(.top, 20)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, y in
            searchHeaderProgress = min(max(y / 40, 0), 1)
        }
        // Shared app-wide compact-header vignette (dark + blur), revealed as
        // the results scroll up under the chrome row.
        .overlay(alignment: .top) {
            GeometryReader { proxy in
                CompactHeaderScrim(height: proxy.safeAreaInsets.top + 215, fadeStart: 0.2)
                    .frame(width: proxy.size.width)
            }
            .ignoresSafeArea(.container, edges: .top)
            .opacity(searchHeaderProgress * searchHeaderProgress)
            .allowsHitTesting(false)
        }
    }

    func getChannelsToShow(for cat: StreamCategory) -> [StreamChannel] {
        // -2 = Recently Watched. Use the cached id-to-channel map so this is
        // O(recent) instead of O(recent × channels) -- the latter was the
        // single largest hitch when entering this list with a populated
        // playlist (thousands of channels × dozens of recents).
        if cat.id == -2 {
            return viewModel.recentIDs.compactMap { idToChannel[$0] }
        }
        if cat.id == -4 { return viewModel.channels.filter { viewModel.favoriteIDs.contains($0.id) } }
        if cat.id == -1 { return viewModel.channels.filter { !viewModel.hiddenIDs.contains($0.id) } }
        return viewModel.channels.filter { $0.categoryID == cat.id && !viewModel.hiddenIDs.contains($0.id) }
    }

    /// Visible categories grouped by broader genre (Sports, News, Movies, etc.)
    /// in `HomeCategoryGroup.allCases` order. Empty groups are omitted.
    var groupedCategories: [(HomeCategoryGroup, [StreamCategory])] {
        let visible = viewModel.categories.filter { !$0.isHidden }
        let buckets = Dictionary(grouping: visible) { HomeCategoryGroup.classify($0) }
        return HomeCategoryGroup.allCases.compactMap { group in
            guard let cats = buckets[group], !cats.isEmpty else { return nil }
            return (group, cats)
        }
    }

    /// Cache key for `cachedDisplayedFeatured`. Hashes only the inputs that
    /// can actually change the result, so the cache rebuilds only on
    /// genuine changes (chip toggle, new featured list).
    private var featuredCacheKey: String {
        let g = selectedHomeGroup?.rawValue ?? "for-you"
        let ids = viewModel.featuredChannels.map { String($0.id) }.joined(separator: ",")
        let live = scoreViewModel.allLiveGameIDsKey
        let favCount = scoreViewModel.favoriteTeamIDs.count + scoreViewModel.favoriteLeagueKeys.count
        return "\(g)|\(ids)|\(live)|\(favCount)|\(viewModel.channelRevision)"
    }

    /// Cache key for `cachedRecent`. Triggers a refresh when the user's
    /// recent list mutates or when the global channel list reloads.
    private var recentCacheKey: String {
        viewModel.recentIDs.map { String($0) }.joined(separator: ",")
            + "|\(viewModel.channels.count)|\(viewModel.channelRevision)"
    }

    /// Featured carousel content for the current chip selection. Called only
    /// from `.task(id: featuredCacheKey)` — never directly from `body` so
    /// the body itself stays cheap.
    /// • "For You" → pre-computed mixed-genre list from ChannelViewModel.
    /// • Specific group → channels from that group, preferring ones with a
    ///   currently-live program (better hero cards) and limiting to 6.
    func computeDisplayedFeatured() -> [FeaturedItem] {
        if let group = selectedHomeGroup {
            // Classify each CATEGORY once (dozens), never per CHANNEL
            // (thousands) — the keyword classifier runs a regex plus ~250
            // substring checks, and calling it for every channel made each
            // chip tap stall for around a second.
            var groupByCatID: [Int: HomeCategoryGroup] = [:]
            groupByCatID.reserveCapacity(viewModel.categories.count)
            for cat in viewModel.categories {
                groupByCatID[cat.id] = HomeCategoryGroup.classify(cat)
            }
            var inGroup: [StreamChannel] = []
            inGroup.reserveCapacity(64)
            for channel in viewModel.channels {
                if viewModel.hiddenIDs.contains(channel.id) { continue }
                guard groupByCatID[channel.categoryID] == group else { continue }
                inGroup.append(channel)
                if inGroup.count > 60 { break }
            }
            let withLive = inGroup.filter { viewModel.getCurrentProgram(for: $0) != nil }
            let pool = withLive.isEmpty ? inGroup : withLive
            return Array(pool.prefix(6)).map { FeaturedItem(channel: $0) }
        }

        var result: [FeaturedItem] = []
        var usedIDs = Set<Int>()
        var usedGameIDs = Set<String>()

        // Live games lead the hero — favorites first, then any other live
        // game whose broadcast resolves to a channel (capped so the carousel
        // stays mostly featured content). Each renders as the full-bleed
        // matchup hero page: big title, dot metadata, white Watch pill.
        for game in scoreViewModel.favoriteLiveGames() {
            if let ch = viewModel.resolveChannel(forGame: game), usedIDs.insert(ch.id).inserted {
                usedGameIDs.insert(game.id)
                result.append(FeaturedItem(channel: ch, game: game))
            }
        }
        for game in scoreViewModel.allLiveGames {
            guard result.count < 3 else { break }
            guard !usedGameIDs.contains(game.id),
                  game.homeCompetitor?.team?.logo != nil,
                  game.awayCompetitor?.team?.logo != nil else { continue }
            if let ch = viewModel.resolveChannel(forGame: game), usedIDs.insert(ch.id).inserted {
                usedGameIDs.insert(game.id)
                result.append(FeaturedItem(channel: ch, game: game))
            }
        }

        for ch in viewModel.featuredChannels where usedIDs.insert(ch.id).inserted {
            result.append(FeaturedItem(channel: ch))
        }

        return result
    }

    /// Pairs a themed row's channels with whatever each is showing. The
    /// ranking itself happened ONCE, off the main thread, alongside the
    /// featured picks — this is only a guide lookup per card.
    func spotlightItems(for group: ChannelViewModel.SpotlightGroup) -> [SpotlightItem] {
        group.channels.map {
            SpotlightItem(channel: $0, program: viewModel.getCurrentProgram(for: $0))
        }
    }

    /// The page body: three category shelves, then a themed row of big cards,
    /// repeating until the themed rows are used up — after which the remaining
    /// categories simply carry on.
    /// The page body, in the order the user has chosen — which by default is the
    /// natural interleave (category shelves in threes with a row of big cards
    /// between them). The order itself lives on the view model, because the Home
    /// Layout settings screen has to list exactly what this renders; both walk
    /// the same `HomeSection` list so the two can't disagree.
    func computeHomeRows() -> [HomeRow] {
        var catByID: [String: StreamCategory] = [:]
        for cat in shelfCategories {
            catByID[ChannelViewModel.homeSectionID(categoryID: cat.id)] = cat
        }
        var groupByID: [String: ChannelViewModel.SpotlightGroup] = [:]
        for group in viewModel.spotlightGroups {
            groupByID[ChannelViewModel.homeSectionID(spotlightID: group.id)] = group
        }
        return viewModel.orderedHomeSections().compactMap { section in
            if let cat = catByID[section.id] {
                return HomeRow(id: section.id, kind: .category(cat))
            }
            if let group = groupByID[section.id] {
                return HomeRow(id: section.id, kind: .spotlight(group))
            }
            return nil
        }
    }

    /// Stores the grouping and the shelf order together, so the two can never
    /// drift apart.
    ///
    /// The shelves follow the USER'S OWN category order, not the genre buckets.
    /// Flattening the buckets meant the home page led with every sports
    /// category, then every news one, and so on — an order the Manage
    /// Categories screen has no way to show and dragging there could not
    /// change. The buckets are still kept for the group filter.
    private func setGroupedCategories(_ groups: [(HomeCategoryGroup, [StreamCategory])]) {
        cachedGrouped = groups
        shelfCategories = viewModel.categories.filter { !$0.isHidden }
    }

    /// Category shelves to render below Quick Access for the current chip.
    /// • "For You" → all groups (matches the pre-chip behaviour).
    /// • Specific group → just that group's categories.
    var displayedGroupedCategories: [(HomeCategoryGroup, [StreamCategory])] {
        guard let group = selectedHomeGroup else { return cachedGrouped }
        return cachedGrouped.filter { $0.0 == group }
    }

    /// Navigates back to the home screen while ensuring the departing detail
    /// view cannot block Quick Access taps.
    ///
    /// SwiftUI keeps a transitioning view (blurFade removal) in the hierarchy
    /// at opacity > 0 for ~600 ms. Because opacity alone doesn't disable hit
    /// testing, the fading view intercepts taps meant for the home screen.
    /// Setting `isDetailInteractive = false` before the animation removes
    /// `userInteractionEnabled` from the UIKit layer first, so the home screen
    /// is tappable the instant the transition starts.
    /// Back-out for the interactive swipe.
    ///
    /// The animated path below is right for the chevron — the page plays its
    /// slide-out and goes. After a swipe it is wrong twice over: the page is
    /// ALREADY off-screen under the finger, so a second removal animation is a
    /// move it has no room to make, and while that animation was still
    /// running the swipe state reset the page's offset to zero — snapping it
    /// back over the screen mid-fade. That is the flash of the category on
    /// the way out.
    private func handleSwipeBackNavigation() {
        isDetailInteractive = false
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { selectedCategory = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            isDetailInteractive = true
        }
    }

    private func handleBackNavigation() {
        isDetailInteractive = false
        // Eased down here rather than from the observer, so the home screen
        // travels with the page on its way out — the same pairing the detail
        // pages get from `DetailRouter.close()`.
        withAnimation(Self.pageAnimation) { backSwipe.cover.set(0) }
        // Defer the state flip to the next run-loop turn so SwiftUI can
        // commit `isDetailInteractive = false` as its own update pass —
        // batching both changes together would apply `allowsHitTesting(false)`
        // only to the CURRENT render's view, not the one kept alive for the
        // removal transition.
        DispatchQueue.main.async {
            withAnimation(Self.pageAnimation) { selectedCategory = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                isDetailInteractive = true
            }
        }
    }
}

struct DashboardCard: View {
    let title: String
    let icon: String
    let color: Color
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                Circle()
                    .fill(color.opacity(0.55))
                    .frame(width: 130, height: 130)
                    .blur(radius: 38)
                    .offset(x: 35, y: -30)

                Image(systemName: icon)
                    .font(.system(size: 42, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color)
                    .shadow(color: color.opacity(0.6), radius: 8, x: 0, y: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 14)
                    .padding(.trailing, 16)

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .modifier(TintedGlassCard(cornerRadius: 20, tint: color))
        }
        .buttonStyle(PressableCardStyle())
    }
}

struct TintedGlassCard: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color

    private var isTinted: Bool {
        tint != .clear
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            let glass: Glass = isTinted
                ? .regular.tint(tint.opacity(0.18))
                : .regular
            return AnyView(
                content
                    .glassEffect(glass, in: shape)
                    .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: isTinted ? tint.opacity(0.28) : Color.black.opacity(0.2), radius: isTinted ? 14 : 6, x: 0, y: isTinted ? 6 : 3)
                    .clipShape(shape)
            )
        } else {
            return AnyView(
                content
                    .background(isTinted ? tint.opacity(0.15) : Color.white.opacity(0.08))
                    .background(.ultraThinMaterial)
                    .clipShape(shape)
                    .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: isTinted ? tint.opacity(0.28) : Color.black.opacity(0.2), radius: isTinted ? 14 : 6, x: 0, y: isTinted ? 6 : 3)
            )
        }
    }
}

enum CategoryPalette {
    private static let palette: [Color] = [
        Color(red: 0.94, green: 0.36, blue: 0.38),
        Color(red: 0.96, green: 0.58, blue: 0.22),
        Color(red: 0.98, green: 0.78, blue: 0.27),
        Color(red: 0.34, green: 0.78, blue: 0.44),
        Color(red: 0.29, green: 0.69, blue: 0.91),
        Color(red: 0.38, green: 0.48, blue: 0.97),
        Color(red: 0.65, green: 0.42, blue: 0.93),
        Color(red: 0.93, green: 0.44, blue: 0.76),
        Color(red: 0.27, green: 0.73, blue: 0.72),
        Color(red: 0.82, green: 0.53, blue: 0.35)
    ]

    static func color(for name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = ((hash &<< 5) &+ hash) &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

struct CategoryHeroCard: View {
    let title: String
    var color: Color? = nil
    var subtitle: String? = nil

    var body: some View {
        ZStack {
            if let color {
                Circle()
                    .fill(color.opacity(0.55))
                    .frame(width: 110, height: 110)
                    .blur(radius: 30)
                    .offset(x: 32, y: -24)
            }

            VStack(spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        // Keep the colour glow contained: the blurred blob would otherwise
        // spill past the tile's rounded rectangle. Clipping the content (not
        // the whole card) leaves TintedGlassCard's intended drop shadow intact.
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .modifier(TintedGlassCard(cornerRadius: 20, tint: color ?? .clear))
    }
}

/// Nuvio-style shelf card for a category: flat charcoal 16:9 tile with the
/// category's colour glowing softly inside and a giant translucent initial,
/// the name in white BELOW the card — the reference's shelf-card layout
/// adapted for artwork-less categories.
struct NuvioCategoryCard: View {
    let title: String
    var color: Color? = nil

    private var glow: Color { color ?? CategoryPalette.color(for: title) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                Circle()
                    .fill(glow.opacity(0.5))
                    .frame(width: 130, height: 130)
                    .blur(radius: 42)
                    .offset(x: 34, y: -22)
                Text(String(title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.system(size: 62, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.14))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 118)
            .nuvioCard()

            Text(title)
                .font(NuvioTheme.cardTitleFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
    }
}

struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct SidebarLayout: SwiftUI.View {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Binding var selectedCategory: StreamCategory?; @Binding var selectedChannel: StreamChannel?; @Binding var searchText: String
    let isLandscape: Bool; let accentColor: Color; let playAction: (StreamChannel) -> Void; @Binding var showMultiView: Bool; @Binding var showSettings: Bool
    var zoomNS: Namespace.ID? = nil
    @State private var channelForDescription: StreamChannel?
    /// Tap-through preview: what's on, description, and the play button.
    @State private var previewChannel: StreamChannel?

    // O(1) id → channel cache. Refreshed only when the channel list size
    // changes; prevents the O(recent × channels) walk that getChannelsToShow
    // would otherwise perform every time the user selects Recently Watched.
    @State private var idToChannel: [Int: StreamChannel] = [:]
    
    var body: some SwiftUI.View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ClockView().padding(.vertical, 20)
                        if !searchText.isEmpty { GlassSidebarRow(title: "Search Results", isSelected: true, accentColor: accentColor) }
                        else {
                            Button(action: { viewModel.triggerSelectionHaptic(); withAnimation { selectedCategory = StreamCategory(id: -2, name: "Recently Watched") } }) { GlassSidebarRow(title: "Recently Watched", isSelected: selectedCategory?.id == -2, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { viewModel.triggerSelectionHaptic(); withAnimation { selectedCategory = StreamCategory(id: -4, name: "Favorites") } }) { GlassSidebarRow(title: "Favorites", isSelected: selectedCategory?.id == -4, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { viewModel.triggerSelectionHaptic(); withAnimation { selectedCategory = StreamCategory(id: -3, name: "Sports") } }) { GlassSidebarRow(title: "Sports", isSelected: selectedCategory?.id == -3, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { viewModel.triggerSelectionHaptic(); withAnimation { selectedCategory = StreamCategory(id: -5, name: "Recordings") } }) { GlassSidebarRow(title: "Recordings", isSelected: selectedCategory?.id == -5, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { viewModel.triggerSelectionHaptic(); withAnimation(MainView.multiViewSlide) { showMultiView = true } }) { GlassSidebarRow(title: "Multi-View", isSelected: false, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { viewModel.triggerSelectionHaptic(); withAnimation { selectedCategory = StreamCategory(id: -1, name: "All Channels") } }) { GlassSidebarRow(title: "All Channels", isSelected: selectedCategory?.id == -1, accentColor: accentColor) }.buttonStyle(.plain)
                            Divider().background(Color.white.opacity(0.3)).padding(.vertical, 8)
                            ForEach(viewModel.categories.filter { !$0.isHidden }) { cat in Button(action: { viewModel.triggerSelectionHaptic(); withAnimation { selectedCategory = cat } }) { GlassSidebarRow(title: cat.name, isSelected: selectedCategory?.id == cat.id, accentColor: accentColor) }.buttonStyle(.plain).contextMenu { Button { viewModel.triggerRenameCategory(cat) } label: { Label("Rename", systemImage: "pencil") }; Button { viewModel.hideCategory(cat.id) } label: { Label("Hide", systemImage: "eye.slash") } } }
                        }
                    }.padding(.horizontal, 10)
                }
            }.frame(width: isLandscape ? 260 : 170).background(Color.clear); Divider().overlay(Color.white.opacity(0.2))
            ZStack {
                if viewModel.isLoading {
                    ScrollView {
                        VStack {
                            ForEach(0..<15, id: \.self) { _ in ChannelRowSkeleton() }
                        }
                    }
                }
                else if !searchText.isEmpty {
                    
                    
                    
                    StandardLayout(viewModel: viewModel, scoreViewModel: scoreViewModel, selectedCategory: $selectedCategory, selectedChannel: $selectedChannel, searchText: $searchText, accentColor: accentColor, playAction: playAction, showMultiView: $showMultiView, showSettings: $showSettings, selectedRecording: .constant(nil), zoomNS: zoomNS)
                        .id("SearchOverride") 
                } else if selectedCategory?.id == -3 { SportsHubView(viewModel: viewModel, accentColor: accentColor, playAction: playAction, onBack: nil, scoreViewModel: scoreViewModel).transition(.opacity) }
                else if selectedCategory?.id == -5 { RecordingsView(viewModel: viewModel, playAction: playAction, onBack: { withAnimation { selectedCategory = nil } }).transition(.opacity) }
                else {
                    ScrollViewReader { proxy in
                        let channels = getChannelsToShow()
                        Group {
                            if channels.isEmpty {
                                EmptyStateView(title: "No Channels", systemImage: "tv.slash", description: "Select a category.")
                            } else {
                                List {
                                    ForEach(channels) { c in
                                        ChannelRow(channel: c, epgProgram: viewModel.getCurrentProgram(for: c), isFavorite: viewModel.favoriteIDs.contains(c.id), accentColor: accentColor, isCompact: !isLandscape, playAction: { viewModel.triggerSelectionHaptic(); previewChannel = c }, toggleFav: { viewModel.toggleFavorite(c.id) })
                                            .equatable()
                                            .id(c.id)
                                            .matchedTransitionSourceIfAvailable(id: c.id, in: zoomNS)
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                            .listRowInsets(EdgeInsets())
                                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                                Button {
                                                    viewModel.toggleFavorite(c.id)
                                                } label: {
                                                    Label(viewModel.favoriteIDs.contains(c.id) ? "Unfavorite" : "Favorite", systemImage: viewModel.favoriteIDs.contains(c.id) ? "star.slash.fill" : "star.fill")
                                                }
                                                .tint(.yellow)
                                            }
                                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                                Button(role: .destructive) {
                                                    viewModel.hideChannel(c.id)
                                                } label: {
                                                    Label("Hide", systemImage: "eye.slash.fill")
                                                }
                                                if selectedCategory?.id == -2 || viewModel.recentIDs.contains(c.id) {
                                                    Button {
                                                        viewModel.removeFromRecent(c.id)
                                                    } label: {
                                                        Label("Remove", systemImage: "clock.badge.xmark")
                                                    }
                                                    .tint(.orange)
                                                }
                                            }
                                            .contextMenu {
                                                Button { playAction(c) } label: { Label("Play", systemImage: "play.fill") }
                                                Button { viewModel.toggleFavorite(c.id) } label: { Label(viewModel.favoriteIDs.contains(c.id) ? "Unfavorite" : "Favorite", systemImage: viewModel.favoriteIDs.contains(c.id) ? "star.slash" : "star") }
                                                Button { viewModel.triggerRenameChannel(c) } label: { Label("Rename", systemImage: "pencil") }
                                                Button { viewModel.hideChannel(c.id) } label: { Label("Hide", systemImage: "eye.slash") }
                                                if let prog = viewModel.getCurrentProgram(for: c), let desc = prog.description, !desc.isEmpty {
                                                    Button { channelForDescription = c } label: { Label("Description", systemImage: "text.alignleft") }
                                                }
                                                if selectedCategory?.id == -2 || viewModel.recentIDs.contains(c.id) { Button(role: .destructive) { viewModel.removeFromRecent(c.id) } label: { Label("Remove", systemImage: "clock.badge.xmark") } }
                                            }
                                    }
                                }
                                .listStyle(.plain)
                                .scrollContentBackground(.hidden)
                                .environment(\.defaultMinListRowHeight, 0)
                            }
                        }
                        .transition(.opacity)
                        .onAppear {
                            if let last = viewModel.lastPlayedChannelID {
                                DispatchQueue.main.async { proxy.scrollTo(last, anchor: .center) }
                            }
                        }
                            .onChangeCompat(of: viewModel.lastPlayedChannelID) { id in
                            if let id = id { proxy.scrollTo(id, anchor: .center) }
                        }
                            .onChangeCompat(of: viewModel.scrollRestoreTrigger) { _ in
                            if let last = viewModel.lastPlayedChannelID {
                                proxy.scrollTo(last, anchor: .center)
                            }
                        }
                    }
                }
            }.animation(.spring(response: 0.4, dampingFraction: 0.8), value: selectedCategory)
        }
        .alert(item: $channelForDescription) { channel in
            Alert(
                title: Text("Program Description"),
                message: Text(viewModel.getCurrentProgram(for: channel)?.description ?? "No description available."),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(item: $previewChannel) { channel in
            ChannelPreviewSheet(
                channel: channel,
                viewModel: viewModel,
                accentColor: accentColor,
                playAction: { playAction($0) }
            )
        }
        .onAppear {
            if idToChannel.isEmpty {
                var map = [Int: StreamChannel]()
                map.reserveCapacity(viewModel.channels.count)
                for c in viewModel.channels { map[c.id] = c }
                idToChannel = map
            }
        }
        .task(id: "\(viewModel.channels.count)-\(viewModel.channelRevision)") {
            var map = [Int: StreamChannel]()
            map.reserveCapacity(viewModel.channels.count)
            for c in viewModel.channels { map[c.id] = c }
            idToChannel = map
        }
    }

    func getChannelsToShow() -> [StreamChannel] {
        guard let cat = selectedCategory else { return [] }
        if cat.id == -2 {
            return viewModel.recentIDs.compactMap { idToChannel[$0] }
        }
        if cat.id == -4 { return viewModel.channels.filter { viewModel.favoriteIDs.contains($0.id) } }
        if cat.id == -1 { return viewModel.channels.filter { !viewModel.hiddenIDs.contains($0.id) } }
        return viewModel.channels.filter { $0.categoryID == cat.id && !viewModel.hiddenIDs.contains($0.id) }
    }
}

struct CategoryDetailView: SwiftUI.View {
    let title: String; let channels: [StreamChannel]; let accentColor: Color; let playAction: (StreamChannel) -> Void; let toggleFav: (Int) -> Void; let promptRename: (StreamChannel) -> Void; let hideChannel: (Int) -> Void; let favoriteIDs: Set<Int>; @ObservedObject var viewModel: ChannelViewModel; @Binding var showMultiView: Bool; var onBack: (() -> Void)? = nil; var onCategorySelect: ((StreamCategory) -> Void)? = nil; var zoomNS: Namespace.ID? = nil
    @State private var channelForDescription: StreamChannel?
    /// Tap-through preview: what's on, description, and the play button.
    @State private var previewChannel: StreamChannel?
    /// 0 at the top, 1 once scrolled — reveals the compact-header vignette.
    @State private var headerProgress: CGFloat = 0

    var body: some SwiftUI.View {
        ZStack {
            AppBackground()
            
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    Group {
                        if !viewModel.searchText.isEmpty {
                            Text("Search Results").font(.headline).padding()
                        } else {
                            List {
                                ForEach(channels) { c in
                                    ChannelRow(channel: c, epgProgram: viewModel.getCurrentProgram(for: c), isFavorite: favoriteIDs.contains(c.id), accentColor: accentColor, playAction: { viewModel.triggerSelectionHaptic(); previewChannel = c }, toggleFav: { toggleFav(c.id) })
                                        .equatable()
                                        .id(c.id)
                                        .matchedTransitionSourceIfAvailable(id: c.id, in: zoomNS)
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets())
                                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                            Button {
                                                toggleFav(c.id)
                                            } label: {
                                                Label(favoriteIDs.contains(c.id) ? "Unfavorite" : "Favorite", systemImage: favoriteIDs.contains(c.id) ? "star.slash.fill" : "star.fill")
                                            }
                                            .tint(.yellow)
                                        }
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                hideChannel(c.id)
                                            } label: {
                                                Label("Hide", systemImage: "eye.slash.fill")
                                            }
                                        }
                                        .contextMenu {
                                            Button { playAction(c) } label: { Label("Play", systemImage: "play.fill") }
                                            Button { toggleFav(c.id) } label: { Label(favoriteIDs.contains(c.id) ? "Unfavorite" : "Favorite", systemImage: favoriteIDs.contains(c.id) ? "star.slash" : "star") }
                                            Button { promptRename(c) } label: { Label("Rename", systemImage: "pencil") }
                                            Button { hideChannel(c.id) } label: { Label("Hide", systemImage: "eye.slash") }
                                            if let prog = viewModel.getCurrentProgram(for: c), let desc = prog.description, !desc.isEmpty {
                                                Button { channelForDescription = c } label: { Label("Description", systemImage: "text.alignleft") }
                                            }
                                        }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .environment(\.defaultMinListRowHeight, 0)
                            .onScrollGeometryChange(for: CGFloat.self) { geo in
                                geo.contentOffset.y + geo.contentInsets.top
                            } action: { _, y in
                                headerProgress = min(max(y / 40, 0), 1)
                            }
                        }
                    }
                    .onAppear {
                        if let last = viewModel.lastPlayedChannelID {
                            DispatchQueue.main.async { proxy.scrollTo(last, anchor: .center) }
                        }
                    }
                }
            }

            // Shared app-wide compact-header vignette (dark + blur), revealed
            // as the channel list scrolls up under the chrome row.
            GeometryReader { proxy in
                CompactHeaderScrim(height: proxy.safeAreaInsets.top + 215, fadeStart: 0.2)
                    .frame(width: proxy.size.width)
            }
            .ignoresSafeArea(.container, edges: .top)
            .opacity(headerProgress * headerProgress)
            .allowsHitTesting(false)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let onBack = onBack {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
        }
        .alert(item: $channelForDescription) { channel in
            Alert(
                title: Text("Program Description"),
                message: Text(viewModel.getCurrentProgram(for: channel)?.description ?? "No description available."),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(item: $previewChannel) { channel in
            ChannelPreviewSheet(
                channel: channel,
                viewModel: viewModel,
                accentColor: accentColor,
                playAction: { playAction($0) }
            )
        }
        // Frozen for the duration of a back-swipe, so the page travels
        // sideways only instead of also drifting up or down under the finger.
        // The detail pages take the same lock from `DetailRouter.dragLock`;
        // without it this was the one way a category swipe still did not feel
        // like a favourite team's page.
        .scrollLocked(BackSwipeState.shared.dragLock)
    }
}

struct MiniPlayerView: SwiftUI.View {
    let channel: StreamChannel
    let viewModel: ChannelViewModel
    let onExpand: () -> Void
    let onClose: () -> Void
    
    @ObservedObject var playerManager = NebuloPlayerEngine.shared
    
    @State private var showControls = false
    @State private var pipOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some SwiftUI.View {
        ZStack {
            UnifiedPlayerViewBridge()
                .frame(width: 240, height: 135)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
            
            
            Color.black.opacity(0.001)
                .frame(width: 240, height: 135)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        showControls.toggle()
                    }
                }
            
            if showControls {
                ZStack {
                    Color.black.opacity(0.3)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .allowsHitTesting(false)
                    
                    Button(action: {
                        if playerManager.isPlaying { playerManager.pause() } else { playerManager.resume() }
                    }) {
                        Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2.weight(.bold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .padding(12)
                            .modifier(GlassEffect(cornerRadius: 22, isSelected: true, accentColor: nil))
                    }
                    .buttonStyle(.plain)
                    
                    VStack {
                        HStack {
                            Button(action: {
                                onClose()
                                NebuloPlayerEngine.shared.stop()
                            }) {
                                Image(systemName: "xmark")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .modifier(GlassEffect(cornerRadius: 16, isSelected: true, accentColor: nil))
                            }
                            .buttonStyle(.plain)
                            
                            Spacer()
                            
                            Button(action: onExpand) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .modifier(GlassEffect(cornerRadius: 16, isSelected: true, accentColor: nil))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(8)
                        Spacer()
                    }
                }
                .frame(width: 240, height: 135)
                .zIndex(10)
            }
        }
        .frame(width: 240, height: 135)
        .offset(pipOffset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    pipOffset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                }
                .onEnded { value in
                    let screenWidth = UIScreen.main.bounds.width
                    let screenHeight = UIScreen.main.bounds.height
                    let pipWidth: CGFloat = 240
                    let pipHeight: CGFloat = 135
                    
                    let horizontalRange = screenWidth - pipWidth - 40
                    let verticalRange = screenHeight - pipHeight - 120
                    
                    let targetX: CGFloat = pipOffset.width > -horizontalRange / 2 ? 0 : -horizontalRange
                    let targetY: CGFloat = pipOffset.height < -verticalRange / 2 ? -verticalRange + 60 : 0
                    
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        pipOffset = CGSize(width: targetX, height: targetY)
                        lastOffset = pipOffset
                    }
                }
        )
    }
}

/// Edge back-swipe that TRACKS THE FINGER, with the screen underneath easing
/// in behind it — the same gesture the detail pages use, and the same feel
/// UIKit gives the Settings sub-pages for free.
///
/// The previous version did nothing until the drag ENDED and then jumped:
/// a 25pt strip whose only job was to notice a 60pt translation on release.
/// Nothing moved under your finger, so a swipe on a category page felt
/// unrelated to the animation it produced.
struct SwipeBackModifier: ViewModifier {
    let onBack: () -> Void
    /// Off when the screen has nothing of its own to go back to. The strip is
    /// a `highPriorityGesture` on the leading edge, so leaving it installed on
    /// a screen that was PUSHED (Recordings, opened from Settings) beats
    /// UIKit's interactive pop to the touch and then does nothing with it —
    /// the page just sits there under your finger.
    var isEnabled: Bool = true
    /// Shared with whatever is drawing the screen underneath, so it can move
    /// in step. Nil for callers with nothing behind them to ease in.
    var state: BackSwipeState? = nil
    /// Told when a drag starts and stops, so the host can reveal the screen
    /// underneath for the duration.
    var onDragChange: ((Bool) -> Void)? = nil

    /// Only the far edge goes back: everything inboard belongs to the page.
    private static let edgeWidth: CGFloat = 32

    @State private var dragging = false
    @State private var rejected = false

    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            if let state {
                content.modifier(DetailSlideOffset(slide: state.slide))
            } else {
                content
            }

            if isEnabled {
                Color.clear
                    .frame(width: Self.edgeWidth)
                    .contentShape(Rectangle())
                    .highPriorityGesture(drag)
            }
        }
    }

    private var drag: some Gesture {
        let width = max(UIScreen.main.bounds.width, 1)
        return DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if !dragging && !rejected {
                    // Judged once, on the first reported movement: a leftward
                    // or vertical start is somebody else's gesture.
                    guard dx > 0, abs(dx) > abs(dy) else { rejected = true; return }
                    dragging = true
                    SwipeTapGuard.suppress()
                    state?.dragLock.set(true)
                    onDragChange?(true)
                }
                guard dragging else { return }
                state?.track(dx / width)
            }
            .onEnded { value in
                let wasDragging = dragging
                dragging = false
                rejected = false
                state?.dragLock.set(false)
                guard wasDragging else {
                    onDragChange?(false)
                    return
                }
                // Same rule as the detail pages: a third of the width
                // travelled, or a flick that would carry it past two thirds.
                let travelled = max(0, value.translation.width)
                let flick = value.predictedEndTranslation.width - value.translation.width
                if travelled > width * 0.3 || travelled + flick > width * 0.6 {
                    if let state {
                        state.finish { onBack(); onDragChange?(false) }
                    } else {
                        onBack()
                        onDragChange?(false)
                    }
                } else {
                    state?.cancel()
                    onDragChange?(false)
                }
            }
    }
}

struct MultiViewIndicator: SwiftUI.View { 
    let count: Int; let accentColor: Color?; let action: () -> Void; 
    var body: some SwiftUI.View { 
        VStack {
            Spacer()
            Button(action: action) { 
                HStack { Image(systemName: "square.grid.2x2.fill"); Text("Multi-View Active: \(count)/4") }
                    .font(.caption.bold()).foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .modifier(GlassEffect(cornerRadius: 20, isSelected: true, accentColor: accentColor)) 
            }
            // Rides just above the floating bottom bar. The bar ignores the
            // bottom safe area (20pt off the physical edge, 61pt tall) while
            // this stack respects it, so relative to the safe-area bottom the
            // bar's top edge sits at 20 + 61 − ~34 ≈ 47pt.
            .padding(.bottom, 57)
        }
    }
}

/// Thin wrapper that observes `EPGLoadingState` directly so high-frequency
/// progress ticks (10 fps) only re-render this small view — never the main
/// channel list, category grid, or any other part of the app.
private struct EPGProgressBanner: View {
    @ObservedObject var epgState: EPGLoadingState
    let status: String
    let accentColor: Color
    let isBlocking: Bool
    let onDismiss: () -> Void

    var body: some View {
        LoadingStatusOverlay(
            status: status,
            progress: epgState.progress > 0 ? epgState.progress : nil,
            accentColor: accentColor,
            isBlocking: isBlocking,
            onDismiss: onDismiss
        )
    }
}

struct LoadingStatusOverlay: View {
    let status: String
    var progress: Double? = nil
    let accentColor: Color
    var isBlocking: Bool = true
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height

            VStack {
                HStack(spacing: 12) {
                    if progress != nil {
                        CircularProgressRing(progress: progress ?? 0, accent: accentColor)
                            .frame(width: 22, height: 22)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.primary)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(status)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let progress {
                            Text("\(Int(progress * 100))%")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .modifier(CapsuleGlassBackground())
                .padding(.top, isLandscape ? 16 : 54)
                .gesture(
                    DragGesture()
                        .onEnded { value in
                            if value.translation.height < -20 {
                                onDismiss?()
                            }
                        }
                )

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(
                isBlocking
                    ? Color.black.opacity(0.35)
                    : Color.clear
            )
            .ignoresSafeArea()
            .allowsHitTesting(isBlocking)
        }
    }
}

private struct CapsuleGlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            AnyView(content.glassEffect(.regular, in: Capsule()))
        } else {
            AnyView(
                content
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            )
        }
    }
}

private struct CircularProgressRing: View {
    let progress: Double
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: progress)
        }
    }
}

// MARK: - Home Screen Components
// Apple-style typography hierarchy with YouTube TV-inspired hero card,
// glass chips, and tinted section accents. Matches the player slide aesthetic.

/// Time-aware greeting at the top of the home screen.
/// "Good Morning, Good Afternoon, Good Evening" + the current weekday/date.
struct HomeGreetingHeader: View {
    @State private var now: Date = Date()

    /// Static formatter — DateFormatter init is surprisingly expensive,
    /// and we don't want to allocate one on every body render.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: now)
        switch hour {
        case 5..<12:  return "Good Morning"
        case 12..<17: return "Good Afternoon"
        case 17..<22: return "Good Evening"
        default:      return "Good Night"
        }
    }

    private var dateString: String {
        Self.dateFormatter.string(from: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.system(size: 32, weight: .bold, design: .default))
                .foregroundStyle(.primary)
            Text(dateString)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reusable section header used across the home screen. Appears as a tappable
/// row with optional icon + chevron when an action is provided, or a static
/// label otherwise.
/// The one settings gear used everywhere — a circular liquid-glass button
/// (real glassEffect on iOS 26, ultra-thin material below) pinned to the
/// top-right of every screen so it never moves or changes style. 44×44 to
/// match the system toolbar buttons on the Sports / detail screens exactly.
struct SettingsGearButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .modifier(GlassEffect(cornerRadius: 22, isSelected: false, accentColor: nil))
        }
        .buttonStyle(.plain)
    }
}

struct FeaturedItem {
    let channel: StreamChannel
    var game: ESPNEvent? = nil
}

/// Matchup card content — team colors bleed in from each side over a dark
/// centre, big partly-translucent crests in the background with the score,
/// names, LIVE pill and watch pill reading over them. Shared by the home
/// featured carousel and the Sports hub featured card so the two read as
/// one design.
struct MatchupHeroContent: View {
    let game: ESPNEvent
    var footerIcon: String? = nil
    var footerText: String? = nil
    let height: CGFloat
    let cornerRadius: CGFloat

    private func teamColor(_ c: ESPNCompetitor?) -> Color {
        guard let hex = c?.team?.color, !hex.isEmpty else { return Color(white: 0.22) }
        return Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)") ?? Color(white: 0.22)
    }

    var body: some View {
        let away = game.awayCompetitor
        let home = game.homeCompetitor
        let isLive = game.status.type.state == "in"
        let showScores = game.status.type.state != "pre"

        Rectangle()
            .fill(Color(white: 0.07))
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: teamColor(away).opacity(0.90), location: 0.0),
                        .init(color: teamColor(away).opacity(0.35), location: 0.32),
                        .init(color: Color.clear, location: 0.5),
                        .init(color: teamColor(home).opacity(0.35), location: 0.68),
                        .init(color: teamColor(home).opacity(0.90), location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .overlay { Color.black.opacity(0.18) }
            .overlay {
                // Big, partly-translucent crests living in the BACKGROUND —
                // they bleed slightly off each edge and everything else
                // (score, names, pills) reads over them.
                HStack {
                    CachedAsyncImage(urlString: away?.team?.logo ?? "",
                                     size: CGSize(width: 150, height: 150))
                        .opacity(0.55)
                        .offset(x: -18)
                    Spacer()
                    CachedAsyncImage(urlString: home?.team?.logo ?? "",
                                     size: CGSize(width: 150, height: 150))
                        .opacity(0.55)
                        .offset(x: 18)
                }
                .padding(.horizontal, 6)
                .allowsHitTesting(false)
            }
            .overlay {
                // Names on the sides, the score as its own big centred
                // cluster — all floating over the translucent crests, with
                // soft shadows so they stay legible on any logo.
                HStack(spacing: 0) {
                    teamName(away)
                        .frame(maxWidth: .infinity)
                    Group {
                        if showScores {
                            // One Text so a big baseball/basketball score
                            // scales down as a unit instead of wrapping a
                            // "10" onto two lines.
                            Text("\(Text(away?.score ?? "0")) \(Text("–").foregroundStyle(.white.opacity(0.4))) \(Text(home?.score ?? "0"))")
                                .font(.system(size: 34, weight: .black).monospacedDigit())
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        } else {
                            Text("vs")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .frame(minWidth: 84)
                    .layoutPriority(1)
                    .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 1)
                    teamName(home)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
            }
            .overlay(alignment: .top) {
                HStack {
                    HStack(spacing: 6) {
                        if isLive {
                            HStack(spacing: 4) {
                                Circle().fill(.white).frame(width: 6, height: 6)
                                Text("LIVE")
                                    .font(.system(size: 10, weight: .black))
                                    .kerning(0.6)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.9), in: Capsule())
                        }
                        Text(game.status.type.detail.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                        Text("Watch")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.white, in: Capsule())
                }
                .padding(.top, 14)
                .padding(.horizontal, 14)
            }
            .overlay(alignment: .bottom) {
                if let text = footerText, !text.isEmpty {
                    HStack(spacing: 6) {
                        if let icon = footerIcon {
                            Image(systemName: icon)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(text)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.35), in: Capsule())
                    .padding(.bottom, 12)
                    .padding(.horizontal, 14)
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.32), radius: 18, x: 0, y: 8)
    }

    private func teamName(_ c: ESPNCompetitor?) -> some View {
        Text(c?.team?.shortDisplayName ?? c?.team?.abbreviation ?? "—")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
    }
}

/// Horizontal scroller backed by `UIScrollView` with `delaysContentTouches`
/// disabled — the missing piece that SwiftUI's `ScrollView` doesn't expose.
/// Without this, the inner pan gesture stays in a tracking state for ~half
/// a second after every swipe and silently swallows taps. Used by the chip
/// row and the home-page Live Now / Continue Watching shelves.
/// A home shelf: one horizontally scrolling row, built the way Nuvio builds
/// theirs.
///
/// Nuvio's home is a `LazyColumn` of sections, each of which is a plain
/// `Column { header; LazyRow(items, key = ...) }` — a lazy row nested in a
/// lazy column, all of it composables drawn into a single canvas. Creating
/// one when it scrolls into view costs a measure pass and nothing else.
///
/// This used to be a `UIViewRepresentable` wrapping a UIScrollView with a
/// UIHostingController inside it, to work around SwiftUI's horizontal
/// ScrollView leaving its pan recogniser tracking after a swipe and
/// swallowing later taps. The cost of that workaround was enormous and paid
/// on exactly the wrong beat: home's shelves sit in a `LazyVStack`, so every
/// row entering the viewport built a hosting controller, an Auto Layout
/// hierarchy and a full SwiftUI tree, synchronously, in the middle of the
/// scroll. That is the jitter on every scroll — it scales with the number of
/// shelves and lands mid-gesture by construction.
///
/// The tap bug it was working around is separately handled now: every card in
/// every shelf checks `SwipeTapGuard.tapsAllowed`, which was added long after
/// this wrapper and covers a swipe that ends over a tappable card.
struct TouchPassingHorizontalScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content()
        }
        // The UIKit version set `alwaysBounceHorizontal = false`; this is the
        // native equivalent — a shelf narrower than the screen sits still
        // instead of rubber-banding.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

struct LiveGamesPreviewList: View {
    let games: [ESPNEvent]
    @ObservedObject var scoreViewModel: ScoreViewModel
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color

    var body: some View {
        // UIScrollView wrapper — see comment on TouchPassingHorizontalScroll.
        // Prevents the post-swipe gesture lockout that makes Quick Access
        // buttons un-tappable after scrolling this shelf.
        TouchPassingHorizontalScroll {
            LazyHStack(spacing: 12) {
                ForEach(games) { game in
                    LiveEventCard(game: game, accentColor: accentColor)
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .onTapGesture {
                            // Opens the game card first — the stream starts
                            // from there (or from the long-press menu's
                            // "Watch Stream"), never straight from a tap.
                            guard SwipeTapGuard.tapsAllowed else { return }
                            viewModel.triggerSelectionHaptic()
                            let sport = scoreViewModel.sportType(for: game)
                            if sport == .f1 {
                                scoreViewModel.presentRaceCard(game)
                            } else if sport == .golf {
                                scoreViewModel.presentGolfCard(game)
                            } else {
                                scoreViewModel.deepLinkRequest = scoreViewModel.makeDetailRequest(for: game, sport: sport)
                            }
                        }
                        .liveGameContextMenu(game: game, viewModel: viewModel, scoreViewModel: scoreViewModel)
                }
            }
            .padding(.horizontal)
        }
        .frame(height: LiveGameCard.cardHeight + 10)
    }
}

/// The sports-hub long-press menu, reusable on any live game card (home
/// Live Now shelf, search overlay's Live Now). Same actions as the hub's
/// GameScoreButton menu, minus Remind Me (these cards are always live).
extension View {
    func liveGameContextMenu(
        game: ESPNEvent,
        viewModel: ChannelViewModel,
        scoreViewModel: ScoreViewModel,
        beforeNavigate: (() -> Void)? = nil
    ) -> some View {
        modifier(LiveGameContextMenuModifier(
            game: game,
            viewModel: viewModel,
            scoreViewModel: scoreViewModel,
            beforeNavigate: beforeNavigate
        ))
    }
}

struct LiveGameContextMenuModifier: ViewModifier {
    let game: ESPNEvent
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    let beforeNavigate: (() -> Void)?
    // Observed (not read through the singleton) so stopping the activity —
    // from here, another menu, or the Lock Screen — refreshes the label.
    @ObservedObject private var activityManager = GameActivityManager.shared

    func body(content: Content) -> some View {
        content.contextMenu {
            let (h, a) = game.searchTerms
            let sport = scoreViewModel.sportType(for: game)
            let isPinned = scoreViewModel.pinnedGameIDs.contains(game.id)
            let isScoreHidden = scoreViewModel.hiddenScoreGameIDs.contains(game.id)

            if sport == .f1 {
                Button {
                    beforeNavigate?()
                    scoreViewModel.presentRaceCard(game)
                } label: {
                    Label("Race Card", systemImage: "flag.checkered")
                }
            } else if sport == .golf {
                Button {
                    beforeNavigate?()
                    scoreViewModel.presentGolfCard(game)
                } label: {
                    Label("Leaderboard", systemImage: "list.number")
                }
            } else {
                Button {
                    beforeNavigate?()
                    // The root-level deep-link sheet — presents the stats
                    // page over any screen, not just the sports hub.
                    scoreViewModel.deepLinkRequest = scoreViewModel.makeDetailRequest(for: game, sport: sport)
                } label: {
                    Label("View Stats", systemImage: "chart.bar.fill")
                }
            }

            Button {
                beforeNavigate?()
                viewModel.runSmartSearch(gameID: game.id, home: h, away: a, sport: sport, network: game.streamNetworkHint)
            } label: {
                Label("Watch Stream", systemImage: "play.fill")
            }

            Button {
                beforeNavigate?()
                viewModel.showStreamOptions(home: h, away: a, sport: sport, network: game.streamNetworkHint)
            } label: {
                Label("Stream List", systemImage: "list.bullet")
            }

            Button {
                beforeNavigate?()
                viewModel.autoAddGameToMultiView(home: h, away: a, network: game.streamNetworkHint)
            } label: {
                Label("Add to Multi-View", systemImage: "square.grid.2x2")
            }

            // Highlights only exist once the game is over.
            if game.status.type.state == "post" {
                Button {
                    let query = "\(game.shortName) highlights"
                    if let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                       let url = URL(string: "https://www.youtube.com/results?search_query=\(encoded)") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Find Highlights", systemImage: "play.rectangle.fill")
                }
            }

            Button {
                viewModel.toggleGameRecording(game: game, sport: sport)
            } label: {
                let isScheduled = viewModel.scheduledRecording(for: game) != nil
                Label(isScheduled ? "Cancel Recording" : "Record",
                      systemImage: isScheduled ? "stop.circle" : "record.circle")
            }

            if game.status.type.state == "in" {
                let isTracking = activityManager.trackedGameIDs.contains(game.id)
                Button {
                    activityManager.toggle(
                        game: game,
                        leagueName: game.leagueLabel ?? sport.rawValue,
                        sport: sport
                    )
                } label: {
                    Label(isTracking ? "Stop Live Activity" : "Live Activity",
                          systemImage: isTracking ? "bell.slash" : "bell.badge")
                }
            }

            Button {
                scoreViewModel.togglePin(game.id)
            } label: {
                Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
            }

            Button {
                scoreViewModel.toggleHideScore(game.id)
            } label: {
                Label(isScoreHidden ? "Show Score" : "Hide Score", systemImage: isScoreHidden ? "eye" : "eye.slash")
            }
        }
    }
}

/// Live game card on the home shelf, built to the reference app's "Live
/// Sports" tile: a diagonal split of the two clubs' colours with both crests
/// over it, a status badge in the top-left corner, and the league above the
/// matchup along the bottom. The one departure from the reference is that
/// those tiles are all upcoming, so they only carry a kickoff time — these
/// are live, so the badge reads LIVE and the score sits opposite the title.
struct LiveGameCard: View {
    let game: ESPNEvent
    let accentColor: Color

    static let cardWidth: CGFloat = 245
    static let cardHeight: CGFloat = 173

    private var homeName: String {
        game.homeCompetitor?.team?.shortDisplayName
            ?? game.homeCompetitor?.team?.abbreviation
            ?? game.homeCompetitor?.athlete?.shortName
            ?? "—"
    }
    private var awayName: String {
        game.awayCompetitor?.team?.shortDisplayName
            ?? game.awayCompetitor?.team?.abbreviation
            ?? game.awayCompetitor?.athlete?.shortName
            ?? "—"
    }
    private var homeLogo: String {
        game.homeCompetitor?.team?.logo
            ?? game.homeCompetitor?.athlete?.flag?.href
            ?? game.homeCompetitor?.athlete?.headshot
            ?? ""
    }
    private var awayLogo: String {
        game.awayCompetitor?.team?.logo
            ?? game.awayCompetitor?.athlete?.flag?.href
            ?? game.awayCompetitor?.athlete?.headshot
            ?? ""
    }
    private var homeScore: String { game.homeCompetitor?.score ?? "0" }
    private var awayScore: String { game.awayCompetitor?.score ?? "0" }
    private var isLive: Bool { game.status.type.state == "in" }

    private func teamColor(_ c: ESPNCompetitor?) -> Color {
        guard let hex = c?.team?.color, !hex.isEmpty,
              let col = Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)") else {
            return Color(white: 0.16)
        }
        return col
    }

    /// League / competition caption — the reference's small grey "MLS".
    private var leagueLabel: String? {
        if let n = game.broadcastName, !n.isEmpty { return n.uppercased() }
        return nil
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Hard diagonal split: away's colour on the left, home's on the
            // right, meeting on a steep edge across the middle.
            LinearGradient(
                stops: [
                    .init(color: teamColor(game.awayCompetitor), location: 0.5),
                    .init(color: teamColor(game.homeCompetitor), location: 0.5)
                ],
                startPoint: UnitPoint(x: 0.02, y: 0),
                endPoint: UnitPoint(x: 0.98, y: 1)
            )

            // Each crest sits centred in ITS OWN half — away at a quarter of
            // the width, home at three quarters — so neither one crosses the
            // diagonal onto the other club's colour. Centring them as a pair
            // put the away crest right on the seam.
            HStack(spacing: 0) {
                CachedAsyncImage(urlString: awayLogo, size: CGSize(width: 46, height: 46))
                    .frame(width: 46, height: 46)
                    .frame(maxWidth: .infinity)
                CachedAsyncImage(urlString: homeLogo, size: CGSize(width: 46, height: 46))
                    .frame(width: 46, height: 46)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .offset(y: -14)

            // Legibility wash so the caption reads over any club colour,
            // pale ones included.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.42),
                    .init(color: .black.opacity(0.72), location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )

            // Status badge, top-left.
            Group {
                if isLive {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.system(size: 11, weight: .black))
                            .kerning(0.5)
                            .foregroundStyle(.white)
                    }
                } else {
                    Text(Self.timeFmt.string(from: game.gameDate))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .padding(11)

            // League above the matchup, bottom-left; score opposite it.
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if let league = leagueLabel {
                        Text(league)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Text("\(awayName) vs. \(homeName)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
                if isLive {
                    Text("\(awayScore)–\(homeScore)")
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 11)
            .frame(width: Self.cardWidth, height: Self.cardHeight, alignment: .bottomLeading)
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }
}

/// Picks the Live Now card that fits the event.
///
/// A race weekend and a golf tournament have no two sides, so the matchup card
/// drew them as a grey diagonal captioned "Norris vs. Hamilton". The choice is
/// made from the event's own shape rather than a sport enum, so every Live Now
/// surface gets it without plumbing a view model through.
struct LiveEventCard: View {
    let game: ESPNEvent
    let accentColor: Color

    var body: some View {
        if game.isRaceEvent {
            LiveRaceCard(game: game)
        } else if game.isFieldEvent {
            LiveGolfCard(game: game)
        } else {
            LiveGameCard(game: game, accentColor: accentColor)
        }
    }
}

/// The Live Now card for a race weekend.
///
/// A Grand Prix has no two sides to split a card between, so the team card's
/// diagonal was two shades of grey and the caption read "Norris vs. Hamilton",
/// which is nonsense. This is the weekend on its own terms: the F1 red, the
/// session that's running with its clock, the circuit, and whoever's leading.
struct LiveRaceCard: View {
    let game: ESPNEvent

    private static let f1Red = Color(red: 0.88, green: 0.02, blue: 0.02)
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    /// The session that's running, or the next one due.
    private var session: ESPNEvent.RaceSession? { game.currentRaceSession }
    private var isLive: Bool { session?.state == "in" }
    /// Whoever's on top of the session that has a result — the leader while a
    /// session runs, the winner once it's done.
    private var leader: ESPNCompetitor? {
        (session?.state == "in" ? session : game.latestFinishedRaceSession)?.order.first
    }

    private var circuitName: String? {
        game.circuit?.fullName ?? game.circuit?.address?.city
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Red on the left falling away to near-black on the right, so the
            // caption at the bottom still reads.
            LinearGradient(
                colors: [Self.f1Red, Color(red: 0.42, green: 0.02, blue: 0.04),
                         Color(red: 0.10, green: 0.02, blue: 0.03)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            Image(systemName: "flag.checkered")
                .font(.system(size: 92, weight: .bold))
                .foregroundStyle(.white.opacity(0.10))
                .frame(width: LiveGameCard.cardWidth, height: LiveGameCard.cardHeight,
                       alignment: .trailing)
                .offset(x: 26, y: -10)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.40),
                    .init(color: .black.opacity(0.7), location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )

            // Which session, and its clock.
            HStack(spacing: 5) {
                if isLive {
                    Circle().fill(.white).frame(width: 6, height: 6)
                }
                Text(session.map { ScoreRow.sessionName($0.label).uppercased() } ?? "F1")
                    .font(.system(size: 10, weight: .black))
                    .kerning(0.5)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(isLive ? Color.red : Color.black.opacity(0.55)))
            .padding(11)

            VStack(alignment: .leading, spacing: 3) {
                if let circuitName {
                    Text(circuitName.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(0.4)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Text(game.shortName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                HStack(spacing: 6) {
                    if let leader, let name = leader.athlete?.shortName ?? leader.athlete?.displayName {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.75))
                        Text(name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    } else if let session, session.state == "pre", let date = session.date {
                        Text(Self.timeFmt.string(from: date))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 11)
            .frame(width: LiveGameCard.cardWidth, height: LiveGameCard.cardHeight,
                   alignment: .bottomLeading)
        }
        .frame(width: LiveGameCard.cardWidth, height: LiveGameCard.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }
}

/// The Live Now card for a golf tournament — the leader and their score, on the
/// tour's navy, rather than a two-man matchup that doesn't exist.
struct LiveGolfCard: View {
    let game: ESPNEvent

    private static let tourNavy = Color(red: 0.06, green: 0.20, blue: 0.44)

    private var isLive: Bool { game.status.type.state == "in" }

    private var board: [ESPNCompetitor] {
        (game.allCompetitions.first?.competitors ?? [])
            .sorted { ($0.order ?? 999) < ($1.order ?? 999) }
    }

    /// Under par green, over par red — golf's own convention.
    private static func parColor(_ total: String?) -> Color {
        guard let total, !total.isEmpty else { return .white }
        if total.hasPrefix("-") { return Color(red: 0.45, green: 0.95, blue: 0.55) }
        if total.hasPrefix("+") { return Color(red: 1.0, green: 0.55, blue: 0.5) }
        return .white
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Self.tourNavy, Color(red: 0.03, green: 0.10, blue: 0.24),
                         Color(red: 0.02, green: 0.05, blue: 0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            Image(systemName: "figure.golf")
                .font(.system(size: 84, weight: .semibold))
                .foregroundStyle(.white.opacity(0.10))
                .frame(width: LiveGameCard.cardWidth, height: LiveGameCard.cardHeight,
                       alignment: .trailing)
                .offset(x: 20, y: -8)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.36),
                    .init(color: .black.opacity(0.7), location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )

            // The round, which is golf's equivalent of a period.
            HStack(spacing: 5) {
                if isLive { Circle().fill(.white).frame(width: 6, height: 6) }
                Text(roundLabel.uppercased())
                    .font(.system(size: 10, weight: .black))
                    .kerning(0.5)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(isLive ? Color.red : Color.black.opacity(0.55)))
            .padding(11)

            VStack(alignment: .leading, spacing: 3) {
                Text(game.shortName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                // Top two, which is the story of a leaderboard at a glance.
                ForEach(Array(board.prefix(2).enumerated()), id: \.offset) { index, player in
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(player.athlete?.shortName ?? player.athlete?.displayName ?? "—")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(player.score ?? "–")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(Self.parColor(player.score))
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 11)
            .frame(width: LiveGameCard.cardWidth, height: LiveGameCard.cardHeight,
                   alignment: .bottomLeading)
        }
        .frame(width: LiveGameCard.cardWidth, height: LiveGameCard.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    /// "Round 4 - In Progress" → "Round 4"; anything else passes through.
    private var roundLabel: String {
        let detail = game.status.type.detail
        if let cut = detail.range(of: " - ") { return String(detail[detail.startIndex..<cut.lowerBound]) }
        return detail.isEmpty ? "PGA Tour" : detail
    }
}

/// Watches a `FlagBox` without dragging the view that owns it into every
/// change. Same trick as `HubActivationProbe` in the Sports hub.
private struct HeroVisibilityProbe: View {
    @ObservedObject var flag: FlagBox
    let onChange: (Bool) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChangeCompat(of: flag.value) { onChange($0) }
    }
}

/// Swipeable hero carousel backed by TabView(.page) — the most gesture-stable
/// paging API in SwiftUI (uses UIPageViewController underneath). The earlier
/// custom-ScrollView + .scrollTargetBehavior + .scrollPosition(id:) approach
/// left UIScrollView gesture recognisers in a stuck state after a swipe,
/// permanently blocking taps on sibling views. TabView avoids this entirely.
///
/// Nuvio redesign: full-bleed hero exactly like the reference recording —
/// the artwork bleeds behind the status bar, everything anchors to the
/// bottom (title, dot-separated metadata, white capsule pill, page dots),
/// and the image dissolves into the black canvas below. Auto-advances like
/// the reference carousel.
/// Full-bleed hero carousel, ported from Nuvio's `HomeHeroSection.kt`
/// (github.com/luqmanfadlli/NuvioMobile-iOS). That implementation keeps a
/// paging position as `page + offsetFraction`, derives each visible page's
/// alpha from `1 - |offset|`, and moves the backdrop and the text block at
/// DIFFERENT parallax rates — which is what makes the title fade and drift
/// while the artwork barely shifts. Its constants are reproduced below.
///
/// The backdrop is scaled rather than widened: a scale is layout-neutral, so
/// the parallax shift never exposes a bare edge AND the hero can't widen the
/// home layout (sizing pages wider did exactly that, pushing every shelf
/// off-screen).
struct FeaturedCarousel: View {
    let items: [FeaturedItem]
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color
    /// Opens the page's destination — the channel preview popup, or the game
    /// card for a live matchup. Playback starts from there, not from here.
    let openAction: (FeaturedItem) -> Void
    /// How far the home screen has scrolled down, clamped to the hero's own
    /// height. Drives Nuvio's backdrop scroll parallax. NOT observed here —
    /// only the `HeroScrollParallax` leaf watches it, so a scroll frame
    /// re-renders that transform instead of the whole carousel.
    let scroll: ScrollProgress
    /// Whether the home screen is the screen on display.
    ///
    /// Home is kept mounted behind search results and category pages, faded
    /// to zero rather than removed — so the dwell countdown kept running and
    /// the auto-advance kept sliding two full-screen artwork layers for a
    /// hero nobody could see, for as long as the user was anywhere else in
    /// the app. Read through a leaf box, not as a plain `Bool`, so flipping
    /// it doesn't re-evaluate this whole view: only the probe below watches
    /// it. Defaults to "visible" so any other call site behaves as before.
    var visible: FlagBox = FlagBox(true)

    /// Snapped page.
    @State private var page = 0
    /// How far the pager sits past `page`, in pages. Positive while dragging
    /// toward the NEXT card. Everything visual is a function of this.
    /// A LEAF, for the same reason the countdown below is one.
    ///
    /// Nuvio's pager offset feeds nothing but `graphicsLayer` blocks — alpha,
    /// translationX, scale — so dragging its hero re-runs those blocks and
    /// recomposes nothing. As a plain `@State` here, every frame of a swipe
    /// re-evaluated this whole view: both full-screen artwork layers, the title
    /// block, the pill and the dots, sixty to a hundred and twenty times a
    /// second. Held in its own object, a frame of the drag re-renders the two
    /// transform modifiers that read it and nothing else.
    @State private var fraction = ScrollProgress()
    /// 0 → 1 across the dwell time; drives the dot's countdown fill.
    ///
    /// A LEAF, not a plain `@State`. It's animated linearly across the whole
    /// eight-second dwell, and as a value on this view that meant SwiftUI
    /// re-evaluated the carousel's entire body — both page layers, the backdrop
    /// image, the title block, the pill — on every frame of those eight
    /// seconds, on a loop, for as long as the home screen was on screen. That
    /// is a full-screen view rebuilding at 60fps behind everything the user
    /// does, which is exactly what a scroll has to compete with. Only
    /// `NuvioPageDots` observes it now.
    @State private var progress = ScrollProgress()
    /// Bumped when a drag ends, restarting the dwell countdown — so swiping
    /// resets the timer even when the swipe didn't commit.
    @State private var timerKey = 0
    /// Bumped whenever a drag takes over, so an auto-advance that was already
    /// sliding abandons its page commit instead of fighting the finger.
    @State private var advanceToken = 0
    /// Direction of an auto-advance that has been PRE-MOUNTED but hasn't begun
    /// travelling. It exists only so `layers` puts the incoming page in the view
    /// tree one pass before the slide starts — see `autoAdvance`.
    /// The page this transition is moving TO.
    ///
    /// Held in state because the commit rebases `page`, and the two layers must
    /// not swap z-order when it does. Ordering by `rel` alone flipped them at
    /// exactly that moment: the outgoing page went from the bottom of the stack
    /// to the top in one frame, still at most of its alpha, which is the
    /// previous slide flashing over the new one as you let go. Ordering by
    /// destination is stable across the rebase AND doesn't flip mid-drag, which
    /// sorting by visibility did at the halfway crossover.
    ///
    /// Never cleared: by the time it changes again the neighbour is invisible,
    /// so the reorder can't be seen.
    @State private var incomingIndex: Int?

    /// Set for the duration of one drag, so the auto-advance token is bumped
    /// once per gesture instead of once per frame.
    @State private var dragOwnsPager = false

    /// Which neighbouring page is mounted: +1 for the one to the right, -1 to
    /// the left, nil for none. Drags and the auto-advance share it.
    ///
    /// This used to be derived from the fraction's sign, which is what tied
    /// `layers` to a value that changes every frame. Direction changes at most
    /// once per gesture, so holding it separately is what lets the layer list
    /// stay still while the fraction runs.
    @State private var neighbour: Int?

    // ── Nuvio's constants ────────────────────────────────────────────────
    private static let backgroundParallax: CGFloat = 0.055
    private static let backgroundScale: CGFloat = 1.14
    private static let contentParallax: CGFloat = 0.18
    private static let swipeThresholdFraction: CGFloat = 0.16
    /// HERO_SWIPE_VELOCITY_THRESHOLD — a flick this fast commits regardless of
    /// how far it actually travelled.
    private static let swipeVelocityThreshold: CGFloat = 300
    /// How a page settles after a swipe, committed or abandoned.
    ///
    /// Nuvio hands both to `animateScrollToPage`, whose default snap spec in
    /// Compose Foundation is a critically damped spring at stiffness 400 — so
    /// this is that: no overshoot, landing in about a third of a second. It
    /// replaces a pair of hand-picked easeOut curves that differed between
    /// committing and springing back.
    private static let settle: Animation = .spring(response: 0.32, dampingFraction: 1)
    private static let dwell: Double = 8
    /// When to rebase the page index after a settle animation.
    ///
    /// A spring's `response` is not its duration, so this is deliberately past
    /// the point the motion is visually done. Landing late is harmless — both
    /// pages are already at their final positions, the incoming one at rest and
    /// the outgoing one a full page out at zero alpha — whereas landing early
    /// would cut the travel short.
    private static let settleHandoff: Double = 0.5
    /// Two lines of the 30pt title (≈36pt each) + the 13pt gap + the 15pt
    /// metadata line. Reserving it keeps the static pill from being nudged by
    /// a card whose title wraps.
    private static let contentBlockHeight: CGFloat = 104

    private var screenWidth: CGFloat { UIScreen.main.bounds.width }

    /// Fraction of the screen the hero fills. Static because the home screen
    /// measures it too — for the overscroll stretch and the scroll-parallax
    /// clamp — and three copies of the same literal would drift apart.
    ///
    /// Matched to Nuvio by the landmark you actually SEE — where the first
    /// shelf heading sits — measured off the two apps side by side in the app
    /// switcher and expressed as a fraction of screen height:
    ///
    ///     Nuvio  "Continue Watching" at 0.695 x H
    ///     Nebulo "Continue Watching" at 0.626 x H   (60pt high)
    ///     hero bottom -> heading text = 53pt (30pt stack spacing + cap inset)
    ///     heroHeight = 0.695 x H - 53pt = 0.634 x H
    ///
    /// Read the number, not the ratio, if this needs adjusting again: the two
    /// apps have to be at the TOP of their home screens for the comparison to
    /// mean anything, and Nuvio's own heading has measured at both 0.596 and
    /// 0.695 across two different screenshots — so either it wasn't at the top
    /// in one of them, or its hero is sized by its poster's aspect ratio and
    /// isn't a fixed fraction at all. This matches the most recent one.
    static var heroHeight: CGFloat {
        UIScreen.main.bounds.height * 0.634
    }
    private var heroHeight: CGFloat { Self.heroHeight }

    /// The pages worth drawing: the current one, plus whichever neighbour is
    /// mounted. Position and alpha are NOT here — they are applied per layer by
    /// `HeroPageTransform`, which reads the fraction itself.
    ///
    /// Order follows `incomingIndex`, not the live fraction: sorting by
    /// visibility needed a value that changes every frame, and it swapped the
    /// two layers' z-order as the swipe passed halfway.
    private var layers: [(index: Int, rel: Int)] {
        let n = items.count
        guard n > 0 else { return [] }
        var rels: [Int] = [0]
        if n > 1, let neighbour { rels.append(neighbour) }
        // Deliberately NOT culled at visibility 0 — a page that is mounted but
        // invisible is what lets the slide animate its offset instead of the
        // view being inserted at its destination.
        return rels
            .map { (index: (($0 + page) % n + n) % n, rel: $0) }
            // Destination last, so it composites on top for the whole
            // transition — see `incomingIndex`.
            .sorted { ($0.index == incomingIndex ? 1 : 0) < ($1.index == incomingIndex ? 1 : 0) }
    }

    /// The card the static pill belongs to: the most visible layer, which is
    /// the last one after the least-visible-first sort. Nuvio resolves its
    /// button's target the same way, so the label and destination always match
    /// the words you're actually reading.
    /// Nuvio reads `pagerState.currentPage` for its button's target, so this
    /// follows the settled page too — and stays off the live fraction, which
    /// would drag this whole body into every frame of a swipe.
    private var currentItem: FeaturedItem? {
        guard !items.isEmpty else { return nil }
        return items[min(page, items.count - 1)]
    }

    private var pillTitle: String { currentItem?.game != nil ? "Watch" : "Watch Now" }

    private func open(_ item: FeaturedItem) {
        guard SwipeTapGuard.tapsAllowed else { return }
        viewModel.triggerSelectionHaptic()
        openAction(item)
    }

    /// Steps to a neighbouring page WITHOUT any deferred work: the page index
    /// moves now and the fraction is rebased by the same amount, which leaves
    /// the two layers in pixel-identical positions. Then the fraction eases to
    /// zero. Because nothing is scheduled for later, a second fast swipe lands
    /// on clean state instead of colliding with a pending hand-off.
    private func step(_ delta: Int) {
        guard items.count > 1 else { return }
        let n = items.count
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            page = ((page + delta) % n + n) % n
            fraction.set(fraction.value - CGFloat(delta))
            // The page just left behind, so it can finish sliding out.
            neighbour = -delta
            // Zero the countdown in the SAME unanimated pass as the page. Left
            // to the `.task` below, it lands a frame or more later, so the dots
            // draw at least once with the OUTGOING page's nearly-finished
            // progress — which is the white flash before the dot settles back
            // to grey.
            progress.set(0)
        }
        withAnimation(Self.settle) { fraction.set(0) }
        // Drop the page just left behind once it has finished sliding out. It
        // is invisible by then, so nothing is seen to disappear — and leaving it
        // mounted means a second full-screen texture and a second shadowed text
        // block being composited at rest, for a page nobody can see. Guarded by
        // the token so a drag that starts in the meantime keeps its own
        // neighbour.
        let token = advanceToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleHandoff) {
            guard advanceToken == token else { return }
            neighbour = nil
        }
    }

    /// The AUTO-advance, which has to travel the whole page to read as a slide.
    ///
    /// It animates the fraction OUTWARD to a full page — exactly the path a
    /// finger takes when it drags all the way across — and rebases the page
    /// index only once that animation has landed.
    ///
    /// The catch, and why this dissolved rather than slid: at rest the incoming
    /// page ISN'T IN THE VIEW TREE. `layers` only carries a neighbour while the
    /// fraction is non-zero, so animating 0 → 1 in one pass hands SwiftUI a tree
    /// where the outgoing page has vanished and the incoming one has appeared at
    /// its final offset. There are no matching identities to interpolate between,
    /// so it applies the default transition to each — an opacity fade. A drag
    /// looks right for exactly the opposite reason: the finger has already put
    /// the fraction somewhere non-zero, so both pages are mounted before
    /// anything animates.
    ///
    /// So the travel is split across two update passes: mount the neighbour
    /// off-screen first, then animate. Both pages are then present throughout
    /// and SwiftUI interpolates their offsets — the same slide a swipe gives.
    private func autoAdvance() {
        guard items.count > 1 else { return }
        let token = advanceToken

        // Pass 1: put the incoming page in the tree at its off-screen resting
        // place. Unanimated, and nothing moves — at visibility 0 it can't be
        // seen.
        var mount = Transaction()
        mount.disablesAnimations = true
        withTransaction(mount) {
            neighbour = 1
            incomingIndex = (page + 1) % items.count
        }

        // Pass 2, next frame: now that both pages exist, the fraction can be
        // animated and their offsets interpolate. The delay only has to outlast
        // the current update; a frame is 16ms.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            // A drag that arrived in between bumped the token and owns the
            // fraction now; drop the pre-mount and leave the finger alone.
            guard advanceToken == token else {
                neighbour = nil
                return
            }
            // The SAME spec a swipe settles with. Nuvio hands its auto-advance
            // to `animateScrollToPage` exactly as it hands a manual commit, so
            // an idle slide travels at the speed of a thrown one.
            withAnimation(Self.settle) { fraction.set(1) }
            // SCHEDULED, not a completion handler. A completion that shares its
            // transaction with another animation in the same subtree can simply
            // never arrive — the dock's lens hop was left frozen mid-swell by
            // exactly that — and if this one went missing the carousel would
            // stall a page out forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleHandoff) {
                // `items` can shrink while the slide is in flight (a live game
                // ends and its channel drops out), and an empty list would make
                // the modulo below divide by zero.
                guard advanceToken == token, items.count > 1 else {
                    neighbour = nil
                    return
                }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    page = (page + 1) % items.count
                    fraction.set(0)
                    progress.set(0)
                    neighbour = nil
                }
            }
        }
    }

    var body: some View {
        ZStack {
            // ── Artwork, barely shifting, scaled so the shift never bares an
            //    edge. Alpha is the page's visibility.
            ForEach(layers, id: \.index) { layer in
                NuvioHeroBackdrop(item: items[layer.index],
                                  height: heroHeight,
                                  program: viewModel.getCurrentProgram(for: items[layer.index].channel))
                    // Flattened to ONE texture before anything transforms or
                    // fades it. A backdrop is an image plus gradients — several
                    // children — so an opacity below 1 on it forces the whole
                    // subtree into an offscreen buffer before it can be blended,
                    // and mid-swipe BOTH backdrops are partly transparent. That
                    // is two full-screen flattens per frame, redone every frame
                    // because the alpha keeps moving, which is the frame loss
                    // during a swipe. Rasterised once, the scale, the shift and
                    // the fade are three cheap operations on a single layer.
                    //
                    // Placed INSIDE the parallax deliberately: outside it, the
                    // scroll scale would change the rasterised size and re-draw
                    // the texture on every frame of a vertical scroll instead.
                    .drawingGroup()
                    // Scroll parallax + the carousel's base scale, then the
                    // page's own sideways parallax on top (so the horizontal
                    // shift isn't multiplied by the scale, matching Nuvio's
                    // single graphicsLayer).
                    .modifier(HeroScrollParallax(scroll: scroll, baseScale: Self.backgroundScale))
                    .modifier(HeroPageTransform(fraction: fraction,
                                                rel: layer.rel,
                                                width: screenWidth,
                                                parallax: Self.backgroundParallax))
            }

            // ── The dissolve into the black canvas is drawn ONCE, not per
            //    page, so it never double-composites mid-transition.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.42),
                    .init(color: .black.opacity(0.55), location: 0.72),
                    .init(color: .black.opacity(0.96), location: 0.94),
                    .init(color: .black, location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)

            // ── Title · metadata move and cross-dissolve at roughly three
            //    times the backdrop's parallax; the pill below them is drawn
            //    ONCE and never moves, exactly as Nuvio arranges its hero
            //    column (layered text block, then a static button).
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                ZStack(alignment: .bottom) {
                    ForEach(layers, id: \.index) { layer in
                        let item = items[layer.index]
                        NuvioHeroContent(
                            channel: item.channel,
                            program: viewModel.getCurrentProgram(for: item.channel),
                            categoryName: viewModel.categories.first(where: { $0.id == item.channel.categoryID })?.name,
                            game: item.game,
                            onPlay: { open(item) }
                        )
                        .frame(width: screenWidth)
                        .modifier(HeroPageTransform(fraction: fraction,
                                                    rel: layer.rel,
                                                    width: screenWidth,
                                                    parallax: Self.contentParallax))
                        // Only the settled page takes taps, as Nuvio only wires
                        // its current page's button. Reading the live fraction
                        // here would put this body back on every frame.
                        .allowsHitTesting(layer.rel == 0)
                    }
                }
                // A FIXED, bottom-aligned block: a two-line title grows UPWARD
                // into the artwork instead of shoving the pill down, so the
                // button holds still from card to card as well as mid-swipe.
                .frame(height: Self.contentBlockHeight, alignment: .bottom)

                // Reproduces the old spacing exactly: the 13pt stack gap plus
                // the pill's 3pt top inset.
                Spacer().frame(height: 16)

                // ── The call to action, drawn ONCE outside the layers. It
                //    neither travels nor fades; only its label and target
                //    follow whichever card is in front.
                NuvioPillButton(title: pillTitle) {
                    guard let item = currentItem else { return }
                    open(item)
                }
                // The label only ever swaps between "Watch" and "Watch Now" —
                // never let that ride the swipe's ease-out.
                .animation(nil, value: pillTitle)
            }
            .padding(.bottom, 44)
        }
        .frame(height: heroHeight)
        // Clips after the parallax offsets, so the scaled artwork covers the
        // full width at every point of the gesture.
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    let dx = value.translation.width
                    guard abs(dx) > abs(value.translation.height) else { return }
                    // A horizontal drag over the hero must not also fire the
                    // page's tap action on release.
                    SwipeTapGuard.suppress()
                    guard items.count > 1 else { return }
                    // The finger now owns the fraction — cancel any in-flight
                    // auto-advance's page commit, and drop its pre-mount (the
                    // non-zero fraction below mounts the right neighbour for
                    // whichever way this drag is going).
                    // ONCE per gesture. This was `advanceToken += 1` on every
                    // frame — a plain `@State` write per frame, which
                    // re-evaluated this whole view sixty times a second and
                    // undid the point of holding the fraction in a leaf.
                    if !dragOwnsPager {
                        dragOwnsPager = true
                        advanceToken += 1
                    }
                    // Mount the neighbour this drag is heading toward, and mark
                    // it as the destination for z-order. Assigned only when the
                    // direction actually changes, so it is one or two renders
                    // per gesture rather than one per frame.
                    let heading = dx < 0 ? 1 : -1
                    if neighbour != heading {
                        neighbour = heading
                        let n = items.count
                        if n > 0 { incomingIndex = ((page + heading) % n + n) % n }
                    }
                    fraction.set(max(-1, min(1, -dx / screenWidth)))
                }
                .onEnded { value in
                    let dx = value.translation.width
                    defer { timerKey += 1; dragOwnsPager = false }
                    guard items.count > 1, abs(dx) > abs(value.translation.height) else {
                        withAnimation(Self.settle) { fraction.set(0) }
                        return
                    }
                    // Nuvio's resolveHeroTargetPage: commit on a sixth of the
                    // width OR on 300pt/s of velocity, whichever comes first.
                    let travelled = abs(dx) > screenWidth * Self.swipeThresholdFraction
                    let thrown = abs(value.velocity.width) > Self.swipeVelocityThreshold
                    if travelled || thrown {
                        step(dx < 0 ? 1 : -1)
                    } else {
                        withAnimation(Self.settle) { fraction.set(0) }
                    }
                }
        )
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                NuvioPageDots(count: items.count, index: page, progress: progress)
                    .padding(.bottom, 14)
                    .allowsHitTesting(false)
            }
        }
        // Keyed to the page AND the drag generation, so any page change or
        // finished swipe cancels and restarts the countdown from zero.
        .task(id: "\(page)-\(timerKey)") {
            progress.set(0)
            guard items.count > 1 else { return }
            // Nothing to count down to while the hero is off screen. The
            // probe below restarts the countdown the moment home comes back.
            guard visible.value else { return }
            withAnimation(.linear(duration: Self.dwell)) { progress.set(1) }
            try? await Task.sleep(nanoseconds: UInt64(Self.dwell * 1_000_000_000))
            // Never auto-advance out from under a finger that is still mid-swipe.
            guard !Task.isCancelled, fraction.value == 0, visible.value else { return }
            autoAdvance()
        }
        .background(
            HeroVisibilityProbe(flag: visible) { _ in
                // Bumping the key restarts the `.task` above: it stops the
                // countdown on the way out and starts a fresh one on the way
                // back, so the hero never returns mid-dwell.
                timerKey += 1
            }
        )
        // The featured list can shrink in place (a live game ends and its
        // channel drops out) — clamp so the pager never points past the end.
        .onChangeCompat(of: items.count) { n in
            if page >= n { page = 0 }
        }
    }
}

/// The hero's ARTWORK layer — the part that barely moves and is scaled up so
/// the parallax shift never exposes an edge. Three variants:
///   • Matchup — team-colour washes meeting in the middle, big crests.
///   • Programme photo — a still of whatever is on, exactly as the spotlight
///     cards do it: the guide's own image when it ships one, otherwise a
///     lookup on the programme title (TVmaze, then Wikipedia), which is what
///     puts a picture of the host on a talk or news hour.
///   • Channel — a wash built from the logo's own brand colour, with the sharp
///     logo floating in the upper half. The fallback when there's no photo to
///     be had.
struct NuvioHeroBackdrop: View {
    let item: FeaturedItem
    let height: CGFloat
    /// What's on right now, for the programme photo. Resolved by the carousel,
    /// which already looks it up for the title block.
    var program: EPGProgram? = nil

    /// Bumped once the logo's colour lands in the shared cache, purely to
    /// trigger a re-render.
    @State private var glowTick = 0
    /// Artwork found for the programme title when the guide shipped no still.
    @State private var fetchedArt: String?

    private var channel: StreamChannel { item.channel }
    private var game: ESPNEvent? { item.game }

    /// The photo to fill the hero with, if there is one.
    private var still: String? {
        if let image = program?.image, !image.isEmpty { return image }
        return fetchedArt
    }

    private var hasMatchup: Bool {
        game?.homeCompetitor?.team?.logo != nil && game?.awayCompetitor?.team?.logo != nil
    }

    /// Read from the process-wide cache on every render so it always matches
    /// THIS card's channel. Held in `@State`, a view reused for a different
    /// card kept the previous channel's colour for a frame and flashed.
    private var glow: Color? {
        guard let icon = channel.icon, !icon.isEmpty else { return nil }
        _ = glowTick
        return LogoGlow.cache[icon]
    }

    private func teamColor(_ c: ESPNCompetitor?) -> Color {
        guard let hex = c?.team?.color, !hex.isEmpty else { return Color(white: 0.22) }
        return Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)") ?? Color(white: 0.22)
    }

    var body: some View {
        Group {
            if hasMatchup, let g = game {
                let away = g.awayCompetitor
                let home = g.homeCompetitor
                ZStack {
                    Color(white: 0.06)
                    // Each team's colour floods from its side PAST the centre,
                    // so the two washes meet instead of leaving a dead band.
                    LinearGradient(
                        colors: [teamColor(away).opacity(0.85), teamColor(away).opacity(0.0)],
                        startPoint: .leading,
                        endPoint: UnitPoint(x: 0.72, y: 0.5)
                    )
                    LinearGradient(
                        colors: [teamColor(home).opacity(0.85), teamColor(home).opacity(0.0)],
                        startPoint: .trailing,
                        endPoint: UnitPoint(x: 0.28, y: 0.5)
                    )
                    HStack(spacing: 0) {
                        CachedAsyncImage(urlString: away?.team?.logo ?? "",
                                         size: CGSize(width: 150, height: 150))
                            .frame(maxWidth: .infinity)
                        CachedAsyncImage(urlString: home?.team?.logo ?? "",
                                         size: CGSize(width: 150, height: 150))
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 16)
                    .opacity(0.9)
                    .offset(y: -height * 0.13)
                }
            } else if let still {
                let width = UIScreen.main.bounds.width
                ZStack {
                    // Cropped to fill the whole hero, and decoded at that size
                    // — the shared 300x300 default would be upscaled here and
                    // look soft. `size:` IS the frame, not just a decode hint.
                    CachedAsyncImage(urlString: still,
                                     size: CGSize(width: width, height: height),
                                     contentMode: .fill,
                                     decodeSize: CGSize(width: width, height: height))
                        .frame(width: width, height: height)
                        .clipped()

                    // A gentle floor under the title block. The carousel draws
                    // its own dissolve over every layer, so this only has to
                    // cover the case of a photo that's bright at the bottom.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.38),
                            .init(color: .black.opacity(0.40), location: 0.70),
                            .init(color: .black.opacity(0.72), location: 1.0)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            } else {
                let base = glow ?? Color(white: 0.28)
                ZStack {
                    // Solid brand tone across the whole backdrop — the same
                    // colour the channel's cards are filled with — with the
                    // brighter glow pooling behind the logo for depth.
                    LogoGlow.tone(for: channel.icon) ?? Color(white: 0.13)
                    RadialGradient(
                        colors: [base.opacity(0.55), .clear],
                        center: UnitPoint(x: 0.5, y: 0.34),
                        startRadius: 0,
                        endRadius: height * 0.55
                    )
                    CachedAsyncImage(urlString: channel.icon ?? "", size: nil)
                        .frame(maxWidth: 190, maxHeight: 190)
                        .offset(y: -height * 0.17)

                    // A dark logo gets a PALE tile so it can be seen at all
                    // (see LogoGlow.brandSample) — but the hero's white title
                    // and metadata sit over the lower half, so that half has to
                    // come back down to dark. The carousel's shared dissolve
                    // alone isn't enough over a light field.
                    if LogoGlow.isLightTone(for: channel.icon) {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.30),
                                .init(color: .black.opacity(0.55), location: 0.58),
                                .init(color: .black.opacity(0.88), location: 0.80)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                }
                .task(id: channel.icon) {
                    guard let icon = channel.icon, LogoGlow.cache[icon] == nil else { return }
                    _ = await LogoGlow.color(for: icon)
                    glowTick += 1
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        // Only when the guide gave us nothing: look the programme up. Results
        // (including misses) are cached on disk, so it's one request per title
        // ever, and the hero shows its brand treatment until it lands.
        .task(id: program?.title) {
            fetchedArt = nil
            guard let title = program?.title, !title.isEmpty,
                  (program?.image ?? "").isEmpty else { return }
            fetchedArt = await ProgramArtworkService.shared.artwork(for: title)
        }
    }
}

/// The hero's MOVING content — big title and dot-separated metadata only.
/// Travels at roughly three times the backdrop's parallax and fades with the
/// page, which is what reads as the title sliding and dissolving.
///
/// The Watch pill is deliberately NOT here: Nuvio draws its call-to-action
/// once, outside the per-page layers, so the button holds absolutely still
/// while the words slide and cross-dissolve behind it. `FeaturedCarousel`
/// owns it.
struct NuvioHeroContent: View {
    let channel: StreamChannel
    let program: EPGProgram?
    let categoryName: String?
    var game: ESPNEvent? = nil
    let onPlay: () -> Void

    private var hasMatchup: Bool {
        game?.homeCompetitor?.team?.logo != nil && game?.awayCompetitor?.team?.logo != nil
    }

    private var metadataParts: [String] {
        if let g = game {
            var parts: [String] = []
            parts.append(g.status.type.state == "in" ? "Live" : g.status.type.detail)
            if g.status.type.state == "in" { parts.append(g.status.type.detail) }
            if let network = g.broadcastName, !network.isEmpty { parts.append(network) }
            return parts
        }
        // What's on, and nothing else — the category a channel happens to be
        // filed under isn't information anyone wants on a hero card.
        var parts: [String] = []
        if let prog = program { parts.append(prog.title) }
        if parts.isEmpty { parts = ["Live TV"] }
        return parts
    }

    var body: some View {
        VStack(spacing: 13) {
            Group {
                if hasMatchup, let g = game {
                    let away = g.awayCompetitor?.team?.shortDisplayName ?? "—"
                    let home = g.homeCompetitor?.team?.shortDisplayName ?? "—"
                    if g.status.type.state == "pre" {
                        Text("\(away) vs \(home)")
                    } else {
                        Text("\(away) \(g.awayCompetitor?.score ?? "0") – \(g.homeCompetitor?.score ?? "0") \(home)")
                    }
                } else {
                    // Country prefix, quality tag and regional affiliate all
                    // stripped: "US: NBC Sports Bay Area FHD" reads as
                    // "NBC Sports".
                    Text(NameCleaner.simplifiedBrand(channel.name))
                }
            }
            .font(.system(size: 30, weight: .heavy))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 28)
            .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 2)

            NuvioMetadataLine(parts: metadataParts)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
    }
}

// MARK: - Category Grouping
// Classifies user categories into broader genre buckets for the home screen
// shelves. Uses keyword matching against the lowercased category name with
// common country-code prefixes (e.g. "US:", "UK -") stripped out first.

enum HomeCategoryGroup: String, CaseIterable, Hashable {
    case sports        = "Sports"
    case news          = "News"
    case movies        = "Movies"
    case kids          = "Kids"
    case documentary   = "Documentaries"
    case lifestyle     = "Lifestyle"
    case international = "International"
    case other         = "More"

    var icon: String {
        switch self {
        case .sports:        return "sportscourt.fill"
        case .news:          return "newspaper.fill"
        case .movies:        return "film.fill"
        case .kids:          return "face.smiling.fill"
        case .documentary:   return "books.vertical.fill"
        case .lifestyle:     return "leaf.fill"
        case .international: return "globe"
        case .other:         return "rectangle.grid.2x2.fill"
        }
    }

    /// Strip common country-code prefixes ("US:", "USA |", "UK -", etc.) so
    /// that "US: Animal Planet" still classifies as Documentary.
    /// Compiled once — building an NSRegularExpression on every call made
    /// classification measurably slow on hot paths.
    nonisolated private static let prefixRegex = try? NSRegularExpression(pattern: #"^([a-z]{2,4})\s*[:|\-–—]\s*"#)

    nonisolated private static func cleanedName(_ raw: String) -> String {
        let lowered = raw.lowercased()
        if let regex = prefixRegex {
            let range = NSRange(lowered.startIndex..., in: lowered)
            return regex.stringByReplacingMatches(in: lowered, options: [], range: range, withTemplate: "")
        }
        return lowered
    }

    nonisolated private static func contains(_ haystack: String, _ keywords: [String]) -> Bool {
        keywords.contains { haystack.contains($0) }
    }

    nonisolated static func classify(_ category: StreamCategory) -> HomeCategoryGroup {
        let n = cleanedName(category.name)

        // Sports — checked FIRST so "Fox Sports", "ESPN", "Bein Sport", etc. never leak
        // into news. Covers all mainstream and niche sports worldwide.
        if contains(n, [
            // Generic
            "sport", "deport", "ppv", "pay-per-view", "pay per view",
            // Football / Soccer
            "football", "soccer", "fútbol", "futbol",
            "nfl", "ncaa", "college football",
            "premier league", "champions league", "europa league", "conference league",
            "mls", "la liga", "serie a", "bundesliga", "ligue 1", "liga mx",
            "eredivisie", "primeira liga", "super lig",
            "brasileirao", "brasileirão", "campeonato brasileiro",
            "j league", "j-league", "j1 league",
            "k league", "k-league",
            "a-league", "a league",
            "scottish premiership", "scottish prem", "spfl",
            "efl", "fa cup", "carabao cup", "dfb pokal", "coppa italia", "copa del rey",
            "copa america", "euro ", "euros ", "world cup",
            "africa cup", "afcon", "concacaf", "libertadores", "sudamericana",
            // Basketball
            "nba", "basketball", "wnba", "euroleague", "fiba",
            // Baseball / Hockey
            "mlb", "nhl", "baseball", "hockey",
            // Combat sports
            "ufc", "wwe", "aew", "boxing", "bellator", "pfl", "mma", "wrestling",
            "kickboxing", "muay thai", "judo", "taekwondo", "karate",
            // Motorsport
            "motogp", "moto gp", "f1", "formula 1", "formula one", "nascar",
            "indycar", "racing", "race ", "supercross", "superbike",
            "dtm", "wrc", "rally", "le mans", "lemans", "endurance racing",
            // Golf
            "golf", "pga", "lpga",
            // Tennis
            "tennis", "atp", "wta", "wimbledon", "us open tennis",
            // Cricket
            "cricket", "ipl", "bbl", "test match",
            // Rugby
            "rugby", "nrl", "afl", "gaelic",
            // Olympic / multi-sport
            "olympic", "paralympic",
            // Networks
            "espn", "beinsport", "bein sport", "sky sport", "fox sport",
            "nbcsn", "golf channel", "tennis channel", "tnt sport",
            "dazn", "eleven sport",
            // Darts / Snooker / Cue sports
            "darts", "snooker", "billiard",
            // Cycling
            "cycling", "tour de france", "giro d'italia", "giro d italia",
            "vuelta a españa", "vuelta a espana", "velodrome",
            // Athletics / Track and Field
            "athletics", "track and field", "marathon",
            // Swimming / Aquatics
            "swimming", "aquatic",
            // Gymnastics / Winter sports
            "gymnastics", "figure skat", "biathlon", "curling", "bobsled", "luge",
            "ski", "skiing", "snowboard",
            // Volleyball / Handball / Water polo / Racket
            "volleyball", "handball", "waterpolo", "water polo",
            "badminton", "table tennis", "ping pong", "squash",
            // Esports / Gaming
            "esport", "e-sport", "esports", "gaming league",
            // Horse racing / Equestrian
            "horse racing", "equestrian",
            // Poker / Card
            "poker", "wsop",
            // Misc
            "kabaddi", "sumo", "netball", "lacrosse", "field hockey",
            "beach volley", "beach soccer", "futsal"
        ]) { return .sports }

        // News — major broadcast networks (ABC, NBC, CBS, PBS, Fox) plus cable/intl news.
        // Comes after Sports so "Fox Sports" is already captured, leaving plain "Fox" for news.
        if contains(n, [
            "news", "noticias",
            // US broadcast & cable
            "abc", "nbc", "cbs", "pbs", "fox",
            "cnn", "msnbc", "cnbc", "bloomberg", "cspan", "oann", "newsmax",
            // International
            "bbc", "sky news", "itv", "channel 4", "channel 5",
            "ctv", "cbc", "sbs",
            "al jazeera", "france 24", "dw", "euronews", "trt world",
            "abc news", "nbc news", "cbs news"
        ]) { return .news }

        // Kids — checked before Movies so "Disney Channel" / "Cartoon Network"
        // map to Kids rather than Movies. Common kids networks worldwide.
        if contains(n, [
            "kids", "child", "children",
            "cartoon", "cartoons",
            "nick", "nickelodeon", "nick jr", "nickjr",
            "disney",
            "cbeebies", "cbbc", "milkshake",
            "pbs kids", "pbskids",
            "boomerang", "cartoonito",
            "baby tv", "babyfirst", "babytv",
            "cocomelon", "paw patrol", "peppa", "sesame"
        ]) { return .kids }

        // Movies — checked before documentaries so "movie history" still hits Movies.
        if contains(n, [
            "movie", "movies", "film", "films", "cinema", "cinemax",
            "hbo", "showtime", "starz", "epix",
            "mgm", "tcm", "amc", "fxm", "fxx",
            "thriller", "horror", "action", "drama", "romance",
            "blockbuster", "indie", "independent film",
            "bollywood", "hollywood", "kollywood",
            "24/7", "marathon", "saga", "franchise"
        ]) { return .movies }

        if contains(n, ["doc", "history", "discovery", "national geographic", "nat geo",
                        "smithsonian", "science", "animal planet", "viasat"]) { return .documentary }

        if contains(n, ["food", "cooking", "home", "garden", "travel", "lifestyle", "fashion",
                        "hgtv", "diy", "fitness", "health", "wellness"]) { return .lifestyle }

        // International — country names, language identifiers, and regional labels.
        // Checked after all specific genres so e.g. "France 24" (news) is already matched.
        if contains(n, [
            // Regional / group labels
            "international", "world", "global",
            "latin", "latino", "latina", "hispanic",
            "africa", "afrique", "asia", "europe", "middle east",
            // Language names
            "arabic", "français", "french", "deutsch", "german",
            "español", "spanish", "italiano", "italian",
            "português", "portuguese",
            "hindi", "urdu", "farsi", "persian",
            "turkish", "korean", "japanese", "chinese", "mandarin", "cantonese",
            "russian", "polish", "romanian", "hungarian", "czech", "slovak",
            "bulgarian", "serbian", "croatian", "albanian", "greek", "hebrew",
            "ukrainian", "armenian", "azerbaijani", "georgian",
            "thai", "vietnamese", "indonesian", "malay", "tagalog", "filipino",
            "punjabi", "bengali", "tamil", "telugu", "marathi", "gujarati",
            "swahili", "somali", "amharic", "hausa",
            // Country names
            "france", "germany", "spain", "italy", "portugal",
            "brazil", "mexico", "argentina", "colombia", "venezuela",
            "chile", "peru", "ecuador", "bolivia", "paraguay", "uruguay",
            "india", "pakistan", "bangladesh", "nepal", "sri lanka",
            "china", "japan", "korea", "taiwan", "thailand", "vietnam",
            "philippines", "indonesia", "malaysia", "singapore", "myanmar",
            "turkey", "iran", "iraq", "saudi", "egypt", "algeria", "morocco",
            "tunisia", "nigeria", "kenya", "ghana", "ethiopia", "tanzania",
            "south africa", "cameroon", "ivory coast", "senegal",
            "australia", "new zealand",
            "poland", "romania", "hungary", "ukraine", "russia",
            "netherlands", "belgium", "sweden", "norway", "denmark", "finland",
            "austria", "switzerland", "israel", "lebanon", "jordan", "syria",
            "qatar", "uae", "kuwait", "bahrain", "oman"
        ]) { return .international }

        return .other
    }
}



