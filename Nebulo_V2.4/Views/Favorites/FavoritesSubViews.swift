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

    @State private var tab: Tab = .teams
    @State private var search = ""

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

    var body: some View {
        NavigationView {
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
                                 ? "Teams will appear once the live scoreboard loads."
                                 : "No teams match your search.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                                .listRowBackground(Color.clear)
                        } else {
                            ForEach(teamHits, id: \.team.id) { hit in
                                AddFavoriteTeamRow(
                                    team: hit.team,
                                    leagueLabel: hit.leagueLabel,
                                    isFavorite: scoreViewModel.isFavoriteTeam(hit.team),
                                    onToggle: { scoreViewModel.toggleFavoriteTeam(hit.team) }
                                )
                            }
                        }
                    } else {
                        if leagueHits.isEmpty {
                            Text("Leagues will appear once the live scoreboard loads.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                                .listRowBackground(Color.clear)
                        } else {
                            ForEach(leagueHits, id: \.displayName) { hit in
                                AddFavoriteLeagueRow(
                                    sport: hit.sport,
                                    leagueLabel: hit.leagueLabel,
                                    displayName: hit.displayName,
                                    isFavorite: scoreViewModel.isFavoriteLeague(sport: hit.sport, leagueLabel: hit.leagueLabel),
                                    onToggle: { scoreViewModel.toggleFavoriteLeague(sport: hit.sport, leagueLabel: hit.leagueLabel) }
                                )
                            }
                        }
                    }
                }
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search teams or leagues")
            }
            .navigationTitle("Add to Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationView {
            List {
                let teams = scoreViewModel.resolvedFavoriteTeams()
                let leagues = scoreViewModel.resolvedFavoriteLeagues()

                if !teams.isEmpty {
                    Section("Teams") {
                        ForEach(teams, id: \.team.id) { item in
                            FavoriteTeamCompactRow(
                                team: item.team,
                                leagueLabel: item.leagueLabel,
                                scoreViewModel: scoreViewModel
                            )
                        }
                        .onMove { source, destination in
                            scoreViewModel.moveFavoriteTeams(from: source, to: destination)
                        }
                        .onDelete { idx in
                            for i in idx { scoreViewModel.toggleFavoriteTeam(teams[i].team) }
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
            .navigationTitle("Teams & Leagues")
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
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Environment(\.dismiss) private var dismiss

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    private var games: [ESPNEvent] { scoreViewModel.gamesForTeam(team.id) }

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
        let home = game.homeCompetitor?.team?.shortDisplayName ?? game.homeCompetitor?.team?.displayName ?? ""
        let away = game.awayCompetitor?.team?.shortDisplayName ?? game.awayCompetitor?.team?.displayName ?? ""
        let sport = scoreViewModel.sportType(for: game)
        viewModel.runSmartSearch(
            gameID: game.id,
            home: home,
            away: away,
            sport: sport,
            network: game.broadcastName
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

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    /// Games for THIS league only. When a specific leagueLabel is set (e.g.
    /// "Bundesliga"), pull exclusively from that league's section in
    /// `filteredSectionsMap` — pulling from `filteredGames[sport]` would dump
    /// in every soccer game across every league.
    private var games: [ESPNEvent] {
        let pool: [ESPNEvent]
        if let label = leagueLabel {
            pool = (scoreViewModel.filteredSectionsMap[sport] ?? [])
                .filter { $0.league == label }
                .flatMap { $0.games }
        } else {
            // No specific league — use the flat sport-wide list (e.g. NFL).
            pool = scoreViewModel.filteredGames[sport] ?? []
        }
        var seen = Set<String>()
        let unique = pool.filter { seen.insert($0.id).inserted }
        return unique.sorted { a, b in
            let ra = stateRank(a.status.type.state)
            let rb = stateRank(b.status.type.state)
            if ra != rb { return ra < rb }
            return a.gameDate < b.gameDate
        }
    }

    private func stateRank(_ state: String) -> Int {
        switch state {
        case "in":   return 0  // live first
        case "pre":  return 1  // upcoming next
        case "post": return 2  // final last
        default:     return 3
        }
    }

    private var liveGames: [ESPNEvent] { games.filter { $0.status.type.state == "in" } }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Hero: league logo + name + sport
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

                    if games.isEmpty {
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
                    } else {
                        VStack(spacing: 10) {
                            ForEach(games) { game in
                                Button(action: { playFromGame(game) }) {
                                    TeamGameRow(game: game, dateFormatter: Self.dateFmt)
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
                        .padding(.horizontal, 16)
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
        }
    }

    private func playFromGame(_ game: ESPNEvent) {
        let home = game.homeCompetitor?.team?.shortDisplayName ?? game.homeCompetitor?.team?.displayName ?? ""
        let away = game.awayCompetitor?.team?.shortDisplayName ?? game.awayCompetitor?.team?.displayName ?? ""
        viewModel.runSmartSearch(
            gameID: game.id,
            home: home,
            away: away,
            sport: sport,
            network: game.broadcastName
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

            HStack(spacing: 12) {
                competitorView(game.awayCompetitor)
                Text(game.status.type.state == "pre" ? "vs" : "—")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                competitorView(game.homeCompetitor)
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

struct FavoriteTeamCompactRow: View {
    let team: ESPNTeam
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
            if let live = scoreViewModel.liveOrNextGame(forTeamID: team.id), live.status.type.state == "in" {
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("Live").font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
                }
            }
        }
    }
}
