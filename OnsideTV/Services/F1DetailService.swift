import Foundation

/// Everything ESPN will tell us about a Formula 1 driver.
///
/// A driver isn't a team, so none of the team endpoints apply — `teams/{id}`
/// under `racing/f1` is a 404, which is why a favourited driver's page came up
/// empty. What ESPN does publish is the championship standings, and they carry
/// far more than a table: alongside each driver's position and points there's a
/// stat per round of the calendar holding the points they scored there, with the
/// Grand Prix's full name in the description.
///
/// So one request gives the standings, every driver's season round-by-round, and
/// the calendar itself.
nonisolated enum F1DetailService {

    struct DriverStanding: Identifiable, Sendable {
        /// ESPN athlete id — the same id a favourited driver is stored under.
        let id: String
        let name: String
        let flag: String?
        let rank: Int?
        /// Championship points, ESPN's own formatting.
        let points: String?
    }

    /// One round of the season, from a single driver's point of view.
    struct Round: Identifiable, Sendable {
        /// "HUN", "MON".
        let code: String
        /// "AWS Hungarian Grand Prix".
        let grandPrix: String
        /// Points scored. nil when the round hasn't been run yet.
        let points: String?
        /// True once the round has happened, whether or not it scored.
        let hasRun: Bool
        var id: String { code }
    }

    struct ConstructorStanding: Identifiable, Sendable {
        let id: String
        let name: String
        /// Team colour, hex without the leading "#".
        let color: String?
        let rank: Int?
        let points: String?
    }

    struct Season: Sendable {
        let standings: [DriverStanding]
        let constructors: [ConstructorStanding]
        /// athlete id → that driver's season, in calendar order.
        let rounds: [String: [Round]]
    }

    static func fetchSeason() async -> Season? {
        guard let url = URL(string: "https://site.api.espn.com/apis/v2/sports/racing/f1/standings"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONDecoder().decode(StandingsResponse.self, from: data)
        else { return nil }

        guard let drivers = res.children?
            .first(where: { ($0.name ?? "").localizedCaseInsensitiveContains("driver") })?
            .standings?.entries, !drivers.isEmpty
        else { return nil }

        var standings: [DriverStanding] = []
        var rounds: [String: [Round]] = [:]

        for entry in drivers {
            guard let athlete = entry.athlete, let id = athlete.id else { continue }
            var rank: Int?
            var points: String?
            var season: [Round] = []

            for stat in entry.stats ?? [] {
                switch stat.name {
                case "rank":
                    rank = stat.value.map { Int($0) }
                case "championshipPts":
                    points = stat.displayValue
                case "overall", .none:
                    continue
                default:
                    // Everything else is a round of the calendar. A blank
                    // display value means the race hasn't happened; "-" means it
                    // has and the driver took nothing from it.
                    let raw = (stat.displayValue ?? "").trimmingCharacters(in: .whitespaces)
                    let hasRun = !raw.isEmpty
                    season.append(Round(
                        code: stat.abbreviation ?? stat.name ?? "",
                        grandPrix: stat.description ?? stat.abbreviation ?? stat.name ?? "Round",
                        points: (hasRun && raw != "-") ? raw : nil,
                        hasRun: hasRun
                    ))
                }
            }

            standings.append(DriverStanding(
                id: id,
                name: athlete.displayName ?? athlete.shortName ?? "Driver",
                flag: athlete.flag?.href,
                rank: rank,
                points: points
            ))
            rounds[id] = season
        }

        var constructors: [ConstructorStanding] = []
        if let teams = res.children?
            .first(where: { ($0.name ?? "").localizedCaseInsensitiveContains("constructor") })?
            .standings?.entries {
            for entry in teams {
                guard let team = entry.team, let id = team.id else { continue }
                var rank: Int?
                var points: String?
                for stat in entry.stats ?? [] {
                    switch stat.name {
                    case "rank": rank = stat.value.map { Int($0) }
                    // Constructors keep score under "points"; drivers under
                    // "championshipPts". Reading the driver key here left every
                    // team on a dash.
                    case "points": points = stat.displayValue
                    default: continue
                    }
                }
                constructors.append(ConstructorStanding(
                    id: id,
                    name: team.displayName ?? "Constructor",
                    color: team.color,
                    rank: rank,
                    points: points
                ))
            }
            constructors.sort { ($0.rank ?? .max) < ($1.rank ?? .max) }
        }

        standings.sort { ($0.rank ?? .max) < ($1.rank ?? .max) }
        return Season(standings: standings, constructors: constructors, rounds: rounds)
    }

    // MARK: - Circuit

    /// The track itself. Only the core API has this, and it's the richest thing
    /// ESPN publishes about a race weekend: layout diagram, lap count, lap
    /// record, distance, turns, direction.
    struct CircuitDetail: Sendable {
        let name: String
        let location: String?
        /// "4.381 km"
        let length: String?
        /// Full race distance, "306.63 km"
        let distance: String?
        let laps: Int?
        let turns: Int?
        let direction: String?
        let established: Int?
        /// "1:16.627"
        let lapRecordTime: String?
        let lapRecordYear: Int?
        /// Track layout image.
        let diagram: String?
    }

    static func fetchCircuit(id: String) async -> CircuitDetail? {
        guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/racing/leagues/f1/circuits/\(id)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONDecoder().decode(CircuitResponse.self, from: data)
        else { return nil }
        let place = [res.address?.city, res.address?.country].compactMap { $0 }.joined(separator: ", ")
        // Prefer the raster diagram: SwiftUI can't draw the SVG variant.
        let diagram = res.diagrams?.first { ($0.href ?? "").hasSuffix(".jpg") || ($0.href ?? "").hasSuffix(".png") }
            ?? res.diagrams?.first
        return CircuitDetail(
            name: res.fullName ?? "Circuit",
            location: place.isEmpty ? nil : place,
            length: res.length,
            distance: res.distance,
            laps: res.laps,
            turns: res.turns,
            direction: res.direction,
            established: res.established,
            lapRecordTime: res.fastestLapTime,
            lapRecordYear: res.fastestLapYear,
            diagram: diagram?.href
        )
    }

    private struct CircuitResponse: Decodable {
        struct Address: Decodable { let city: String?; let country: String? }
        struct Diagram: Decodable { let href: String? }
        let fullName: String?
        let address: Address?
        let length: String?
        let distance: String?
        let laps: Int?
        let turns: Int?
        let direction: String?
        let established: Int?
        let fastestLapTime: String?
        let fastestLapYear: Int?
        let diagrams: [Diagram]?
    }

    // MARK: - Session classification

    /// One line of a session's classification.
    struct SessionEntry: Identifiable, Sendable {
        let position: Int
        let driverID: String
        let driverName: String
        let flag: String?
        /// Car number.
        let number: String?
        /// "McLaren", "Ferrari".
        let constructor: String?
        /// Team colour, hex without the leading "#".
        let teamColor: String?
        /// Session time — a lap time in qualifying, race time for the winner.
        let time: String?
        /// Gap to the session leader, "+0.012". Empty for the leader.
        let gap: String?
        let laps: String?
        /// Championship points taken from this session.
        let points: String?
        var id: String { driverID }
    }

    /// Enriches a session's finishing order with the things only the core API
    /// carries: car number, constructor and team colour for everyone, plus lap
    /// times, lap counts and each driver's gap to the session leader.
    ///
    /// The scoreboard already gives the order and the driver names, so this is
    /// additive — the card draws a full classification before any of it lands.
    ///
    /// Times cost one request per driver, and the whole grid is 20-22, so the
    /// requests run six at a time and the result is cached per session. That's
    /// worth it: a timing screen with times for the top ten and blanks below
    /// isn't a timing screen.
    static func fetchSessionDetail(
        eventID: String,
        sessionAbbreviation: String
    ) async -> [String: SessionEntry] {
        guard let competitionID = await competitionID(eventID: eventID, abbreviation: sessionAbbreviation),
              let url = URL(string: "https://sports.core.api.espn.com/v2/sports/racing/leagues/f1/events/\(eventID)/competitions/\(competitionID)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONDecoder().decode(CompetitionResponse.self, from: data)
        else { return [:] }

        let competitors = (res.competitors ?? []).sorted { ($0.order ?? 99) < ($1.order ?? 99) }
        var out: [String: SessionEntry] = [:]
        for (index, competitor) in competitors.enumerated() {
            guard let id = competitor.id else { continue }
            out[id] = SessionEntry(
                position: competitor.order ?? (index + 1),
                driverID: id,
                driverName: "",
                flag: nil,
                number: competitor.vehicle?.number,
                constructor: competitor.vehicle?.manufacturer,
                teamColor: competitor.vehicle?.teamColor,
                time: nil,
                gap: nil,
                laps: nil,
                points: nil
            )
        }

        // Times for the whole field, six requests at a time.
        let ids = competitors.compactMap(\.id)
        var stats: [String: DriverSessionStats] = [:]
        var index = 0
        while index < ids.count {
            let slice = Array(ids[index..<min(index + 6, ids.count)])
            let found = await withTaskGroup(of: (String, DriverSessionStats?).self) { group in
                for driverID in slice {
                    group.addTask {
                        (driverID, await driverStats(eventID: eventID,
                                                     competitionID: competitionID,
                                                     driverID: driverID))
                    }
                }
                var partial: [String: DriverSessionStats] = [:]
                for await (id, value) in group { if let value { partial[id] = value } }
                return partial
            }
            stats.merge(found) { _, new in new }
            index += 6
        }

        // The leader's time is the reference every gap is measured from — how a
        // timing screen reads, and far more useful than 20 absolute times.
        let leaderSeconds = competitors.first.flatMap { $0.id }
            .flatMap { stats[$0]?.totalTime }
            .flatMap(seconds(fromTime:))

        for (id, s) in stats {
            guard let base = out[id] else { continue }
            var gap: String?
            if let leaderSeconds, base.position > 1,
               let mine = s.totalTime.flatMap(seconds(fromTime:)), mine > leaderSeconds {
                gap = "+" + formatGap(mine - leaderSeconds)
            }
            out[id] = SessionEntry(
                position: base.position, driverID: base.driverID, driverName: base.driverName,
                flag: base.flag, number: base.number, constructor: base.constructor,
                teamColor: base.teamColor,
                time: s.totalTime, gap: gap, laps: s.laps, points: s.points
            )
        }
        return out
    }

    /// "1:17.207" / "1:34:12.345" / "58.812" → seconds.
    private static func seconds(fromTime text: String) -> Double? {
        let parts = text.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total: Double = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Under a minute reads as "0.483"; beyond that as "1:02.400", the way a
    /// timing screen switches over.
    private static func formatGap(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.3f", seconds) }
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%d:%06.3f", minutes, remainder)
    }

    private struct DriverSessionStats: Sendable {
        let totalTime: String?
        let laps: String?
        let points: String?
    }

    private static func driverStats(eventID: String, competitionID: String, driverID: String) async -> DriverSessionStats? {
        guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/racing/leagues/f1/events/\(eventID)/competitions/\(competitionID)/competitors/\(driverID)/statistics"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONDecoder().decode(StatisticsResponse.self, from: data)
        else { return nil }
        var time: String?
        var laps: String?
        var points: String?
        for category in res.splits?.categories ?? [] {
            for stat in category.stats ?? [] {
                switch stat.name {
                case "totalTime": time = stat.displayValue
                case "lapsCompleted": laps = stat.displayValue
                case "championshipPts": points = stat.displayValue
                default: continue
                }
            }
        }
        guard time != nil || laps != nil || points != nil else { return nil }
        return DriverSessionStats(totalTime: time, laps: laps, points: points)
    }

    /// Maps a session abbreviation ("Qual") to its core-API competition id.
    private static func competitionID(eventID: String, abbreviation: String) async -> String? {
        guard let url = URL(string: "https://sports.core.api.espn.com/v2/sports/racing/leagues/f1/events/\(eventID)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONDecoder().decode(EventResponse.self, from: data)
        else { return nil }
        // The refs come in calendar order, which is the same order the
        // scoreboard lists the sessions, so an id lookup by index is enough
        // when the abbreviation isn't spelled out here.
        for item in res.competitions ?? [] {
            if let abbr = item.type?.abbreviation,
               abbr.caseInsensitiveCompare(abbreviation) == .orderedSame {
                return item.id
            }
        }
        return nil
    }

    private struct EventResponse: Decodable {
        struct Item: Decodable {
            let id: String?
            let type: TypeNode?
            struct TypeNode: Decodable { let abbreviation: String? }
        }
        let competitions: [Item]?
    }

    private struct CompetitionResponse: Decodable {
        struct Competitor: Decodable {
            let id: String?
            let order: Int?
            let vehicle: Vehicle?
            struct Vehicle: Decodable {
                let number: String?
                let manufacturer: String?
                let teamColor: String?
            }
        }
        let competitors: [Competitor]?
    }

    private struct StatisticsResponse: Decodable {
        struct Splits: Decodable { let categories: [Category]? }
        struct Category: Decodable { let stats: [Stat]? }
        struct Stat: Decodable { let name: String?; let displayValue: String? }
        let splits: Splits?
    }

    // MARK: - Per-driver feeds

    /// A driver and the channels in the user's own playlist that carry their
    /// onboard camera.
    struct DriverFeed: Identifiable, Sendable {
        let driver: String
        let channels: [StreamChannel]
        var id: String { driver }
    }

    /// Scans the playlist for per-driver onboard feeds.
    ///
    /// Plenty of IPTV providers carry them and plenty don't, so this is a scan
    /// rather than an assumption: the tab only exists when something matched.
    ///
    /// Matching is deliberately strict. A surname alone would put a channel
    /// called "Hamilton" (the city, the musical, a local station) on Lewis
    /// Hamilton's row, so a channel qualifies only when its name contains the
    /// surname as a WHOLE WORD *and* something that marks it as motorsport —
    /// either in the channel name or in the name of the category it lives in,
    /// which covers providers who file bare surnames under "F1 ONBOARD".
    nonisolated static func driverFeeds(
        drivers: [String],
        channels: [StreamChannel],
        categoryNames: [Int: String],
        hiddenChannelIDs: Set<Int>,
        hiddenCategoryIDs: Set<Int>
    ) -> [DriverFeed] {
        let markers = ["f1", "formula 1", "formula1", "onboard", "on board",
                       "driver cam", "drivercam", "grand prix", "motorsport"]

        /// Surnames long enough to be unambiguous, mapped back to the driver.
        var surnames: [(surname: String, driver: String)] = []
        for driver in drivers {
            let cleaned = driver.folding(options: .diacriticInsensitive, locale: nil)
            guard let last = cleaned.split(separator: " ").last, last.count >= 4 else { continue }
            surnames.append((String(last).lowercased(), driver))
        }
        guard !surnames.isEmpty else { return [] }

        var byDriver: [String: [StreamChannel]] = [:]
        for channel in channels {
            guard !hiddenChannelIDs.contains(channel.id),
                  !hiddenCategoryIDs.contains(channel.categoryID) else { continue }
            let name = channel.name.folding(options: .diacriticInsensitive, locale: nil).lowercased()
            let category = (categoryNames[channel.categoryID] ?? "")
                .folding(options: .diacriticInsensitive, locale: nil).lowercased()
            let context = name + " " + category
            guard markers.contains(where: { context.contains($0) }) else { continue }
            for (surname, driver) in surnames where containsWord(surname, in: name) {
                byDriver[driver, default: []].append(channel)
            }
        }

        // Driver order follows the order passed in — the championship, or the
        // session's finishing order.
        return drivers.compactMap { driver in
            guard let list = byDriver[driver], !list.isEmpty else { return nil }
            return DriverFeed(driver: driver, channels: list)
        }
    }

    /// Whole-word containment: "norris" matches "F1 ONBOARD NORRIS" and
    /// "F1: Norris (McLaren)" but not "Norrisville TV".
    nonisolated private static func containsWord(_ word: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: word, range: searchRange) {
            let beforeOK = found.lowerBound == text.startIndex
                || !text[text.index(before: found.lowerBound)].isLetter
            let afterOK = found.upperBound == text.endIndex
                || !text[found.upperBound].isLetter
            if beforeOK && afterOK { return true }
            guard found.upperBound < text.endIndex else { return false }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    // MARK: - Wire models (only the fields we read)

    private struct StandingsResponse: Decodable {
        let children: [Child]?
        struct Child: Decodable {
            let name: String?
            let standings: Standings?
        }
        struct Standings: Decodable { let entries: [Entry]? }
        struct Entry: Decodable {
            let athlete: Athlete?
            /// Constructor standings key off `team` where drivers key off
            /// `athlete`; both children come back in the same request.
            let team: Team?
            let stats: [Stat]?
        }
        struct Team: Decodable {
            let id: String?
            let displayName: String?
            let color: String?
        }
        struct Athlete: Decodable {
            let id: String?
            let displayName: String?
            let shortName: String?
            let flag: Flag?
        }
        struct Flag: Decodable { let href: String? }
        struct Stat: Decodable {
            let name: String?
            let abbreviation: String?
            let description: String?
            let displayValue: String?
            let value: Double?
        }
    }
}
