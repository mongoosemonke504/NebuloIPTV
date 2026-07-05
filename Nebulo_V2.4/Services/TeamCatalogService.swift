import Foundation

/// Fetches and caches the full team catalog from the ESPN site API — every
/// team in every league the app covers (each sport's own team list plus all
/// soccer competitions from `SportType.soccerCompetitionGroups`), and the
/// Formula 1 drivers from the championship standings. National soccer teams
/// come from the international competitions (World Cup, Euro, Copa América…).
///
/// Future-proofing, by design:
///   • Adding a sport: give it a scoreboard `endpoint` in `SportType` — its
///     team list is derived automatically via `apiPath`.
///   • Adding a soccer competition: one line in
///     `SportType.soccerCompetitionGroups` and its teams appear here too.
///   • Failures are per-league: one bad endpoint never empties the catalog,
///     and a league that fails or comes back empty (off-season tournaments)
///     keeps its previous teams thanks to the merge in `fetch(previous:)`.
///   • The catalog persists to disk and refreshes at most once a week —
///     team lists barely change, so launches are instant and offline-safe.
nonisolated enum TeamCatalogService {

    struct Entry: Codable, Sendable {
        let team: ESPNTeam
        /// Stored as the raw string so a renamed/removed SportType in a
        /// future version degrades to "skip this entry", never a decode
        /// failure that would nuke the whole cached catalog.
        let sportRaw: String
        let leagueLabel: String?
        var sport: SportType? { SportType(rawValue: sportRaw) }
    }

    struct Catalog: Codable, Sendable {
        let fetchedAt: Date
        let entries: [Entry]
    }

    static let refreshInterval: TimeInterval = 7 * 24 * 3600

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NebuloTeamCatalog.json")
    }

    static func loadCached() -> Catalog? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Catalog.self, from: data)
    }

    private static func save(_ catalog: Catalog) {
        if let data = try? JSONEncoder().encode(catalog) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    // MARK: - Fetch

    /// One fetchable unit — a single league's team list, or the F1 driver
    /// standings. Units are ordered: when the same team id shows up in
    /// several units (a club in its league and again in a cup), the first
    /// unit wins, so teams get labeled with their primary competition.
    private struct Unit {
        let sport: SportType
        let leagueLabel: String?
        let url: URL
        let kind: Kind
        enum Kind { case teamList, f1Drivers }
    }

    private static func makeUnits() -> [Unit] {
        var units: [Unit] = []
        for sport in SportType.allCases {
            if sport == .f1 {
                // Racing has no team list — the drivers ARE the "teams",
                // sourced from the championship standings (one request
                // covers the whole grid, updated as the season evolves).
                if let url = URL(string: "https://site.api.espn.com/apis/v2/sports/racing/f1/standings") {
                    units.append(Unit(sport: .f1, leagueLabel: nil, url: url, kind: .f1Drivers))
                }
                continue
            }
            guard let path = sport.apiPath,
                  let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/teams?limit=1000")
            else { continue }
            units.append(Unit(sport: sport, leagueLabel: nil, url: url, kind: .teamList))
        }
        for group in SportType.soccerCompetitionGroups {
            for comp in group.competitions {
                guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/soccer/\(comp.code)/teams?limit=1000")
                else { continue }
                units.append(Unit(sport: group.sport, leagueLabel: comp.name, url: url, kind: .teamList))
            }
        }
        return units
    }

    /// Stable per-league key used to decide which previous entries to retain.
    private static func unitKey(_ sportRaw: String, _ leagueLabel: String?) -> String {
        sportRaw + "|" + (leagueLabel ?? "")
    }

    /// Dedupe key for a team. ESPN ids are only unique within a sport, and
    /// the four soccer buckets share one id pool — the same club appears in
    /// its league, a domestic cup, and a continental competition, and must
    /// be listed once (labeled by the first unit that contains it).
    private static func dedupeKey(_ sportRaw: String, _ teamID: String) -> String {
        let sportKey = (SportType(rawValue: sportRaw)?.isSoccer == true) ? "Soccer" : sportRaw
        return sportKey + "#" + teamID
    }

    /// Fetches every unit in parallel, dedupes in unit order, and merges with
    /// `previous`: any league that produced nothing this pass (transient
    /// failure, or a tournament between seasons) keeps its old teams.
    /// Returns `previous` untouched if the network is fully unreachable.
    static func fetch(previous: [Entry]) async -> [Entry] {
        let units = makeUnits()
        var perUnit: [Int: [Entry]] = [:]

        await withTaskGroup(of: (Int, [Entry]).self) { group in
            for (idx, unit) in units.enumerated() {
                group.addTask {
                    (idx, (try? await fetchUnit(unit)) ?? [])
                }
            }
            for await (idx, entries) in group {
                perUnit[idx] = entries
            }
        }

        let fetchedKeys = Set(units.indices.compactMap { idx in
            (perUnit[idx]?.isEmpty == false) ? unitKey(units[idx].sport.rawValue, units[idx].leagueLabel) : nil
        })
        guard !fetchedKeys.isEmpty else { return previous }

        var seen = Set<String>()
        var out: [Entry] = []
        for idx in units.indices {
            for entry in perUnit[idx] ?? [] {
                if seen.insert(dedupeKey(entry.sportRaw, entry.team.id)).inserted {
                    out.append(entry)
                }
            }
        }
        for entry in previous where !fetchedKeys.contains(unitKey(entry.sportRaw, entry.leagueLabel)) {
            if seen.insert(dedupeKey(entry.sportRaw, entry.team.id)).inserted {
                out.append(entry)
            }
        }

        save(Catalog(fetchedAt: Date(), entries: out))
        return out
    }

    private static func fetchUnit(_ unit: Unit) async throws -> [Entry] {
        let (data, _) = try await URLSession.shared.data(from: unit.url)
        switch unit.kind {
        case .teamList:
            let res = try JSONDecoder().decode(TeamListResponse.self, from: data)
            let holders = res.sports?.first?.leagues?.first?.teams ?? []
            return holders.compactMap { holder in
                let t = holder.team
                guard t.isActive ?? true else { return nil }
                let logo = t.logos?.first(where: { $0.rel?.contains("default") ?? false })?.href
                    ?? t.logos?.first?.href
                return Entry(
                    team: ESPNTeam(id: t.id,
                                   abbreviation: t.abbreviation,
                                   displayName: t.displayName,
                                   shortDisplayName: t.shortDisplayName,
                                   logo: logo,
                                   color: t.color),
                    sportRaw: unit.sport.rawValue,
                    leagueLabel: unit.leagueLabel
                )
            }
        case .f1Drivers:
            let res = try JSONDecoder().decode(StandingsResponse.self, from: data)
            let drivers = res.children?
                .first(where: { ($0.name ?? "").localizedCaseInsensitiveContains("driver") })?
                .standings?.entries ?? []
            return drivers.compactMap { entry in
                guard let a = entry.athlete, let id = a.id else { return nil }
                // ESPN publishes racing headshots at a stable URL keyed by
                // athlete id (same asset the standings pages use).
                let headshot = "https://a.espncdn.com/i/headshots/rpm/players/full/\(id).png"
                return Entry(
                    team: ESPNTeam(id: id,
                                   abbreviation: a.abbreviation,
                                   displayName: a.displayName,
                                   shortDisplayName: a.shortName,
                                   logo: headshot,
                                   color: nil),
                    sportRaw: SportType.f1.rawValue,
                    leagueLabel: nil
                )
            }
        }
    }

    // MARK: - Wire models (only the fields we read)

    private struct TeamListResponse: Decodable {
        struct SportNode: Decodable { let leagues: [LeagueNode]? }
        struct LeagueNode: Decodable { let teams: [TeamHolder]? }
        struct TeamHolder: Decodable { let team: APITeam }
        struct APITeam: Decodable {
            let id: String
            let abbreviation: String?
            let displayName: String?
            let shortDisplayName: String?
            let color: String?
            let isActive: Bool?
            let logos: [Logo]?
            struct Logo: Decodable { let href: String?; let rel: [String]? }
        }
        let sports: [SportNode]?
    }

    private struct StandingsResponse: Decodable {
        struct Child: Decodable { let name: String?; let standings: Standings? }
        struct Standings: Decodable { let entries: [StandingEntry]? }
        struct StandingEntry: Decodable { let athlete: Athlete? }
        struct Athlete: Decodable {
            let id: String?
            let displayName: String?
            let abbreviation: String?
            let shortName: String?
        }
        let children: [Child]?
    }
}
