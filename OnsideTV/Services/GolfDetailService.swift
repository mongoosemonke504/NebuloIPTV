import Foundation

/// Everything ESPN publishes about a golf tournament.
///
/// Like racing, golf has no `summary` endpoint — it 404s. What it does have is
/// the feed behind ESPN's own leaderboard page, and that one request carries the
/// whole thing: the full field with positions, round scores, holes played and
/// tee times, the host course down to the par and yardage of every hole, the
/// purse, the cut line, the defending champion, and the tournament's
/// statistical leaders.
///
/// The plain scoreboard has the field too, but none of the course, cut or purse
/// detail, and no `thru` or tee times — so the card reads from this instead.
nonisolated enum GolfDetailService {

    // MARK: - Model

    struct Round: Identifiable, Sendable {
        let number: Int
        /// Strokes for the round, "64".
        let strokes: String?
        /// That round against par, "-7".
        let toPar: String?
        var id: Int { number }
    }

    struct Player: Identifiable, Sendable {
        let id: String
        let name: String
        let flag: String?
        let headshot: String?
        let amateur: Bool
        /// "1", "T2" — ESPN's own wording, ties included.
        let position: String?
        /// Total against par, "-17".
        let total: String?
        /// Holes played in the current round.
        let thru: Int?
        /// "1:40 PM ET" for a player yet to start.
        let teeTime: String?
        /// pre / in / post, for this PLAYER — half the field can be out on the
        /// course while the other half hasn't teed off.
        let state: String
        /// Places gained (+) or lost (−) since the last round.
        let movement: Int?
        let earnings: Double?
        let rounds: [Round]
        /// Sort key from the feed; ties share a position but not a sort order.
        let sortOrder: Int
    }

    struct Hole: Identifiable, Sendable {
        let number: Int
        let par: Int?
        let yards: Int?
        var id: Int { number }
    }

    struct Course: Sendable {
        let name: String
        let totalYards: Int?
        let par: Int?
        /// Par for the front and back nines.
        let parOut: Int?
        let parIn: Int?
        let holes: [Hole]
    }

    struct StatLeader: Identifiable, Sendable {
        /// "Driving Distance"
        let title: String
        let player: String
        let value: String
        var id: String { title }
    }

    struct Tournament: Sendable {
        let name: String
        let statusDetail: String?
        let state: String
        /// "$8,800,000"
        let purse: String?
        let isMajor: Bool
        let numberOfRounds: Int?
        /// The round the cut falls after, and where it landed.
        let cutRound: Int?
        let cutScore: String?
        let cutCount: Int?
        /// "Medal", "Stableford".
        let scoringSystem: String?
        let defendingChampion: String?
        let course: Course?
        let leaders: [StatLeader]
        let field: [Player]
    }

    // MARK: - Fetch

    static func fetchTournament(eventID: String) async -> Tournament? {
        guard let url = URL(string: "https://site.web.api.espn.com/apis/site/v2/sports/golf/leaderboard?event=\(eventID)")
        else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONDecoder().decode(LeaderboardResponse.self, from: data),
              let event = res.events?.first
        else { return nil }

        let competition = event.competitions?.first

        let field: [Player] = (competition?.competitors ?? []).map { entry in
            let status = entry.status
            return Player(
                id: entry.id ?? entry.athlete?.id ?? UUID().uuidString,
                name: entry.athlete?.displayName ?? entry.athlete?.shortName ?? "Player",
                flag: entry.athlete?.flag?.href,
                headshot: entry.athlete?.headshot?.href,
                amateur: entry.amateur ?? entry.athlete?.amateur ?? false,
                position: status?.position?.displayName,
                total: entry.score?.displayValue,
                thru: status?.thru,
                // `detail` is the tee time in local broadcast wording once the
                // player is scheduled; it's the status text otherwise.
                teeTime: (status?.type?.state == "pre") ? status?.detail : nil,
                state: status?.type?.state ?? "pre",
                movement: entry.movement,
                earnings: entry.earnings,
                rounds: (entry.linescores ?? []).compactMap { line in
                    guard let period = line.period else { return nil }
                    // A round not yet played comes back as 0 strokes / "-".
                    let played = (line.value ?? 0) > 0
                    return Round(
                        number: period,
                        strokes: played ? line.value.map { String(Int($0)) } : nil,
                        toPar: played ? line.displayValue : nil
                    )
                },
                sortOrder: entry.sortOrder ?? 999
            )
        }
        .sorted { $0.sortOrder < $1.sortOrder }

        let hostCourse = (event.courses ?? []).first { $0.host == true } ?? event.courses?.first
        let course: Course? = hostCourse.map { c in
            Course(
                name: c.name ?? "Course",
                totalYards: c.totalYards,
                par: c.shotsToPar,
                parOut: c.parOut,
                parIn: c.parIn,
                holes: (c.holes ?? []).compactMap { hole in
                    guard let number = hole.number else { return nil }
                    return Hole(number: number, par: hole.shotsToPar, yards: hole.totalYards)
                }
                .sorted { $0.number < $1.number }
            )
        }

        let leaders: [StatLeader] = (competition?.leaders ?? []).compactMap { category in
            guard let leader = category.leaders?.first,
                  let value = leader.displayValue,
                  let player = leader.athlete?.displayName else { return nil }
            return StatLeader(
                title: category.displayName ?? category.shortDisplayName ?? category.name ?? "Leader",
                player: player,
                value: value
            )
        }

        let cutScore = event.tournament?.cutScore.map { score -> String in
            if score == 0 { return "E" }
            return score > 0 ? "+\(score)" : "\(score)"
        }

        return Tournament(
            name: event.name ?? event.shortName ?? "Tournament",
            statusDetail: competition?.status?.type?.detail ?? event.status?.type?.description,
            state: event.status?.type?.state ?? "pre",
            purse: event.displayPurse,
            isMajor: event.tournament?.major ?? false,
            numberOfRounds: event.tournament?.numberOfRounds,
            cutRound: event.tournament?.cutRound,
            cutScore: cutScore,
            cutCount: event.tournament?.cutCount,
            scoringSystem: event.tournament?.scoringSystem?.name,
            defendingChampion: event.defendingChampion?.athlete?.displayName,
            course: course,
            leaders: leaders,
            field: field
        )
    }

    // MARK: - Wire models (only the fields we read)

    private struct LeaderboardResponse: Decodable {
        let events: [Event]?

        struct Event: Decodable {
            let name: String?
            let shortName: String?
            let displayPurse: String?
            let status: Status?
            let tournament: TournamentNode?
            let defendingChampion: DefendingChampion?
            let courses: [CourseNode]?
            let competitions: [Competition]?
        }

        struct TournamentNode: Decodable {
            let major: Bool?
            let numberOfRounds: Int?
            let cutRound: Int?
            let cutScore: Int?
            let cutCount: Int?
            let scoringSystem: ScoringSystem?
            struct ScoringSystem: Decodable { let name: String? }
        }

        struct DefendingChampion: Decodable {
            let athlete: Athlete?
        }

        struct CourseNode: Decodable {
            let name: String?
            let totalYards: Int?
            let shotsToPar: Int?
            let parIn: Int?
            let parOut: Int?
            let host: Bool?
            let holes: [HoleNode]?
            struct HoleNode: Decodable {
                let number: Int?
                let shotsToPar: Int?
                let totalYards: Int?
            }
        }

        struct Competition: Decodable {
            let status: Status?
            let competitors: [Competitor]?
            let leaders: [LeaderCategory]?
        }

        struct LeaderCategory: Decodable {
            let name: String?
            let displayName: String?
            let shortDisplayName: String?
            let leaders: [LeaderEntry]?
            struct LeaderEntry: Decodable {
                let displayValue: String?
                let athlete: Athlete?
            }
        }

        struct Competitor: Decodable {
            let id: String?
            let movement: Int?
            let earnings: Double?
            let sortOrder: Int?
            let amateur: Bool?
            let status: CompetitorStatus?
            let score: Score?
            let linescores: [LineScore]?
            let athlete: Athlete?
        }

        struct CompetitorStatus: Decodable {
            let thru: Int?
            let detail: String?
            let type: StatusType?
            let position: Position?
            struct Position: Decodable { let displayName: String? }
        }

        struct Score: Decodable { let displayValue: String? }

        struct LineScore: Decodable {
            let value: Double?
            let displayValue: String?
            let period: Int?
        }

        struct Athlete: Decodable {
            let id: String?
            let displayName: String?
            let shortName: String?
            let amateur: Bool?
            let flag: Href?
            let headshot: Href?
        }

        struct Href: Decodable { let href: String? }
        struct Status: Decodable { let type: StatusType? }
        struct StatusType: Decodable {
            let state: String?
            let detail: String?
            let description: String?
        }
    }
}
