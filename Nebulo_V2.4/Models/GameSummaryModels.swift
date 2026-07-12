import Foundation

/// Models for ESPN's game summary endpoint
/// (`site.api.espn.com/apis/site/v2/sports/{sport}/{league}/summary?event={id}`).
///
/// The schema varies by sport — soccer gets `rosters` (lineups + formation)
/// and `headToHeadGames`, US sports get `boxscore.players` and
/// `winprobability` — so every section is optional and the top-level decode
/// isolates each section with `try?`: one malformed section must never take
/// down the whole detail page.

/// Decodes a value ESPN sometimes sends as a string and sometimes as a
/// number (jersey numbers, formation places).
nonisolated struct GSFlexString: Codable, Hashable, Sendable {
    let value: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(Int(d)) }
        else { value = "" }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

nonisolated struct GameSummary: Codable, Sendable {
    let header: GSHeader?
    let boxscore: GSBoxscore?
    let rosters: [GSRoster]?
    let keyEvents: [GSKeyEvent]?
    let headToHeadGames: [GSGameGroup]?
    let lastFiveGames: [GSGameGroup]?
    let gameInfo: GSGameInfo?
    let winprobability: [GSWinProb]?
    let leaders: [GSTeamLeaders]?
    let seasonseries: [GSSeasonSeries]?
    let commentary: [GSCommentaryItem]?
    let standings: GSStandings?
    let situation: GSSituation?

    enum CodingKeys: String, CodingKey {
        case header, boxscore, rosters, keyEvents, headToHeadGames,
             lastFiveGames, gameInfo, winprobability, leaders, seasonseries,
             commentary, standings, situation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        header = try? c.decodeIfPresent(GSHeader.self, forKey: .header)
        boxscore = try? c.decodeIfPresent(GSBoxscore.self, forKey: .boxscore)
        rosters = try? c.decodeIfPresent([GSRoster].self, forKey: .rosters)
        keyEvents = try? c.decodeIfPresent([GSKeyEvent].self, forKey: .keyEvents)
        headToHeadGames = try? c.decodeIfPresent([GSGameGroup].self, forKey: .headToHeadGames)
        lastFiveGames = try? c.decodeIfPresent([GSGameGroup].self, forKey: .lastFiveGames)
        gameInfo = try? c.decodeIfPresent(GSGameInfo.self, forKey: .gameInfo)
        winprobability = try? c.decodeIfPresent([GSWinProb].self, forKey: .winprobability)
        leaders = try? c.decodeIfPresent([GSTeamLeaders].self, forKey: .leaders)
        seasonseries = try? c.decodeIfPresent([GSSeasonSeries].self, forKey: .seasonseries)
        commentary = try? c.decodeIfPresent([GSCommentaryItem].self, forKey: .commentary)
        standings = try? c.decodeIfPresent(GSStandings.self, forKey: .standings)
        situation = try? c.decodeIfPresent(GSSituation.self, forKey: .situation)
    }
}

// MARK: - Live situation

/// The "current moment" block ESPN only sends while a game is in progress.
/// Baseball carries the count, outs, and base runners; football carries the
/// down & distance and possession.
nonisolated struct GSSituation: Codable, Sendable {
    let balls: Int?
    let strikes: Int?
    let outs: Int?
    let onFirst: GSSituationPlayer?
    let onSecond: GSSituationPlayer?
    let onThird: GSSituationPlayer?
    let batter: GSSituationPlayer?
    let pitcher: GSSituationPlayer?
    /// Sent between innings instead of batter/pitcher.
    let dueUp: [GSSituationPlayer]?
    let down: Int?
    let distance: Int?
    let downDistanceText: String?
    let shortDownDistanceText: String?
    let possessionText: String?
    let isRedZone: Bool?
    /// Team id of the side with the ball (football).
    let possession: GSFlexString?
    let lastPlay: GSSituationLastPlay?
}

