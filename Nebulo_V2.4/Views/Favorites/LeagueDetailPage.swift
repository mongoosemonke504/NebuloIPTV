import SwiftUI

// MARK: - Shared standings pieces

/// Which stat columns a table shows. Football and the US leagues keep score in
/// completely different currencies, and forcing one column set on both is what
/// made the MLB table nonsense: every rank was "–", every D was 0, and "PTS"
/// was showing games-behind to one decimal place.
///
/// So there are two sets, chosen by a stat only the US leagues report —
/// `gamesBehind`. Football gets PL/W/D/L/GD/PTS; baseball, basketball, hockey
/// and football(US) get W/L/PCT/GB. Within a set, a column still drops out if
/// the league didn't supply it at all.
enum StandingsColumns {
    struct Column: Identifiable {
        let id: String
        let header: String
        let width: CGFloat
        let value: (LeagueDetailService.StandingRow) -> String
    }

    private static let soccer: [Column] = [
        Column(id: "PL",  header: "PL",  width: 28) { $0.played },
        Column(id: "W",   header: "W",   width: 24) { $0.wins },
        Column(id: "D",   header: "D",   width: 24) { $0.draws },
        Column(id: "L",   header: "L",   width: 24) { $0.losses },
        Column(id: "GD",  header: "GD",  width: 34) { $0.goalDiff },
        Column(id: "PTS", header: "PTS", width: 34) { $0.points }
    ]

    private static let american: [Column] = [
        Column(id: "W",    header: "W",   width: 30) { $0.wins },
        Column(id: "L",    header: "L",   width: 30) { $0.losses },
        Column(id: "PCT",  header: "PCT", width: 42) { $0.winPercent },
        Column(id: "DIFF", header: "DIFF", width: 42) { $0.goalDiff },
        Column(id: "GB",   header: "GB",  width: 36) { $0.gamesBehind }
    ]

    static func available(in rows: [LeagueDetailService.StandingRow]) -> [Column] {
        let isAmerican = rows.contains { $0.gamesBehind != "–" }
        let set = isAmerican ? american : soccer
        return set.filter { col in rows.contains { col.value($0) != "–" } }
    }
}

/// The grey column-header strip above a table.
struct StandingsHeaderRow: View {
    let columns: [StandingsColumns.Column]

    var body: some View {
        HStack(spacing: 6) {
            Text("#").frame(width: 22, alignment: .leading)
            Text("Team").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { col in
                Text(col.header)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: col.width, alignment: .trailing)
            }
        }
        .font(.system(size: 10, weight: .black))
        .foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// One table row. `isHighlighted` is the team you came in for, which the
/// reference app tints so you can find yourself at a glance.
struct StandingsRowView: View {
    let row: LeagueDetailService.StandingRow
    let columns: [StandingsColumns.Column]
    var isHighlighted: Bool = false
    /// Position to print when ESPN gives no `rank` stat — MLB doesn't, which
    /// is why every row in the baseball table read "–". The rows arrive
    /// pre-sorted, so their index IS the standing.
    var fallbackRank: Int? = nil

    private var zoneColor: Color? {
        guard let hex = row.noteColor, !hex.isEmpty else { return nil }
        return Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)")
    }

    private var rankText: String {
        if row.rank != "–", !row.rank.isEmpty { return row.rank }
        if let fallbackRank { return String(fallbackRank) }
        return "–"
    }

    /// The emphasised column: points in football, win percentage in the US.
    private var leadColumn: String { columns.contains { $0.id == "PTS" } ? "PTS" : "PCT" }

    var body: some View {
        HStack(spacing: 6) {
            Text(rankText)
                .frame(width: 22, alignment: .leading)
                .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 8) {
                CachedAsyncImage(urlString: row.team.logo ?? "", size: CGSize(width: 20, height: 20))
                    .frame(width: 20, height: 20)
                Text(row.team.shortDisplayName ?? row.team.displayName ?? "—")
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { col in
                Text(col.value(row))
                    .foregroundStyle(col.id == leadColumn ? .white : .white.opacity(0.75))
                    .fontWeight(col.id == leadColumn ? .bold : .regular)
                    .monospacedDigit()
                    // MLB plays 100+ games, so a fixed narrow cell wrapped
                    // "103" onto two lines. Never wrap a stat.
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: col.width, alignment: .trailing)
            }
        }
        .font(.system(size: 13, weight: isHighlighted ? .bold : .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isHighlighted ? Color.white.opacity(0.07) : Color.clear)
        // The qualification zone bar ESPN colours: promotion, continental
        // places, relegation.
        .overlay(alignment: .leading) {
            if let zoneColor {
                Rectangle()
                    .fill(zoneColor)
                    .frame(width: 3)
            }
        }
    }
}

