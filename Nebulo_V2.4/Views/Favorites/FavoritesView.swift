import SwiftUI
import Combine

// MARK: - Filter pills

enum FavoritesFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case channels = "Channels"
    case teams = "Teams"
    case reminders = "Reminders"
    var id: String { rawValue }
}

// MARK: - Favorites screen

/// Hub for the user's favorited channels, teams, leagues, and game reminders.
/// Matches the visual language of `MultiViewScreen`'s hub: liquid-glass
/// back/settings buttons up top, a big title row, scrolling content, and a
/// pinned search pill at the bottom.
struct FavoritesView: View {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    let accentColor: Color
    let playAction: (StreamChannel) -> Void
    /// Channel tapped in the Channels list — shows the preview popup rather
    /// than starting playback outright.
    @State private var previewChannel: StreamChannel?
    let onBack: () -> Void
    /// Hook for the main app's full-screen search overlay. Falls back to the
    /// local AddFavoriteSheet if the host can't surface the main search (e.g.
    /// the iPad sidebar layout).
    var onOpenSearch: (() -> Void)? = nil


    @State private var filter: FavoritesFilter = .all
    @State private var showAddSheet = false
    @State private var showReorderChannels = false
    @State private var showSeeAllTeams = false
    @State private var showSearchSheet = false
    /// Identifies the team row that should present its detail sheet. Using an
    /// optional struct (rather than a Bool + ID combo) means the sheet
    /// presents/dismisses purely from this binding — no race conditions.
    /// Set the instant a drag reads as horizontal, which disables the page's
    /// vertical scroll for the rest of that gesture. A leaf box, so flipping it
    /// re-renders the scroll modifier alone.
    @State private var scrollLock = FlagBox()

    @State private var detailTeam: TeamDetailSelection? = nil
    @State private var detailLeague: LeagueDetailSelection? = nil
    /// 0 at rest, 1 once the big title has scrolled away. Tracked 1:1 with
    /// the scroll offset (no canned animation) — drives the title fade and
    /// the compact line growing into the pinned pill bar. Held in its own
    /// object (observed only by the fading title + gradient) so scrolling
    /// doesn't re-render this whole screen's content every frame.
    @State private var titleProgress = ScrollProgress()

    /// Lightweight envelope used to drive the team page on team taps. Carries
    /// the team plus its league context (needed to look up the right logo).
    struct TeamDetailSelection: Identifiable {
        let team: ESPNTeam
        let leagueLabel: String?
        var sport: SportType? = nil
        var id: String { ScoreViewModel.teamKey(sport: sport, teamID: team.id) }
    }

    /// Drives the league page on league taps. Carries the sport + league
    /// label so the page can pull the right table and fixtures.
    struct LeagueDetailSelection: Identifiable {
        let sport: SportType
        let leagueLabel: String?
        let displayName: String
        var id: String { "\(sport.rawValue)|\(leagueLabel ?? "*")" }
    }

    /// Which side the incoming content enters from. `true` when moving to a
    /// pill further right, so content slides in from the trailing edge like
    /// a page turn. Set BEFORE the animated change so the transition reads
    /// the correct direction.
    @State private var slideFromTrailing = true

    /// True while a slide transition is in flight. Filter changes are
    /// ignored during this window: interrupting a `.move` transition
    /// mid-animation can leave the incoming view stuck offscreen (a fully
    /// blank section) — rapid swipes must wait ~0.3s for the previous
    /// slide to settle.
    @State private var isSliding = false

