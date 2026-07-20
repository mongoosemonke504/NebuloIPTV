import Foundation

nonisolated struct ESPNResponse: Codable, Sendable {
    let events: [ESPNEvent]?
}

struct ESPNEvent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let shortName: String
    let status: ESPNStatus
    let competitions: [ESPNCompetition]
    let date: String
    let groupings: [ESPNGrouping]?
    /// Tournament round / season phase, e.g. "group-stage", "round-of-16",
    /// "final" — or the season name for regular league play. Drives the
    /// bracket and round labels in the league detail sheet.
    let season: ESPNEventSeason?
    var leagueLabel: String? = nil
    /// Tournament round for tennis matches ("Final", "Round of 16", …) —
    /// nil for every other sport.
    var tennisRound: String? = nil
    /// "<tour>/<tournament event id>" ("wta/188-2026") — everything needed
    /// to re-find this match in ESPN's tennis APIs. Nil for other sports.
    var tennisPath: String? = nil


    private let _dateParsed: Date?

    enum CodingKeys: String, CodingKey {
        case id, shortName, status, competitions, date, groupings, season, leagueLabel, tennisRound, tennisPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.shortName = try container.decode(String.self, forKey: .shortName)
        self.status = try container.decode(ESPNStatus.self, forKey: .status)
        self.competitions = try container.decode([ESPNCompetition].self, forKey: .competitions)
        self.date = try container.decode(String.self, forKey: .date)
        self.groupings = try container.decodeIfPresent([ESPNGrouping].self, forKey: .groupings)
        self.season = try? container.decodeIfPresent(ESPNEventSeason.self, forKey: .season)
        self.leagueLabel = try container.decodeIfPresent(String.self, forKey: .leagueLabel)
        self.tennisRound = try container.decodeIfPresent(String.self, forKey: .tennisRound)
        self.tennisPath = try container.decodeIfPresent(String.self, forKey: .tennisPath)

        self._dateParsed = ESPNEvent.parseDate(self.date)
    }

    /// Builds a standalone event from parts — used to convert each tennis
    /// match (a competition inside a tournament's groupings) into its own
    /// scoreboard row.
    nonisolated init(id: String, shortName: String, status: ESPNStatus, competitions: [ESPNCompetition], date: String, leagueLabel: String? = nil, tennisRound: String? = nil, tennisPath: String? = nil) {
        self.id = id
        self.shortName = shortName
        self.status = status
        self.competitions = competitions
        self.date = date
        self.groupings = nil
        self.season = nil
        self.leagueLabel = leagueLabel
        self.tennisRound = tennisRound
        self.tennisPath = tennisPath
        self._dateParsed = ESPNEvent.parseDate(date)
    }

    /// ESPN's scoreboard API isn't strictly consistent — some endpoints return
    /// `2024-03-15T19:00Z` (no seconds), others include fractional seconds, and
    /// occasionally non-ISO formats slip through. Trying multiple shapes here
    /// matters: if parsing falls through and `_dateParsed` ends up `nil`, the
    /// home-screen smart header used to read `gameDate` as `Date()` and tell
    /// the user every unparseable game was starting "in 1 minute". Now we hand
    /// back nil and the consumer uses `.distantFuture` as a safe sentinel.
    private static func parseDate(_ raw: String) -> Date? {
        // 1. ISO-8601 with fractional seconds: 2024-03-15T19:00:00.123Z
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        // 2. ISO-8601 with seconds: 2024-03-15T19:00:00Z
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        // 3. Hand-rolled fallbacks for non-standard ESPN shapes (no seconds,
        //    no timezone marker, etc.). UTC enforced when the string is naïve.
        let formats = [
            "yyyy-MM-dd'T'HH:mm'Z'",
            "yyyy-MM-dd'T'HH:mmZZZZZ",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd HH:mm:ss"
        ]
        for fmt in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "UTC")
            df.dateFormat = fmt
            if let d = df.date(from: raw) { return d }
        }
        return nil
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(shortName, forKey: .shortName)
        try container.encode(status, forKey: .status)
        try container.encode(competitions, forKey: .competitions)
        try container.encode(date, forKey: .date)
        try container.encode(groupings, forKey: .groupings)
        try container.encodeIfPresent(season, forKey: .season)
        try container.encode(leagueLabel, forKey: .leagueLabel)
        try container.encodeIfPresent(tennisRound, forKey: .tennisRound)
        try container.encodeIfPresent(tennisPath, forKey: .tennisPath)
    }
    
    nonisolated var allCompetitions: [ESPNCompetition] {
        if !competitions.isEmpty { return competitions }
        return groupings?.flatMap { $0.competitions } ?? []
    }
    
    var homeCompetitor: ESPNCompetitor? { 
        allCompetitions.first?.competitors?.first(where: { $0.homeAway == "home" }) 
        ?? allCompetitions.first?.competitors?.first(where: { $0.order == 2 })
        ?? allCompetitions.first?.competitors?.last
    }
    var awayCompetitor: ESPNCompetitor? { 
        allCompetitions.first?.competitors?.first(where: { $0.homeAway == "away" }) 
        ?? allCompetitions.first?.competitors?.first(where: { $0.order == 1 })
        ?? allCompetitions.first?.competitors?.first
    }
    var broadcastName: String? { allCompetitions.first?.broadcasts?.first?.names.first }
    
    nonisolated var gameDate: Date {
        // Use .distantFuture as a safe sentinel when the date string couldn't
        // be parsed at all. Falling back to `Date()` would make the home-screen
        // smart header announce every unparseable game as starting "in 1
        // minute", which is exactly the false-positive we were seeing.
        return _dateParsed ?? .distantFuture
    }

    /// Pre-game status line in the app's own format, replacing whatever
    /// shape each ESPN feed uses (MLB's bare "Scheduled", other sports'
    /// full timestamps): "Today at 7:05 PM", "Tomorrow at 1:10 PM", then
    /// "Sat, 7/19 at 4:05 PM" from two days out. Non-schedule statuses
    /// (postponed, delayed, TBD) pass through untouched.
    nonisolated var scheduleAwareDetail: String {
        let detail = status.type.detail
        guard status.type.state == "pre" else { return detail }
        let date = gameDate
        guard date != .distantFuture else { return detail }
        let lower = detail.lowercased()
        for keyword in ["postpon", "delay", "tbd", "cancel", "suspend"] where lower.contains(keyword) {
            return detail
        }
        let time = DateFormatter()
        time.dateFormat = "h:mm a"
        let timeText = time.string(from: date)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today at \(timeText)" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow at \(timeText)" }
        let day = DateFormatter()
        day.dateFormat = "EEE, M/d"
        return "\(day.string(from: date)) at \(timeText)"
    }
}

