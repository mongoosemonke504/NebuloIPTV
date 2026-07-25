import SwiftUI

// MARK: - Shared standings pieces

/// Which stat columns a table shows. Football and the US leagues keep score in
/// completely different currencies, and forcing one column set on both is what
/// made the MLB table nonsense: every rank was "–", every D was 0, and "PTS"
/// was showing games-behind to one decimal place.
///
/// So there are two sets, chosen by a stat only the US leagues report —
/// `gamesBehind`. Football gets PL/W/D/L/GD/PTS; baseball, basketball, hockey
/// and football(US) get W/L/PCT/GB. Within a set, a column still drops out if
/// the league didn't supply it at all.
enum StandingsColumns {
    struct Column: Identifiable {
        let id: String
        let header: String
        let width: CGFloat
        let value: (LeagueDetailService.StandingRow) -> String
    }

    private static let soccer: [Column] = [
        Column(id: "PL",  header: "PL",  width: 28) { $0.played },
        Column(id: "W",   header: "W",   width: 24) { $0.wins },
        Column(id: "D",   header: "D",   width: 24) { $0.draws },
        Column(id: "L",   header: "L",   width: 24) { $0.losses },
        Column(id: "GD",  header: "GD",  width: 34) { $0.goalDiff },
        Column(id: "PTS", header: "PTS", width: 34) { $0.points }
    ]

    private static let american: [Column] = [
        Column(id: "W",    header: "W",   width: 30) { $0.wins },
        Column(id: "L",    header: "L",   width: 30) { $0.losses },
        Column(id: "PCT",  header: "PCT", width: 42) { $0.winPercent },
        Column(id: "DIFF", header: "DIFF", width: 42) { $0.goalDiff },
        Column(id: "GB",   header: "GB",  width: 36) { $0.gamesBehind }
    ]

    static func available(in rows: [LeagueDetailService.StandingRow]) -> [Column] {
        let isAmerican = rows.contains { $0.gamesBehind != "–" }
        let set = isAmerican ? american : soccer
        return set.filter { col in rows.contains { col.value($0) != "–" } }
    }
}

/// The grey column-header strip above a table.
struct StandingsHeaderRow: View {
    let columns: [StandingsColumns.Column]

    var body: some View {
        HStack(spacing: 6) {
            Text("#").frame(width: 22, alignment: .leading)
            Text("Team").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { col in
                Text(col.header)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: col.width, alignment: .trailing)
            }
        }
        .font(.system(size: 10, weight: .black))
        .foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// One table row. `isHighlighted` is the team you came in for, which the
/// reference app tints so you can find yourself at a glance.
struct StandingsRowView: View {
    let row: LeagueDetailService.StandingRow
    let columns: [StandingsColumns.Column]
    var isHighlighted: Bool = false
    /// Position to print when ESPN gives no `rank` stat — MLB doesn't, which
    /// is why every row in the baseball table read "–". The rows arrive
    /// pre-sorted, so their index IS the standing.
    var fallbackRank: Int? = nil

    private var zoneColor: Color? {
        guard let hex = row.noteColor, !hex.isEmpty else { return nil }
        return Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)")
    }

    private var rankText: String {
        if row.rank != "–", !row.rank.isEmpty { return row.rank }
        if let fallbackRank { return String(fallbackRank) }
        return "–"
    }

    /// The emphasised column: points in football, win percentage in the US.
    private var leadColumn: String { columns.contains { $0.id == "PTS" } ? "PTS" : "PCT" }

    var body: some View {
        HStack(spacing: 6) {
            Text(rankText)
                .frame(width: 22, alignment: .leading)
                .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 8) {
                CachedAsyncImage(urlString: row.team.logo ?? "", size: CGSize(width: 20, height: 20))
                    .frame(width: 20, height: 20)
                Text(row.team.shortDisplayName ?? row.team.displayName ?? "—")
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { col in
                Text(col.value(row))
                    .foregroundStyle(col.id == leadColumn ? .white : .white.opacity(0.75))
                    .fontWeight(col.id == leadColumn ? .bold : .regular)
                    .monospacedDigit()
                    // MLB plays 100+ games, so a fixed narrow cell wrapped
                    // "103" onto two lines. Never wrap a stat.
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: col.width, alignment: .trailing)
            }
        }
        .font(.system(size: 13, weight: isHighlighted ? .bold : .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isHighlighted ? Color.white.opacity(0.07) : Color.clear)
        // The qualification zone bar ESPN colours: promotion, continental
        // places, relegation.
        .overlay(alignment: .leading) {
            if let zoneColor {
                Rectangle()
                    .fill(zoneColor)
                    .frame(width: 3)
            }
        }
    }
}