/// Situation player references carry only a numeric id — names get resolved
/// against the box score.
nonisolated struct GSSituationPlayer: Codable, Sendable {
    let playerId: GSFlexString?
}

nonisolated struct GSSituationLastPlay: Codable, Sendable {
    let id: String?
    let text: String?
}

// MARK: - Header

nonisolated struct GSHeader: Codable, Sendable {
    let competitions: [GSHeaderCompetition]?
    let league: GSLeague?
}

nonisolated struct GSLeague: Codable, Sendable {
    let name: String?
    let abbreviation: String?
}

nonisolated struct GSHeaderCompetition: Codable, Sendable {
    let competitors: [GSHeaderCompetitor]?
    let status: GSStatus?
    let date: String?
}

nonisolated struct GSStatus: Codable, Sendable {
    let displayClock: String?
    let period: Int?
    let type: GSStatusType?
}

nonisolated struct GSStatusType: Codable, Sendable {
    let state: String?
    let detail: String?
    let shortDetail: String?
    let completed: Bool?
}

nonisolated struct GSHeaderCompetitor: Codable, Sendable {
    let homeAway: String?
    let score: String?
    let winner: Bool?
    let order: Int?
    let team: GSTeam?
    let record: [GSRecord]?

    enum CodingKeys: String, CodingKey { case homeAway, score, winner, order, team, record }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        homeAway = try? c.decodeIfPresent(String.self, forKey: .homeAway)
        score = try? c.decodeIfPresent(String.self, forKey: .score)
        winner = try? c.decodeIfPresent(Bool.self, forKey: .winner)
        order = try? c.decodeIfPresent(Int.self, forKey: .order)
        team = try? c.decodeIfPresent(GSTeam.self, forKey: .team)
        // Array of objects for US sports, sometimes a bare string for soccer.
        record = try? c.decodeIfPresent([GSRecord].self, forKey: .record)
    }
}

nonisolated struct GSRecord: Codable, Sendable {
    let type: String?
    let summary: String?
    let displayValue: String?
}

nonisolated struct GSTeam: Codable, Sendable {
    let id: String?
    let displayName: String?
    let shortDisplayName: String?
    let abbreviation: String?
    let color: String?
    let alternateColor: String?
    let logo: String?
    let logos: [GSLogo]?

    var anyLogo: String? { logo ?? logos?.first?.href }
}

nonisolated struct GSLogo: Codable, Sendable { let href: String? }

// MARK: - Box score

nonisolated struct GSBoxscore: Codable, Sendable {
    let teams: [GSBoxTeam]?
    let players: [GSBoxPlayers]?
}

nonisolated struct GSBoxTeam: Codable, Sendable {
    let team: GSTeam?
    let homeAway: String?
    let statistics: [GSTeamStat]?
    let displayOrder: Int?
}

nonisolated struct GSTeamStat: Codable, Sendable {
    let name: String?
    let displayValue: String?
    let label: String?
    let abbreviation: String?
}

nonisolated struct GSBoxPlayers: Codable, Sendable {
    let team: GSTeam?
    let statistics: [GSStatGroup]?
    let displayOrder: Int?
}

nonisolated struct GSStatGroup: Codable, Sendable {
    let name: String?
    let type: String?
    let text: String?
    let names: [String]?
    let labels: [String]?
    let keys: [String]?
    let totals: [String]?
    let athletes: [GSBoxAthlete]?

    /// Column headers — NBA/soccer use `names`, NFL/MLB use `labels`.
    var columns: [String] { labels ?? names ?? [] }
    var title: String { text ?? (name ?? type ?? "").capitalized }
}

nonisolated struct GSBoxAthlete: Codable, Sendable {
    let athlete: GSAthlete?
    let starter: Bool?
    let didNotPlay: Bool?
    let stats: [String]?
}

nonisolated struct GSAthlete: Codable, Sendable {
    let id: String?
    let displayName: String?
    let shortName: String?
    let lastName: String?
    let jersey: GSFlexString?
    let headshot: GSHeadshot?
    let position: GSPosition?

    var compactName: String { shortName ?? lastName ?? displayName ?? "—" }
}

