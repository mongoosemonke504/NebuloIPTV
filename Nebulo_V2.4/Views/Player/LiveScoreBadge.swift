import SwiftUI

/// Small glassy "LIVE · TEAM A 2 — 1 TEAM B · 73'" pill that overlays the video
/// when the channel is broadcasting a live ESPN game.
struct LiveScoreBadge: View {
    let game: ESPNEvent

    var body: some View {
        HStack(spacing: 8) {
            // Pulsing red LIVE pill
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
                    .kerning(0.6)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.red.opacity(0.85))
            .clipShape(Capsule())

            // Score line
            Text(scoreLine)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            // Clock / period
            if !clockText.isEmpty {
                Text("·")
                    .foregroundStyle(.white.opacity(0.6))
                Text(clockText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .modifier(GlassEffect(cornerRadius: 18, isSelected: true, accentColor: nil))
    }

    private var scoreLine: String {
        let homeName = game.homeCompetitor?.team?.shortDisplayName
            ?? game.homeCompetitor?.team?.abbreviation
            ?? game.homeCompetitor?.team?.displayName
            ?? "HOME"
        let awayName = game.awayCompetitor?.team?.shortDisplayName
            ?? game.awayCompetitor?.team?.abbreviation
            ?? game.awayCompetitor?.team?.displayName
            ?? "AWAY"
        let homeScore = game.homeCompetitor?.score ?? "0"
        let awayScore = game.awayCompetitor?.score ?? "0"
        return "\(homeName.uppercased()) \(homeScore) — \(awayScore) \(awayName.uppercased())"
    }

    /// Trim ESPN's verbose status string into something compact, e.g. "73'", "2nd 4:32", "HT", "Bottom 3rd".
    private var clockText: String {
        let raw = game.status.type.detail

        // Handle baseball inning info: "bottom", "top", "bottom 1", "top 5", etc.
        let lowercased = raw.lowercased()
        if lowercased.contains("bottom") || lowercased.contains("top") {
            // Try to find inning number in the string
            let components = raw.split(separator: " ").map(String.init)
            if components.count >= 2, let inning = components.last {
                // Format as "Bottom 3rd", "Top 5th", etc.
                let ordinal = getOrdinalSuffix(inning)
                return "\(components[0].capitalized) \(inning)\(ordinal)"
            } else if components.count == 1 {
                // Just "bottom" or "top" without inning number
                return components[0].capitalized
            }
        }

        // ESPN soccer often returns "73'" already; pass through if short
        if raw.count <= 8 { return raw }
        // Otherwise take the first space-separated component
        return raw.split(separator: " ").first.map(String.init) ?? raw
    }

    private func getOrdinalSuffix(_ number: String) -> String {
        guard let num = Int(number) else { return "" }
        switch num % 10 {
        case 1 where num % 100 != 11: return "st"
        case 2 where num % 100 != 12: return "nd"
        case 3 where num % 100 != 13: return "rd"
        default: return "th"
        }
    }
}
