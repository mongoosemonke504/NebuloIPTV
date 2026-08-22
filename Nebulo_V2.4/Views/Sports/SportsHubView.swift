import SwiftUI
import UIKit
import UserNotifications

/// Selection state for the Sports hub tab bar.
/// `.all` shows the cross-sport Live overview; `.sport(_)` shows a specific
/// sport's scoreboard. Using a dedicated enum keeps the TabView selection and
/// the chip-row highlight in sync without a separate `allLiveMode` bool.
private enum SportsTab: Hashable {
    case all
    case sport(SportType)

    /// Key the hub's last tab is remembered under, so returning to Sports lands
    /// back where the user left it instead of resetting to "All".
    static let storageKey = "sportsHubLastTab"

    /// Stable string form. `SportType` is a String enum, so a sport tab stores
    /// as its raw value and "all" can't collide with one.
    var storedValue: String {
        switch self {
        case .all: return "all"
        case .sport(let sport): return sport.rawValue
        }
    }

    /// Restores a stored tab, falling back to `.all` for an unknown or missing
    /// value — including a sport the user has since hidden.
    static func restored(from stored: String?, allowing available: [SportType]) -> SportsTab {
        guard let stored, stored != "all",
              let sport = SportType(rawValue: stored),
              available.contains(sport) else { return .all }
        return .sport(sport)
    }
}

/// Watches a hub's visibility flag without pulling the hub's own body into it:
/// a zero-size view that observes the box and reports transitions.
private struct HubActivationProbe: View {
    @ObservedObject var flag: FlagBox
    let onChange: (Bool) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { onChange(flag.value) }
            .onChangeCompat(of: flag.value) { onChange($0) }
    }
}

struct SportsHubView: View {
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color; let playAction: (StreamChannel) -> Void; var onBack: (() -> Void)? = nil
    @ObservedObject var scoreViewModel: ScoreViewModel
    var onOpenSearch: (() -> Void)? = nil
    /// Whether this hub is the visible tab.
    ///
    /// The hub is kept alive across tab switches now (see StandardLayout), so
    /// everything it reacts to would keep firing while it is off screen — a
    /// filter pass on every keystroke in the app-wide search, a forced refresh
    /// on every foreground, and a `repeatForever` spinner driving frames for a
    /// view nobody can see. Each of those is gated on this.
    ///
    /// A leaf box read directly, deliberately NOT an `@ObservedObject` and not
    /// a plain `Bool` property. Either of those would make flipping tabs change
    /// this view's inputs, and re-evaluating a whole screen's body is exactly
    /// the pause that keeping it mounted was supposed to remove. Only the tiny
    /// probe below watches it.
    var active: FlagBox = FlagBox()
    @Environment(\.scenePhase) var scenePhase
    @State private var isRefreshingAnimation = false
    /// Header stat counts — refreshed whenever the live game set changes.
    @State private var todaysEventCount: Int = 0
    @State private var liveChannelCount: Int = 0

    /// Current tab — `.all` is the "Live Now" overview.
    /// Driving a single TabView with `.page` style lets the user swipe
    /// directly between "All" and any individual sport without tapping chips.
    ///
    /// Seeded from the last tab the user was on, so returning to Sports lands
    /// where they left it. Read straight out of UserDefaults here rather than
    /// restored in `onAppear`, which would render "All" for a frame first and
    /// visibly snap across. Validated against `orderedSports` on appear, since
    /// the stored sport may since have been hidden.
    @State private var sportsTab: SportsTab = SportsTab.restored(
        from: UserDefaults.standard.string(forKey: SportsTab.storageKey),
        allowing: SportType.allCases
    )

    /// 0 at rest, 1 once the big title has scrolled away. Tracked 1:1 with
    /// the scroll offset (no canned animation) — drives the title fade and
    /// the compact line growing into the pinned chip bar. Held in its own
    /// object (observed only by the fading title + gradient) so scrolling the
    /// scoreboard doesn't re-render this whole hub every frame.
    @State private var statsProgress = ScrollProgress()

    private var orderedSports: [SportType] {
        scoreViewModel.sportTabOrder.filter { !scoreViewModel.hiddenSportTabs.contains($0) }
    }

    /// Chips in visual order — "All" first, then each sport.
    private var orderedTabs: [SportsTab] {
        [.all] + orderedSports.map { SportsTab.sport($0) }
    }

    /// True while a slide transition is in flight. Tab changes are ignored
    /// during this window: interrupting a `.move` transition mid-animation
    /// can leave the incoming view stuck offscreen (a fully blank section)
    /// — rapid swipes must wait ~0.3s for the previous slide to settle.
    @State private var isSliding = false

    /// Which side the incoming games list enters from. `true` when moving to
    /// a chip further right ("All" → NFL → …), so content slides in from the
    /// trailing edge like a page turn. Set BEFORE the animated tab change so
    /// the transition reads the correct direction.
    @State private var slideFromTrailing = true

    /// One tab switch per drag: set the moment the swipe fires (mid-drag,
    /// in `.onChanged`), cleared when the finger lifts.
    @State private var swipeConsumed = false

    /// Global frame of the pinned chip row. Drags starting inside it scroll
    /// the chips instead of flipping the page.
    @State private var chipBarFrame: CGRect = .zero

    /// Set the instant a drag reads as horizontal, which disables the hub's
    /// vertical scroll for the rest of that gesture — a sideways swipe then
    /// travels purely sideways instead of also dragging the page up or down.
    /// A leaf box, so flipping it re-renders the scroll modifier alone.
    @State private var scrollLock = FlagBox()

    /// Offset-based scroll control for the hub's single scroll view.
    /// `scrollTo(id:)` was a silent no-op whenever the target row wasn't
    /// materialised by the LazyVStack (always the case when scrolled deep),
    /// so tab switches never actually reset — ScrollPosition works on raw
    /// offsets and is independent of lazy materialisation.
    @State private var hubScrollPos = ScrollPosition()

    /// Measured height of the stats-header block (title + counts + padding).
    /// Scrolling to exactly this offset lands on the "compact" state where
    /// the chip bar pins. Class box: layout writes must not re-render.
    final class HubMetrics {
        var headerHeight: CGFloat = 96
        /// Live vertical scroll offset. Kept here (not in @State) for the same
        /// reason as headerHeight: it updates every scroll frame and must not
        /// re-render the hub.
        var scrollY: CGFloat = 0
    }
    @State private var hubMetrics = HubMetrics()