nonisolated struct GSHeadshot: Codable, Sendable {
    let href: String?

    enum CodingKeys: String, CodingKey { case href }

    init(from decoder: Decoder) throws {
        // Object `{href, alt}` in box scores, occasionally a bare URL string.
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            href = try? c.decodeIfPresent(String.self, forKey: .href)
        } else if let c = try? decoder.singleValueContainer() {
            href = try? c.decode(String.self)
        } else {
            href = nil
        }
    }
}

nonisolated struct GSPosition: Codable, Sendable {
    let name: String?
    let displayName: String?
    let abbreviation: String?
}

// MARK: - Lineups (soccer)

nonisolated struct GSRoster: Codable, Sendable {
    let team: GSTeam?
    let homeAway: String?
    let formation: String?
    let roster: [GSRosterPlayer]?
}

nonisolated struct GSRosterPlayer: Codable, Sendable {
    let active: Bool?
    let starter: Bool?
    let jersey: GSFlexString?
    let formationPlace: GSFlexString?
    let position: GSPosition?
    let athlete: GSAthlete?
    let stats: [GSPlayerStat]?
    let subbedIn: GSSubbed?
    let subbedOut: GSSubbed?
}

/// `subbedIn`/`subbedOut` are a bare bool for unused players but an object
/// (`{didSub, period, clock}`) once a substitution actually happened.
nonisolated struct GSSubbed: Codable, Sendable {
    let didSub: Bool
    let clock: String?

    enum CodingKeys: String, CodingKey { case didSub, clock }
    enum ClockKeys: String, CodingKey { case displayValue }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer(), let b = try? c.decode(Bool.self) {
            didSub = b; clock = nil
        } else if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            didSub = (try? c.decodeIfPresent(Bool.self, forKey: .didSub)) ?? true
            if let clockC = try? c.nestedContainer(keyedBy: ClockKeys.self, forKey: .clock) {
                clock = try? clockC.decodeIfPresent(String.self, forKey: .displayValue)
            } else { clock = nil }
        } else {
            didSub = false; clock = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(didSub)
    }
}

nonisolated struct GSPlayerStat: Codable, Sendable {
    let name: String?
    let abbreviation: String?
    let displayValue: String?
    let value: Double?
}

// MARK: - Key events

nonisolated struct GSKeyEvent: Codable, Identifiable, Sendable {
    let id: String?
    let type: GSEventType?
    let clock: GSClock?
    let team: GSMiniTeam?
    let participants: [GSParticipant]?
    let text: String?
    let shortText: String?
    let period: GSPeriod?
    let scoringPlay: Bool?
    /// Pitch coordinates (0–100 along each axis, x toward the attacked
    /// goal) — present on shot/goal plays, used for the shot map.
    let fieldPositionX: Double?
    let fieldPositionY: Double?
    let fieldPosition2X: Double?
    let fieldPosition2Y: Double?

    var eventID: String { id ?? "\(clock?.value ?? 0)-\(type?.id ?? "")" }
}

/// One commentary line; shot/goal entries carry a full `play` object with
/// pitch coordinates (same shape as a key event).
nonisolated struct GSCommentaryItem: Codable, Sendable {
    let text: String?
    let play: GSKeyEvent?

    enum CodingKeys: String, CodingKey { case text, play }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        play = try? c.decodeIfPresent(GSKeyEvent.self, forKey: .play)
    }
}

// MARK: - Standings

nonisolated struct GSStandings: Codable, Sendable {
    let groups: [GSStandingsGroup]?
}

nonisolated struct GSStandingsGroup: Codable, Sendable {
    let header: String?
    let standings: GSStandingsEntries?
}

nonisolated struct GSStandingsEntries: Codable, Sendable {
    let entries: [GSStandingEntry]?
}

