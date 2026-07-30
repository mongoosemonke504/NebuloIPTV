import SwiftUI

/// The page a favourited Formula 1 driver opens.
///
/// The team page can't serve this: a driver has no roster, no table row of their
/// own and no fixture list, and ESPN's team endpoints 404 for racing — which is
/// why tapping a favourited driver used to land on an empty page. This is the
/// same shape (hero, pinned chips, sliding tabs) filled with what a driver
/// actually has: their championship position, the race weekend that's on, and
/// their season round by round.
struct DriverDetailPage: View {
    /// The catalog entry for the driver — `id` is the ESPN athlete id and
    /// `logo` their headshot.
    let driver: ESPNTeam
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    /// Passed through to the race card so an onboard feed can start from here.
    let playAction: (StreamChannel) -> Void
    @Environment(\.dismiss) private var dismiss


    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case season = "Season"
        case standings = "Standings"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .overview
    @State private var season: F1DetailService.Season?
    @State private var loading = true

    @State private var heroPull = ScrollProgress()
    @State private var heroScroll = ScrollProgress()
    @State private var titleProgress = ScrollProgress()

    @State private var scrollLock = FlagBox()
    @State private var swipeConsumed = false
    @State private var isSliding = false
    @State private var slideFromTrailing = true
    @State private var chipBarFrame: CGRect = .zero

    /// Points of scroll the header collapse runs over — see the team page.
    private static let handoverSpan: CGFloat = 90

    private var heroHeight: CGFloat { UIScreen.main.bounds.height * 0.47 }

    private var pinnedInset: CGFloat {
        let top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets.top ?? 0
        return top + 44
    }

    // MARK: Derived

    private var name: String { driver.displayName ?? driver.shortDisplayName ?? "Driver" }

    private var standing: F1DetailService.DriverStanding? {
        season?.standings.first { $0.id == driver.id }
    }

    private var rounds: [F1DetailService.Round] { season?.rounds[driver.id] ?? [] }

    /// Rounds already run, most recent first — a driver's results so far.
    private var completedRounds: [F1DetailService.Round] {
        rounds.filter(\.hasRun).reversed()
    }

    private var upcomingRounds: [F1DetailService.Round] {
        rounds.filter { !$0.hasRun }
    }

    /// The race weekend this driver is entered in, from the scoreboard pool.
    private var raceWeekend: ESPNEvent? {
        scoreViewModel.liveOrNextGame(
            forTeamID: ScoreViewModel.teamKey(sport: .f1, teamID: driver.id)
        )
    }

    private var metadataParts: [String] {
        var parts = ["Formula 1"]
        if let rank = standing?.rank { parts.append("P\(rank)") }
        if let points = standing?.points { parts.append("\(points) pts") }
        return parts
    }

