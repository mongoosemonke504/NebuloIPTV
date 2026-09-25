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

    /// Racing only: the track this weekend is at.
    var circuit: ESPNCircuit? = nil

    enum CodingKeys: String, CodingKey {
        case id, shortName, status, competitions, date, groupings, season, leagueLabel, tennisRound, tennisPath, circuit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.shortName = try container.decode(String.self, forKey: .shortName)
        self.competitions = try container.decode([ESPNCompetition].self, forKey: .competitions)
        // The scoreboard feed carries `status` on the event. The team-schedule
        // feed does NOT — it only hangs one off the competition. Requiring the
        // event-level key meant every schedule payload threw mid-array and
        // `fetchSchedule` returned nothing at all, so a team page only ever
        // showed the handful of games the scoreboard pool happened to hold.
        if let eventStatus = try? container.decode(ESPNStatus.self, forKey: .status) {
            self.status = eventStatus
        } else if let competitionStatus = self.competitions.first?.status {
            self.status = competitionStatus
        } else {
            throw DecodingError.keyNotFound(CodingKeys.status, DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "No status on the event or its first competition"
            ))
        }
        self.date = try container.decode(String.self, forKey: .date)
        self.groupings = try container.decodeIfPresent([ESPNGrouping].self, forKey: .groupings)
        self.season = try? container.decodeIfPresent(ESPNEventSeason.self, forKey: .season)
        self.leagueLabel = try container.decodeIfPresent(String.self, forKey: .leagueLabel)
        self.tennisRound = try container.decodeIfPresent(String.self, forKey: .tennisRound)
        self.tennisPath = try container.decodeIfPresent(String.self, forKey: .tennisPath)
        self.circuit = try? container.decodeIfPresent(ESPNCircuit.self, forKey: .circuit)

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
    nonisolated static func parseDate(_ raw: String) -> Date? {
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
    var broadcastName: String? {
        allCompetitions.first?.broadcasts?.compactMap(\.displayName).first
    }

    /// The network term the stream search should hunt for.
    ///
    /// A network match is by far the strongest signal the search has (+1000,
    /// and it fills the results list first). ESPN's golf and racing feeds hang
    /// no broadcast off the leaderboard competition, so those events reached
    /// the search with no network at all and had to get by on the event name —
    /// which for golf is mostly words like "The", "Open" and "Championship"
    /// that match half the guide. The sport's own name stands in: golf lives
    /// on channels with "golf" in the name, a Grand Prix on ones with "F1".
    nonisolated var streamNetworkHint: String? {
        if let broadcastName, !broadcastName.trimmingCharacters(in: .whitespaces).isEmpty {
            return broadcastName
        }
        if isRaceEvent { return "F1" }
        if isFieldEvent { return "golf" }
        return nil
    }

    // MARK: Racing
    //
    // A Grand Prix is one event holding five sessions — FP1, FP2, FP3,
    // qualifying and the race — each with its own clock and finishing order.
    // The event's own `status` is no use for the card: ESPN reports "Final" for
    // a weekend whose race hasn't been run, because a practice session has.

    /// One session of a race weekend.
    nonisolated struct RaceSession: Identifiable, Sendable {
        /// "FP1", "Qual", "Race".
        let label: String
        let state: String
        let detail: String
        let date: Date?
        /// Finishing order, first to last.
        let order: [ESPNCompetitor]
        var id: String { label }
        var isRace: Bool { label.lowercased().hasPrefix("race") }
    }

    nonisolated var raceSessions: [RaceSession] {
        competitions.enumerated().map { index, competition in
            let type = competition.type?.abbreviation ?? competition.type?.text ?? "Session \(index + 1)"
            let status = competition.status ?? status
            return RaceSession(
                label: type,
                state: status.type.state,
                detail: status.type.detail,
                date: competition.date.flatMap(ESPNEvent.parseDate),
                order: (competition.competitors ?? []).sorted { ($0.order ?? 99) < ($1.order ?? 99) }
            )
        }
    }

    /// The session to lead the card with: the one running now, else the next one
    /// due, else the race itself once the weekend is over.
    nonisolated var currentRaceSession: RaceSession? {
        let sessions = raceSessions
        return sessions.first { $0.state == "in" }
            ?? sessions.first { $0.state == "pre" }
            ?? sessions.last { $0.isRace }
            ?? sessions.last
    }

    /// The most recent session with a result to show.
    nonisolated var latestFinishedRaceSession: RaceSession? {
        raceSessions.last { $0.state == "post" && !$0.order.isEmpty }
    }

    /// A race weekend. Only racing events carry a circuit, so this needs no
    /// sport enum threaded through the view layer.
    nonisolated var isRaceEvent: Bool { circuit != nil }

    /// A FIELD event: dozens of individual entrants on a leaderboard rather
    /// than two sides on a scoreline — a golf tournament, a race weekend.
    nonisolated var isFieldEvent: Bool {
        let competitors = allCompetitions.first?.competitors ?? []
        return competitors.count > 4 && competitors.allSatisfy { $0.team == nil }
    }

    /// Whether this event should count as live right now.
    ///
    /// For most sports that's simply the event's own state. A race weekend is
    /// not: ESPN marks the EVENT "Final" as soon as a practice session ends, so
    /// a Grand Prix that was actually being run read as finished and never
    /// reached Live Now. Its sessions are the source of truth.
    nonisolated var isLiveNow: Bool {
        if status.type.state == "in" { return true }
        return competitions.contains { $0.status?.type.state == "in" }
    }

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
    /// The scoreboard feed repeats the event's status here; the team-schedule
    /// feed puts it ONLY here. See `ESPNEvent.init(from:)`.
    var status: ESPNStatus? = nil
    /// Which session this is, for racing: a Grand Prix event carries five
    /// competitions — FP1, FP2, FP3, Qual and Race — each with its own start
    /// time, status and finishing order.
    var type: ESPNCompetitionType? = nil
    var date: String? = nil
    /// Live in-game situation from the scoreboard feed — bases/count/outs
    /// for baseball, down & distance for football. Nil for other sports
    /// and finished games.
    var situation: ESPNSituation? = nil
}

