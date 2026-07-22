import SwiftUI
import Combine

/// Closes the game-detail presentation. The detail is shown as a custom
/// in-hierarchy overlay (not a system sheet), so `@Environment(\.dismiss)`
/// no longer reaches it — the presenter injects this closure instead, and
/// the content views call it exactly where they used to call `dismiss()`.
private struct GameDetailDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var gameDetailDismiss: () -> Void {
        get { self[GameDetailDismissKey.self] }
        set { self[GameDetailDismissKey.self] = newValue }
    }
}

/// Closes the player-stats carousel. Injected by `PlayerSheetContainer` so a
/// player page can dismiss itself when overscrolled past its own top.
private struct PlayerSheetDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var playerSheetDismiss: () -> Void {
        get { self[PlayerSheetDismissKey.self] }
        set { self[PlayerSheetDismissKey.self] = newValue }
    }
}

/// Reports whether the detail's vertical scroll is at its top, so the
/// presenter's dismiss drag knows when a downward swipe (from the header strip
/// or anywhere in the content) should grab and slide the whole card off
/// instead of scrolling — the way a system sheet only dismisses from its top.
private struct GameDetailAtTopKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}
extension EnvironmentValues {
    var gameDetailAtTop: (Bool) -> Void {
        get { self[GameDetailAtTopKey.self] }
        set { self[GameDetailAtTopKey.self] = newValue }
    }
}

/// The presenter's "dismiss drag is engaged" latch, handed down so the content
/// only cancels its top rubber-band while the card is actually being pulled to
/// dismiss — leaving the normal elastic bounce intact when you just scroll up
/// into the top.
private struct GameDetailDragActiveKey: EnvironmentKey {
    static let defaultValue: ValueBox<Bool>? = nil
}
extension EnvironmentValues {
    var gameDetailDragActive: ValueBox<Bool>? {
        get { self[GameDetailDragActiveKey.self] }
        set { self[GameDetailDragActiveKey.self] = newValue }
    }
}

/// Player-carousel counterparts of `gameDetailAtTop` / `gameDetailDragActive`.
private struct PlayerSheetAtTopKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}
extension EnvironmentValues {
    var playerSheetAtTop: (Bool) -> Void {
        get { self[PlayerSheetAtTopKey.self] }
        set { self[PlayerSheetAtTopKey.self] = newValue }
    }
}

private struct PlayerSheetDragActiveKey: EnvironmentKey {
    static let defaultValue: ValueBox<Bool>? = nil
}
extension EnvironmentValues {
    var playerSheetDragActive: ValueBox<Bool>? {
        get { self[PlayerSheetDragActiveKey.self] }
        set { self[PlayerSheetDragActiveKey.self] = newValue }
    }
}

/// The little grey grab handle centered at the top of a detail/stat card —
/// the sheet-style affordance that says "drag me down to close".
private struct CardGrabber: View {
    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.4))
            .frame(width: 36, height: 5)
            .padding(.top, 8)
            .allowsHitTesting(false)
    }
}

/// Everything a soccer player-stats carousel needs, published up from the
/// tapped card to the presenter so the carousel can be shown full-screen
/// above the whole detail (not clipped inside the detail card). Equated by
/// `key` only — the heat-points closure isn't `Equatable`.
struct SoccerPlayerSheetData: Equatable {
    let key: String
    let players: [GDLineupPlayer]
    let initialID: String
    let side: GDTeamSide
    let topRatedID: String?
    let heatPoints: (String) -> [GDHeatPoint]
    static func == (l: SoccerPlayerSheetData, r: SoccerPlayerSheetData) -> Bool { l.key == r.key }
}

struct BoxPlayerSheetData: Equatable {
    let key: String
    let players: [BoxSheetPlayer]
    let initialID: String
    let side: GDTeamSide
    let topRatedID: String?
    static func == (l: BoxPlayerSheetData, r: BoxPlayerSheetData) -> Bool { l.key == r.key }
}

/// Shared between the detail cards and their presenter: a tapped player sets
/// one of these, and the presenter renders the corresponding carousel over
/// the whole detail. Lifting it out of the card is what lets the player
/// carousel be the full screen width (peeking neighbours from the true
/// screen edge, like the games) and keeps a downward swipe on it from also
/// dragging the detail card behind it.
final class PlayerSheetHost: ObservableObject {
    @Published var soccer: SoccerPlayerSheetData?
    @Published var box: BoxPlayerSheetData?
    var isPresenting: Bool { soccer != nil || box != nil }
    func dismiss() { soccer = nil; box = nil }
}

/// Presents `GameDetailView` as a full-screen overlay layered directly over
/// the app, rather than as a system `.sheet`. A sheet at its full-height
/// detent forces iOS's card-stack presentation — it scales the presenter
/// down and darkens it, which no `presentationBackground`/`interaction`
/// combination fully removes. Presenting in-hierarchy keeps the Sports Hub
/// rendering live and undimmed behind the cards, lets the cards run flush to
/// the screen's real bottom edge, and hands corner + dismiss control back to
/// us. Drag down from the top of the card to dismiss.
struct GameDetailPresenter: View {
    let request: GameDetailRequest
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    let accentColor: Color
    let onDismiss: () -> Void

    /// Starts one full screen down so the card slides UP into place on appear
    /// while the black backdrop is already painted behind it. The presenter
    /// itself mounts with no transition (see ContentView), which is what keeps
    /// the backdrop from travelling with the card.
    @State private var dragY: CGFloat = UIScreen.main.bounds.height
    /// True while the detail's vertical scroll is at its top — the dismiss
    /// drag only engages then, so mid-content scrolling is never hijacked.
    @State private var atTop = ValueBox(true)
    /// Latched once the dismiss drag takes over, with the finger translation
    /// captured at that instant. Subtracting the baseline means the card
    /// tracks the finger from where the drag engaged — so a swipe that first
    /// scrolls up to the top and keeps going doesn't make the card jump.
    @State private var dragEngaged = ValueBox(false)
    @State private var dragBaseline = ValueBox<CGFloat>(0)
    /// The gap-filling black backdrop's opacity. Fades in on appear at the same
    /// pace it fades out, held solid through the whole swipe, then faded out
    /// once the card is fully off-screen so the Sports Hub reappears.
    @State private var tintOpacity: CGFloat = 0
    @StateObject private var playerHost = PlayerSheetHost()

    var body: some View {
        ZStack {
            // Strong black tint filling the gaps above and between the cards:
            // the Sports Hub stays faintly visible behind it but isn't easy to
            // read through. Stays solid through the whole swipe, then fades out
            // once the card is gone so the hub comes back.
            Color.black.opacity(tintOpacity)
                .ignoresSafeArea()

            GameDetailView(request: request, viewModel: viewModel, scoreViewModel: scoreViewModel, accentColor: accentColor)
                .environment(\.gameDetailDismiss, onDismiss)
                // The content reports when it's scrolled to the top; only then
                // does a downward drag grab the whole card to dismiss.
                .environment(\.gameDetailAtTop) { atTop.value = $0 }
                // Lets the content cancel its rubber-band only while the card
                // is being dragged to dismiss — normal top bounce stays.
                .environment(\.gameDetailDragActive, dragEngaged)
                .environmentObject(playerHost)
                .offset(y: dragY)
                // No compositingGroup: for a pure translation it forces the
                // whole heavy subtree to re-flatten every frame, which made the
                // slide less smooth than the (ungrouped) player card. Letting
                // the already-rendered layers just translate matches it.
                .ignoresSafeArea(edges: .bottom)
                // While a player carousel is up it owns all touches (its own
                // clear backing sits on top), so this gesture never fires and
                // the detail card stays put under it.
                .simultaneousGesture(dismissGesture)

            // Player stats live here — a sibling ABOVE the whole detail, not
            // inside a detail card — so the carousel spans the full screen
            // width and its clear backing blocks the detail's own swipe.
            if let data = playerHost.soccer {
                PlayerSheetContainer(onDismiss: { playerHost.dismiss() }) {
                    PlayerStatsSheet(
                        players: data.players, initialID: data.initialID, side: data.side,
                        showPhotos: true, topRatedID: data.topRatedID, heatPoints: data.heatPoints
                    )
                }
                .transition(.move(edge: .bottom))
                .zIndex(20)
            }
            if let data = playerHost.box {
                PlayerSheetContainer(onDismiss: { playerHost.dismiss() }) {
                    BoxPlayerStatsSheet(
                        players: data.players, initialID: data.initialID,
                        side: data.side, topRatedID: data.topRatedID
                    )
                }
                .transition(.move(edge: .bottom))
                .zIndex(20)
            }
        }
        .animation(.smooth(duration: 0.3), value: playerHost.soccer)
        .animation(.smooth(duration: 0.3), value: playerHost.box)
        // Drives the OPEN: the backdrop fades up in place (never travelling
        // with the card) at the same easeOut(0.14) pace it fades out on close,
        // while the card itself slides up. The drag-close animates dragY
        // off-screen itself and then drops the view, so this never runs on close.
        .onAppear {
            withAnimation(.easeOut(duration: 0.14)) { tintOpacity = 0.78 }
            withAnimation(.smooth(duration: 0.3)) { dragY = 0 }
        }
    }

    /// Sheet-style dismiss: while the content is scrolled to its top, a
    /// downward drag grabs the whole card and it tracks the finger 1:1 the
    /// entire way (nothing re-renders — it's just a transform on the same
    /// live card, which is why the follow is smooth). On release, if pulled
    /// far enough the SAME transform simply animates the rest of the way off
    /// the bottom — then the heavy view is dropped once it's already
    /// off-screen, so no teardown hitch is ever visible. Otherwise it springs
    /// back. The vertical-dominance guard leaves horizontal paging alone.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { v in
                if !dragEngaged.value {
                    // Engage on a clearly downward, vertical drag when either
                    // the scroll is at its top OR the drag started on the grey
                    // grab bar / compact header at the very top of the card —
                    // so the grabber always closes, even when scrolled down.
                    // Leaves mid-content scrolling and horizontal paging alone.
                    guard atTop.value || v.startLocation.y < 110,
                          v.translation.height > 0,
                          v.translation.height > abs(v.translation.width) * 1.3 else { return }
                    dragEngaged.value = true
                    dragBaseline.value = v.translation.height
                }
                dragY = max(0, v.translation.height - dragBaseline.value)
            }
            .onEnded { v in
                let engaged = dragEngaged.value
                dragEngaged.value = false
                guard engaged else { return }
                let travel = v.translation.height - dragBaseline.value
                let predicted = v.predictedEndTranslation.height - dragBaseline.value
                if travel > 120 || predicted > 400 {
                    // Slide the card off the bottom over the still-solid black
                    // backdrop, THEN fade that black out to reveal the hub, and
                    // only then tear the live view down (off-screen, unseen).
                    let target = UIScreen.main.bounds.height + 120
                    withAnimation(.easeOut(duration: 0.34)) { dragY = target }
                    // Start fading the black early (while the card is still
                    // sliding) and quickly, so the hub is already back by the
                    // time the card clears the bottom.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeOut(duration: 0.14)) { tintOpacity = 0 }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { onDismiss() }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragY = 0 }
                }
            }
    }
}

/// Wraps a player-stats card carousel so it presents over the match detail
/// the same way the detail presents over the Sports Hub: the detail page
/// stays visible and undimmed behind the card (a clear backing blocks stray
/// taps and dismisses on a tap in the surrounding gap), and a downward drag
/// from the top strip slides the card off. Used in place of a `.sheet`,
/// whose full-height detent would darken the detail behind it.
private struct PlayerSheetContainer<Content: View>: View {
    /// Removes the carousel instantly (used for a tap in the gap and by the
    /// drag-close after it has slid the card off-screen).
    let onDismiss: () -> Void

