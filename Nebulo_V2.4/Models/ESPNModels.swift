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
    var gameDate: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: date) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: date) ?? Date()
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
