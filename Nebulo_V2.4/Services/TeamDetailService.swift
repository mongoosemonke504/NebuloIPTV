import Foundation

/// Everything ESPN's public site API will tell us about ONE team, for the
/// team page opened from a favourite: identity and colours, the season record
/// broken down by split, where they sit in the table, the venue, and the full
/// season schedule.
///
/// Two endpoints back this:
///   • `…/teams/{id}` — profile, colours, record splits, standing summary,
///     venue, and the next scheduled event.
///   • `…/teams/{id}/schedule` — every fixture of the current season, which
///     the scoreboard pool alone can't provide (it only spans a few days).
nonisolated enum TeamDetailService {

    // MARK: - Model

    struct RecordSplit: Identifiable, Sendable {
        let id: String
        /// "Overall", "Home", "Away", "vs. Conf." …
        let name: String
        /// "12-5" / "12-5-1"
        let summary: String
    }

    struct Profile: Sendable {
        let id: String
        let displayName: String
        let location: String?
        let abbreviation: String?
        /// Primary brand colour, hex without the leading "#".
        let color: String?
        let alternateColor: String?
        let logo: String?
        /// Season record, split by home/away/conference where ESPN has it.
        let records: [RecordSplit]
        /// "2nd in AFC West" — ESPN's own words.
        let standingSummary: String?
        let venueName: String?
        let venueCity: String?
        /// League/competition ESPN filed the team under.
        let leagueName: String?
    }

    // MARK: - Requests

    /// The `sport/league` path segment for a team lookup. Soccer clubs live
    /// under their competition ("soccer/eng.1"); the US leagues under their
    /// own sport path.
    static func apiPath(sport: SportType?, leagueLabel: String?) -> String? {
        guard let sport else { return nil }
        return LeagueDetailService.apiPath(sport: sport, leagueLabel: leagueLabel)
    }

    static func fetchProfile(sport: SportType?, leagueLabel: String?, teamID: String) async -> Profile? {
        guard let path = apiPath(sport: sport, leagueLabel: leagueLabel),
              let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/teams/\(teamID)")
        else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONDecoder().decode(TeamResponse.self, from: data),
              let t = res.team
        else { return nil }

        let splits: [RecordSplit] = (t.record?.items ?? []).compactMap { item in
            guard let summary = item.summary, !summary.isEmpty else { return nil }
            let name = item.description ?? item.type?.capitalized ?? "Record"
            return RecordSplit(id: name, name: name, summary: summary)
        }

        return Profile(
            id: t.id ?? teamID,
            displayName: t.displayName ?? t.name ?? "Unknown team",
            location: t.location,
            abbreviation: t.abbreviation,
            color: t.color,
            alternateColor: t.alternateColor,
            logo: t.logos?.first?.href,
            records: splits,
            standingSummary: t.standingSummary,
            venueName: t.franchise?.venue?.fullName,
            venueCity: [t.franchise?.venue?.address?.city, t.franchise?.venue?.address?.state]
                .compactMap { $0 }.joined(separator: ", ").nilIfEmpty,
            leagueName: res.team?.groups?.parent?.name
        )
    }

    /// The team's full season schedule. Falls back to [] for leagues ESPN
    /// doesn't expose one for — the page then shows only what the scoreboard
    /// pool already knows.
    static func fetchSchedule(sport: SportType?, leagueLabel: String?, teamID: String) async -> [ESPNEvent] {
        guard let path = apiPath(sport: sport, leagueLabel: leagueLabel),
              let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/teams/\(teamID)/schedule")
        else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONDecoder().decode(ScheduleResponse.self, from: data)
        else { return [] }
        return (res.events ?? []).sorted { $0.gameDate < $1.gameDate }
    }

    // MARK: - Squad

    struct Player: Identifiable, Sendable {
        let id: String
        let name: String
        let jersey: String?
        let position: String?
        let headshot: String?
    }

    /// The current squad. ESPN returns two different shapes for this endpoint —
    /// grouped by position for soccer, a flat list for the US leagues — so both
    /// are decoded and flattened into one roster.
    static func fetchRoster(sport: SportType?, leagueLabel: String?, teamID: String) async -> [Player] {
        guard let path = apiPath(sport: sport, leagueLabel: leagueLabel),
              let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/teams/\(teamID)/roster")
        else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONDecoder().decode(RosterResponse.self, from: data)
        else { return [] }

        let raw: [RosterResponse.Athlete]
        switch res.athletes {
        case .grouped(let groups): raw = groups.flatMap { $0.items ?? [] }
        case .flat(let list):      raw = list
        case .none:                raw = []
        }

        var seen = Set<String>()
        return raw.compactMap { a in
            guard let id = a.id, seen.insert(id).inserted else { return nil }
            let name = a.displayName ?? a.fullName ?? a.shortName
            guard let name, !name.isEmpty else { return nil }
            return Player(id: id,
                          name: name,
                          jersey: a.jersey,
                          position: a.position?.abbreviation ?? a.position?.name,
                          headshot: a.headshot?.href)
        }
    }

    // MARK: - Wire models (only the fields we read)

    private struct RosterResponse: Decodable {
        /// `athletes` is either [{position, items:[…]}] or [athlete…].
        enum Athletes: Decodable {
            case grouped([Group])
            case flat([Athlete])

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let groups = try? container.decode([Group].self), groups.contains(where: { $0.items != nil }) {
                    self = .grouped(groups)
                } else {
                    self = .flat((try? container.decode([Athlete].self)) ?? [])
                }
            }
        }
        struct Group: Decodable { let position: String?; let items: [Athlete]? }
        struct Athlete: Decodable {
            let id: String?
            let fullName: String?
            let displayName: String?
            let shortName: String?
            let jersey: String?
            let position: Position?
            let headshot: Headshot?
        }
        struct Position: Decodable { let name: String?; let abbreviation: String? }
        struct Headshot: Decodable { let href: String? }
        let athletes: Athletes?
    }

    private struct TeamResponse: Decodable {
        let team: Team?
        struct Team: Decodable {
            let id: String?
            let abbreviation: String?
            let displayName: String?
            let name: String?
            let location: String?
            let color: String?
            let alternateColor: String?
            let standingSummary: String?
            let logos: [Logo]?
            let record: Record?
            let franchise: Franchise?
            let groups: Groups?
        }
        struct Logo: Decodable { let href: String? }
        struct Record: Decodable { let items: [Item]? }
        struct Item: Decodable { let description: String?; let type: String?; let summary: String? }
        struct Franchise: Decodable { let venue: Venue? }
        struct Venue: Decodable { let fullName: String?; let address: Address? }
        struct Address: Decodable { let city: String?; let state: String? }
        struct Groups: Decodable { let parent: Parent? }
        struct Parent: Decodable { let name: String? }
    }

    /// The team schedule endpoint returns the same `events` shape as the
    /// scoreboard, so ESPNEvent decodes it directly.
    private struct ScheduleResponse: Decodable {
        let events: [ESPNEvent]?
    }
}

nonisolated private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
