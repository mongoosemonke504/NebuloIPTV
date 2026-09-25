import SwiftUI

// MARK: - Reorder favorite channels sheet

/// Drag-to-reorder list for the user's favorite channels. Persists via
/// `ChannelViewModel.moveFavoriteChannels`. Uses the system `List` reorder
/// affordance because it ships drag/drop, accessibility, and haptics for free.
struct ReorderFavoriteChannelsSheet: View {
    @ObservedObject var viewModel: ChannelViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                
                
                ForEach(viewModel.orderedFavoriteChannels()) { channel in
                    HStack(spacing: 12) {
                        if let icon = channel.icon, !icon.isEmpty {
                            CachedAsyncImage(urlString: icon, size: CGSize(width: 36, height: 36))
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 36, height: 36)
                        }
                        Text(channel.name).lineLimit(1)
                    }
                }
                .onMove { source, destination in
                    viewModel.moveFavoriteChannels(from: source, to: destination)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Add favorite sheet (teams + leagues)

/// Two-tab picker so the user can browse every team / league the ESPN
/// scoreboard has surfaced this session and toggle favorites on each one.
struct AddFavoriteSheet: View {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("nebColor1") private var nebColor1 = "#1A2538"
    @AppStorage("nebColor2") private var nebColor2 = "#11101A"
    @AppStorage("nebColor3") private var nebColor3 = "#1F1A24"
    @AppStorage("nebX1") private var nebX1 = 0.5
    @AppStorage("nebY1") private var nebY1 = 0.0
    @AppStorage("nebX2") private var nebX2 = 0.5
    @AppStorage("nebY2") private var nebY2 = 0.5
    @AppStorage("nebX3") private var nebX3 = 0.5
    @AppStorage("nebY3") private var nebY3 = 1.0

    @State private var tab: Tab = .teams
    @State private var search = ""
    /// Leagues the user has opened in the Teams tab. Collapsed by default so
    /// the full catalog reads as a compact league index; searching expands
    /// every matching section automatically.
    @State private var expandedLeagues: Set<String> = []

    enum Tab: String, CaseIterable, Identifiable {
        case teams = "Teams", leagues = "Leagues"
        var id: String { rawValue }
    }

    private var teamHits: [(team: ESPNTeam, sport: SportType, leagueLabel: String?)] {
        let all = scoreViewModel.allKnownTeams()
        guard !search.isEmpty else { return all }
        let lower = search.lowercased()
        return all.filter { hit in
            (hit.team.displayName ?? "").lowercased().contains(lower)
            || (hit.team.shortDisplayName ?? "").lowercased().contains(lower)
            || (hit.team.abbreviation ?? "").lowercased().contains(lower)
            || (hit.leagueLabel ?? "").lowercased().contains(lower)
        }
    }

    private var leagueHits: [(sport: SportType, leagueLabel: String?, displayName: String)] {
        let all = scoreViewModel.allKnownLeagues()
        guard !search.isEmpty else { return all }
        let lower = search.lowercased()
        return all.filter { $0.displayName.lowercased().contains(lower) || $0.sport.rawValue.lowercased().contains(lower) }
    }

    /// Display rank for each league section: soccer competitions first in
    /// catalog order (leagues → cups → continental → international), then
    /// the standalone sports in the user's Sports-hub tab order. Unranked
    /// labels (future additions) sort alphabetically at the end.
    private var leagueRank: [String: Int] {
        var rank: [String: Int] = [:]
        var i = 0
        for (_, competitions) in SportType.soccerCompetitionGroups {
            for comp in competitions where rank[comp.name] == nil {
                rank[comp.name] = i; i += 1
            }
        }
        for sport in scoreViewModel.orderedSports where !sport.isSoccer && rank[sport.rawValue] == nil {
            rank[sport.rawValue] = i; i += 1
        }
        return rank
    }

    /// Teams grouped into per-league sections so the full catalog stays
    /// browsable. Grouping also keeps ForEach ids unique — ESPN team ids
    /// repeat across sports, but never within one league.
    private var groupedTeamHits: [(label: String, sport: SportType, leagueLabel: String?, teams: [(team: ESPNTeam, sport: SportType, leagueLabel: String?)])] {
        let rank = leagueRank
        return Dictionary(grouping: teamHits) { $0.leagueLabel ?? $0.sport.rawValue }
            .map { (label: $0.key, sport: $0.value.first?.sport ?? .nfl, leagueLabel: $0.value.first?.leagueLabel, teams: $0.value) }
            .sorted {
                let ra = rank[$0.label] ?? Int.max
                let rb = rank[$1.label] ?? Int.max
                return ra == rb ? $0.label < $1.label : ra < rb
            }
    }

    /// Leagues grouped into sections: each soccer bucket keeps its own
    /// section (in catalog order), every standalone sport lands in "Sports".
    private var groupedLeagueHits: [(label: String, leagues: [(sport: SportType, leagueLabel: String?, displayName: String)])] {
        var sections: [(label: String, leagues: [(sport: SportType, leagueLabel: String?, displayName: String)])] = []
        var index: [String: Int] = [:]
        for hit in leagueHits {
            let label = hit.sport.isSoccer ? hit.sport.rawValue : "Sports"
            if let i = index[label] {
                sections[i].leagues.append(hit)
            } else {
                index[label] = sections.count
                sections.append((label, [hit]))
            }
        }
        return sections
    }

    var body: some View {
        NavigationView {
            ZStack {
                NebulaBackgroundView(
                    color1: Color(hex: nebColor1) ?? .purple,
                    color2: Color(hex: nebColor2) ?? .blue,
                    color3: Color(hex: nebColor3) ?? .pink,
                    point1: UnitPoint(x: nebX1, y: nebY1),
                    point2: UnitPoint(x: nebX2, y: nebY2),
                    point3: UnitPoint(x: nebX3, y: nebY3)
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                List {
                    if tab == .teams {
                        if teamHits.isEmpty {
                            Text(scoreViewModel.allKnownTeams().isEmpty
                                 ? "Loading the team catalog…"
                                 : "No teams match your search.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                                .listRowBackground(Color.clear)
                        } else {
                            ForEach(groupedTeamHits, id: \.label) { group in
                                let isExpanded = !search.isEmpty || expandedLeagues.contains(group.label)
                                Section {
                                    if isExpanded {
                                        ForEach(group.teams, id: \.team.id) { hit in
                                            AddFavoriteTeamRow(
                                                team: hit.team,
                                                leagueLabel: hit.leagueLabel,
                                                isFavorite: scoreViewModel.isFavoriteTeam(hit.team, sport: hit.sport),
                                                onToggle: { scoreViewModel.toggleFavoriteTeam(hit.team, sport: hit.sport) }
                                            )
                                            .listRowBackground(Color.black.opacity(0.35))
                                        }
                                    }
                                } header: {
                                    // The header IS the disclosure control:
                                    // tap to expand/collapse the league.
                                    Button {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            if expandedLeagues.contains(group.label) {
                                                expandedLeagues.remove(group.label)
                                            } else {
                                                expandedLeagues.insert(group.label)
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 8) {
                                            if let logo = LeagueLogoURL.url(sport: group.sport, leagueLabel: group.leagueLabel) {
                                                CachedAsyncImage(urlString: logo, size: CGSize(width: 20, height: 20))
                                            }
                                            Text(group.label)
                                            Text("\(group.teams.count)")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                            Spacer()
                                            if search.isEmpty {
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 11, weight: .bold))
                                                    .foregroundStyle(.secondary)
                                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!search.isEmpty)
                                }
                            }
                        }
                    } else {
                        if leagueHits.isEmpty {
                            Text("No leagues match your search.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                                .listRowBackground(Color.clear)
                        } else {
                            ForEach(groupedLeagueHits, id: \.label) { group in
                                Section(group.label) {
                                    ForEach(group.leagues, id: \.displayName) { hit in
                                        AddFavoriteLeagueRow(
                                            sport: hit.sport,
                                            leagueLabel: hit.leagueLabel,
                                            displayName: hit.displayName,
                                            isFavorite: scoreViewModel.isFavoriteLeague(sport: hit.sport, leagueLabel: hit.leagueLabel),
                                            onToggle: { scoreViewModel.toggleFavoriteLeague(sport: hit.sport, leagueLabel: hit.leagueLabel) }
                                        )
                                        .listRowBackground(Color.black.opacity(0.35))
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                }
            }
            // Search rides at the bottom in the same glass pill the home
            // screen uses, instead of the system navigation-bar drawer.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("Search teams or leagues", text: $search)
                        .font(.body.weight(.medium))
                        .autocorrectionDisabled()
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .modifier(GlassEffect(cornerRadius: 100, isSelected: false, accentColor: nil))
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
            .navigationTitle("Add to Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct AddFavoriteTeamRow: View {
    let team: ESPNTeam
    let leagueLabel: String?
    let isFavorite: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                FavoriteSquareLogo(logo: team.logo, abbreviation: team.abbreviation ?? team.displayName ?? "•", color: team.color)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.displayName ?? team.shortDisplayName ?? "Unknown team")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let l = leagueLabel {
                        Text(l)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isFavorite ? Color.pink : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AddFavoriteLeagueRow: View {
    let sport: SportType
    let leagueLabel: String?
    let displayName: String
    let isFavorite: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                FavoriteSquareLogo(
                    logo: LeagueLogoURL.url(sport: sport, leagueLabel: leagueLabel),
                    abbreviation: displayName,
                    color: nil
                )
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(sport.rawValue)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isFavorite ? Color.pink : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - See All teams view

/// Full list of every favorited team and league with the same rendering
/// vocabulary as the FavoritesView shelf. Reorder is enabled via a system
/// edit mode so the user can curate their starting lineup.
struct FavoritesAllTeamsView: View {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss
    /// Opens READY to drag. The reordering was always here, behind an Edit
    /// button that had to be found first — which is why it read as missing.
    @State private var editMode: EditMode = .active

    var body: some View {
        NavigationView {
            List {
                let teams = scoreViewModel.resolvedFavoriteTeams()
                let leagues = scoreViewModel.resolvedFavoriteLeagues()

                if !teams.isEmpty {
                    Section("Teams") {
                        // Positional ids: team ids alone can repeat across
                        // sports, and move/delete already work off indices.
                        ForEach(Array(teams.enumerated()), id: \.offset) { _, item in
                            FavoriteTeamCompactRow(
                                team: item.team,
                                sport: item.sport,
                                leagueLabel: item.leagueLabel,
                                scoreViewModel: scoreViewModel
                            )
                        }
                        .onMove { source, destination in
                            scoreViewModel.moveFavoriteTeams(from: source, to: destination)
                        }
                        .onDelete { idx in
                            for i in idx { scoreViewModel.toggleFavoriteTeam(teams[i].team, sport: teams[i].sport) }
                        }
                    }
                }

                if !leagues.isEmpty {
                    Section("Leagues") {
                        ForEach(leagues, id: \.displayName) { item in
                            HStack(spacing: 12) {
                                FavoriteSquareLogo(
                                    logo: LeagueLogoURL.url(sport: item.sport, leagueLabel: item.leagueLabel),
                                    abbreviation: item.displayName,
                                    color: nil
                                )
                                .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName).font(.system(size: 15, weight: .semibold))
                                    Text(item.sport.rawValue).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onMove { source, destination in
                            scoreViewModel.moveFavoriteLeagues(from: source, to: destination)
                        }
                        .onDelete { idx in
                            for i in idx {
                                let l = leagues[i]
                                scoreViewModel.toggleFavoriteLeague(sport: l.sport, leagueLabel: l.leagueLabel)
                            }
                        }
                    }
                }

                if teams.isEmpty && leagues.isEmpty {
                    Text("No teams or leagues yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Reorder Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode.isEditing ? "Done" : "Edit") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                }
            }
        }
    }
}

// MARK: - Team next games sheet

/// Surfaces every known game for a favorited team — live + upcoming + past —
/// each tappable to launch the channel-matching smart search. Pulls from the
/// ScoreViewModel's master game pool via `gamesForTeam(_:)`.
struct TeamNextGamesSheet: View {
    let team: ESPNTeam
    let leagueLabel: String?
    var sport: SportType? = nil
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Environment(\.dismiss) private var dismiss

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    private var games: [ESPNEvent] {
        scoreViewModel.gamesForTeam(ScoreViewModel.teamKey(sport: sport, teamID: team.id))
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Hero: team logo + name + league
                    VStack(spacing: 10) {
                        FavoriteSquareLogo(
                            logo: team.logo,
                            abbreviation: team.abbreviation ?? team.displayName ?? "•",
                            color: team.color
                        )
                        .frame(width: 76, height: 76)
                        Text(team.displayName ?? team.shortDisplayName ?? "Unknown team")
                            .font(.system(size: 22, weight: .bold))
                            .multilineTextAlignment(.center)
                        if let league = leagueLabel {
                            Text(league)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    if games.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "calendar.badge.exclamationmark")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("No games on the schedule")
                                .font(.headline)
                            Text("ESPN hasn't surfaced any matches for this team in the current window. Check back closer to game time.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        .padding(.vertical, 36)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(games) { game in
                                Button(action: { playFromGame(game) }) {
                                    TeamGameRow(game: game, dateFormatter: Self.dateFmt)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    let sport = scoreViewModel.sportType(for: game)
                                    Button {
                                        viewModel.toggleGameRecording(game: game, sport: sport)
                                    } label: {
                                        let isScheduled = viewModel.scheduledRecording(for: game) != nil
                                        Label(isScheduled ? "Cancel Recording" : "Record",
                                              systemImage: isScheduled ? "stop.circle" : "record.circle")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    Color.clear.frame(height: 24)
                }
            }
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func playFromGame(_ game: ESPNEvent) {
        // `searchTerms` rather than the competitors: it already knows that a
        // golf tournament or a race weekend has no two sides, and returns the
        // EVENT's name. Reading team names directly gave those two empty
        // strings — golf competitors are athletes, with no team at all — so a
        // favourite golfer's Watch searched for nothing.
        let terms = game.searchTerms
        let sport = scoreViewModel.sportType(for: game)
        viewModel.runSmartSearch(
            gameID: game.id,
            home: terms.home,
            away: terms.away,
            sport: sport,
            network: game.streamNetworkHint,
            event: game
        )
        dismiss()
    }
}

// MARK: - League games sheet

/// Sheet presented when a favorited league row is tapped. Shows live games at
/// the top followed by upcoming, then completed. Tapping any row runs the
/// smart-search/play flow.
struct LeagueGamesSheet: View {
    let sport: SportType
    let leagueLabel: String?
    let displayName: String
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Environment(\.dismiss) private var dismiss

    /// Wide-window schedule (recent results + upcoming fixtures) fetched on
    /// appear; the session pool covers the gap while it loads or if it fails.
    @State private var schedule: [ESPNEvent] = []
    @State private var standings: [LeagueDetailService.StandingsGroup] = []
    @State private var isLoadingDetail = true
    @State private var mode: DetailMode = .matches

    enum DetailMode: String, CaseIterable, Identifiable {
        case matches, standings, bracket
        var id: String { rawValue }
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    // MARK: Data

    /// Today's games from the session pool — instant content while the wide
    /// window loads, and the fallback if that fetch fails.
    private var sessionGames: [ESPNEvent] {
        let pool: [ESPNEvent]
        if let label = leagueLabel {
            pool = (scoreViewModel.filteredSectionsMap[sport] ?? [])
                .filter { $0.league == label }
                .flatMap { $0.games }
        } else {
            pool = scoreViewModel.filteredGames[sport] ?? []
        }
        var seen = Set<String>()
        return pool.filter { seen.insert($0.id).inserted }
    }

    private var games: [ESPNEvent] { schedule.isEmpty ? sessionGames : schedule }

    private var liveGames: [ESPNEvent] { games.filter { $0.status.type.state == "in" } }
    private var upcomingGames: [ESPNEvent] {
        games.filter { $0.status.type.state == "pre" }.sorted { $0.gameDate < $1.gameDate }
    }
    private var finishedGames: [ESPNEvent] {
        games.filter { $0.status.type.state == "post" }.sorted { $0.gameDate > $1.gameDate }
    }

    // MARK: Tournament structure

    /// True for slugs that name a knockout phase ("round-of-16",
    /// "semifinals", "final", "3rd-place-match", playoff rounds…) as opposed
    /// to group/regular-season play.
    private func isKnockoutSlug(_ slug: String?) -> Bool {
        guard let s = slug?.lowercased() else { return false }
        if s.contains("group") || s.contains("regular") { return false }
        return s.contains("round-of") || s.contains("quarterfinal") || s.contains("semifinal")
            || s.contains("final") || s.contains("place") || s.contains("playoff") || s.contains("knockout")
    }

    private var knockoutGames: [ESPNEvent] { games.filter { isKnockoutSlug($0.season?.slug) } }

    /// Distinct knockout rounds ordered by earliest kickoff — the Round of
    /// 16 lands before the Quarterfinals with no hardcoded round list to
    /// maintain when ESPN adds new formats.
    private var knockoutRounds: [(name: String, games: [ESPNEvent])] {
        var buckets: [String: [ESPNEvent]] = [:]
        for game in knockoutGames {
            guard let slug = game.season?.slug else { continue }
            buckets[slug, default: []].append(game)
        }
        return buckets
            .sorted { a, b in
                let da = a.value.map(\.gameDate).min() ?? .distantFuture
                let db = b.value.map(\.gameDate).min() ?? .distantFuture
                return da < db
            }
            .map { (roundName($0.key), $0.value.sorted { $0.gameDate < $1.gameDate }) }
    }

    /// True when the schedule carries tournament phases (groups/knockouts).
    private var isTournament: Bool {
        !knockoutGames.isEmpty || games.contains { ($0.season?.slug ?? "").lowercased().contains("group") }
    }

    /// "round-of-16" → "Round of 16", "3rd-place-match" → "3rd Place Match".
    private func roundName(_ slug: String) -> String {
        slug.split(separator: "-")
            .map { $0 == "of" ? "of" : $0.capitalized }
            .joined(separator: " ")
    }

    /// Round caption for a match row — only tournament phases, never the
    /// season name of regular league play.
    private func roundLabel(for game: ESPNEvent) -> String? {
        guard isTournament, let slug = game.season?.slug else { return nil }
        let s = slug.lowercased()
        guard s.contains("group") || isKnockoutSlug(s) else { return nil }
        return roundName(slug)
    }

    private var availableModes: [DetailMode] {
        var modes: [DetailMode] = [.matches]
        if !standings.isEmpty { modes.append(.standings) }
        if !knockoutGames.isEmpty { modes.append(.bracket) }
        return modes
    }

    private func title(for mode: DetailMode) -> String {
        switch mode {
        case .matches:   return "Matches"
        case .standings: return standings.count > 1 ? "Groups" : "Table"
        case .bracket:   return "Bracket"
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    hero

                    if availableModes.count > 1 {
                        Picker("", selection: $mode) {
                            ForEach(availableModes) { m in
                                Text(title(for: m)).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                    }

                    switch mode {
                    case .matches:   matchesContent
                    case .standings: standingsContent
                    case .bracket:   bracketContent
                    }

                    Color.clear.frame(height: 24)
                }
            }
            .navigationTitle("Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                async let sched = LeagueDetailService.fetchSchedule(sport: sport, leagueLabel: leagueLabel)
                async let stand = LeagueDetailService.fetchStandings(sport: sport, leagueLabel: leagueLabel)
                let (s, st) = await (sched, stand)
                schedule = s
                standings = st
                isLoadingDetail = false
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 10) {
            FavoriteSquareLogo(
                logo: LeagueLogoURL.url(sport: sport, leagueLabel: leagueLabel),
                abbreviation: abbreviationFor(displayName),
                color: nil
            )
            .frame(width: 76, height: 76)
            Text(displayName)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
            Text(sport.rawValue)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if !liveGames.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("\(liveGames.count) live now")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: Matches (live → upcoming fixtures → recent results)

    @ViewBuilder private var matchesContent: some View {
        if games.isEmpty {
            if isLoadingDetail {
                ProgressView()
                    .padding(.vertical, 48)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No games on the schedule")
                        .font(.headline)
                    Text("ESPN hasn't surfaced any matches for this league in the current window. Check back closer to game time.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.vertical, 36)
            }
        } else {
            VStack(spacing: 20) {
                if !liveGames.isEmpty { matchSection("Live Now", liveGames) }
                if !upcomingGames.isEmpty { matchSection("Upcoming", upcomingGames) }
                if !finishedGames.isEmpty { matchSection("Results", finishedGames) }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private func matchSection(_ sectionTitle: String, _ sectionGames: [ESPNEvent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sectionTitle.uppercased())
                .font(.system(size: 12, weight: .black))
                .kerning(0.8)
                .foregroundStyle(.secondary)
            ForEach(sectionGames) { game in
                Button(action: { playFromGame(game) }) {
                    TeamGameRow(game: game, dateFormatter: Self.dateFmt, roundLabel: roundLabel(for: game))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        viewModel.toggleGameRecording(game: game, sport: sport)
                    } label: {
                        let isScheduled = viewModel.scheduledRecording(for: game) != nil
                        Label(isScheduled ? "Cancel Recording" : "Record",
                              systemImage: isScheduled ? "stop.circle" : "record.circle")
                    }
                }
            }
        }
    }

    // MARK: Standings (league table, or tournament group tables)

    /// Shares the league page's board so a table looks — and picks its columns
    /// — the same everywhere. The old card hard-coded football's PL/W/D/L/GD/PTS,
    /// which made the MLB table meaningless.
    @ViewBuilder private var standingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(standings) { group in
                if standings.count > 1 {
                    Text(group.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                }
                StandingsBoard(group: group)
            }
            StandingsLegend(rows: standings.flatMap { $0.rows })
        }
    }

    // MARK: Bracket (knockout rounds as horizontally scrolling columns)

    @ViewBuilder private var bracketContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 14) {
                ForEach(knockoutRounds, id: \.name) { round in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(round.name.uppercased())
                            .font(.system(size: 11, weight: .black))
                            .kerning(0.8)
                            .foregroundStyle(.secondary)
                        ForEach(round.games) { game in
                            Button(action: { playFromGame(game) }) {
                                BracketMatchCard(game: game)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func playFromGame(_ game: ESPNEvent) {
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
            sport: sport,
            network: game.streamNetworkHint,
            event: game
        )
        dismiss()
    }

    private func abbreviationFor(_ s: String) -> String {
        let parts = s.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return parts.prefix(3).map { String($0.prefix(1)) }.joined().uppercased()
        }
        return String(s.prefix(3)).uppercased()
    }
}

/// Single row inside the team detail sheet. Shows both competitors with score
/// (or scheduled time for upcoming games) and a state pill.
struct TeamGameRow: View {
    let game: ESPNEvent
    let dateFormatter: DateFormatter
    /// Tournament phase caption ("Group Stage", "Round of 16") — nil for
    /// regular league play.
    var roundLabel: String? = nil

    private var stateLabel: String {
        switch game.status.type.state {
        case "in": return "LIVE"
        case "post": return "FT"
        default: return "UPCOMING"
        }
    }

    private var stateColor: Color {
        switch game.status.type.state {
        case "in": return .red
        case "post": return .gray
        default: return .blue
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                stateBadge
                if let round = roundLabel {
                    Text(round)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .lineLimit(1)
                }
                Spacer()
                if game.status.type.state == "in" {
                    Text(game.status.type.detail.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                } else if game.status.type.state == "pre" {
                    Text(dateFormatter.string(from: game.gameDate))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Final")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            // A Grand Prix and a golf tournament have no two sides to split a
            // row between — ESPN gives them a field of athletes with no team,
            // so the matchup layout drew two blank crests either side of a
            // "vs". Both get a leaderboard instead, the score under the name.
            // Dispatched off the event's own shape, exactly like LiveEventCard.
            if game.isRaceEvent {
                fieldBoard(entries: raceOrder, caption: raceCaption, parColored: false)
            } else if game.isFieldEvent {
                fieldBoard(entries: leaderboard, caption: nil, parColored: true)
            } else {
                HStack(spacing: 12) {
                    competitorView(game.awayCompetitor)
                    Text(game.status.type.state == "pre" ? "vs" : "—")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                    competitorView(game.homeCompetitor)
                }
            }

            if let network = game.broadcastName, !network.isEmpty {
                HStack {
                    Text(network)
                        .font(.system(size: 10, weight: .black))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var stateBadge: some View {
        HStack(spacing: 4) {
            if game.status.type.state == "in" {
                Circle().fill(Color.red).frame(width: 6, height: 6)
            }
            Text(stateLabel)
                .font(.system(size: 10, weight: .black))
                .kerning(0.6)
        }
        .foregroundStyle(stateColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(stateColor.opacity(0.15), in: Capsule())
    }

    /// The session with a result worth showing — the one running, else the
    /// last one that finished. Same rule the Live Now race card uses.
    private var raceSession: ESPNEvent.RaceSession? {
        let current = game.currentRaceSession
        if current?.state == "in" { return current }
        return game.latestFinishedRaceSession ?? current
    }

    private var raceOrder: [ESPNCompetitor] { raceSession?.order ?? [] }

    private var raceCaption: String? {
        guard let raceSession else { return nil }
        return ScoreRow.sessionName(raceSession.label)
    }

    private var leaderboard: [ESPNCompetitor] {
        (game.allCompetitions.first?.competitors ?? [])
            .sorted { ($0.order ?? 999) < ($1.order ?? 999) }
    }

    /// Under par green, over par red — golf's own convention.
    private static func parColor(_ total: String?) -> Color {
        guard let total, !total.isEmpty else { return .primary }
        if total.hasPrefix("-") { return Color(red: 0.30, green: 0.75, blue: 0.40) }
        if total.hasPrefix("+") { return Color(red: 0.90, green: 0.35, blue: 0.30) }
        return .primary
    }

    private static func entrantName(_ c: ESPNCompetitor) -> String {
        c.athlete?.shortName ?? c.athlete?.displayName
            ?? c.team?.shortDisplayName ?? c.team?.displayName ?? "—"
    }

    /// The event, then its top three with each score sitting on that
    /// entrant's own line.
    @ViewBuilder
    private func fieldBoard(entries: [ESPNCompetitor], caption: String?, parColored: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(game.shortName)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let caption {
                    Text(caption.uppercased())
                        .font(.system(size: 9, weight: .black))
                        .kerning(0.4)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if entries.isEmpty {
                Text(game.status.type.state == "pre" ? "Field not confirmed yet" : "No leaderboard yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(entries.prefix(3).enumerated()), id: \.offset) { index, entrant in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 13, alignment: .leading)
                        Text(Self.entrantName(entrant))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let score = entrant.score, !score.isEmpty {
                            Text(score)
                                .font(.system(size: 13, weight: .heavy))
                                .monospacedDigit()
                                .foregroundStyle(parColored ? Self.parColor(score) : Color.primary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func competitorView(_ c: ESPNCompetitor?) -> some View {
        VStack(spacing: 4) {
            if let logo = c?.team?.logo, !logo.isEmpty {
                CachedAsyncImage(urlString: logo, size: CGSize(width: 36, height: 36))
                    .frame(width: 36, height: 36)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(c?.team?.abbreviation ?? "?")
                            .font(.system(size: 11, weight: .bold))
                    )
            }
            Text(c?.team?.shortDisplayName ?? c?.team?.abbreviation ?? "—")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if let score = c?.score, !score.isEmpty, game.status.type.state != "pre" {
                Text(score)
                    .font(.system(size: 18, weight: .black))
            }
        }
        .frame(maxWidth: .infinity)
    }
}


// MARK: - Bracket match card

/// Compact matchup card used in the knockout bracket columns.
struct BracketMatchCard: View {
    let game: ESPNEvent

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d · h:mm a"; return f
    }()

    private var footer: String {
        switch game.status.type.state {
        case "in":   return game.status.type.detail
        case "post": return "Final"
        default:     return Self.fmt.string(from: game.gameDate)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            teamLine(game.awayCompetitor)
            teamLine(game.homeCompetitor)
            HStack(spacing: 4) {
                if game.status.type.state == "in" {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                }
                Text(footer)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(game.status.type.state == "in" ? Color.red : Color.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(width: 168, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    @ViewBuilder private func teamLine(_ c: ESPNCompetitor?) -> some View {
        let finished = game.status.type.state == "post"
        let won = c?.winner == true
        HStack(spacing: 7) {
            if let logo = c?.team?.logo, !logo.isEmpty {
                CachedAsyncImage(urlString: logo, size: CGSize(width: 18, height: 18))
            } else {
                Circle().fill(Color.secondary.opacity(0.2)).frame(width: 18, height: 18)
            }
            Text(c?.team?.shortDisplayName ?? c?.team?.abbreviation ?? "TBD")
                .font(.system(size: 12, weight: won ? .bold : .semibold))
                .foregroundStyle(!finished || won ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let score = c?.score, !score.isEmpty, game.status.type.state != "pre" {
                Text(score)
                    .font(.system(size: 13, weight: won ? .black : .semibold).monospacedDigit())
                    .foregroundStyle(!finished || won ? Color.primary : Color.secondary)
            }
        }
    }
}

struct FavoriteTeamCompactRow: View {
    let team: ESPNTeam
    var sport: SportType? = nil
    let leagueLabel: String?
    @ObservedObject var scoreViewModel: ScoreViewModel

    var body: some View {
        HStack(spacing: 12) {
            FavoriteSquareLogo(logo: team.logo, abbreviation: team.abbreviation ?? team.displayName ?? "•", color: team.color)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(team.displayName ?? team.shortDisplayName ?? "Unknown team")
                    .font(.system(size: 15, weight: .semibold))
                if let l = leagueLabel {
                    Text(l).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let live = scoreViewModel.liveOrNextGame(forTeamID: ScoreViewModel.teamKey(sport: sport, teamID: team.id)),
               live.status.type.state == "in" {
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("Live").font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
                }
            }
        }
    }
}