    /// Central tab switch: derives the slide direction from chip order and
    /// swaps with a flat easeOut — deliberately no spring, no bounce.
    /// The page snaps INSTANTLY (no animation) to the new tab's top before
    /// the slide begins. If the header was already collapsed (user was
    /// scrolled down), it lands on the compact anchor instead so the chip
    /// bar stays pinned rather than the big title reappearing.
    private func selectTab(_ newTab: SportsTab) {
        guard newTab != sportsTab, !isSliding else { return }
        let tabs = orderedTabs
        let oldIdx = tabs.firstIndex(of: sportsTab) ?? 0
        let newIdx = tabs.firstIndex(of: newTab) ?? 0
        slideFromTrailing = newIdx > oldIdx
        isSliding = true
        // Land no lower than the compact anchor (chips pinned, big title gone)
        // and otherwise stay exactly where we are, so the page never moves
        // vertically while it's sliding horizontally.
        //
        // This used to key off statsProgress >= 0.99, which saturates at 40pt
        // scrolled while the compact anchor sits at headerHeight (~96pt): every
        // switch between those two points yanked the page DOWN to 96, and every
        // switch below 40pt yanked it UP to 0. That vertical jump landing on
        // the same frame as the horizontal slide was the jank.
        let targetY = min(hubMetrics.scrollY, hubMetrics.headerHeight)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            hubScrollPos.scrollTo(y: targetY)
        }
        withAnimation(.easeOut(duration: 0.25)) { sportsTab = newTab }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isSliding = false
        }
    }

    /// Warms the crests for the chips either side of the current one.
    ///
    /// `ImageLoader` only consults the memory cache while a view is being built
    /// (its disk path decoded on the main thread, which is what made scrolling
    /// stutter). So a chip switch whose crests are not yet resident builds rows
    /// with placeholders, and the logos resolve a few frames later — appearing
    /// in place instead of sliding in with the row they belong to, which is
    /// what stops the switch reading as one movement. `prefetchLogos` no-ops on
    /// anything already cached, so this is cheap to call on every switch.
    private func warmAdjacentTabs() {
        let tabs = orderedTabs
        guard let idx = tabs.firstIndex(of: sportsTab) else { return }
        for step in [-1, 1] {
            let neighbour = idx + step
            guard tabs.indices.contains(neighbour) else { continue }
            if case .sport(let sport) = tabs[neighbour] {
                scoreViewModel.prefetchLogos(for: sport)
            }
        }
    }

    /// What used to run in `onAppear`: now on every arrival at the tab, since
    /// the hub itself only appears once.
    private func arrive() {
        // No swipe can be in flight on arrival, so never inherit a frozen
        // scroll from a gesture that was cancelled on the way out.
        scrollLock.set(false)
        // The remembered tab was restored without knowing which sports are
        // visible (that needs the view model). Drop back to All if it names
        // a sport the user has since hidden, so the hub can't open on a tab
        // with no chip to match it.
        if case .sport(let sport) = sportsTab, !orderedSports.contains(sport) {
            sportsTab = .all
        }
        if scoreViewModel.isLoading {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isRefreshingAnimation = true
            }
        }
        // Ahead of the first swipe, not on it.
        warmAdjacentTabs()
    }

    /// Steps to the previous/next chip. Driven by the horizontal swipe.
    /// No haptic here — the buzz on every page swipe broke the immersion;
    /// haptics stay on deliberate chip taps only.
    private func advanceSportsTab(_ delta: Int) {
        let tabs = orderedTabs
        guard let idx = tabs.firstIndex(of: sportsTab) else { return }
        let next = idx + delta
        guard tabs.indices.contains(next) else { return }
        selectTab(tabs[next])
    }

    var body: some View {
        ZStack(alignment: .top) {
            // One scroll for the whole screen, exactly like Recordings: the
            // big "Sports" title is scroll content and physically scrolls
            // away with the games. The chip selector rides in a PINNED
            // section header — it scrolls as part of the page but sticks at
            // the top once it reaches it, so it's always available.
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    statsHeader
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                        .scrollProgressOpacity(statsProgress) { 1 - Double($0) }
                        .background(ScrollOffsetProbe(space: "sportsScroll", id: "sports"))
                        // Height of the header block == the compact scroll
                        // offset used by selectTab's reset.
                        .background(
                            GeometryReader { g in
                                Color.clear
                                    .onAppear { hubMetrics.headerHeight = g.size.height }
                                    .onChangeCompat(of: g.size.height) { hubMetrics.headerHeight = $0 }
                            }
                        )

                    Section(header: pinnedChipHeader) {
                        // ZStack so the outgoing and incoming lists overlap
                        // during the directional slide instead of stacking
                        // vertically. `.id(sportsTab)` gives each sport's
                        // list distinct identity so the transition fires.
                        ZStack(alignment: .top) {
                            Group {
                                if sportsTab == .all {
                                    AllLiveSportsView(
                                        scoreViewModel: scoreViewModel,
                                        viewModel: viewModel,
                                        accentColor: accentColor
                                    )
                                } else if case .sport(let s) = sportsTab {
                                    SportGamesListView(
                                        sport: s,
                                        scoreViewModel: scoreViewModel,
                                        viewModel: viewModel
                                    )
                                }
                            }
                            .id(sportsTab)
                            // Resolves the whole page's geometry as ONE unit
                            // while it slides. Without this a child whose own
                            // layout settles mid-transition — a logo that has
                            // just finished loading and now has a size — is
                            // positioned against the page's FINAL geometry
                            // rather than its animating one, so it sits still
                            // while everything around it travels. That is what
                            // stops the switch reading as a single movement.
                            .geometryGroup()
                            // Same slide as the Favorites section: move +
                            // opacity, NO opaque backdrop. The backdrop's dark
                            // fill clashed with the header gradient and the
                            // nebula behind the games; the fade keeps the
                            // brief overlap of outgoing/incoming lists subtle
                            // instead.
                            .transition(.asymmetric(
                                insertion: .move(edge: slideFromTrailing ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: slideFromTrailing ? .leading : .trailing).combined(with: .opacity)
                            ))
                        }
                        .padding(.top, 10)
                    }
                }
            }
            .coordinateSpace(name: "sportsScroll")
            .scrollPosition($hubScrollPos)
            // Frozen for the duration of a horizontal swipe (see scrollLock).
            .scrollLocked(scrollLock)
            .onPreferenceChange(SectionScrollOffsetsKey.self) { offsets in
                guard let y = offsets["sports"] else { return }
                hubMetrics.scrollY = max(0, -y)
                statsProgress.set(min(max(-y / 40, 0), 1))
            }
            // Horizontal swipe anywhere on the list turns the page. Fires
            // DURING the drag the moment it clearly reads as a deliberate
            // horizontal swipe — the slide itself is the manual two-page
            // animation (both sports visible), it just doesn't track the
            // finger. Drags that start on the chip row scroll the chips
            // instead, and left-edge swipes stay reserved for back
            // navigation.
            .simultaneousGesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .onChanged { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        // As soon as the drag reads as horizontal, open the
                        // tap-suppression window so the game row under the
                        // finger doesn't ALSO fire on release.
                        if abs(dx) > abs(dy) * 1.4 {
                            SwipeTapGuard.suppress()
                        }
                        // ...and FREEZE the vertical scroll, so a sideways
                        // swipe travels purely sideways instead of also
                        // dragging the page up or down. Drags on the chip row
                        // (which scroll the chips) and left-edge back swipes
                        // are left alone. A drag that turns decisively VERTICAL
                        // before a page flip releases the lock again, so this
                        // can never strand the page unscrollable.
                        if value.startLocation.x > 44,
                           !chipBarFrame.contains(value.startLocation) {
                            if abs(dx) > abs(dy) * 1.4 {
                                scrollLock.set(true)
                            } else if !swipeConsumed, abs(dy) > abs(dx) * 1.4 {
                                scrollLock.set(false)
                            }
                        }
                        guard !swipeConsumed, !isSliding,
                              value.startLocation.x > 44,
                              !chipBarFrame.contains(value.startLocation),
                              abs(dx) > 38, abs(dx) > abs(dy) * 1.4 else { return }
                        swipeConsumed = true
                        advanceSportsTab(dx < 0 ? 1 : -1)
                    }
                    .onEnded { _ in
                        swipeConsumed = false
                        scrollLock.set(false)
                    }
            )
            // Sync selectedSport when the chip selection changes so the
            // existing fetch/pre-resolution observers fire correctly.
            // Deferred past the slide: the observers kick off score fetches,
            // channel pre-resolution and crest prefetches — running those in
            // the same frames as the slide animation is what made the chip
            // switch look choppy.
            .onChangeCompat(of: sportsTab) { tab in
                // Remembered here rather than in selectTab, so a swipe between
                // tabs is recorded the same as a chip tap.
                UserDefaults.standard.set(tab.storedValue, forKey: SportsTab.storageKey)
                // The chips this one can now be swiped to, warmed while the
                // slide that just landed here is still finishing.
                warmAdjacentTabs()
                guard case .sport(let s) = tab else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard sportsTab == tab else { return }
                    if s != scoreViewModel.selectedSport {
                        scoreViewModel.selectedSport = s
                    }
                    scoreViewModel.prefetchLogos(for: s)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let onSearch = onOpenSearch {
                FavoritesSearchPill(onTap: onSearch)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 0)
            }
        }
        // No toolbar here: the system nav bar is permanently hidden by
        // MainViewModifiers, and the Back pill + settings gear are drawn
        // in-view by StandardLayout so all sections share the same chrome.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await scoreViewModel.fetchScores()
            scoreViewModel.applyFilter(text: viewModel.searchText)
            recomputeStats()

            // Everything below is WARMING — nothing on screen waits for it —
            // so it must not land on the frame the tab switch is animating.
            //
            // It was doing exactly that. `fetchScores` returns immediately
            // whenever its five-minute freshness guard holds, and an async
            // function that returns without ever suspending doesn't yield: the
            // whole body ran in one main-actor turn, right behind the hub's
            // first render. So every visit to this tab paid for a full
            // stream pre-resolution pass and a walk of every soccer section's
            // crests at precisely the worst moment.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            triggerPreResolution()
            // The busiest tab — many league sections of logos — so its crests
            // are cached before the user can swipe there, rather than
            // streaming in on arrival.
            scoreViewModel.prefetchLogos(for: .soccerLeagues)
        }
        // Recompute header stats whenever the live game set changes.
        .task(id: scoreViewModel.allLiveGameIDsKey) {
            recomputeStats()
        }
        // Was `.onAppear`. Mounted hubs appear once and then stay, so the
        // arrival work hangs off becoming visible instead — watched by a
        // zero-size probe so this screen's body stays out of it.
        .background(
            HubActivationProbe(flag: active) { isVisible in
                guard isVisible else {
                    // A spinner nobody can see must not keep driving frames.
                    isRefreshingAnimation = false
                    return
                }
                arrive()
            }
        )
        .onChangeCompat(of: scoreViewModel.isLoading) { loading in
            guard active.value else { return }
            if loading {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isRefreshingAnimation = true
                }
            } else {
                withAnimation(.default) {
                    isRefreshingAnimation = false
                }
                triggerPreResolution()
            }
        }
        .onChangeCompat(of: scenePhase) { phase in
            guard active.value else { return }
            if phase == .active {
                Task { 
                    await scoreViewModel.fetchScores(forceRefresh: true, silent: true)
                    triggerPreResolution()
                }
            }
        }
        .onChangeCompat(of: scoreViewModel.selectedSport) { _ in
            guard active.value else { return }
            // `_ =` keeps this a Void statement — as the closure's lone
            // expression, the Task would be its implicit return value and
            // Swift 6.2's named-Task initializer overloads become ambiguous.
            _ = Task {
                await scoreViewModel.fetchScores()
                triggerPreResolution()
            }
        }
        .onChangeCompat(of: viewModel.searchText) { text in
            // Every keystroke in the app-wide search reached here. Hidden, it
            // would filter and pre-resolve streams for a screen nobody is
            // looking at, on the thread doing the typing.
            guard active.value else { return }
            scoreViewModel.applyFilter(text: text)
            triggerPreResolution()
        }
        // The stream picker moved up to MainViewModifiers: every "Stream List"
        // action sets the same flag, but this sheet only existed here, so the
        // one on a home or search card set it with nothing mounted to present
        // it and the menu item did nothing at all.
        // The race card itself is presented one level up, in MainView, so the
        // same request opens it from the hub, the home shelves and the hero.
        // The game detail is presented as a custom overlay from ContentView
        // (see GameDetailPresenter) — driven by the same detailRequest
        // binding a game tap sets here — so the hub renders live behind it.
    }
    
    // MARK: - Pinned chip header

    /// Sticky section header: just the sport chips (the compact title lives
    /// in StandardLayout's chrome row, level with Back/gear). Fixed height,
    /// NO background scrim — the chips are self-contained glass pills, and
    /// any backing gradient drew a visible edge below the chrome row that
    /// read as a second border. Content scrolls behind the pills, same as
    /// the app-wide bottom search bar.
    private var pinnedChipHeader: some View {
        SportSelectorView(
            selectedSport: Binding(
                get: {
                    if case .sport(let s) = sportsTab { return s }
                    return scoreViewModel.selectedSport
                },
                set: { newSport in
                    // selectTab derives the slide direction from chip order
                    // so tapping a chip slides the same way a swipe does.
                    // selectedSport syncs via the deferred sportsTab observer
                    // so the fetch/pre-resolution work never lands mid-slide.
                    selectTab(.sport(newSport))
                }
            ),
            pinnedCount: scoreViewModel.allPinnedGames.count,
            orderedSports: orderedSports,
            scoreViewModel: scoreViewModel,
            allMode: Binding(
                get: { sportsTab == .all },
                set: { isAll in if isAll { selectTab(.all) } }
            )
        ) {
            Task { await scoreViewModel.fetchScores() }
        }
        .padding(.vertical, 2)
        .captureGlobalFrame { chipBarFrame = $0 }
        // Home-style dark gradient. As part of the pinned header it renders
        // ABOVE the scrolling games (dimming them as they pass under) but
        // BEHIND the chips themselves, which stay at full contrast. The tall
        // frame + upward offset stretch it past the top of the screen — the
        // scroll's clip extends under the chrome row and status bar, so the
        // gradient reaches the true screen top and no edge can form; below,
        // it fades to clear well past the chips.
        .background(alignment: .top) {
            // Sized to the header above it: the chrome row lost 10pt, so the
            // scrim's reach and the point it starts fading come in to match.
            // The upward offset still clears the status bar plus that row with
            // slack — it is what stops an edge forming at the top of the screen.
            CompactHeaderScrim(height: 226, fadeStart: 0.46)
                .offset(y: -112)
                .scrollProgressOpacity(statsProgress, cullWhenHidden: true) { Double($0 * $0) }
        }
    }

    // MARK: - Stats header (above chips, visible on all tabs)

    private var statsHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: {
                ChannelViewModel.shared.triggerSelectionHaptic()
                Task { await scoreViewModel.fetchScores(forceRefresh: true) }
            }) {
                Text("Sports")
                    .font(NuvioTheme.pageTitleFont)
                    .foregroundStyle(.white)
                    .opacity(isRefreshingAnimation ? 0.3 : 1.0)
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Text("\(scoreViewModel.allLiveGames.count) LIVE")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.red)
                Text("·")
                    .foregroundStyle(.secondary)
                Text("\(liveChannelCount) channels")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text("\(todaysEventCount) events today")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recomputeStats() {
        let cal = Calendar.current

        var todaysIDs = Set<String>()
        for (sport, games) in scoreViewModel.filteredGames where !scoreViewModel.hiddenSportTabs.contains(sport) {
            for g in games where cal.isDateInToday(g.gameDate) {
                todaysIDs.insert(g.id)
            }
        }
        for (sport, sections) in scoreViewModel.filteredSectionsMap where !scoreViewModel.hiddenSportTabs.contains(sport) {
            for s in sections {
                for g in s.games where cal.isDateInToday(g.gameDate) {
                    todaysIDs.insert(g.id)
                }
            }
        }
        todaysEventCount = todaysIDs.count

        var channels = Set<String>()
        for game in scoreViewModel.allLiveGames {
            if let n = game.broadcastName?.lowercased(), !n.isEmpty {
                channels.insert(n)
            }
        }
        liveChannelCount = channels.count
    }

    private func triggerPreResolution() {
        let sport = scoreViewModel.selectedSport
        let games: [ESPNEvent]
        if isSoccerCategory(sport) {
            games = scoreViewModel.filteredSectionsMap[sport]?.flatMap { $0.games } ?? []
        } else {
            games = scoreViewModel.filteredGames[sport] ?? []
        }
        
        if !games.isEmpty {
            viewModel.preResolveGames(games)
        }
    }
    
    private func isSoccerCategory(_ sport: SportType) -> Bool {
        return sport == .soccerLeagues || sport == .domesticCups || sport == .continental || sport == .international
    }
    
}