/// A whole standings group as one card.
struct StandingsBoard: View {
    let group: LeagueDetailService.StandingsGroup
    var highlightTeamID: String? = nil

    var body: some View {
        let columns = StandingsColumns.available(in: group.rows)
        VStack(spacing: 0) {
            StandingsHeaderRow(columns: columns)
            ForEach(Array(group.rows.enumerated()), id: \.element.id) { idx, row in
                StandingsRowView(
                    row: row,
                    columns: columns,
                    isHighlighted: row.team.id == highlightTeamID,
                    fallbackRank: idx + 1
                )
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(NuvioTheme.card)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 20)
    }
}

/// Key for the coloured zone bars — "Champions League", "Europa League",
/// "Relegation" — built from whatever notes ESPN actually attached.
struct StandingsLegend: View {
    let rows: [LeagueDetailService.StandingRow]

    private var entries: [(color: Color, text: String)] {
        var seen = Set<String>()
        var out: [(Color, String)] = []
        for row in rows {
            guard let hex = row.noteColor, !hex.isEmpty,
                  let text = row.noteText, !text.isEmpty,
                  seen.insert(text).inserted,
                  let c = Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)") else { continue }
            out.append((c, text))
        }
        return out
    }

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(entries, id: \.text) { entry in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(entry.color)
                            .frame(width: 14, height: 14)
                        Text(entry.text)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 22)
        }
    }
}

// MARK: - League page

/// The page a favourited LEAGUE opens: the reference football app's league
/// screen in this app's language — a full-bleed hero carrying the competition
/// crest, then Table / Fixtures / Results as chips, with the standings (zone
/// bars and legend included) and the fixture list grouped by date.
struct LeagueDetailPage: View {
    let sport: SportType
    let leagueLabel: String?
    let displayName: String
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case table = "Table", fixtures = "Fixtures", results = "Results"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .table
    @State private var standings: [LeagueDetailService.StandingsGroup] = []
    @State private var schedule: [ESPNEvent] = []
    @State private var loading = true

    @State private var heroPull = ScrollProgress()
    @State private var heroScroll = ScrollProgress()

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    private static let dayHeaderFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()

    /// Shallower than the team hero — a crest on a flat field doesn't need the
    /// full 60% of the screen the artwork-backed heroes use.
    private var heroHeight: CGFloat { UIScreen.main.bounds.height * 0.42 }

    private var logo: String? { LeagueLogoURL.url(sport: sport, leagueLabel: leagueLabel) }

    private var liveGames: [ESPNEvent] { schedule.filter { $0.status.type.state == "in" } }

    private var upcoming: [ESPNEvent] {
        schedule.filter { $0.status.type.state == "pre" }.sorted { $0.gameDate < $1.gameDate }
    }

    private var results: [ESPNEvent] {
        schedule.filter { $0.status.type.state == "post" }.sorted { $0.gameDate > $1.gameDate }
    }

