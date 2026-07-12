import Foundation
import SwiftUI
import Combine

/// A request to open the FotMob-style match detail sheet for a game.
/// Carries the resolved sport and (for soccer) the ESPN competition code so
/// the summary endpoint URL can be built without re-deriving anything.
struct GameDetailRequest: Identifiable, Equatable {
    let game: ESPNEvent
    let sport: SportType
    let leagueCode: String?
    var id: String { game.id }

    static func == (lhs: GameDetailRequest, rhs: GameDetailRequest) -> Bool { lhs.id == rhs.id }
}

// MARK: - Derived display data

struct GDTeamSide {
    let id: String
    let name: String
    let abbreviation: String
    let logo: String?
    let color: Color
    let score: String
    let record: String?
    let winner: Bool
}

struct GDStatBar: Identifiable {
    let label: String
    let homeText: String
    let awayText: String
    /// Home share of the combined value, 0…1 (0.5 when both are zero).
    let homeFraction: Double
    var id: String { label }
}

struct GDLineupPlayer: Identifiable {
    let id: String
    let name: String
    let jersey: String
    let rating: Double?
    let goals: Int
    let yellow: Bool
    let red: Bool
    let subbedOffClock: String?
    let subbedOnClock: String?
    let positionAbbrev: String?
}

struct GDLineup {
    let formation: String?
    /// Starter rows ordered from the goalkeeper outward ([GK], [defense], …).
    /// Empty when the formation couldn't be laid out — the view falls back
    /// to a list.
    let rows: [[GDLineupPlayer]]
    let starters: [GDLineupPlayer]
    let substitutes: [GDLineupPlayer]
}

struct GDBoxRow: Identifiable {
    let id: String
    let name: String
    let rating: Double?
    let values: [String]
}

struct GDBoxGroup: Identifiable {
    let title: String
    let columns: [String]
    let rows: [GDBoxRow]
    var id: String { title }
}

enum GDEventKind {
    case goal, ownGoal, penaltyGoal, penaltyMiss, yellow, red, substitution
}

struct GDTimelineEntry: Identifiable {
    let id: String
    let minute: String
    let kind: GDEventKind
    let playerText: String
    let detailText: String?
    let isHome: Bool
    /// Match period the event happened in (1 = first half) — the view
    /// draws the halftime divider between periods.
    let period: Int
}

struct GDShot: Identifiable {
    let id: String
    /// 0–100 along the pitch toward the goal being attacked.
    let x: Double
    /// 0–100 across the pitch width.
    let y: Double
    let isHome: Bool
    let isGoal: Bool
    let text: String
    let minute: String
}

struct GDStandingRow: Identifiable {
    let id: String
    let rank: Int
    let name: String
    let logo: String?
    let values: [String]
    /// True for the two teams playing this game — highlighted in the table.
    let isPlaying: Bool
    let isHome: Bool
}

struct GDStandingsGroup: Identifiable {
    let header: String
    let columns: [String]
    let rows: [GDStandingRow]
    var id: String { header }
}

struct GDMeeting: Identifiable {
    let id: String
    let dateText: String
    let leagueText: String
    let homeAbbrev: String
    let awayAbbrev: String
    let homeScore: String
    let awayScore: String
}

struct GDLeaderRow: Identifiable {
    let id: String
    let category: String
    let name: String
    let statLine: String
    let headshot: String?
    let isHome: Bool
}

struct GDBaseballSituation {
    let balls: Int
    let strikes: Int
    let outs: Int
    let onFirst: Bool
    let onSecond: Bool
    let onThird: Bool
    let batter: String?
    let pitcher: String?
    /// Next hitters, sent between innings instead of a live batter.
    let dueUp: [String]
    /// Nil between innings (Mid/End) when nobody is at the plate.
    let battingTeamIsHome: Bool?
}

struct GDFootballSituation {
    let downDistanceText: String
    let possessionIsHome: Bool?
    let isRedZone: Bool
    let lastPlayText: String?
}

// MARK: - View model

@MainActor
final class GameDetailViewModel: ObservableObject {
    let request: GameDetailRequest

    @Published private(set) var summary: GameSummary?
    @Published private(set) var isLoading = true
    @Published private(set) var failed = false

    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    init(request: GameDetailRequest) {
        self.request = request
    }

    private var summaryURL: URL? {
        let path: String?
        if let code = request.leagueCode {
            path = "soccer/\(code)"
        } else {
            path = request.sport.apiPath
        }
        guard let path else { return nil }
        return URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/summary?event=\(request.game.id)")
    }

    var isLive: Bool {
        (summary?.header?.competitions?.first?.status?.type?.state ?? request.game.status.type.state) == "in"
    }

