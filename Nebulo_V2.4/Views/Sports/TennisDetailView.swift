import SwiftUI
import Combine

// MARK: - Core-API payloads (bio + match extras)

/// ESPN has no per-match stat feed for tennis (aces, serve % …aren't
/// published), so the detail page builds its "stats" from what does exist:
/// the full set-by-set line score, seeds/world ranks, and a player
/// comparison assembled from the core-API athlete records (age, height,
/// plays, career singles record, titles, prize money).
private nonisolated struct TCoreCompetition: Codable {
    let notes: [TCoreNote]?
    let court: TCoreCourt?
    let venue: TCoreVenue?
    let competitors: [TCoreCompetitor]?
}
private nonisolated struct TCoreNote: Codable { let text: String? }
private nonisolated struct TCoreCourt: Codable { let description: String? }
private nonisolated struct TCoreVenue: Codable {
    let address: TCoreAddress?
}
private nonisolated struct TCoreAddress: Codable { let summary: String? }
private nonisolated struct TCoreCompetitor: Codable {
    let id: String?
    let order: Int?
    let name: String?
    let tournamentSeed: Int?
}
private nonisolated struct TCoreAthlete: Codable {
    let displayName: String?
    let age: Int?
    let displayHeight: String?
    let hand: TCoreHand?
    let birthPlace: TCoreAddress?
}
private nonisolated struct TCoreHand: Codable { let displayValue: String? }
private nonisolated struct TCoreStatistics: Codable { let splits: TCoreSplits? }
private nonisolated struct TCoreSplits: Codable { let categories: [TCoreStatCategory]? }
private nonisolated struct TCoreStatCategory: Codable { let stats: [TCoreStat]? }
private nonisolated struct TCoreStat: Codable {
    let name: String?
    let displayValue: String?
    let value: Double?
}

/// One player's comparison column in the detail page.
struct TennisPlayerBio {
    var seed: Int?
    var age: String?
    var height: String?
    var hand: String?
    var birthplace: String?
    var singlesRecord: String?
    var titles: String?
    var prize: String?

    var hasAnything: Bool {
        age != nil || height != nil || hand != nil || singlesRecord != nil
    }
}

// MARK: - View model

/// Drives the tennis match detail page: seeds from the scoreboard event the
/// user tapped, re-polls the tour scoreboard while the match is live, and
/// fetches the one-time extras (court, result note, player bios) from
/// ESPN's core API.
@MainActor
final class TennisDetailViewModel: ObservableObject {
    @Published private(set) var game: ESPNEvent
    @Published private(set) var court: String?
    @Published private(set) var venueCity: String?
    @Published private(set) var resultNote: String?
    @Published private(set) var homeBio: TennisPlayerBio?
    @Published private(set) var awayBio: TennisPlayerBio?

    init(game: ESPNEvent) {
        _game = Published(initialValue: game)
    }

    var homeSide: ESPNCompetitor? { game.homeCompetitor }
    var awaySide: ESPNCompetitor? { game.awayCompetitor }

    var tournamentName: String? {
        game.leagueLabel?.components(separatedBy: TennisFeed.labelSeparator).first
    }

    var drawName: String? {
        guard let label = game.leagueLabel else { return nil }
        let parts = label.components(separatedBy: TennisFeed.labelSeparator)
        return parts.count > 1 ? parts.dropFirst().joined(separator: TennisFeed.labelSeparator) : nil
    }

    func refreshLoop() async {
        await loadExtras()
        while !Task.isCancelled && game.status.type.state != "post" {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            guard let path = game.tennisPath else { return }
            if let fresh = await TennisFeed.fetchMatch(id: game.id, tennisPath: path, session: ScoreViewModel.noCacheSession) {
                game = fresh
            }
        }
    }

