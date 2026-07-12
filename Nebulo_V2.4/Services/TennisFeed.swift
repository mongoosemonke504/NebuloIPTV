import Foundation

/// Shared tennis pipeline: fetches the ATP/WTA scoreboards, converts each
/// tournament-draw match into a standalone `ESPNEvent`, and builds the
/// sectioned output the hub renders ("Wimbledon — Men's Singles", singles
/// draws before doubles). Also used by the match detail page to re-poll a
/// single match, and by stream search to build player-name terms.
nonisolated enum TennisFeed {
    static let tours = ["atp", "wta"]

    /// Separates the tournament name from the draw name in a section label.
    static let labelSeparator = " — "

    // MARK: Fetch

    static func fetchScoreboard(tour: String, session: URLSession) async -> TennisScoreboard? {
        let urlStr = "https://site.api.espn.com/apis/site/v2/sports/tennis/\(tour)/scoreboard"
        guard let url = URL(string: urlStr) else { return nil }
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        return try? JSONDecoder().decode(TennisScoreboard.self, from: data)
    }

    /// Both tours' scoreboards flattened into hub sections + the flat game
    /// list. Majors appear in both feeds with the same match ids, so matches
    /// are deduped across feeds. Only matches near the current day survive:
    /// everything live, scheduled inside ±(26h…48h), results inside ~1 day —
    /// a Grand Slam draw carries hundreds of matches we never show.
    static func fetchSections(session: URLSession) async -> ([SoccerGameSection], [ESPNEvent]) {
        var boards = [TennisScoreboard?](repeating: nil, count: tours.count)
        await withTaskGroup(of: (Int, TennisScoreboard?).self) { group in
            for (index, tour) in tours.enumerated() {
                group.addTask { (index, await fetchScoreboard(tour: tour, session: session)) }
            }
            for await (index, board) in group { boards[index] = board }
        }

        let now = Date()
        var seenMatchIDs = Set<String>()
        var sections: [SoccerGameSection] = []
        var allGames: [ESPNEvent] = []

        for (index, board) in boards.enumerated() {
            let tour = tours[index]
            for tournament in board?.events ?? [] {
                let tournamentName = shortTournamentName(tournament.name ?? "Tennis")
                // Singles draws first, then doubles, keeping feed order
                // within each kind.
                let groupings = tournament.groupings ?? []
                let ordered = groupings.filter { isSingles($0) } + groupings.filter { !isSingles($0) }
                for grouping in ordered {
                    let drawName = grouping.grouping?.displayName ?? "Draw"
                    var games: [ESPNEvent] = []
                    for match in grouping.competitions ?? [] {
                        guard let id = match.id else { continue }
                        guard seenMatchIDs.insert(id).inserted else { continue }
                        guard let event = convert(
                            match: match,
                            leagueLabel: tournamentName + labelSeparator + drawName,
                            tennisPath: tournament.id.map { "\(tour)/\($0)" }
                        ) else { continue }
                        let interval = event.gameDate == .distantFuture ? 0 : event.gameDate.timeIntervalSince(now)
                        switch event.status.type.state {
                        case "in": games.append(event)
                        // Lower bound too: draws keep abandoned "scheduled"
                        // placeholder matches from days ago.
                        case "pre": if interval < 48 * 3600 && interval > -26 * 3600 { games.append(event) }
                        default: if interval > -26 * 3600 { games.append(event) }
                        }
                    }
                    guard !games.isEmpty else { continue }
                    games.sort { a, b in
                        let aState = a.status.type.state
                        let bState = b.status.type.state
                        if aState == "in" && bState != "in" { return true }
                        if aState != "in" && bState == "in" { return false }
                        if aState == "pre" && bState == "post" { return true }
                        if aState == "post" && bState == "pre" { return false }
                        return a.gameDate < b.gameDate
                    }
                    sections.append(SoccerGameSection(league: tournamentName + labelSeparator + drawName, games: games))
                    allGames.append(contentsOf: games)
                }
            }
        }
        return (sections, allGames)
    }

    /// Re-fetches one match by scanning its tour's scoreboard — used by the
    /// match detail page to poll a live match. `tennisPath` is the
    /// "<tour>/<tournament id>" stored on the event at conversion time.
    static func fetchMatch(id: String, tennisPath: String, session: URLSession) async -> ESPNEvent? {
        let parts = tennisPath.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        guard let board = await fetchScoreboard(tour: parts[0], session: session) else { return nil }
        for tournament in board.events ?? [] where tournament.id == parts[1] {
            let tournamentName = shortTournamentName(tournament.name ?? "Tennis")
            for grouping in tournament.groupings ?? [] {
                for match in grouping.competitions ?? [] where match.id == id {
                    let drawName = grouping.grouping?.displayName ?? "Draw"
                    return convert(
                        match: match,
                        leagueLabel: tournamentName + labelSeparator + drawName,
                        tennisPath: tennisPath
                    )
                }
            }
        }
        return nil
    }

    private static func isSingles(_ grouping: TennisGroupingRaw) -> Bool {
        grouping.grouping?.slug?.contains("singles") == true
    }

    /// Sponsor-bloated tournament names ("… Open for the Van Alen Cup
    /// Presented by the Margaret Fund") trimmed to the part people know.
    static func shortTournamentName(_ name: String) -> String {
        var out = name
        for marker in [" presented by", " Presented by", " for the "] {
            if let range = out.range(of: marker) {
                out = String(out[..<range.lowerBound])
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Conversion

    /// One tennis match → one scoreboard event. The competitor's `score`
    /// becomes the sets won (completed sets carry a winner flag), so generic
    /// surfaces (featured card, Live Now) show a sensible set count while
    /// the tennis row renders the full per-set linescores. ESPN briefly
    /// flips matches to a "suspended" status during set breaks (and real
    /// rain delays) — those stay live here so they never drop off the Live
    /// Now shelf mid-match.
    static func convert(match: TennisMatchRaw, leagueLabel: String, tennisPath: String?) -> ESPNEvent? {
        guard let id = match.id, let rawStatus = match.status, let date = match.date else { return nil }
        let rawCompetitors = match.competitors ?? []
        guard !rawCompetitors.isEmpty else { return nil }

        let competitors = rawCompetitors.map { c -> ESPNCompetitor in
            let setsWon = (c.linescores ?? []).filter { $0.winner == true }.count
            return ESPNCompetitor(
                id: c.id, homeAway: c.homeAway, score: String(setsWon),
                team: c.team, athlete: c.athlete, order: c.order,
                winner: c.winner, linescores: c.linescores,
                possession: c.possession, roster: c.roster, curatedRank: c.curatedRank
            )
        }

        var status = rawStatus
        let typeName = rawStatus.type.name ?? ""
        let looksSuspended = typeName.contains("SUSPEND") || typeName.contains("DELAY")
            || rawStatus.type.detail.localizedCaseInsensitiveContains("suspend")
            || rawStatus.type.detail.localizedCaseInsensitiveContains("delay")
        if looksSuspended && rawStatus.type.completed != true {
            // Between sets the just-finished set carries winner flags; a
            // true mid-set stoppage doesn't.
            let betweenSets = competitors.contains { $0.linescores?.last?.winner != nil }
            status = ESPNStatus(type: ESPNStatusType(
                detail: betweenSets ? "Set Break" : rawStatus.type.detail,
                state: "in",
                name: rawStatus.type.name,
                completed: false
            ))
        }

        let away = competitors.first { $0.homeAway == "away" } ?? competitors.first
        let home = competitors.first { $0.homeAway == "home" } ?? competitors.last
        return ESPNEvent(
            id: id,
            shortName: "\(sideName(away)) vs \(sideName(home))",
            status: status,
            competitions: [ESPNCompetition(competitors: competitors, broadcasts: match.broadcasts, leaders: nil)],
            date: date,
            leagueLabel: leagueLabel,
            tennisRound: match.round?.displayName,
            tennisPath: tennisPath
        )
    }

    /// Display name for one side — the athlete for singles, the combined
    /// pair name for doubles.
    static func sideName(_ competitor: ESPNCompetitor?) -> String {
        competitor?.athlete?.shortName
            ?? competitor?.athlete?.displayName
            ?? competitor?.roster?.shortDisplayName
            ?? competitor?.roster?.displayName
            ?? "TBD"
    }

    // MARK: Stream search terms

    /// Last name(s) for one side — "Muchova", or "Nys Roger-Vasselin" for
    /// doubles. Initial-dot short names ("K. Muchova") tokenize into a bare
    /// "k" that matches half the playlist, so search runs on last names only.
    static func searchName(_ competitor: ESPNCompetitor?) -> String {
        guard let competitor else { return "" }
        if let pair = competitor.roster?.athletes, !pair.isEmpty {
            return pair.compactMap { lastName($0.displayName ?? $0.shortName) }.joined(separator: " ")
        }
        return lastName(competitor.athlete?.displayName ?? competitor.athlete?.shortName) ?? ""
    }

    static func lastName(_ name: String?) -> String? {
        guard let name else { return nil }
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        guard let last = parts.last else { return nil }
        return String(last)
    }

    /// Bonus keywords for stream search: the tournament name plus the sport
    /// itself — EPG rows for tennis usually carry "Tennis: Wimbledon …"
    /// style titles even when no player name is listed.
    static func searchKeywords(for game: ESPNEvent) -> [String] {
        var words = ["tennis"]
        if let label = game.leagueLabel {
            let tournament = label.components(separatedBy: labelSeparator).first ?? label
            words += SmartSearchLogic.tokenize(tournament).filter { $0.count >= 4 && $0 != "open" }
        }
        return words
    }

    /// Home/away terms for the stream search engines. Player last names
    /// carry the match; the tournament/sport keywords ride on the home side
    /// only, so a tournament-name hit alone can surface a channel without
    /// counterfeiting the "both sides matched" bonus.
    static func searchTerms(for game: ESPNEvent) -> (home: String, away: String) {
        let home = searchName(game.homeCompetitor)
        let away = searchName(game.awayCompetitor)
        let keywords = searchKeywords(for: game).joined(separator: " ")
        return (home.isEmpty ? keywords : home + " " + keywords, away)
    }
}

extension ESPNEvent {
    /// Search terms for stream matching — team short names for team sports,
    /// player last names + tournament keywords for tennis (initial-dot
    /// names like "K. Muchova" tokenize into a bare "k" that matches half
    /// the playlist, and channel/EPG rows never carry the initial anyway).
    nonisolated var searchTerms: (home: String, away: String) {
        if tennisPath != nil { return TennisFeed.searchTerms(for: self) }
        let home = homeCompetitor?.team?.shortDisplayName ?? homeCompetitor?.athlete?.shortName ?? ""
        let away = awayCompetitor?.team?.shortDisplayName ?? awayCompetitor?.athlete?.shortName ?? ""
        return (home, away)
    }
}