    /// Fetch once, then keep refreshing while the game is live. Runs inside
    /// the view's `.task`, so dismissal cancels it automatically.
    func refreshLoop() async {
        await fetch()
        while !Task.isCancelled && isLive {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { break }
            await fetch()
        }
    }

    private func fetch() async {
        guard let url = summaryURL else {
            isLoading = false; failed = true
            return
        }
        do {
            let fetched = try await Self.fetchSummary(url: url)
            summary = fetched
            failed = false
        } catch {
            if summary == nil { failed = true }
        }
        isLoading = false
    }

    nonisolated private static func fetchSummary(url: URL) async throws -> GameSummary {
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(GameSummary.self, from: data)
    }

    // MARK: Header

    private var headerCompetitors: [GSHeaderCompetitor] {
        summary?.header?.competitions?.first?.competitors ?? []
    }

    private func side(_ homeAway: String) -> GSHeaderCompetitor? {
        headerCompetitors.first { $0.homeAway == homeAway }
    }

    private func teamSide(from competitor: GSHeaderCompetitor?, fallback: ESPNCompetitor?, color: Color) -> GDTeamSide {
        let team = competitor?.team
        return GDTeamSide(
            id: team?.id ?? fallback?.team?.id ?? "",
            name: team?.shortDisplayName ?? team?.displayName ?? fallback?.team?.shortDisplayName ?? "—",
            abbreviation: team?.abbreviation ?? fallback?.team?.abbreviation ?? "—",
            logo: team?.anyLogo ?? fallback?.team?.logo,
            color: color,
            score: competitor?.score ?? fallback?.score ?? "",
            record: competitor?.record?.first?.summary ?? competitor?.record?.first?.displayValue,
            winner: competitor?.winner ?? false
        )
    }

    var homeSide: GDTeamSide { teamSide(from: side("home"), fallback: request.game.homeCompetitor, color: resolvedColors.home) }
    var awaySide: GDTeamSide { teamSide(from: side("away"), fallback: request.game.awayCompetitor, color: resolvedColors.away) }

    /// Both teams' chart/bar colors, resolved together: when the two primary
    /// colors are too close to tell apart (two red teams, two navy teams),
    /// swap in an alternate color on whichever side makes the pair distinct.
    private var resolvedColors: (home: Color, away: Color) {
        let homeTeam = side("home")?.team
        let awayTeam = side("away")?.team
        let hp = homeTeam?.color ?? request.game.homeCompetitor?.team?.color
        let ap = awayTeam?.color ?? request.game.awayCompetitor?.team?.color
        let combos: [(String?, String?)] = [
            (hp, ap),
            (hp, awayTeam?.alternateColor),
            (homeTeam?.alternateColor, ap),
            (homeTeam?.alternateColor, awayTeam?.alternateColor),
        ]

        var best: (home: Color, away: Color)?
        var bestDistance = -1.0
        for (homeHex, awayHex) in combos {
            guard let h = Self.rgb(homeHex), let a = Self.rgb(awayHex) else { continue }
            let distance = Self.colorDistance(h, a)
            // Skip near-black picks — they vanish against the dark UI.
            let visible = Self.luminance(h) >= 0.06 && Self.luminance(a) >= 0.06
            if distance >= 0.32 && visible {
                return (Self.color(h), Self.color(a))
            }
            if distance > bestDistance {
                bestDistance = distance
                best = (Self.color(h), Self.color(a))
            }
        }
        return best ?? (.gray, .blue)
    }

    nonisolated private static func rgb(_ hex: String?) -> (r: Double, g: Double, b: Double)? {
        guard let raw = hex?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")),
              raw.count == 6 else { return nil }
        var v: UInt64 = 0
        guard Scanner(string: raw).scanHexInt64(&v) else { return nil }
        return (Double((v & 0xFF0000) >> 16) / 255.0,
                Double((v & 0x00FF00) >> 8) / 255.0,
                Double(v & 0x0000FF) / 255.0)
    }

    nonisolated private static func colorDistance(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    nonisolated private static func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    }

    nonisolated private static func color(_ c: (r: Double, g: Double, b: Double)) -> Color {
        Color(red: c.r, green: c.g, blue: c.b)
    }

    var statusDetail: String {
        summary?.header?.competitions?.first?.status?.type?.detail ?? request.game.status.type.detail
    }

    var statusState: String {
        summary?.header?.competitions?.first?.status?.type?.state ?? request.game.status.type.state
    }

    var leagueName: String? {
        summary?.header?.league?.name ?? request.game.leagueLabel
    }

    // MARK: Momentum (win probability)

