import SwiftUI
import Combine

// MARK: - Scoreboard payloads (per-fight fields)

/// The shared scoreboard models only carry competitors per competition —
/// MMA needs the per-fight extras (weight class, round/clock, win method),
/// so the detail page re-decodes the scoreboard with these.
private nonisolated struct MMAScoreboardRaw: Codable {
    let events: [MMAEventRaw]?
}
private nonisolated struct MMAEventRaw: Codable {
    let id: String?
    let name: String?
    let competitions: [MMAFightRaw]?
    let venues: [MMAVenueRaw]?
    let status: ESPNStatus?
}
private nonisolated struct MMAVenueRaw: Codable {
    let fullName: String?
    let address: MMAAddressRaw?
}
private nonisolated struct MMAAddressRaw: Codable {
    let city: String?
    let state: String?
}
private nonisolated struct MMAFightRaw: Codable {
    let id: String?
    let date: String?
    let type: MMAFightTypeRaw?
    let status: MMAStatusRaw?
    let competitors: [ESPNCompetitor]?
    let details: [MMADetailRaw]?
}
private nonisolated struct MMAFightTypeRaw: Codable { let abbreviation: String? }
private nonisolated struct MMAStatusRaw: Codable {
    let displayClock: String?
    let period: Int?
    let type: ESPNStatusType?
}
private nonisolated struct MMADetailRaw: Codable { let type: MMADetailTypeRaw? }
private nonisolated struct MMADetailTypeRaw: Codable { let text: String? }

// MARK: - Display model

struct MMAFight: Identifiable {
    struct Fighter {
        let name: String
        let flag: String?
        let record: String?
        let winner: Bool
    }
    let id: String
    let weightClass: String?
    let statusText: String
    let state: String
    /// "KO/TKO", "Submission", "Decision" — finished fights only.
    let method: String?
    let away: Fighter
    let home: Fighter
}

// MARK: - View model

/// Drives the MMA event page: the whole card as a list of fights, main
/// event first, re-polled while the card is live.
@MainActor
final class MMADetailViewModel: ObservableObject {
    @Published private(set) var fights: [MMAFight] = []
    @Published private(set) var eventName: String
    @Published private(set) var venueLine: String?
    @Published private(set) var statusState: String
    @Published private(set) var isLoading = true

    private let eventID: String

    init(game: ESPNEvent) {
        eventID = game.id
        eventName = game.shortName
        statusState = game.status.type.state
        _ = game
    }

    /// Search terms for the watch button: the main event's fighters plus
    /// the promotion keyword.
    var searchTerms: (home: String, away: String) {
        guard let main = fights.first else { return (eventName, "") }
        let home = TennisFeed.lastName(main.home.name) ?? main.home.name
        let away = TennisFeed.lastName(main.away.name) ?? main.away.name
        return (home + " ufc mma", away)
    }

    func refreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            guard statusState != "post" else { return }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    private func refresh() async {
        guard let url = URL(string: SportType.mma.endpoint) else { return }
        guard let (data, _) = try? await ScoreViewModel.noCacheSession.data(from: url) else { return }
        guard let board = try? JSONDecoder().decode(MMAScoreboardRaw.self, from: data) else { return }
        guard let event = board.events?.first(where: { $0.id == eventID }) else {
            isLoading = false
            return
        }
        eventName = event.name ?? eventName
        statusState = event.status?.type.state ?? statusState
        if let venue = event.venues?.first {
            let city = [venue.address?.city, venue.address?.state].compactMap { $0 }.joined(separator: ", ")
            venueLine = [venue.fullName, city.isEmpty ? nil : city].compactMap { $0 }.joined(separator: " · ")
        }
        // Feed order runs prelims → main event; show the main event first.
        fights = (event.competitions ?? []).reversed().compactMap { Self.fight(from: $0) }
        isLoading = false
    }

    private nonisolated static func fight(from raw: MMAFightRaw) -> MMAFight? {
        guard let id = raw.id, let competitors = raw.competitors, competitors.count >= 2 else { return nil }
        let away = competitors.first { $0.order == 2 } ?? competitors[0]
        let home = competitors.first { $0.order == 1 } ?? competitors[1]
        let state = raw.status?.type?.state ?? "pre"

        var statusText = raw.status?.type?.detail ?? ""
        if state == "in", let round = raw.status?.period, let clock = raw.status?.displayClock {
            statusText = "R\(round) · \(clock)"
        } else if state == "post", let round = raw.status?.period, let clock = raw.status?.displayClock {
            statusText = "R\(round) \(clock)"
        } else if state == "pre" {
            statusText = ""
        }

        return MMAFight(
            id: id,
            weightClass: raw.type?.abbreviation,
            statusText: statusText,
            state: state,
            method: method(from: raw.details),
            away: fighter(away),
            home: fighter(home)
        )
    }

    private nonisolated static func fighter(_ competitor: ESPNCompetitor) -> MMAFight.Fighter {
        MMAFight.Fighter(
            name: competitor.athlete?.shortName ?? competitor.athlete?.displayName ?? "TBD",
            flag: competitor.athlete?.flag?.href,
            record: competitor.records?.first?.summary,
            winner: competitor.winner == true
        )
    }