nonisolated struct ESPNCompetitionType: Codable, Hashable, Sendable {
    /// "FP1", "Qual", "Race".
    let abbreviation: String?
    let text: String?
}

/// Racing venue — the only place ESPN names the track. Team sports use
/// `venue` on the competition instead.
nonisolated struct ESPNCircuit: Codable, Hashable, Sendable {
    /// Core-API circuit id — the key to the layout diagram, lap count and lap
    /// record, none of which the scoreboard carries.
    let id: String?
    let fullName: String?
    let address: Address?
    nonisolated struct Address: Codable, Hashable, Sendable {
        let city: String?
        let country: String?
    }

    /// "Hungaroring · Budapest, Hungary"
    var summary: String? {
        let place = [address?.city, address?.country].compactMap { $0 }.joined(separator: ", ")
        let parts = [fullName, place.isEmpty ? nil : place].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
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
/// The scoreboard feed says `{"names": ["FOX"]}`; the team-schedule feed says
/// `{"media": {"shortName": "MLB.TV"}, …}` with no `names` at all. Both shapes
/// have to decode — a required `names` threw on every schedule payload.
struct ESPNBroadcast: Codable, Hashable, Sendable {
    let names: [String]?
    let media: Media?

    nonisolated struct Media: Codable, Hashable, Sendable { let shortName: String? }

    /// The network to show, from whichever shape arrived.
    var displayName: String? {
        if let name = names?.first, !name.isEmpty { return name }
        if let short = media?.shortName, !short.isEmpty { return short }
        return nil
    }
}
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

    /// `score` is a bare string on the scoreboard ("6") but an object on the
    /// team-schedule feed (`{"value": 6.0, "displayValue": "6"}`), and an
    /// upcoming game has none at all. Decoding it as a String threw on every
    /// schedule payload, taking the whole fixture list with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self._id = try c.decodeIfPresent(String.self, forKey: ._id)
        self.homeAway = try c.decodeIfPresent(String.self, forKey: .homeAway)
        if let text = try? c.decode(String.self, forKey: .score) {
            self.score = text
        } else if let object = try? c.decode(ScoreObject.self, forKey: .score) {
            self.score = object.text
        } else {
            self.score = nil
        }
        self.team = try c.decodeIfPresent(ESPNTeam.self, forKey: .team)
        self.athlete = try c.decodeIfPresent(ESPNAthlete.self, forKey: .athlete)
        self.order = try c.decodeIfPresent(Int.self, forKey: .order)
        self.winner = try c.decodeIfPresent(Bool.self, forKey: .winner)
        self.linescores = try c.decodeIfPresent([ESPNLinescore].self, forKey: .linescores)
        self.possession = try c.decodeIfPresent(Bool.self, forKey: .possession)
        self.roster = try c.decodeIfPresent(ESPNRoster.self, forKey: .roster)
        self.curatedRank = try c.decodeIfPresent(ESPNCuratedRank.self, forKey: .curatedRank)
        self.records = try c.decodeIfPresent([ESPNRecordEntry].self, forKey: .records)
    }

    private struct ScoreObject: Codable {
        let value: Double?
        let displayValue: String?
        var text: String? {
            if let displayValue, !displayValue.isEmpty { return displayValue }
            guard let value else { return nil }
            return value == value.rounded() ? String(Int(value)) : String(value)
        }
    }

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
nonisolated struct ESPNTeam: Codable, Hashable, Sendable {
    let id: String
    let abbreviation: String?
    let displayName: String?
    let shortDisplayName: String?
    let logo: String?
    let color: String?
    /// "Los Angeles" / "Lakers" — the two halves of the display name, as the
    /// feed splits them. Guides name a side by either half as often as by
    /// both, so the stream search wants each on its own. Nil for teams the
    /// catalog built before these were kept.
    let location: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id, abbreviation, displayName, shortDisplayName, logo, color, logos, location, name
    }

    nonisolated struct Logo: Codable, Hashable, Sendable { let href: String? }

    /// The scoreboard feed gives a flat `logo` string; the team-schedule feed
    /// gives a `logos` array instead. Without the second shape every crest in a
    /// fixture list came out blank.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.abbreviation = try c.decodeIfPresent(String.self, forKey: .abbreviation)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        self.shortDisplayName = try c.decodeIfPresent(String.self, forKey: .shortDisplayName)
        self.color = try c.decodeIfPresent(String.self, forKey: .color)
        self.location = try c.decodeIfPresent(String.self, forKey: .location)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        if let flat = try c.decodeIfPresent(String.self, forKey: .logo), !flat.isEmpty {
            self.logo = flat
        } else {
            self.logo = (try? c.decodeIfPresent([Logo].self, forKey: .logos))?
                .flatMap { $0.compactMap(\.href).first }
        }
    }

    nonisolated init(id: String, abbreviation: String?, displayName: String?,
                     shortDisplayName: String?, logo: String?, color: String?,
                     location: String? = nil, name: String? = nil) {
        self.id = id
        self.abbreviation = abbreviation
        self.displayName = displayName
        self.shortDisplayName = shortDisplayName
        self.logo = logo
        self.color = color
        self.location = location
        self.name = name
    }

    /// Written out in the scoreboard's flat shape — this is what the persisted
    /// scheduled recordings and Live Activity payloads read back.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(abbreviation, forKey: .abbreviation)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(shortDisplayName, forKey: .shortDisplayName)
        try c.encodeIfPresent(logo, forKey: .logo)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(name, forKey: .name)
    }
}
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
