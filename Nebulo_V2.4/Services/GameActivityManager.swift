import Foundation
import ActivityKit
import SwiftUI
import UIKit
import Combine

/// Starts, updates, and ends the per-game Live Activity. Score refreshes
/// flow in via `sync(pool:)` from ScoreViewModel each time fresh scores
/// land; an activity ends itself shortly after its game goes final or
/// disappears from the feed.
@MainActor
final class GameActivityManager: ObservableObject {
    static let shared = GameActivityManager()

    /// Game ids with a running activity — published so bells and menu
    /// labels flip immediately.
    @Published private(set) var trackedGameIDs: Set<String> = []

    private var activities: [String: Activity<GameActivityAttributes>] = [:]

    private init() {
        // Re-adopt activities that survived an app relaunch.
        for activity in Activity<GameActivityAttributes>.activities {
            activities[activity.attributes.gameID] = activity
            trackedGameIDs.insert(activity.attributes.gameID)
            watchForSystemEnd(activity)
        }
    }

    /// The user can end an activity from the Lock Screen (swipe → Clear)
    /// without the app knowing — mirror that back into `trackedGameIDs` so
    /// every bell and menu label stays truthful.
    private func watchForSystemEnd(_ activity: Activity<GameActivityAttributes>) {
        Task { [weak self] in
            for await state in activity.activityStateUpdates {
                if state == .dismissed || state == .ended {
                    self?.activities.removeValue(forKey: activity.attributes.gameID)
                    self?.trackedGameIDs.remove(activity.attributes.gameID)
                    break
                }
            }
        }
    }

    var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func isTracking(_ gameID: String) -> Bool {
        trackedGameIDs.contains(gameID)
    }

    func toggle(game: ESPNEvent, leagueName: String, sport: SportType? = nil) {
        if isTracking(game.id) {
            ChannelViewModel.shared.triggerHaptic(.light)
            stop(game.id)
        } else {
            ChannelViewModel.shared.triggerHaptic(.medium)
            start(game: game, leagueName: leagueName, sport: sport)
        }
    }

    /// Playing-surface tag for the widget's faint background sketch.
    private nonisolated static func surfaceKind(for sport: SportType?) -> String? {
        guard let sport else { return nil }
        switch sport {
        case .nba, .wnba, .cbb: return "basketball"
        case .nfl, .cfb: return "football"
        case .nhl, .collegeHockey: return "hockey"
        case .mlb, .softball: return "baseball"
        case .tennis, .mVolleyball, .wVolleyball: return "tennis"
        case .mma: return "octagon"
        case .soccerLeagues, .domesticCups, .continental, .international,
             .mLacrosse, .wLacrosse: return "soccer"
        default: return nil
        }
    }

    func start(game: ESPNEvent, leagueName: String, sport: SportType? = nil) {
        guard !isTracking(game.id) else { return }
        // Optimistic: flip the UI immediately; the request itself waits for
        // the logo fetch below (attributes are immutable once requested).
        trackedGameIDs.insert(game.id)

        let home = game.homeCompetitor
        let away = game.awayCompetitor
        // Athlete sports (tennis, MMA) have no team object — the player's
        // flag stands in for the logo.
        let homeLogo = home?.team?.logo ?? home?.athlete?.flag?.href
        let awayLogo = away?.team?.logo ?? away?.athlete?.flag?.href

        Task {
            let homeLogoFile = await Self.stageLogo(urlString: homeLogo, key: "home-\(game.id)")
            let awayLogoFile = await Self.stageLogo(urlString: awayLogo, key: "away-\(game.id)")

            // User untracked while the logos were downloading — don't start.
            guard self.trackedGameIDs.contains(game.id), self.activities[game.id] == nil else { return }

            let attributes = GameActivityAttributes(
                gameID: game.id,
                homeName: home?.team?.shortDisplayName ?? home?.athlete?.shortName ?? "Home",
                awayName: away?.team?.shortDisplayName ?? away?.athlete?.shortName ?? "Away",
                homeAbbrev: Self.abbreviation(for: home, fallback: "HOME"),
                awayAbbrev: Self.abbreviation(for: away, fallback: "AWAY"),
                homeColorHex: home?.team?.color,
                awayColorHex: away?.team?.color,
                leagueName: leagueName,
                homeLogoFile: homeLogoFile,
                awayLogoFile: awayLogoFile,
                sportKind: Self.surfaceKind(for: sport),
                isFieldEvent: game.isFieldEvent,
                eventName: game.shortName
            )

            do {
                let activity = try Activity.request(
                    attributes: attributes,
                    content: .init(state: self.contentState(for: game), staleDate: nil)
                )
                self.activities[game.id] = activity
                self.watchForSystemEnd(activity)
            } catch {
                print("⚠️ [GameActivityManager] Could not start Live Activity: \(error)")
                self.trackedGameIDs.remove(game.id)
            }
        }
    }

