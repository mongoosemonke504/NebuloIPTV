import SwiftUI
import Combine

/// Everything the Formula 1 and golf tabs of the game card need, loaded once
/// per card.
///
/// Both sports are FIELD events — dozens of individual entrants on a
/// leaderboard rather than two sides on a scoreline — and neither has a
/// `summary` endpoint, so `GameDetailViewModel` has nothing to work with. This
/// stands alongside it and feeds the extra tabs.
@MainActor
final class FieldEventModel: ObservableObject {
    @Published private(set) var season: F1DetailService.Season?
    @Published private(set) var circuit: F1DetailService.CircuitDetail?
    /// session abbreviation → driver id → enriched classification entry.
    @Published private(set) var sessionDetail: [String: [String: F1DetailService.SessionEntry]] = [:]
    @Published private(set) var feeds: [F1DetailService.DriverFeed] = []
    @Published private(set) var tournament: GolfDetailService.Tournament?
    @Published private(set) var loading = false

    private var loadedEventID: String?
    private var loadingSessions: Set<String> = []

    func load(event: ESPNEvent, isRace: Bool, viewModel: ChannelViewModel) async {
        guard loadedEventID != event.id else { return }
        loadedEventID = event.id
        loading = true
        defer { loading = false }

        if isRace {
            async let s = F1DetailService.fetchSeason()
            async let c: F1DetailService.CircuitDetail? = {
                guard let id = event.circuit?.id else { return nil }
                return await F1DetailService.fetchCircuit(id: id)
            }()
            season = await s
            circuit = await c
            scanForDriverFeeds(event: event, viewModel: viewModel)
            if let lead = event.latestFinishedRaceSession ?? event.currentRaceSession {
                await loadSession(lead.label, eventID: event.id)
            }
        } else {
            tournament = await GolfDetailService.fetchTournament(eventID: event.id)
        }
    }

    func loadSession(_ label: String, eventID: String) async {
        guard sessionDetail[label] == nil, !loadingSessions.contains(label) else { return }
        loadingSessions.insert(label)
        let detail = await F1DetailService.fetchSessionDetail(eventID: eventID, sessionAbbreviation: label)
        sessionDetail[label] = detail
        loadingSessions.remove(label)
    }

    /// Which drivers to look for: the championship order when we have it, else
    /// whoever's entered this weekend.
    private func scanForDriverFeeds(event: ESPNEvent, viewModel: ChannelViewModel) {
        var names: [String] = []
        var seen = Set<String>()
        let source: [String] = season.map { $0.standings.map(\.name) }
            ?? event.raceSessions.flatMap { $0.order }.compactMap { $0.athlete?.displayName }
        for name in source where seen.insert(name).inserted { names.append(name) }
        guard !names.isEmpty else { return }

        var categoryNames: [Int: String] = [:]
        for category in viewModel.categories { categoryNames[category.id] = category.name }
        feeds = F1DetailService.driverFeeds(
            drivers: names,
            channels: viewModel.channels,
            categoryNames: categoryNames,
            hiddenChannelIDs: viewModel.hiddenIDs,
            hiddenCategoryIDs: Set(viewModel.categories.filter(\.isHidden).map(\.id))
        )
    }
}

// MARK: - Shared chrome

/// The card sections use one surface everywhere, matching the team card's rows.
private struct FieldCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
    }
}

