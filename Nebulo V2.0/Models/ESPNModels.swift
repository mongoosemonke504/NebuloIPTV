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
    var leagueLabel: String? = nil
    var homeCompetitor: ESPNCompetitor? { competitions.first?.competitors.first(where: { $0.homeAway == "home" }) }
    var awayCompetitor: ESPNCompetitor? { competitions.first?.competitors.first(where: { $0.homeAway == "away" }) }
    var broadcastName: String? { competitions.first?.broadcasts?.first?.names.first }
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

struct ESPNStatus: Codable, Hashable, Sendable { let type: ESPNStatusType }
struct ESPNStatusType: Codable, Hashable, Sendable { let detail: String; let state: String }
struct ESPNCompetition: Codable, Hashable, Sendable { let competitors: [ESPNCompetitor]; let broadcasts: [ESPNBroadcast]?; let leaders: [ESPNLeader]? }
struct ESPNBroadcast: Codable, Hashable, Sendable { let names: [String] }
struct ESPNCompetitor: Codable, Identifiable, Hashable, Sendable { var id: String { team.id }; let homeAway: String; let score: String?; let team: ESPNTeam }
struct ESPNTeam: Codable, Hashable, Sendable { let id: String; let abbreviation: String?; let displayName: String?; let shortDisplayName: String?; let logo: String?; let color: String? }
struct ESPNLeader: Codable, Hashable, Sendable { let name: String?; let displayName: String?; let leaders: [ESPNLeaderEntry]? }
struct ESPNLeaderEntry: Codable, Hashable, Sendable { let displayValue: String?; let athlete: ESPNAthlete? }
struct ESPNAthlete: Codable, Hashable, Sendable { let displayName: String?; let headshot: String? }