    /// Short label for one side: team abbreviation for team sports, the
    /// athlete's surname for tennis/MMA.
    private nonisolated static func abbreviation(for comp: ESPNCompetitor?, fallback: String) -> String {
        if let abbrev = comp?.team?.abbreviation, !abbrev.isEmpty { return abbrev }
        if let short = comp?.team?.shortDisplayName, !short.isEmpty {
            return String(short.prefix(3)).uppercased()
        }
        if let name = comp?.athlete?.shortName ?? comp?.athlete?.displayName {
            return name.split(separator: " ").last.map(String.init) ?? name
        }
        return fallback
    }

    /// Downloads a team logo, renders it down to a small PNG, and writes it
    /// into the shared app-group container so the widget process can show
    /// it. Returns the stored filename, or nil (widget falls back to the
    /// team-color monogram).
    private nonisolated static func stageLogo(urlString: String?, key: String) async -> String? {
        guard let urlString, let url = URL(string: urlString),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: GameActivityAttributes.appGroupID)
        else { return nil }

        let dir = container.appendingPathComponent("Logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "\(key).png"
        let dest = dir.appendingPathComponent(filename)

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return nil }
            // Live Activity views run under a tight memory cap — store a
            // small fixed-size render, not the original asset. 144px covers
            // the 48pt lock-screen logo at 3x.
            let side: CGFloat = 144
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            let scaled = renderer.image { _ in
                let aspect = min(side / max(image.size.width, 1), side / max(image.size.height, 1))
                let drawSize = CGSize(width: image.size.width * aspect, height: image.size.height * aspect)
                let origin = CGPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
                image.draw(in: CGRect(origin: origin, size: drawSize))
            }
            guard let png = scaled.pngData() else { return nil }
            try png.write(to: dest)
            return filename
        } catch {
            return nil
        }
    }

    func stop(_ gameID: String) {
        guard let activity = activities.removeValue(forKey: gameID) else {
            trackedGameIDs.remove(gameID)
            return
        }
        trackedGameIDs.remove(gameID)
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Pushes the latest scores into every running activity. Games that
    /// went final get one last update, stay on the Lock Screen briefly,
    /// then dismiss; games missing from the pool entirely are ended.
    func sync(pool: [ESPNEvent]) {
        guard !trackedGameIDs.isEmpty else { return }
        var byID: [String: ESPNEvent] = [:]
        for game in pool { byID[game.id] = game }

        for gameID in trackedGameIDs {
            guard let activity = activities[gameID] else { continue }
            guard let game = byID[gameID] else {
                stop(gameID)
                continue
            }
            let state = contentState(for: game)
            Task {
                if state.isFinal {
                    await activity.end(
                        .init(state: state, staleDate: nil),
                        dismissalPolicy: .after(Date().addingTimeInterval(15 * 60))
                    )
                } else {
                    await activity.update(.init(state: state, staleDate: nil))
                }
            }
            if state.isFinal {
                activities.removeValue(forKey: gameID)
                trackedGameIDs.remove(gameID)
            }
        }
    }

    /// The top of a field event's leaderboard, already formatted for display.
    ///
    /// A tournament or a race weekend has a field, not two sides — reporting it
    /// as "player vs player" picks two entrants arbitrarily and says nothing
    /// about the event. Racing reads its order from the session being run;
    /// golf from the leaderboard itself.
    private static func leaderboardLines(for game: ESPNEvent, limit: Int = 3) -> [String]? {
        guard game.isFieldEvent else { return nil }

        let entrants: [ESPNCompetitor]
        if game.isRaceEvent {
            let current = game.currentRaceSession
            let session = current?.state == "in" ? current : (game.latestFinishedRaceSession ?? current)
            entrants = session?.order ?? []
        } else {
            entrants = (game.allCompetitions.first?.competitors ?? [])
                .sorted { ($0.order ?? 999) < ($1.order ?? 999) }
        }
        guard !entrants.isEmpty else { return nil }

        return entrants.prefix(limit).enumerated().map { index, entrant in
            let name = entrant.athlete?.shortName
                ?? entrant.athlete?.displayName
                ?? entrant.team?.shortDisplayName
                ?? "—"
            let score = entrant.score.map { $0.isEmpty ? "" : "  \($0)" } ?? ""
            return "\(index + 1)  \(name)\(score)"
        }
    }

    private func contentState(for game: ESPNEvent) -> GameActivityAttributes.ContentState {
        let situation = game.allCompetitions.first?.situation
        // Football: "3rd & 4 · DAL 35" reads better with possession spot.
        var situationText = situation?.shortDownDistanceText ?? situation?.downDistanceText
        if let text = situationText, let spot = situation?.possessionText {
            situationText = "\(text) · \(spot)"
        }
        return GameActivityAttributes.ContentState(
            homeScore: game.homeCompetitor?.score ?? "0",
            awayScore: game.awayCompetitor?.score ?? "0",
            statusDetail: game.status.type.detail,
            isFinal: game.status.type.state == "post",
            onFirst: situation?.onFirst,
            onSecond: situation?.onSecond,
            onThird: situation?.onThird,
            balls: situation?.balls,
            strikes: situation?.strikes,
            outs: situation?.outs,
            situationText: situationText,
            leaderboard: Self.leaderboardLines(for: game)
        )
    }
}
