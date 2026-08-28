import Foundation
import ActivityKit

/// Extension-side copy of the app's GameActivityAttributes. ActivityKit
/// matches the running activity to the widget UI by the attributes type
/// name and its encoded fields, so this must stay byte-for-byte identical
/// to Nebulo_V2.4/Models/GameActivityAttributes.swift.
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
        /// Each line is already formatted — "1  Scheffler   −12".
        var leaderboard: [String]?
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
