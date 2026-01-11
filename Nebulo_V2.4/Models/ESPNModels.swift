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
    
    // Cache the parsed date to avoid repeated formatter creation and actor isolation issues
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
        
        // Parse date once
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: self.date) {
            self._dateParsed = d
        } else {
            formatter.formatOptions = [.withInternetDateTime]
            self._dateParsed = formatter.date(from: self.date)
        }
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
        return _dateParsed ?? Date()
    }
    
    static func == (lhs: ESPNEvent, rhs: ESPNEvent) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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