/// A whole standings group as one card.
struct StandingsBoard: View {
    let group: LeagueDetailService.StandingsGroup
    var highlightTeamID: String? = nil

    var body: some View {
        let columns = StandingsColumns.available(in: group.rows)
        VStack(spacing: 0) {
            StandingsHeaderRow(columns: columns)
            ForEach(Array(group.rows.enumerated()), id: \.element.id) { idx, row in
                StandingsRowView(
                    row: row,
                    columns: columns,
                    isHighlighted: row.team.id == highlightTeamID,
                    fallbackRank: idx + 1
                )
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(NuvioTheme.card)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 20)
    }
}

/// Key for the coloured zone bars — "Champions League", "Europa League",
/// "Relegation" — built from whatever notes ESPN actually attached.
struct StandingsLegend: View {
    let rows: [LeagueDetailService.StandingRow]

    private var entries: [(color: Color, text: String)] {
        var seen = Set<String>()
        var out: [(Color, String)] = []
        for row in rows {
            guard let hex = row.noteColor, !hex.isEmpty,
                  let text = row.noteText, !text.isEmpty,
                  seen.insert(text).inserted,
                  let c = Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)") else { continue }
            out.append((c, text))
        }
        return out
    }

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(entries, id: \.text) { entry in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(entry.color)
                            .frame(width: 14, height: 14)
                        Text(entry.text)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 22)
        }
    }
}

// MARK: - League page

/// The page a favourited LEAGUE opens: the reference football app's league
/// screen in this app's language — a full-bleed hero carrying the competition
/// crest, then Table / Fixtures / Results as chips, with the standings (zone
/// bars and legend included) and the fixture list grouped by date.
struct LeagueDetailPage: View {
    let sport: SportType
    let leagueLabel: String?
    let displayName: String
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case table = "Table", fixtures = "Fixtures", results = "Results"
        // Series tabs — Formula 1 and golf have a season of one-off events
        // rather than a table and a fixture list. See `isSeries`.
        case schedule = "Schedule", drivers = "Drivers", constructors = "Constructors"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .table
    @State private var standings: [LeagueDetailService.StandingsGroup] = []
    @State private var schedule: [ESPNEvent] = []
    @State private var loading = true
    /// Season calendar + championships, for the series sports only.
    @State private var calendar: [SeriesCalendarService.Entry] = []
    @State private var season: F1DetailService.Season?

    @State private var heroPull = ScrollProgress()
    @State private var heroScroll = ScrollProgress()

    /// Horizontal-swipe plumbing, the same as the team and driver pages.
    @State private var scrollLock = FlagBox()
    @State private var swipeConsumed = false
    @State private var isSliding = false
    @State private var slideFromTrailing = true
    @State private var chipBarFrame: CGRect = .zero

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    private static let dayHeaderFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()

    /// Shallower than the team hero — a crest on a flat field doesn't need the
    /// full 60% of the screen the artwork-backed heroes use.
    private var heroHeight: CGFloat { UIScreen.main.bounds.height * 0.42 }

    private var logo: String? { LeagueLogoURL.url(sport: sport, leagueLabel: leagueLabel) }

    private var liveGames: [ESPNEvent] { schedule.filter { $0.status.type.state == "in" } }

    private var upcoming: [ESPNEvent] {
        schedule.filter { $0.status.type.state == "pre" }.sorted { $0.gameDate < $1.gameDate }
    }

    private var results: [ESPNEvent] {
        schedule.filter { $0.status.type.state == "post" }.sorted { $0.gameDate > $1.gameDate }
    }