nonisolated struct ESPNEventSeason: Codable, Hashable, Sendable { let slug: String? }
struct ESPNGrouping: Codable, Hashable, Sendable { let competitions: [ESPNCompetition] }
struct ESPNStatus: Codable, Hashable, Sendable { let type: ESPNStatusType }
struct ESPNStatusType: Codable, Hashable, Sendable {
    let detail: String
    let state: String
    /// ESPN's machine name ("STATUS_SUSPENDED", …). Decoded so tennis can
    /// tell a set-break/rain "suspension" apart from a finished match.
    var name: String? = nil
    var completed: Bool? = nil
}
struct ESPNCompetition: Codable, Hashable, Sendable {
    let competitors: [ESPNCompetitor]?
    let broadcasts: [ESPNBroadcast]?
    let leaders: [ESPNLeader]?
    /// Live in-game situation from the scoreboard feed — bases/count/outs
    /// for baseball, down & distance for football. Nil for other sports
    /// and finished games.
    var situation: ESPNSituation? = nil
}

/// Only the fields the Live Activity's situation line uses.
nonisolated struct ESPNSituation: Codable, Hashable, Sendable {
    let balls: Int?
    let strikes: Int?
    let outs: Int?
    let onFirst: Bool?
    let onSecond: Bool?
    let onThird: Bool?
    let downDistanceText: String?
    let shortDownDistanceText: String?
    let possessionText: String?
}
struct ESPNBroadcast: Codable, Hashable, Sendable { let names: [String] }
struct ESPNCompetitor: Codable, Identifiable, Hashable, Sendable {
    private let _id: String?
    let homeAway: String?
    let score: String?
    let team: ESPNTeam?
    let athlete: ESPNAthlete?
    let order: Int?
    let winner: Bool?
    /// Per-period scores — for tennis these are the per-set game counts,
    /// with `winner` marking sets the player took and `tiebreak` the
    /// tiebreak points.
    let linescores: [ESPNLinescore]?
    /// True while this side is serving (live tennis only).
    let possession: Bool?
    /// Doubles pairing — carries the combined display name and the two
    /// athletes (for their flags). Singles matches use `athlete` instead.
    let roster: ESPNRoster?
    /// World ranking / tournament seed where ESPN provides one.
    let curatedRank: ESPNCuratedRank?
    /// Win-loss records ("18-11-1") — MMA fighters carry these.
    let records: [ESPNRecordEntry]?

