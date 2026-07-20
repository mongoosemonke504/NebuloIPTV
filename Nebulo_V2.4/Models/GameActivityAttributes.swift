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
}

extension GameActivityAttributes {
    static let appGroupID = "group.personal.Nebulo-V2-4"

    /// Resolves a stored logo filename to its file URL in the shared
    /// container. Nil when the app group isn't provisioned.
    static func logoURL(filename: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("Logos", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