    /// Central filter switch: derives the slide direction from pill order
    /// and swaps with a flat easeOut — no spring, no bounce.
    private func selectFilter(_ newFilter: FavoritesFilter) {
        guard newFilter != filter, !isSliding else { return }
        let all = FavoritesFilter.allCases
        let oldIdx = all.firstIndex(of: filter) ?? 0
        let newIdx = all.firstIndex(of: newFilter) ?? 0
        slideFromTrailing = newIdx > oldIdx
        isSliding = true
        withAnimation(.easeOut(duration: 0.25)) { filter = newFilter }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isSliding = false
        }
    }

    /// One filter switch per drag — set mid-drag when the swipe fires,
    /// cleared on finger-lift.
    @State private var swipeConsumed = false
    /// Global frame of the reminders List. Horizontal swipes that begin inside
    /// it are left to the List's own row swipe-to-remove, so the filter pager
    /// doesn't steal them and flip to the next chip.
    @State private var reminderListFrame: CGRect = .zero

    /// Steps to the previous/next filter pill. Driven by the horizontal swipe.
    /// No haptic — swipes stay silent; haptics belong to deliberate taps.
    private func advanceFilter(_ delta: Int) {
        let all = FavoritesFilter.allCases
        guard let idx = all.firstIndex(of: filter) else { return }
        let next = idx + delta
        guard all.indices.contains(next) else { return }
        selectFilter(all[next])
    }

    private var favoriteChannels: [StreamChannel] { viewModel.orderedFavoriteChannels() }
    private var favoriteTeams: [(team: ESPNTeam, sport: SportType?, leagueLabel: String?)] {
        scoreViewModel.resolvedFavoriteTeams()
    }
    private var favoriteLeagues: [(sport: SportType, leagueLabel: String?, displayName: String)] {
        scoreViewModel.resolvedFavoriteLeagues()
    }
    private var reminderGames: [ESPNEvent] {
        var pool: [ESPNEvent] = []
        for games in scoreViewModel.filteredGames.values { pool.append(contentsOf: games) }
        for sections in scoreViewModel.filteredSectionsMap.values {
            for section in sections { pool.append(contentsOf: section.games) }
        }
        var seen = Set<String>()
        var out: [ESPNEvent] = []
        for game in pool where scoreViewModel.reminderGameIDs.contains(game.id) {
            if seen.insert(game.id).inserted { out.append(game) }
        }
        return out.sorted { $0.gameDate < $1.gameDate }
    }

    var body: some View {
        ZStack(alignment: .top) {
            AppBackground()

            // One scroll for the whole screen, exactly like Recordings: the
            // big "Favorites" title is scroll content and physically scrolls
            // away with the content. The filter pills ride in a PINNED
            // section header — they scroll as part of the page but stick at
            // the top once they reach it, so they're always available. As
            // the big title leaves, a compact "Favorites" line grows into
            // the pinned bar above the pills.
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    titleRow
                        .scrollProgressOpacity(titleProgress) { 1 - Double($0) }
                        .background(ScrollOffsetProbe(space: "favScroll", id: "fav"))

                    Section(header: pinnedPillHeader) {
                        // ZStack so the outgoing and incoming content overlap
                        // during the directional slide instead of stacking
                        // vertically. `.id(filter)` gives each page distinct
                        // identity so the transition fires.
                        ZStack(alignment: .top) {
                            filterContent
                                .id(filter)
                                .transition(.asymmetric(
                                    insertion: .move(edge: slideFromTrailing ? .trailing : .leading).combined(with: .opacity),
                                    removal: .move(edge: slideFromTrailing ? .leading : .trailing).combined(with: .opacity)
                                ))
                        }
                    }
                }
            }
            .coordinateSpace(name: "favScroll")
            // Frozen for the duration of a horizontal swipe, so a sideways
            // gesture travels purely sideways — same as the Sports hub.
            .scrollLocked(scrollLock)
            .onPreferenceChange(SectionScrollOffsetsKey.self) { offsets in
                guard let y = offsets["fav"] else { return }
                titleProgress.set(min(max(-y / 40, 0), 1))
            }
            // Horizontal swipe flips to the previous/next filter, matching
            // the Sports hub. Fires mid-drag the moment the swipe reads as
            // horizontal so the switch tracks the gesture instead of waiting
            // for finger-lift. Left-edge swipes stay reserved for back.
            .simultaneousGesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .onChanged { value in
                        // A swipe that starts on a reminder row belongs to that
                        // row's swipe-to-remove — don't page the filter.
                        if reminderListFrame.contains(value.startLocation) { return }
                        let dx = value.translation.width
                        let dy = value.translation.height
                        // As soon as the drag reads as horizontal, open the
                        // tap-suppression window so the row under the finger
                        // doesn't ALSO fire on release.
                        if abs(dx) > abs(dy) * 1.4 {
                            SwipeTapGuard.suppress()
                        }
                        // ...and freeze the vertical scroll, so a sideways
                        // swipe doesn't also drag the page up or down. A drag
                        // that turns decisively vertical before the filter
                        // flips releases it again, so this can never strand
                        // the page unscrollable.
                        if value.startLocation.x > 44 {
                            if abs(dx) > abs(dy) * 1.4 {
                                scrollLock.set(true)
                            } else if !swipeConsumed, abs(dy) > abs(dx) * 1.4 {
                                scrollLock.set(false)
                            }
                        }
                        // Low threshold + mid-drag firing: the swipe is
                        // recognised almost as soon as the finger commits to
                        // a horizontal motion.
                        guard !swipeConsumed,
                              value.startLocation.x > 44,
                              abs(dx) > 20, abs(dx) > abs(dy) * 1.4 else { return }
                        swipeConsumed = true
                        advanceFilter(dx < 0 ? 1 : -1)
                    }
                    .onEnded { _ in
                        swipeConsumed = false
                        scrollLock.set(false)
                    }
            )
        }
        // NOTE: no local bottom search pill here — MainViewModifiers already
        // pins the app-wide search bar to the bottom of every screen, and
        // rendering FavoritesSearchPill as well produced two stacked bars.
        // Same toolbar treatment as RecordingsView: hidden nav-bar background,
        // empty inline title, plain chevron+"Back" on the leading edge in
        // white. The trailing settings gear is supplied by MainViewModifiers
        // at the parent level, exactly like the Recordings screen.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .sheet(item: $previewChannel) { channel in
            ChannelPreviewSheet(
                channel: channel,
                viewModel: viewModel,
                accentColor: accentColor,
                playAction: { playAction($0) }
            )
        }
        .sheet(isPresented: $showAddSheet) {
            AddFavoriteSheet(viewModel: viewModel, scoreViewModel: scoreViewModel)
        }
        .sheet(isPresented: $showReorderChannels) {
            ReorderFavoriteChannelsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showSeeAllTeams) {
            FavoritesAllTeamsView(
                viewModel: viewModel,
                scoreViewModel: scoreViewModel,
                accentColor: accentColor
            )
        }
        .sheet(isPresented: $showSearchSheet) {
            AddFavoriteSheet(viewModel: viewModel, scoreViewModel: scoreViewModel)
        }
        // The same pages the home screen's Favorites shelf opens — a tap on a
        // team here and a tap on the same team there now land in exactly one
        // place. Previously this presented a games-only sheet while home
        // presented the full page.
        .fullScreenCover(item: $detailTeam) { selection in
            // An F1 favourite is a driver, and ESPN's team endpoints 404 for
            // racing, so the team page came up blank. Drivers get their own.
            if selection.sport == .f1 {
                DriverDetailPage(
                    driver: selection.team,
                    viewModel: viewModel,
                    scoreViewModel: scoreViewModel,
                    playAction: playAction
                )
            } else {
                TeamDetailPage(
                    team: selection.team,
                    leagueLabel: selection.leagueLabel,
                    sport: selection.sport,
                    viewModel: viewModel,
                    scoreViewModel: scoreViewModel
                )
            }
        }
        .fullScreenCover(item: $detailLeague) { selection in
            LeagueDetailPage(
                sport: selection.sport,
                leagueLabel: selection.leagueLabel,
                displayName: selection.displayName,
                viewModel: viewModel,
                scoreViewModel: scoreViewModel
            )
        }
    }

    // MARK: Title row (matches RecordingsView's headerView)

    @ViewBuilder private var titleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Favorites")
                .font(NuvioTheme.pageTitleFont)
                .foregroundStyle(.white)
            Text(headerSubtitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var headerSubtitle: String {
        let c = favoriteChannels.count
        let t = favoriteTeams.count + favoriteLeagues.count
        return "\(c) channel\(c == 1 ? "" : "s") · \(t) team\(t == 1 ? "" : "s")"
    }

    // MARK: TabView pages

    /// Wraps a page's content in a ScrollView that reports its OWN scroll
    /// Sticky section header: just the filter pills (the compact title lives
    /// in StandardLayout's chrome row, level with Back/gear). Fixed height,
    /// NO background scrim — the pills are self-contained glass elements,
    /// and any backing gradient drew a visible edge below the chrome row
    /// that read as a second border. Content scrolls behind the pills, same
    /// as the app-wide bottom search bar.
    private var pinnedPillHeader: some View {
        // Custom binding routes pill taps through selectFilter so tapping a
        // pill slides the content the same direction a swipe would.
        FavoritesFilterPills(selected: Binding(
            get: { filter },
            set: { selectFilter($0) }
        ))
            .padding(.vertical, 4)
            // Home-style dark gradient. As part of the pinned header it
            // renders ABOVE the scrolling content (dimming it as it passes
            // under) but BEHIND the pills, which stay at full contrast. The
            // tall frame + upward offset stretch it past the screen top so
            // no edge can form; below, it fades to clear past the pills.
            .background(alignment: .top) {
                CompactHeaderScrim(height: 265, fadeStart: 0.4)
                    .offset(y: -130)
                    .scrollProgressOpacity(titleProgress) { Double($0 * $0) }
            }
    }

    /// Content for the selected filter, shown below the pinned pills in the
    /// shared scroll. Tapping a pill swaps this in place.
    @ViewBuilder private var filterContent: some View {
        switch filter {
        case .all:       allPageContent
        case .channels:  channelsPageContent
        case .teams:     teamsPageContent
        case .reminders: remindersPageContent
        }
    }

    /// Tabs share a baseline of top inset + floating-dock clearance.
    private var pageVerticalPadding: some View {
        Color.clear.frame(height: 122)
    }

    @ViewBuilder private var allPageContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            channelsSection
            teamsSection
            if !reminderGames.isEmpty { remindersSection }
            if favoriteChannels.isEmpty && favoriteTeams.isEmpty && favoriteLeagues.isEmpty && reminderGames.isEmpty {
                emptyState.padding(.top, 60)
            }
            pageVerticalPadding
        }
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var channelsPageContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            channelsSection
            pageVerticalPadding
        }
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var teamsPageContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            teamsSection
            pageVerticalPadding
        }
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var remindersPageContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            if reminderGames.isEmpty {
                FavoritesEmptyTile(
                    icon: "bell.fill",
                    title: "No reminders set",
                    subtitle: "Set a reminder on a game from the Sports section."
                )
                .padding(.horizontal, 20)
            } else {
                remindersSection
            }
            pageVerticalPadding
        }
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    // MARK: Channels section

    @ViewBuilder private var channelsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FavoritesSectionHeader(
                title: "Channels",
                count: favoriteChannels.count,
                trailingIcon: favoriteChannels.count > 1 ? "arrow.up.arrow.down" : nil,
                accentColor: accentColor,
                onTrailingTap: { guard SwipeTapGuard.tapsAllowed else { return }; showReorderChannels = true }
            )
            .padding(.horizontal, 20)

            if favoriteChannels.isEmpty {
                FavoritesEmptyTile(
                    icon: "star.fill",
                    title: "No favorited channels yet",
                    subtitle: "Tap the heart on a channel to add it here."
                )
                .padding(.horizontal, 20)
            } else {
                // Same row the category lists use — logo, name, current EPG
                // program with progress bar and time left — so a favorited
                // channel reads exactly like it does anywhere else.
                LazyVStack(spacing: 0) {
                    ForEach(favoriteChannels) { channel in
                        ChannelRow(
                            channel: channel,
                            epgProgram: viewModel.getCurrentProgram(for: channel),
                            isFavorite: true,
                            accentColor: accentColor,
                            // Opens the same preview popup as a category
                            // list — description, upcoming guide, Play button.
                            playAction: { previewChannel = channel },
                            toggleFav: { viewModel.toggleFavorite(channel.id) }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: Teams & Leagues section

    @ViewBuilder private var teamsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FavoritesSectionHeader(
                title: "Teams & Leagues",
                count: favoriteTeams.count + favoriteLeagues.count,
                // Chevron opens the Teams & Leagues editor (reorder / delete);
                // "+" adds more. Both render as the same neutral circular
                // buttons — no accent-colored text.
                trailingIcon: (favoriteTeams.isEmpty && favoriteLeagues.isEmpty) ? nil : "chevron.right",
                accentColor: accentColor,
                onTrailingTap: { guard SwipeTapGuard.tapsAllowed else { return }; showSeeAllTeams = true },
                onAddTap: { guard SwipeTapGuard.tapsAllowed else { return }; showAddSheet = true }
            )
            .padding(.horizontal, 20)

            if favoriteTeams.isEmpty && favoriteLeagues.isEmpty {
                Button(action: { guard SwipeTapGuard.tapsAllowed else { return }; showAddSheet = true }) {
                    FavoritesEmptyTile(
                        icon: "sportscourt.fill",
                        title: "Add a team or league",
                        subtitle: "Every club, national side, and F1 driver — pick your favorites."
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
            } else {
                VStack(spacing: 10) {
                    // Every favourite, not a preview of them: hiding half the
                    // list behind a "see all" button meant six favourites
                    // showed as four. The chevron still opens the editor for
                    // reordering and deleting.
                    // Positional ids — team ids alone can repeat across sports.
                    ForEach(Array(favoriteTeams.enumerated()), id: \.offset) { _, item in
                        FavoriteTeamRow(
                            team: item.team,
                            sport: item.sport,
                            leagueLabel: item.leagueLabel,
                            scoreViewModel: scoreViewModel,
                            onTap: {
                                // A golfer's page IS the leaderboard, with their
                                // row highlighted — there's no per-player feed
                                // to build a separate page from.
                                if item.sport == .golf,
                                   let tournament = scoreViewModel.liveOrNextGame(
                                       forTeamID: ScoreViewModel.teamKey(sport: .golf, teamID: item.team.id)) {
                                    scoreViewModel.presentGolfCard(
                                        tournament,
                                        highlightPlayer: item.team.displayName
                                    )
                                } else {
                                    detailTeam = TeamDetailSelection(team: item.team, leagueLabel: item.leagueLabel, sport: item.sport)
                                }
                            },
                            onWatch: { game in
                                playFromGame(game, sport: item.sport)
                            },
                            onRemove: {
                                scoreViewModel.toggleFavoriteTeam(item.team, sport: item.sport)
                            }
                        )
                    }
                    ForEach(Array(favoriteLeagues.enumerated()), id: \.element.displayName) { _, item in
                        FavoriteLeagueRow(
                            sport: item.sport,
                            leagueLabel: item.leagueLabel,
                            displayName: item.displayName,
                            scoreViewModel: scoreViewModel,
                            onTap: {
                                // Every favourited series opens its own page —
                                // Formula 1 and golf get the season (calendar
                                // and championships) there, not a single race.
                                detailLeague = LeagueDetailSelection(
                                    sport: item.sport,
                                    leagueLabel: item.leagueLabel,
                                    displayName: item.displayName
                                )
                            },
                            onRemove: {
                                scoreViewModel.toggleFavoriteLeague(sport: item.sport, leagueLabel: item.leagueLabel)
                            }
                        )
                    }

                    // "Add another" row so users can keep adding teams even
                    // after the first favorite. Tapping opens the same picker
                    // sheet as the empty-state tile.
                    Button(action: { guard SwipeTapGuard.tapsAllowed else { return }; showAddSheet = true }) {
                        HStack(spacing: 12) {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.14))
                                )
                            Text("Add another team or league")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.black.opacity(0.3))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 0.8, dash: [5, 4]))
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: Reminders section

    @ViewBuilder private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FavoritesSectionHeader(
                title: "Reminders",
                count: reminderGames.count,
                trailingIcon: nil,
                accentColor: accentColor,
                onTrailingTap: nil
            )
            .padding(.horizontal, 20)

            // Same native List swipe as the scheduled recordings / channel-hide
            // gesture: swipe a reminder to reveal Remove, same reveal and
            // row-collapse. Scroll-disabled and sized to its rows so it nests
            // in the outer scroll view.
            List {
                ForEach(reminderGames) { game in
                    FavoriteReminderRow(
                        game: game,
                        scoreViewModel: scoreViewModel,
                        onWatch: { playFromGame(game, sport: scoreViewModel.sportType(for: game)) },
                        onRemove: { scoreViewModel.toggleReminder(game) }
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            scoreViewModel.toggleReminder(game)
                        } label: {
                            Label("Remove", systemImage: "trash.fill")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .environment(\.defaultMinListRowHeight, 0)
            .frame(height: CGFloat(reminderGames.count) * 86)
            .captureGlobalFrame { reminderListFrame = $0 }
            // Cleared when the section isn't shown, so its old frame can't
            // create a dead zone on another filter page.
            .onDisappear { reminderListFrame = .zero }
        }
    }

    // MARK: Empty state

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "heart.fill")
                .font(.system(size: 50, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
            VStack(spacing: 8) {
                Text("Nothing favorited yet")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text("Heart channels, teams, and leagues to pin them here.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            Button(action: { guard SwipeTapGuard.tapsAllowed else { return }; showAddSheet = true }) {
                Text("Add a team or league")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .modifier(MVCapsuleGlass())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Helpers

    /// Resolves a game card tap (Watch button or reminder row) into a stream
    /// search via the channel view model's smart-search.
    private func playFromGame(_ game: ESPNEvent, sport: SportType?) {
        let home = game.homeCompetitor?.team?.shortDisplayName ?? game.homeCompetitor?.team?.displayName ?? ""
        let away = game.awayCompetitor?.team?.shortDisplayName ?? game.awayCompetitor?.team?.displayName ?? ""
        viewModel.runSmartSearch(
            gameID: game.id,
            home: home,
            away: away,
            sport: sport ?? scoreViewModel.sportType(for: game),
            network: game.broadcastName
        )
    }
}

// MARK: - Filter pills

/// Edge-to-edge horizontal chip selector. The ScrollView itself spans the full
/// screen width; only the inner HStack carries the 20-pt inset that matches
/// the rest of the content padding. This lets the trailing chips scroll past
/// the right edge instead of being clipped at a hard 20-pt margin.
struct FavoritesFilterPills: View {
    @Binding var selected: FavoritesFilter

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FavoritesFilter.allCases) { f in
                        Button(action: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                selected = f
                            }
                        }) {
                            Text(f.rawValue)
                                .font(.system(size: 15, weight: .semibold))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                // Opaque, background-derived fill — content
                                // scrolling behind the pinned pills must not
                                // show through.
                                .backgroundTintedChip(isSelected: selected == f)
                        }
                        .buttonStyle(.plain)
                        .id(f)
                    }
                }
                .padding(.horizontal, 20)
            }
            // Auto-scroll the active chip into view when the user swipes
            // between pages so it never sits off-screen.
            .onChange(of: selected) { _, newValue in
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Section header

struct FavoritesSectionHeader: View {
    let title: String
    let count: Int
    /// SF Symbol for the trailing action, rendered as the same neutral
    /// circular button as "+" — the old accent-colored text labels ("See
    /// All", "Reorder") read as clutter next to it.
    let trailingIcon: String?
    let accentColor: Color
    let onTrailingTap: (() -> Void)?
    /// Optional "+" tap target rendered on the trailing side. The Teams &
    /// Leagues section uses this so the user can always add another favorite
    /// even when the list is full.
    var onAddTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Same section title as everywhere else, with the count badge
            // alongside it.
            Text(title)
                .font(NuvioTheme.sectionTitleFont)
                .foregroundStyle(.white)
                .lineLimit(1)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
            }
            Spacer()
            if let icon = trailingIcon, let action = onTrailingTap {
                Button(action: action) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }
            if let addAction = onAddTap {
                Button(action: addAction) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Channel tile

struct FavoriteChannelTile: View {
    let channel: StreamChannel
    let isLive: Bool
    /// Current EPG program title — shown under the channel name so the user
    /// can see what's on without opening the channel.
    var nowPlaying: String? = nil
    let onTap: () -> Void
    let onRemove: () -> Void

    private var abbreviation: String {
        let cleaned = channel.name
            .replacingOccurrences(of: "HD", with: "")
            .replacingOccurrences(of: "FHD", with: "")
            .replacingOccurrences(of: "UHD", with: "")
            .trimmingCharacters(in: .whitespaces)
        let words = cleaned.split(separator: " ").filter { !$0.isEmpty }
        if words.count == 1 {
            return String(words[0].prefix(2)).uppercased()
        }
        return words.prefix(2).map { String($0.prefix(1)) }.joined().uppercased()
    }

    var body: some View {
        Button(action: { guard SwipeTapGuard.tapsAllowed else { return }; onTap() }) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(0.55))
                        if let icon = channel.icon, !icon.isEmpty {
                            CachedAsyncImage(urlString: icon)
                                .padding(10)
                        } else {
                            Text(abbreviation)
                                .font(.system(size: 22, weight: .black))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    )

                    if isLive {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
                            .offset(x: 4, y: -4)
                    }
                }

                Text(channel.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let program = nowPlaying, !program.isEmpty {
                    Text(program)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isLive ? .red : .white.opacity(0.55))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.9)
                } else {
                    Text(isLive ? "Live" : "Off air")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label("Remove from Favorites", systemImage: "heart.slash")
            }
        }
    }
}

// MARK: - Team row

struct FavoriteTeamRow: View {
    let team: ESPNTeam
    let sport: SportType?
    let leagueLabel: String?
    @ObservedObject var scoreViewModel: ScoreViewModel
    @ObservedObject private var activityManager = GameActivityManager.shared
    /// Tap on the row body (anywhere except the Watch pill) opens the team's
    /// schedule sheet. The Watch pill keeps its existing one-tap-to-play flow.
    let onTap: () -> Void
    let onWatch: (ESPNEvent) -> Void
    let onRemove: () -> Void

    private var liveGame: ESPNEvent? {
        scoreViewModel.liveOrNextGame(forTeamID: ScoreViewModel.teamKey(sport: sport, teamID: team.id))
    }

    var body: some View {
        Button(action: { guard SwipeTapGuard.tapsAllowed else { return }; onTap() }) {
            HStack(spacing: 12) {
                FavoriteSquareLogo(logo: team.logo, abbreviation: team.abbreviation ?? team.displayName ?? "•", color: team.color)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(team.displayName ?? team.shortDisplayName ?? "Unknown Team")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        // An F1 favourite is a driver and a golf favourite is a
                        // player, not a club.
                        Text(sport == .f1 ? "DRIVER" : (sport == .golf ? "GOLFER" : "TEAM"))
                            .font(.system(size: 9, weight: .black))
                            .kerning(0.6)
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    if sport == .f1 {
                        raceStatusLines
                    } else if sport == .golf {
                        golfStatusLines
                    } else {
                        liveStatusLine
                    }
                }

                Spacer()

                if let game = liveGame, game.status.type.state == "in" {
                    // Inner Button keeps its own tap target so live games are
                    // still a one-tap-to-watch flow. SwiftUI bubbles outer
                    // taps only when this button doesn't claim them.
                    Button(action: { guard SwipeTapGuard.tapsAllowed else { return }; onWatch(game) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                            Text("Watch").font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.white))
                    }
                    .buttonStyle(.plain)
                } else {
                    // Subtle chevron so the row reads as a tappable disclosure.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let game = liveGame {
                Button { onWatch(game) } label: {
                    Label(game.status.type.state == "in" ? "Watch Live" : "Find Stream", systemImage: "play.fill")
                }
                let gameSport = sport ?? scoreViewModel.sportType(for: game)
                if gameSport != .f1 {
                    Button {
                        scoreViewModel.deepLinkRequest = scoreViewModel.makeDetailRequest(for: game, sport: gameSport)
                    } label: {
                        Label("View Stats", systemImage: "chart.bar.fill")
                    }
                }
                if game.status.type.state == "pre" {
                    let isReminderSet = scoreViewModel.reminderGameIDs.contains(game.id)
                    Button { scoreViewModel.toggleReminder(game) } label: {
                        Label(isReminderSet ? "Cancel Reminder" : "Remind Me",
                              systemImage: isReminderSet ? "bell.slash" : "bell")
                    }
                } else if game.status.type.state == "in" {
                    let isTracking = activityManager.trackedGameIDs.contains(game.id)
                    Button {
                        activityManager.toggle(
                            game: game,
                            leagueName: game.leagueLabel ?? gameSport.rawValue,
                            sport: gameSport
                        )
                    } label: {
                        Label(isTracking ? "Stop Live Activity" : "Live Activity",
                              systemImage: isTracking ? "bell.slash" : "bell.badge")
                    }
                }
            }
            Button(role: .destructive, action: onRemove) {
                Label("Remove from Favorites", systemImage: "heart.slash")
            }
        }
    }

    /// A driver's row can't say "Live · 2nd Quarter". It says which Grand Prix
    /// is next, at which circuit, which session is up and when — and, once a
    /// session has run, where this driver finished in it.
    @ViewBuilder private var raceStatusLines: some View {
        if let race = liveGame {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(race.shortName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                    if let circuit = race.circuit?.fullName {
                        Text("· \(circuit)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                if let session = race.currentRaceSession {
                    let live = session.state == "in"
                    HStack(spacing: 5) {
                        if live { Circle().fill(Color.red).frame(width: 6, height: 6) }
                        Text("\(ScoreRow.sessionName(session.label)) · \(session.detail)")
                            .font(.system(size: 12, weight: live ? .bold : .medium))
                            .foregroundStyle(live ? .red : .white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                if let placing = driverPlacing(in: race) {
                    Text(placing)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
        } else {
            Text("No upcoming race")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// "P3 in Qualifying" — where this driver came in the most recent session
    /// that has a result. Matches on name, since the favourite carries a
    /// catalog id and the scoreboard identifies drivers by athlete.
    private func driverPlacing(in race: ESPNEvent) -> String? {
        guard let session = race.latestFinishedRaceSession else { return nil }
        let wanted = (team.displayName ?? team.shortDisplayName ?? "")
            .folding(options: .diacriticInsensitive, locale: nil).lowercased()
        guard !wanted.isEmpty else { return nil }
        let index = session.order.firstIndex { competitor in
            let name = (competitor.athlete?.displayName ?? competitor.athlete?.fullName ?? "")
                .folding(options: .diacriticInsensitive, locale: nil).lowercased()
            guard !name.isEmpty else { return false }
            return name == wanted || name.hasSuffix(wanted) || wanted.hasSuffix(name)
        }
        guard let index else { return nil }
        return "P\(index + 1) in \(ScoreRow.sessionName(session.label))"
    }

    /// A golfer's row: which tournament is on, and where they stand in it. The
    /// scoreboard's competitor id is the athlete id, so their line comes
    /// straight out of the event already in memory — no extra request.
    @ViewBuilder private var golfStatusLines: some View {
        if let tournament = liveGame {
            let entry = (tournament.allCompetitions.first?.competitors ?? [])
                .first { $0.id == team.id }
            VStack(alignment: .leading, spacing: 3) {
                Text(tournament.shortName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if tournament.status.type.state == "in" {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                    }
                    if let entry, let order = entry.order {
                        Text("\(order)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .monospacedDigit()
                        Text("·")
                            .foregroundStyle(.white.opacity(0.4))
                        Text(entry.score ?? "–")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(ScoreRow.golfParColor(entry.score))
                            .monospacedDigit()
                        Text("·")
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Text(tournament.status.type.detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tournament.status.type.state == "in" ? .red : .white.opacity(0.6))
                        .lineLimit(1)
                }
            }
        } else {
            Text("No tournament this week")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder private var liveStatusLine: some View {
        if let game = liveGame, game.status.type.state == "in" {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("Live · \(game.status.type.detail)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                }
                if let league = leagueLabel ?? game.leagueLabel {
                    Text("· \(league)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
        } else if let next = liveGame, next.status.type.state == "pre" {
            Text("Next · \(next.scheduleAwareDetail)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        } else if let label = leagueLabel {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }
}

// MARK: - League row

struct FavoriteLeagueRow: View {
    let sport: SportType
    let leagueLabel: String?
    let displayName: String
    @ObservedObject var scoreViewModel: ScoreViewModel
    let onTap: () -> Void
    let onRemove: () -> Void

    private var liveCount: Int {
        // When a specific leagueLabel is set (e.g. "Bundesliga"), only count games
        // from that league's section — otherwise filteredGames[sport] dumps in
        // every soccer game across every league.
        let pool: [ESPNEvent]
        if let label = leagueLabel {
            pool = (scoreViewModel.filteredSectionsMap[sport] ?? [])
                .filter { $0.league == label }
                .flatMap { $0.games }
        } else {
            // No specific league pinned — use the flat sport-wide game list.
            pool = scoreViewModel.filteredGames[sport] ?? []
        }
        return pool.filter { $0.status.type.state == "in" }.count
    }

    /// Formula 1 and golf run one event at a time — the weekend or tournament
    /// that's on, else the next one due.
    private var fieldEvent: ESPNEvent? {
        guard sport == .f1 || sport == .golf else { return nil }
        let pool = scoreViewModel.filteredGames[sport] ?? []
        if let live = pool.first(where: { $0.isLiveNow }) { return live }
        return pool.filter { $0.status.type.state == "pre" }
            .min { $0.gameDate < $1.gameDate } ?? pool.max { $0.gameDate < $1.gameDate }
    }

    /// The session for a race weekend, the round for a tournament.
    private func fieldStatus(_ event: ESPNEvent) -> String {
        if let session = event.currentRaceSession {
            return "\(ScoreRow.sessionName(session.label)) · \(session.detail)"
        }
        return event.status.type.detail
    }

    var body: some View {
        Button(action: { guard SwipeTapGuard.tapsAllowed else { return }; onTap() }) {
            HStack(spacing: 12) {
                FavoriteSquareLogo(
                    logo: LeagueLogoURL.url(sport: sport, leagueLabel: leagueLabel),
                    abbreviation: abbreviationFor(displayName),
                    color: nil
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("LEAGUE")
                            .font(.system(size: 9, weight: .black))
                            .kerning(0.6)
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    // A field series runs ONE event at a time, so "0 live now"
                    // says nothing useful — name the event and where it is.
                    if let event = fieldEvent {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.shortName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                if event.isLiveNow {
                                    Circle().fill(Color.red).frame(width: 6, height: 6)
                                }
                                Text(fieldStatus(event))
                                    .font(.system(size: 12, weight: event.isLiveNow ? .bold : .medium))
                                    .foregroundStyle(event.isLiveNow ? .red : .white.opacity(0.6))
                                    .lineLimit(1)
                            }
                        }
                    } else if liveCount > 0 {
                        HStack(spacing: 6) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                            Text("\(liveCount) live now")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text(sport.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                Spacer()

                if liveCount > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label("Remove from Favorites", systemImage: "heart.slash")
            }
        }
    }

    private func abbreviationFor(_ s: String) -> String {
        let parts = s.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return parts.prefix(3).map { String($0.prefix(1)) }.joined().uppercased()
        }
        return String(s.prefix(3)).uppercased()
    }
}

// MARK: - Reminder row

struct FavoriteReminderRow: View {
    let game: ESPNEvent
    @ObservedObject var scoreViewModel: ScoreViewModel
    let onWatch: () -> Void
    let onRemove: () -> Void

    // Re-render each minute so the "in 2h 14m" countdown stays honest without a
    // per-second ticker.
    @State private var now = Date()
    private let minuteTick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()

    /// Full team names ("Los Angeles Lakers at Boston Celtics") rather than the
    /// three-letter shortName, falling back to shortName if names are missing.
    private var matchupName: String {
        let away = game.awayCompetitor?.team?.displayName
        let home = game.homeCompetitor?.team?.displayName
        if let away, let home, !away.isEmpty, !home.isEmpty { return "\(away) at \(home)" }
        return game.shortName
    }

    /// The live/upcoming/final state as a coloured status word.
    private var statusPill: (text: String, color: Color)? {
        switch game.status.type.state {
        case "in":   return ("LIVE", .red)
        case "post": return ("FINAL", .white.opacity(0.5))
        default:     return nil
        }
    }

    /// Rich schedule line: exact time plus a relative countdown for upcoming
    /// games ("Today · 7:10 PM · in 2h"), or the day for anything further out.
    private var scheduleLine: String {
        let date = game.gameDate
        let cal = Calendar.current
        switch game.status.type.state {
        case "in":   return "Started " + Self.timeFmt.string(from: date)
        case "post": return "Ended " + Self.dayFmt.string(from: date)
        default: break
        }
        let time = Self.timeFmt.string(from: date)
        let dayPrefix: String
        if cal.isDateInToday(date) { dayPrefix = "Today" }
        else if cal.isDateInTomorrow(date) { dayPrefix = "Tomorrow" }
        else { dayPrefix = Self.dayFmt.string(from: date) }

        let delta = date.timeIntervalSince(now)
        guard delta > 0 else { return "\(dayPrefix) · \(time)" }
        let mins = Int(delta / 60)
        let countdown: String
        if mins < 60 { countdown = "in \(max(1, mins))m" }
        else if mins < 24 * 60 { countdown = "in \(mins / 60)h \(mins % 60)m" }
        else { countdown = "in \(mins / (24 * 60))d" }
        return "\(dayPrefix) · \(time) · \(countdown)"
    }

    /// The broadcast channel's logo, resolved from the game's network name to
    /// one of the user's channels. Same leading visual as a scheduled
    /// recording row, so the two cards read identically.
    private var channelLogoURL: String? {
        guard let broadcast = game.broadcastName, !broadcast.isEmpty else { return nil }
        return ChannelViewModel.shared.channels.first {
            $0.name.localizedCaseInsensitiveContains(broadcast)
                || broadcast.localizedCaseInsensitiveContains($0.name)
        }?.icon
    }

    /// Leading logo chip — the channel the game is on, matching the recordings
    /// section's card exactly.
    private var logoChip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if let url = channelLogoURL, !url.isEmpty {
                CachedAsyncImage(urlString: url, size: CGSize(width: 40, height: 40))
                    .padding(6)
            } else {
                Image(systemName: "bell.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.yellow)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    var body: some View {
        HStack(spacing: 12) {
            logoChip

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(matchupName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let pill = statusPill {
                        Text(pill.text)
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(pill.color == .red ? .white : .black.opacity(0.7))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(pill.color == .red ? Color.red : Color.white.opacity(0.6)))
                    }
                }
                Text(scheduleLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            if game.status.type.state == "in" {
                Button(action: { guard SwipeTapGuard.tapsAllowed else { return }; onWatch() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                        Text("Watch").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .onReceive(minuteTick) { now = $0 }
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label("Remove reminder", systemImage: "bell.slash")
            }
        }
    }
}

// MARK: - Squared logo (team or league)

struct FavoriteSquareLogo: View {
    let logo: String?
    let abbreviation: String
    let color: String?

    private var fallbackColor: Color {
        guard let hex = color, !hex.isEmpty else { return Color.white.opacity(0.18) }
        return Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)") ?? Color.white.opacity(0.18)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(fallbackColor)
            if let logo = logo, !logo.isEmpty {
                CachedAsyncImage(urlString: logo)
                    .padding(6)
            } else {
                Text(String(abbreviation.prefix(3)))
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Empty tile

struct FavoritesEmptyTile: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 48, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}

// MARK: - Bottom search pill

/// Visually identical to MainView's home-screen `bottomSearchPill` — same
/// magnifying-glass + "Search" + capsule-glass background. Keeping the
/// layout the same makes the Favorites screen feel like the home screen.
struct FavoritesSearchPill: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: { guard SwipeTapGuard.tapsAllowed else { return }; onTap() }) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Search")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .modifier(MVCapsuleGlass())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