    enum CodingKeys: String, CodingKey {
        case _id = "id"
        case homeAway, score, team, athlete, order, winner, linescores, possession, roster, curatedRank, records
    }

    var id: String { _id ?? team?.id ?? athlete?.displayName ?? UUID().uuidString }

    nonisolated init(id: String?, homeAway: String?, score: String?, team: ESPNTeam?, athlete: ESPNAthlete?, order: Int?, winner: Bool?, linescores: [ESPNLinescore]?, possession: Bool? = nil, roster: ESPNRoster? = nil, curatedRank: ESPNCuratedRank? = nil, records: [ESPNRecordEntry]? = nil) {
        self._id = id
        self.homeAway = homeAway
        self.score = score
        self.team = team
        self.athlete = athlete
        self.order = order
        self.winner = winner
        self.linescores = linescores
        self.possession = possession
        self.roster = roster
        self.curatedRank = curatedRank
        self.records = records
    }
}
nonisolated struct ESPNCuratedRank: Codable, Hashable, Sendable { let current: Int? }
nonisolated struct ESPNRecordEntry: Codable, Hashable, Sendable { let summary: String? }
nonisolated struct ESPNLinescore: Codable, Hashable, Sendable { let value: Double?; let winner: Bool?; let tiebreak: Int? }
nonisolated struct ESPNRoster: Codable, Hashable, Sendable {
    let displayName: String?
    let shortDisplayName: String?
    let athletes: [ESPNAthlete]?
}
nonisolated struct ESPNTeam: Codable, Hashable, Sendable { let id: String; let abbreviation: String?; let displayName: String?; let shortDisplayName: String?; let logo: String?; let color: String? }
struct ESPNLeader: Codable, Hashable, Sendable { let name: String?; let displayName: String?; let leaders: [ESPNLeaderEntry]? }
struct ESPNLeaderEntry: Codable, Hashable, Sendable { let displayValue: String?; let athlete: ESPNAthlete? }
struct ESPNAthlete: Codable, Hashable, Sendable {
    let id: String?
    let displayName: String?
    let headshot: String?
    let flag: ESPNFlag?
    let fullName: String?
    let shortName: String?
}
struct ESPNFlag: Codable, Hashable, Sendable { let href: String? }

// MARK: - Tennis scoreboard

/// The tennis scoreboard's shape differs from every team sport: each event
/// is a whole tournament whose matches live inside `groupings` (Men's
/// Singles, Women's Singles, …) and carry their own status/date/round.
/// These mirror just enough of that JSON to convert each match into a
/// standalone `ESPNEvent`.
nonisolated struct TennisScoreboard: Codable, Sendable {
    let events: [TennisTournament]?
}
nonisolated struct TennisTournament: Codable, Sendable {
    let id: String?
    let name: String?
    let groupings: [TennisGroupingRaw]?
}
nonisolated struct TennisGroupingRaw: Codable, Sendable {
    let grouping: TennisGroupingInfo?
    let competitions: [TennisMatchRaw]?
}
nonisolated struct TennisGroupingInfo: Codable, Sendable {
    let slug: String?
    let displayName: String?
}
nonisolated struct TennisMatchRaw: Codable, Sendable {
    let id: String?
    let date: String?
    let status: ESPNStatus?
    let competitors: [ESPNCompetitor]?
    let broadcasts: [ESPNBroadcast]?
    let round: TennisRoundRaw?
}
nonisolated struct TennisRoundRaw: Codable, Sendable {
    let displayName: String?
}
