import SwiftUI
import Combine

// MARK: - Filter pills

enum FavoritesFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case channels = "Channels"
    case teams = "Teams"
    case leagues = "Leagues"
    var id: String { rawValue }
}

// MARK: - Favorites screen

/// Hub for the user's favorited channels, teams and leagues.
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
    /// Drives the compact "Favorites" line that grows into the chrome row as
    /// the big title scrolls away.
    var titleProgress: ScrollProgress = ScrollProgress()
    @State private var showAddSheet = false
    @State private var showReorderChannels = false
    @State private var showSeeAllTeams = false
    @State private var showSearchSheet = false
    /// Live scroll depth of the ACTIVE page, driving the header slide. A
    /// LEAF, so a scroll frame moves the header and re-renders nothing else.
    @State private var headerScroll = ScrollProgress()
    /// How far EVERY page is scrolled, kept per filter. The pages each keep
    /// their own scroll position, so on a swipe the header has to be told the
    /// new page's depth — otherwise it holds the one it had for the page you
    /// just left, and a page sitting at its top under a still-collapsed
    /// header shows the big title's height of empty space above its content.
    @State private var pageDepths: [String: CGFloat] = [:]
    /// Height of the big title — how far the header travels before the pills
    /// reach the top.
    @State private var bigTitleHeight: CGFloat = 56

    /// Breathing room between the bottom of the pill row and the first thing
    /// on the page. Larger than the Sports hub's: the filter pills are taller
    /// than the sport chips, so the same gap read as tighter here.
    static let headerClearance: CGFloat = 42

    /// Distance from the top of the DISPLAY down to the top of the header.
    ///
    /// Used ONLY to tell the backdrop how far up to reach — it is not part of
    /// any layout, which matters: an earlier version added it to the pages'
    /// top padding as well, on top of the safe-area inset the scroll view was
    /// already applying, and every page sat that much too low.
    @State private var safeTop: CGFloat = 112

    /// Height of the WHOLE header. Each page reserves exactly this much and
    /// it does NOT shrink as the header collapses, so the header sliding
    /// cannot change how far the page thinks it has scrolled.
    @State private var headerHeight: CGFloat = 120

    /// Central filter switch, used by the pill row. The pager animates the
    /// page move itself, so this is only a selection change — no slide
    /// direction and no scroll clamp: each page keeps its own scroll
    /// position, which is exactly what the shared scroll could not do.
    private func selectFilter(_ newFilter: FavoritesFilter) {
        guard newFilter != filter else { return }
        withAnimation(.easeInOut(duration: 0.25)) { filter = newFilter }
    }

    /// Hand the header the depth of the page just landed on, rather than
    /// leaving it showing the depth of the page left behind.
    private func syncHeaderToFilter(_ f: FavoritesFilter) {
        applyHeaderDepth(pageDepths[f.rawValue] ?? 0)
    }

    private var favoriteChannels: [StreamChannel] { viewModel.orderedFavoriteChannels() }
    private var favoriteTeams: [(team: ESPNTeam, sport: SportType?, leagueLabel: String?)] {
        scoreViewModel.resolvedFavoriteTeams()
    }
    private var favoriteLeagues: [(sport: SportType, leagueLabel: String?, displayName: String)] {
        scoreViewModel.resolvedFavoriteLeagues()
    }

    /// One filter's content as its own independently scrolling page.
    ///
    /// The header is a top safe-area inset on the pager, so each page's
    /// scroll view is laid out beneath it automatically.
    private func filterPage(for f: FavoritesFilter) -> some View {
        ScrollView(showsIndicators: false) {
            content(for: f)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The header's height plus a little clearance, so the first
                // row has room below the pills. The scroll view supplies the
                // status bar and chrome row itself as a safe-area content
                // inset, so this must not add that distance again.
                .padding(.top, headerHeight + Self.headerClearance)
        }
        // Read straight off this scroll view rather than through a preference:
        // a paged TabView hosts each page in its own controller and
        // preferences do not reliably cross that.
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, y in
            let scrolled = max(0, y)
            // Recorded for every page, so a swipe can pick the right one up.
            pageDepths[f.rawValue] = scrolled
            // ...but only the page you are on may move the header.
            guard f == filter else { return }
            applyHeaderDepth(scrolled)
        }
    }

    @ViewBuilder
    private func content(for f: FavoritesFilter) -> some View {
        switch f {
        case .all:       allPageContent
        case .channels:  channelsPageContent
        case .teams:     teamsPageContent
        case .leagues:   leaguesPageContent
        }
    }

    /// Title and pills — FIXED at the top.
    ///
    /// Neither scrolls away, and neither travels sideways with the pages.
    /// Content passes underneath it, which is what the scrim behind it is for.
    /// Points the header at a given scroll depth: how far it has slid, and
    /// how far the chrome row's compact title has grown in.
    private func applyHeaderDepth(_ scrolled: CGFloat) {
        headerScroll.set(scrolled)
        titleProgress.set(min(max(scrolled / max(bigTitleHeight, 1), 0), 1))
    }

    /// The header: the filter pills, and nothing else.
    ///
    /// The big "Favorites" title is gone — the chrome row above already names
    /// the screen and carries the channel/team counts, so the large one was
    /// repeating what was already there while taking most of the height at
    /// the top. Nothing collapses as a result, so the header cannot get out
    /// of step with the space each page reserves for it.
    private var headerChrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { bigTitleHeight = g.size.height }
                            .onChangeCompat(of: g.size.height) { bigTitleHeight = $0 }
                    }
                )
                .modifier(HeaderFade(offset: headerScroll, over: bigTitleHeight))

            pinnedPillHeader
        }
            // Thick at the very top of the SCREEN, clear by the bottom of the
            // pills.
            .background(alignment: .top) {
                HeaderFadeBackdrop(headerHeight: headerHeight, extendUp: safeTop)
            }
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { headerHeight = g.size.height }
                        .onChangeCompat(of: g.size.height) { headerHeight = $0 }
                }
            )
            // `headerHeight` is measured BEFORE this, so it never changes as
            // the header moves — which keeps each page's reserved space
            // constant while the header rides over it.
            .modifier(HeaderSlide(offset: headerScroll, limit: bigTitleHeight))
    }

    /// The large page title. This is the part that scrolls away; the chrome
    /// row above keeps a small "Favorites" once it has gone.
    @ViewBuilder private var titleRow: some View {
        Text("Favorites")
            .font(NuvioTheme.pageTitleFont)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 10)
    }

    var body: some View {
        ZStack(alignment: .top) {
            AppBackground()
                .ignoresSafeArea()

            // The four filters are SIBLINGS in a real pager, the same
            // treatment the Sports hub got and for the same reason: with one
            // shared scroll and the page swapped in by identity, only one
            // page ever exists, so a swipe cannot show you the one you are
            // swiping towards. `TabView(.page)` is UIPageViewController
            // underneath — genuine interactive paging, both pages on screen
            // tracking the finger, and each page keeping its own scroll
            // position.
            TabView(selection: $filter) {
                ForEach(FavoritesFilter.allCases) { f in
                    filterPage(for: f)
                        .tag(f)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // The pages reach the top of the DISPLAY, so their content passes
            // behind the chrome row and the status bar. Without this there is
            // nothing up there for the gradient to sit over, and a black wash
            // on a black canvas is simply a black bar.
            .ignoresSafeArea(.container, edges: .top)

            // The header OVERLAYS the pages rather than being reserved by
            // SwiftUI. `safeAreaInset` looked tidier, but its reservation and
            // the header's own height are computed independently and were
            // disagreeing by well over a hundred points — the empty strip
            // between the chips and the first card. Here both sides come from
            // the SAME measured `headerHeight`: the header is that tall, and
            // each page reserves exactly that, so they cannot drift apart.
            headerChrome
        }
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { safeTop = g.frame(in: .global).minY }
                    .onChangeCompat(of: g.frame(in: .global).minY) { safeTop = $0 }
            }
        )
        // NOTE: no local bottom search pill here — MainViewModifiers already
        // pins the app-wide search bar to the bottom of every screen, and
        // rendering FavoritesSearchPill as well produced two stacked bars.
        // Same toolbar treatment as RecordingsView: hidden nav-bar background,
        // empty inline title, plain chevron+"Back" on the leading edge in
        // white. The trailing settings gear is supplied by MainViewModifiers
        // at the parent level, exactly like the Recordings screen.
        .onChangeCompat(of: filter) { syncHeaderToFilter($0) }
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
    }

    // MARK: Title row (matches RecordingsView's headerView)


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
    }

    /// Tabs share a baseline of top inset + floating-dock clearance.
    private var pageVerticalPadding: some View {
        Color.clear.frame(height: 122)
    }

    @ViewBuilder private var allPageContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Nothing favorited at all gets the single big empty state — the
            // per-section "add" tiles would otherwise stack three deep above it.
            if favoriteChannels.isEmpty && favoriteTeams.isEmpty && favoriteLeagues.isEmpty {
                emptyState.padding(.top, 60)
            } else {
                channelsSection
                teamsSection
                leaguesSection
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

    @ViewBuilder private var leaguesPageContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            leaguesSection
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

    // MARK: Teams section

    /// Teams and leagues get their own sections rather than one merged list:
    /// a club and a competition are different things to follow, they open
    /// different pages, and mixed together the list read as one long run of
    /// crests with no order to it.
    @ViewBuilder private var teamsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FavoritesSectionHeader(
                title: "Teams",
                count: favoriteTeams.count,
                // Chevron opens the Teams & Leagues editor (reorder / delete);
                // "+" adds more. Both render as the same neutral circular
                // buttons — no accent-colored text.
                trailingIcon: favoriteTeams.isEmpty ? nil : "chevron.right",
                accentColor: accentColor,
                onTrailingTap: { guard SwipeTapGuard.tapsAllowed else { return }; showSeeAllTeams = true },
                onAddTap: { guard SwipeTapGuard.tapsAllowed else { return }; showAddSheet = true }
            )
            .padding(.horizontal, 20)

            if favoriteTeams.isEmpty {
                Button(action: { guard SwipeTapGuard.tapsAllowed else { return }; showAddSheet = true }) {
                    FavoritesEmptyTile(
                        icon: "sportscourt.fill",
                        title: "Add a team",
                        subtitle: "Every club, national side, F1 driver and golfer — pick your favorites."
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
                                    DetailRouter.shared.open(.team(team: item.team, sport: item.sport, leagueLabel: item.leagueLabel))
                                }
                            },
                            onWatch: { game in
                                playFromGame(game, sport: item.sport)
                            },
                            onRemove: {
                                scoreViewModel.toggleFavoriteTeam(item.team, sport: item.sport)
                            },
                            onReorder: { guard SwipeTapGuard.tapsAllowed else { return }; showSeeAllTeams = true }
                        )
                    }

                    addAnotherRow(title: "Add another team")
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: Leagues section

    @ViewBuilder private var leaguesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FavoritesSectionHeader(
                title: "Leagues",
                count: favoriteLeagues.count,
                trailingIcon: favoriteLeagues.isEmpty ? nil : "chevron.right",
                accentColor: accentColor,
                onTrailingTap: { guard SwipeTapGuard.tapsAllowed else { return }; showSeeAllTeams = true },
                onAddTap: { guard SwipeTapGuard.tapsAllowed else { return }; showAddSheet = true }
            )
            .padding(.horizontal, 20)

            if favoriteLeagues.isEmpty {
                Button(action: { guard SwipeTapGuard.tapsAllowed else { return }; showAddSheet = true }) {
                    FavoritesEmptyTile(
                        icon: "trophy.fill",
                        title: "Add a league",
                        subtitle: "Follow a competition for its table, fixtures and results."
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(favoriteLeagues.enumerated()), id: \.element.displayName) { _, item in
                        FavoriteLeagueRow(
                            sport: item.sport,
                            leagueLabel: item.leagueLabel,
                            displayName: item.displayName,
                            scoreViewModel: scoreViewModel,
                            onTap: {
                                // The row is the league: its page, with the
                                // season's calendar and championships.
                                DetailRouter.shared.open(.league(
                                    sport: item.sport,
                                    leagueLabel: item.leagueLabel,
                                    displayName: item.displayName
                                ))
                            },
                            onOpenLive: { live in
                                // The tournament line is the tournament, and
                                // tapping it opens the card that can play it.
                                if item.sport == .golf {
                                    scoreViewModel.presentGolfCard(live)
                                } else if item.sport == .f1 {
                                    scoreViewModel.presentRaceCard(live)
                                } else {
                                    scoreViewModel.deepLinkRequest =
                                        scoreViewModel.makeDetailRequest(for: live, sport: item.sport)
                                }
                            },
                            onRemove: {
                                scoreViewModel.toggleFavoriteLeague(sport: item.sport, leagueLabel: item.leagueLabel)
                            },
                            onReorder: { guard SwipeTapGuard.tapsAllowed else { return }; showSeeAllTeams = true }
                        )
                    }

                    addAnotherRow(title: "Add another league")
                }
                .padding(.horizontal, 20)
            }
        }
    }

    /// Dashed "add" row that closes out a populated section, so users can keep
    /// adding after the first favourite. Opens the same picker as the empty
    /// state and the header's "+".
    private func addAnotherRow(title: String) -> some View {
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
                Text(title)
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

    /// Resolves a game card tap (its Watch button) into a stream
    /// search via the channel view model's smart-search.
    private func playFromGame(_ game: ESPNEvent, sport: SportType?) {
        // `searchTerms` rather than the competitors: it already knows that a
        // golf tournament or a race weekend has no two sides, and returns the
        // EVENT's name. Reading team names directly gave those two empty
        // strings — golf competitors are athletes, with no team at all — so a
        // favourite golfer's Watch searched for nothing.
        let terms = game.searchTerms
        viewModel.runSmartSearch(
            gameID: game.id,
            home: terms.home,
            away: terms.away,
            sport: sport ?? scoreViewModel.sportType(for: game),
            network: game.streamNetworkHint
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
    /// Opens the reorder editor. These rows sit in a VStack rather than a List,
    /// so they cannot be dragged in place — the menu points at the screen that
    /// can do it.
    var onReorder: () -> Void = {}

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
    /// Opens the reorder editor. These rows sit in a VStack rather than a List,
    /// so they cannot be dragged in place — the menu points at the screen that
    /// can do it.
    var onReorder: () -> Void = {}

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
            // The same surface a channel row is drawn on — NuvioTheme.card
            // with the same hairline — rather than a black wash that all but
            // disappeared against the black canvas behind it.
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(NuvioTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
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
    /// Opens the card for the event this series is running.
    var onOpenLive: ((ESPNEvent) -> Void)? = nil
    let onRemove: () -> Void
    /// Opens the reorder editor. These rows sit in a VStack rather than a List,
    /// so they cannot be dragged in place — the menu points at the screen that
    /// can do it.
    var onReorder: () -> Void = {}

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

    /// The row itself. A plain container rather than a Button: a Button's label
    /// never routes taps to anything inside it, and the live event line below
    /// needs its own tap. A nested tap gesture DOES take precedence over the
    /// one on its ancestor, which is what makes the two targets possible.
    private var rowBody: some View {
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
                    liveEventLine(event)
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
        // The same surface a channel row is drawn on — NuvioTheme.card with the
        // same hairline — rather than a black wash that all but disappeared
        // against the black canvas behind it.
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(NuvioTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    /// The event this series is running, and its own tap target: tapping the
    /// tournament opens the card that can play it, while the row around it
    /// still goes to the league page.
    @ViewBuilder
    private func liveEventLine(_ event: ESPNEvent) -> some View {
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
        .contentShape(Rectangle())
    }

    var body: some View {
        Button {
            guard SwipeTapGuard.tapsAllowed else { return }
            ChannelViewModel.shared.triggerSelectionHaptic()
            // The league's own page, always — the general view of the series
            // rather than whichever event happens to be on. That page opens on
            // its Live tab when something is running, so the tournament card is
            // one tap further and nothing is lost.
            onTap()
        } label: {
            rowBody
        }
        .buttonStyle(.plain)

        .contextMenu {
            if let event = fieldEvent, let onOpenLive {
                Button {
                    onOpenLive(event)
                } label: {
                    Label(event.isLiveNow ? "Watch \(event.shortName)" : event.shortName,
                          systemImage: "sportscourt")
                }
            }
            Button(action: onReorder) {
                Label("Reorder Favorites", systemImage: "arrow.up.arrow.down")
            }
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

struct FavoriteSquareLogo: View {
    let logo: String?
    let abbreviation: String
    let color: String?
    /// Flipped once the crest has been sampled, so a tile that started on
    /// the brand colour can move off it.
    @State private var crestSampled = false

    private var brandColor: Color {
        guard let hex = color, !hex.isEmpty else { return Color.white.opacity(0.18) }
        return Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)") ?? Color.white.opacity(0.18)
    }

    /// The brand colour — unless the crest would vanish on it. Some clubs'
    /// marks are one flat colour, and that colour IS the brand colour: a
    /// black crest on a black tile, the Longhorns' burnt orange on burnt
    /// orange. Those tiles are pushed lighter or darker, whichever lets the
    /// crest read — see `LogoGlow.field`.
    private var fill: Color {
        _ = crestSampled
        return LogoGlow.field(hex: color, forLogo: logo) ?? brandColor
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(fill)
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
        // Only a crest on a brand tile can be lost; nothing to learn
        // otherwise.
        .samplesCrests(color == nil ? [] : [logo], flag: $crestSampled)
    }
}

/// Samples the given crests once, so `LogoGlow.field` can answer for them,
/// and flips `flag` when they all have been — the one state change that
/// re-renders the view whose colours depend on the answer. Nothing happens
/// for crests already sampled, which after the first look is all of them.
private struct CrestSampling: ViewModifier {
    let logos: [String]
    @Binding var flag: Bool

    func body(content: Content) -> some View {
        content.task(id: logos) {
            let pending = logos.filter { LogoGlow.mean(for: $0) == nil }
            guard !pending.isEmpty else { return }
            for logo in pending { await LogoGlow.sampleIfNeeded(logo) }
            flag.toggle()
        }
    }
}

extension View {
    /// See `CrestSampling`.
    func samplesCrests(_ logos: [String?], flag: Binding<Bool>) -> some View {
        modifier(CrestSampling(logos: logos.compactMap { $0 }.filter { !$0.isEmpty }, flag: flag))
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