    private nonisolated static func fetchJSON<T: Decodable>(_ type: T.Type, from urlString: String) async -> T? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, _) = try? await ScoreViewModel.noCacheSession.data(from: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// One-time extras: the core competition (court, result note, athlete
    /// ids + seeds), then each singles player's bio and career stats.
    private func loadExtras() async {
        guard let path = game.tennisPath else { return }
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let base = "https://sports.core.api.espn.com/v2/sports/tennis"
        let compURL = "\(base)/leagues/\(parts[0])/events/\(parts[1])/competitions/\(game.id)?lang=en&region=us"
        guard let comp = await Self.fetchJSON(TCoreCompetition.self, from: compURL) else { return }

        court = comp.court?.description
        venueCity = comp.venue?.address?.summary
        if game.status.type.state == "post" {
            resultNote = comp.notes?.first?.text
        }

        // Bios only make sense for singles — doubles "competitors" are
        // pairs with combined ids the athlete endpoint doesn't serve.
        guard game.homeCompetitor?.athlete != nil else { return }
        let homeCore = comp.competitors?.first { $0.order == 1 }
        let awayCore = comp.competitors?.first { $0.order == 2 }
        async let home = Self.loadBio(base: base, competitor: homeCore)
        async let away = Self.loadBio(base: base, competitor: awayCore)
        let (homeLoaded, awayLoaded) = await (home, away)
        if !Task.isCancelled {
            homeBio = homeLoaded
            awayBio = awayLoaded
        }
    }

    private nonisolated static func loadBio(base: String, competitor: TCoreCompetitor?) async -> TennisPlayerBio? {
        guard let id = competitor?.id else { return nil }
        var bio = TennisPlayerBio(seed: competitor?.tournamentSeed)
        if let athlete = await fetchJSON(TCoreAthlete.self, from: "\(base)/athletes/\(id)?lang=en&region=us") {
            bio.age = athlete.age.map(String.init)
            bio.height = athlete.displayHeight
            bio.hand = athlete.hand?.displayValue
            bio.birthplace = athlete.birthPlace?.summary
        }
        if let stats = await fetchJSON(TCoreStatistics.self, from: "\(base)/athletes/\(id)/statistics?lang=en&region=us") {
            let all = (stats.splits?.categories ?? []).flatMap { $0.stats ?? [] }
            func stat(_ name: String) -> TCoreStat? { all.first { $0.name == name } }
            if let won = stat("singlesWon")?.displayValue, let lost = stat("singlesLost")?.displayValue {
                bio.singlesRecord = "\(won)–\(lost)"
            }
            bio.titles = stat("singlesTitles")?.displayValue
            if let prize = stat("prize")?.value, prize > 0 {
                bio.prize = "$" + Int(prize).formatted()
            }
        }
        return bio.hasAnything || bio.seed != nil ? bio : nil
    }
}

// MARK: - Detail page

/// Tennis match detail page — same card language as the team-sport detail
/// page (dark glass cards on soft glows), tailored to what tennis actually
/// has: set-by-set line score with tiebreaks, serving indicator, result
/// note, player comparison, and match info.
struct TennisDetailContentView: View {
    let request: GameDetailRequest
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color

    @StateObject private var detail: TennisDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var collapseProgress = ScrollProgress()

    init(request: GameDetailRequest, viewModel: ChannelViewModel, accentColor: Color) {
        self.request = request
        self.viewModel = viewModel
        self.accentColor = accentColor
        _detail = StateObject(wrappedValue: TennisDetailViewModel(game: request.game))
    }

    private var isLive: Bool { detail.game.status.type.state == "in" }