    /// Fraction of the game played, 0…1 — the win-probability area only
    /// extends this far across the chart, so a game in the 4th inning fills
    /// less than half the width and a final fills all of it. Estimated from
    /// period + clock since the play feed can't know a game's total length
    /// ahead of time. Live games cap at 0.97 so the curve visibly still has
    /// room to run (overtime/extras sit at the cap too).
    var gameProgress: Double {
        switch statusState {
        case "pre": return 0
        case "in": break
        default: return 1
        }
        let status = summary?.header?.competitions?.first?.status
        let period = max(status?.period ?? 1, 1)

        // Baseball: innings with top/mid/bottom/end halves.
        if request.sport == .mlb || request.sport == .softball {
            let detail = statusShortDetail.lowercased()
            let half: Double
            if detail.hasPrefix("top") { half = 0.25 }
            else if detail.hasPrefix("mid") { half = 0.5 }
            else if detail.hasPrefix("bot") { half = 0.75 }
            else if detail.hasPrefix("end") { half = 1.0 }
            else { half = 0.5 }
            return min(0.97, (Double(period - 1) + half) / 9.0)
        }

        // Soccer: the clock counts up over ~90 minutes.
        if request.leagueCode != nil || request.sport.isSoccer {
            if let clock = status?.displayClock,
               let minutes = Double(clock.prefix(while: { $0.isNumber })), minutes > 0 {
                return min(0.97, minutes / 95.0)
            }
            return min(0.97, Double(period) * 0.5)
        }

        // Clocked US sports: displayClock counts DOWN within the period.
        let (periods, periodMinutes) = regulationFormat
        guard period <= periods else { return 0.97 }
        var fraction = 0.5
        if periodMinutes > 0, let clock = status?.displayClock {
            let parts = clock.split(separator: ":")
            if let minutes = Double(parts.first ?? "") {
                let seconds = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
                let remaining = minutes * 60 + seconds
                fraction = max(0, min(1, 1 - remaining / (periodMinutes * 60)))
            }
        }
        return min(0.97, (Double(period - 1) + fraction) / Double(periods))
    }

    /// (regulation periods, minutes per period) — 0 minutes = no game clock.
    private var regulationFormat: (periods: Int, minutes: Double) {
        switch request.sport {
        case .nfl, .cfb: return (4, 15)
        case .nba: return (4, 12)
        case .wnba: return (4, 10)
        case .cbb: return (2, 20)
        case .nhl, .collegeHockey: return (3, 20)
        case .mLacrosse, .wLacrosse: return (4, 15)
        case .mVolleyball, .wVolleyball: return (5, 0)
        default: return (2, 45)
        }
    }

