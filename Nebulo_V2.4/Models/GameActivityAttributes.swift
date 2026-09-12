import Foundation
import ActivityKit

/// Attributes for the live-game Live Activity (Lock Screen + Dynamic
/// Island). This file must ALSO be a member of the widget extension target —
/// ActivityKit matches the running activity to the widget UI by this type.
struct GameActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var homeScore: String
        var awayScore: String
        /// Live status line, e.g. "Q3 4:12", "45' +2", "End of 7th".
        var statusDetail: String
        var isFinal: Bool
        /// Baseball live situation — bases, count, outs.
        var onFirst: Bool?
        var onSecond: Bool?
        var onThird: Bool?
        var balls: Int?
        var strikes: Int?
        var outs: Int?
        /// One-line situation for other sports (football down & distance).
        var situationText: String?
        /// FIELD EVENTS (a golf tournament, a race weekend): a leaderboard has
        /// no two sides, so it carries its top entrants instead of two scores.
        var leaderboard: [LeaderboardEntry]?
    }

    /// One row of a field event's board. Kept as three pieces rather than one
    /// formatted line so the widget can column-align position, name and score
    /// — a leaderboard whose numbers don't line up doesn't read as one.
    public struct LeaderboardEntry: Codable, Hashable {
        /// "1", or "T2" where the score is shared.
        var position: String
        var name: String
        /// Golf's score to par ("-12", "E"); a race's finishing time or gap.
        var score: String
    }

    var gameID: String
    var homeName: String
    var awayName: String
    var homeAbbrev: String
    var awayAbbrev: String
    /// Team colors as hex strings ("1D428A") — rendered as accent bars.
    var homeColorHex: String?
    var awayColorHex: String?
    var leagueName: String
    /// Logo filenames inside the app group's Logos/ folder. The app
    /// downloads and stores them before starting the activity; the widget
    /// process reads them from the shared container.
    var homeLogoFile: String?
    var awayLogoFile: String?
    /// Playing surface drawn faintly behind the card: "basketball",
    /// "soccer", "football", "hockey", "baseball", "tennis", "octagon".
    var sportKind: String?
    /// True for a tournament or a race weekend. Those have a field rather than
    /// two sides, so the card shows the event and its leaderboard instead of
    /// two crests either side of a score.
    var isFieldEvent: Bool = false
    /// The event's own name, for field events — "BMW Championship".
    var eventName: String?
    /// Which kind of field event: "golf" or "racing". Decides the glyph the
    /// Dynamic Island shows in place of a crest, and how its board reads.
    var fieldEventKind: String?
}

extension GameActivityAttributes {
    static let appGroupID = "group.Nebulo"

    /// Resolves a stored logo filename to its file URL in the shared
    /// container. Nil when the app group isn't provisioned.
    static func logoURL(filename: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("Logos", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
