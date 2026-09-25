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
        /// "Grass" / "Turf", with "Indoor" appended when it's a dome — the only
        /// venue detail ESPN reliably fills in, and only for the US leagues.
        let venueSurface: String?
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
            venueSurface: surface(of: t.franchise?.venue),
            leagueName: res.team?.groups?.parent?.name
        )
    }

    private static func surface(of venue: TeamResponse.Venue?) -> String? {
        guard let venue, venue.grass != nil || venue.indoor != nil else { return nil }
        var parts: [String] = []
        if let grass = venue.grass { parts.append(grass ? "Grass" : "Turf") }
        if venue.indoor == true { parts.append("Indoor") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The team's full season schedule. Falls back to [] for leagues ESPN
    /// doesn't expose one for — the page then shows only what the scoreboard
    /// pool already knows.
    ///
    /// Between seasons ESPN's default schedule is genuinely empty: ask a
    /// Premier League club in July and you get 0 events, which left the form
    /// strip, the past-matches list and the last starting XI all blank for
    /// months. So a schedule with no finished game in it pulls the previous
    /// season in alongside, and the two are merged.
    static func fetchSchedule(sport: SportType?, leagueLabel: String?, teamID: String) async -> [ESPNEvent] {
        guard let path = apiPath(sport: sport, leagueLabel: leagueLabel) else { return [] }
        let current = await schedulePage(path: path, teamID: teamID, season: nil)
        var events = current.events

        if !events.contains(where: { $0.status.type.state == "post" }), let year = current.seasonYear {
            let previous = await schedulePage(path: path, teamID: teamID, season: year - 1)
            var seen = Set(events.map(\.id))
            for event in previous.events where seen.insert(event.id).inserted { events.append(event) }
        }
        return events.sorted { $0.gameDate < $1.gameDate }
    }

    private static func schedulePage(
        path: String,
        teamID: String,
        season: Int?
    ) async -> (events: [ESPNEvent], seasonYear: Int?) {
        var string = "https://site.api.espn.com/apis/site/v2/sports/\(path)/teams/\(teamID)/schedule"
        if let season { string += "?season=\(season)" }
        guard let url = URL(string: string),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONDecoder().decode(ScheduleResponse.self, from: data)
        else { return ([], nil) }
        return (res.events ?? [], res.season?.year)
    }

    // MARK: - Squad

    struct Player: Identifiable, Sendable {
        let id: String
        let name: String
        let jersey: String?
        /// Short position label ("GK", "WR") for the chip on the photo.
        let position: String?
        /// Section this player belongs under — "Goalkeepers", "Offense",
        /// "Pitchers" — already pluralised for a heading.
        let group: String
        let headshot: String?
        /// Where they're from: the national side for football, the birth
        /// country for the US leagues.
        let country: String?
        /// Country flag image, football only — ESPN attaches none elsewhere.
        let flag: String?
        let age: Int?
    }

    /// The current squad. ESPN returns two different shapes for this endpoint —
    /// a flat list for football and the NBA, position groups for the NFL and
    /// MLB — so both are decoded and flattened into one roster, each player
    /// carrying the section heading it should appear under.
    static func fetchRoster(sport: SportType?, leagueLabel: String?, teamID: String) async -> [Player] {
        guard let path = apiPath(sport: sport, leagueLabel: leagueLabel),
              let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/teams/\(teamID)/roster")
        else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONDecoder().decode(RosterResponse.self, from: data)
        else { return [] }

        /// (athlete, the group heading ESPN filed them under, if any)
        let raw: [(RosterResponse.Athlete, String?)]
        switch res.athletes {
        case .grouped(let groups):
            raw = groups.flatMap { group in (group.items ?? []).map { ($0, group.position) } }
        case .flat(let list):
            raw = list.map { ($0, nil) }
        case .none:
            raw = []
        }

        var seen = Set<String>()
        return raw.compactMap { athlete, groupName in
            let a = athlete
            guard let id = a.id, seen.insert(id).inserted else { return nil }
            let name = a.displayName ?? a.fullName ?? a.shortName
            guard let name, !name.isEmpty else { return nil }
            return Player(
                id: id,
                name: name,
                jersey: a.jersey,
                position: a.position?.abbreviation ?? a.position?.name,
                // Priority: the group ESPN put them in, then the position's
                // parent ("Wide Receiver" → "Offense"), then the position
                // itself, which is what football rosters carry.
                group: sectionTitle(groupName
                                    ?? a.position?.parent?.displayName
                                    ?? a.position?.parent?.name
                                    ?? a.position?.name),
                headshot: a.headshot?.href,
                country: a.citizenship ?? a.birthPlace?.country,
                flag: a.flag?.href,
                age: a.age ?? age(fromISO: a.dateOfBirth)
            )
        }
    }

    /// ESPN's group names arrive in every style there is — "specialTeam",
    /// "Pitchers", "Goalkeeper" — and they're going straight into a heading.
    private static func sectionTitle(_ raw: String?) -> String {
        guard var name = raw, !name.isEmpty else { return "Squad" }
        // camelCase → words.
        if name.rangeOfCharacter(from: .whitespaces) == nil {
            var spaced = ""
            for ch in name {
                if ch.isUppercase && !spaced.isEmpty { spaced.append(" ") }
                spaced.append(ch)
            }
            name = spaced
        }
        name = name.prefix(1).uppercased() + name.dropFirst()
        switch name.lowercased() {
        // Position names arrive singular, and a heading over eight players
        // reading "Guard" looks like a mistake. Only the ones ESPN actually
        // returns are listed — blanket pluralising would turn the NFL's
        // "Defense" into "Defenses".
        case "goalkeeper": return "Goalkeepers"
        case "defender": return "Defenders"
        case "midfielder": return "Midfielders"
        case "forward": return "Forwards"
        case "guard": return "Guards"
        case "center": return "Centers"
        case "pitcher": return "Pitchers"
        case "catcher": return "Catchers"
        case "infielder": return "Infielders"
        case "outfielder": return "Outfielders"
        case "goalie": return "Goalies"
        case "injured reserve or out": return "Injured Reserve"
        case "practice squad": return "Practice Squad"
        case "special team": return "Special Teams"
        default: return name
        }
    }

    private static func age(fromISO iso: String?) -> Int? {
        guard let iso, !iso.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: iso)
        }()
        guard let date else { return nil }
        return Calendar.current.dateComponents([.year], from: date, to: Date()).year
    }

    // MARK: - Club info

    /// The things ESPN simply has no field for. Football clubs come back from
    /// ESPN with an entirely empty venue object, and no league gets a founding
    /// year or a description from it at all.
    struct ClubInfo: Sendable {
        let stadium: String?
        let location: String?
        let founded: String?
        /// A few paragraphs about the club.
        let about: String?
    }

    /// Club identity from TheSportsDB, looked up by name.
    ///
    /// `names` are tried in order — ESPN's own name first, then shorter forms —
    /// because the two feeds don't always agree on it ("LA Clippers" against
    /// "Los Angeles Clippers"). Anything from the wrong sport is discarded, so
    /// a fallback query landing on a namesake ("Clippers" → Columbus Clippers,
    /// baseball) returns nothing rather than the wrong club.
    ///
    /// Capacity is deliberately NOT read even though the feed carries it: spot
    /// checks had Tottenham at 36,284 against a real 62,850 and Manchester City
    /// 9,000 over. A wrong number in a stadium card is worse than no number.
    static func fetchClubInfo(names: [String], sport: SportType?) async -> ClubInfo? {
        for name in names.filter({ !$0.isEmpty }) {
            if let info = await clubInfo(name: name, sport: sport) { return info }
        }
        return nil
    }

    private static func clubInfo(name: String, sport: SportType?) async -> ClubInfo? {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.thesportsdb.com/api/v1/json/3/searchteams.php?t=\(encoded)")
        else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SportsDBTeamResponse.self, from: data),
              let teams = decoded.teams, !teams.isEmpty
        else { return nil }

        // A bare club name can also hit the women's side, so prefer an exact
        // name match within the sport.
        let wanted = sportsDBSport(for: sport)
        let candidates = teams.filter { wanted == nil || $0.strSport == wanted }
        let target = PlayerPhotoService.normalize(name)
        let best = candidates.first { PlayerPhotoService.normalize($0.strTeam ?? "") == target }
            ?? candidates.first
        guard let best else { return nil }

        return ClubInfo(
            stadium: best.strStadium?.nilIfEmpty,
            location: best.strLocation?.nilIfEmpty,
            founded: best.intFormedYear?.nilIfEmpty,
            about: best.strDescriptionEN?.nilIfEmpty
        )
    }

    private static func sportsDBSport(for sport: SportType?) -> String? {
        switch sport {
        case .nba, .wnba, .cbb:     return "Basketball"
        case .mlb:                  return "Baseball"
        case .nhl, .collegeHockey:  return "Ice Hockey"
        case .nfl, .cfb:            return "American Football"
        case .none:                 return nil
        default:                    return "Soccer"
        }
    }

    private struct SportsDBTeamResponse: Decodable {
        struct Team: Decodable {
            let strTeam: String?
            let strSport: String?
            let strStadium: String?
            let strLocation: String?
            let intFormedYear: String?
            let strDescriptionEN: String?
        }
        let teams: [Team]?
    }

    // MARK: - Season statistics

    struct Stat: Identifiable, Sendable {
        let id: String
        let label: String
        let value: String
    }

    struct StatCategory: Identifiable, Sendable {
        let id: String
        let name: String
        let stats: [Stat]
    }

    struct SeasonStats: Sendable {
        /// "2025-26 Premier League" — ESPN's own name for the season.
        let seasonLabel: String
        let categories: [StatCategory]
    }

    /// The team's season totals. The site API carries none of this, so it comes
    /// from the core API, which needs a season year AND a season type in the
    /// path — and those differ by sport (football's regular season is type 1,
    /// the NBA's is 2). Both are read off the league's own current-season
    /// document rather than guessed.
    ///
    /// A season that hasn't kicked off yet has no stats at all, so the previous
    /// one is tried before giving up — otherwise the tab would sit empty all
    /// summer.
    static func fetchSeasonStats(sport: SportType?, leagueLabel: String?, teamID: String) async -> SeasonStats? {
        guard let path = apiPath(sport: sport, leagueLabel: leagueLabel) else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let root = "https://sports.core.api.espn.com/v2/sports/\(parts[0])/leagues/\(parts[1])"

        guard let current = await currentSeason(root: root) else { return nil }
        if let stats = await statistics(root: root, season: current, teamID: teamID) { return stats }

        guard let previous = await season(root: root, year: current.year - 1) else { return nil }
        return await statistics(root: root, season: previous, teamID: teamID)
    }

    private struct Season: Sendable {
        let year: Int
        let typeID: String
        let label: String
    }

    private struct SeasonListResponse: Decodable {
        struct Item: Decodable { let ref: String?; enum CodingKeys: String, CodingKey { case ref = "$ref" } }
        let items: [Item]?
    }

    private struct SeasonResponse: Decodable {
        struct SeasonType: Decodable { let id: String?; let name: String? }
        let year: Int?
        let displayName: String?
        let type: SeasonType?
    }

    private static func currentSeason(root: String) async -> Season? {
        guard let url = URL(string: "\(root)/seasons?limit=1"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let list = try? JSONDecoder().decode(SeasonListResponse.self, from: data),
              let ref = list.items?.first?.ref,
              // The refs come back on http with an internal host on some
              // leagues; only the path matters.
              let year = Int(ref.split(separator: "/").last?.prefix(4) ?? "")
        else { return nil }
        return await season(root: root, year: year)
    }

    private static func season(root: String, year: Int) async -> Season? {
        guard let url = URL(string: "\(root)/seasons/\(year)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(SeasonResponse.self, from: data)
        else { return nil }
        return Season(
            year: decoded.year ?? year,
            typeID: decoded.type?.id ?? "1",
            label: decoded.type?.name ?? decoded.displayName ?? String(year)
        )
    }

    private struct StatisticsResponse: Decodable {
        struct Splits: Decodable { let categories: [Category]? }
        struct Category: Decodable {
            let name: String?
            let displayName: String?
            let stats: [Entry]?
        }
        struct Entry: Decodable {
            let name: String?
            let displayName: String?
            let displayValue: String?
        }
        let splits: Splits?
    }

    private static func statistics(root: String, season: Season, teamID: String) async -> SeasonStats? {
        guard let url = URL(string:
                "\(root)/seasons/\(season.year)/types/\(season.typeID)/teams/\(teamID)/statistics"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(StatisticsResponse.self, from: data)
        else { return nil }

        let categories: [StatCategory] = (decoded.splits?.categories ?? []).compactMap { category in
            let stats: [Stat] = (category.stats ?? []).compactMap { entry in
                guard let key = entry.name, let value = entry.displayValue, !value.isEmpty else { return nil }
                // ESPN ships these three on every football team and they are
                // 0.0 on every one of them.
                guard !key.hasPrefix("avgRatingFrom") else { return nil }
                return Stat(id: key, label: entry.displayName ?? key, value: value)
            }
            guard !stats.isEmpty else { return nil }
            let name = category.displayName ?? category.name ?? "Stats"
            return StatCategory(id: category.name ?? name, name: name, stats: stats)
        }
        guard !categories.isEmpty else { return nil }
        return SeasonStats(seasonLabel: season.label, categories: categories)
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
            let citizenship: String?
            let flag: Headshot?
            let birthPlace: BirthPlace?
            let age: Int?
            let dateOfBirth: String?
        }
        struct Position: Decodable {
            let name: String?
            let abbreviation: String?
            let parent: Parent?
            struct Parent: Decodable { let name: String?; let displayName: String? }
        }
        struct BirthPlace: Decodable { let country: String? }
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
        struct Venue: Decodable {
            let fullName: String?
            let address: Address?
            let grass: Bool?
            let indoor: Bool?
        }
        struct Address: Decodable { let city: String?; let state: String? }
        struct Groups: Decodable { let parent: Parent? }
        struct Parent: Decodable { let name: String? }
    }

    /// The team schedule endpoint returns the same `events` shape as the
    /// scoreboard, so ESPNEvent decodes it directly.
    private struct ScheduleResponse: Decodable {
        struct Season: Decodable { let year: Int? }
        let events: [ESPNEvent]?
        let season: Season?
    }
}

nonisolated private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