    @ViewBuilder var content: Content

    @State private var dragY: CGFloat = 0
    /// Same sheet-style dismiss model as the game card: engage only from the
    /// scroll top, track the finger 1:1, and on release either slide the rest
    /// of the way off (then remove) or spring back.
    @State private var atTop = ValueBox(true)
    @State private var dragEngaged = ValueBox(false)
    @State private var dragBaseline = ValueBox<CGFloat>(0)

    var body: some View {
        ZStack {
            // Full-screen clear backing: shows the detail through, blocks its
            // touches (so a swipe here never reaches the detail's own dismiss
            // gesture), and dismisses on a tap in the surrounding gap.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
                .ignoresSafeArea()
            content
                .ignoresSafeArea(edges: .bottom)
                .environment(\.playerSheetDismiss, onDismiss)
                .environment(\.playerSheetAtTop) { atTop.value = $0 }
                .environment(\.playerSheetDragActive, dragEngaged)
        }
        .offset(y: dragY)
        .simultaneousGesture(dismissGesture)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { v in
                if !dragEngaged.value {
                    guard atTop.value,
                          v.translation.height > 0,
                          v.translation.height > abs(v.translation.width) * 1.3 else { return }
                    dragEngaged.value = true
                    dragBaseline.value = v.translation.height
                }
                dragY = max(0, v.translation.height - dragBaseline.value)
            }
            .onEnded { v in
                let engaged = dragEngaged.value
                dragEngaged.value = false
                guard engaged else { return }
                let travel = v.translation.height - dragBaseline.value
                let predicted = v.predictedEndTranslation.height - dragBaseline.value
                if travel > 120 || predicted > 400 {
                    // Slide the live card the rest of the way off, then remove
                    // it (unanimated, since it's already gone from view).
                    withAnimation(.easeOut(duration: 0.34)) { dragY = UIScreen.main.bounds.height + 120 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { onDismiss() }
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragY = 0 }
                }
            }
    }
}

/// Carousel around the match detail page: each game in the list the user
/// came from (Live Now order for live games, the sport's own scoreboard
/// otherwise) is a full-height card, with the previous/next game's card
/// peeking in from the screen edges — swipe on the header area or the
/// peeking edges to page between games. The list is snapshotted when the
/// detail opens so score refreshes never shuffle pages mid-swipe.
struct GameDetailView: View {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    let accentColor: Color

    private let pages: [GameDetailRequest]
    @State private var currentID: String?

    @MainActor
    init(request: GameDetailRequest, viewModel: ChannelViewModel, scoreViewModel: ScoreViewModel, accentColor: Color) {
        self.viewModel = viewModel
        self.scoreViewModel = scoreViewModel
        self.accentColor = accentColor
        // A window around the tapped game, not the whole scoreboard — a
        // 100+ page lazy carousel makes the initial scroll-to-page landing
        // unreliable, and nobody swipes farther than this anyway.
        let full = scoreViewModel.detailPagingList(from: request)
        if let index = full.firstIndex(where: { $0.id == request.id }) {
            let lo = max(0, index - 12)
            let hi = min(full.count - 1, index + 12)
            self.pages = Array(full[lo...hi])
        } else {
            self.pages = [request]
        }
        _currentID = State(initialValue: request.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 9) {
                    ForEach(pages) { page in
                        Group {
                            if page.sport == .tennis {
                                TennisDetailContentView(request: page, viewModel: viewModel, accentColor: accentColor)
                            } else if page.sport == .mma {
                                MMADetailContentView(request: page, viewModel: viewModel, accentColor: accentColor)
                            } else {
                                GameDetailContentView(request: page, viewModel: viewModel, scoreViewModel: scoreViewModel, accentColor: accentColor, onPageGame: pageGame)
                            }
                        }
                        .background(Color(white: 0.10))
                        .containerRelativeFrame(.horizontal)
                        // Round ONLY the top corners: the card runs flush
                        // off the bottom of the phone, so a long stats/
                        // events list scrolls all the way to the screen
                        // edge instead of being clipped short by a rounded
                        // bottom rectangle floating above it.
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 34, bottomLeadingRadius: 0,
                                bottomTrailingRadius: 0, topTrailingRadius: 34
                            )
                        )
                        .overlay(alignment: .top) { CardGrabber() }
                        .allowsHitTesting(page.id == currentID)
                        .id(page.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            // Slightly narrower main card + tighter inter-card gap: more of
            // the next game peeks in from the edge (peek ≈ inset − spacing).
            .safeAreaPadding(.horizontal, 19)
            .scrollPosition(id: $currentID)
            .onAppear {
                // The scrollPosition binding's initial value alone lands on
                // the wrong page in a lazy carousel — anchor it explicitly.
                proxy.scrollTo(currentID, anchor: .center)
            }
            .onChange(of: currentID) { _, _ in
                ChannelViewModel.shared.triggerSelectionHaptic()
            }
            .padding(.top, 34)
            .preferredColorScheme(.dark)
        }
    }

    /// Steps the carousel one game left/right. Fired by the tab pager when
    /// the user swipes past its first/last chip — the overscroll reads as
    /// "next page", so it pages games the same way the header swipe does.
    private func pageGame(_ delta: Int) {
        guard let current = currentID,
              let index = pages.firstIndex(where: { $0.id == current }),
              pages.indices.contains(index + delta) else { return }
        withAnimation(.easeOut(duration: 0.35)) { currentID = pages[index + delta].id }
    }
}

/// Vertical scroll readings the detail page reacts to each frame: the
/// scrolled distance (drives the compact-bar fade) and the deepest valid
/// offset (so a tab switch that shrinks the content can detect a stranded
/// scroll position).
private struct GDScrollMetrics: Equatable {
    let scrolled: CGFloat
    let maxScrolled: CGFloat
}

/// FotMob-style match detail page, split into tabs:
///   • Overview — live situation, momentum ribbon, headline stats, shot map,
///     match events (with a halftime divider), lineups/top performers, H2H,
///     venue.
///   • Stats — the full team-stat list (and player box scores for US sports).
///   • Table — league/tournament standings with both teams highlighted.
/// Sections render only when the summary payload actually carries their
/// data, so the same screen works across every sport the hub shows.
struct GameDetailContentView: View {
    let request: GameDetailRequest
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    let accentColor: Color
    let onPageGame: (Int) -> Void

    @StateObject private var detail: GameDetailViewModel
    @ObservedObject private var activityManager = GameActivityManager.shared
    @Environment(\.gameDetailDismiss) private var dismiss
    /// Reports scroll-at-top to the presenter, which owns the dismiss drag.
    @Environment(\.gameDetailAtTop) private var reportAtTop
    /// True while the presenter's dismiss drag is engaged — only then do we
    /// cancel the top rubber-band.
    @Environment(\.gameDetailDragActive) private var dragActive
    /// Owned by the presenter — a tapped player publishes its stats carousel
    /// here so it renders full-screen above the whole detail.
    @EnvironmentObject private var playerHost: PlayerSheetHost
    @State private var lineupSide = "home"
    @State private var boxSide = "home"
    @State private var scrolledTab: GDTab? = .overview
    /// 0 at rest, 1 once the big header has scrolled past. Tracks the live
    /// scroll offset directly (no withAnimation) so the compact score bar
    /// crossfades in lockstep with the finger — same pattern as the home
    /// header and the player panel collapse. Held in its own object so
    /// scrolling doesn't re-render this whole page each frame.
    @State private var collapseProgress = ScrollProgress()
    /// How far past their natural position the tab chips are being held
    /// (0 while riding with the content, growing as they dock under the
    /// compact bar). Same leaf-only re-render trick as collapseProgress.
    @State private var chipStick = ScrollProgress()
    /// Live scroll offset, used to pin the header vignette (an in-content
    /// element at zIndex 0.5, below the chips) at the top as content scrolls
    /// under it — so the vignette passes continuously behind the bright chips.
    @State private var headerPin = ScrollProgress()
    /// Measured height of each tab's content, so the pager can be framed to
    /// the visible tab and a short tab can't scroll as deep as its tallest
    /// neighbor.
    @State private var tabHeights: [GDTab: CGFloat] = [:]
    /// Measured height of the compact score bar — the dock line for the
    /// sticky chips.
    @State private var barHeight: CGFloat = 64
    @State private var scrollTarget = ScrollPosition(edge: .top)
    /// Per-gesture latch for the edge-overscroll game paging; a box so the
    /// per-frame writes never invalidate the page.
    @State private var edgeFired = ValueBox(false)
    /// True while the vertical scroll is untouched — rubber-band overshoot
    /// while dragging must not be mistaken for a stranded offset.
    @State private var scrollIdle = ValueBox(true)
    /// Cancels the scroll's own top rubber-band (set to −overscroll) so that
    /// while the whole card is being pulled down, the content inside moves
    /// with the card instead of also bouncing on its own — otherwise the
    /// content drifts twice as far as the card at the top.
    @State private var bounceCancel = ScrollProgress()

    private var tab: GDTab { scrolledTab ?? .overview }

    private enum GDTab: String, CaseIterable {
        case overview = "Overview"
        case stats = "Stats"
        case table = "Table"
    }

    init(request: GameDetailRequest, viewModel: ChannelViewModel, scoreViewModel: ScoreViewModel, accentColor: Color, onPageGame: @escaping (Int) -> Void = { _ in }) {
        self.request = request
        self.viewModel = viewModel
        self.scoreViewModel = scoreViewModel
        self.accentColor = accentColor
        self.onPageGame = onPageGame
        _detail = StateObject(wrappedValue: GameDetailViewModel(request: request))
    }

    private var isSoccer: Bool { request.leagueCode != nil || request.sport.isSoccer }

    private var hasBoxScore: Bool {
        !detail.boxGroups(homeAway: "home").isEmpty || !detail.boxGroups(homeAway: "away").isEmpty
    }

    private var availableTabs: [GDTab] {
        var tabs: [GDTab] = [.overview]
        if !detail.allStats.isEmpty || (!isSoccer && hasBoxScore) { tabs.append(.stats) }
        if !detail.standingsGroups.isEmpty { tabs.append(.table) }
        return tabs
    }

