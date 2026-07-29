import Foundation

/// Fetches the extended detail for a single league or tournament: a wide
/// schedule window (recent results + upcoming fixtures, not just today's
/// scoreboard) and standings — the league table, or the per-group tables of
/// a tournament like the World Cup. Backs the league detail sheet in the
/// Favorites hub.
nonisolated enum LeagueDetailService {

    /// Site-API path for a (sport, leagueLabel) pair — "soccer/eng.1" for a
    /// soccer competition, "football/nfl" for a standalone sport.
    static func apiPath(sport: SportType, leagueLabel: String?) -> String? {
        if sport.isSoccer {
            guard let label = leagueLabel,
                  let comp = SportType.competitions(for: sport).first(where: { $0.name == label })
            else { return nil }
            return "soccer/\(comp.code)"
        }
        return sport.apiPath
    }

    /// Schedule window: two weeks back for results, seven weeks forward for
    /// fixtures — wide enough to cover a whole tournament in one request.
    static func fetchSchedule(sport: SportType, leagueLabel: String?) async -> [ESPNEvent] {
        guard let path = apiPath(sport: sport, leagueLabel: leagueLabel) else { return [] }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd"
        let from = fmt.string(from: Date().addingTimeInterval(-14 * 86400))
        let to   = fmt.string(from: Date().addingTimeInterval(49 * 86400))
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/scoreboard?dates=\(from)-\(to)&limit=500")
        else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONDecoder().decode(ESPNResponse.self, from: data)
        else { return [] }
        return (res.events ?? []).sorted { $0.gameDate < $1.gameDate }
    }

    // MARK: - Standings

    struct StandingRow: Identifiable, Sendable {
        let id: String
        let rank: String
        let team: ESPNTeam
        let played: String
        let wins: String
        let draws: String
        let losses: String
        let goalDiff: String
        let points: String
        /// US-league stats. ESPN reports these instead of draws/points, and a
        /// table that shows "D" and "PTS" for baseball is nonsense — see
        /// StandingsColumns, which picks a column set from these.
        let winPercent: String
        let gamesBehind: String
        /// Qualification note color (hex) ESPN attaches to promotion /
        /// advancement / relegation zones — rendered as a thin edge bar.
        let noteColor: String?
        /// ESPN's own wording for that zone ("UEFA Champions League",
        /// "Relegation"), which the league page turns into a legend.
        let noteText: String?
    }

    struct StandingsGroup: Identifiable, Sendable {
        let id: String
        let name: String
        let rows: [StandingRow]
    }

    /// League table (one group) or tournament group tables (many groups).
    /// Returns [] when the league has no standings — the sheet hides the tab.
    static func fetchStandings(sport: SportType, leagueLabel: String?) async -> [StandingsGroup] {
        guard let path = apiPath(sport: sport, leagueLabel: leagueLabel),
              let url = URL(string: "https://site.api.espn.com/apis/v2/sports/\(path)/standings")
        else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONDecoder().decode(StandingsResponse.self, from: data)
        else { return [] }

        return (res.children ?? []).enumerated().compactMap { idx, child in
            guard let entries = child.standings?.entries, !entries.isEmpty else { return nil }
            let rows: [StandingRow] = entries.map { entry in
                func stat(_ names: [String]) -> String {
                    for n in names {
                        if let s = entry.stats?.first(where: { $0.name == n }) {
                            if let v = s.displayValue, !v.isEmpty { return v }
                            if let v = s.value { return String(Int(v)) }
                        }
                    }
                    return "–"
                }
                let t = entry.team
                let team = ESPNTeam(id: t?.id ?? UUID().uuidString,
                                    abbreviation: t?.abbreviation,
                                    displayName: t?.displayName,
                                    shortDisplayName: t?.shortDisplayName,
                                    logo: t?.logos?.first?.href,
                                    color: nil)
                // Football reports `rank`; every US league reports
                // `playoffSeed` instead and no rank at all. A seed of 0 is
                // ESPN's "not seeded yet" (the whole NFL preseason), so it's
                // treated as missing rather than printed as position zero.
                let position = stat(["rank", "playoffSeed"])
                return StandingRow(id: team.id,
                                   rank: (Int(position) ?? 0) > 0 ? position : "–",
                                   team: team,
                                   played: stat(["gamesPlayed"]),
                                   wins: stat(["wins"]),
                                   draws: stat(["ties", "draws"]),
                                   losses: stat(["losses"]),
                                   goalDiff: stat(["pointDifferential", "differential"]),
                                   points: stat(["points"]),
                                   winPercent: stat(["winPercent"]),
                                   gamesBehind: stat(["gamesBehind"]),
                                   noteColor: entry.note?.color,
                                   noteText: entry.note?.description)
            }
            return StandingsGroup(id: child.name ?? "\(idx)",
                                  name: child.name ?? "Standings",
                                  rows: sortedByPosition(rows))
        }
    }

    /// Puts a table in table order.
    ///
    /// Only football's standings arrive sorted, and only football reports a
    /// `rank`. Everything else hands back entries in an order of its own — the
    /// Western Conference came out Lakers (.646) above Spurs (.756) — and since
    /// the row index was also the fallback position, every number in the "#"
    /// column was wrong too.
    ///
    /// The US leagues' `playoffSeed` is NOT a substitute: baseball's is
    /// division-winners-then-wildcards, which put the Yankees (.567) below the
    /// White Sox (.524). So those tables are ordered by record and numbered by
    /// their own position, which is what a standings table means.
    private static func sortedByPosition(_ rows: [StandingRow]) -> [StandingRow] {
        func number(_ text: String) -> Double {
            Double(text.replacingOccurrences(of: "+", with: "")) ?? -.greatestFiniteMagnitude
        }
        // Same discriminator StandingsColumns uses to choose its column set.
        let isAmerican = rows.contains { $0.gamesBehind != "–" }

        if !isAmerican {
            func position(_ row: StandingRow) -> Int? {
                guard let n = Int(row.rank), n > 0 else { return nil }
                return n
            }
            if rows.allSatisfy({ position($0) != nil }) {
                return rows.sorted { position($0)! < position($1)! }
            }
            return rows.sorted { a, b in
                let pa = number(a.points), pb = number(b.points)
                if pa != pb { return pa > pb }
                return number(a.goalDiff) > number(b.goalDiff)
            }
        }

        // Win percentage is the currency in basketball, baseball and football;
        // hockey reports none at all and keeps score in points.
        let usesWinPercent = rows.contains { $0.winPercent != "–" }
        let ordered = rows.sorted { a, b in
            if usesWinPercent {
                let pa = number(a.winPercent), pb = number(b.winPercent)
                if pa != pb { return pa > pb }
            } else {
                let pa = number(a.points), pb = number(b.points)
                if pa != pb { return pa > pb }
            }
            let wa = number(a.wins), wb = number(b.wins)
            if wa != wb { return wa > wb }
            return number(a.goalDiff) > number(b.goalDiff)
        }
        // Drop the seed so the "#" column shows the table position instead of a
        // playoff seed that disagrees with the order the rows are in.
        return ordered.map { row in
            StandingRow(id: row.id, rank: "–", team: row.team, played: row.played,
                        wins: row.wins, draws: row.draws, losses: row.losses,
                        goalDiff: row.goalDiff, points: row.points,
                        winPercent: row.winPercent, gamesBehind: row.gamesBehind,
                        noteColor: row.noteColor, noteText: row.noteText)
        }
    }

    // MARK: - Wire models (only the fields we read)

    private struct StandingsResponse: Decodable {
        struct Child: Decodable { let name: String?; let standings: Standings? }
        struct Standings: Decodable { let entries: [Entry]? }
        struct Entry: Decodable {
            let team: APITeam?
            let note: Note?
            let stats: [Stat]?
            struct Note: Decodable { let color: String?; let description: String? }
        }
        struct APITeam: Decodable {
            let id: String?
            let abbreviation: String?
            let displayName: String?
            let shortDisplayName: String?
            let logos: [Logo]?
            struct Logo: Decodable { let href: String? }
        }
        struct Stat: Decodable { let name: String?; let displayValue: String?; let value: Double? }
        let children: [Child]?
    }
}
