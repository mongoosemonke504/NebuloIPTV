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
}

struct SportsHubView: View {
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color; let playAction: (StreamChannel) -> Void; var onBack: (() -> Void)? = nil
    @ObservedObject var scoreViewModel: ScoreViewModel
    var onOpenSearch: (() -> Void)? = nil
    @Environment(\.scenePhase) var scenePhase
    @State private var isRefreshingAnimation = false
    /// Header stat counts — refreshed whenever the live game set changes.
    @State private var todaysEventCount: Int = 0
    @State private var liveChannelCount: Int = 0

    /// Current tab — `.all` is the default "Live Now" overview.
    /// Driving a single TabView with `.page` style lets the user swipe
    /// directly between "All" and any individual sport without tapping chips.
    @State private var sportsTab: SportsTab = .all

    /// 0 at rest, 1 once the big title has scrolled away. Tracked 1:1 with
    /// the scroll offset (no canned animation) — drives the title fade and
    /// the compact line growing into the pinned chip bar. Held in its own
    /// object (observed only by the fading title + gradient) so scrolling the
    /// scoreboard doesn't re-render this whole hub every frame.
    @State private var statsProgress = ScrollProgress()

    private var orderedSports: [SportType] {
        scoreViewModel.sportTabOrder.filter { !scoreViewModel.hiddenSportTabs.contains($0) }
    }

    /// Which side the incoming games list enters from. `true` when moving to
    /// a chip further right ("All" → NFL → …), so content slides in from the
    /// trailing edge like a page turn. Set BEFORE the animated tab change so
    /// the transition reads the correct direction.
    @State private var slideFromTrailing = true

    /// Chips in visual order — "All" first, then each sport.
    private var orderedTabs: [SportsTab] {
        [.all] + orderedSports.map { SportsTab.sport($0) }
    }

    /// True while a slide transition is in flight. Tab changes are ignored
    /// during this window: interrupting a `.move` transition mid-animation
    /// can leave the incoming view stuck offscreen (a fully blank section)
    /// — rapid swipes must wait ~0.3s for the previous slide to settle.
    @State private var isSliding = false

