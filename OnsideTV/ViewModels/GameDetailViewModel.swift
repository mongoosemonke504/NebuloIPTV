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
    /// A golfer to highlight on the leaderboard — set when the card is opened
    /// from a favourited player rather than from the tournament itself.
    var highlightPlayer: String? = nil
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
    /// The hex `color` was resolved from, for the card's washes: a crest can
    /// vanish into a wash of its own colour, and the test needs the number.
    /// Nil when the colour is a fallback rather than the club's.
    let colorHex: String?
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
    let fullName: String
    let jersey: String
    let rating: Double?
    let goals: Int
    let yellow: Bool
    let red: Bool
    let subbedOffClock: String?
    let subbedOnClock: String?
    let positionAbbrev: String?
    let headshot: String?
    let age: Int?
    /// Match stat lines for the individual-stats sheet, in ESPN's order.
    let stats: [GDPlayerStatLine]
}

struct GDPlayerStatLine: Identifiable {
    /// ESPN's internal stat key ("totalGoals") — used for grouping.
    let key: String
    let label: String
    let value: String
    var id: String { key }
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
    /// Unique per group ("athleteID + group name") — a two-way player
    /// appears in several groups.
    let id: String
    /// Bare athlete id, for merging one player's rows across groups.
    let athleteID: String
    let name: String
    let rating: Double?
    let values: [String]
    let headshot: String?
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

/// One located touch/shot for a single player's heatmap. Coordinates are
/// normalized toward the attacked goal (x → 100 at the goal line).
struct GDHeatPoint: Identifiable {
    let id: String
    let x: Double
    let y: Double
    let isShot: Bool
    let isGoal: Bool
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

// MARK: - Summary cache / prefetch

/// Process-wide store of fetched game summaries, plus a prefetcher the Sports
/// Hub drives so the first card a user opens is already populated.
///
/// `GameDetailViewModel` deliberately uses an ephemeral URLSession with
/// `reloadIgnoringLocalCacheData` — live scores must never be served from the
/// URL cache — so without this every open, and every reopen, started on a
/// spinner and paid a full round trip. Holding decoded summaries here keeps
/// that policy for the network while making a reopen instant: the card renders
/// from the cache immediately and the refresh loop still runs behind it, so
/// what's on screen is never more than one refresh stale.
///
/// Memory-only and deliberately so: these are large decoded object graphs, and
/// they're only worth keeping while the app is warm. Capped, and cleared under
/// memory pressure.
@MainActor
final class GameSummaryStore {
    static let shared = GameSummaryStore()

    /// Enough to cover a hub screen's worth of games and the carousel around
    /// whichever one is open, without holding the whole scoreboard.
    private let capacity = 40

    /// The decoded summary AND the bytes it came from. A card that starts
    /// from a cached summary compares its first refresh against those bytes,
    /// and an unchanged payload is never re-published — see
    /// `GameDetailViewModel.fetch()`.
    private var cache: [String: (summary: GameSummary, data: Data)] = [:]
    /// Insertion order, so the oldest entry is the one evicted at capacity.
    private var order: [String] = []
    /// Games with a prefetch in flight, so a scroll that re-triggers the hub's
    /// prefetch doesn't start the same request twice.
    private var inFlight: Set<String> = []

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }
    }

    func summary(for gameID: String) -> GameSummary? { cache[gameID]?.summary }
    func entry(for gameID: String) -> (summary: GameSummary, data: Data)? { cache[gameID] }

    func store(_ summary: GameSummary, data: Data, for gameID: String) {
        if cache[gameID] == nil {
            order.append(gameID)
            if order.count > capacity, let oldest = order.first {
                order.removeFirst()
                cache[oldest] = nil
            }
        }
        cache[gameID] = (summary, data)
    }

    func clear() {
        cache.removeAll()
        order.removeAll()
    }

    /// Warms a game in the background. Cheap to call repeatedly — already
    /// cached or already in flight both no-op.
    func prefetch(_ request: GameDetailRequest) {
        let id = request.game.id
        guard cache[id] == nil, !inFlight.contains(id),
              let url = GameDetailViewModel.summaryURL(for: request) else { return }
        inFlight.insert(id)
        Task { [weak self] in
            let fetched = try? await GameDetailViewModel.fetchSummary(url: url)
            guard let self else { return }
            if let fetched { self.store(fetched.summary, data: fetched.data, for: id) }
            self.inFlight.remove(id)
        }
    }
}