    /// Home-win probability per play, downsampled for drawing. Nil when ESPN
    /// doesn't provide a probability feed (soccer) or it's too short to read.
    var momentum: [Double]? {
        guard let raw = summary?.winprobability, raw.count >= 8 else { return nil }
        let values = raw.compactMap { $0.homeWinPercentage }
        guard values.count >= 8 else { return nil }
        let maxPoints = 120
        guard values.count > maxPoints else { return values }
        let stride = Double(values.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { values[Int((Double($0) * stride).rounded())] }
    }

    /// Soccer gets no win-probability feed, so derive a pressure curve from
    /// the timestamped shot/goal plays instead: each attacking event adds
    /// weight for its team, smoothed over a ~3-minute window, mapped to the
    /// same 0…1 home-share scale the chart draws.
    var derivedMomentum: [Double]? {
        let allShots = shots
        guard allShots.count >= 4 else { return nil }
        var events: [(seconds: Double, weight: Double, isHome: Bool)] = []
        for play in (summary?.commentary ?? []).compactMap({ $0.play }) {
            guard let seconds = play.clock?.value,
                  let typeText = play.type?.type?.lowercased() ?? play.type?.text?.lowercased() else { continue }
            let isGoal = typeText.contains("goal") && !typeText.contains("kick") && !typeText.contains("goalkeeper")
            let weight: Double
            if isGoal { weight = 3.0 }
            else if typeText.contains("shot") || typeText.contains("attempt") { weight = 1.2 }
            else { continue }
            events.append((seconds, weight, playIsHome(play.team)))
        }
        guard events.count >= 4 else { return nil }

        // Live games span only the played part — padding a 30' game out to
        // 90' leaves two-thirds of the ribbon dead flat.
        let lastEvent = events.map { $0.seconds }.max() ?? 0
        let maxSeconds = statusState == "post" ? max(5400, lastEvent + 120) : lastEvent + 60
        let samples = 90
        let sigma = 240.0
        return (0..<samples).map { i in
            let t = maxSeconds * Double(i) / Double(samples - 1)
            var net = 0.0
            for event in events {
                let d = (event.seconds - t) / sigma
                let influence = exp(-d * d / 2) * event.weight
                net += event.isHome ? influence : -influence
            }
            // Soft-clip into 0…1 so one flurry doesn't pin the ribbon.
            return 0.5 + 0.5 * (net / (abs(net) + 1.6))
        }
    }

    // MARK: Team stats

    /// Preferred ordering for soccer stat labels — the API returns them in
    /// an arbitrary order with the headline numbers buried in the middle.
    private static let soccerStatPriority: [String] = [
        "POSSESSION", "SHOTS", "ON GOAL", "Corner Kicks", "Fouls", "Saves",
        "Yellow Cards", "Red Cards", "Offsides", "Accurate Passes",
        "Pass Completion %", "Tackles", "Interceptions", "Blocked Shots", "Crosses"
    ]

    var statBars: [GDStatBar] {
        guard let teams = summary?.boxscore?.teams, teams.count == 2 else { return [] }
        let home = teams.first { $0.homeAway == "home" } ?? teams[1]
        let away = teams.first { $0.homeAway == "away" } ?? teams[0]
        var awayByLabel: [String: GSTeamStat] = [:]
        for s in away.statistics ?? [] {
            if let label = s.label ?? s.name { awayByLabel[label] = s }
        }
        var bars: [GDStatBar] = []
        var seen = Set<String>()
        for stat in home.statistics ?? [] {
            guard let label = stat.label ?? stat.name, !seen.contains(label),
                  let h = stat.displayValue, let a = awayByLabel[label]?.displayValue else { continue }
            seen.insert(label)
            let hv = Self.leadingNumber(h), av = Self.leadingNumber(a)
            let total = hv + av
            bars.append(GDStatBar(
                label: Self.prettyStatLabel(label),
                homeText: h, awayText: a,
                homeFraction: total > 0 ? hv / total : 0.5
            ))
        }
        // Curated order first, everything else in API order after.
        let priority = Self.soccerStatPriority
        func rank(_ bar: GDStatBar) -> Int {
            priority.firstIndex { $0.caseInsensitiveCompare(bar.label) == .orderedSame } ?? Int.max
        }
        return bars.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map { $0.element }
    }

    /// The possession stat, pulled out of the list for the FotMob-style
    /// full-width percentage bar at the top of the stats.
    var possessionBar: GDStatBar? {
        statBars.first { $0.label.lowercased().contains("possession") }
    }

    /// Headline stats shown on the overview under the momentum graph.
    var mainStats: [GDStatBar] {
        Array(statBars.filter { !$0.label.lowercased().contains("possession") }.prefix(4))
    }

    /// Everything for the dedicated Stats tab.
    var allStats: [GDStatBar] {
        statBars.filter { !$0.label.lowercased().contains("possession") }
    }

    private static func prettyStatLabel(_ label: String) -> String {
        if label == label.uppercased() && label.count > 3 {
            return label.capitalized
        }
        return label
    }

    nonisolated private static func leadingNumber(_ s: String) -> Double {
        var out = ""
        for ch in s {
            if ch.isNumber || ch == "." { out.append(ch) }
            else if !out.isEmpty { break }
        }
        return Double(out) ?? 0
    }

    /// Ratings are only meaningful once the game has started — pre-game
    /// payloads carry projected lineups with season-total stats, which the
    /// engine would happily "rate" (a .300 hitter's 89 season hits pins
    /// everyone at 10.0).
    private var ratingsAvailable: Bool { statusState != "pre" }

    // MARK: Soccer lineups

    func lineup(homeAway: String) -> GDLineup? {
        guard let roster = summary?.rosters?.first(where: { $0.homeAway == homeAway }),
              let players = roster.roster, !players.isEmpty else { return nil }

        func convert(_ p: GSRosterPlayer) -> GDLineupPlayer {
            var goals = 0, yellow = false, red = false
            for s in p.stats ?? [] {
                switch s.abbreviation ?? s.name ?? "" {
                case "G": goals = Int(s.value ?? 0)
                case "YC": yellow = (s.value ?? 0) > 0
                case "RC": red = (s.value ?? 0) > 0
                default: break
                }
            }
            let isGK = p.position?.abbreviation == "G"
            return GDLineupPlayer(
                id: p.athlete?.id ?? UUID().uuidString,
                name: p.athlete?.lastName ?? p.athlete?.shortName ?? p.athlete?.displayName ?? "—",
                jersey: p.jersey?.value ?? "",
                rating: ratingsAvailable ? PlayerRatingEngine.soccerRating(stats: p.stats ?? [], isGoalkeeper: isGK) : nil,
                goals: goals,
                yellow: yellow,
                red: red,
                subbedOffClock: (p.subbedOut?.didSub == true) ? (p.subbedOut?.clock ?? "") : nil,
                subbedOnClock: (p.subbedIn?.didSub == true) ? (p.subbedIn?.clock ?? "") : nil,
                positionAbbrev: p.position?.abbreviation
            )
        }

        let starterPlayers = players.filter { $0.starter == true }
            .sorted { Int($0.formationPlace?.value ?? "99") ?? 99 < Int($1.formationPlace?.value ?? "99") ?? 99 }
        let starters = starterPlayers.map(convert)
        let subs = players.filter { $0.starter != true && $0.subbedIn?.didSub == true }.map(convert)

        // Formation "4-2-3-1" → rows from the goalkeeper outward. ESPN's
        // formationPlace uses classic football numbering (2 = right back,
        // 9 = striker, 11 = left winger), NOT row order — chunking by place
        // puts the striker in midfield. The position abbreviation encodes
        // both the band (CD/DM/CM/AM/F) and the side (CD-L, AM-R, LB), so
        // rows and left→right slots come from there instead.
        var rows: [[GDLineupPlayer]] = []
        if let formation = roster.formation, starterPlayers.count == 11 {
            let counts = formation.split(separator: "-").compactMap { Int($0) }
            if counts.reduce(0, +) == 10 {
                rows = Self.formationRows(starters: starterPlayers, counts: counts, convert: convert)
            }
        }
        return GDLineup(formation: roster.formation, rows: rows, starters: starters, substitutes: subs)
    }

    /// Lays 11 starters into formation rows using position abbreviations,
    /// falling back to formation-place chunking when the abbreviations are
    /// too sparse to trust.
    nonisolated private static func formationRows(
        starters: [GSRosterPlayer],
        counts: [Int],
        convert: (GSRosterPlayer) -> GDLineupPlayer
    ) -> [[GDLineupPlayer]] {
        let backRowCount = counts.first ?? 4
        let gk = starters.first { bandRank($0.position?.abbreviation, backRowCount: backRowCount) == 0 }
            ?? starters.first { $0.formationPlace?.value == "1" }
        guard let gk else { return [] }
        let outfield = starters.filter { $0.athlete?.id != gk.athlete?.id }
        guard outfield.count == 10 else { return [] }

        let ranked = outfield.map { player -> (player: GSRosterPlayer, band: Double?, side: Double) in
            let abbrev = player.position?.abbreviation?.uppercased()
            return (player, bandRank(abbrev, backRowCount: backRowCount), sideRank(abbrev))
        }
        // Need nearly every player labeled for the band sort to mean
        // anything; otherwise skip the pitch (the view shows the list
        // instead) — place-order chunking would scramble the rows.
        guard ranked.filter({ $0.band == nil }).count <= 1 else { return [] }
        let ordered = ranked.sorted { a, b in
            let ab = a.band ?? 3, bb = b.band ?? 3
            if ab != bb { return ab < bb }
            if a.side != b.side { return a.side < b.side }
            return Int(a.player.formationPlace?.value ?? "99") ?? 99
                 < Int(b.player.formationPlace?.value ?? "99") ?? 99
        }

        var rows: [[GDLineupPlayer]] = [[convert(gk)]]
        var idx = 0
        for count in counts {
            let slice = ordered[idx..<idx + count]
            // Within a row, order purely by side (left → right).
            let row = slice.sorted { a, b in
                if a.side != b.side { return a.side < b.side }
                return Int(a.player.formationPlace?.value ?? "99") ?? 99
                     < Int(b.player.formationPlace?.value ?? "99") ?? 99
            }
            rows.append(row.map { convert($0.player) })
            idx += count
        }
        return rows
    }

    /// Vertical band on the pitch: 0 GK, 1 defense, 2 defensive mid,
    /// 3 midfield, 4 attacking mid, 5 forwards. Wing-backs count as
    /// defenders in a five-back line, midfielders otherwise (3-5-2).
    nonisolated private static func bandRank(_ abbreviation: String?, backRowCount: Int) -> Double? {
        guard let a = abbreviation?.uppercased() else { return nil }
        if a == "G" || a == "GK" { return 0 }
        if a.contains("WB") { return backRowCount >= 5 ? 1 : 2.5 }
        if a == "RB" || a == "LB" || a.hasPrefix("CD") || a == "D" || a == "SW" { return 1 }
        if a.hasPrefix("DM") { return 2 }
        if a.hasPrefix("CM") || a == "RM" || a == "LM" || a == "M" { return 3 }
        if a.hasPrefix("AM") { return 4 }
        if a.hasPrefix("F") || a.hasPrefix("CF") || a == "ST" || a == "RW" || a == "LW" { return 5 }
        return nil
    }

    /// Horizontal slot, left → right as drawn (team attacking up-screen):
    /// 0 wide left, 1 inner left, 2 center, 3 inner right, 4 wide right.
    nonisolated private static func sideRank(_ abbreviation: String?) -> Double {
        guard let a = abbreviation?.uppercased() else { return 2 }
        if a == "LB" || a == "LM" || a == "LW" || a == "LWB" || a.hasSuffix("-LO") { return 0 }
        if a == "RB" || a == "RM" || a == "RW" || a == "RWB" || a.hasSuffix("-RO") { return 4 }
        if a.hasSuffix("-L") { return 1 }
        if a.hasSuffix("-R") { return 3 }
        return 2
    }

    // MARK: Box scores (US sports)

    func boxGroups(homeAway: String) -> [GDBoxGroup] {
        guard let teams = summary?.boxscore?.players else { return [] }
        let homeID = homeSide.id
        let entry = teams.first { ($0.team?.id == homeID) == (homeAway == "home") }
        guard let groups = entry?.statistics else { return [] }

        // Merge every group an athlete appears in so the rating sees the
        // whole line (an NFL RB shows up in rushing AND receiving).
        var athleteGroups: [String: [(group: String, columns: [String: String])]] = [:]
        for group in groups {
            let cols = group.columns
            for boxAthlete in group.athletes ?? [] {
                guard let athleteID = boxAthlete.athlete?.id,
                      let stats = boxAthlete.stats, !stats.isEmpty else { continue }
                var mapped: [String: String] = [:]
                for (i, col) in cols.enumerated() where i < stats.count { mapped[col] = stats[i] }
                athleteGroups[athleteID, default: []].append((group.name ?? group.type ?? "", mapped))
            }
        }

        return groups.compactMap { group in
            let cols = group.columns
            let rows: [GDBoxRow] = (group.athletes ?? []).compactMap { boxAthlete in
                guard let athlete = boxAthlete.athlete,
                      boxAthlete.didNotPlay != true,
                      let stats = boxAthlete.stats, !stats.isEmpty else { return nil }
                let rating = ratingsAvailable ? athlete.id.flatMap { aid in
                    PlayerRatingEngine.boxScoreRating(sport: request.sport, groups: athleteGroups[aid] ?? [])
                } : nil
                return GDBoxRow(
                    id: (athlete.id ?? UUID().uuidString) + (group.name ?? ""),
                    name: athlete.compactName,
                    rating: rating,
                    values: stats
                )
            }
            guard !rows.isEmpty, !cols.isEmpty else { return nil }
            return GDBoxGroup(title: group.title, columns: cols, rows: rows)
        }
    }

    // MARK: Key events timeline

    var timeline: [GDTimelineEntry] {
        guard let events = summary?.keyEvents else { return [] }
        return events.compactMap { event in
            guard let typeText = event.type?.type?.lowercased() ?? event.type?.text?.lowercased() else { return nil }
            let kind: GDEventKind
            if typeText.contains("own-goal") || typeText.contains("own goal") { kind = .ownGoal }
            else if typeText.contains("penalty") && (typeText.contains("missed") || typeText.contains("saved")) { kind = .penaltyMiss }
            else if typeText.contains("penalty") && typeText.contains("goal") { kind = .penaltyGoal }
            else if typeText.contains("goal") { kind = .goal }
            else if typeText.contains("yellow") { kind = .yellow }
            else if typeText.contains("red") { kind = .red }
            else if typeText.contains("sub") { kind = .substitution }
            else { return nil }

            let players = (event.participants ?? []).compactMap { $0.athlete?.compactName }
            let playerText: String
            let detailText: String?
            if kind == .substitution && players.count >= 2 {
                playerText = players[0]
                detailText = "for \(players[1])"
            } else {
                playerText = players.first ?? event.team?.displayName ?? ""
                detailText = nil
            }
            return GDTimelineEntry(
                id: event.eventID,
                minute: event.clock?.displayValue ?? "",
                kind: kind,
                playerText: playerText,
                detailText: detailText,
                isHome: playIsHome(event.team),
                period: event.period?.number ?? 1
            )
        }
    }

    // MARK: Shot map

    /// Commentary play `team` objects often carry only a display name — no
    /// id — so match against both sides' ids AND names. Getting this wrong
    /// silently dumps every play onto one team (which is exactly what the
    /// first shot map shipped doing).
    private func playIsHome(_ team: GSMiniTeam?) -> Bool {
        guard let team else { return false }
        if let id = team.id, !id.isEmpty {
            if id == homeSide.id { return true }
            if id == awaySide.id { return false }
        }
        guard let name = team.displayName else { return false }
        let homeTeam = side("home")?.team
        let awayTeam = side("away")?.team
        for candidate in [homeTeam?.displayName, homeTeam?.shortDisplayName, request.game.homeCompetitor?.team?.displayName] {
            if let candidate, name.caseInsensitiveCompare(candidate) == .orderedSame { return true }
        }
        for candidate in [awayTeam?.displayName, awayTeam?.shortDisplayName, request.game.awayCompetitor?.team?.displayName] {
            if let candidate, name.caseInsensitiveCompare(candidate) == .orderedSame { return false }
        }
        return false
    }

    /// Every shot with pitch coordinates, from the commentary play feed
    /// (key events only cover goals). Coordinates arrive normalized toward
    /// the attacked goal (x → 100 at the goal line) for both teams.
    var shots: [GDShot] {
        var plays: [GSKeyEvent] = (summary?.commentary ?? []).compactMap { $0.play }
        // Older/lighter payloads only carry coordinates on key events.
        plays.append(contentsOf: summary?.keyEvents ?? [])

        var seen = Set<String>()
        var result: [GDShot] = []
        for play in plays {
            guard let x = play.fieldPositionX, let y = play.fieldPositionY,
                  let typeText = play.type?.type?.lowercased() ?? play.type?.text?.lowercased() else { continue }
            let isGoal = typeText.contains("goal")
                && !typeText.contains("kick")
                && !typeText.contains("goalkeeper")
                && !typeText.contains("post")
            let isShot = typeText.contains("shot") || typeText.contains("attempt") || isGoal
            guard isShot, seen.insert(play.eventID).inserted else { continue }
            result.append(GDShot(
                id: play.eventID,
                x: x, y: y,
                isHome: playIsHome(play.team),
                isGoal: isGoal,
                text: play.shortText ?? play.text ?? "",
                minute: play.clock?.displayValue ?? ""
            ))
        }
        return result
    }

    // MARK: Standings

    private static let soccerTableColumns = ["GP", "W", "D", "L", "GD", "P"]
    private static let usTableColumns = ["W", "L", "PCT", "GB", "STRK"]

    var standingsGroups: [GDStandingsGroup] {
        guard let groups = summary?.standings?.groups, !groups.isEmpty else { return [] }
        let isSoccer = request.leagueCode != nil || request.sport.isSoccer
        let preferred = isSoccer ? Self.soccerTableColumns : Self.usTableColumns
        let homeID = homeSide.id
        let awayID = awaySide.id

        return groups.compactMap { group in
            guard let entries = group.standings?.entries, !entries.isEmpty else { return nil }

            func statValue(_ entry: GSStandingEntry, _ column: String) -> String? {
                entry.stats?.first {
                    ($0.abbreviation ?? $0.name)?.caseInsensitiveCompare(column) == .orderedSame
                }?.displayValue
            }
            // Keep only preferred columns the payload actually has.
            var columns = preferred.filter { statValue(entries[0], $0) != nil }
            if columns.count < 2 {
                columns = (entries[0].stats ?? []).prefix(5).compactMap { $0.abbreviation ?? $0.name }
            }

            let rows = entries.enumerated().map { index, entry in
                GDStandingRow(
                    id: entry.id ?? "\(group.header ?? "")-\(index)",
                    rank: index + 1,
                    name: entry.team ?? "—",
                    logo: entry.logo?.first?.href,
                    values: columns.map { statValue(entry, $0) ?? "–" },
                    isPlaying: entry.id == homeID || entry.id == awayID,
                    isHome: entry.id == homeID
                )
            }
            return GDStandingsGroup(header: group.header ?? "Standings", columns: columns, rows: rows)
        }
    }

    // MARK: H2H + form

    /// W/D/L chips for each side, most recent first.
    func form(homeAway: String) -> [String] {
        guard let groups = summary?.lastFiveGames else { return [] }
        let sideID = homeAway == "home" ? homeSide.id : awaySide.id
        let group = groups.first { $0.team?.id == sideID }
            ?? (homeAway == "home" ? groups.first : groups.dropFirst().first)
        return (group?.events ?? []).prefix(5).compactMap { $0.gameResult }
    }

    var meetings: [GDMeeting] {
        guard let events = summary?.headToHeadGames?.first?.events, !events.isEmpty else { return [] }
        let abbrevByID = [homeSide.id: homeSide.abbreviation, awaySide.id: awaySide.abbreviation]
        let nameHint = summary?.headToHeadGames?.first?.team

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM yyyy"

        return events.prefix(6).map { meeting in
            let date = meeting.gameDate.flatMap { ESPNEventDateParser.parse($0) }
            // The group's own team + opponent cover whichever id the score
            // fields reference.
            let homeName = meeting.homeTeamId.flatMap { hid in
                abbrevByID[hid] ?? (nameHint?.id == hid ? nameHint?.displayName : meeting.opponent?.abbreviation)
            } ?? "—"
            let awayName = meeting.awayTeamId.flatMap { aid in
                abbrevByID[aid] ?? (nameHint?.id == aid ? nameHint?.displayName : meeting.opponent?.abbreviation)
            } ?? "—"
            return GDMeeting(
                id: meeting.gameID,
                dateText: date.map { df.string(from: $0) } ?? "",
                leagueText: meeting.leagueAbbreviation ?? meeting.leagueName ?? "",
                homeAbbrev: homeName,
                awayAbbrev: awayName,
                homeScore: meeting.homeTeamScore ?? "",
                awayScore: meeting.awayTeamScore ?? ""
            )
        }
    }

    var seasonSeriesText: String? {
        summary?.seasonseries?.first?.summary
    }

    // MARK: Leaders

    var topPerformers: [GDLeaderRow] {
        guard let teamLeaders = summary?.leaders else { return [] }
        let homeID = homeSide.id
        var rows: [GDLeaderRow] = []
        for teamEntry in teamLeaders {
            let isHome = teamEntry.team?.id == homeID
            for category in (teamEntry.leaders ?? []).prefix(3) {
                guard let entry = category.leaders?.first, let athlete = entry.athlete else { continue }
                rows.append(GDLeaderRow(
                    id: (athlete.id ?? UUID().uuidString) + (category.name ?? ""),
                    category: category.displayName ?? category.name ?? "",
                    name: athlete.compactName,
                    statLine: entry.displayValue ?? "",
                    headshot: athlete.headshot?.href,
                    isHome: isHome
                ))
            }
        }
        return rows
    }

    // MARK: Live situation

    /// Resolves a situation playerId against the box score, which is the
    /// only place the summary payload carries athlete names.
    private func athleteName(id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        for teamPlayers in summary?.boxscore?.players ?? [] {
            for group in teamPlayers.statistics ?? [] {
                for entry in group.athletes ?? [] where entry.athlete?.id == id {
                    return entry.athlete?.compactName
                }
            }
        }
        return nil
    }

    private var statusShortDetail: String {
        summary?.header?.competitions?.first?.status?.type?.shortDetail ?? statusDetail
    }

    /// Bases, count, and outs for a live baseball game. "Top 3rd" means the
    /// away side is batting, "Bot" the home side; "Mid"/"End" is between
    /// innings, where ESPN sends the due-up hitters instead of a batter.
    var baseballSituation: GDBaseballSituation? {
        guard statusState == "in",
              request.sport == .mlb || request.sport == .softball,
              let situation = summary?.situation else { return nil }
        let detail = statusShortDetail.lowercased()
        let battingHome: Bool?
        if detail.hasPrefix("bot") { battingHome = true }
        else if detail.hasPrefix("top") { battingHome = false }
        else { battingHome = nil }
        return GDBaseballSituation(
            balls: situation.balls ?? 0,
            strikes: situation.strikes ?? 0,
            outs: min(situation.outs ?? 0, 3),
            onFirst: situation.onFirst != nil,
            onSecond: situation.onSecond != nil,
            onThird: situation.onThird != nil,
            batter: athleteName(id: situation.batter?.playerId?.value),
            pitcher: athleteName(id: situation.pitcher?.playerId?.value),
            dueUp: (situation.dueUp ?? []).compactMap { athleteName(id: $0.playerId?.value) },
            battingTeamIsHome: battingHome
        )
    }

    /// Down & distance for a live football game.
    var footballSituation: GDFootballSituation? {
        guard statusState == "in",
              request.sport == .nfl || request.sport == .cfb,
              let situation = summary?.situation else { return nil }
        var text = situation.downDistanceText ?? situation.shortDownDistanceText
        if text == nil, let down = situation.down, let distance = situation.distance, down > 0 {
            let ordinals = ["1st", "2nd", "3rd", "4th"]
            text = "\(ordinals[min(down, 4) - 1]) & \(distance == 0 ? "Goal" : String(distance))"
        }
        guard let text else { return nil }
        let possessionID = situation.possession?.value
        let possessionIsHome: Bool?
        if let possessionID, !possessionID.isEmpty {
            possessionIsHome = possessionID == homeSide.id ? true : (possessionID == awaySide.id ? false : nil)
        } else {
            possessionIsHome = nil
        }
        return GDFootballSituation(
            downDistanceText: text,
            possessionIsHome: possessionIsHome,
            isRedZone: situation.isRedZone ?? false,
            lastPlayText: situation.lastPlay?.text
        )
    }

    // MARK: Venue

    var venueLine: (name: String, city: String?)? {
        guard let venue = summary?.gameInfo?.venue, let name = venue.fullName ?? venue.shortName else { return nil }
        let address = venue.address
        let city = [address?.city, address?.state, address?.country].compactMap { $0 }.joined(separator: ", ")
        return (name, city.isEmpty ? nil : city)
    }

    var attendance: Int? { summary?.gameInfo?.attendance }

    var officials: [String] {
        (summary?.gameInfo?.officials ?? []).compactMap { $0.displayName }
    }
}

/// Shared date parsing for ESPN's slightly inconsistent date strings.
nonisolated enum ESPNEventDateParser {
    static func parse(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return df.date(from: raw)
    }
}