    /// The win method hides in the fight's play details as
    /// "(Unofficial) Winner <Method>" entries; "Kotko" is ESPN's internal
    /// name for KO/TKO.
    private nonisolated static func method(from details: [MMADetailRaw]?) -> String? {
        for detail in details ?? [] {
            guard let text = detail.type?.text, let range = text.range(of: "Winner ") else { continue }
            let raw = String(text[range.upperBound...])
            switch raw.lowercased() {
            case "kotko": return "KO/TKO"
            case "submission": return "Submission"
            case "decision": return "Decision"
            default: return raw
            }
        }
        return nil
    }
}

// MARK: - Detail page

/// MMA event page: the full fight card, main event first — fighters with
/// flags and records, weight class, live round/clock, and the finish
/// method for completed bouts.
struct MMADetailContentView: View {
    let request: GameDetailRequest
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color

    @StateObject private var detail: MMADetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var collapseProgress = ScrollProgress()

    init(request: GameDetailRequest, viewModel: ChannelViewModel, accentColor: Color) {
        self.request = request
        self.viewModel = viewModel
        self.accentColor = accentColor
        _detail = StateObject(wrappedValue: MMADetailViewModel(game: request.game))
    }

    private var isLive: Bool { detail.statusState == "in" }

    var body: some View {
        ZStack {
            backgroundLayer

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    headerCard
                    watchButton
                    if detail.isLoading && detail.fights.isEmpty {
                        CustomSpinner(color: .white, lineWidth: 4, size: 36)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if detail.fights.isEmpty {
                        EmptyStateView(
                            title: "No Fight Card",
                            systemImage: "figure.boxing",
                            description: "The card for this event isn't available."
                        )
                        .padding(.top, 40)
                    } else {
                        fightCardSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, scrolled in
                collapseProgress.set(min(max((scrolled - 105) / 50, 0), 1))
            }
            .overlay(alignment: .top) {
                compactHeader
                    .scrollProgressReveal(collapseProgress)
            }
        }
        .preferredColorScheme(.dark)
        .task(id: request.id) {
            await detail.refreshLoop()
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.08).ignoresSafeArea()
            LinearGradient(
                colors: [Color(red: 0.75, green: 0.12, blue: 0.15).opacity(0.55), .clear],
                startPoint: .topLeading,
                endPoint: UnitPoint(x: 0.6, y: 0.7)
            )
            LinearGradient(
                colors: [accentColor.opacity(0.3), .clear],
                startPoint: .topTrailing,
                endPoint: UnitPoint(x: 0.4, y: 0.6)
            )
        }
        .ignoresSafeArea()
    }

    private var compactHeader: some View {
        HStack(spacing: 10) {
            Text(detail.eventName)
                .font(.system(size: 15, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            Text(isLive ? "LIVE" : (detail.statusState == "post" ? "Final" : ""))
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(isLive ? .red : .secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(alignment: .top) { PinnedHeaderGradient() }
    }

    private var headerCard: some View {
        VStack(spacing: 8) {
            Text("UFC")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.secondary)
            Text(detail.eventName)
                .font(.system(size: 22, weight: .heavy))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
            if let venue = detail.venueLine {
                Text(venue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text(request.game.status.type.detail)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isLive ? .red : .secondary)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private var watchButton: some View {
        HStack(spacing: 10) {
            Button {
                ChannelViewModel.shared.triggerHaptic(.medium)
                let terms = detail.searchTerms
                let game = request.game
                dismiss()
                viewModel.runSmartSearch(
                    gameID: game.id,
                    home: terms.home,
                    away: terms.away,
                    sport: .mma,
                    network: game.broadcastName
                )
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(isLive ? "Watch Live" : "Find Stream")
                    if let network = request.game.broadcastName {
                        Text(network)
                            .font(.system(size: 11, weight: .black))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .modifier(WatchButtonGlass())
            }
            .buttonStyle(.plain)

            if isLive {
                LiveActivityPillButton(game: request.game, leagueName: "UFC", sport: .mma)
            }
        }
    }

    // MARK: Fight card

    private var fightCardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FIGHT CARD")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white.opacity(0.75))
            VStack(spacing: 10) {
                ForEach(Array(detail.fights.enumerated()), id: \.element.id) { index, fight in
                    fightRow(fight, isMainEvent: index == 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func fightRow(_ fight: MMAFight, isMainEvent: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(isMainEvent ? "MAIN EVENT" : (fight.weightClass?.uppercased() ?? "BOUT"))
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(isMainEvent ? .yellow : .secondary)
                if isMainEvent, let weight = fight.weightClass {
                    Text(weight.uppercased())
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if fight.state == "in" {
                    Text(fight.statusText.isEmpty ? "LIVE" : fight.statusText)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.red)
                } else if fight.state == "post" {
                    Text([fight.method, fight.statusText.isEmpty ? nil : fight.statusText].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                mmaFighterColumn(fight.away, align: .leading)
                Text("vs")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tertiary)
                mmaFighterColumn(fight.home, align: .trailing)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func mmaFighterColumn(_ fighter: MMAFight.Fighter, align: HorizontalAlignment) -> some View {
        HStack(spacing: 7) {
            if align == .trailing { fighterText(fighter, alignment: .trailing) }
            CachedAsyncImage(urlString: fighter.flag ?? "", size: CGSize(width: 20, height: 20))
                .frame(width: 20, height: 20)
            if align == .leading { fighterText(fighter, alignment: .leading) }
        }
        .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
    }

    private func fighterText(_ fighter: MMAFight.Fighter, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            HStack(spacing: 4) {
                if alignment == .trailing && fighter.winner {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.green)
                }
                Text(fighter.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if alignment == .leading && fighter.winner {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.green)
                }
            }
            if let record = fighter.record {
                Text(record)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