struct SportGamesListView: View {
    let sport: SportType
    @ObservedObject var scoreViewModel: ScoreViewModel
    @ObservedObject var viewModel: ChannelViewModel
    
    // Content only — no ScrollView. SportsHubView provides the single
    // scroll so the title, pinned chips and games all share one page.
    //
    // Hybrid laziness: the first screenful of rows renders EAGERLY so the
    // tab slides in fully formed (an all-lazy list materialised visible
    // cards in batches mid-slide — the staggered pop-in), while everything
    // below the fold stays LAZY (an all-eager list built 100+ rows the
    // moment a swipe fired — the pre-switch stutter).
    private static let eagerRowBudget = 6

    var body: some View {
            VStack(spacing: 12) {
                if sport == .pinned {
                    if scoreViewModel.allPinnedGames.isEmpty {
                        EmptyStateView(title: "No Pinned Games", systemImage: "pin.slash", description: "Pin games to see them here.")
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        ForEach(scoreViewModel.allPinnedGames) { game in
                            // Resolve the real sport so pinned F1/MMA/tennis
                            // rows render and tap correctly.
                            scoreButton(game: game, sport: scoreViewModel.sportType(for: game))
                        }
                    }
                } else if usesSections(sport) {
                    if let sections = scoreViewModel.filteredSectionsMap[sport], !sections.isEmpty {

                        let allSectionGames = sections.flatMap { $0.games }
                        let pinnedSectionGames = allSectionGames.filter { scoreViewModel.pinnedGameIDs.contains($0.id) }

                        if !pinnedSectionGames.isEmpty {
                            Section(header: subCategoryHeader("Pinned")) {
                                ForEach(pinnedSectionGames) { game in
                                    scoreButton(game: game, sport: sport)
                                }
                            }
                        }

                        if sport == .tennis {
                            // Tournament first, then its draws (singles
                            // before doubles — the fetch orders them).
                            let groups = tennisGroups(sections)
                            if let first = groups.first {
                                tennisTournamentSection(first)
                            }
                            if groups.count > 1 {
                                LazyVStack(spacing: 12) {
                                    ForEach(groups.dropFirst(), id: \.name) { group in
                                        tennisTournamentSection(group)
                                    }
                                }
                            }
                        } else {
                            let split = splitSections(sections)
                            ForEach(split.eager, id: \.league) { s in
                                soccerSection(s)
                            }
                            if !split.lazy.isEmpty {
                                LazyVStack(spacing: 12) {
                                    ForEach(split.lazy, id: \.league) { s in
                                        soccerSection(s)
                                    }
                                }
                            }
                        }
                    } else {
                        emptyState
                    }
                } else {
                    let filtered = scoreViewModel.filteredGames[sport] ?? []
                    if filtered.isEmpty {
                        emptyState
                    } else {
                        let pinned = filtered.filter { scoreViewModel.pinnedGameIDs.contains($0.id) }
                        let unpinned = filtered.filter { !scoreViewModel.pinnedGameIDs.contains($0.id) }

                        if !pinned.isEmpty {
                            Section(header: subCategoryHeader("Pinned")) {
                                ForEach(pinned) { game in
                                    scoreButton(game: game, sport: sport)
                                }
                            }
                        }

                        if !unpinned.isEmpty {
                            Section(header: pinned.isEmpty ? AnyView(EmptyView()) : AnyView(subCategoryHeader("Games"))) {
                                ForEach(Array(unpinned.prefix(Self.eagerRowBudget))) { game in
                                    scoreButton(game: game, sport: sport)
                                }
                            }
                            if unpinned.count > Self.eagerRowBudget {
                                LazyVStack(spacing: 12) {
                                    ForEach(Array(unpinned.dropFirst(Self.eagerRowBudget))) { game in
                                        scoreButton(game: game, sport: sport)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 120)
    }

    /// Consecutive tennis sections ("Wimbledon — Men's Singles") bucketed by
    /// tournament, preserving feed order (majors first, singles draws before
    /// doubles within a tournament).
    private func tennisGroups(_ sections: [SoccerGameSection]) -> [(name: String, draws: [SoccerGameSection])] {
        var order: [String] = []
        var buckets: [String: [SoccerGameSection]] = [:]
        for section in sections {
            let name = section.league.components(separatedBy: TennisFeed.labelSeparator).first ?? section.league
            if buckets[name] == nil {
                order.append(name)
                buckets[name] = []
            }
            buckets[name]!.append(section)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// One tournament: prominent header, then each draw as a sub-section.
    @ViewBuilder
    private func tennisTournamentSection(_ group: (name: String, draws: [SoccerGameSection])) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.name)
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
            ForEach(group.draws, id: \.league) { draw in
                let remaining = draw.games.filter { !scoreViewModel.pinnedGameIDs.contains($0.id) }
                if !remaining.isEmpty {
                    subCategoryHeader(tennisDrawTitle(draw.league))
                    ForEach(remaining) { game in
                        scoreButton(game: game, sport: sport)
                    }
                }
            }
        }
    }

    private func tennisDrawTitle(_ league: String) -> String {
        let parts = league.components(separatedBy: TennisFeed.labelSeparator)
        return parts.count > 1 ? parts.dropFirst().joined(separator: TennisFeed.labelSeparator) : league
    }

    /// Splits the league sections at the eager-row budget: sections up to
    /// the first screenful render eagerly, the rest lazily.
    private func splitSections(_ sections: [SoccerGameSection]) -> (eager: [SoccerGameSection], lazy: [SoccerGameSection]) {
        var eager: [SoccerGameSection] = []
        var lazy: [SoccerGameSection] = []
        var count = 0
        for s in sections {
            if count < Self.eagerRowBudget {
                eager.append(s)
                count += s.games.count
            } else {
                lazy.append(s)
            }
        }
        return (eager, lazy)
    }

    @ViewBuilder
    private func soccerSection(_ s: SoccerGameSection) -> some View {
        let remainingGames = s.games.filter { !scoreViewModel.pinnedGameIDs.contains($0.id) }
        if !remainingGames.isEmpty {
            Section(header: leagueHeader(s.league)) {
                ForEach(remainingGames) { game in
                    scoreButton(game: game, sport: sport)
                }
            }
        }
    }

    private func subCategoryHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
    
    /// Sports whose scoreboard renders as titled sections instead of one
    /// flat list — the soccer buckets (per-league sections) and tennis
    /// (per-tournament-draw sections).
    private func usesSections(_ sport: SportType) -> Bool {
        return sport.isSoccer || sport == .tennis
    }

    @ViewBuilder
    private var emptyState: some View {
        if scoreViewModel.isLoading {
            CustomSpinner(color: .white, lineWidth: 4, size: 40)
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
        }
        else {
            EmptyStateView(title: "No Match Data", systemImage: "calendar.badge.exclamationmark", description: "No matches found for \(sport.rawValue).")
                .frame(maxWidth: .infinity, minHeight: 300)
        }
    }
    
    private func soccerSectionsView(sections: [SoccerGameSection]) -> some View {
        ForEach(sections, id: \.league) { s in
            Section(header: leagueHeader(s.league)) {
                ForEach(s.games) { game in
                    scoreButton(game: game, sport: sport)
                }
            }
        }
    }
    
    private func leagueHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top)
    }
    
    private func scoreButton(game: ESPNEvent, sport: SportType) -> some View {
        GameScoreButton(
            game: game,
            sport: sport,
            viewModel: viewModel,
            scoreViewModel: scoreViewModel
        )
    }
}

/// Wraps a single game row + its long-press context menu.
///
/// Pulled out of `SportGamesListView` so SwiftUI can diff this subtree
/// independently. The previous inline version re-built its `.contextMenu`
/// every time the parent list re-evaluated (which happens on every score
/// fetch / live-game tick), which made the long-press popup visibly flash a
/// few times a second. Capturing the volatile toggle flags into `let`s here
/// and freezing the context-menu preview into a static snapshot via the
/// `.contextMenu(menuItems:preview:)` overload stops the rebuild churn.
private struct GameScoreButton: View {
    let game: ESPNEvent
    let sport: SportType
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    // Observed so a stopped/dismissed Live Activity re-renders the menu
    // label — reading the singleton directly left "Stop Live Activity"
    // stuck after the activity was already gone.
    @ObservedObject private var activityManager = GameActivityManager.shared

    var body: some View {
        // Captured once per body pass — read from the view model only once
        // rather than re-reading inside each Label closure (which would all
        // trigger fresh dependency tracking).
        let isPinned     = scoreViewModel.pinnedGameIDs.contains(game.id)
        let isScoreHidden = scoreViewModel.hiddenScoreGameIDs.contains(game.id)
        let isReminderSet = scoreViewModel.reminderGameIDs.contains(game.id)
        let (h, a) = game.searchTerms

        Button(action: {
            guard SwipeTapGuard.tapsAllowed else { return }
            ChannelViewModel.shared.triggerSelectionHaptic()
            // Stats-first: tapping a game opens the match detail sheet, and the
            // stream is one more tap from there. Racing gets its own card —
            // a weekend of sessions, not a fixture — rather than skipping
            // straight to the stream the way it used to.
            if sport == .f1 {
                scoreViewModel.presentRaceCard(game)
            } else if sport == .golf {
                scoreViewModel.presentGolfCard(game)
            } else {
                scoreViewModel.presentGameDetails(game, sport: sport)
            }
        }) {
            ScoreRow(game: game, sport: sport, isScoreHidden: isScoreHidden, isReminderSet: isReminderSet)
        }
        .buttonStyle(.plain)
        .contextMenu(menuItems: {
            Button {
                viewModel.runSmartSearch(gameID: game.id, home: h, away: a, sport: sport, network: game.streamNetworkHint)
            } label: {
                Label("Watch Stream", systemImage: "play.fill")
            }

            Button {
                viewModel.showStreamOptions(home: h, away: a, sport: sport, network: game.streamNetworkHint)
            } label: {
                Label("Stream List", systemImage: "list.bullet")
            }

            Button {
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

            if game.status.type.state == "pre" {
                Button {
                    scoreViewModel.toggleReminder(game)
                } label: {
                    Label(isReminderSet ? "Cancel Reminder" : "Remind Me",
                          systemImage: isReminderSet ? "bell.slash" : "bell")
                }
            } else if game.status.type.state == "in" {
                let isTracking = activityManager.trackedGameIDs.contains(game.id)
                Button {
                    activityManager.toggle(
                        game: game,
                        leagueName: game.leagueLabel ?? sport.rawValue,
                        sport: sport == .pinned ? scoreViewModel.sportType(for: game) : sport
                    )
                } label: {
                    Label(isTracking ? "Stop Live Activity" : "Live Activity",
                          systemImage: isTracking ? "bell.slash" : "bell.badge")
                }
            }

            if sport == .f1 {
                Button {
                    scoreViewModel.presentRaceCard(game)
                } label: {
                    Label("Race Card", systemImage: "flag.checkered")
                }
            } else if sport == .golf {
                Button {
                    scoreViewModel.presentGolfCard(game)
                } label: {
                    Label("Leaderboard", systemImage: "list.number")
                }
            } else {
                Button {
                    scoreViewModel.presentGameDetails(game, sport: sport)
                } label: {
                    Label("View Stats", systemImage: "chart.bar.fill")
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
        }, preview: {
            // Static preview — uses fixed game data captured at long-press
            // time. ScoreRow itself observes live game data, so reusing it
            // here would make the preview tick along with score changes and
            // flash a few times a second. A purpose-built static card avoids
            // that.
            GameContextPreview(game: game)
        })
    }
}

/// Frozen long-press preview for a game. Renders shortName, broadcast name,
/// and a stable status detail — no observed score state.
private struct GameContextPreview: View {
    let game: ESPNEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(game.shortName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            HStack(spacing: 8) {
                if let network = game.broadcastName, !network.isEmpty {
                    Text(network)
                        .font(.system(size: 11, weight: .black))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                let detail = game.scheduleAwareDetail.trimmingCharacters(in: .whitespaces)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}

/// Cross-sport "Live Now" overview — the first page of the Sports hub.
/// Layout:
///   • Big "Sports" title with LIVE / channels / events stats line
///   • Featured card highlighting the most prominent live event
///   • "Live Now" section: games grouped by sport — the sport name appears
///     once as a section header, then all games for that sport beneath it.
struct AllLiveSportsView: View {
    @ObservedObject var scoreViewModel: ScoreViewModel
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color

    /// Featured live game — a favorite team's live game wins; otherwise the
    /// first game in the live list (already sorted by recency). Returns nil
    /// when nothing is live so the featured card is hidden.
    private var featuredGame: ESPNEvent? {
        let favGames = scoreViewModel.favoriteLiveGames()
        if let fav = favGames.first { return fav }
        return scoreViewModel.allLiveGames.first
    }

    /// Games grouped by sport, preserving the order in which sports first
    /// appear in `allLiveGames`. Each sport header is shown exactly once.
    private func groups(from games: [ESPNEvent]) -> [LiveSportGroup] {
        var orderedSports: [SportType] = []
        var buckets: [SportType: [ESPNEvent]] = [:]
        for game in games {
            let sport = scoreViewModel.sportType(for: game)
            if buckets[sport] == nil {
                orderedSports.append(sport)
                buckets[sport] = []
            }
            buckets[sport]!.append(game)
        }
        return orderedSports.compactMap { sport in
            guard let games = buckets[sport], !games.isEmpty else { return nil }
            return LiveSportGroup(sport: sport,
                                  name: scoreViewModel.getSportName(sport),
                                  games: games)
        }
    }

    private var groupedLiveGames: [LiveSportGroup] { groups(from: scoreViewModel.allLiveGames) }

    /// The rest of the day either side of what is in play. Anything already
    /// listed as live is excluded so a game cannot appear twice — a race
    /// weekend reads as live off its sessions while its own status still says
    /// otherwise.
    private func todayGroups(state: String) -> [LiveSportGroup] {
        let live = Set(scoreViewModel.allLiveGames.map(\.id))
        return groups(from: scoreViewModel.allTodayGames.filter {
            !live.contains($0.id) && $0.status.type.state == state
        })
    }

    private var upcomingGroups: [LiveSportGroup] { todayGroups(state: "pre") }
    private var finishedGroups: [LiveSportGroup] { todayGroups(state: "post") }

    /// One titled block of games grouped by sport. Extracted so Live Now and
    /// the rest of the day are drawn by the same code rather than three copies
    /// of it; the count capsule's colour is the app's state convention — red in
    /// play, blue still to come, grey done.
    @ViewBuilder
    private func section(_ groups: [LiveSportGroup], title: String, tint: Color) -> some View {
        if !groups.isEmpty {
            let total = groups.reduce(0) { $0 + $1.games.count }
            HStack(spacing: 10) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Text("\(total)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(tint, in: Capsule())
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 6)

            // One VStack per sport — header shown once, games beneath.
            VStack(spacing: 20) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "trophy.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.tertiary)
                            Text(group.name.uppercased())
                                .font(.system(size: 10, weight: .black))
                                .kerning(0.6)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.leading, 4)

                        VStack(spacing: 10) {
                            ForEach(group.games) { game in
                                gameButton(game: game, sport: group.sport)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    // Content only — no ScrollView. SportsHubView provides the single
    // scroll so the title, pinned chips and games all share one page.
    var body: some View {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Featured live event card
                if let game = featuredGame {
                    featuredCard(game: game)
                        .padding(.horizontal)
                }

                // The day, in the order it happens: what is on now, what is
                // still to come, and what has already finished.
                let live = groupedLiveGames
                let upcoming = upcomingGroups
                let finished = finishedGroups

                section(live, title: "Live Now", tint: .red)
                section(upcoming, title: "Later Today", tint: .blue)
                section(finished, title: "Finished Today", tint: .gray)

                if live.isEmpty && upcoming.isEmpty && finished.isEmpty {
                    EmptyStateView(
                        title: "Nothing On Today",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: "No games are scheduled for today. Check back soon."
                    )
                    .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
                    .padding(.top, 60)
                }
            }
            .padding(.bottom, 120)
    }

    // MARK: - Data model

    private struct LiveSportGroup: Identifiable {
        let sport: SportType
        let name: String
        let games: [ESPNEvent]
        var id: String { sport.rawValue }
    }

    // MARK: - Featured card

    @ViewBuilder
    private func featuredCard(game: ESPNEvent) -> some View {
        let sport = scoreViewModel.sportType(for: game)
        let title = featuredTitle(for: game, sport: sport)
        let subtitle = featuredSubtitle(for: game, sport: sport)
        let description = featuredDescription(for: game)

        let hasLogos = game.homeCompetitor?.team?.logo != nil && game.awayCompetitor?.team?.logo != nil
        let footer = game.broadcastName.flatMap { $0.isEmpty ? nil : "\(subtitle) · on \($0)" } ?? subtitle

        Button(action: {
            guard SwipeTapGuard.tapsAllowed else { return }
            ChannelViewModel.shared.triggerSelectionHaptic()
            if sport == .f1 {
                playGame(game, sport: sport)
            } else {
                scoreViewModel.presentGameDetails(game, sport: sport)
            }
        }) {
            if hasLogos {
                MatchupHeroContent(
                    game: game,
                    footerIcon: "tv",
                    footerText: footer,
                    height: 220,
                    cornerRadius: 22
                )
            } else {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: [accentColor.opacity(0.55), Color.black.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Circle()
                        .fill(accentColor.opacity(0.45))
                        .frame(width: 220, height: 220)
                        .blur(radius: 70)
                        .offset(x: -40, y: -40)
                        .allowsHitTesting(false)

                    LinearGradient(
                        colors: [Color.black.opacity(0.05), Color.black.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 5) {
                            if game.status.type.state == "in" {
                                Circle().fill(.red).frame(width: 7, height: 7)
                                Text("LIVE")
                                    .font(.caption2.weight(.black))
                                    .kerning(1.4)
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 8, weight: .black))
                                Text("FEATURED")
                                    .font(.caption2.weight(.black))
                                    .kerning(1.4)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))

                        Spacer(minLength: 0)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(title)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Text(subtitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                            if !description.isEmpty {
                                Text(description)
                                    .font(.footnote)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(2)
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                    .font(.footnote.weight(.bold))
                                Text("Watch")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(.white, in: Capsule())
                            .padding(.top, 6)
                        }
                    }
                    .padding(20)
                }
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .drawingGroup()
                .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 8)
            }
        }
        .buttonStyle(.plain)
    }

    private func featuredTitle(for game: ESPNEvent, sport: SportType) -> String {
        // Prefer "Home vs Away"; fall back to shortName for races/MMA.
        let home = game.homeCompetitor?.team?.displayName
            ?? game.homeCompetitor?.team?.shortDisplayName
            ?? game.homeCompetitor?.athlete?.displayName
        let away = game.awayCompetitor?.team?.displayName
            ?? game.awayCompetitor?.team?.shortDisplayName
            ?? game.awayCompetitor?.athlete?.displayName
        if let h = home, let a = away, !h.isEmpty, !a.isEmpty {
            return "\(a) vs \(h)"
        }
        return game.shortName
    }

    private func featuredSubtitle(for game: ESPNEvent, sport: SportType) -> String {
        let league = scoreViewModel.getSportName(sport)
        if let label = game.leagueLabel, !label.isEmpty { return label }
        return league
    }

    private func featuredDescription(for game: ESPNEvent) -> String {
        var parts: [String] = []
        let detail = game.status.type.detail
        if !detail.isEmpty { parts.append(detail) }
        if let n = game.broadcastName, !n.isEmpty { parts.append("on \(n)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Game row (no sport header — header is in the group VStack above)

    @ViewBuilder
    private func gameButton(game: ESPNEvent, sport: SportType) -> some View {
        // Reuse the same self-contained button used by the per-sport tabs so
        // the long-press menu (with Record + stable preview) stays consistent
        // across both the Live overview and the individual sport scoreboards.
        GameScoreButton(
            game: game,
            sport: sport,
            viewModel: viewModel,
            scoreViewModel: scoreViewModel
        )
    }

    private func playGame(_ game: ESPNEvent, sport: SportType) {
        let (h, a) = game.searchTerms
        viewModel.runSmartSearch(gameID: game.id, home: h, away: a, sport: sport, network: game.streamNetworkHint)
    }
}

struct ManualSelectionSheet: View {
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color; let playAction: (StreamChannel) -> Void; @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List(viewModel.suggestedChannels) { channel in
                Button(action: { dismiss(); playAction(channel) }) {
                    HStack {
                        CachedAsyncImage(urlString: channel.icon ?? "", size: CGSize(width: 35, height: 35)).cornerRadius(8).clipped()
                        VStack(alignment: .leading) {
                            HStack(spacing: 6) {
                                Text(channel.name).font(.headline).foregroundStyle(.primary)
                                
                                let fullInfo = "\(channel.name) \(viewModel.getCurrentProgram(for: channel)?.title ?? "") \(viewModel.getCurrentProgram(for: channel)?.description ?? "")"
                                
                                let q = SmartSearchLogic.detectQuality(fullInfo, width: channel.width, height: channel.height)
                                if q != .unknown {
                                    Text(q.rawValue.components(separatedBy: " ").first ?? "SD")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.8))
                                        .cornerRadius(4)
                                }
                                
                                let lang = SmartSearchLogic.detectLanguage(fullInfo)
                                Text(lang?.rawValue.prefix(2).uppercased() ?? "??")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.8))
                                    .cornerRadius(4)
                            }
                            if let live = viewModel.getCurrentProgram(for: channel) {
                                Text(live.title).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer(); Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(accentColor)
                    }
                }
                .onAppear { viewModel.prewarmChannel(channel) }
            }.navigationTitle("Select Stream").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.medium])
    }
}

struct ScoreRow: View {
    let game: ESPNEvent; let sport: SportType; var isScoreHidden: Bool = false; var isReminderSet: Bool = false
    var body: some View { 
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if sport == .f1 {
                    raceLayout
                } else if sport == .golf {
                    golfLayout
                } else if sport == .tennis {
                    tennisLayout
                } else {
                    teamLayout
                }
            }
            .padding(.vertical, 18).padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(teamColorBackdrop)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1)) 
            
            if isReminderSet {
                Image(systemName: "bell.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 10, weight: .bold))
                    .padding(8)
            }
        }
    }
    
    /// Each club's colour bleeding in from ITS OWN side and meeting past the
    /// middle, the way the home screen's live-game cards read. Only for team
    /// sports: F1 and tennis have no two clubs to colour.
    @ViewBuilder
    private var teamColorBackdrop: some View {
        if sport == .f1 || sport == .tennis || sport == .golf {
            Color.black.opacity(0.4)
        } else {
            ZStack {
                Color.black.opacity(0.55)
                LinearGradient(
                    colors: [Self.teamColor(game.awayCompetitor).opacity(0.55),
                             Self.teamColor(game.awayCompetitor).opacity(0.0)],
                    startPoint: .leading,
                    endPoint: UnitPoint(x: 0.62, y: 0.5)
                )
                LinearGradient(
                    colors: [Self.teamColor(game.homeCompetitor).opacity(0.55),
                             Self.teamColor(game.homeCompetitor).opacity(0.0)],
                    startPoint: .trailing,
                    endPoint: UnitPoint(x: 0.38, y: 0.5)
                )
            }
        }
    }

    private static func teamColor(_ c: ESPNCompetitor?) -> Color {
        guard let hex = c?.team?.color, !hex.isEmpty,
              let col = Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)") else {
            return Color(white: 0.22)
        }
        return col
    }

    private var teamLayout: some View { HStack(alignment: .center, spacing: 4) { if let away = game.awayCompetitor { TeamColumn(competitor: away, gameState: game.status.type.state, align: .trailing, isScoreHidden: isScoreHidden).frame(maxWidth: .infinity) }; VStack(spacing: 6) { Text(game.scheduleAwareDetail.uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(game.status.type.state == "in" ? .red : .secondary).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8).frame(minWidth: 70, maxWidth: 100); if let cn = game.broadcastName { Text(cn).font(.system(size: 10, weight: .black)).foregroundStyle(.primary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.white.opacity(0.15)).cornerRadius(4) }; Capsule().fill(Color.white.opacity(0.1)).frame(width: 1.5, height: 20) }; if let home = game.homeCompetitor { TeamColumn(competitor: home, gameState: game.status.type.state, align: .leading, isScoreHidden: isScoreHidden).frame(maxWidth: .infinity) } } }
    
    
    /// Tennis scoreboard row: round + status header, then one line per
    /// player — flag, name, and the per-set linescores on the right (sets
    /// the player won render bold, the in-progress set stays live-white).
    private var tennisLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let round = game.tennisRound {
                    Text(round.uppercased())
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer()
                Text(tennisStatusText.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(game.status.type.state == "in" ? .red : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let cn = game.broadcastName {
                    Text(cn).font(.system(size: 10, weight: .black)).foregroundStyle(.primary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.white.opacity(0.15)).cornerRadius(4)
                }
            }
            VStack(spacing: 9) {
                tennisPlayerRow(game.awayCompetitor)
                tennisPlayerRow(game.homeCompetitor)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Scheduled matches show a compact local start time — ESPN's tennis
    /// pre-game detail is a full sentence ("Sat, July 11th at 8:30 AM EDT")
    /// that doesn't fit a row.
    private var tennisStatusText: String {
        guard game.status.type.state == "pre" else { return game.status.type.detail }
        // Matches without a scheduled time carry ESPN's unfilled template
        // ("M/d - 'TBD'") — formatting our parsed date would invent a time.
        if game.status.type.detail.contains("TBD") { return "TBD" }
        let date = game.gameDate
        guard date != .distantFuture else { return game.status.type.detail }
        let df = DateFormatter()
        df.dateFormat = "E h:mm a"
        return df.string(from: date)
    }

    @ViewBuilder
    private func tennisPlayerRow(_ competitor: ESPNCompetitor?) -> some View {
        if let competitor {
            let name = TennisFeed.sideName(competitor)
            let lost = game.status.type.state == "post" && competitor.winner != true
            let sets = competitor.linescores ?? []
            let pairFlags = (competitor.roster?.athletes ?? []).compactMap { $0.flag?.href }
            HStack(spacing: 8) {
                if pairFlags.count >= 2 {
                    // Doubles: both partners' flags, slightly smaller.
                    HStack(spacing: 3) {
                        ForEach(pairFlags.prefix(2), id: \.self) { flag in
                            CachedAsyncImage(urlString: flag, size: CGSize(width: 16, height: 16))
                                .frame(width: 16, height: 16)
                        }
                    }
                } else {
                    CachedAsyncImage(urlString: competitor.athlete?.flag?.href ?? pairFlags.first ?? "", size: CGSize(width: 22, height: 22))
                        .frame(width: 22, height: 22)
                }
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(lost ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if game.status.type.state == "in" && competitor.possession == true {
                    // Serving indicator — tennis-ball green.
                    Circle()
                        .fill(Color(red: 0.78, green: 0.92, blue: 0.25))
                        .frame(width: 7, height: 7)
                }
                if competitor.winner == true {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if game.status.type.state != "pre" && !sets.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(sets.indices, id: \.self) { i in
                            let wonSet = sets[i].winner == true
                            let isCurrentSet = game.status.type.state == "in" && i == sets.count - 1
                            tennisSetScore(sets[i], emphasized: wonSet || isCurrentSet)
                        }
                    }
                }
            }
        }
    }

    /// One set's game count, with the tiebreak score as a superscript
    /// ("7⁶") the way tennis scorelines are written.
    private func tennisSetScore(_ line: ESPNLinescore, emphasized: Bool) -> some View {
        HStack(alignment: .top, spacing: 1) {
            Text(isScoreHidden ? "?" : tennisSetText(line))
                .font(.system(size: 16, weight: emphasized ? .black : .semibold, design: .rounded))
            if !isScoreHidden, let tiebreak = line.tiebreak {
                Text("\(tiebreak)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.top, 1)
            }
        }
        .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .frame(minWidth: 12)
    }

    private func tennisSetText(_ line: ESPNLinescore) -> String {
        guard let value = line.value else { return "–" }
        return String(Int(value))
    }

    /// A race weekend, not a fixture. The old card was the event name plus the
    /// event's own status — which reads "Final" all Saturday because a practice
    /// session finished — and nothing else: no track, no session times, no
    /// result. This one leads with the session that matters right now and shows
    /// the podium of the last one that ran.
    private var raceLayout: some View {
        let session = game.currentRaceSession
        let finished = game.latestFinishedRaceSession
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.shortName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let circuit = game.circuit?.summary {
                        Text(circuit)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let cn = game.broadcastName {
                    Text(cn)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(3)
                }
            }

            if let session {
                HStack(spacing: 6) {
                    Text(Self.sessionName(session.label).uppercased())
                        .font(.system(size: 10, weight: .black))
                        .kerning(0.4)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                    Text(session.detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(session.state == "in" ? .red : .secondary)
                        .lineLimit(1)
                }
            }

            if let finished, session?.state != "in" || finished.label != session?.label {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(Self.sessionName(finished.label)) result")
                        .font(.system(size: 10, weight: .black))
                        .kerning(0.4)
                        .foregroundStyle(.white.opacity(0.4))
                    ForEach(Array(finished.order.prefix(3).enumerated()), id: \.offset) { index, driver in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(width: 12, alignment: .leading)
                            if let flag = driver.athlete?.flag?.href, !flag.isEmpty {
                                CachedAsyncImage(urlString: flag,
                                                 size: CGSize(width: 16, height: 16),
                                                 decodeSize: CGSize(width: 48, height: 48))
                                    .clipShape(RoundedRectangle(cornerRadius: 2))
                            }
                            Text(driver.athlete?.displayName ?? driver.athlete?.shortName ?? "—")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    /// A golf tournament: the event, where it's being played, the round, and
    /// the top of the leaderboard. The scoreboard hands over the whole 144-man
    /// field ordered by position, so the top three come free.
    private var golfLayout: some View {
        let leaders = (game.allCompetitions.first?.competitors ?? [])
            .sorted { ($0.order ?? 999) < ($1.order ?? 999) }
            .prefix(3)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.shortName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(game.status.type.detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(game.status.type.state == "in" ? .red : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let cn = game.broadcastName {
                    Text(cn)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(3)
                }
            }

            if !leaders.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(leaders.enumerated()), id: \.offset) { index, player in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(width: 12, alignment: .leading)
                            if let flag = player.athlete?.flag?.href, !flag.isEmpty {
                                CachedAsyncImage(urlString: flag,
                                                 size: CGSize(width: 16, height: 16),
                                                 decodeSize: CGSize(width: 48, height: 48))
                                    .clipShape(RoundedRectangle(cornerRadius: 2))
                            }
                            Text(player.athlete?.displayName ?? player.athlete?.shortName ?? "—")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(player.score ?? "–")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Self.golfParColor(player.score))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    /// Under par green, over par red — the same convention as the game card.
    static func golfParColor(_ total: String?) -> Color {
        guard let total, !total.isEmpty else { return .white }
        if total.hasPrefix("-") { return Color(red: 0.35, green: 0.85, blue: 0.45) }
        if total.hasPrefix("+") { return Color(red: 1.0, green: 0.45, blue: 0.42) }
        return .white
    }

    /// ESPN's session abbreviations spelled out.
    static func sessionName(_ abbreviation: String) -> String {
        switch abbreviation.lowercased() {
        case "fp1": return "Practice 1"
        case "fp2": return "Practice 2"
        case "fp3": return "Practice 3"
        case "qual", "q": return "Qualifying"
        case "sprint": return "Sprint"
        case "sq", "sprintqual": return "Sprint Qualifying"
        case "race": return "Race"
        default: return abbreviation
        }
    }
}

struct TeamColumn: View {
    let competitor: ESPNCompetitor; let gameState: String; let align: HorizontalAlignment; var isScoreHidden: Bool = false
    var body: some View { 
        let name = competitor.team?.shortDisplayName ?? competitor.team?.abbreviation ?? competitor.athlete?.shortName ?? competitor.athlete?.displayName ?? competitor.roster?.shortDisplayName ?? "Unknown"
        let logo = competitor.team?.logo ?? competitor.athlete?.flag?.href ?? competitor.athlete?.headshot ?? competitor.roster?.athletes?.first?.flag?.href ?? ""
        let score = isScoreHidden ? "?" : (gameState == "pre" ? "" : (competitor.score ?? "0"))
        
        return HStack(spacing: 8) { if align == .trailing { teamInfoStack(n: name, l: logo); scoreText(s: score) } else { scoreText(s: score); teamInfoStack(n: name, l: logo) } } 
    }
    private func teamInfoStack(n: String, l: String) -> some View { VStack(spacing: 4) { CachedAsyncImage(urlString: l, size: CGSize(width: 32, height: 32)).frame(width: 32, height: 32).padding(2); Text(n).font(.system(size: 13, weight: .bold)).foregroundStyle(.primary).multilineTextAlignment(.center).lineLimit(1).minimumScaleFactor(0.75) }.frame(maxWidth: .infinity) }
    private func scoreText(s: String) -> some View { Text(s).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.primary).lineLimit(1).fixedSize(horizontal: true, vertical: false).frame(minWidth: 40) }
}

struct SportSelectorView: View {
    @Binding var selectedSport: SportType
    let pinnedCount: Int
    let orderedSports: [SportType]
    @ObservedObject var scoreViewModel: ScoreViewModel
    /// When set, an "All" chip is rendered first. Tapping it sets `allMode = true`
    /// (and parents typically render a cross-sport Live overview); tapping any
    /// other chip clears it and falls back to the per-sport scoreboard.
    var allMode: Binding<Bool>? = nil
    let action: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if let allMode = allMode {
                        Button(action: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                allMode.wrappedValue = true
                            }
                        }) {
                            Text("All")
                                .font(.caption.bold())
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .backgroundTintedChip(isSelected: allMode.wrappedValue)
                                .clipShape(Capsule())
                        }
                        .id("__all__")
                    }
                    ForEach(orderedSports) { s in
                        Button(action: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                allMode?.wrappedValue = false
                                selectedSport = s
                            }
                            action()
                        }) {
                            Text(scoreViewModel.getSportName(s) + (s == .pinned ? " (\(pinnedCount))" : ""))
                                .font(.caption.bold())
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .backgroundTintedChip(isSelected: (allMode?.wrappedValue == false || allMode == nil) && selectedSport == s)
                                .clipShape(Capsule())
                        }
                        .id(s)
                    }
                }
                .padding(.horizontal)
                // Trimmed from 10. The chips keep their own pill padding, so
                // they are the same size; it is the gap around the row that
                // was making the pinned header taller than it needs to be.
                .padding(.vertical, 6)
            }
            // anchor nil = scroll the MINIMUM needed to bring the chip fully
            // into view, and not at all if it's already visible — centring
            // on every swipe dragged the whole row around unnecessarily.
            // Spring, not easeOut: consecutive swipes retarget a spring
            // mid-flight so the row glides to the new chip, where the old
            // quick easeOut restarted from zero and read as a jittery snap.
            .onChangeCompat(of: selectedSport) { ns in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                    proxy.scrollTo(ns, anchor: nil)
                }
            }
            .onChangeCompat(of: allMode?.wrappedValue ?? false) { isAll in
                guard isAll else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                    proxy.scrollTo("__all__", anchor: nil)
                }
            }
            // Opening the section: centre the active chip so the ones either
            // side of it are visible, rather than starting hard against the
            // leading edge. Centred here specifically — swipes keep `anchor:
            // nil` above, which scrolls the minimum needed and would otherwise
            // drag the whole row around on every change. Unanimated, since this
            // is the row's starting position rather than a move from one.
            .onAppear {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if allMode?.wrappedValue ?? false {
                        proxy.scrollTo("__all__", anchor: .center)
                    } else {
                        proxy.scrollTo(selectedSport, anchor: .center)
                    }
                }
            }
        }
    }
}