    /// Fixtures grouped by calendar day, in the order the reference app lists
    /// them: a day subhead, then that day's matches.
    private func grouped(_ games: [ESPNEvent]) -> [(day: Date, games: [ESPNEvent])] {
        let cal = Calendar.current
        var buckets: [Date: [ESPNEvent]] = [:]
        for g in games {
            let key = cal.startOfDay(for: g.gameDate)
            buckets[key, default: []].append(g)
        }
        return buckets.keys.sorted().map { (day: $0, games: buckets[$0] ?? []) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            AppBackground().ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                        .modifier(HeroStretch(pull: heroPull, height: heroHeight))

                    // Tab chips — the reference's Table / Fixtures / News row,
                    // minus the tabs this app has no feed for.
                    HStack(spacing: 9) {
                        ForEach(availableTabs) { t in
                            Button(action: {
                                guard SwipeTapGuard.tapsAllowed else { return }
                                selectTab(t)
                            }) {
                                Text(t.rawValue)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(tab == t ? .black : .white.opacity(0.85))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                    .background(
                                        Capsule().fill(tab == t ? Color.white : Color(white: 0.15))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20)
                    .captureGlobalFrame { chipBarFrame = $0 }

                    // ZStack so the outgoing and incoming tab overlap during the
                    // directional slide instead of stacking vertically.
                    ZStack(alignment: .top) {
                        Group {
                            switch tab {
                            case .table:   tableTab
                            case .fixtures: fixtureList(upcoming, empty: "No fixtures scheduled")
                            case .results:  fixtureList(results, empty: "No results yet", newestFirst: true)
                            case .schedule: seasonScheduleTab
                            case .drivers: seriesStandingsTab
                            case .constructors: seriesConstructorsTab
                            }
                        }
                        .id(tab)
                        .transition(.asymmetric(
                            insertion: .move(edge: slideFromTrailing ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: slideFromTrailing ? .leading : .trailing).combined(with: .opacity)
                        ))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if loading && standings.isEmpty && schedule.isEmpty {
                        HStack {
                            Spacer()
                            CustomSpinner(color: .white.opacity(0.5), lineWidth: 2, size: 22)
                            Spacer()
                        }
                        .padding(.vertical, 30)
                    }

                    Color.clear.frame(height: 60)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            // Frozen for the duration of a horizontal swipe, so a sideways
            // gesture travels purely sideways.
            .scrollLocked(scrollLock)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, scrolled in
                heroPull.set(max(0, -scrolled))
                heroScroll.set(min(max(0, scrolled), heroHeight))
            }
            // Sideways swipe turns the page, the same gesture the team, driver
            // and Sports pages use. Drags starting on the chip row are left
            // alone, and the left screen edge stays reserved for back
            // navigation.
            .simultaneousGesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .onChanged { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        if abs(dx) > abs(dy) * 1.4 { SwipeTapGuard.suppress() }
                        if value.startLocation.x > 44, !chipBarFrame.contains(value.startLocation) {
                            if abs(dx) > abs(dy) * 1.4 {
                                scrollLock.set(true)
                            } else if !swipeConsumed, abs(dy) > abs(dx) * 1.4 {
                                // A drag that turns decisively vertical releases
                                // the lock, so this can never strand the page.
                                scrollLock.set(false)
                            }
                        }
                        guard !swipeConsumed, !isSliding,
                              value.startLocation.x > 44,
                              !chipBarFrame.contains(value.startLocation),
                              abs(dx) > 38, abs(dx) > abs(dy) * 1.4 else { return }
                        swipeConsumed = true
                        advanceTab(dx < 0 ? 1 : -1)
                    }
                    .onEnded { _ in
                        swipeConsumed = false
                        scrollLock.set(false)
                    }
            )

            HStack {
                NuvioCircleButton(systemName: "chevron.left") {
                    viewModel.triggerSelectionHaptic()
                    dismiss()
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // No swipe can be in flight on arrival, so never inherit a frozen
            // scroll from a gesture cancelled on the way out.
            scrollLock.set(false)
        }
        .task(id: "\(sport.rawValue)|\(leagueLabel ?? "")") {
            loading = true
            async let s = LeagueDetailService.fetchStandings(sport: sport, leagueLabel: leagueLabel)
            async let f = LeagueDetailService.fetchSchedule(sport: sport, leagueLabel: leagueLabel)
            standings = await s
            schedule = await f

            if isSeries {
                // The season calendar, plus the championships F1 keeps. Golf
                // publishes no standings, so it gets the schedule alone.
                async let c = SeriesCalendarService.fetch(sport: sport)
                async let season: F1DetailService.Season? = sport == .f1
                    ? await F1DetailService.fetchSeason() : nil
                calendar = await c
                self.season = await season
                tab = .schedule
                loading = false
                return
            }

            loading = false
            // Nothing to show a table for — open on the fixtures instead of a
            // blank tab.
            if standings.isEmpty { tab = .fixtures }
        }
    }

    // MARK: Tab switching

    /// Switches tab with the app's directional slide — the chips and the swipe
    /// both come through here so a tap and a swipe animate identically.
    private func selectTab(_ newTab: Tab) {
        guard newTab != tab, !isSliding else { return }
        let tabs = availableTabs
        let oldIndex = tabs.firstIndex(of: tab) ?? 0
        let newIndex = tabs.firstIndex(of: newTab) ?? 0
        slideFromTrailing = newIndex > oldIndex
        isSliding = true
        withAnimation(.easeOut(duration: 0.25)) { tab = newTab }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isSliding = false }
    }

    /// Steps to the previous/next chip — what the sideways swipe drives. No
    /// haptic: a buzz on every page swipe breaks the feel.
    private func advanceTab(_ delta: Int) {
        let tabs = availableTabs
        guard let index = tabs.firstIndex(of: tab) else { return }
        let next = index + delta
        guard tabs.indices.contains(next) else { return }
        selectTab(tabs[next])
    }

    // MARK: Hero

    private var hero: some View {
        ZStack {
            ZStack {
                // Leagues have no brand colour, so the field is the app's own
                // charcoal with the crest's glow pooling behind it.
                Color(white: 0.13)
                RadialGradient(
                    colors: [Color.white.opacity(0.10), .clear],
                    center: UnitPoint(x: 0.5, y: 0.40),
                    startRadius: 0,
                    endRadius: 240
                )
                CachedAsyncImage(urlString: logo ?? "", size: nil)
                    .frame(maxWidth: 128, maxHeight: 128)
                    .offset(y: -heroHeight * 0.10)
                    .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 5)
            }
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
            .modifier(HeroScrollParallax(scroll: heroScroll, baseScale: 1.14))

            // One continuous ramp to black — see the team page for why the old
            // clear-then-dive stops left a line and a flat black band.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: .black.opacity(0.05), location: 0.30),
                    .init(color: .black.opacity(0.30), location: 0.55),
                    .init(color: .black.opacity(0.62), location: 0.75),
                    .init(color: .black.opacity(0.86), location: 0.90),
                    .init(color: .black, location: 1.00)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 13) {
                    Text(displayName)
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 28)
                        .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 2)

                    NuvioMetadataLine(parts: metadataParts)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 30)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var metadataParts: [String] {
        var parts: [String] = [sport.rawValue]
        if !liveGames.isEmpty { parts.append("\(liveGames.count) live") }
        if let group = standings.first, !group.rows.isEmpty { parts.append("\(group.rows.count) teams") }
        return parts
    }

    // MARK: Series (Formula 1, golf)

    /// One event at a time over a season, with no table and no fixture list —
    /// so this page shows the season instead: the calendar, and the
    /// championships where the series keeps one.
    private var isSeries: Bool { sport == .f1 || sport == .golf }

    private var availableTabs: [Tab] {
        guard isSeries else { return [.table, .fixtures, .results] }
        var tabs: [Tab] = [.schedule]
        if !(season?.standings.isEmpty ?? true) { tabs.append(.drivers) }
        if !(season?.constructors.isEmpty ?? true) { tabs.append(.constructors) }
        return tabs
    }

    private static let seriesDayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    /// The whole season: every Grand Prix or tour stop, with the one that's on
    /// marked live and everything already run dimmed.
    @ViewBuilder
    private var seasonScheduleTab: some View {
        if calendar.isEmpty {
            emptyNote("No schedule published yet")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(calendar.enumerated()), id: \.element.id) { index, entry in
                    let current = entry.isCurrent()
                    let past = entry.isPast()
                    Button(action: {
                        guard SwipeTapGuard.tapsAllowed else { return }
                        // Only the event ESPN is currently serving has a card
                        // behind it; the rest of the calendar is reference.
                        guard let game = scheduleEvent(for: entry.id) else { return }
                        viewModel.triggerSelectionHaptic()
                        dismiss()
                        if sport == .f1 {
                            scoreViewModel.presentRaceCard(game)
                        } else {
                            scoreViewModel.presentGolfCard(game)
                        }
                    }) {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(.white.opacity(0.4))
                                .monospacedDigit()
                                .frame(width: 22, alignment: .leading)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.label)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white.opacity(past && !current ? 0.6 : 1))
                                    .lineLimit(1)
                                if current {
                                    HStack(spacing: 5) {
                                        Circle().fill(Color.red).frame(width: 6, height: 6)
                                        Text("This week")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(.red)
                                    }
                                }
                            }

                            Spacer(minLength: 8)

                            Text(dateRange(entry))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)

