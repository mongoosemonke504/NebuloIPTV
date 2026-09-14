import SwiftUI

/// The page a favourited team opens — from the Favorites tab and from the home
/// screen's Favorites shelf alike. The hero behaves exactly like the home
/// screen's: full-bleed behind the status bar, artwork parallaxing as you
/// scroll, stretching from its bottom edge when you rubber-band past the top —
/// just without the pager, since there's only ever one team here.
///
/// Below it, the reference football app's team screen in this app's language,
/// split across the same tabs: Overview, Matches, Table, Stats and Squad.
/// Nothing here is football-only — the tabs, the columns and the roster
/// sections all take their shape from what ESPN returns for the sport, so a
/// baseball club gets Pitchers/Catchers/Infielders where a football club gets
/// Goalkeepers/Defenders/Midfielders.
struct TeamDetailPage: View {
    let team: ESPNTeam
    let leagueLabel: String?
    var sport: SportType? = nil
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case matches = "Matches"
        case table = "Table"
        case stats = "Stats"
        case squad = "Squad"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .overview
    @State private var profile: TeamDetailService.Profile?
    @State private var schedule: [ESPNEvent] = []
    @State private var standings: [LeagueDetailService.StandingsGroup] = []
    @State private var squad: [TeamDetailService.Player] = []
    @State private var squadPhotos: [String: String] = [:]
    @State private var seasonStats: TeamDetailService.SeasonStats?
    @State private var clubInfo: TeamDetailService.ClubInfo?
    @State private var aboutExpanded = false
    @State private var lastLineup: GDLineup?
    @State private var lastLineupOpponent: String?
    @State private var loading = true

    /// Same two scroll-driven leaves the home hero uses.
    @State private var heroPull = ScrollProgress()
    @State private var heroScroll = ScrollProgress()
    /// 0 → big title visible, 1 → collapsed onto the chrome row. A leaf so the
    /// per-frame writes re-render the two faded views and nothing else.
    @State private var titleProgress = ScrollProgress()

    /// Live scroll depth of the ACTIVE page, driving the header slide. A
    /// LEAF, so a scroll frame moves the header and re-renders nothing else.
    @State private var headerScroll = ScrollProgress()
    /// Measured height of the floating header (hero + chip row). Each page
    /// reserves exactly this at its top.
    /// Seeded with what the chrome comes to — the hero plus the chip row —
    /// rather than zero, so the pages' reserve is right on the very first
    /// frame; the measurement then only corrects it by a point or two.
    /// Started at zero, the content sat under the hero for a frame and then
    /// jumped down by the header's whole height — mid-push.
    @State private var headerHeight: CGFloat = UIScreen.main.bounds.height * 0.47 + 50
    /// The top content inset the pages' scroll views apply on their own —
    /// see the reserve in `tabPage`.
    /// Seeded with the status-bar inset, which is what the pager's controller
    /// applies to every page — see `tabPage`.
    @State private var pageInsetTop: CGFloat = WindowInsets.top