    var body: some View {
        ZStack {
            backgroundLayer

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    // Header vignette (dark + blur) pinned at the top once the
                    // page collapses. It lives in the content at zIndex 0.5 —
                    // above the scrolling rows it dims, but BELOW the tab chips
                    // (zIndex 1), so the vignette passes continuously behind the
                    // chips while they stay bright. Zero layout height (the
                    // negative bottom padding cancels the VStack spacing) so it
                    // never pushes the real content down.
                    Color.clear
                        .frame(height: 0)
                        .overlay(alignment: .top) {
                            GameHeaderScrim(
                                awayColor: detail.awaySide.color,
                                homeColor: detail.homeSide.color
                            )
                                .padding(.horizontal, -9)
                                .offset(y: -55)
                                .scrollProgressReveal(collapseProgress)
                        }
                        .scrollProgressOffset(headerPin)
                        .padding(.bottom, -14)
                        .zIndex(0.5)

                    headerCard

                    watchButton

                    if detail.isLoading && detail.summary == nil {
                        CustomSpinner(color: .white, lineWidth: 4, size: 36)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if detail.failed && detail.summary == nil {
                        EmptyStateView(
                            title: "No Match Data",
                            systemImage: "chart.bar.xaxis",
                            description: "Detailed stats aren't available for this game."
                        )
                        .padding(.top, 40)
                    } else {
                        if availableTabs.count > 1 {
                            // One set of chips, no pinned copy: they scroll
                            // with the content and the offset below holds
                            // them docked under the compact bar once they
                            // reach it — the hub's pin/unpin feel. The outer
                            // container is never offset, so the probe reads
                            // their natural position.
                            // No backing scrim on the chips themselves — the
                            // compact bar's PinnedHeaderGradient reaches down
                            // past the dock line and dims content passing
                            // under them, same as the hub's pinned pills.
                            ZStack(alignment: .top) {
                                tabChips
                                    .padding(.vertical, 6)
                                    .scrollProgressOffset(chipStick)
                            }
                            .background(GlobalOffsetProbe(id: "gdChips"))
                            .zIndex(1)
                        }
                        tabPager
                            .padding(.horizontal, -9)
                            .frame(height: tabHeights[tab], alignment: .top)
                            .clipped()
                            .animation(.easeOut(duration: 0.25), value: tab)
                    }
                }
                // Tighter side padding so the section cards sit closer to
                // the card's edges.
                .padding(.horizontal, 9)
                // Clears the grabber handle sitting at the card's top edge.
                .padding(.top, 24)
                // Clears the home-indicator strip so the last stats row
                // isn't tucked under it at the bottom of the scroll.
                .padding(.bottom, 80)
                // Undo the top rubber-band so the content rides down with the
                // card, not ahead of it, during a pull-to-close.
                .scrollProgressOffset(bounceCancel)
            }
            .scrollPosition($scrollTarget)
            // Scroll-linked, not threshold + animation: the bar's opacity
            // maps directly onto the offset (fading in over 105→155pt, where
            // the big score header scrolls out) so it moves with the finger
            // and reverses the same way — no spring, no bounce.
            .onScrollGeometryChange(for: GDScrollMetrics.self) { geometry in
                GDScrollMetrics(
                    scrolled: geometry.contentOffset.y + geometry.contentInsets.top,
                    maxScrolled: max(0, geometry.contentSize.height + geometry.contentInsets.top
                        + geometry.contentInsets.bottom - geometry.containerSize.height)
                )
            } action: { _, metrics in
                collapseProgress.set(min(max((metrics.scrolled - 105) / 50, 0), 1))
                // Pin the header vignette against the scroll (offset by the
                // live scroll distance so it holds at the top).
                headerPin.set(metrics.scrolled)
                // Report at-top to the presenter's dismiss drag. Cancel the
                // scroll's own top rubber-band ONLY while the card is being
                // dragged to dismiss (so the content doesn't over-bounce past
                // the card); otherwise leave the normal elastic top bounce.
                let overscroll = max(0, -metrics.scrolled)
                bounceCancel.set((dragActive?.value ?? false) ? -overscroll : 0)
                reportAtTop(metrics.scrolled <= 1)
                // Content got shorter than the current offset (switched to a
                // tab with less content): bring the new tab's bottom to the
                // bottom of the screen instead of leaving empty space. Only
                // while idle — rubber-band overshoot mid-drag settles itself.
                if scrollIdle.value && metrics.scrolled > metrics.maxScrolled + 1 {
                    withAnimation(.easeOut(duration: 0.3)) { scrollTarget.scrollTo(edge: .bottom) }
                }
            }
            .onScrollPhaseChange { _, newPhase in
                scrollIdle.value = newPhase == .idle
            }
            .background(GlobalOffsetProbe(id: "gdContainer"))
            // Overlay, not safeAreaInset: the bar takes no layout space, so
            // nothing jumps when it appears — content just slides under it.
            .overlay(alignment: .top) {
                compactHeader
                    .scrollProgressReveal(collapseProgress)
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .onAppear { barHeight = g.size.height }
                                .onChangeCompat(of: g.size.height) { barHeight = $0 }
                        }
                    )
            }
        }
        .onPreferenceChange(SectionScrollOffsetsKey.self) { offsets in
            // A player carousel over the page can shift the probes' reported
            // frames; freeze the chip dock while one is up.
            guard !playerHost.isPresenting else { return }
            guard let containerTop = offsets["gdContainer"], let chipsTop = offsets["gdChips"] else { return }
            chipStick.set(max(0, containerTop + barHeight - chipsTop))
        }
        .preferredColorScheme(.dark)
        .task(id: request.id) {
            await detail.refreshLoop()
        }
    }

    /// Builds the soccer player's stats carousel data from this card's lineup
    /// and publishes it to the presenter, which shows it over the whole
    /// detail (full screen width, undimmed detail behind).
    private func presentLineupPlayer(_ player: GDLineupPlayer) {
        let lineup = detail.lineup(homeAway: lineupSide)
        let roster = (lineup?.starters ?? []) + (lineup?.substitutes ?? [])
        playerHost.soccer = SoccerPlayerSheetData(
            key: player.id,
            players: roster.isEmpty ? [player] : roster,
            initialID: player.id,
            side: lineupSide == "home" ? detail.homeSide : detail.awaySide,
            topRatedID: detail.topRatedPlayerID,
            heatPoints: { detail.playerHeatPoints(athleteID: $0) }
        )
    }

    /// Box-score (US sports) counterpart of `presentLineupPlayer`.
    private func presentBoxPlayer(_ row: GDBoxRow) {
        let players = boxSheetPlayers()
        playerHost.box = BoxPlayerSheetData(
            key: row.athleteID,
            players: players.isEmpty
                ? [BoxSheetPlayer(id: row.athleteID, name: row.name, headshot: row.headshot, rating: row.rating, sections: [])]
                : players,
            initialID: row.athleteID,
            side: boxSide == "home" ? detail.homeSide : detail.awaySide,
            topRatedID: detail.topRatedPlayerID
        )
    }

    /// One entry per athlete on the current box-score side, their rows from
    /// every stat group merged into sections (a two-way player shows both).
    private func boxSheetPlayers() -> [BoxSheetPlayer] {
        let groups = detail.boxGroups(homeAway: boxSide)
        var order: [String] = []
        var byID: [String: BoxSheetPlayer] = [:]
        for group in groups {
            for row in group.rows where !row.athleteID.isEmpty {
                let lines = zip(group.columns, row.values).map { column, value in
                    GDPlayerStatLine(key: "\(group.title)-\(column)", label: column, value: value)
                }
                let section = BoxSheetSection(title: group.title, lines: lines)
                if var existing = byID[row.athleteID] {
                    existing.sections.append(section)
                    if existing.rating == nil { existing.rating = row.rating }
                    byID[row.athleteID] = existing
                } else {
                    order.append(row.athleteID)
                    byID[row.athleteID] = BoxSheetPlayer(
                        id: row.athleteID, name: row.name, headshot: row.headshot,
                        rating: row.rating, sections: [section]
                    )
                }
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// Apple Sports-style pinned bar once the big header scrolls away: each
    /// team's score sits beside its logo, the status in the middle (with
    /// the mini base diamond while baseball is live). The tab chips aren't
    /// part of the bar — they're sticky content that docks just beneath it.
    private var compactHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                CachedAsyncImage(urlString: detail.awaySide.logo ?? "", size: CGSize(width: 34, height: 34))
                    .frame(width: 34, height: 34)
                if detail.statusState != "pre" {
                    Text(detail.awaySide.score)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                }
                Spacer()
                VStack(spacing: 1) {
                    HStack(spacing: 6) {
                        Text(detail.statusState == "pre" ? startTimeText : detail.statusDetail)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(detail.statusState == "in" ? .red : .primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if detail.statusState == "in", let situation = detail.baseballSituation {
                            BasesDiamondView(
                                onFirst: situation.onFirst,
                                onSecond: situation.onSecond,
                                onThird: situation.onThird,
                                fillColor: compactBattingColor(situation)
                            )
                            .scaleEffect(0.45)
                            .frame(width: 30, height: 26)
                        }
                    }
                    if let subline = compactStatusSubline {
                        Text(subline)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if detail.statusState != "pre" {
                    Text(detail.homeSide.score)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                }
                CachedAsyncImage(urlString: detail.homeSide.logo ?? "", size: CGSize(width: 34, height: 34))
                    .frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 9)
        // Sits just below the grabber handle at the card's top edge.
        .padding(.top, 18)
        .padding(.bottom, 10)
        // No scrim here — the vignette is a separate in-content layer pinned
        // behind the bar AND the chips (so the chips stay bright over it).
    }

    private func compactBattingColor(_ situation: GDBaseballSituation) -> Color {
        switch situation.battingTeamIsHome {
        case true: return detail.homeSide.color
        case false: return detail.awaySide.color
        default: return .white
        }
    }

    /// "Today" / "Yesterday" / "Jul 12" under the compact status — matches
    /// Apple Sports' "Final / Today" stack. Hidden while live (the status
    /// line itself carries the inning/clock).
    private var compactStatusSubline: String? {
        guard detail.statusState != "in" else { return nil }
        let date = request.game.gameDate
        guard date != .distantFuture else { return nil }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: date)
    }

    /// Single path for every tab change: picks the slide direction from the
    /// chip order, fires the haptic, and animates the content push.
    private func switchTab(to newTab: GDTab) {
        guard scrolledTab != newTab else { return }
        ChannelViewModel.shared.triggerSelectionHaptic()
        withAnimation(.easeOut(duration: 0.3)) { scrolledTab = newTab }
    }

    // MARK: Tabs

    private var tabChips: some View {
        HStack(spacing: 8) {
            ForEach(availableTabs, id: \.self) { candidate in
                Button {
                    switchTab(to: candidate)
                } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 13, weight: .bold))
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(tab == candidate ? Color.white : Color.white.opacity(0.08))
                        .foregroundColor(tab == candidate ? .black : .white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
        // The tab change animates the content slide; without this the chip
        // colors crossfade too, and mid-fade the selected chip reads as
        // black-on-black. Killing the animation here makes the white
        // selection snap instantly.
        .transaction { $0.animation = nil }
    }

    private var tabPager: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(availableTabs, id: \.self) { candidate in
                    VStack(spacing: 14) {
                        tabContent(for: candidate)
                    }
                    .background(
                        GeometryReader { g in
                            Color.clear
                                // +40 cushion: async sections (lineups,
                                // events, momentum) can grow the real
                                // content a beat after this first fires, and
                                // the tabPager below is hard-.clipped() to
                                // this height — a measurement that lands even
                                // slightly short permanently chops the tab's
                                // own bottom. A hair too tall just leaves a
                                // few points of blank space, which is fine.
                                .onAppear { tabHeights[candidate] = g.size.height + 40 }
                                .onChangeCompat(of: g.size.height) { tabHeights[candidate] = $0 + 40 }
                        }
                    )
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        // Tab content sits closer to the card edge (matches the reduced
        // outer content padding).
        .safeAreaPadding(.horizontal, 9)
        .scrollPosition(id: $scrolledTab)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            let restX = -geometry.contentInsets.leading
            let maxX = max(restX, geometry.contentSize.width - geometry.containerSize.width
                + geometry.contentInsets.trailing)
            if geometry.contentOffset.x < restX { return geometry.contentOffset.x - restX }
            if geometry.contentOffset.x > maxX { return geometry.contentOffset.x - maxX }
            return 0
        } action: { _, overshoot in
            if abs(overshoot) < 4 {
                edgeFired.value = false
            } else if !edgeFired.value {
                if overshoot <= -30 {
                    edgeFired.value = true
                    onPageGame(-1)
                } else if overshoot >= 30 {
                    edgeFired.value = true
                    onPageGame(1)
                }
            }
        }
    }

    @ViewBuilder
    private func tabContent(for candidate: GDTab) -> some View {
        switch candidate {
        case .overview: overviewTab
        case .stats: statsTab
        case .table: tableTab
        }
    }

    @ViewBuilder
    private var overviewTab: some View {
        if let situation = detail.baseballSituation {
            baseballSituationSection(situation)
        }
        if let situation = detail.footballSituation {
            footballSituationSection(situation)
        }
        if let momentum = detail.momentum {
            winProbabilitySection(momentum)
        } else if let momentum = detail.derivedMomentum {
            momentumSection(momentum, caption: "MOMENTUM")
        }
        if detail.possessionBar != nil || !detail.mainStats.isEmpty {
            mainStatsSection
        }
        if isSoccer && !detail.shots.isEmpty {
            shotMapSection
        }
        if !detail.timeline.isEmpty {
            timelineSection
        }
        if isSoccer {
            if detail.lineup(homeAway: "home") != nil || detail.lineup(homeAway: "away") != nil {
                soccerLineupSection
            }
        }
        if !detail.topPerformers.isEmpty {
            performersSection
        }
        h2hSection
        venueSection
    }

    @ViewBuilder
    private var statsTab: some View {
        if !detail.allStats.isEmpty {
            sectionCard("Team Stats") {
                VStack(spacing: 14) {
                    if let possession = detail.possessionBar {
                        possessionView(possession)
                    }
                    ForEach(detail.allStats) { bar in
                        statBarRow(bar)
                    }
                }
            }
        }
        if !isSoccer && hasBoxScore {
            boxScoreSection
        }
    }

    @ViewBuilder
    private var tableTab: some View {
        ForEach(detail.standingsGroups) { group in
            standingsCard(group)
        }
    }

    // MARK: Background

    private var backgroundLayer: some View {
        ZStack {
            // Same card base as the player-stats pages.
            Color(white: 0.10).ignoresSafeArea()
            // Strong team-color wash, Apple Sports-style: away team floods
            // in from the top-left, home from the top-right, both fading
            // into the dark base toward the bottom.
            LinearGradient(
                colors: [detail.awaySide.color.opacity(0.65), .clear],
                startPoint: .topLeading,
                endPoint: UnitPoint(x: 0.65, y: 0.75)
            )
            LinearGradient(
                colors: [detail.homeSide.color.opacity(0.55), .clear],
                startPoint: .topTrailing,
                endPoint: UnitPoint(x: 0.35, y: 0.75)
            )
        }
        .ignoresSafeArea()
    }

    // MARK: Header

    private var headerCard: some View {
        VStack(spacing: 10) {
            if let league = detail.leagueName {
                Text(league.uppercased())
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                teamHeaderColumn(detail.awaySide)
                VStack(spacing: 6) {
                    if detail.statusState == "pre" {
                        Text(startTimeText)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                    } else {
                        // One Text so a big basketball score scales down as
                        // a unit instead of wrapping "29" onto two lines.
                        Text("\(detail.awaySide.score) \(Text("–").foregroundStyle(.secondary)) \(detail.homeSide.score)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    Text(detail.statusDetail)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(detail.statusState == "in" ? .red : .secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(minWidth: 100)
                .layoutPriority(1)
                teamHeaderColumn(detail.homeSide)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private var startTimeText: String {
        let date = request.game.gameDate
        guard date != .distantFuture else { return "—" }
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df.string(from: date)
    }

    private func teamHeaderColumn(_ side: GDTeamSide) -> some View {
        VStack(spacing: 6) {
            CachedAsyncImage(urlString: side.logo ?? "", size: CGSize(width: 52, height: 52))
                .frame(width: 52, height: 52)
            Text(side.name)
                .font(.system(size: 14, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            if let record = side.record {
                Text(record)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Watch

    private var watchButton: some View {
        HStack(spacing: 10) {
            Button {
                ChannelViewModel.shared.triggerHaptic(.medium)
                let home = detail.homeSide.name
                let away = detail.awaySide.name
                dismiss()
                viewModel.runSmartSearch(
                    gameID: request.game.id,
                    home: home,
                    away: away,
                    sport: request.sport,
                    network: request.game.broadcastName
                )
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(detail.statusState == "in" ? "Watch Live" : "Find Stream")
                    if let network = request.game.broadcastName {
                        Text(network)
                            .font(.system(size: 11, weight: .black))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .modifier(WatchButtonGlass())
            }
            .buttonStyle(.plain)

            if detail.statusState == "pre" {
                // Reminder toggle — mirrors the app's chip language: glass
                // at rest, solid white with black glyph once armed.
                let isReminderSet = scoreViewModel.reminderGameIDs.contains(request.game.id)
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        scoreViewModel.toggleReminder(request.game)
                    }
                } label: {
                    detailPillIcon(
                        systemName: isReminderSet ? "bell.fill" : "bell",
                        active: isReminderSet,
                        fill: .white,
                        activeGlyph: .black
                    )
                }
                .buttonStyle(.plain)
            } else if detail.statusState == "in" {
                LiveActivityPillButton(
                    game: request.game,
                    leagueName: request.game.leagueLabel ?? request.sport.rawValue,
                    sport: request.leagueCode != nil ? .soccerLeagues : request.sport
                )
            }
        }
    }

    /// Circular-pill icon button beside the watch button. At rest it's the
    /// same glass as the watch pill; active, it fills solid with the state
    /// color so the toggle reads at a glance — the same idle/selected
    /// treatment the app's chips use.
    private func detailPillIcon(systemName: String, active: Bool, fill: Color, activeGlyph: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(active ? activeGlyph : .white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 52, height: 22)
            .padding(.vertical, 13)
            .background {
                if active {
                    Capsule().fill(fill)
                }
            }
            .modifier(ConditionalWatchGlass(showGlass: !active))
            .overlay {
                if active {
                    Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                }
            }
            .shadow(color: active ? fill.opacity(0.45) : .clear, radius: 10, y: 2)
    }

    // MARK: Live situation

    /// Live baseball panel: the base diamond, ball–strike count, outs, and
    /// who's at the plate. Between innings it shows the due-up hitters.
    private func baseballSituationSection(_ situation: GDBaseballSituation) -> some View {
        let battingColor: Color = {
            switch situation.battingTeamIsHome {
            case true: return detail.homeSide.color
            case false: return detail.awaySide.color
            default: return .white
            }
        }()
        return sectionCard("Live Situation") {
            VStack(spacing: 12) {
                HStack(alignment: .center) {
                    BasesDiamondView(
                        onFirst: situation.onFirst,
                        onSecond: situation.onSecond,
                        onThird: situation.onThird,
                        fillColor: battingColor
                    )
                    Spacer()
                    VStack(spacing: 4) {
                        Text("\(situation.balls)-\(situation.strikes)")
                            .font(.system(size: 26, weight: .black, design: .rounded))
                        Text("COUNT")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(spacing: 8) {
                        HStack(spacing: 5) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle()
                                    .fill(i < situation.outs ? Color.white : Color.white.opacity(0.15))
                                    .frame(width: 11, height: 11)
                            }
                        }
                        Text("OUTS")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)

                if situation.batter != nil || situation.pitcher != nil {
                    HStack(spacing: 10) {
                        if let batter = situation.batter {
                            situationPlayerChip(role: "AB", name: batter, color: battingColor)
                        }
                        if let pitcher = situation.pitcher {
                            let fieldingColor: Color = situation.battingTeamIsHome == true
                                ? detail.awaySide.color : detail.homeSide.color
                            situationPlayerChip(role: "P", name: pitcher, color: fieldingColor)
                        }
                    }
                } else if !situation.dueUp.isEmpty {
                    HStack(spacing: 6) {
                        Text("DUE UP")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.secondary)
                        Text(situation.dueUp.prefix(3).joined(separator: ", "))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func situationPlayerChip(role: String, name: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Text(role)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 24, height: 18)
                .background(color.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    /// Live football panel: possession team, down & distance, red-zone flag,
    /// and the last play.
    private func footballSituationSection(_ situation: GDFootballSituation) -> some View {
        sectionCard("Live Situation") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if let possessionIsHome = situation.possessionIsHome {
                        let side = possessionIsHome ? detail.homeSide : detail.awaySide
                        CachedAsyncImage(urlString: side.logo ?? "", size: CGSize(width: 24, height: 24))
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "football.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    Text(situation.downDistanceText)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    if situation.isRedZone {
                        Text("RED ZONE")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.red.opacity(0.85))
                            .clipShape(Capsule())
                    }
                }
                if let lastPlay = situation.lastPlayText, !lastPlay.isEmpty {
                    Text(lastPlay)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: Momentum / win probability

    /// ESPN's real per-play win probability: the curve spans the whole game
    /// on the x-axis but only fills up to where the game currently is, with
    /// live percentages in the legend and press-and-hold scrubbing.
    private func winProbabilitySection(_ points: [Double]) -> some View {
        let last = points.last ?? 0.5
        return sectionCard("Win Probability") {
            VStack(spacing: 8) {
                MomentumChart(
                    points: points,
                    homeColor: detail.homeSide.color,
                    awayColor: detail.awaySide.color,
                    progress: detail.gameProgress,
                    homeAbbrev: detail.homeSide.abbreviation,
                    awayAbbrev: detail.awaySide.abbreviation,
                    interactive: true
                )
                .frame(height: 110)
                HStack {
                    momentumLegend(detail.awaySide, percent: 100 - Int((last * 100).rounded()))
                    Spacer()
                    Text(detail.statusState == "in" ? "LIVE · HOLD TO SCRUB" : "HOLD TO SCRUB")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    momentumLegend(detail.homeSide, percent: Int((last * 100).rounded()))
                }
            }
        }
    }

    /// Fallback pressure curve for sports with no probability feed — not a
    /// probability, so no percentages or scrubbing.
    private func momentumSection(_ points: [Double], caption: String) -> some View {
        sectionCard("Momentum") {
            VStack(spacing: 8) {
                MomentumChart(
                    points: points,
                    homeColor: detail.homeSide.color,
                    awayColor: detail.awaySide.color,
                    progress: detail.gameProgress
                )
                .frame(height: 110)
                HStack {
                    momentumLegend(detail.awaySide)
                    Spacer()
                    Text(caption)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.secondary)
                    Spacer()
                    momentumLegend(detail.homeSide)
                }
            }
        }
    }

    private func momentumLegend(_ side: GDTeamSide, percent: Int? = nil) -> some View {
        HStack(spacing: 5) {
            Circle().fill(side.color).frame(width: 9, height: 9)
            Text(side.abbreviation)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
            if let percent {
                Text("\(percent)%")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
        }
    }

    // MARK: Main stats (overview)

    private var mainStatsSection: some View {
        sectionCard("Top Stats") {
            VStack(spacing: 14) {
                if let possession = detail.possessionBar {
                    possessionView(possession)
                }
                ForEach(detail.mainStats) { bar in
                    statBarRow(bar)
                }
            }
        }
    }

    /// FotMob-style full-width possession bar with the percentages inside.
    private func possessionView(_ bar: GDStatBar) -> some View {
        VStack(spacing: 6) {
            Text("Ball Possession")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            GeometryReader { geo in
                HStack(spacing: 2) {
                    HStack {
                        Text(possessionLabel(bar.awayText))
                            .padding(.leading, 12)
                        Spacer()
                    }
                    .frame(width: max(44, geo.size.width * (1 - bar.homeFraction)))
                    .frame(maxHeight: .infinity)
                    .background(detail.awaySide.color)
                    HStack {
                        Spacer()
                        Text(possessionLabel(bar.homeText))
                            .padding(.trailing, 12)
                    }
                    .frame(maxHeight: .infinity)
                    .background(detail.homeSide.color)
                }
                .font(.system(size: 14, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .frame(height: 34)
        }
    }

    private func possessionLabel(_ raw: String) -> String {
        let value = raw.replacingOccurrences(of: "%", with: "")
        if let number = Double(value) {
            return "\(Int(number.rounded()))%"
        }
        return raw
    }

    private func statBarRow(_ bar: GDStatBar) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(bar.awayText)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                Text(bar.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(bar.homeText)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule()
                        .fill(detail.awaySide.color)
                        .frame(width: max(3, geo.size.width * (1 - bar.homeFraction)))
                    Capsule()
                        .fill(detail.homeSide.color)
                        .frame(width: max(3, geo.size.width * bar.homeFraction))
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: Shot map

    private var shotMapSection: some View {
        sectionCard("Shot Map") {
            VStack(spacing: 8) {
                ShotMapView(
                    shots: detail.shots,
                    homeColor: detail.homeSide.color,
                    awayColor: detail.awaySide.color
                )
                .frame(height: 190)
                HStack {
                    momentumLegend(detail.awaySide)
                    Spacer()
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Circle().fill(.white).frame(width: 8, height: 8)
                            Text("Goal").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            Circle().stroke(.white.opacity(0.7), lineWidth: 1.5).frame(width: 8, height: 8)
                            Text("Shot").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    momentumLegend(detail.homeSide)
                }
            }
        }
    }

    // MARK: Timeline

    private var timelineSection: some View {
        sectionCard("Match Events") {
            let entries = detail.timeline
            let firstHalf = entries.filter { $0.period <= 1 }
            let secondHalf = entries.filter { $0.period >= 2 }
            VStack(spacing: 0) {
                ForEach(firstHalf) { entry in
                    timelineRow(entry)
                }
                if !firstHalf.isEmpty && !secondHalf.isEmpty {
                    halftimeDivider
                }
                ForEach(secondHalf) { entry in
                    timelineRow(entry)
                }
            }
        }
    }

    private var halftimeDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
            Text("HALFTIME")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
        }
        .padding(.vertical, 10)
    }

    private func timelineRow(_ entry: GDTimelineEntry) -> some View {
        HStack(spacing: 10) {
            if entry.isHome { Spacer(minLength: 40) }
            if !entry.isHome { timelineBody(entry, alignRight: false) }
            Text(entry.minute)
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 40)
            if entry.isHome { timelineBody(entry, alignRight: true) }
            if !entry.isHome { Spacer(minLength: 40) }
        }
        .padding(.vertical, 7)
    }

    private func timelineBody(_ entry: GDTimelineEntry, alignRight: Bool) -> some View {
        HStack(spacing: 8) {
            if alignRight { timelineText(entry, alignment: .trailing) }
            timelineIcon(entry.kind)
            if !alignRight { timelineText(entry, alignment: .leading) }
        }
        .frame(maxWidth: .infinity, alignment: alignRight ? .trailing : .leading)
    }

    private func timelineText(_ entry: GDTimelineEntry, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(entry.playerText)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if let detailText = entry.detailText {
                Text(detailText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func timelineIcon(_ kind: GDEventKind) -> some View {
        switch kind {
        case .goal, .penaltyGoal:
            Image(systemName: "soccerball.inverse")
                .font(.system(size: 15))
                .foregroundStyle(.white)
        case .ownGoal:
            Image(systemName: "soccerball.inverse")
                .font(.system(size: 15))
                .foregroundStyle(.red)
        case .penaltyMiss:
            Image(systemName: "xmark.circle")
                .font(.system(size: 15))
                .foregroundStyle(.red)
        case .yellow:
            RoundedRectangle(cornerRadius: 2).fill(.yellow).frame(width: 11, height: 15)
        case .red:
            RoundedRectangle(cornerRadius: 2).fill(.red).frame(width: 11, height: 15)
        case .substitution:
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.green)
        }
    }

    // MARK: Lineups (soccer)

    private var soccerLineupSection: some View {
        sectionCard("Lineups") {
            VStack(spacing: 12) {
                sidePicker(selection: $lineupSide)
                if let lineup = detail.lineup(homeAway: lineupSide) {
                    let side = lineupSide == "home" ? detail.homeSide : detail.awaySide
                    if let formation = lineup.formation {
                        Text(formation)
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    if !lineup.rows.isEmpty {
                        FormationPitchView(
                            rows: lineup.rows,
                            teamColor: side.color,
                            showPhotos: true,
                            topRatedID: detail.topRatedPlayerID,
                            onSwipe: handleLineupSwipe
                        ) { tapped in
                            viewModel.triggerSelectionHaptic()
                            presentLineupPlayer(tapped)
                        }
                    } else {
                        VStack(spacing: 6) {
                            ForEach(lineup.starters) { player in
                                lineupListRow(player)
                            }
                        }
                    }
                    if !lineup.substitutes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SUBSTITUTES")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                            ForEach(lineup.substitutes) { player in
                                lineupListRow(player)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("Lineup not available yet")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    /// Direction-aware swipe over the formation pitch. Priority per
    /// direction: the other team's lineup, then the neighboring tab, then
    /// the neighboring game.
    private func handleLineupSwipe(_ h: CGFloat) {
        if h < 0 && lineupSide == "away" {
            ChannelViewModel.shared.triggerSelectionHaptic()
            withAnimation(.easeOut(duration: 0.15)) { lineupSide = "home" }
        } else if h > 0 && lineupSide == "home" {
            ChannelViewModel.shared.triggerSelectionHaptic()
            withAnimation(.easeOut(duration: 0.15)) { lineupSide = "away" }
        } else {
            let delta = h < 0 ? 1 : -1
            if let index = availableTabs.firstIndex(of: tab), availableTabs.indices.contains(index + delta) {
                switchTab(to: availableTabs[index + delta])
            } else {
                onPageGame(delta)
            }
        }
    }

    private func lineupListRow(_ player: GDLineupPlayer) -> some View {
        Button {
            viewModel.triggerSelectionHaptic()
            presentLineupPlayer(player)
        } label: {
            lineupListRowContent(player)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func lineupListRowContent(_ player: GDLineupPlayer) -> some View {
        HStack(spacing: 10) {
            Text(player.age.map { "\($0)" } ?? "—")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            CachedAsyncImage(
                urlString: player.headshot ?? "",
                size: CGSize(width: 26, height: 26),
                failurePlaceholder: AnyView(
                    Image(systemName: "person.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                )
            )
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.white.opacity(0.08)))
            .clipShape(Circle())
            Text(player.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if player.goals > 0 {
                Image(systemName: "soccerball.inverse").font(.system(size: 12))
            }
            if player.red {
                RoundedRectangle(cornerRadius: 1.5).fill(.red).frame(width: 9, height: 12)
            } else if player.yellow {
                RoundedRectangle(cornerRadius: 1.5).fill(.yellow).frame(width: 9, height: 12)
            }
            if let onClock = player.subbedOnClock, !onClock.isEmpty {
                Text("▲ \(onClock)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
            }
            Spacer()
            RatingBadge(rating: player.rating, isTop: player.id == detail.topRatedPlayerID)
        }
    }

    // MARK: Box score (US sports, Stats tab)

    private var boxScoreSection: some View {
        sectionCard("Box Score") {
            VStack(spacing: 12) {
                sidePicker(selection: $boxSide)
                let groups = detail.boxGroups(homeAway: boxSide)
                if groups.isEmpty {
                    Text("Player stats not available yet")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(groups) { group in
                        boxGroupTable(group)
                    }
                }
            }
        }
    }

    private func boxGroupTable(_ group: GDBoxGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.title.uppercased())
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 0) {
                // Frozen name + rating column.
                VStack(alignment: .leading, spacing: 0) {
                    Text("PLAYER")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.secondary)
                        .frame(height: 22)
                    ForEach(group.rows) { row in
                        HStack(spacing: 5) {
                            CachedAsyncImage(urlString: row.headshot ?? "", size: CGSize(width: 22, height: 22))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.white.opacity(0.08)))
                                .clipShape(Circle())
                            RatingBadge(rating: row.rating, compact: true, isTop: row.athleteID == detail.topRatedPlayerID)
                            Text(row.name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(height: 27)
                    }
                }
                .frame(width: 150, alignment: .leading)
                .overlay(HorizontalPanOverlay(onSwipe: { translation in
                    if translation < 0 && boxSide == "away" {
                        ChannelViewModel.shared.triggerSelectionHaptic()
                        withAnimation(.easeOut(duration: 0.15)) { boxSide = "home" }
                    } else if translation > 0 && boxSide == "home" {
                        ChannelViewModel.shared.triggerSelectionHaptic()
                        withAnimation(.easeOut(duration: 0.15)) { boxSide = "away" }
                    } else {
                        onPageGame(translation < 0 ? 1 : -1)
                    }
                }, onTap: { location in
                    // Fixed row metrics (22pt header, 27pt rows) → row index.
                    let index = Int((location.y - 22) / 27)
                    guard index >= 0, group.rows.indices.contains(index) else { return }
                    viewModel.triggerSelectionHaptic()
                    presentBoxPlayer(group.rows[index])
                }))

                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(group.columns.indices, id: \.self) { i in
                                Text(group.columns[i])
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, height: 22)
                            }
                        }
                        ForEach(group.rows) { row in
                            HStack(spacing: 0) {
                                ForEach(row.values.indices, id: \.self) { i in
                                    Text(row.values[i])
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.8))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .frame(width: 48, height: 27)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func sidePicker(selection: Binding<String>) -> some View {
        HStack(spacing: 8) {
            sideChip(side: detail.awaySide, value: "away", selection: selection)
            sideChip(side: detail.homeSide, value: "home", selection: selection)
        }
    }

    private func sideSwipeGesture(_ selection: Binding<String>, pageThrough: ((Int) -> Void)? = nil) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                let h = value.translation.width
                // Same deliberate-swipe bar as the box score's pan overlay.
                guard abs(h) >= 55, abs(h) > abs(value.translation.height) * 1.5 else { return }
                if h < 0 && selection.wrappedValue == "away" {
                    ChannelViewModel.shared.triggerSelectionHaptic()
                    withAnimation(.easeOut(duration: 0.15)) { selection.wrappedValue = "home" }
                } else if h > 0 && selection.wrappedValue == "home" {
                    ChannelViewModel.shared.triggerSelectionHaptic()
                    withAnimation(.easeOut(duration: 0.15)) { selection.wrappedValue = "away" }
                } else if let pageThrough {
                    pageThrough(h < 0 ? 1 : -1)
                }
            }
    }

    private func sideChip(side: GDTeamSide, value: String, selection: Binding<String>) -> some View {
        Button {
            ChannelViewModel.shared.triggerSelectionHaptic()
            withAnimation(.easeOut(duration: 0.15)) { selection.wrappedValue = value }
        } label: {
            HStack(spacing: 6) {
                CachedAsyncImage(urlString: side.logo ?? "", size: CGSize(width: 18, height: 18))
                    .frame(width: 18, height: 18)
                Text(side.name)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(selection.wrappedValue == value ? Color.white.opacity(0.18) : Color.white.opacity(0.05))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(selection.wrappedValue == value ? 0.3 : 0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    // MARK: Standings (Table tab)

    private func standingsCard(_ group: GDStandingsGroup) -> some View {
        sectionCard(group.header) {
            VStack(spacing: 0) {
                // Column header row.
                HStack(spacing: 8) {
                    Text("#")
                        .frame(width: 20, alignment: .center)
                    Text("TEAM")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(group.columns.indices, id: \.self) { i in
                        Text(group.columns[i])
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)

                ForEach(group.rows) { row in
                    standingsRow(row)
                }
            }
        }
    }

    private func standingsRow(_ row: GDStandingRow) -> some View {
        let highlightColor = row.isHome ? detail.homeSide.color : detail.awaySide.color
        return HStack(spacing: 8) {
            Text("\(row.rank)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            HStack(spacing: 7) {
                CachedAsyncImage(urlString: row.logo ?? "", size: CGSize(width: 20, height: 20))
                    .frame(width: 20, height: 20)
                Text(row.name)
                    .font(.system(size: 13, weight: row.isPlaying ? .bold : .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(row.values.indices, id: \.self) { i in
                Text(row.values[i])
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .background(
            row.isPlaying
                ? RoundedRectangle(cornerRadius: 8).fill(highlightColor.opacity(0.22))
                : nil
        )
        .overlay(alignment: .leading) {
            if row.isPlaying {
                Capsule().fill(highlightColor).frame(width: 3, height: 22)
            }
        }
    }

    // MARK: Top performers

    private var performersSection: some View {
        sectionCard("Top Performers") {
            VStack(spacing: 10) {
                ForEach(detail.topPerformers) { leader in
                    HStack(spacing: 10) {
                        if let headshot = leader.headshot {
                            CachedAsyncImage(urlString: headshot, size: CGSize(width: 36, height: 36))
                                .frame(width: 36, height: 36)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Circle())
                        } else {
                            Circle()
                                .fill((leader.isHome ? detail.homeSide.color : detail.awaySide.color).opacity(0.4))
                                .frame(width: 36, height: 36)
                                .overlay(Image(systemName: "person.fill").font(.system(size: 15)).foregroundStyle(.white.opacity(0.7)))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(leader.name)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            Text(leader.category)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(leader.statLine)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        }
    }

    // MARK: H2H

    @ViewBuilder
    private var h2hSection: some View {
        let homeForm = detail.form(homeAway: "home")
        let awayForm = detail.form(homeAway: "away")
        let meetings = detail.meetings
        if !homeForm.isEmpty || !awayForm.isEmpty || !meetings.isEmpty || detail.seasonSeriesText != nil {
            sectionCard("Head to Head") {
                VStack(spacing: 12) {
                    if let series = detail.seasonSeriesText {
                        Text(series)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                    }
                    if !homeForm.isEmpty || !awayForm.isEmpty {
                        HStack {
                            formColumn(side: detail.awaySide, results: awayForm)
                            Spacer()
                            Text("FORM")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(.secondary)
                            Spacer()
                            formColumn(side: detail.homeSide, results: homeForm)
                        }
                    }
                    if !meetings.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(meetings) { meeting in
                                HStack {
                                    Text(meeting.dateText)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 64, alignment: .leading)
                                    Text(meeting.leagueText)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(meeting.awayAbbrev) \(meeting.awayTeamDisplayScore) – \(meeting.homeTeamDisplayScore) \(meeting.homeAbbrev)")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func formColumn(side: GDTeamSide, results: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(results.indices, id: \.self) { i in
                Text(results[i])
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(formColor(results[i]))
                    .clipShape(Circle())
            }
        }
    }

    private func formColor(_ result: String) -> Color {
        switch result.uppercased() {
        case "W": return .green.opacity(0.75)
        case "L": return .red.opacity(0.75)
        default: return .gray.opacity(0.5)
        }
    }

    // MARK: Venue

    @ViewBuilder
    private var venueSection: some View {
        if detail.venueLine != nil || !detail.officials.isEmpty {
            sectionCard("Match Info") {
                VStack(alignment: .leading, spacing: 10) {
                    if let venue = detail.venueLine {
                        infoRow(icon: "building.2", title: venue.name, subtitle: venue.city)
                    }
                    if let attendance = detail.attendance, attendance > 0 {
                        infoRow(icon: "person.3", title: "Attendance", subtitle: attendance.formatted())
                    }
                    if !detail.officials.isEmpty {
                        infoRow(
                            icon: "figure.walk",
                            title: detail.officials.count > 1 ? "Officials" : "Referee",
                            subtitle: detail.officials.joined(separator: ", ")
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func infoRow(icon: String, title: String, subtitle: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Section shell

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white.opacity(0.75))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

// MARK: - Watch button glass

/// Liquid-glass capsule for the detail pages' watch buttons — real
/// glassEffect on iOS 26, ultra-thin material below, matching the app's
/// other glass controls.
struct WatchButtonGlass: ViewModifier {
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

/// WatchButtonGlass that can stand down: the detail page's pill toggles
/// swap their glass for a solid state-color fill while active, and glass
/// layered over the fill would wash it out.
struct ConditionalWatchGlass: ViewModifier {
    let showGlass: Bool
    func body(content: Content) -> some View {
        if showGlass {
            AnyView(content.modifier(WatchButtonGlass()))
        } else {
            AnyView(content)
        }
    }
}

/// Live Activity toggle pill for any live game — glass at rest, solid red
/// with a glow while the game is on the Lock Screen. Shared across the
/// team-sport, tennis, and MMA detail pages so every sport gets the same
/// control next to its watch button.
struct LiveActivityPillButton: View {
    let game: ESPNEvent
    let leagueName: String
    var sport: SportType? = nil
    @ObservedObject private var activityManager = GameActivityManager.shared

    var body: some View {
        let isTracking = activityManager.trackedGameIDs.contains(game.id)
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                activityManager.toggle(game: game, leagueName: leagueName, sport: sport)
            }
        } label: {
            Image(systemName: isTracking ? "bell.badge.fill" : "bell.badge")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 52, height: 22)
                .padding(.vertical, 13)
                .background {
                    if isTracking {
                        Capsule().fill(Color.red)
                    }
                }
                .modifier(ConditionalWatchGlass(showGlass: !isTracking))
                .overlay {
                    if isTracking {
                        Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                    }
                }
                .shadow(color: isTracking ? Color.red.opacity(0.45) : .clear, radius: 10, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bases diamond

/// Scoreboard-style base indicator: second base on top, third left, first
/// right. Occupied bases fill in the batting team's color.
struct BasesDiamondView: View {
    let onFirst: Bool
    let onSecond: Bool
    let onThird: Bool
    let fillColor: Color

    var body: some View {
        ZStack {
            base(occupied: onSecond).offset(y: -15)
            base(occupied: onThird).offset(x: -17, y: 2)
            base(occupied: onFirst).offset(x: 17, y: 2)
        }
        .frame(width: 66, height: 58)
    }

    private func base(occupied: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(occupied ? fillColor : Color.white.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(occupied ? fillColor : Color.white.opacity(0.3), lineWidth: 1.2)
            )
            .frame(width: 20, height: 20)
            .rotationEffect(.degrees(45))
    }
}

// MARK: - Rating badge

/// FotMob-style colored rating chip: red < 5, orange 5–6.9, green 7+.
/// Blue is reserved for the single best-rated player of the whole match
/// (`isTop`) — everyone else caps at green no matter how high the number.
/// Hidden (dash) when no rating could be computed.
struct RatingBadge: View {
    let rating: Double?
    var compact: Bool = false
    var isTop: Bool = false

    var body: some View {
        Group {
            if let rating {
                Text(String(format: "%.1f", rating))
                    .font(.system(size: compact ? 10 : 12, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, compact ? 4 : 6)
                    .padding(.vertical, compact ? 2 : 3)
                    .background(color(for: rating))
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 5 : 6))
            } else if compact {
                Text("–")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(width: 26)
            }
        }
        .frame(minWidth: compact ? 26 : 32)
    }

    private func color(for rating: Double) -> Color {
        if isTop { return Color(red: 0.1, green: 0.65, blue: 0.85) }
        switch rating {
        case ..<5.0: return Color(red: 0.85, green: 0.25, blue: 0.25)
        case ..<7.0: return Color(red: 0.95, green: 0.6, blue: 0.1)
        default: return Color(red: 0.2, green: 0.7, blue: 0.35)
        }
    }
}

// MARK: - Player stats sheet

/// Individual match stats, one page per lineup player — swipe sideways to
/// move through the whole roster, same paging feel as the games pager.
struct PlayerStatsSheet: View {
    let players: [GDLineupPlayer]
    let initialID: String
    let side: GDTeamSide
    let showPhotos: Bool
    let topRatedID: String?
    let heatPoints: (String) -> [GDHeatPoint]

    @State private var selection: String?

    init(players: [GDLineupPlayer], initialID: String, side: GDTeamSide, showPhotos: Bool, topRatedID: String?, heatPoints: @escaping (String) -> [GDHeatPoint]) {
        self.players = players
        self.initialID = initialID
        self.side = side
        self.showPhotos = showPhotos
        self.topRatedID = topRatedID
        self.heatPoints = heatPoints
        _selection = State(initialValue: initialID)
    }

    var body: some View {
        // Same card carousel as the games pager: full-width pages with the
        // neighbors peeking in from the screen edges.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 9) {
                    ForEach(players) { player in
                        PlayerStatsPage(player: player, side: side, showPhoto: showPhotos, isTopRated: player.id == topRatedID, points: heatPoints(player.id))
                            // Translucent frosted glass: the match detail
                            // blurs through the card, with a dark tint on top
                            // keeping the stat text readable.
                            .background { Color.black.opacity(0.3).background(.ultraThinMaterial) }
                            .containerRelativeFrame(.horizontal)
                            .clipShape(
                                UnevenRoundedRectangle(
                                    topLeadingRadius: 34, bottomLeadingRadius: 0,
                                    bottomTrailingRadius: 0, topTrailingRadius: 34
                                )
                            )
                            .overlay(alignment: .top) { CardGrabber() }
                            .id(player.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .safeAreaPadding(.horizontal, 20)
            .scrollPosition(id: $selection)
            .onAppear {
                // The binding's initial value alone lands unreliably in a
                // lazy carousel — anchor the opening page explicitly.
                proxy.scrollTo(selection, anchor: .center)
            }
            .onChange(of: selection) { _, _ in
                ChannelViewModel.shared.triggerSelectionHaptic()
            }
        }
        .padding(.top, 31)
        .preferredColorScheme(.dark)
    }
}

/// One player's page: header, then grouped stat rows.
/// The name/position strip pins to the top once the header scrolls away —
/// same behavior as the game page's compact score bar.
private struct PlayerStatsPage: View {
    let player: GDLineupPlayer
    let side: GDTeamSide
    let showPhoto: Bool
    let isTopRated: Bool
    let points: [GDHeatPoint]

    @Environment(\.playerSheetDismiss) private var dismiss
    @Environment(\.playerSheetAtTop) private var reportAtTop
    @Environment(\.playerSheetDragActive) private var dragActive
    /// 0 while the big header is visible, 1 once it has scrolled past.
    @State private var collapse: CGFloat = 0
    /// Cancels the scroll's own top rubber-band so the content rides down
    /// with the card during a pull-to-close instead of drifting ahead of it.
    @State private var bounceCancel = ScrollProgress()

    private static let topKeys = ["minutes", "totalGoals", "goalAssists", "totalShots", "shotsOnTarget", "accuratePasses", "saves", "goalsConceded"]
    private static let attackKeys = ["totalPasses", "totalCrosses", "accurateCrosses", "totalLongBalls", "accurateLongBalls", "blockedShots", "offsides", "ownGoals"]
    private static let defenseKeys = ["totalTackles", "effectiveTackles", "totalClearance", "effectiveClearance", "interceptions", "shotsFaced", "punches", "crossesCaught"]
    private static let disciplineKeys = ["foulsCommitted", "foulsSuffered", "yellowCards", "redCards"]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 26) {
                header
                statSection("Top stats", keys: Self.topKeys, extraRows: xgRows)
                statSection("Attack", keys: Self.attackKeys)
                statSection("Defense", keys: Self.defenseKeys)
                statSection("Discipline", keys: Self.disciplineKeys)
                otherSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 28)
            .padding(.bottom, 44)
            .scrollProgressOffset(bounceCancel)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, scrolled in
            // The avatar + name block is ~150pt tall; crossfade the pinned
            // strip in over the stretch where it slides out.
            collapse = min(max((scrolled - 110) / 45, 0), 1)
            // Report at-top to the container's dismiss drag; cancel the top
            // rubber-band only while that drag is engaged.
            let overscroll = max(0, -scrolled)
            bounceCancel.set((dragActive?.value ?? false) ? -overscroll : 0)
            reportAtTop(scrolled <= 1)
        }
        .background(alignment: .top) { TeamGlow(color: side.color) }
        .overlay(alignment: .top) { compactBar.opacity(collapse) }
    }

    /// Pinned name strip once the header scrolls away.
    private var compactBar: some View {
        VStack(spacing: 2) {
            Text(player.fullName)
                .font(.system(size: 17, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 5) {
                if let pos = player.positionAbbrev {
                    Text(pos)
                }
                Text("·")
                Text(side.name).lineLimit(1)
                RatingBadge(rating: player.rating, compact: true, isTop: isTopRated)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        // Same translucent fade as the game page's pinned score bar.
        .background(alignment: .top) { PinnedHeaderGradient() }
    }

    /// Estimated xG row appended to Top stats when the player took a shot.
    private var xgRows: [GDPlayerStatLine] {
        guard let xg = GameDetailViewModel.estimatedXG(points: points) else { return [] }
        return [GDPlayerStatLine(key: "xgEstimate", label: "Expected goals (est.)", value: String(format: "%.2f", xg))]
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 92, height: 92)
                    .overlay(
                        Group {
                            if showPhoto, let headshot = player.headshot, !headshot.isEmpty {
                                CachedAsyncImage(
                                    urlString: headshot,
                                    size: CGSize(width: 92, height: 92),
                                    failurePlaceholder: AnyView(sheetJerseyFallback)
                                )
                                .frame(width: 92, height: 92)
                                .clipShape(Circle())
                            } else {
                                sheetJerseyFallback
                            }
                        }
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                RatingBadge(rating: player.rating, isTop: isTopRated)
                    .offset(x: 8, y: -2)
            }
            VStack(spacing: 4) {
                Text(player.fullName)
                    .font(.system(size: 23, weight: .bold))
                statusLine
            }

            HStack(spacing: 0) {
                infoColumn(top: { Text(player.positionAbbrev ?? "—").font(.system(size: 16, weight: .semibold)) }, label: "Position")
                infoColumn(top: {
                    HStack(spacing: 6) {
                        CachedAsyncImage(urlString: side.logo ?? "", size: CGSize(width: 18, height: 18))
                            .frame(width: 18, height: 18)
                        Text(side.name)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }, label: "Team")
                infoColumn(top: { Text(player.age.map { "\($0)" } ?? "—").font(.system(size: 16, weight: .semibold)) }, label: "Age")
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    /// Goals / cards / sub markers under the name, only when present.
    @ViewBuilder private var statusLine: some View {
        let hasAny = player.goals > 0 || player.yellow || player.red || player.subbedOffClock != nil || player.subbedOnClock != nil
        if hasAny {
            HStack(spacing: 8) {
                if player.goals > 0 {
                    Label("\(player.goals)", systemImage: "soccerball.inverse")
                        .font(.system(size: 12, weight: .semibold))
                }
                if player.red {
                    RoundedRectangle(cornerRadius: 1.5).fill(.red).frame(width: 9, height: 12)
                } else if player.yellow {
                    RoundedRectangle(cornerRadius: 1.5).fill(.yellow).frame(width: 9, height: 12)
                }
                if let off = player.subbedOffClock {
                    Text("▼ \(off)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
                }
                if let on = player.subbedOnClock, !on.isEmpty {
                    Text("▲ \(on)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
                }
            }
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var sheetJerseyFallback: some View {
        Text(player.jersey.isEmpty ? "—" : "#\(player.jersey)")
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
    }

    private func infoColumn(@ViewBuilder top: () -> some View, label: String) -> some View {
        VStack(spacing: 3) {
            top()
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func lines(for keys: [String]) -> [GDPlayerStatLine] {
        keys.compactMap { key in player.stats.first(where: { $0.key == key }) }
    }

    @ViewBuilder private func statSection(_ title: String, keys: [String], extraRows: [GDPlayerStatLine] = []) -> some View {
        let rows = lines(for: keys) + extraRows
        if !rows.isEmpty { statList(title, rows: rows) }
    }

    /// Whatever ESPN sent that isn't already shown above.
    @ViewBuilder private var otherSection: some View {
        let known = Set(Self.topKeys + Self.attackKeys + Self.defenseKeys + Self.disciplineKeys)
        let rows = player.stats.filter { !known.contains($0.key) }
        if !rows.isEmpty { statList("Other", rows: rows) }
    }

    private func statList(_ title: String, rows: [GDPlayerStatLine]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .padding(.bottom, 6)
            ForEach(rows) { line in
                HStack {
                    Text(line.label)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text(line.value)
                        .font(.system(size: 16, weight: .semibold))
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Box-score player sheet (US sports)

struct BoxSheetPlayer: Identifiable {
    let id: String
    let name: String
    let headshot: String?
    var rating: Double?
    var sections: [BoxSheetSection]
}

struct BoxSheetSection: Identifiable {
    let title: String
    let lines: [GDPlayerStatLine]
    var id: String { title }
}

/// Soft team-color wash bleeding down from the top of a player page.
struct TeamGlow: View {
    let color: Color
    var body: some View {
        Ellipse()
            .fill(color.opacity(0.45))
            .frame(height: 260)
            .padding(.horizontal, -60)
            .blur(radius: 70)
            .offset(y: -120)
            .allowsHitTesting(false)
    }
}

/// Individual stats for a box-score athlete — same card carousel, header
/// and pinned-strip treatment as the soccer player sheet, with one section
/// per stat group the player appears in.
struct BoxPlayerStatsSheet: View {
    let players: [BoxSheetPlayer]
    let initialID: String
    let side: GDTeamSide
    let topRatedID: String?

    @State private var selection: String?

    init(players: [BoxSheetPlayer], initialID: String, side: GDTeamSide, topRatedID: String?) {
        self.players = players
        self.initialID = initialID
        self.side = side
        self.topRatedID = topRatedID
        _selection = State(initialValue: initialID)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 9) {
                    ForEach(players) { player in
                        BoxPlayerStatsPage(player: player, side: side, isTopRated: player.id == topRatedID)
                            // Translucent frosted glass: the match detail
                            // blurs through the card, with a dark tint on top
                            // keeping the stat text readable.
                            .background { Color.black.opacity(0.3).background(.ultraThinMaterial) }
                            .containerRelativeFrame(.horizontal)
                            .clipShape(
                                UnevenRoundedRectangle(
                                    topLeadingRadius: 34, bottomLeadingRadius: 0,
                                    bottomTrailingRadius: 0, topTrailingRadius: 34
                                )
                            )
                            .overlay(alignment: .top) { CardGrabber() }
                            .id(player.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .safeAreaPadding(.horizontal, 20)
            .scrollPosition(id: $selection)
            .onAppear {
                proxy.scrollTo(selection, anchor: .center)
            }
            .onChange(of: selection) { _, _ in
                ChannelViewModel.shared.triggerSelectionHaptic()
            }
        }
        .padding(.top, 31)
        .preferredColorScheme(.dark)
    }
}

private struct BoxPlayerStatsPage: View {
    let player: BoxSheetPlayer
    let side: GDTeamSide
    let isTopRated: Bool

    @Environment(\.playerSheetDismiss) private var dismiss
    @Environment(\.playerSheetAtTop) private var reportAtTop
    @Environment(\.playerSheetDragActive) private var dragActive
    @State private var collapse: CGFloat = 0
    @State private var bounceCancel = ScrollProgress()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 26) {
                header
                ForEach(player.sections) { section in
                    statList(section)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 28)
            .padding(.bottom, 44)
            .scrollProgressOffset(bounceCancel)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, scrolled in
            collapse = min(max((scrolled - 110) / 45, 0), 1)
            let overscroll = max(0, -scrolled)
            bounceCancel.set((dragActive?.value ?? false) ? -overscroll : 0)
            reportAtTop(scrolled <= 1)
        }
        .background(alignment: .top) { TeamGlow(color: side.color) }
        .overlay(alignment: .top) { compactBar.opacity(collapse) }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 92, height: 92)
                    .overlay(
                        Group {
                            if let headshot = player.headshot, !headshot.isEmpty {
                                CachedAsyncImage(
                                    urlString: headshot,
                                    size: CGSize(width: 92, height: 92),
                                    failurePlaceholder: AnyView(personFallback)
                                )
                                .frame(width: 92, height: 92)
                                .clipShape(Circle())
                            } else {
                                personFallback
                            }
                        }
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                RatingBadge(rating: player.rating, isTop: isTopRated)
                    .offset(x: 8, y: -2)
            }
            Text(player.name)
                .font(.system(size: 23, weight: .bold))
            HStack(spacing: 6) {
                CachedAsyncImage(urlString: side.logo ?? "", size: CGSize(width: 18, height: 18))
                    .frame(width: 18, height: 18)
                Text(side.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var personFallback: some View {
        Image(systemName: "person.fill")
            .font(.system(size: 34))
            .foregroundStyle(.white.opacity(0.4))
    }

    private var compactBar: some View {
        VStack(spacing: 2) {
            Text(player.name)
                .font(.system(size: 17, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 5) {
                Text(side.name).lineLimit(1)
                RatingBadge(rating: player.rating, compact: true, isTop: isTopRated)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(alignment: .top) { PinnedHeaderGradient() }
    }

    private func statList(_ section: BoxSheetSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.system(size: 20, weight: .bold))
                .padding(.bottom, 6)
            ForEach(section.lines) { line in
                HStack {
                    Text(line.label)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text(line.value)
                        .font(.system(size: 16, weight: .semibold))
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Formation pitch

/// Draws a soccer half-pitch with the team laid out by formation rows,
/// goalkeeper at the bottom, attack at the top — one team at a time, which
/// keeps every name readable on a phone (a full two-team pitch makes each
/// chip ~40pt and unreadable).
struct FormationPitchView: View {
    /// Rows from the goalkeeper outward.
    let rows: [[GDLineupPlayer]]
    let teamColor: Color
    /// All-or-nothing: true only when every player's headshot resolved.
    var showPhotos: Bool = false
    /// Match-best player — the only blue rating badge on the pitch.
    var topRatedID: String? = nil
    /// Deliberate horizontal swipe over the pitch (raw translation).
    var onSwipe: (CGFloat) -> Void = { _ in }
    var onTapPlayer: (GDLineupPlayer) -> Void = { _ in }

    var body: some View {
        // Attack at the top: last formation row first, GK last.
        let displayRows = Array(rows.reversed())
        GeometryReader { geo in
            let rowHeight = geo.size.height / CGFloat(max(displayRows.count, 1))
            ZStack {
                pitchLines(in: geo.size)
                ForEach(displayRows.indices, id: \.self) { rowIndex in
                    let row = displayRows[rowIndex]
                    let y = rowHeight * (CGFloat(rowIndex) + 0.5)
                    let slotWidth = geo.size.width / CGFloat(row.count)
                    ForEach(row.indices, id: \.self) { colIndex in
                        PitchPlayerChip(player: row[colIndex], teamColor: teamColor, showPhoto: showPhotos, isTopRated: row[colIndex].id == topRatedID)
                            .position(x: slotWidth * (CGFloat(colIndex) + 0.5), y: y)
                    }
                }
                // UIKit pan, not a SwiftUI drag: it only claims clearly
                // horizontal gestures, so vertical swipes over the pitch
                // scroll the page normally. It swallows taps, so player
                // taps are mapped back through the slot grid.
                HorizontalPanOverlay(onSwipe: onSwipe, onTap: { location in
                    guard rowHeight > 0, !displayRows.isEmpty else { return }
                    let rowIndex = min(max(Int(location.y / rowHeight), 0), displayRows.count - 1)
                    let row = displayRows[rowIndex]
                    guard !row.isEmpty else { return }
                    let slotWidth = geo.size.width / CGFloat(row.count)
                    let colIndex = min(max(Int(location.x / slotWidth), 0), row.count - 1)
                    onTapPlayer(row[colIndex])
                })
            }
        }
        // Fixed height regardless of formation — a 3-row 4-4-2 and a 5-row
        // 4-2-3-1 draw the same pitch, the rows just space out differently.
        .frame(height: 400)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func pitchLines(in size: CGSize) -> some View {
        Canvas { context, _ in
            let line = Color.white.opacity(0.10)
            // Goal box at the bottom (GK end).
            let boxWidth = size.width * 0.5
            let box = CGRect(x: (size.width - boxWidth) / 2, y: size.height - 34, width: boxWidth, height: 34)
            context.stroke(Path(box), with: .color(line), lineWidth: 1)
            let smallWidth = size.width * 0.24
            let small = CGRect(x: (size.width - smallWidth) / 2, y: size.height - 14, width: smallWidth, height: 14)
            context.stroke(Path(small), with: .color(line), lineWidth: 1)
            // Center circle arc at the top (halfway line is the top edge).
            var arc = Path()
            arc.addArc(center: CGPoint(x: size.width / 2, y: 0), radius: 36,
                       startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            context.stroke(arc, with: .color(line), lineWidth: 1)
        }
    }
}

private struct PitchPlayerChip: View {
    let player: GDLineupPlayer
    let teamColor: Color
    var showPhoto: Bool = false
    var isTopRated: Bool = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(teamColor.opacity(0.9))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Group {
                            if showPhoto, let headshot = player.headshot, !headshot.isEmpty {
                                CachedAsyncImage(
                                    urlString: headshot,
                                    size: CGSize(width: 38, height: 38),
                                    failurePlaceholder: AnyView(jerseyFallback)
                                )
                                .frame(width: 38, height: 38)
                                .clipShape(Circle())
                            } else {
                                jerseyFallback
                            }
                        }
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                RatingBadge(rating: player.rating, compact: true, isTop: isTopRated)
                    .offset(x: 14, y: -6)
            }
            HStack(spacing: 2) {
                if player.goals > 0 {
                    Image(systemName: "soccerball.inverse").font(.system(size: 9))
                }
                if player.red {
                    RoundedRectangle(cornerRadius: 1).fill(.red).frame(width: 5, height: 8)
                } else if player.yellow {
                    RoundedRectangle(cornerRadius: 1).fill(.yellow).frame(width: 5, height: 8)
                }
                if player.subbedOffClock != nil {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.red)
                }
                Text(player.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: 80)
        }
    }

    private var jerseyFallback: some View {
        Text(player.jersey.isEmpty ? "—" : player.jersey)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
    }
}

// MARK: - Shot map

/// Full-pitch shot chart: home team's shots plotted at the left goal, away
/// at the right. ESPN coordinates arrive normalized toward the attacked
/// goal (x → 100 at the goal line) for both teams, so the home side is
/// mirrored onto the left half.
struct ShotMapView: View {
    let shots: [GDShot]
    let homeColor: Color
    let awayColor: Color

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                pitchLines(in: size)
                ForEach(shots) { shot in
                    shotMarker(shot)
                        .position(markerPosition(for: shot, in: size))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func markerPosition(for shot: GDShot, in size: CGSize) -> CGPoint {
        let xFraction: Double = shot.isHome ? (100.0 - shot.x) / 100.0 : shot.x / 100.0
        let px = size.width * CGFloat(xFraction)
        let py = size.height * CGFloat(shot.y / 100.0)
        return CGPoint(
            x: min(max(px, 8), size.width - 8),
            y: min(max(py, 8), size.height - 8)
        )
    }

    @ViewBuilder
    private func shotMarker(_ shot: GDShot) -> some View {
        let color = shot.isHome ? homeColor : awayColor
        if shot.isGoal {
            ZStack {
                Circle().fill(color).frame(width: 15, height: 15)
                Image(systemName: "soccerball.inverse")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
            }
        } else {
            Circle()
                .stroke(color, lineWidth: 1.8)
                .frame(width: 12, height: 12)
        }
    }

    private func pitchLines(in size: CGSize) -> some View {
        Canvas { context, _ in
            let line = Color.white.opacity(0.10)
            // Halfway line + center circle.
            var mid = Path()
            mid.move(to: CGPoint(x: size.width / 2, y: 0))
            mid.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            context.stroke(mid, with: .color(line), lineWidth: 1)
            let circle = CGRect(x: size.width / 2 - 28, y: size.height / 2 - 28, width: 56, height: 56)
            context.stroke(Path(ellipseIn: circle), with: .color(line), lineWidth: 1)
            // Penalty boxes.
            let boxHeight = size.height * 0.56
            let boxWidth = size.width * 0.16
            let leftBox = CGRect(x: 0, y: (size.height - boxHeight) / 2, width: boxWidth, height: boxHeight)
            let rightBox = CGRect(x: size.width - boxWidth, y: (size.height - boxHeight) / 2, width: boxWidth, height: boxHeight)
            context.stroke(Path(leftBox), with: .color(line), lineWidth: 1)
            context.stroke(Path(rightBox), with: .color(line), lineWidth: 1)
            // Six-yard boxes.
            let smallHeight = size.height * 0.26
            let smallWidth = size.width * 0.06
            let leftSmall = CGRect(x: 0, y: (size.height - smallHeight) / 2, width: smallWidth, height: smallHeight)
            let rightSmall = CGRect(x: size.width - smallWidth, y: (size.height - smallHeight) / 2, width: smallWidth, height: smallHeight)
            context.stroke(Path(leftSmall), with: .color(line), lineWidth: 1)
            context.stroke(Path(rightSmall), with: .color(line), lineWidth: 1)
        }
    }
}

// MARK: - Horizontal-only pan (UIKit)

private struct HorizontalPanOverlay: UIViewRepresentable {
    let onSwipe: (CGFloat) -> Void
    /// The overlay's UIView swallows every touch over the column, so taps
    /// must come through it too — reported in the overlay's coordinates.
    var onTap: ((CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSwipe = onSwipe
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSwipe: onSwipe, onTap: onTap) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSwipe: (CGFloat) -> Void
        var onTap: ((CGPoint) -> Void)?
        init(onSwipe: @escaping (CGFloat) -> Void, onTap: ((CGPoint) -> Void)?) {
            self.onSwipe = onSwipe
            self.onTap = onTap
        }

        @objc func panned(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .ended else { return }
            let t = pan.translation(in: pan.view)
            // A deliberate swipe, not a nudge: at least 55 pts of travel,
            // clearly more sideways than vertical.
            guard abs(t.x) >= 55, abs(t.x) > abs(t.y) * 1.5 else { return }
            onSwipe(t.x)
        }

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            onTap?(tap.location(in: tap.view))
        }

        func gestureRecognizerShouldBegin(_ r: UIGestureRecognizer) -> Bool {
            guard let pan = r as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }
    }
}

// MARK: - Momentum chart

/// FotMob-style momentum ribbon: the area above the midline (home on top)
/// fills in the home color, below in the away color. Points are lightly
/// smoothed so the raw per-play win-probability feed doesn't render as
/// jagged noise. The x-axis spans the WHOLE game; `progress` says how much
/// has been played, so a live game's curve stops partway with empty track
/// ahead of it. With `interactive`, press-and-hold scrubs a marker along
/// the curve and shows the probability at that moment.
struct MomentumChart: View {
    let points: [Double]
    let homeColor: Color
    let awayColor: Color
    var progress: Double = 1
    var homeAbbrev: String = ""
    var awayAbbrev: String = ""
    var interactive: Bool = false

    /// Scrub position as a fraction of the full chart width, while the
    /// finger is down.
    @State private var scrubFraction: CGFloat?

    private var smoothed: [Double] {
        guard points.count > 4 else { return points }
        return points.indices.map { i in
            let lo = max(0, i - 1), hi = min(points.count - 1, i + 1)
            var sum = 0.0
            for j in lo...hi { sum += points[j] }
            return sum / Double(hi - lo + 1)
        }
    }

    private var span: CGFloat { CGFloat(min(max(progress, 0.05), 1)) }

    var body: some View {
        let values = smoothed
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                // Midline = 50/50, across the whole game.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height / 2))
                    p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                areaPath(values, in: size, home: true)
                    .fill(homeColor.opacity(0.6))
                areaPath(values, in: size, home: false)
                    .fill(awayColor.opacity(0.6))

                if interactive, let fraction = scrubFraction, !values.isEmpty {
                    scrubOverlay(values, fraction: fraction, in: size)
                }
            }
            .simultaneousGesture(scrubGesture(in: size), isEnabled: interactive)
        }
    }

    // MARK: Scrubbing

    /// Hold-then-drag: the chart only takes the touch after a short press
    /// with the finger essentially still. A vertical swipe moves past the
    /// hold's distance limit almost immediately, so page scrolling and
    /// sheet dismissal keep working when the gesture starts on the chart.
    private func scrubGesture(in size: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 8)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .second(true, let drag):
                    if scrubFraction == nil { ChannelViewModel.shared.triggerSelectionHaptic() }
                    let x = drag?.location.x ?? size.width * span
                    scrubFraction = min(max(x / max(size.width, 1), 0), span)
                default:
                    break
                }
            }
            .onEnded { _ in scrubFraction = nil }
    }

    @ViewBuilder
    private func scrubOverlay(_ values: [Double], fraction: CGFloat, in size: CGSize) -> some View {
        let index = Int((fraction / span * CGFloat(values.count - 1)).rounded())
        let clamped = min(max(index, 0), values.count - 1)
        let probability = values[clamped]
        let x = size.width * fraction
        let y = size.height * CGFloat(1 - probability)
        let homeLeads = probability >= 0.5
        let percent = Int(((homeLeads ? probability : 1 - probability) * 100).rounded())
        let label = "\(homeLeads ? homeAbbrev : awayAbbrev) \(percent)%"

        Path { p in
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
        }
        .stroke(Color.white.opacity(0.5), lineWidth: 1)

        Circle()
            .fill(homeLeads ? homeColor : awayColor)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .position(x: x, y: y)

        Text(label)
            .font(.system(size: 11, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((homeLeads ? homeColor : awayColor).opacity(0.9))
            .clipShape(Capsule())
            .position(x: min(max(x, 34), size.width - 34), y: 10)
    }

    // MARK: Geometry

    private func xy(_ values: [Double], _ index: Int, in size: CGSize) -> CGPoint {
        // Data spans only the played fraction of the width.
        let x = size.width * span * CGFloat(index) / CGFloat(max(values.count - 1, 1))
        // Home win % of 1 → top edge; 0 → bottom edge.
        let y = size.height * CGFloat(1 - values[index])
        return CGPoint(x: x, y: y)
    }

    /// The probability area on one side of the midline: y clamped to the
    /// home half (above) or away half (below), closed back along the line.
    private func areaPath(_ values: [Double], in size: CGSize, home: Bool) -> Path {
        Path { p in
            guard !values.isEmpty else { return }
            let mid = size.height / 2
            func clampedY(_ i: Int) -> CGFloat {
                let y = xy(values, i, in: size).y
                return home ? min(y, mid) : max(y, mid)
            }
            p.move(to: CGPoint(x: 0, y: mid))
            for i in 0..<values.count {
                p.addLine(to: CGPoint(x: xy(values, i, in: size).x, y: clampedY(i)))
            }
            p.addLine(to: CGPoint(x: size.width * span, y: mid))
            p.closeSubpath()
        }
    }
}

private extension GDMeeting {
    var awayTeamDisplayScore: String { awayScore.isEmpty ? "–" : awayScore }
    var homeTeamDisplayScore: String { homeScore.isEmpty ? "–" : homeScore }
}