                            if scheduleEvent(for: entry.id) != nil {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(current ? Color.white.opacity(0.07) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < calendar.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 0.5)
                            .padding(.leading, 14)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(NuvioTheme.card)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 20)
        }
    }

    private func dateRange(_ entry: SeriesCalendarService.Entry) -> String {
        guard let start = entry.start else { return "" }
        let startText = Self.seriesDayFmt.string(from: start)
        guard let end = entry.end,
              !Calendar.current.isDate(start, inSameDayAs: end) else { return startText }
        return "\(startText) – \(Self.seriesDayFmt.string(from: end))"
    }

    /// The calendar row's event, when it's one the scoreboard is serving.
    private func scheduleEvent(for id: String) -> ESPNEvent? {
        schedule.first { $0.id == id }
    }

    @ViewBuilder
    private var seriesStandingsTab: some View {
        if let drivers = season?.standings, !drivers.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(drivers.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 10) {
                        Text(row.rank.map(String.init) ?? String(index + 1))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 24, alignment: .leading)
                        if let flag = row.flag, !flag.isEmpty {
                            CachedAsyncImage(urlString: flag,
                                             size: CGSize(width: 20, height: 20),
                                             decodeSize: CGSize(width: 60, height: 60))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                        Text(row.name)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.points ?? "–")
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if index < drivers.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 0.5)
                            .padding(.leading, 14)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(NuvioTheme.card)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 20)
        } else {
            emptyNote("No championship standings yet")
        }
    }

    @ViewBuilder
    private var seriesConstructorsTab: some View {
        if let teams = season?.constructors, !teams.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(teams.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 10) {
                        Text(row.rank.map(String.init) ?? String(index + 1))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 24, alignment: .leading)
                        Text(row.name)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.points ?? "–")
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .overlay(alignment: .leading) {
                        if let hex = row.color,
                           let color = Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)") {
                            Rectangle().fill(color).frame(width: 3)
                        }
                    }
                    if index < teams.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 0.5)
                            .padding(.leading, 14)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(NuvioTheme.card)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 20)
        } else {
            emptyNote("No constructors' championship")
        }
    }

    // MARK: Tabs

    @ViewBuilder
    private var tableTab: some View {
        if standings.isEmpty {
            emptyNote("No table for this competition")
        } else {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(standings) { group in
                    VStack(alignment: .leading, spacing: 14) {
                        // Group tables (a World Cup) each get their own title;
                        // a single league table doesn't need one.
                        if standings.count > 1 {
                            NuvioSectionHeader(title: group.name, inset: 20)
                        }
                        StandingsBoard(group: group)
                    }
                }
                StandingsLegend(rows: standings.flatMap { $0.rows })
            }
        }
    }

    @ViewBuilder
    private func fixtureList(_ games: [ESPNEvent], empty: String, newestFirst: Bool = false) -> some View {
        if games.isEmpty {
            emptyNote(empty)
        } else {
            let days = newestFirst ? grouped(games).reversed().map { $0 } : grouped(games)
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, bucket in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Self.dayHeaderFmt.string(from: bucket.day))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 22)
                        VStack(spacing: 10) {
                            ForEach(bucket.games) { game in
                                Button(action: {
                                    guard SwipeTapGuard.tapsAllowed else { return }
                                    viewModel.triggerSelectionHaptic()
                                    let s = scoreViewModel.sportType(for: game)
                                    scoreViewModel.deepLinkRequest = scoreViewModel.makeDetailRequest(for: game, sport: s)
                                    dismiss()
                                }) {
                                    TeamGameRow(game: game, dateFormatter: Self.dateFmt)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        viewModel.toggleGameRecording(game: game, sport: scoreViewModel.sportType(for: game))
                                    } label: {
                                        let isScheduled = viewModel.scheduledRecording(for: game) != nil
                                        Label(isScheduled ? "Cancel Recording" : "Record",
                                              systemImage: isScheduled ? "stop.circle" : "record.circle")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
    }
}
