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
    var leagueLabel: String? = nil
    
    
    private let _dateParsed: Date?
    
    enum CodingKeys: String, CodingKey {
        case id, shortName, status, competitions, date, groupings, leagueLabel
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.shortName = try container.decode(String.self, forKey: .shortName)
        self.status = try container.decode(ESPNStatus.self, forKey: .status)
        self.competitions = try container.decode([ESPNCompetition].self, forKey: .competitions)
        self.date = try container.decode(String.self, forKey: .date)
        self.groupings = try container.decodeIfPresent([ESPNGrouping].self, forKey: .groupings)
        self.leagueLabel = try container.decodeIfPresent(String.self, forKey: .leagueLabel)

        self._dateParsed = ESPNEvent.parseDate(self.date)
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
        try container.encode(leagueLabel, forKey: .leagueLabel)
    }
    
    var allCompetitions: [ESPNCompetition] {
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
}

struct ESPNGrouping: Codable, Hashable, Sendable { let competitions: [ESPNCompetition] }
struct ESPNStatus: Codable, Hashable, Sendable { let type: ESPNStatusType }
struct ESPNStatusType: Codable, Hashable, Sendable { let detail: String; let state: String }
struct ESPNCompetition: Codable, Hashable, Sendable { let competitors: [ESPNCompetitor]?; let broadcasts: [ESPNBroadcast]?; let leaders: [ESPNLeader]? }
struct ESPNBroadcast: Codable, Hashable, Sendable { let names: [String] }
struct ESPNCompetitor: Codable, Identifiable, Hashable, Sendable {
    private let _id: String?
    let homeAway: String?
    let score: String?
    let team: ESPNTeam?
    let athlete: ESPNAthlete?
    let order: Int?
    let winner: Bool?
    
    enum CodingKeys: String, CodingKey {
        case _id = "id"
        case homeAway, score, team, athlete, order, winner
    }
    
    var id: String { _id ?? team?.id ?? athlete?.displayName ?? UUID().uuidString }
}
struct ESPNTeam: Codable, Hashable, Sendable { let id: String; let abbreviation: String?; let displayName: String?; let shortDisplayName: String?; let logo: String?; let color: String? }
struct ESPNLeader: Codable, Hashable, Sendable { let name: String?; let displayName: String?; let leaders: [ESPNLeaderEntry]? }
struct ESPNLeaderEntry: Codable, Hashable, Sendable { let displayValue: String?; let athlete: ESPNAthlete? }
struct ESPNAthlete: Codable, Hashable, Sendable { 
    let displayName: String?
    let headshot: String?
    let flag: ESPNFlag?
    let fullName: String?
    let shortName: String?
}
struct ESPNFlag: Codable, Hashable, Sendable { let href: String? }