    /// Points of scroll over which the header collapses: the big title hands
    /// over to the compact one, and the chip row's scrim ramps in.
    private static let handoverSpan: CGFloat = 90

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    /// Shorter than the home screen's hero. Home's fills the screen because
    /// it's the whole point of that page; here the tabs and the content under
    /// them are, and 60% of the screen pushed the chips most of a screen down.
    /// Height of the status bar, read from the window — the stack ignores the
    /// top safe area for the hero's sake, so anything that must clear the
    /// status bar adds this back itself.
    private var statusBarInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets.top ?? 0
    }

    private var heroHeight: CGFloat { UIScreen.main.bounds.height * 0.47 }

    /// Where the pinned chip row has to come to rest: clear of the status bar
    /// and the back chevron. The scroll view deliberately ignores the top safe
    /// area (so the hero can bleed behind the status bar), which means a pinned
    /// header would otherwise stick at the very top of the screen, under the
    /// Dynamic Island.
    private var pinnedInset: CGFloat { statusBarInset + 44 }

    // MARK: Derived

    private var displayName: String {
        profile?.displayName ?? team.displayName ?? team.shortDisplayName ?? "Team"
    }

    /// The brand colour's hex, for the crest's contrast test — see `hero`.
    private var brandHex: String? { profile?.color ?? team.color }

    /// The team's brand colour: ESPN's team profile first (it carries the real
    /// hex), then whatever the scoreboard attached, then a neutral slate.
    private var brand: Color {
        let hex = brandHex
        guard let hex, !hex.isEmpty,
              let c = Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)") else {
            return Color(white: 0.20)
        }
        return c
    }

    private var secondary: Color {
        guard let hex = profile?.alternateColor, !hex.isEmpty,
              let c = Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)") else { return brand }
        return c
    }

    private var logo: String? { profile?.logo ?? team.logo }

    /// Everything we know about this team's fixtures: the season schedule from
    /// the team endpoint, topped up with anything live in the scoreboard pool
    /// the schedule hasn't caught up with.
    private var allGames: [ESPNEvent] {
        var seen = Set<String>()
        var out: [ESPNEvent] = []
        for g in scoreViewModel.gamesForTeam(ScoreViewModel.teamKey(sport: sport, teamID: team.id))
            where seen.insert(g.id).inserted { out.append(g) }
        for g in schedule where seen.insert(g.id).inserted { out.append(g) }
        return out
    }

    private var liveGame: ESPNEvent? { allGames.first { $0.status.type.state == "in" } }

    private var nextGame: ESPNEvent? {
        allGames.filter { $0.status.type.state == "pre" && $0.gameDate > Date() }
            .min { $0.gameDate < $1.gameDate }
    }

    private var recentResults: [ESPNEvent] {
        allGames.filter { $0.status.type.state == "post" }
            .sorted { $0.gameDate > $1.gameDate }
    }

    private var upcoming: [ESPNEvent] {
        allGames.filter { $0.status.type.state == "pre" }
            .sorted { $0.gameDate < $1.gameDate }
    }

    /// The standings group this team appears in.
    private var standingsGroup: LeagueDetailService.StandingsGroup? {
        standings.first { $0.rows.contains { $0.team.id == team.id } }
    }

    /// THIS team's slice of the table: their row plus the one above and below,
    /// which is all the reference app shows on a team page.
    private var tableSlice: [LeagueDetailService.StandingRow] {
        guard let group = standingsGroup,
              let idx = group.rows.firstIndex(where: { $0.team.id == team.id }) else { return [] }
        let lower = max(0, idx - 1)
        let upper = min(group.rows.count - 1, idx + 1)
        return Array(group.rows[lower...upper])
    }

    private var overallRecord: String? {
        profile?.records.first { $0.name.lowercased().contains("overall") }?.summary
            ?? profile?.records.first?.summary
    }

    /// The dot-separated line under the crest: league · record · table position.
    private var metadataParts: [String] {
        var parts: [String] = []
        if let league = leagueLabel ?? profile?.leagueName ?? sport?.rawValue { parts.append(league) }
        if let rec = overallRecord { parts.append(rec) }
        if let standing = profile?.standingSummary { parts.append(standing) }
        if parts.isEmpty { parts = ["Team"] }
        return parts
    }

    private var leagueName: String { leagueLabel ?? profile?.leagueName ?? sport?.rawValue ?? "League" }

    /// Squad sections in the order ESPN listed them — "Goalkeepers, Defenders,
    /// Midfielders, Forwards" for football, "Pitchers, Catchers, …" for
    /// baseball. Never alphabetised: the API order IS the meaningful one.
    private var squadSections: [(title: String, players: [TeamDetailService.Player])] {
        var order: [String] = []
        var buckets: [String: [TeamDetailService.Player]] = [:]
        for player in squad {
            if buckets[player.group] == nil { order.append(player.group) }
            buckets[player.group, default: []].append(player)
        }
        return order.map { (title: $0, players: buckets[$0] ?? []) }
    }

    /// Tabs with nothing behind them are dropped rather than opening empty —
    /// plenty of competitions have no table, and some sports no roster.
    ///
    /// Every tab while the page is still loading, though. Nearly every team
    /// has all five, and deciding from the data in hand meant the row opened
    /// as one chip — Overview, the full width — and split into five a beat
    /// later, as the page was still arriving; the row rebuilding itself was
    /// the thing that read as the tabs arriving separately from the page. A
    /// tab that turns out to be empty is dropped once, after the load.
    private var availableTabs: [Tab] {
        Tab.allCases.filter { t in
            if loading { return true }
            switch t {
            case .overview: return true
            case .matches:  return !allGames.isEmpty
            case .table:    return standingsGroup != nil
            case .stats:    return seasonStats != nil || !(profile?.records.isEmpty ?? true)
            case .squad:    return !squad.isEmpty
            }
        }
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            AppBackground().ignoresSafeArea()

            // The tabs are SIBLINGS in a real pager, the same treatment the
            // Sports and Favorites hubs got and for the same reason: with one
            // shared scroll and the tab swapped in by identity, only one tab
            // ever exists, so a swipe cannot show you the one you are swiping
            // towards. `TabView(.page)` is UIPageViewController underneath —
            // genuine interactive paging, both tabs on screen tracking the
            // finger, each keeping its own scroll position.
            //
            // The hero and the chip row float over the pages and slide up
            // with the active page's scroll until the chips pin, clear of the
            // status bar and the back chevron. The chips end up at
            // `pinnedInset`, so the travel is simply the hero's height less
            // that — no measurement to get wrong.
            TabView(selection: $tab) {
                ForEach(availableTabs) { t in
                    tabPage(for: t)
                        .tag(t)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            headerChrome
            // Static chrome — the catalog page's circular back chevron, with
            // the compact team name fading in as the big one scrolls off.
            HStack(spacing: 10) {
                NuvioCircleButton(systemName: "chevron.left") {
                    viewModel.triggerSelectionHaptic()
                    DetailRouter.shared.close()
                }
                Spacer(minLength: 0)
                // Name AND the league · record · position line: with the hero
                // gone this band is the only place they can live, and a name
                // on its own left the space reading as empty.
                VStack(spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    NuvioMetadataLine(parts: metadataParts)
                        .scaleEffect(0.85)
                }
                // Starts only once the hero's copy has finished fading (see
                // the hero's matching modifier).
                .scrollProgressOpacity(titleProgress) { Double(max(($0 - 0.55) / 0.45, 0)) }
                Spacer(minLength: 0)
                // Balances the chevron so the title sits centred.
                Color.clear.frame(width: 38, height: 38)
            }
            .padding(.horizontal, 16)
            // Below the status bar. The stack ignores the top safe area so the
            // hero can bleed behind it, which put this row under the clock and
            // Dynamic Island as well; the inset is added back here by hand.
            .padding(.top, statusBarInset + 4)
        }
        // The hero bleeds behind the status bar, exactly like home's. On the
        // whole stack, so the pages and the header share one origin — and so
        // the pages' scroll views take NO automatic top inset, which keeps
        // their reserve exactly the header's measured height.
        .ignoresSafeArea(.container, edges: .top)
        // A swipe changes `tab` without going through `selectTab`, so the
        // re-sync hangs off the value itself.
        .onChangeCompat(of: tab) { _ in syncHeaderToSelectedTab() }
        .preferredColorScheme(.dark)
        .task(id: team.id) {
            loading = true
            async let p = TeamDetailService.fetchProfile(sport: sport, leagueLabel: leagueLabel, teamID: team.id)
            async let s = TeamDetailService.fetchSchedule(sport: sport, leagueLabel: leagueLabel, teamID: team.id)
            async let t: [LeagueDetailService.StandingsGroup] = {
                guard let sport else { return [] }
                return await LeagueDetailService.fetchStandings(sport: sport, leagueLabel: leagueLabel)
            }()
            async let r = TeamDetailService.fetchRoster(sport: sport, leagueLabel: leagueLabel, teamID: team.id)
            async let st = TeamDetailService.fetchSeasonStats(sport: sport, leagueLabel: leagueLabel, teamID: team.id)
            profile = await p
            schedule = await s
            standings = await t
            squad = await r
            seasonStats = await st
            loading = false

            // These depend on the roster/schedule/profile above, so they run
            // after rather than alongside — and none blocks the page appearing.
            await resolveSquadPhotos()
            clubInfo = await TeamDetailService.fetchClubInfo(
                names: [displayName, team.shortDisplayName].compactMap { $0 },
                sport: sport
            )
            await loadLastLineup()
        }
        // A tab whose data never arrived would strand the page on a blank
        // panel; drop back to Overview, which always has something.
        .onChange(of: availableTabs.map(\.rawValue)) { _, tabs in
            if !tabs.contains(tab.rawValue) { tab = .overview }
        }
    }

    // MARK: Loading

    /// Football rosters carry a photo for roughly one player in ten, so the
    /// rest are resolved by name in a single batched lookup.
    private func resolveSquadPhotos() async {
        let missing = squad.filter { ($0.headshot ?? "").isEmpty }.map(\.name)
        guard !missing.isEmpty else { return }
        squadPhotos = await PlayerPhotoService.shared.photos(for: missing, sport: sport)
    }

    /// The XI that started this team's most recent finished game — the
    /// reference app's "Last starting XI". Only football summaries carry
    /// formations, so this simply stays nil everywhere else and the section
    /// doesn't appear.
    private func loadLastLineup() async {
        guard let game = recentResults.first else { return }
        let gameSport = scoreViewModel.sportType(for: game)
        let request = scoreViewModel.makeDetailRequest(for: game, sport: gameSport)
        guard let url = GameDetailViewModel.summaryURL(for: request),
              let summary = try? await GameDetailViewModel.prefetchSummary(url: url),
              let roster = summary.rosters?.first(where: { $0.team?.id == team.id })
        else { return }

        let names = (roster.roster ?? []).compactMap { $0.athlete?.displayName }
        let photos = await PlayerPhotoService.shared.photos(for: names, sport: sport)

        lastLineup = GameDetailViewModel.buildLineup(
            roster: roster,
            ratingsAvailable: true,
            headshot: { athlete in
                if let href = athlete?.headshot?.href, !href.isEmpty { return href }
                guard let name = athlete?.displayName else { return nil }
                return photos[name]
            },
            age: { _ in nil }
        )
        let opponent = game.allCompetitions.first?.competitors?.first { $0.team?.id != team.id }
        lastLineupOpponent = opponent?.team?.shortDisplayName ?? opponent?.team?.displayName
    }

    // MARK: Hero

    private var hero: some View {
        ZStack {
            // The colour field and crest are the "artwork" layer: they carry
            // the home hero's scroll parallax and overscroll scale, so they
            // lag behind the name and pill travelling away at full speed.
            ZStack {
                brand
                RadialGradient(
                    colors: [secondary.opacity(0.55), .clear],
                    center: UnitPoint(x: 0.5, y: 0.36),
                    startRadius: 0,
                    endRadius: 260
                )
                // The crest sits on a field of its own colour here, so a
                // one-colour mark gets a pool of light behind it — see
                // `TeamCrest`.
                TeamCrest(logo: logo ?? "", size: 150, fieldHex: brandHex)
                    .offset(y: -heroHeight * 0.13)
                    .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 5)
            }
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
            .modifier(HeroScrollParallax(scroll: heroScroll, baseScale: 1.14))

            // Dissolve into the canvas so the name and pill stay legible over
            // any brand colour, pale ones included.
            //
            // One CONTINUOUS ramp, and it reaches pure black only at the very
            // last pixel. The earlier version was clear to 0.40, then dove to
            // 96% black by 0.93 — which put two artefacts on screen at once:
            // the dive read as a hard line where the colour crossed into
            // visually-black, and everything past it was a flat black band
            // filling the hero's bottom quarter (~100pt of dead space between
            // the colour and the chips). A monotonic ramp has no crossing point
            // to see and no plateau to sit in, so any slice of the hero the
            // scroll happens to leave on screen reads as a gradient. Ending on
            // black exactly at the bottom edge is what keeps that edge
            // invisible — there is no colour left at it to cut off.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: .black.opacity(0.05), location: 0.30),
                    .init(color: .black.opacity(0.30), location: 0.55),
                    .init(color: .black.opacity(0.62), location: 0.75),
                    .init(color: .black.opacity(0.86), location: 0.90),
                    .init(color: .black, location: 1.00)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                // Name, competition and record sit under the crest, inside the
                // hero. The chip row directly below is the page's only other
                // fixed furniture, and the compact copy of the name lives in the
                // chrome row for when this has scrolled away.
                VStack(spacing: 13) {
                    Text(displayName)
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

                Spacer().frame(height: 16)

                if let game = liveGame ?? nextGame {
                    NuvioPillButton(title: liveGame != nil ? "Watch" : "Game Card") {
                        guard SwipeTapGuard.tapsAllowed else { return }
                        viewModel.triggerSelectionHaptic()
                        openGameCard(game)
                    }
                }
            }
            .padding(.bottom, 34)
            // Hands the name over to the compact copy in the chrome row instead
            // of leaving both on screen at once. The two fades are deliberately
            // sequential — this block is gone by 0.5, the compact one only
            // starts at 0.55 — because they sit barely 100pt apart, so a
            // straight cross-fade read as the team name printed twice.
            .scrollProgressOpacity(titleProgress) { 1 - Double(min($0 / 0.5, 1)) }
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    // MARK: Pinned chips

    /// Sticky section header: the tab chips.
    ///
    /// All five share the width evenly rather than scrolling sideways — a row
    /// you had to scroll to reach the last chip made the tabs feel hidden. The
    /// labels shrink to fit inside their share instead.
    private var pinnedChipHeader: some View {
        HStack(spacing: 6) {
            ForEach(availableTabs) { t in
                Button(action: {
                    guard SwipeTapGuard.tapsAllowed else { return }
                    selectTab(t)
                }) {
                    Text(t.rawValue)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tab == t ? .black : .white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule().fill(tab == t ? Color.white : Color(white: 0.15))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Pushes the chips clear of the status bar and back chevron once the
        // header pins; the title block above cancels it out beforehand.
        .padding(.top, pinnedInset)
        // Dims the content passing underneath, and only once the header is
        // actually pinned — at the top of the page it would otherwise wash over
        // the title block sitting inside its padding.
        .background(alignment: .top) {
            // `topFade` matches the handover span, so the scrim's top edge is
            // soft over exactly the stretch of scroll where it's still mid-screen
            // and hard-edged once it's flush with the top.
            CompactHeaderScrim(height: pinnedInset + 120,
                               fadeStart: 0.55,
                               topFade: Self.handoverSpan)
                .scrollProgressOpacity(titleProgress, cullWhenHidden: true) { Double($0 * $0) }
        }
    }

    /// How far the header slides before the chips pin: the hero's height,
    /// less the inset the chips come to rest at.
    private var headerTravel: CGFloat { max(0, heroHeight - pinnedInset) }

    /// Last known scroll depth of each tab. A reference box rather than
    /// `@State`, because it is written on every scroll frame.
    fileprivate final class TabDepths { var values: [Tab: CGFloat] = [:] }
    @State fileprivate var tabDepths = TabDepths()

    /// Puts the header where a given scroll depth wants it.
    private func applyScroll(_ scrolled: CGFloat) {
        heroPull.set(max(0, -scrolled))
        heroScroll.set(min(max(0, scrolled), heroHeight))
        headerScroll.set(max(0, scrolled))
        // The chips pin at `headerTravel`. The handover runs over the last
        // 90pt of that travel, so the big title fades out as the compact one
        // in the chrome row fades in.
        let span = Self.handoverSpan
        titleProgress.set(min(max((scrolled - (headerTravel - span)) / span, 0), 1))
    }

    /// Hands the header the depth of whichever tab is now in front. Each page
    /// keeps its own scroll position, so arriving at one otherwise leaves the
    /// header holding the depth of the page you left — collapsed over a list
    /// sitting at its top, which is the tall gap between the chips and the
    /// first row.
    private func syncHeaderToSelectedTab() {
        applyScroll(tabDepths.values[tab] ?? 0)
    }

    /// One tab as its own independently scrolling page.
    private func tabPage(for t: Tab) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // The floating header's height, reserved — LESS whatever top
                // inset this scroll view has applied on its own. The pager
                // hosts each page in its own controller, and that controller
                // re-applies the window's safe area even though the stack
                // around it ignores it; left in, content sat that far below
                // the chips. Constant otherwise: the header SLIDES, it never
                // resizes, so the reserve cannot drift from it.
                Color.clear.frame(height: max(0, headerHeight - pageInsetTop))

                Group {
                    switch t {
                    case .overview: overviewTab
                    case .matches:  matchesTab
                    case .table:    tableTab
                    case .stats:    statsTab
                    case .squad:    squadTab
                    }
                }
                .padding(.top, 12)

                if loading && profile == nil {
                    HStack {
                        Spacer()
                        CustomSpinner(color: .white.opacity(0.5), lineWidth: 2, size: 22)
                        Spacer()
                    }
                    .padding(.vertical, 30)
                }

                Color.clear.frame(height: 60)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Frozen while the page is being swiped closed, so it travels
        // sideways only.
        .scrollLocked(DetailRouter.shared.dragLock)
        // Read straight off this scroll view rather than through a preference:
        // a paged TabView hosts each page in its own controller and
        // preferences do not reliably cross that.
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geo in
            let scrolled = geo.contentOffset.y + geo.contentInsets.top
            if geo.contentInsets.top != pageInsetTop { withoutAnimation { pageInsetTop = geo.contentInsets.top } }
            tabDepths.values[t] = scrolled
            // Only the page you are on drives the header; the neighbours are
            // mounted and reporting too.
            guard t == tab else { return }
            applyScroll(scrolled)
        }
    }

    /// The hero and the chip row, floating over the pages and sliding up with
    /// the active page's scroll until the chips pin.
    private var headerChrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
                .modifier(HeroStretch(pull: heroPull, height: heroHeight))
                // Cancels the chip header's own top padding (see
                // pinnedChipHeader) so the chips sit tight under the hero
                // until the moment they pin.
                .padding(.bottom, -pinnedInset)

            pinnedChipHeader
        }
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { withoutAnimation { headerHeight = g.size.height } }
                    .onChangeCompat(of: g.size.height) { h in withoutAnimation { headerHeight = h } }
            }
        )
        .modifier(HeaderSlide(offset: headerScroll, limit: headerTravel))
    }

    /// Switches tab, used by the chip row. The pager animates the page move
    /// itself, so this is only a selection change.
    private func selectTab(_ newTab: Tab) {
        guard newTab != tab else { return }
        withAnimation(.easeInOut(duration: 0.25)) { tab = newTab }
    }

    // MARK: Overview

    @ViewBuilder
    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let game = liveGame ?? nextGame {
                section(liveGame != nil ? "Ongoing" : "Next Match") {
                    nextMatchCard(game)
                }
            }

            if recentResults.count >= 2 {
                section("Team Form") { formStrip }
            }

            if let lineup = lastLineup, !lineup.rows.isEmpty {
                section(lastLineupOpponent.map { "Last Starting XI · vs \($0)" } ?? "Last Starting XI") {
                    FormationPitchView(
                        rows: lineup.rows,
                        teamColor: brand,
                        // All-or-nothing, same rule as the match page: a pitch
                        // with three photos and eight initials looks broken.
                        showPhotos: lineup.rows.allSatisfy { row in
                            row.allSatisfy { !($0.headshot ?? "").isEmpty }
                        }
                    )
                    .padding(.horizontal, 20)
                }
            }

            if !tableSlice.isEmpty {
                section(leagueName, chevron: standingsGroup != nil) {
                    tab = .table
                } content: {
                    tableSliceCard
                }
            }

            if hasStadiumInfo {
                section("Stadium") { infoCard }
            }

            if let about = clubInfo?.about {
                section("About") { aboutCard(about) }
            }

            // Everything above is conditional, so say so rather than leaving a
            // hero floating over blank canvas.
            if !loading && liveGame == nil && nextGame == nil && recentResults.count < 2
                && tableSlice.isEmpty && !hasStadiumInfo && clubInfo?.about == nil {
                emptyNote("No details available for this team yet")
            }
        }
    }

    // MARK: Matches

    @ViewBuilder
    private var matchesTab: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let game = liveGame {
                section("Ongoing") { nextMatchCard(game) }
            }

            if !upcoming.isEmpty {
                section("Upcoming Matches") {
                    VStack(spacing: 10) {
                        ForEach(upcoming.prefix(30)) { gameRow($0) }
                    }
                    .padding(.horizontal, 16)
                }
            }

            if !recentResults.isEmpty {
                section("Past Matches") {
                    VStack(spacing: 10) {
                        ForEach(recentResults.prefix(30)) { gameRow($0) }
                    }
                    .padding(.horizontal, 16)
                }
            }

            if allGames.isEmpty { emptyNote("No fixtures for this team yet") }
        }
    }

    // MARK: Table

    @ViewBuilder
    private var tableTab: some View {
        if let group = standingsGroup {
            VStack(alignment: .leading, spacing: 16) {
                if standings.count > 1, !group.name.isEmpty {
                    NuvioSectionHeader(title: group.name, inset: 20)
                }
                StandingsBoard(group: group, highlightTeamID: team.id)
                StandingsLegend(rows: group.rows)
            }
        } else {
            emptyNote("No table for this competition")
        }
    }

    // MARK: Stats

    @ViewBuilder
    private var statsTab: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let records = profile?.records, !records.isEmpty {
                section(profile?.standingSummary ?? "Record") { recordGrid(records) }
            }

            if let stats = seasonStats {
                ForEach(stats.categories) { category in
                    section(category.name) { statCard(category) }
                }
            } else if profile?.records.isEmpty ?? true {
                emptyNote("No season stats yet")
            }

            if let label = seasonStats?.seasonLabel {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 22)
            }
        }
    }

    private func statCard(_ category: TeamDetailService.StatCategory) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(category.stats.enumerated()), id: \.element.id) { index, stat in
                HStack(spacing: 12) {
                    Text(stat.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(stat.value)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                if index < category.stats.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 0.5)
                        .padding(.leading, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(NuvioTheme.card)
        )
        .padding(.horizontal, 20)
    }

    // MARK: Squad

    @ViewBuilder
    private var squadTab: some View {
        LazyVStack(alignment: .leading, spacing: 26) {
            ForEach(squadSections, id: \.title) { squadSection in
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        NuvioSectionHeader(title: squadSection.title, inset: 20)
                        Spacer(minLength: 8)
                        // Only label the age column when there are ages behind
                        // it — the NFL roster feed carries none.
                        if squadSection.players.contains(where: { $0.age != nil }) {
                            Text("Age")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.trailing, 34)
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(squadSection.players.enumerated()), id: \.element.id) { index, player in
                            squadRow(player)
                            if index < squadSection.players.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.06))
                                    .frame(height: 0.5)
                                    .padding(.leading, 68)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(NuvioTheme.card)
                    )
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private func squadRow(_ player: TeamDetailService.Player) -> some View {
        let photo = (player.headshot?.isEmpty == false) ? player.headshot! : (squadPhotos[player.name] ?? "")
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(white: 0.15))
                if photo.isEmpty {
                    Text(initials(of: player.name))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    // `size:` on CachedAsyncImage IS the frame, not a decode
                    // hint — passing 88 drew an 88pt photo inside a 44pt row,
                    // and a ZStack doesn't clip its children, so every headshot
                    // spilled over the rows above and below. The decode stays at
                    // 2× for retina via `decodeSize`.
                    CachedAsyncImage(
                        urlString: photo,
                        size: CGSize(width: 44, height: 44),
                        contentMode: .fill,
                        decodeSize: CGSize(width: 132, height: 132)
                    )
                    .clipShape(Circle())
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if let jersey = player.jersey, !jersey.isEmpty {
                        Text(jersey)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                            .monospacedDigit()
                    }
                    Text(player.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                HStack(spacing: 6) {
                    if let flag = player.flag, !flag.isEmpty {
                        CachedAsyncImage(urlString: flag,
                                         size: CGSize(width: 16, height: 16),
                                         decodeSize: CGSize(width: 48, height: 48))
                            .clipShape(Circle())
                    }
                    // Football gives a nationality, the US leagues a birth
                    // country; whichever came back is "where they're from".
                    // With neither, the position label carries the row.
                    Text(player.country ?? player.position ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let age = player.age {
                Text("\(age)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
                    .frame(width: 26, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func initials(of name: String) -> String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }

    // MARK: Shared pieces

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        chevron: Bool = false,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            NuvioSectionHeader(title: title, showsChevron: chevron, inset: 20, action: action)
            content()
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
    }

    /// The reference app's "Next match" card: date on the left, competition on
    /// the right, then home — crest — time — crest — away.
    private func nextMatchCard(_ game: ESPNEvent) -> some View {
        let live = game.status.type.state == "in"
        return Button(action: {
            guard SwipeTapGuard.tapsAllowed else { return }
            viewModel.triggerSelectionHaptic()
            openGameCard(game)
        }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(live ? game.status.type.detail : Self.dayFmt.string(from: game.gameDate))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(live ? Color.red : Color.white.opacity(0.55))
                    Spacer(minLength: 8)
                    if let network = game.broadcastName, !network.isEmpty {
                        Text(network.uppercased())
                            .font(.system(size: 10, weight: .black))
                            .kerning(0.5)
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                    }
                }

                HStack(spacing: 10) {
                    Text(game.awayCompetitor?.team?.shortDisplayName ?? "—")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    CachedAsyncImage(urlString: game.awayCompetitor?.team?.logo ?? "",
                                     size: CGSize(width: 32, height: 32))
                        .frame(width: 32, height: 32)

                    VStack(spacing: 0) {
                        if live {
                            Text("\(game.awayCompetitor?.score ?? "0")–\(game.homeCompetitor?.score ?? "0")")
                                .font(.system(size: 17, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .monospacedDigit()
                        } else {
                            Text(Self.timeFmt.string(from: game.gameDate))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(width: 58)

                    CachedAsyncImage(urlString: game.homeCompetitor?.team?.logo ?? "",
                                     size: CGSize(width: 32, height: 32))
                        .frame(width: 32, height: 32)

                    Text(game.homeCompetitor?.team?.shortDisplayName ?? "—")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(NuvioTheme.card)
            )
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
    }

    /// Last five finished games as the reference's coloured score chips, with
    /// the opponent's crest beneath each one. Oldest on the left.
    private var formStrip: some View {
        let last5 = Array(recentResults.prefix(5).reversed())
        return HStack(spacing: 10) {
            ForEach(last5) { game in
                let us = game.allCompetitions.first?.competitors?.first { $0.team?.id == team.id }
                let them = game.allCompetitions.first?.competitors?.first { $0.team?.id != team.id }
                let ourScore = Int(us?.score ?? "") ?? 0
                let theirScore = Int(them?.score ?? "") ?? 0
                let tint: Color = ourScore > theirScore ? Color.green.opacity(0.85)
                    : ourScore < theirScore ? Color.red.opacity(0.85)
                    : Color.white.opacity(0.22)

                Button(action: {
                    guard SwipeTapGuard.tapsAllowed else { return }
                    viewModel.triggerSelectionHaptic()
                    openGameCard(game)
                }) {
                    VStack(spacing: 8) {
                        // Basketball scores are three digits a side, which wrapped
                        // "134 - 136" onto two lines inside the chip. One line
                        // always, shrinking to fit, and the chip fills its column
                        // so all five stay the same width.
                        Text("\(ourScore)-\(theirScore)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint))
                        CachedAsyncImage(urlString: them?.team?.logo ?? "",
                                         size: CGSize(width: 26, height: 26))
                            .frame(width: 26, height: 26)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(NuvioTheme.card)
        )
        .padding(.horizontal, 20)
    }

    /// The team's three rows of the table, theirs highlighted — the reference's
    /// team-page table card. The section chevron opens the full standings.
    private var tableSliceCard: some View {
        VStack(spacing: 0) {
            let columns = StandingsColumns.available(in: tableSlice)
            StandingsHeaderRow(columns: columns)
            ForEach(tableSlice) { row in
                StandingsRowView(
                    row: row,
                    columns: columns,
                    isHighlighted: row.team.id == team.id,
                    // Leagues without a `rank` stat still need a position, and
                    // here it's the row's real index in the FULL table.
                    fallbackRank: standingsGroup?.rows.firstIndex(where: { $0.id == row.id }).map { $0 + 1 }
                )
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(NuvioTheme.card)
        )
        .padding(.horizontal, 20)
    }

    private func recordGrid(_ records: [TeamDetailService.RecordSplit]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            ForEach(records) { rec in
                VStack(alignment: .leading, spacing: 4) {
                    Text(rec.name.uppercased())
                        .font(.system(size: 10, weight: .black))
                        .kerning(0.5)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                    Text(rec.summary)
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(NuvioTheme.card)
                )
            }
        }
        .padding(.horizontal, 20)
    }

    /// ESPN returns a completely empty venue object for football clubs, so the
    /// stadium name and city come from the club lookup for those and from ESPN
    /// for the US leagues, whichever answered.
    private var stadiumName: String? { profile?.venueName ?? clubInfo?.stadium }
    private var stadiumLocation: String? {
        profile?.venueCity ?? clubInfo?.location ?? profile?.location
    }
    private var hasStadiumInfo: Bool {
        stadiumName != nil || stadiumLocation != nil
            || profile?.venueSurface != nil || clubInfo?.founded != nil
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let venue = stadiumName {
                infoRow(icon: "sportscourt.fill", label: "Venue", value: venue)
            }
            if let city = stadiumLocation {
                infoRow(icon: "mappin.and.ellipse", label: "Location", value: city)
            }
            if let surface = profile?.venueSurface {
                infoRow(icon: "leaf.fill", label: "Surface", value: surface)
            }
            if let founded = clubInfo?.founded {
                infoRow(icon: "calendar", label: "Founded", value: founded)
            }
            if let abbr = profile?.abbreviation ?? team.abbreviation {
                infoRow(icon: "tag.fill", label: "Abbreviation", value: abbr)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(NuvioTheme.card)
        )
        .padding(.horizontal, 20)
    }

    /// Club history, collapsed to four lines with a Read more toggle — these
    /// run to several paragraphs and would otherwise own the whole tab.
    private func aboutCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.78))
                .lineSpacing(3)
                .lineLimit(aboutExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: {
                guard SwipeTapGuard.tapsAllowed else { return }
                viewModel.triggerSelectionHaptic()
                withAnimation(.easeInOut(duration: 0.22)) { aboutExpanded.toggle() }
            }) {
                Text(aboutExpanded ? "Show less" : "Read more")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(NuvioTheme.card)
        )
        .padding(.horizontal, 20)
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(white: 0.17)))
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private func gameRow(_ game: ESPNEvent) -> some View {
        Button(action: {
            guard SwipeTapGuard.tapsAllowed else { return }
            viewModel.triggerSelectionHaptic()
            openGameCard(game)
        }) {
            TeamGameRow(game: game, dateFormatter: Self.dateFmt)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                viewModel.toggleGameRecording(game: game, sport: scoreViewModel.sportType(for: game))
            } label: {
                let isScheduled = viewModel.scheduledRecording(for: game) != nil
                Label(isScheduled ? "Cancel Recording" : "Record",
                      systemImage: isScheduled ? "stop.circle" : "record.circle")
            }
        }
    }

    /// Opens the app's existing game card, which owns the stats, the lineups
    /// and the "Watch Stream" action — no reason to rebuild any of that here.
    private func openGameCard(_ game: ESPNEvent) {
        let sport = scoreViewModel.sportType(for: game)
        scoreViewModel.deepLinkRequest = scoreViewModel.makeDetailRequest(for: game, sport: sport)
        DetailRouter.shared.close()
    }
}