    private var availableTabs: [Tab] {
        Tab.allCases.filter { t in
            switch t {
            case .overview:  return true
            case .season:    return !rounds.isEmpty
            case .standings: return !(season?.standings.isEmpty ?? true)
            }
        }
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            AppBackground().ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    hero
                        .modifier(HeroStretch(pull: heroPull, height: heroHeight))
                        .padding(.bottom, -pinnedInset)

                    ScrollOffsetProbe(space: "driverScroll", id: "driver")

                    Section(header: pinnedChipHeader) {
                        ZStack(alignment: .top) {
                            Group {
                                switch tab {
                                case .overview:  overviewTab
                                case .season:    seasonTab
                                case .standings: standingsTab
                                }
                            }
                            .id(tab)
                            .transition(.asymmetric(
                                insertion: .move(edge: slideFromTrailing ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: slideFromTrailing ? .leading : .trailing).combined(with: .opacity)
                            ))
                        }
                        .padding(.top, 12)

                        if loading && season == nil {
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
            }
            .ignoresSafeArea(.container, edges: .top)
            .coordinateSpace(name: "driverScroll")
            .scrollLocked(scrollLock)
            .onPreferenceChange(SectionScrollOffsetsKey.self) { offsets in
                guard let y = offsets["driver"] else { return }
                let span = Self.handoverSpan
                titleProgress.set(min(max((span - y) / span, 0), 1))
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, scrolled in
                heroPull.set(max(0, -scrolled))
                heroScroll.set(min(max(0, scrolled), heroHeight))
            }
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

            HStack(spacing: 10) {
                NuvioCircleButton(systemName: "chevron.left") {
                    viewModel.triggerSelectionHaptic()
                    dismiss()
                }
                Spacer(minLength: 0)
                Text(name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .scrollProgressOpacity(titleProgress) { Double(max(($0 - 0.55) / 0.45, 0)) }
                Spacer(minLength: 0)
                Color.clear.frame(width: 38, height: 38)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .preferredColorScheme(.dark)
        .onAppear { scrollLock.set(false) }
        .task(id: driver.id) {
            loading = true
            season = await F1DetailService.fetchSeason()
            loading = false
        }
        .onChange(of: availableTabs.map(\.rawValue)) { _, tabs in
            if !tabs.contains(tab.rawValue) { tab = .overview }
        }
    }

    // MARK: Hero

    private var hero: some View {
        ZStack {
            ZStack {
                // Racing has no club colour, so the field is the app's charcoal
                // with a pool of light behind the headshot — the same treatment
                // the league pages use for a competition crest.
                Color(white: 0.13)
                RadialGradient(
                    colors: [Color.white.opacity(0.12), .clear],
                    center: UnitPoint(x: 0.5, y: 0.38),
                    startRadius: 0,
                    endRadius: 230
                )
                CachedAsyncImage(urlString: driver.logo ?? "", size: nil)
                    .frame(maxWidth: 168, maxHeight: 168)
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
                VStack(spacing: 11) {
                    HStack(spacing: 10) {
                        if let flag = standing?.flag, !flag.isEmpty {
                            CachedAsyncImage(urlString: flag,
                                             size: CGSize(width: 26, height: 26),
                                             decodeSize: CGSize(width: 78, height: 78))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Text(name)
                            .font(.system(size: 30, weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 2)
                    }
                    .padding(.horizontal, 24)

                    NuvioMetadataLine(parts: metadataParts)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)

                if let race = raceWeekend, race.status.type.state == "in" {
                    Spacer().frame(height: 16)
                    NuvioPillButton(title: "Watch") {
                        guard SwipeTapGuard.tapsAllowed else { return }
                        viewModel.triggerSelectionHaptic()
                        watch(race)
                    }
                }
            }
            .padding(.bottom, 30)
            // Sequential handover to the compact name in the chrome row — see
            // the team page for why the two fades must not overlap.
            .scrollProgressOpacity(titleProgress) { 1 - Double(min($0 / 0.5, 1)) }
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    // MARK: Chips

    private var pinnedChipHeader: some View {
        HStack(spacing: 6) {
            ForEach(availableTabs) { t in
                Button(action: {
                    guard SwipeTapGuard.tapsAllowed else { return }
                    viewModel.triggerSelectionHaptic()
                    selectTab(t)
                }) {
                    Text(t.rawValue)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tab == t ? .black : .white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(tab == t ? Color.white : Color(white: 0.15)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.top, pinnedInset)
        .captureGlobalFrame { chipBarFrame = $0 }
        .background(alignment: .top) {
            // Soft top edge while the scrim is still mid-screen — see the team
            // page.
            CompactHeaderScrim(height: pinnedInset + 120,
                               fadeStart: 0.55,
                               topFade: Self.handoverSpan)
                .scrollProgressOpacity(titleProgress) { Double($0 * $0) }
        }
    }

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

    private func advanceTab(_ delta: Int) {
        let tabs = availableTabs
        guard let index = tabs.firstIndex(of: tab) else { return }
        let next = index + delta
        guard tabs.indices.contains(next) else { return }
        selectTab(tabs[next])
    }

    // MARK: Overview

    @ViewBuilder
    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let race = raceWeekend {
                section(race.status.type.state == "in" ? "Ongoing" : "Race Weekend") {
                    weekendCard(race)
                }
            }

            if standing != nil {
                section("Championship") { championshipCard }
            }

            if !completedRounds.isEmpty {
                section("Recent Rounds") {
                    roundList(Array(completedRounds.prefix(5)))
                }
            }

            if !loading && season == nil {
                emptyNote("No Formula 1 data available right now")
            }
        }
    }

    /// The weekend card: circuit, the session that's next or running, and this
    /// driver's placing in the last session that has a result.
    private func weekendCard(_ race: ESPNEvent) -> some View {
        let session = race.currentRaceSession
        let finished = race.latestFinishedRaceSession
        // Named apart from `placing(in:)` — a local of the same name shadows
        // the method and the closure stops type-checking.
        let placingText: String? = finished.flatMap { placing(in: $0) }
        return Button(action: {
            guard SwipeTapGuard.tapsAllowed else { return }
            viewModel.triggerSelectionHaptic()
            // Closes this page and opens the weekend's game card — the same
            // card the hub and the home shelves open.
            dismiss()
            scoreViewModel.presentRaceCard(race)
        }) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(race.shortName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let circuit = race.circuit?.summary {
                        Text(circuit)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }

                if let session {
                    HStack(spacing: 7) {
                        Text(ScoreRow.sessionName(session.label).uppercased())
                            .font(.system(size: 10, weight: .black))
                            .kerning(0.4)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                        Text(session.detail)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(session.state == "in" ? .red : .white.opacity(0.65))
                            .lineLimit(1)
                    }
                }

                if let placingText, let finished {
                    HStack(spacing: 8) {
                        Text(placingText)
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(.white)
                        Text("in \(ScoreRow.sessionName(finished.label))")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(NuvioTheme.card)
            )
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
    }

    /// "P3" — where this driver came in a session, matched by name because the
    /// scoreboard identifies drivers by athlete name, not id.
    private func placing(in session: ESPNEvent.RaceSession) -> String? {
        let wanted = name.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        guard !wanted.isEmpty else { return nil }
        let index = session.order.firstIndex { competitor in
            let other = (competitor.athlete?.displayName ?? competitor.athlete?.fullName ?? "")
                .folding(options: .diacriticInsensitive, locale: nil).lowercased()
            guard !other.isEmpty else { return false }
            return other == wanted || other.hasSuffix(wanted) || wanted.hasSuffix(other)
        }
        guard let index else { return nil }
        return "P\(index + 1)"
    }

    private var championshipCard: some View {
        HStack(spacing: 0) {
            statCell("Position", standing?.rank.map { "P\($0)" } ?? "–")
            divider
            statCell("Points", standing?.points ?? "–")
            divider
            statCell("Rounds", "\(completedRounds.count)/\(rounds.count)")
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(NuvioTheme.card)
        )
        .padding(.horizontal, 20)
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .black))
                .kerning(0.5)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 0.5, height: 34)
    }

    // MARK: Season

    @ViewBuilder
    private var seasonTab: some View {
        VStack(alignment: .leading, spacing: 26) {
            if !completedRounds.isEmpty {
                section("Results") { roundList(completedRounds) }
            }
            if !upcomingRounds.isEmpty {
                section("Remaining Rounds") { roundList(upcomingRounds) }
            }
        }
    }

    private func roundList(_ list: [F1DetailService.Round]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, round in
                HStack(spacing: 12) {
                    Text(round.code)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 38, alignment: .leading)
                    Text(round.grandPrix)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(round.hasRun ? 0.9 : 0.55))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if round.hasRun {
                        Text(round.points.map { "\($0) pts" } ?? "No points")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(round.points == nil ? .white.opacity(0.45) : .white)
                            .monospacedDigit()
                    } else {
                        Text("Upcoming")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                if index < list.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 0.5)
                        .padding(.leading, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(NuvioTheme.card)
        )
        .padding(.horizontal, 20)
    }

    // MARK: Standings

    @ViewBuilder
    private var standingsTab: some View {
        if let standings = season?.standings, !standings.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("#").frame(width: 22, alignment: .leading)
                    Text("Driver").frame(maxWidth: .infinity, alignment: .leading)
                    Text("PTS").frame(width: 44, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                ForEach(Array(standings.enumerated()), id: \.element.id) { index, row in
                    let isMe = row.id == driver.id
                    HStack(spacing: 10) {
                        Text(row.rank.map(String.init) ?? String(index + 1))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 22, alignment: .leading)
                        HStack(spacing: 8) {
                            if let flag = row.flag, !flag.isEmpty {
                                CachedAsyncImage(urlString: flag,
                                                 size: CGSize(width: 18, height: 18),
                                                 decodeSize: CGSize(width: 54, height: 54))
                                    .clipShape(RoundedRectangle(cornerRadius: 2))
                            }
                            Text(row.name)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.points ?? "–")
                            .foregroundStyle(.white)
                            .fontWeight(.bold)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(.system(size: 13, weight: isMe ? .bold : .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(isMe ? Color.white.opacity(0.07) : Color.clear)
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
            emptyNote("No standings available")
        }
    }

    // MARK: Shared

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            NuvioSectionHeader(title: title, inset: 20)
            content()
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
    }

    /// Racing has no game-card page, so the weekend goes straight to the
    /// channel-matching search the hub uses.
    private func watch(_ race: ESPNEvent) {
        let (home, away) = race.searchTerms
        dismiss()
        viewModel.runSmartSearch(gameID: race.id, home: home, away: away,
                                 sport: .f1, network: race.broadcastName)
    }
}