// MARK: - View model

@MainActor
final class GameDetailViewModel: ObservableObject {
    let request: GameDetailRequest

    @Published private(set) var summary: GameSummary? {
        didSet { derived = Derived() }
    }
    @Published private(set) var isLoading = true
    @Published private(set) var failed = false
    /// The bytes `summary` was decoded from. A refresh that comes back
    /// byte-identical — every poll of a game that is over or hasn't started,
    /// and the first refresh of a card opened on a summary the hub had just
    /// prefetched — is dropped here rather than decoded and re-published,
    /// because a publish re-lays out the whole card for a payload that says
    /// nothing new.
    private var lastSummaryData: Data?
    /// Photos and ages found by name — see `PlayerLookupBook`.
    let lookups = PlayerLookupBook()

    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    init(request: GameDetailRequest) {
        self.request = request
        // Reopening a game — or opening one the hub already prefetched — starts
        // fully populated instead of on a spinner. The refresh still runs, so
        // this is a head start, not stale data being pinned.
        if let cached = GameSummaryStore.shared.entry(for: request.game.id) {
            self.summary = cached.summary
            self.lastSummaryData = cached.data
            self.isLoading = false
            // Settled here, before the first body, rather than after the
            // first refresh — which, for a payload that came back unchanged,
            // was the one thing left that still re-published the model and
            // re-laid out a card a second after it appeared.
            recomputeTopRatedPlayer()
        }
    }

    private var summaryURL: URL? { Self.summaryURL(for: request) }