private struct FieldSectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .black))
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FieldRowDivider: View {
    var inset: CGFloat = 12
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

/// Under par green, over par red, level white — golf's own convention, also
/// used for the leaderboard totals on the Live Now card.
func golfParColor(_ total: String?) -> Color {
    guard let total, !total.isEmpty else { return .white }
    if total.hasPrefix("-") { return Color(red: 0.35, green: 0.85, blue: 0.45) }
    if total.hasPrefix("+") { return Color(red: 1.0, green: 0.45, blue: 0.42) }
    return .white
}

// MARK: - Formula 1

/// The weekend's five sessions with their days, times and state, plus the
/// podium of the last one that ran.
struct RaceWeekendPanel: View {
    let race: ESPNEvent
    @ObservedObject var model: FieldEventModel
    let onSelectSession: (String) -> Void

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                FieldSectionTitle(text: "Schedule")
                FieldCard {
                    ForEach(Array(race.raceSessions.enumerated()), id: \.element.id) { index, session in
                        Button {
                            guard SwipeTapGuard.tapsAllowed else { return }
                            guard !session.order.isEmpty, session.state != "pre" else { return }
                            onSelectSession(session.label)
                        } label: {
                            HStack(spacing: 12) {
                                Text(ScoreRow.sessionName(session.label))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 2) {
                                    if session.state == "in" {
                                        HStack(spacing: 5) {
                                            Circle().fill(Color.red).frame(width: 6, height: 6)
                                            Text("LIVE")
                                                .font(.system(size: 11, weight: .black))
                                                .foregroundStyle(.red)
                                        }
                                    } else if let date = session.date {
                                        Text(Self.dayFmt.string(from: date))
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.primary)
                                        Text(Self.timeFmt.string(from: date))
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text(session.detail)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if !session.order.isEmpty, session.state != "pre" {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < race.raceSessions.count - 1 { FieldRowDivider() }
                    }
                }
            }

            if let finished = race.latestFinishedRaceSession, !finished.order.isEmpty {
                VStack(spacing: 8) {
                    FieldSectionTitle(text: "\(ScoreRow.sessionName(finished.label)) — Top 3")
                    FieldCard {
                        ForEach(Array(finished.order.prefix(3).enumerated()), id: \.offset) { index, driver in
                            RaceClassificationRow(
                                position: index + 1,
                                competitor: driver,
                                detail: model.sessionDetail[finished.label]?[driver.id]
                            )
                            if index < 2 { FieldRowDivider() }
                        }
                    }
                }
            }
        }
    }
}

/// One line of a session's classification: position, flag, driver, constructor
/// with its team-colour bar, and the gap to the leader.
struct RaceClassificationRow: View {
    let position: Int
    let competitor: ESPNCompetitor
    let detail: F1DetailService.SessionEntry?

    private var teamColor: Color? {
        guard let hex = detail?.teamColor else { return nil }
        return Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)")
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)

            if let flag = competitor.athlete?.flag?.href, !flag.isEmpty {
                CachedAsyncImage(urlString: flag,
                                 size: CGSize(width: 18, height: 18),
                                 decodeSize: CGSize(width: 54, height: 54))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(competitor.athlete?.displayName ?? competitor.athlete?.shortName ?? "—")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let constructor = detail?.constructor {
                    HStack(spacing: 5) {
                        if let number = detail?.number, !number.isEmpty {
                            Text("#\(number)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        Text(constructor)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 1) {
                // The leader shows an absolute time; everyone behind shows
                // their gap to it, the way a timing screen reads.
                if let gap = detail?.gap, !gap.isEmpty {
                    Text(gap)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                } else if let time = detail?.time, !time.isEmpty {
                    Text(time)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
                if let points = detail?.points, points != "0", !points.isEmpty {
                    Text("\(points) pts")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else if detail?.gap != nil, let time = detail?.time, !time.isEmpty {
                    Text(time)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .leading) {
            if let teamColor {
                Rectangle().fill(teamColor).frame(width: 3)
            }
        }
    }
}

/// A session picker over the full classification.
struct RaceResultsPanel: View {
    let race: ESPNEvent
    @ObservedObject var model: FieldEventModel
    @Binding var selectedSession: String?
    let onNeedSession: (String) -> Void

    private var sessionsWithResults: [ESPNEvent.RaceSession] {
        race.raceSessions.filter { !$0.order.isEmpty && $0.state != "pre" }
    }

    private var current: ESPNEvent.RaceSession? {
        if let selectedSession, let hit = sessionsWithResults.first(where: { $0.label == selectedSession }) {
            return hit
        }
        return race.latestFinishedRaceSession ?? sessionsWithResults.last
    }

    var body: some View {
        VStack(spacing: 12) {
            if sessionsWithResults.count > 1 {
                // Its own horizontal scroll, kept out of the card's page-turning
                // gesture by TouchPassingHorizontalScroll.
                TouchPassingHorizontalScroll {
                    HStack(spacing: 8) {
                        ForEach(sessionsWithResults) { session in
                            let isOn = current?.label == session.label
                            Button {
                                guard SwipeTapGuard.tapsAllowed else { return }
                                selectedSession = session.label
                                onNeedSession(session.label)
                            } label: {
                                Text(ScoreRow.sessionName(session.label))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(isOn ? .black : .white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Capsule().fill(isOn ? Color.white : Color.white.opacity(0.10)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 32)
            }

            if let session = current, !session.order.isEmpty {
                FieldCard {
                    HStack(spacing: 10) {
                        Text("#").frame(width: 20, alignment: .leading)
                        Text("Driver").frame(maxWidth: .infinity, alignment: .leading)
                        Text("GAP").frame(width: 74, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    ForEach(Array(session.order.enumerated()), id: \.offset) { index, driver in
                        RaceClassificationRow(
                            position: index + 1,
                            competitor: driver,
                            detail: model.sessionDetail[session.label]?[driver.id]
                        )
                        if index < session.order.count - 1 { FieldRowDivider() }
                    }
                }
            } else {
                FieldEmptyNote(text: "No classification yet")
            }
        }
        .task(id: current?.label) {
            if let label = current?.label { onNeedSession(label) }
        }
    }
}

/// Per-driver onboard feeds found in the user's own playlist.
struct RaceDriversPanel: View {
    @ObservedObject var model: FieldEventModel
    let onPlay: (StreamChannel) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Onboard feeds found in your playlist.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(model.feeds) { feed in
                let standing = model.season?.standings.first { $0.name == feed.driver }
                FieldCard {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 9) {
                            if let flag = standing?.flag, !flag.isEmpty {
                                CachedAsyncImage(urlString: flag,
                                                 size: CGSize(width: 18, height: 18),
                                                 decodeSize: CGSize(width: 54, height: 54))
                                    .clipShape(RoundedRectangle(cornerRadius: 2))
                            }
                            Text(feed.driver)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if let rank = standing?.rank {
                                Text("P\(rank)")
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // Providers often carry the same driver at several
                        // qualities, so every match gets its own button.
                        ForEach(feed.channels) { channel in
                            Button {
                                guard SwipeTapGuard.tapsAllowed else { return }
                                onPlay(channel)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(channel.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.white.opacity(0.09))
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

/// Drivers' and constructors' championships.
struct RaceStandingsPanel: View {
    @ObservedObject var model: FieldEventModel

    var body: some View {
        VStack(spacing: 14) {
            if let drivers = model.season?.standings, !drivers.isEmpty {
                VStack(spacing: 8) {
                    FieldSectionTitle(text: "Drivers' Championship")
                    FieldCard {
                        ForEach(Array(drivers.enumerated()), id: \.element.id) { index, row in
                            HStack(spacing: 10) {
                                Text(row.rank.map(String.init) ?? String(index + 1))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, alignment: .leading)
                                if let flag = row.flag, !flag.isEmpty {
                                    CachedAsyncImage(urlString: flag,
                                                     size: CGSize(width: 18, height: 18),
                                                     decodeSize: CGSize(width: 54, height: 54))
                                        .clipShape(RoundedRectangle(cornerRadius: 2))
                                }
                                Text(row.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(row.points ?? "–")
                                    .fontWeight(.bold)
                                    .foregroundStyle(.primary)
                                    .monospacedDigit()
                                    .frame(width: 46, alignment: .trailing)
                            }
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            if index < drivers.count - 1 { FieldRowDivider() }
                        }
                    }
                }
            }

            if let teams = model.season?.constructors, !teams.isEmpty {
                VStack(spacing: 8) {
                    FieldSectionTitle(text: "Constructors' Championship")
                    FieldCard {
                        ForEach(Array(teams.enumerated()), id: \.element.id) { index, row in
                            HStack(spacing: 10) {
                                Text(row.rank.map(String.init) ?? String(index + 1))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, alignment: .leading)
                                Text(row.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(row.points ?? "–")
                                    .fontWeight(.bold)
                                    .foregroundStyle(.primary)
                                    .monospacedDigit()
                                    .frame(width: 46, alignment: .trailing)
                            }
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .overlay(alignment: .leading) {
                                if let hex = row.color,
                                   let color = Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)") {
                                    Rectangle().fill(color).frame(width: 3)
                                }
                            }
                            if index < teams.count - 1 { FieldRowDivider() }
                        }
                    }
                }
            }
        }
    }
}

/// The track: layout diagram, lap count, lap record, distance.
struct RaceCircuitPanel: View {
    @ObservedObject var model: FieldEventModel

    var body: some View {
        if let circuit = model.circuit {
            VStack(spacing: 14) {
                if let diagram = circuit.diagram, !diagram.isEmpty {
                    CachedAsyncImage(urlString: diagram, size: nil, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                FieldInfoCard(title: circuit.name, rows: rows(circuit))
            }
        } else {
            FieldEmptyNote(text: "No circuit information")
        }
    }

    private func rows(_ c: F1DetailService.CircuitDetail) -> [FieldInfoRow] {
        var rows: [FieldInfoRow] = []
        if let v = c.location { rows.append(.init(icon: "mappin.and.ellipse", label: "Location", value: v)) }
        if let v = c.length { rows.append(.init(icon: "ruler", label: "Lap length", value: v)) }
        if let v = c.laps { rows.append(.init(icon: "arrow.triangle.2.circlepath", label: "Race laps", value: "\(v)")) }
        if let v = c.distance { rows.append(.init(icon: "flag.checkered", label: "Race distance", value: v)) }
        if let v = c.turns { rows.append(.init(icon: "arrow.turn.up.right", label: "Turns", value: "\(v)")) }
        if let v = c.direction { rows.append(.init(icon: "arrow.clockwise", label: "Direction", value: v)) }
        if let v = c.established { rows.append(.init(icon: "calendar", label: "Opened", value: "\(v)")) }
        if let time = c.lapRecordTime {
            rows.append(.init(icon: "stopwatch", label: "Lap record",
                              value: c.lapRecordYear.map { "\(time) (\($0))" } ?? time))
        }
        return rows
    }
}

// MARK: - Golf

/// The full field, with positions, totals and thru/tee time.
struct GolfLeaderboardPanel: View {
    @ObservedObject var model: FieldEventModel
    var highlightPlayer: String?
    @State private var showFullField = false

    private var field: [GolfDetailService.Player] { model.tournament?.field ?? [] }
    private var visible: [GolfDetailService.Player] {
        showFullField ? field : Array(field.prefix(25))
    }

    private var cutLine: String? {
        guard let t = model.tournament, let round = t.cutRound else { return nil }
        var parts = ["Cut after round \(round)"]
        if let score = t.cutScore { parts.append("at \(score)") }
        if let count = t.cutCount { parts.append("· \(count) players") }
        return parts.joined(separator: " ")
    }

    var body: some View {
        if field.isEmpty {
            FieldEmptyNote(text: "No field posted yet")
        } else {
            VStack(spacing: 10) {
                if let cutLine {
                    Text(cutLine)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                FieldCard {
                    HStack(spacing: 8) {
                        Text("POS").frame(width: 34, alignment: .leading)
                        Text("Player").frame(maxWidth: .infinity, alignment: .leading)
                        Text("TOT").frame(width: 38, alignment: .trailing)
                        Text("THRU").frame(width: 52, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, player in
                        row(player)
                        if index < visible.count - 1 { FieldRowDivider() }
                    }
                }

                if !showFullField, field.count > visible.count {
                    Button {
                        guard SwipeTapGuard.tapsAllowed else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { showFullField = true }
                    } label: {
                        Text("Show all \(field.count) players")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.09))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .onAppear { if highlightPlayer != nil { showFullField = true } }
        }
    }

    private func row(_ player: GolfDetailService.Player) -> some View {
        let isMe = highlightPlayer.map { sameName($0, player.name) } ?? false
        return HStack(spacing: 8) {
            HStack(spacing: 3) {
                Text(player.position ?? "–")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let movement = player.movement, movement != 0 {
                    Image(systemName: movement > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(movement > 0 ? .green : .red)
                }
            }
            .frame(width: 34, alignment: .leading)

            if let flag = player.flag, !flag.isEmpty {
                CachedAsyncImage(urlString: flag,
                                 size: CGSize(width: 18, height: 18),
                                 decodeSize: CGSize(width: 54, height: 54))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }

            HStack(spacing: 5) {
                Text(player.name)
                    .font(.system(size: 14, weight: isMe ? .heavy : .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if player.amateur {
                    Text("(a)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(player.total ?? "–")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(golfParColor(player.total))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)

            Text(thruText(player))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isMe ? Color.white.opacity(0.08) : Color.clear)
    }

    private func thruText(_ player: GolfDetailService.Player) -> String {
        if player.state == "in", let thru = player.thru, thru > 0 {
            return thru >= 18 ? "F" : "\(thru)"
        }
        if player.state == "pre", let tee = player.teeTime, !tee.isEmpty {
            return tee.replacingOccurrences(of: " ET", with: "")
        }
        if player.state == "post" { return "F" }
        if let thru = player.thru, thru > 0 { return "\(thru)" }
        return "–"
    }

    private func sameName(_ a: String, _ b: String) -> Bool {
        func normalize(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespaces)
        }
        return normalize(a) == normalize(b)
    }
}

/// Host course: par, yardage, and every hole.
struct GolfCoursePanel: View {
    @ObservedObject var model: FieldEventModel

    var body: some View {
        if let course = model.tournament?.course {
            VStack(spacing: 14) {
                FieldCard {
                    HStack(spacing: 0) {
                        stat("Par", course.par.map(String.init) ?? "–")
                        divider
                        stat("Yards", course.totalYards.map { "\($0)" } ?? "–")
                        divider
                        stat("Out / In",
                             [course.parOut, course.parIn].compactMap { $0 }.map(String.init).joined(separator: " / "))
                    }
                    .padding(.vertical, 13)
                }

                if !course.holes.isEmpty {
                    VStack(spacing: 8) {
                        FieldSectionTitle(text: "Scorecard")
                        FieldCard {
                            HStack(spacing: 8) {
                                Text("HOLE").frame(width: 44, alignment: .leading)
                                Text("PAR").frame(maxWidth: .infinity, alignment: .leading)
                                Text("YARDS").frame(width: 60, alignment: .trailing)
                            }
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)

                            ForEach(Array(course.holes.enumerated()), id: \.element.id) { index, hole in
                                HStack(spacing: 8) {
                                    Text("\(hole.number)")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .frame(width: 44, alignment: .leading)
                                    Text(hole.par.map { "Par \($0)" } ?? "–")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(hole.yards.map { "\($0)" } ?? "–")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .frame(width: 60, alignment: .trailing)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                if index < course.holes.count - 1 { FieldRowDivider() }
                            }
                        }
                    }
                }
            }
        } else {
            FieldEmptyNote(text: "No course information")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value.isEmpty ? "–" : value)
                .font(.system(size: 21, weight: .heavy))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .black))
                .kerning(0.5)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5, height: 34)
    }
}

/// Tournament statistical leaders and the purse / cut / defending champion.
struct GolfInfoPanel: View {
    @ObservedObject var model: FieldEventModel
    let event: ESPNEvent

    var body: some View {
        if let t = model.tournament {
            VStack(spacing: 14) {
                if t.isMajor {
                    Text("MAJOR CHAMPIONSHIP")
                        .font(.system(size: 11, weight: .black))
                        .kerning(0.8)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(red: 0.98, green: 0.82, blue: 0.35)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !t.leaders.isEmpty {
                    VStack(spacing: 8) {
                        FieldSectionTitle(text: "Tournament Leaders")
                        FieldCard {
                            ForEach(Array(t.leaders.enumerated()), id: \.element.id) { index, leader in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(leader.title.uppercased())
                                            .font(.system(size: 10, weight: .black))
                                            .kerning(0.4)
                                            .foregroundStyle(.secondary)
                                        Text(leader.player)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Text(leader.value)
                                        .font(.system(size: 17, weight: .heavy))
                                        .foregroundStyle(.primary)
                                        .monospacedDigit()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 11)
                                if index < t.leaders.count - 1 { FieldRowDivider() }
                            }
                        }
                    }
                }

                FieldInfoCard(title: "Tournament", rows: rows(t))
            }
        } else {
            FieldEmptyNote(text: "No tournament information")
        }
    }

    private func rows(_ t: GolfDetailService.Tournament) -> [FieldInfoRow] {
        var rows: [FieldInfoRow] = []
        if let v = t.purse { rows.append(.init(icon: "dollarsign.circle", label: "Purse", value: v)) }
        if let v = t.numberOfRounds { rows.append(.init(icon: "list.number", label: "Rounds", value: "\(v)")) }
        if let v = t.scoringSystem { rows.append(.init(icon: "function", label: "Scoring", value: v)) }
        if let round = t.cutRound {
            var text = "After round \(round)"
            if let score = t.cutScore { text += " at \(score)" }
            if let count = t.cutCount { text += " · \(count) players" }
            rows.append(.init(icon: "scissors", label: "Cut", value: text))
        }
        if let v = t.defendingChampion, !v.isEmpty {
            rows.append(.init(icon: "trophy", label: "Defending champion", value: v))
        }
        if let v = t.course?.name { rows.append(.init(icon: "flag", label: "Host course", value: v)) }
        if let v = event.broadcastName, !v.isEmpty {
            rows.append(.init(icon: "tv", label: "Network", value: v))
        }
        return rows
    }
}

// MARK: - Small shared pieces

struct FieldInfoRow: Identifiable {
    let icon: String
    let label: String
    let value: String
    var id: String { label }
}

struct FieldInfoCard: View {
    let title: String?
    let rows: [FieldInfoRow]

    var body: some View {
        VStack(spacing: 8) {
            if let title { FieldSectionTitle(text: title) }
            FieldCard {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in
                        HStack(spacing: 12) {
                            Image(systemName: row.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.white.opacity(0.10)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.label)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(row.value)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct FieldEmptyNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
    }
}