    /// Fixtures grouped by calendar day, in the order the reference app lists
    /// them: a day subhead, then that day's matches.
    private func grouped(_ games: [ESPNEvent]) -> [(day: Date, games: [ESPNEvent])] {
        let cal = Calendar.current
        var buckets: [Date: [ESPNEvent]] = [:]
        for g in games {
            let key = cal.startOfDay(for: g.gameDate)
            buckets[key, default: []].append(g)
        }
        return buckets.keys.sorted().map { (day: $0, games: buckets[$0] ?? []) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            AppBackground().ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                        .modifier(HeroStretch(pull: heroPull, height: heroHeight))

                    // Tab chips — the reference's Table / Fixtures / News row,
                    // minus the tabs this app has no feed for.
                    HStack(spacing: 9) {
                        ForEach(Tab.allCases) { t in
                            Button(action: {
                                guard SwipeTapGuard.tapsAllowed else { return }
                                viewModel.triggerSelectionHaptic()
                                tab = t
                            }) {
                                Text(t.rawValue)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(tab == t ? .black : .white.opacity(0.85))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                    .background(
                                        Capsule().fill(tab == t ? Color.white : Color(white: 0.15))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20)

                    switch tab {
                    case .table:   tableTab
                    case .fixtures: fixtureList(upcoming, empty: "No fixtures scheduled")
                    case .results:  fixtureList(results, empty: "No results yet", newestFirst: true)
                    }

                    if loading && standings.isEmpty && schedule.isEmpty {
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
            .ignoresSafeArea(.container, edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, scrolled in
                heroPull.set(max(0, -scrolled))
                heroScroll.set(min(max(0, scrolled), heroHeight))
            }

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
        .task(id: "\(sport.rawValue)|\(leagueLabel ?? "")") {
            loading = true
            async let s = LeagueDetailService.fetchStandings(sport: sport, leagueLabel: leagueLabel)
            async let f = LeagueDetailService.fetchSchedule(sport: sport, leagueLabel: leagueLabel)
            standings = await s
            schedule = await f
            loading = false
            // Nothing to show a table for — open on the fixtures instead of a
            // blank tab.
            if standings.isEmpty { tab = .fixtures }
        }
    }

    // MARK: Hero

    private var hero: some View {
        ZStack {
            ZStack {
                // Leagues have no brand colour, so the field is the app's own
                // charcoal with the crest's glow pooling behind it.
                Color(white: 0.13)
                RadialGradient(
                    colors: [Color.white.opacity(0.10), .clear],
                    center: UnitPoint(x: 0.5, y: 0.40),
                    startRadius: 0,
                    endRadius: 240
                )
                CachedAsyncImage(urlString: logo ?? "", size: nil)
                    .frame(maxWidth: 128, maxHeight: 128)
                    .offset(y: -heroHeight * 0.10)
                    .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 5)
            }
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
            .modifier(HeroScrollParallax(scroll: heroScroll, baseScale: 1.14))

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
            }
            .padding(.bottom, 30)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var metadataParts: [String] {
        var parts: [String] = [sport.rawValue]
        if !liveGames.isEmpty { parts.append("\(liveGames.count) live") }
        if let group = standings.first, !group.rows.isEmpty { parts.append("\(group.rows.count) teams") }
        return parts
    }

    // MARK: Tabs

    @ViewBuilder
    private var tableTab: some View {
        if standings.isEmpty {
            emptyNote("No table for this competition")
        } else {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(standings) { group in
                    VStack(alignment: .leading, spacing: 14) {
                        // Group tables (a World Cup) each get their own title;
                        // a single league table doesn't need one.
                        if standings.count > 1 {
                            NuvioSectionHeader(title: group.name, inset: 20)
                        }
                        StandingsBoard(group: group)
                    }
                }
                StandingsLegend(rows: standings.flatMap { $0.rows })
            }
        }
    }

    @ViewBuilder
    private func fixtureList(_ games: [ESPNEvent], empty: String, newestFirst: Bool = false) -> some View {
        if games.isEmpty {
            emptyNote(empty)
        } else {
            let days = newestFirst ? grouped(games).reversed().map { $0 } : grouped(games)
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, bucket in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Self.dayHeaderFmt.string(from: bucket.day))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 22)
                        VStack(spacing: 10) {
                            ForEach(bucket.games) { game in
                                Button(action: {
                                    guard SwipeTapGuard.tapsAllowed else { return }
                                    viewModel.triggerSelectionHaptic()
                                    let s = scoreViewModel.sportType(for: game)
                                    scoreViewModel.deepLinkRequest = scoreViewModel.makeDetailRequest(for: game, sport: s)
                                    dismiss()
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
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
    }
}