nonisolated struct GSStandingEntry: Codable, Sendable {
    /// ESPN team id — matches the header competitors' team ids, which is
    /// how the two teams in this game get highlighted in the table.
    let id: String?
    /// Plain display-name string in this endpoint (not a team object).
    let team: String?
    let logo: [GSLogo]?
    let stats: [GSTeamStat]?

    enum CodingKeys: String, CodingKey { case id, team, logo, stats }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .id)).map(String.init)
        team = try? c.decodeIfPresent(String.self, forKey: .team)
        logo = (try? c.decodeIfPresent([GSLogo].self, forKey: .logo))
            ?? (try? c.decodeIfPresent(String.self, forKey: .logo)).map { [GSLogo(href: $0)] }
        stats = try? c.decodeIfPresent([GSTeamStat].self, forKey: .stats)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(team, forKey: .team)
        try c.encodeIfPresent(stats, forKey: .stats)
    }
}

nonisolated struct GSEventType: Codable, Sendable {
    let id: String?
    let text: String?
    let type: String?
}

nonisolated struct GSClock: Codable, Sendable {
    let value: Double?
    let displayValue: String?
}

nonisolated struct GSMiniTeam: Codable, Sendable {
    let id: String?
    let displayName: String?
}

nonisolated struct GSParticipant: Codable, Sendable {
    let athlete: GSAthlete?
}

nonisolated struct GSPeriod: Codable, Sendable { let number: Int? }

// MARK: - Past games (H2H + form)

nonisolated struct GSGameGroup: Codable, Sendable {
    let team: GSMiniTeam?
    let events: [GSPrevGame]?
    let displayOrder: Int?
}

nonisolated struct GSPrevGame: Codable, Identifiable, Sendable {
    let id: String?
    let gameDate: String?
    let homeTeamId: String?
    let awayTeamId: String?
    let homeTeamScore: String?
    let awayTeamScore: String?
    let leagueName: String?
    let leagueAbbreviation: String?
    let opponent: GSOpponent?
    let opponentLogo: String?
    let gameResult: String?
    let atVs: String?
    let score: String?

    var gameID: String { id ?? "\(gameDate ?? "")-\(opponent?.id ?? "")" }
}

nonisolated struct GSOpponent: Codable, Sendable {
    let id: String?
    let displayName: String?
    let abbreviation: String?
    let logo: String?
}

// MARK: - Game info

nonisolated struct GSGameInfo: Codable, Sendable {
    let venue: GSVenue?
    let attendance: Int?
    let officials: [GSOfficial]?
}

nonisolated struct GSVenue: Codable, Sendable {
    let fullName: String?
    let shortName: String?
    let address: GSAddress?
    let images: [GSLogo]?
}

nonisolated struct GSAddress: Codable, Sendable {
    let city: String?
    let state: String?
    let country: String?
}

nonisolated struct GSOfficial: Codable, Sendable {
    let displayName: String?
    let position: GSPosition?

    enum CodingKeys: String, CodingKey { case displayName, position, fullName }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName))
            ?? (try? c.decodeIfPresent(String.self, forKey: .fullName))
        position = try? c.decodeIfPresent(GSPosition.self, forKey: .position)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(position, forKey: .position)
    }
}

// MARK: - Win probability

nonisolated struct GSWinProb: Codable, Sendable {
    let homeWinPercentage: Double?
    let tiePercentage: Double?
    let playId: String?
}

// MARK: - Leaders

nonisolated struct GSTeamLeaders: Codable, Sendable {
    let team: GSTeam?
    let leaders: [GSLeaderCategory]?
}

nonisolated struct GSLeaderCategory: Codable, Sendable {
    let name: String?
    let displayName: String?
    let leaders: [GSLeaderEntry]?
}

nonisolated struct GSLeaderEntry: Codable, Sendable {
    let displayValue: String?
    let athlete: GSAthlete?
}

// MARK: - Season series

nonisolated struct GSSeasonSeries: Codable, Sendable {
    let summary: String?
    let title: String?
    let description: String?
}