    /// Central tab switch: derives the slide direction from chip order and
    /// swaps with a flat easeOut — deliberately no spring, no bounce.
    private func selectTab(_ newTab: SportsTab) {
        guard newTab != sportsTab, !isSliding else { return }
        let tabs = orderedTabs
        let oldIdx = tabs.firstIndex(of: sportsTab) ?? 0
        let newIdx = tabs.firstIndex(of: newTab) ?? 0
        slideFromTrailing = newIdx > oldIdx
        isSliding = true
        withAnimation(.easeOut(duration: 0.25)) { sportsTab = newTab }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isSliding = false
        }
    }

    /// Steps to the previous/next chip. Driven by the horizontal swipe.
    private func advanceSportsTab(_ delta: Int) {
        let tabs = orderedTabs
        guard let idx = tabs.firstIndex(of: sportsTab) else { return }
        let next = idx + delta
        guard tabs.indices.contains(next) else { return }
        ChannelViewModel.shared.triggerSelectionHaptic()
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
                            // Opaque backdrop so a tab slide cleanly covers the
                            // outgoing tab instead of the two sets of crests
                            // ghosting through each other. It must be ALWAYS on
                            // (not just while sliding): the outgoing tab is a
                            // stale snapshot during removal and won't re-render
                            // with a fresh flag, so gating on `isSliding` left
                            // whichever tab renders on top able to show through.
                            // The fill matches the dark backdrop so the games
                            // look unchanged at rest. Paired with a pure `.move`
                            // (no opacity) — a fade would re-introduce see-through.
                            .background(Color(red: 0.05, green: 0.055, blue: 0.08))
                            .transition(.asymmetric(
                                insertion: .move(edge: slideFromTrailing ? .trailing : .leading),
                                removal: .move(edge: slideFromTrailing ? .leading : .trailing)
                            ))
                        }
                        .padding(.top, 10)
                    }
                }
            }
            .coordinateSpace(name: "sportsScroll")
            .onPreferenceChange(SectionScrollOffsetsKey.self) { offsets in
                guard let y = offsets["sports"] else { return }
                statsProgress.set(min(max(-y / 40, 0), 1))
            }
            // Horizontal swipe anywhere on the list flips to the previous /
            // next sport, replacing the paged TabView's swipe. Simultaneous
            // so vertical scrolling is unaffected; only clearly-horizontal
            // drags count, and swipes starting at the left edge stay
            // reserved for back navigation.
            .simultaneousGesture(
                DragGesture(minimumDistance: 25)
                    .onChanged { value in
                        // As soon as the drag reads as horizontal, open the
                        // tap-suppression window so the game row under the
                        // finger doesn't ALSO fire on release.
                        if abs(value.translation.width) > abs(value.translation.height) * 1.5 {
                            SwipeTapGuard.suppress()
                        }
                    }
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard value.startLocation.x > 44,
                              abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                        advanceSportsTab(dx < 0 ? 1 : -1)
                    }
            )
            // Sync selectedSport when the chip selection changes so the
            // existing fetch/pre-resolution observers fire correctly.
            .onChangeCompat(of: sportsTab) { tab in
                if case .sport(let s) = tab {
                    if s != scoreViewModel.selectedSport {
                        scoreViewModel.selectedSport = s
                    }
                    // Warm this sport's crests at high priority so the tab's
                    // logos are present as fast as possible on a cold cache.
                    scoreViewModel.prefetchLogos(for: s)
                }
            }

            if viewModel.isSearchingGame {
                loadingOverlay
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
            triggerPreResolution()
            recomputeStats()
            // Proactively warm the soccer-leagues crests (the busiest tab —
            // many league sections of logos) so they're cached before the
            // user swipes there, instead of streaming in on arrival.
            scoreViewModel.prefetchLogos(for: .soccerLeagues)
        }
        // Recompute header stats whenever the live game set changes.
        .task(id: scoreViewModel.allLiveGameIDsKey) {
            recomputeStats()
        }
        .onAppear {
            if scoreViewModel.isLoading {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isRefreshingAnimation = true
                }
            }
        }
        .onChangeCompat(of: scoreViewModel.isLoading) { loading in
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
            if phase == .active {
                Task { 
                    await scoreViewModel.fetchScores(forceRefresh: true, silent: true)
                    triggerPreResolution()
                }
            }
        }
        .onChangeCompat(of: scoreViewModel.selectedSport) { _ in
            // `_ =` keeps this a Void statement — as the closure's lone
            // expression, the Task would be its implicit return value and
            // Swift 6.2's named-Task initializer overloads become ambiguous.
            _ = Task {
                await scoreViewModel.fetchScores()
                triggerPreResolution()
            }
        }
        .onChangeCompat(of: viewModel.searchText) { text in 
            scoreViewModel.applyFilter(text: text)
            triggerPreResolution()
        }
        .sheet(isPresented: $viewModel.showSelectionSheet) { ManualSelectionSheet(viewModel: viewModel, accentColor: accentColor, playAction: playAction) }
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
                    selectTab(.sport(newSport))
                    scoreViewModel.selectedSport = newSport
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
        .padding(.vertical, 4)
        // Home-style dark gradient. As part of the pinned header it renders
        // ABOVE the scrolling games (dimming them as they pass under) but
        // BEHIND the chips themselves, which stay at full contrast. The tall
        // frame + upward offset stretch it past the top of the screen — the
        // scroll's clip extends under the chrome row and status bar, so the
        // gradient reaches the true screen top and no edge can form; below,
        // it fades to clear well past the chips.
        .background(alignment: .top) {
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.3), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 250)
            .offset(y: -130)
            .scrollProgressOpacity(statsProgress) { Double($0 * $0) }
            .allowsHitTesting(false)
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
                    .font(.system(size: 34, weight: .bold))
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
        for games in scoreViewModel.filteredGames.values {
            for g in games where cal.isDateInToday(g.gameDate) {
                todaysIDs.insert(g.id)
            }
        }
        for sections in scoreViewModel.filteredSectionsMap.values {
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
    
    private var loadingOverlay: some View {
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
        .zIndex(100)
    }
}

struct SportGamesListView: View {
    let sport: SportType
    @ObservedObject var scoreViewModel: ScoreViewModel
    @ObservedObject var viewModel: ChannelViewModel
    
