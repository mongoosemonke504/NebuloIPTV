import SwiftUI

/// The page a favourited team opens. The hero behaves exactly like the home
/// screen's — full-bleed behind the status bar, artwork parallaxing as you
/// scroll, stretching from its bottom edge when you rubber-band past the top —
/// just without the pager, since there's only ever one team here.
///
/// Below it, the reference football app's team layout in this app's language:
/// next match, recent form, the team's own slice of the table, then the record
/// splits, results, schedule and club info. Every section is about THIS team —
/// nothing league-wide except the three table rows around them.
struct TeamDetailPage: View {
    let team: ESPNTeam
    let leagueLabel: String?
    var sport: SportType? = nil
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var profile: TeamDetailService.Profile?
    @State private var schedule: [ESPNEvent] = []
    @State private var standings: [LeagueDetailService.StandingsGroup] = []
    @State private var squad: [TeamDetailService.Player] = []
    @State private var loading = true
    @State private var showFullTable = false

    /// Same two scroll-driven leaves the home hero uses.
    @State private var heroPull = ScrollProgress()
    @State private var heroScroll = ScrollProgress()

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    private var heroHeight: CGFloat { UIScreen.main.bounds.height * 0.60 }

    // MARK: Derived

    private var displayName: String {
        profile?.displayName ?? team.displayName ?? team.shortDisplayName ?? "Team"
    }

    /// The team's brand colour: ESPN's team profile first (it carries the real
    /// hex), then whatever the scoreboard attached, then a neutral slate.
    private var brand: Color {
        let hex = profile?.color ?? team.color
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

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            AppBackground().ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    hero
                        .modifier(HeroStretch(pull: heroPull, height: heroHeight))

                    if let game = liveGame ?? nextGame {
                        section(liveGame != nil ? "Live Now" : "Next Match") {
                            nextMatchCard(game)
                        }
                    }

                    if recentResults.count >= 2 {
                        section("Form") { formStrip }
                    }

                    if !tableSlice.isEmpty {
                        section(leagueName, chevron: standingsGroup != nil) {
                            showFullTable = true
                        } content: {
                            tableSliceCard
                        }
                    }

                    if let records = profile?.records, !records.isEmpty {
                        section("Record") { recordGrid(records) }
                    }

                    if !recentResults.isEmpty {
                        section("Recent Results") {
                            VStack(spacing: 10) {
                                ForEach(recentResults.prefix(8)) { gameRow($0) }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    if upcoming.count > 1 {
                        section("Schedule") {
                            VStack(spacing: 10) {
                                ForEach(upcoming.dropFirst(liveGame == nil ? 1 : 0).prefix(12)) { gameRow($0) }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    if !squad.isEmpty {
                        section("Squad") { squadShelf }
                    }

                    if profile?.venueName != nil || profile?.location != nil {
                        section("Club Info") { infoCard }
                    }

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
            }
            // The hero bleeds behind the status bar, exactly like home's.
            .ignoresSafeArea(.container, edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, scrolled in
                heroPull.set(max(0, -scrolled))
                heroScroll.set(min(max(0, scrolled), heroHeight))
            }

            // Static chrome — the catalog page's circular back chevron.
            HStack {
                NuvioCircleButton(systemName: "chevron.left") {
                    viewModel.triggerSelectionHaptic()
                    dismiss()
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showFullTable) {
            if let group = standingsGroup {
                FullTableSheet(group: group, highlightTeamID: team.id)
            }
        }
        .task(id: team.id) {
            loading = true
            async let p = TeamDetailService.fetchProfile(sport: sport, leagueLabel: leagueLabel, teamID: team.id)
            async let s = TeamDetailService.fetchSchedule(sport: sport, leagueLabel: leagueLabel, teamID: team.id)
            async let t: [LeagueDetailService.StandingsGroup] = {
                guard let sport else { return [] }
                return await LeagueDetailService.fetchStandings(sport: sport, leagueLabel: leagueLabel)
            }()
            async let r = TeamDetailService.fetchRoster(sport: sport, leagueLabel: leagueLabel, teamID: team.id)
            profile = await p
            schedule = await s
            standings = await t
            squad = await r
            loading = false
        }
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
                CachedAsyncImage(urlString: logo ?? "", size: nil)
                    .frame(maxWidth: 150, maxHeight: 150)
                    .offset(y: -heroHeight * 0.13)
                    .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 5)
            }
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
            .modifier(HeroScrollParallax(scroll: heroScroll, baseScale: 1.14))

            // Dissolve into the canvas so the name and pill stay legible over
            // any brand colour, pale ones included.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.40),
                    .init(color: .black.opacity(0.55), location: 0.70),
                    .init(color: .black.opacity(0.96), location: 0.93),
                    .init(color: .black, location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

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
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    // MARK: Sections

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
                        Text("\(ourScore) - \(theirScore)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
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

    /// The current squad — headshot, shirt number and position, in a shelf that
    /// scrolls sideways like the rest of the app's rows.
    private var squadShelf: some View {
        TouchPassingHorizontalScroll {
            HStack(alignment: .top, spacing: 14) {
                ForEach(squad) { player in
                    VStack(spacing: 8) {
                        ZStack(alignment: .bottomTrailing) {
                            CachedAsyncImage(urlString: player.headshot ?? "", size: nil)
                                .padding(player.headshot == nil ? 16 : 0)
                                .frame(width: 66, height: 66)
                                .background(Circle().fill(Color(white: 0.15)))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                            if let jersey = player.jersey, !jersey.isEmpty {
                                Text(jersey)
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(.black)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(.white))
                            }
                        }
                        VStack(spacing: 1) {
                            Text(player.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            if let pos = player.position, !pos.isEmpty {
                                Text(pos)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 78)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 66 + 8 + 44)
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let venue = profile?.venueName {
                infoRow(icon: "sportscourt.fill", label: "Venue", value: venue)
            }
            if let city = profile?.venueCity ?? profile?.location {
                infoRow(icon: "mappin.and.ellipse", label: "Location", value: city)
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
        dismiss()
    }
}

/// The whole group's table, opened from the team page's section chevron with
/// the team's own row still highlighted.
struct FullTableSheet: View {
    let group: LeagueDetailService.StandingsGroup
    let highlightTeamID: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppBackground().ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    NuvioSectionHeader(title: group.name.isEmpty ? "Standings" : group.name, inset: 20)
                        .padding(.top, 18)
                    StandingsBoard(group: group, highlightTeamID: highlightTeamID)
                    StandingsLegend(rows: group.rows)
                    Color.clear.frame(height: 40)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