    var body: some View {
        ZStack {
            backgroundLayer

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    headerCard
                    watchButton
                    if detail.game.status.type.state != "pre" {
                        lineScoreSection
                    }
                    if let note = detail.resultNote, !note.isEmpty {
                        resultSection(note)
                    }
                    if detail.homeBio != nil || detail.awayBio != nil {
                        comparisonSection
                    }
                    matchInfoSection
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

    /// Pinned bar once the big header scrolls away: flags + set score (or
    /// start time) with the live status between them.
    private var compactHeader: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: detail.awaySide?.athlete?.flag?.href ?? (detail.awaySide?.roster?.athletes?.first?.flag?.href ?? ""), size: CGSize(width: 26, height: 26))
                .frame(width: 26, height: 26)
            if detail.game.status.type.state == "pre" {
                Spacer()
                Text(startTimeText)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
            } else {
                Text(detail.awaySide?.score ?? "0")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Text(detail.game.status.type.detail)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isLive ? .red : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Text(detail.homeSide?.score ?? "0")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
            }
            CachedAsyncImage(urlString: detail.homeSide?.athlete?.flag?.href ?? (detail.homeSide?.roster?.athletes?.first?.flag?.href ?? ""), size: CGSize(width: 26, height: 26))
                .frame(width: 26, height: 26)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial.opacity(0.6), ignoresSafeAreaEdges: .top)
    }

    // MARK: Background

    private var backgroundLayer: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.08).ignoresSafeArea()
            // Grass-and-night wash — tennis has no team colors to pull from.
            LinearGradient(
                colors: [Color(red: 0.15, green: 0.5, blue: 0.28).opacity(0.55), .clear],
                startPoint: .topLeading,
                endPoint: UnitPoint(x: 0.65, y: 0.75)
            )
            LinearGradient(
                colors: [accentColor.opacity(0.4), .clear],
                startPoint: .topTrailing,
                endPoint: UnitPoint(x: 0.35, y: 0.75)
            )
        }
        .ignoresSafeArea()
    }

    // MARK: Header

    private var headerCard: some View {
        VStack(spacing: 10) {
            if let tournament = detail.tournamentName {
                Text(tournament.uppercased())
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            HStack(alignment: .top, spacing: 12) {
                playerColumn(detail.awaySide, bio: detail.awayBio)
                VStack(spacing: 6) {
                    if detail.game.status.type.state == "pre" {
                        Text(startTimeText)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                    } else {
                        Text("\(detail.awaySide?.score ?? "0") \(Text("–").foregroundStyle(.secondary)) \(detail.homeSide?.score ?? "0")")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text("SETS")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(.tertiary)
                    }
                    Text(statusLine)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isLive ? .red : .secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(minWidth: 100)
                .layoutPriority(1)
                playerColumn(detail.homeSide, bio: detail.homeBio)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private var statusLine: String {
        var line = detail.game.status.type.detail
        if let round = detail.game.tennisRound {
            line = detail.game.status.type.state == "pre" ? round : "\(line) · \(round)"
        }
        return line
    }

    private var startTimeText: String {
        let date = detail.game.gameDate
        guard date != .distantFuture else { return "—" }
        if detail.game.status.type.detail.contains("TBD") { return "TBD" }
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df.string(from: date)
    }

    private func playerColumn(_ competitor: ESPNCompetitor?, bio: TennisPlayerBio?) -> some View {
        let pairFlags = (competitor?.roster?.athletes ?? []).compactMap { $0.flag?.href }
        return VStack(spacing: 6) {
            if pairFlags.count >= 2 {
                HStack(spacing: 4) {
                    ForEach(pairFlags.prefix(2), id: \.self) { flag in
                        CachedAsyncImage(urlString: flag, size: CGSize(width: 30, height: 30))
                            .frame(width: 30, height: 30)
                    }
                }
                .frame(height: 52)
            } else {
                CachedAsyncImage(urlString: competitor?.athlete?.flag?.href ?? "", size: CGSize(width: 52, height: 52))
                    .frame(width: 52, height: 52)
            }
            HStack(spacing: 4) {
                Text(TennisFeed.sideName(competitor))
                    .font(.system(size: 14, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                if isLive && competitor?.possession == true {
                    Circle()
                        .fill(Color(red: 0.78, green: 0.92, blue: 0.25))
                        .frame(width: 7, height: 7)
                }
            }
            if let seed = bio?.seed ?? competitor?.curatedRank?.current {
                Text("Seed \(seed)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Watch

    private var watchButton: some View {
        Button {
            let game = detail.game
            let (home, away) = game.searchTerms
            dismiss()
            viewModel.runSmartSearch(
                gameID: game.id,
                home: home,
                away: away,
                sport: .tennis,
                network: game.broadcastName
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text(isLive ? "Watch Live" : "Find Stream")
                if let network = detail.game.broadcastName {
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
    }

    // MARK: Line score

    private var lineScoreSection: some View {
        sectionCard("Line Score") {
            let sets = max(detail.awaySide?.linescores?.count ?? 0, detail.homeSide?.linescores?.count ?? 0)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(0..<max(sets, 1), id: \.self) { i in
                        Text("\(i + 1)")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.tertiary)
                            .frame(width: 34)
                    }
                }
                .frame(height: 20)
                lineScoreRow(detail.awaySide, sets: sets)
                lineScoreRow(detail.homeSide, sets: sets)
            }
        }
    }

    private func lineScoreRow(_ competitor: ESPNCompetitor?, sets: Int) -> some View {
        let lost = detail.game.status.type.state == "post" && competitor?.winner != true
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(TennisFeed.sideName(competitor))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(lost ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if isLive && competitor?.possession == true {
                    Circle()
                        .fill(Color(red: 0.78, green: 0.92, blue: 0.25))
                        .frame(width: 7, height: 7)
                }
                if competitor?.winner == true {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            let lines = competitor?.linescores ?? []
            ForEach(0..<max(sets, 1), id: \.self) { i in
                if i < lines.count {
                    let line = lines[i]
                    let emphasized = line.winner == true || (isLive && i == lines.count - 1)
                    HStack(alignment: .top, spacing: 1) {
                        Text(setText(line))
                            .font(.system(size: 16, weight: emphasized ? .black : .semibold, design: .rounded))
                        if let tiebreak = line.tiebreak {
                            Text("\(tiebreak)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.top, 1)
                        }
                    }
                    .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: 34)
                } else {
                    Text("–")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 34)
                }
            }
        }
        .frame(height: 30)
    }

    private func setText(_ line: ESPNLinescore) -> String {
        guard let value = line.value else { return "–" }
        return String(Int(value))
    }

    // MARK: Result

    private func resultSection(_ note: String) -> some View {
        sectionCard("Result") {
            Text(note)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Player comparison

    private var comparisonSection: some View {
        sectionCard("Players") {
            VStack(spacing: 10) {
                comparisonRow("Age", away: detail.awayBio?.age, home: detail.homeBio?.age)
                comparisonRow("Height", away: detail.awayBio?.height, home: detail.homeBio?.height)
                comparisonRow("Plays", away: detail.awayBio?.hand, home: detail.homeBio?.hand)
                comparisonRow("Career Singles", away: detail.awayBio?.singlesRecord, home: detail.homeBio?.singlesRecord)
                comparisonRow("Career Titles", away: detail.awayBio?.titles, home: detail.homeBio?.titles)
                comparisonRow("Prize Money", away: detail.awayBio?.prize, home: detail.homeBio?.prize)
            }
        }
    }

    @ViewBuilder
    private func comparisonRow(_ label: String, away: String?, home: String?) -> some View {
        if away != nil || home != nil {
            HStack {
                Text(away ?? "–")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity)
                Text(home ?? "–")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: Match info

    private var matchInfoSection: some View {
        sectionCard("Match Info") {
            VStack(alignment: .leading, spacing: 10) {
                if let tournament = detail.tournamentName {
                    infoRow(icon: "trophy", title: tournament, subtitle: detail.drawName)
                }
                if let round = detail.game.tennisRound {
                    infoRow(icon: "list.number", title: "Round", subtitle: round)
                }
                if detail.court != nil || detail.venueCity != nil {
                    infoRow(icon: "building.2", title: detail.court ?? "Venue", subtitle: detail.venueCity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoRow(icon: String, title: String, subtitle: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Section shell

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white.opacity(0.75))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}
