import Foundation

/// Homemade FotMob-style match rating (1.0–10.0, ~6.0 = average) computed
/// from the raw per-player stats ESPN exposes. ESPN provides no rating of
/// its own, so this is a weighted sum per sport: positive contributions
/// (goals, assists, saves, points…) push above the baseline, negatives
/// (cards, turnovers, earned runs…) pull below. Weights are tuned so a
/// quiet-but-clean game sits near 6, a strong game lands 7–8, and only a
/// genuinely dominant performance reaches 9+.
nonisolated enum PlayerRatingEngine {

    static func clampRating(_ r: Double) -> Double {
        (min(10.0, max(1.0, r)) * 10).rounded() / 10
    }

    // MARK: - Soccer (from summary `rosters` per-player stats)

    /// Rates a soccer lineup player from the roster stat list. Returns nil
    /// for players who never entered the match.
    /// FotMob-style: 6.0 is a quiet-but-clean game, end product (goals,
    /// assists) moves the needle most, sustained involvement (passing,
    /// defending) accumulates, mistakes and cards subtract, and short
    /// cameos are damped toward average because a 10-minute sub simply
    /// hasn't produced enough evidence either way. Every stat ESPN sends
    /// for a soccer player feeds in.
    static func soccerRating(stats: [GSPlayerStat], isGoalkeeper: Bool) -> Double? {
        var v: [String: Double] = [:]
        for s in stats {
            // Keyed by BOTH forms — scoring stats read best by abbreviation
            // ("G", "SOG"), the passing/defending extras only exist under
            // their full names ("accuratePasses", "effectiveTackles").
            if let key = s.abbreviation { v[key] = s.value ?? 0 }
            if let key = s.name { v[key] = s.value ?? 0 }
        }
        guard (v["APP"] ?? 0) > 0 else { return nil }

        var r = 6.0

        // End product. A keeper or defender scoring is a bigger event.
        let goals = v["G"] ?? 0
        r += goals * (isGoalkeeper ? 1.60 : 1.10)
        r += (v["A"] ?? 0) * 0.80
        let onTarget = v["SOG"] ?? 0
        r += max(0, onTarget - goals) * 0.16   // kept the keeper working
        r -= max(0, (v["SHOT"] ?? 0) - onTarget) * 0.02  // wayward shooting

        // Ball use. ESPN has no dribble or duel data, so passing volume ×
        // accuracy, crosses and long balls are the on-ball proxies. ~72%
        // is average completion; credit scales with volume but caps so a
        // metronome center-back can't outscore a match-winner.
        let passes = v["totalPasses"] ?? 0
        if passes >= 5 {
            let accuracy = (v["accuratePasses"] ?? 0) / passes
            r += (accuracy - 0.72) * min(passes, 70) * 0.05
        }
        r += (v["accurateCrosses"] ?? 0) * 0.09
        r += (v["accurateLongBalls"] ?? 0) * 0.03
        r -= (v["OF"] ?? 0) * 0.06             // offsides

        // Defensive work rate.
        r += (v["effectiveTackles"] ?? 0) * 0.14
        r += (v["interceptions"] ?? 0) * 0.11
        r += (v["effectiveClearance"] ?? 0) * 0.04
        r += (v["blockedShots"] ?? 0) * 0.09

        // Duels won/lost show up as fouls drawn/committed.
        r += (v["FA"] ?? 0) * 0.05
        r -= (v["FC"] ?? 0) * 0.08

        // Discipline and catastrophes.
        r -= (v["YC"] ?? 0) * 0.40
        r -= (v["RC"] ?? 0) * 1.75
        r -= (v["OG"] ?? 0) * 1.25

        let minutes = v["minutes"] ?? 90
        if isGoalkeeper {
            let conceded = v["GA"] ?? 0
            r += (v["SV"] ?? 0) * 0.26
            r -= conceded * 0.45
            r += (v["crossesCaught"] ?? 0) * 0.07
            r += (v["punches"] ?? 0) * 0.03
            if conceded == 0 && minutes >= 45 { r += 0.45 }  // clean sheet
        }

        // Low-minute damping: pull short cameos toward 6.0.
        if minutes > 0 && minutes < 30 {
            r = 6.0 + (r - 6.0) * (0.4 + 0.6 * minutes / 30)
        }
        return clampRating(r)
    }

    // MARK: - US sports (from summary `boxscore.players` stat groups)

    /// Rates a box-score athlete from every stat group they appear in.
    /// `groups` pairs each group's name with the athlete's parsed columns
    /// (column label → raw display string). Returns nil when the player
    /// logged nothing ratable (DNP, empty line).
    static func boxScoreRating(sport: SportType, groups: [(group: String, columns: [String: String])]) -> Double? {
        guard !groups.isEmpty else { return nil }
        switch sport {
        case .nba, .wnba, .cbb: return basketballRating(groups: groups)
        case .nfl, .cfb: return footballRating(groups: groups)
        case .mlb, .softball: return baseballRating(groups: groups)
        case .nhl, .collegeHockey: return hockeyRating(groups: groups)
        default: return nil
        }
    }

    /// Hollinger game-score, shifted onto the 1–10 scale.
    private static func basketballRating(groups: [(group: String, columns: [String: String])]) -> Double? {
        guard let cols = groups.first?.columns else { return nil }
        let min = num(cols["MIN"])
        guard min > 0 else { return nil }
        let (fgm, fga) = pair(cols["FG"])
        let (ftm, fta) = pair(cols["FT"])
        let gameScore = num(cols["PTS"])
            + 0.4 * fgm - 0.7 * fga
            - 0.4 * (fta - ftm)
            + 0.7 * num(cols["OREB"]) + 0.3 * num(cols["DREB"])
            + num(cols["STL"]) + 0.7 * num(cols["AST"]) + 0.7 * num(cols["BLK"])
            - 0.4 * num(cols["PF"]) - num(cols["TO"])
        return clampRating(5.2 + gameScore * 0.16)
    }

    private static func footballRating(groups: [(group: String, columns: [String: String])]) -> Double? {
        var r = 5.5
        var contributed = false
        for (group, cols) in groups {
            switch group {
            case "passing":
                let yds = num(cols["YDS"])
                guard yds != 0 || num(cols["TD"]) != 0 || num(cols["INT"]) != 0 else { continue }
                r += yds * 0.006 + num(cols["TD"]) * 0.7 - num(cols["INT"]) * 0.9
                contributed = true
            case "rushing":
                let car = num(cols["CAR"])
                guard car > 0 else { continue }
                r += num(cols["YDS"]) * 0.018 + num(cols["TD"]) * 0.7
                contributed = true
            case "receiving":
                let rec = num(cols["REC"])
                guard rec > 0 || num(cols["TGTS"]) > 0 else { continue }
                r += rec * 0.08 + num(cols["YDS"]) * 0.014 + num(cols["TD"]) * 0.7
                contributed = true
            case "fumbles":
                r -= num(cols["LOST"]) * 0.8
            case "defensive":
                let tot = num(cols["TOT"])
                guard tot > 0 || num(cols["SACKS"]) > 0 else { continue }
                r += tot * 0.12 + num(cols["SACKS"]) * 0.9 + num(cols["TD"]) * 1.0
                contributed = true
            case "interceptions":
                r += num(cols["INT"]) * 1.2
                contributed = true
            default:
                continue
            }
        }
        return contributed ? clampRating(r) : nil
    }

    private static func baseballRating(groups: [(group: String, columns: [String: String])]) -> Double? {
        var r = 5.5
        var contributed = false
        for (group, cols) in groups {
            switch group {
            case "batting":
                let ab = num(cols["AB"])
                guard ab > 0 else { continue }
                r += num(cols["H"]) * 0.45 + num(cols["R"]) * 0.25 + num(cols["RBI"]) * 0.35
                    + num(cols["HR"]) * 0.5 + num(cols["BB"]) * 0.15 + num(cols["SB"]) * 0.2
                    - num(cols["K"]) * 0.12
                contributed = true
            case "pitching":
                let ip = num(cols["IP"])
                guard ip > 0 else { continue }
                r += 0.3 + ip * 0.12 + num(cols["K"]) * 0.12
                    - num(cols["ER"]) * 0.55 - num(cols["BB"]) * 0.08 - num(cols["H"]) * 0.03
                contributed = true
            default:
                continue
            }
        }
        return contributed ? clampRating(r) : nil
    }

    private static func hockeyRating(groups: [(group: String, columns: [String: String])]) -> Double? {
        for (group, cols) in groups {
            if group.lowercased().contains("goalie") || cols["SA"] != nil {
                let sa = num(cols["SA"])
                guard sa > 0 else { continue }
                return clampRating(5.0 + num(cols["SV"]) * 0.045 - num(cols["GA"]) * 0.55)
            }
            let toi = cols["TOI"] ?? cols["MIN"]
            guard toi != nil else { continue }
            var r = 5.8
            r += num(cols["G"]) * 1.1 + num(cols["A"]) * 0.75 + num(cols["SOG"]) * 0.08
            r += num(cols["HITS"]) * 0.04 + num(cols["BS"]) * 0.05 + num(cols["+/-"]) * 0.12
            r -= num(cols["PIM"]) * 0.08
            return clampRating(r)
        }
        return nil
    }

    // MARK: - Parsing helpers

    /// First number in a display string ("202" → 202, "-7" → -7, "5.3" → 5.3).
    private static func num(_ s: String?) -> Double {
        guard let s, !s.isEmpty else { return 0 }
        return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// Made/attempted split ("7-15" or "19/38" → (7, 15)).
    private static func pair(_ s: String?) -> (Double, Double) {
        guard let s else { return (0, 0) }
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard parts.count == 2,
              let a = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let b = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return (0, 0) }
        return (a, b)
    }
}