    // Content only — no ScrollView. SportsHubView provides the single
    // scroll so the title, pinned chips and games all share one page.
    var body: some View {
            LazyVStack(spacing: 12) {
                if sport == .pinned {
                    if scoreViewModel.allPinnedGames.isEmpty {
                        EmptyStateView(title: "No Pinned Games", systemImage: "pin.slash", description: "Pin games to see them here.").frame(height: 300)
                    } else {
                        ForEach(scoreViewModel.allPinnedGames) { game in
                            scoreButton(game: game, sport: .nfl)
                        }
                    }
                } else if isSoccerCategory(sport) {
                    if let sections = scoreViewModel.filteredSectionsMap[sport], !sections.isEmpty {
                        
                        let allSoccerGames = sections.flatMap { $0.games }
                        let pinnedSoccer = allSoccerGames.filter { scoreViewModel.pinnedGameIDs.contains($0.id) }
                        
                        if !pinnedSoccer.isEmpty {
                            Section(header: subCategoryHeader("Pinned")) {
                                ForEach(pinnedSoccer) { game in
                                    scoreButton(game: game, sport: .soccerLeagues)
                                }
                            }
                        }
                        
                        ForEach(sections, id: \.league) { s in
                            let remainingGames = s.games.filter { !scoreViewModel.pinnedGameIDs.contains($0.id) }
                            if !remainingGames.isEmpty {
                                Section(header: leagueHeader(s.league)) {
                                    ForEach(remainingGames) { game in
                                        scoreButton(game: game, sport: .soccerLeagues) 
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
                                ForEach(unpinned) { game in
                                    scoreButton(game: game, sport: sport)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 120)
    }

    private func subCategoryHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
    
    private func isSoccerCategory(_ sport: SportType) -> Bool {
        return sport == .soccerLeagues || sport == .domesticCups || sport == .continental || sport == .international
    }
    
    @ViewBuilder
    private var emptyState: some View {
        if scoreViewModel.isLoading {
            CustomSpinner(color: .white, lineWidth: 4, size: 40).padding(.top, 100)
        }
        else {
            EmptyStateView(title: "No Match Data", systemImage: "calendar.badge.exclamationmark", description: "No matches found for \(sport.rawValue).").frame(height: 300)
        }
    }
    
    private func soccerSectionsView(sections: [SoccerGameSection]) -> some View {
        ForEach(sections, id: \.league) { s in
            Section(header: leagueHeader(s.league)) {
                ForEach(s.games) { game in
                    scoreButton(game: game, sport: .soccerLeagues) 
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

    var body: some View {
        // Captured once per body pass — read from the view model only once
        // rather than re-reading inside each Label closure (which would all
        // trigger fresh dependency tracking).
        let isPinned     = scoreViewModel.pinnedGameIDs.contains(game.id)
        let isScoreHidden = scoreViewModel.hiddenScoreGameIDs.contains(game.id)
        let isReminderSet = scoreViewModel.reminderGameIDs.contains(game.id)
        let h = game.homeCompetitor?.team?.shortDisplayName ?? game.homeCompetitor?.athlete?.shortName ?? ""
        let a = game.awayCompetitor?.team?.shortDisplayName ?? game.awayCompetitor?.athlete?.shortName ?? ""

        Button(action: {
            guard SwipeTapGuard.tapsAllowed else { return }
            ChannelViewModel.shared.triggerSelectionHaptic()
            viewModel.runSmartSearch(gameID: game.id, home: h, away: a, sport: sport, network: game.broadcastName)
        }) {
            ScoreRow(game: game, sport: sport, isScoreHidden: isScoreHidden, isReminderSet: isReminderSet)
        }
        .buttonStyle(.plain)
        .contextMenu(menuItems: {
            Button {
                viewModel.showStreamOptions(home: h, away: a, sport: sport, network: game.broadcastName)
            } label: {
                Label("Stream List", systemImage: "list.bullet")
            }

            Button {
                viewModel.autoAddGameToMultiView(home: h, away: a, network: game.broadcastName)
            } label: {
                Label("Add to Multi-View", systemImage: "square.grid.2x2")
            }

            Button {
                let query = "\(game.shortName) highlights"
                if let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let url = URL(string: "https://www.youtube.com/results?search_query=\(encoded)") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Find Highlights", systemImage: "play.rectangle.fill")
            }

            Button {
                viewModel.toggleGameRecording(game: game, sport: sport)
            } label: {
                let isScheduled = viewModel.scheduledRecording(for: game) != nil
                Label(isScheduled ? "Cancel Recording" : "Record",
                      systemImage: isScheduled ? "stop.circle" : "record.circle")
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
                let detail = game.status.type.detail.trimmingCharacters(in: .whitespaces)
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
    private var groupedLiveGames: [LiveSportGroup] {
        var orderedSports: [SportType] = []
        var buckets: [SportType: [ESPNEvent]] = [:]
        for game in scoreViewModel.allLiveGames {
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

    // Content only — no ScrollView. SportsHubView provides the single
    // scroll so the title, pinned chips and games all share one page.
    var body: some View {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Featured live event card
                if let game = featuredGame {
                    featuredCard(game: game)
                        .padding(.horizontal)
                }

                // Live Now section header + grouped list
                let groups = groupedLiveGames
                if !groups.isEmpty {
                    let totalLive = groups.reduce(0) { $0 + $1.games.count }
                    HStack(spacing: 10) {
                        Text("Live Now")
                            .font(.title2.bold())
                            .foregroundStyle(.primary)
                        Text("\(totalLive)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Color.red, in: Capsule())
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 6)

                    // One VStack per sport — header shown once, games beneath.
                    VStack(spacing: 20) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                // Sport section header — shown once per sport
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

                                // All games for this sport
                                VStack(spacing: 10) {
                                    ForEach(group.games) { game in
                                        gameButton(game: game, sport: group.sport)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                } else {
                    EmptyStateView(
                        title: "No Live Events",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: "There aren't any live games right now. Check back soon."
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

        Button(action: {
            guard SwipeTapGuard.tapsAllowed else { return }
            ChannelViewModel.shared.triggerSelectionHaptic()
            playGame(game, sport: sport)
        }) {
            ZStack(alignment: .bottomLeading) {
                // Glow gradient — accent at top-left fading to black bottom-right.
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
                        Image(systemName: "play.fill")
                            .font(.system(size: 8, weight: .black))
                        Text("FEATURED")
                            .font(.caption2.weight(.black))
                            .kerning(1.4)
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
            .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 8)
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
        let h = game.homeCompetitor?.team?.shortDisplayName ?? game.homeCompetitor?.athlete?.shortName ?? ""
        let a = game.awayCompetitor?.team?.shortDisplayName ?? game.awayCompetitor?.athlete?.shortName ?? ""
        viewModel.runSmartSearch(gameID: game.id, home: h, away: a, sport: sport, network: game.broadcastName)
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
                } else { 
                    teamLayout 
                } 
            }
            .padding(.vertical, 18).padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1)) 
            
            if isReminderSet {
                Image(systemName: "bell.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 10, weight: .bold))
                    .padding(8)
            }
        }
    }
    
    private var teamLayout: some View { HStack(alignment: .center, spacing: 4) { if let away = game.awayCompetitor { TeamColumn(competitor: away, gameState: game.status.type.state, align: .trailing, isScoreHidden: isScoreHidden).frame(maxWidth: .infinity) }; VStack(spacing: 6) { Text(game.status.type.detail.uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(game.status.type.state == "in" ? .red : .secondary).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8).frame(minWidth: 70, maxWidth: 100); if let cn = game.broadcastName { Text(cn).font(.system(size: 10, weight: .black)).foregroundStyle(.primary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.white.opacity(0.15)).cornerRadius(4) }; Capsule().fill(Color.white.opacity(0.1)).frame(width: 1.5, height: 20) }; if let home = game.homeCompetitor { TeamColumn(competitor: home, gameState: game.status.type.state, align: .leading, isScoreHidden: isScoreHidden).frame(maxWidth: .infinity) } } }
    
    
    private var raceLayout: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(game.shortName).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                HStack(spacing: 8) {
                    Text(game.status.type.detail).font(.system(size: 13)).foregroundStyle(game.status.type.state == "in" ? .red : .secondary)
                    if let cn = game.broadcastName {
                        Text(cn).font(.system(size: 10, weight: .black)).foregroundStyle(.primary).padding(.horizontal, 5).padding(.vertical, 1).background(Color.white.opacity(0.15)).cornerRadius(3)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

struct TeamColumn: View {
    let competitor: ESPNCompetitor; let gameState: String; let align: HorizontalAlignment; var isScoreHidden: Bool = false
    var body: some View { 
        let name = competitor.team?.shortDisplayName ?? competitor.team?.abbreviation ?? competitor.athlete?.shortName ?? competitor.athlete?.displayName ?? "Unknown"
        let logo = competitor.team?.logo ?? competitor.athlete?.flag?.href ?? competitor.athlete?.headshot ?? ""
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

    /// Opaque unselected-chip fill — content scrolling behind the pinned
    /// chips must not show through them. Shared tone across all chip rows.
    static let chipFill = Color(red: 0.13, green: 0.15, blue: 0.20)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if let allMode = allMode {
                        Button(action: {
                            ChannelViewModel.shared.triggerSelectionHaptic()
                            withAnimation(.easeOut(duration: 0.2)) {
                                allMode.wrappedValue = true
                            }
                        }) {
                            Text("All")
                                .font(.caption.bold())
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .background(allMode.wrappedValue ? Color.white : Self.chipFill)
                                .foregroundColor(allMode.wrappedValue ? .black : .white)
                                .clipShape(Capsule())
                        }
                        .id("__all__")
                    }
                    ForEach(orderedSports) { s in
                        Button(action: {
                            ChannelViewModel.shared.triggerSelectionHaptic()
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
                                .background((allMode?.wrappedValue == false || allMode == nil) && selectedSport == s ? Color.white : Self.chipFill)
                                .foregroundColor((allMode?.wrappedValue == false || allMode == nil) && selectedSport == s ? .black : .white)
                                .clipShape(Capsule())
                        }
                        .id(s)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .onAppear { proxy.scrollTo(selectedSport, anchor: .center) }
            .onChangeCompat(of: selectedSport) { ns in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(ns, anchor: .center) }
            }
        }
    }
}