    /// Static so the prefetcher can build the same URL without standing up a
    /// whole view model per game.
    nonisolated static func summaryURL(for request: GameDetailRequest) -> URL? {
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
            // Compared and decoded off the main actor; only a payload that
            // actually changed comes back.
            if let fetched = try await Self.fetchSummary(url: url, unchangedIf: lastSummaryData) {
                summary = fetched.summary
                lastSummaryData = fetched.data
                GameSummaryStore.shared.store(fetched.summary, data: fetched.data, for: request.game.id)
                // Only a changed payload can move the ratings.
                recomputeTopRatedPlayer()
            }
            // Every publish here re-renders the whole card — lineups, shot
            // map, momentum chart and all — so a flag that is already right
            // is left alone rather than re-announced on each 30-second poll.
            if failed { failed = false }
            prefetchPlayerImages()
            resolveSoccerHeadshots()
        } catch {
            if summary == nil, !failed { failed = true }
        }
        if isLoading { isLoading = false }
    }

    /// The single best-rated player across BOTH teams — the only one whose
    /// rating badge renders blue (FotMob's man-of-the-match treatment);
    /// everyone else tops out at green. Recomputed on every score refresh.
    @Published private(set) var topRatedPlayerID: String?

    private func recomputeTopRatedPlayer() {
        var best: (id: String, rating: Double)?
        for homeAway in ["home", "away"] {
            if let lineup = lineup(homeAway: homeAway) {
                for player in lineup.starters + lineup.substitutes {
                    if let rating = player.rating, rating > (best?.rating ?? -1) {
                        best = (player.id, rating)
                    }
                }
            }
            for group in boxGroups(homeAway: homeAway) {
                for row in group.rows where !row.athleteID.isEmpty {
                    if let rating = row.rating, rating > (best?.rating ?? -1) {
                        best = (row.athleteID, rating)
                    }
                }
            }
        }
        if topRatedPlayerID != best?.id { topRatedPlayerID = best?.id }
    }

    private var didPrefetchImages = false

    /// Pulls every player headshot for this game (both lineups + box
    /// scores) into the image cache the moment the summary arrives, so the
    /// lineup and player sheets render photos instantly instead of loading
    /// them one by one on first look. The disk cache persists, so a player
    /// seen once is instant in every later session too.
    private func prefetchPlayerImages() {
        guard !didPrefetchImages, summary != nil else { return }
        didPrefetchImages = true
        var urls = Set<String>()
        for homeAway in ["home", "away"] {
            if let lineup = lineup(homeAway: homeAway) {
                for player in lineup.starters + lineup.substitutes {
                    if let url = player.headshot, !url.isEmpty { urls.insert(url) }
                }
            }
            for group in boxGroups(homeAway: homeAway) {
                for row in group.rows {
                    if let url = row.headshot, !url.isEmpty { urls.insert(url) }
                }
            }
        }
        if !urls.isEmpty {
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for url in urls {
                        group.addTask { _ = await ImageCache.shared.image(forKey: url) }
                    }
                }
            }
        }
    }

    /// Downloads and decodes a summary. With `unchangedIf` set, a response
    /// whose bytes match it returns nil before any decoding — the caller
    /// already holds exactly this payload.
    nonisolated static func fetchSummary(url: URL, unchangedIf previous: Data?) async throws -> (summary: GameSummary, data: Data)? {
        let (data, _) = try await session.data(from: url)
        if let previous, previous == data { return nil }
        return (try JSONDecoder().decode(GameSummary.self, from: data), data)
    }

    /// The same fetch for callers that only want the decoded summary.
    nonisolated static func fetchSummary(url: URL) async throws -> (summary: GameSummary, data: Data) {
        // No comparison to make, so the optional form never returns nil.
        try await fetchSummary(url: url, unchangedIf: nil)!
    }

    /// Same fetch, exposed for background warming and the team page.
    nonisolated static func prefetchSummary(url: URL) async throws -> GameSummary {
        try await fetchSummary(url: url).summary
    }

    // MARK: Derived-value memo

    /// Everything below is derived from `summary`, and a body evaluation of
    /// the card reads most of it — several things more than once: `shots`
    /// three times, `statBars` four, and `homeSide`/`awaySide` once per PLAY
    /// through `playIsHome`. Each read used to re-walk the payload — a soccer
    /// summary carries a few hundred commentary plays — and the card's body
    /// runs on every publish, so each score poll, photo batch and tab switch
    /// spent tens of milliseconds re-deriving before a view was laid out.
    /// Derived once per payload, the same body is dictionary lookups.
    ///
    /// Reset whenever `summary` changes. The lineups and the leaders also
    /// bake in the photo/age lookups, so those two are dropped when the
    /// lookups move — see `absorb`.
    private struct Derived {
        var homeSide: GDTeamSide?
        var awaySide: GDTeamSide?
        var statBars: [GDStatBar]?
        var momentum: [Double]??
        var derivedMomentum: [Double]??
        var timeline: [GDTimelineEntry]?
        var shots: [GDShot]?
        var standingsGroups: [GDStandingsGroup]?
        var meetings: [GDMeeting]?
        var topPerformers: [GDLeaderRow]?
        var lineups: [String: GDLineup?] = [:]
        var boxGroups: [String: [GDBoxGroup]] = [:]
    }
    private var derived = Derived()

    // MARK: Header

    private var headerCompetitors: [GSHeaderCompetitor] {
        summary?.header?.competitions?.first?.competitors ?? []
    }

    private func side(_ homeAway: String) -> GSHeaderCompetitor? {
        headerCompetitors.first { $0.homeAway == homeAway }
    }

    private func teamSide(from competitor: GSHeaderCompetitor?, fallback: ESPNCompetitor?, color: Color, colorHex: String?) -> GDTeamSide {
        let team = competitor?.team
        return GDTeamSide(
            id: team?.id ?? fallback?.team?.id ?? "",
            name: team?.shortDisplayName ?? team?.displayName ?? fallback?.team?.shortDisplayName ?? "—",
            abbreviation: team?.abbreviation ?? fallback?.team?.abbreviation ?? "—",
            logo: team?.anyLogo ?? fallback?.team?.logo,
            color: color,
            colorHex: colorHex,
            score: competitor?.score ?? fallback?.score ?? "",
            record: competitor?.record?.first?.summary ?? competitor?.record?.first?.displayValue,
            winner: competitor?.winner ?? false
        )
    }

    var homeSide: GDTeamSide {
        if let cached = derived.homeSide { return cached }
        let colors = resolvedColors
        let value = teamSide(from: side("home"), fallback: request.game.homeCompetitor,
                             color: colors.home, colorHex: colors.homeHex)
        derived.homeSide = value
        return value
    }
    var awaySide: GDTeamSide {
        if let cached = derived.awaySide { return cached }
        let colors = resolvedColors
        let value = teamSide(from: side("away"), fallback: request.game.awayCompetitor,
                             color: colors.away, colorHex: colors.awayHex)
        derived.awaySide = value
        return value
    }

    /// Both teams' chart/bar colors, resolved together: when the two primary
    /// colors are too close to tell apart (two red teams, two navy teams),
    /// swap in an alternate color on whichever side makes the pair distinct.
    private var resolvedColors: (home: Color, away: Color, homeHex: String?, awayHex: String?) {
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

        var best: (home: Color, away: Color, homeHex: String?, awayHex: String?)?
        var bestDistance = -1.0
        for (homeHex, awayHex) in combos {
            guard let h = Self.rgb(homeHex), let a = Self.rgb(awayHex) else { continue }
            let distance = Self.colorDistance(h, a)
            // Skip near-black picks — they vanish against the dark UI.
            let visible = Self.luminance(h) >= 0.06 && Self.luminance(a) >= 0.06
            if distance >= 0.32 && visible {
                return (Self.color(h), Self.color(a), homeHex, awayHex)
            }
            if distance > bestDistance {
                bestDistance = distance
                best = (Self.color(h), Self.color(a), homeHex, awayHex)
            }
        }
        return best ?? (.gray, .blue, nil, nil)
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
        // Pre-game: the app's own schedule wording ("Today at 7:05 PM")
        // instead of whatever shape this sport's feed uses.
        if statusState == "pre" { return request.game.scheduleAwareDetail }
        return summary?.header?.competitions?.first?.status?.type?.detail ?? request.game.status.type.detail
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
        if let cached = derived.momentum { return cached }
        let value = computeMomentum()
        derived.momentum = .some(value)
        return value
    }

    private func computeMomentum() -> [Double]? {
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
        if let cached = derived.derivedMomentum { return cached }
        let value = computeDerivedMomentum()
        derived.derivedMomentum = .some(value)
        return value
    }

    private func computeDerivedMomentum() -> [Double]? {
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
        if let cached = derived.statBars { return cached }
        let value = computeStatBars()
        derived.statBars = value
        return value
    }

    private func computeStatBars() -> [GDStatBar] {
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

    /// Headshot for an athlete: the payload's own URL when present,
    /// otherwise built from ESPN's headshot CDN path (box scores and soccer
    /// rosters frequently omit the href even though the image exists).
    private func headshotURL(_ athlete: GSAthlete?) -> String? {
        if let href = athlete?.headshot?.href, !href.isEmpty { return href }
        guard let id = athlete?.id, !id.isEmpty else { return nil }
        // Soccer: no CDN guess — ESPN's soccer headshot path 404s for all
        // but a handful of players. Missing ones resolve by name through
        // SoccerHeadshotService instead (see resolvedHeadshots).
        if request.leagueCode != nil || request.sport.isSoccer { return nil }
        guard let path = request.sport.apiPath, let slug = path.split(separator: "/").last else { return nil }
        return "https://a.espncdn.com/combiner/i?img=/i/headshots/\(slug)/players/full/\(id).png&w=96&h=96&scale=crop"
    }

    /// athleteID → photo URL found by name via TheSportsDB/Wikipedia, for
    /// soccer players ESPN has no image for. Lives in `lookups`; read here
    /// for the derivations that bake it into their rows.
    var resolvedHeadshots: [String: String] { lookups.photos }
    /// athleteID → age in years, from the same name lookups (ESPN's soccer
    /// feed has no birth data at all).
    var resolvedAges: [String: Int] { lookups.ages }
    private var headshotResolveStarted = false
    /// Athletes with a definitive lookup answer (even "no photo, no age") —
    /// keeps the periodic re-sweep from re-targeting them forever.
    private var lookupCompleted: Set<String> = []

    private func resolveSoccerHeadshots() {
        guard !headshotResolveStarted,
              request.leagueCode != nil || request.sport.isSoccer,
              let rosters = summary?.rosters else { return }
        // Only players the UI can actually show: starters first (the pitch
        // is what's on screen), then substitutes who came on. Unused bench
        // players appear nowhere, so they'd just burn lookup budget.
        // Players WITH an ESPN photo still get looked up — the age only
        // comes from these lookups — but their ESPN image stays preferred.
        var starters: [(id: String, name: String)] = []
        var subs: [(id: String, name: String)] = []
        for roster in rosters {
            for player in roster.roster ?? [] {
                let used = player.starter == true || player.subbedIn?.didSub == true
                guard used,
                      let athlete = player.athlete, let id = athlete.id, !id.isEmpty,
                      !lookupCompleted.contains(id) else { continue }
                let name = athlete.displayName ?? athlete.shortName ?? ""
                guard !name.isEmpty else { continue }
                if player.starter == true { starters.append((id, name)) }
                else { subs.append((id, name)) }
            }
        }
        let targets = starters + subs
        guard !targets.isEmpty else { return }
        headshotResolveStarted = true
        Task { [weak self] in
            // Pass one: every player already answered on disk, in one go and
            // one publish. This is most of both squads for any team seen
            // before, and it used to go through the same four-at-a-time
            // cadence as the network lookups — fourteen seconds of sleeping
            // between batches of answers that were already in hand, each
            // batch re-drawing the card.
            var pending: [(id: String, name: String)] = []
            var known: [(String, SoccerHeadshotService.PlayerInfo)] = []
            for target in targets {
                if let info = await SoccerHeadshotService.shared.cached(for: target.name) {
                    known.append((target.id, info))
                } else {
                    pending.append(target)
                }
            }
            guard let self else { return }
            self.absorb(known)

            // Pass two: the rest, in small batches with a breather between
            // them — the free API tier rate-limits bursts, and a full
            // two-squad burst is what left the second team photo-less.
            var index = 0
            while index < pending.count {
                let batch = Array(pending[index..<min(index + 4, pending.count)])
                index += 4
                var found: [(String, SoccerHeadshotService.PlayerInfo)] = []
                await withTaskGroup(of: (String, SoccerHeadshotService.PlayerInfo?).self) { group in
                    for target in batch {
                        group.addTask { (target.id, await SoccerHeadshotService.shared.info(for: target.name)) }
                    }
                    for await (id, info) in group {
                        if let info { found.append((id, info)) }
                    }
                }
                self.absorb(found)
                if index < pending.count {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            // Rate-limited lookups aren't cached, so let the next live-poll
            // cycle sweep up anything still missing (cached answers make a
            // re-sweep nearly free).
            self.headshotResolveStarted = false
        }
    }

    /// Files a batch of lookup answers: one write per map, only if it moved,
    /// into the book the lineup and leaders observe — the page itself hears
    /// nothing. The derivations that bake photos into their rows are dropped
    /// first so the views re-reading them see the new answers.
    private func absorb(_ found: [(String, SoccerHeadshotService.PlayerInfo)]) {
        guard !found.isEmpty else { return }
        var photos = lookups.photos
        var ages = lookups.ages
        for (id, info) in found {
            lookupCompleted.insert(id)
            if !info.url.isEmpty {
                photos[id] = info.url
                Task { _ = await ImageCache.shared.image(forKey: info.url) }
            }
            if let age = SoccerHeadshotService.age(fromBorn: info.born) {
                ages[id] = age
            }
        }
        guard photos != lookups.photos || ages != lookups.ages else { return }
        derived.lineups = [:]
        derived.topPerformers = nil
        lookups.merge(photos: photos, ages: ages)
    }

    // MARK: Soccer lineups

    /// Friendly display names for ESPN's internal soccer stat keys; unknown
    /// keys fall back to the camelCase key split into words.
    nonisolated private static let soccerStatLabels: [String: String] = [
        "minutes": "Minutes played",
        "totalGoals": "Goals",
        "goalAssists": "Assists",
        "totalShots": "Shots",
        "shotsOnTarget": "Shots on target",
        "blockedShots": "Blocked shots",
        "offsides": "Offsides",
        "ownGoals": "Own goals",
        "totalPasses": "Passes",
        "accuratePasses": "Accurate passes",
        "totalCrosses": "Crosses",
        "accurateCrosses": "Accurate crosses",
        "totalLongBalls": "Long balls",
        "accurateLongBalls": "Accurate long balls",
        "totalTackles": "Tackles",
        "effectiveTackles": "Tackles won",
        "totalClearance": "Clearances",
        "effectiveClearance": "Effective clearances",
        "interceptions": "Interceptions",
        "foulsCommitted": "Fouls committed",
        "foulsSuffered": "Fouls suffered",
        "yellowCards": "Yellow cards",
        "redCards": "Red cards",
        "saves": "Saves",
        "shotsFaced": "Shots faced",
        "goalsConceded": "Goals conceded",
        "punches": "Punches",
        "crossesCaught": "Crosses caught",
        "appearances": "Appearances",
        "subIns": "Sub appearances"
    ]

    nonisolated static func statLabel(for key: String) -> String {
        if let label = soccerStatLabels[key] { return label }
        // "totalKeeperSweeper" → "Total keeper sweeper"
        var words: [String] = []
        var current = ""
        for ch in key {
            if ch.isUppercase && !current.isEmpty {
                words.append(current)
                current = String(ch).lowercased()
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return key }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    func lineup(homeAway: String) -> GDLineup? {
        if let cached = derived.lineups[homeAway] { return cached }
        let value = Self.buildLineup(
            roster: summary?.rosters?.first { $0.homeAway == homeAway },
            ratingsAvailable: ratingsAvailable,
            headshot: { [self] athlete in
                headshotURL(athlete) ?? resolvedHeadshots[athlete?.id ?? ""]
            },
            age: { [self] id in resolvedAges[id] }
        )
        // `.some`, so a side with no lineup yet is remembered as such rather
        // than the nil assignment deleting the key and re-deriving each read.
        derived.lineups[homeAway] = .some(value)
        return value
    }

    /// The lineup laid out from one team's roster entry.
    ///
    /// Static and dependency-free so the team page can draw a club's last
    /// starting XI from a fetched summary without standing up a whole game
    /// view model — the photo and age lookups differ there, so both arrive as
    /// closures rather than being read off `self`.
    nonisolated static func buildLineup(
        roster: GSRoster?,
        ratingsAvailable: Bool,
        headshot: (GSAthlete?) -> String?,
        age: (String) -> Int?
    ) -> GDLineup? {
        guard let roster, let players = roster.roster, !players.isEmpty else { return nil }

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
            let statLines: [GDPlayerStatLine] = (p.stats ?? []).compactMap { s in
                guard let key = s.name ?? s.abbreviation else { return nil }
                let value = s.displayValue ?? s.value.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }
                guard let value else { return nil }
                return GDPlayerStatLine(key: key, label: Self.statLabel(for: key), value: value)
            }
            return GDLineupPlayer(
                id: p.athlete?.id ?? UUID().uuidString,
                name: p.athlete?.lastName ?? p.athlete?.shortName ?? p.athlete?.displayName ?? "—",
                fullName: p.athlete?.displayName ?? p.athlete?.shortName ?? p.athlete?.lastName ?? "—",
                jersey: p.jersey?.value ?? "",
                rating: ratingsAvailable ? PlayerRatingEngine.soccerRating(stats: p.stats ?? [], isGoalkeeper: isGK) : nil,
                goals: goals,
                yellow: yellow,
                red: red,
                subbedOffClock: (p.subbedOut?.didSub == true) ? (p.subbedOut?.clock ?? "") : nil,
                subbedOnClock: (p.subbedIn?.didSub == true) ? (p.subbedIn?.clock ?? "") : nil,
                positionAbbrev: p.position?.abbreviation,
                headshot: headshot(p.athlete),
                age: age(p.athlete?.id ?? ""),
                stats: statLines
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
        // Tolerate a few unlabeled players (they slot in as midfielders in
        // the sort below) — bail to the list only when the labels are so
        // sparse the layout would be a guess. Bailing on a single odd
        // abbreviation put one team on the pitch and the other in a line.
        guard ranked.filter({ $0.band == nil }).count <= 3 else { return [] }
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
        if a.hasPrefix("F") || a.hasPrefix("CF") || a == "ST" || a == "SS" || a == "RW" || a == "LW" { return 5 }
        // Catch-alls for the abbreviation variants ESPN mixes in ("CB",
        // "RCB", "RCM", "W"…) — an unrecognized label was tanking the whole
        // pitch layout for that team.
        if a.hasSuffix("B") { return 1 }
        if a.hasSuffix("M") { return 3 }
        if a.hasSuffix("W") { return 5 }
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
        if let cached = derived.boxGroups[homeAway] { return cached }
        let value = computeBoxGroups(homeAway: homeAway)
        derived.boxGroups[homeAway] = value
        return value
    }

    private func computeBoxGroups(homeAway: String) -> [GDBoxGroup] {
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
                    athleteID: athlete.id ?? "",
                    name: athlete.compactName,
                    rating: rating,
                    values: stats,
                    headshot: headshotURL(athlete)
                )
            }
            guard !rows.isEmpty, !cols.isEmpty else { return nil }
            return GDBoxGroup(title: group.title, columns: cols, rows: rows)
        }
    }

    // MARK: Key events timeline

    var timeline: [GDTimelineEntry] {
        if let cached = derived.timeline { return cached }
        let value = computeTimeline()
        derived.timeline = value
        return value
    }

    private func computeTimeline() -> [GDTimelineEntry] {
        guard let events = summary?.keyEvents else { return [] }
        return events.compactMap { event in
            guard let typeText = event.type?.type?.lowercased() ?? event.type?.text?.lowercased() else { return nil }
            let kind: GDEventKind
            // "red" must match the card specifically — "Penalty - Scored"
            // contains "red" (sco-RED) and was rendering goals as red cards.
            if typeText.contains("own-goal") || typeText.contains("own goal") { kind = .ownGoal }
            else if typeText.contains("penalty") && (typeText.contains("missed") || typeText.contains("saved")) { kind = .penaltyMiss }
            else if typeText.contains("penalty") && (typeText.contains("goal") || typeText.contains("scored")) { kind = .penaltyGoal }
            else if typeText.contains("goal") || typeText.contains("scored") { kind = .goal }
            else if typeText.contains("yellow") { kind = .yellow }
            else if typeText.contains("red card") || typeText.contains("red-card") || typeText == "red" { kind = .red }
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
        if let cached = derived.shots { return cached }
        let value = computeShots()
        derived.shots = value
        return value
    }

    private func computeShots() -> [GDShot] {
        var plays: [GSKeyEvent] = (summary?.commentary ?? []).compactMap { $0.play }
        // Older/lighter payloads only carry coordinates on key events.
        plays.append(contentsOf: summary?.keyEvents ?? [])

        var seen = Set<String>()
        var result: [GDShot] = []
        for play in plays {
            guard let rawX = play.fieldPositionX, let rawY = play.fieldPositionY,
                  let typeText = play.type?.type?.lowercased() ?? play.type?.text?.lowercased() else { continue }
            let isGoal = typeText.contains("goal")
                && !typeText.contains("kick")
                && !typeText.contains("goalkeeper")
                && !typeText.contains("post")
            let isShot = typeText.contains("shot") || typeText.contains("attempt") || isGoal
            guard isShot, seen.insert(play.eventID).inserted else { continue }
            let (x, y) = Self.normalizedShotXY(x: rawX, y: rawY)
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

    /// ESPN uses two coordinate dialects: live games send 0–100 with the
    /// attacked goal at x = 100; archived games send 0–1 fractions with
    /// the attacked goal at x = 0. Normalize both to the live convention —
    /// without this, old games plotted every shot in one corner.
    nonisolated private static func normalizedShotXY(x: Double, y: Double) -> (Double, Double) {
        if x <= 1.0 && y <= 1.0 {
            return ((1.0 - x) * 100.0, y * 100.0)
        }
        return (x, y)
    }

    /// Every located play involving one athlete, for the player heatmap.
    /// ESPN only attaches pitch coordinates to shot-type plays, so this is
    /// effectively the player's shooting/chance map.
    func playerHeatPoints(athleteID: String) -> [GDHeatPoint] {
        var plays: [GSKeyEvent] = (summary?.commentary ?? []).compactMap { $0.play }
        plays.append(contentsOf: summary?.keyEvents ?? [])

        var seen = Set<String>()
        var out: [GDHeatPoint] = []
        for play in plays {
            guard let rawX = play.fieldPositionX, let rawY = play.fieldPositionY,
                  play.participants?.first?.athlete?.id == athleteID,
                  seen.insert(play.eventID).inserted else { continue }
            let typeText = (play.type?.type ?? play.type?.text ?? "").lowercased()
            let isGoal = typeText.contains("goal")
                && !typeText.contains("kick")
                && !typeText.contains("goalkeeper")
                && !typeText.contains("post")
            let isShot = typeText.contains("shot") || typeText.contains("attempt") || isGoal
            let (x, y) = Self.normalizedShotXY(x: rawX, y: rawY)
            out.append(GDHeatPoint(id: play.eventID, x: x, y: y, isShot: isShot, isGoal: isGoal))
        }
        return out
    }

    /// Rough expected-goals estimate from shot locations alone (distance +
    /// angle decay) — ESPN's feed carries no real xG, so this is our own
    /// model and is labeled "(est.)" in the UI.
    nonisolated static func estimatedXG(points: [GDHeatPoint]) -> Double? {
        let shots = points.filter { $0.isShot }
        guard !shots.isEmpty else { return nil }
        var total = 0.0
        for p in shots {
            // Meters to the goal line / off-center, on a 105×68 pitch.
            let dx = (100.0 - p.x) * 1.05
            let dy = (p.y - 50.0) * 0.68
            let distance = (dx * dx + dy * dy).squareRoot()
            total += min(0.95, max(0.02, 1.30 * exp(-0.115 * distance)))
        }
        return total
    }

    // MARK: Standings

    private static let soccerTableColumns = ["GP", "W", "D", "L", "GD", "P"]
    private static let usTableColumns = ["W", "L", "PCT", "GB", "STRK"]

    var standingsGroups: [GDStandingsGroup] {
        if let cached = derived.standingsGroups { return cached }
        let value = computeStandingsGroups()
        derived.standingsGroups = value
        return value
    }

    private func computeStandingsGroups() -> [GDStandingsGroup] {
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
        if let cached = derived.meetings { return cached }
        let value = computeMeetings()
        derived.meetings = value
        return value
    }

    /// Built once: a `DateFormatter` costs about a millisecond to make.
    nonisolated private static let meetingDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM yyyy"
        return df
    }()

    private func computeMeetings() -> [GDMeeting] {
        guard let events = summary?.headToHeadGames?.first?.events, !events.isEmpty else { return [] }
        let abbrevByID = [homeSide.id: homeSide.abbreviation, awaySide.id: awaySide.abbreviation]
        let nameHint = summary?.headToHeadGames?.first?.team
        let df = Self.meetingDateFormatter

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
        if let cached = derived.topPerformers { return cached }
        let value = computeTopPerformers()
        derived.topPerformers = value
        return value
    }

    private func computeTopPerformers() -> [GDLeaderRow] {
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
                    headshot: headshotURL(athlete) ?? resolvedHeadshots[athlete.id ?? ""],
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
    // Built once. Both formatters were being created per call — and this is
    // called per fixture while a scoreboard decodes. Configured and never
    // mutated again, both are safe to share between threads.
    private static let iso: ISO8601DateFormatter = {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso
    }()
    private static let minuteOnly: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return df
    }()

    static func parse(_ raw: String) -> Date? {
        if let d = iso.date(from: raw) { return d }
        return minuteOnly.date(from: raw)
    }
}

/// Photos and ages found by name for the players ESPN has neither for.
///
/// Its own object rather than two @Published maps on the game model: the
/// whole card observes the model, so each batch of lookups landing re-ran
/// the card's entire body — header, chips, every tab — every two seconds for
/// as long as the sweep took. Only the views that draw a player observe
/// this, so a batch re-renders the lineup and the leaders and nothing else.
@MainActor
final class PlayerLookupBook: ObservableObject {
    /// athleteID → photo URL.
    @Published private(set) var photos: [String: String] = [:]
    /// athleteID → age in years.
    @Published private(set) var ages: [String: Int] = [:]

    /// Replaces both maps, publishing each only if it moved.
    func merge(photos newPhotos: [String: String], ages newAges: [String: Int]) {
        if newPhotos != photos { photos = newPhotos }
        if newAges != ages { ages = newAges }
    }
}
