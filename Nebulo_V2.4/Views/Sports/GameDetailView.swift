import SwiftUI

/// Sheet-level carousel around the match detail page: each game in the list
/// the user came from (Live Now order for live games, the sport's own
/// scoreboard otherwise) is a full-height card, with the previous/next
/// game's card peeking in from the screen edges — swipe on the header area
/// or the peeking edges to page between games. The list is snapshotted when
/// the sheet opens so score refreshes never shuffle pages mid-swipe.
struct GameDetailView: View {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    let accentColor: Color

    private let pages: [GameDetailRequest]
    @State private var currentID: String?

    @MainActor
    init(request: GameDetailRequest, viewModel: ChannelViewModel, scoreViewModel: ScoreViewModel, accentColor: Color) {
        self.viewModel = viewModel
        self.scoreViewModel = scoreViewModel
        self.accentColor = accentColor
        // A window around the tapped game, not the whole scoreboard — a
        // 100+ page lazy carousel makes the initial scroll-to-page landing
        // unreliable, and nobody swipes farther than this anyway.
        let full = scoreViewModel.detailPagingList(from: request)
        if let index = full.firstIndex(where: { $0.id == request.id }) {
            let lo = max(0, index - 12)
            let hi = min(full.count - 1, index + 12)
            self.pages = Array(full[lo...hi])
        } else {
            self.pages = [request]
        }
        _currentID = State(initialValue: request.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(pages) { page in
                        Group {
                            if page.sport == .tennis {
                                TennisDetailContentView(request: page, viewModel: viewModel, accentColor: accentColor)
                            } else if page.sport == .mma {
                                MMADetailContentView(request: page, viewModel: viewModel, accentColor: accentColor)
                            } else {
                                GameDetailContentView(request: page, viewModel: viewModel, accentColor: accentColor, onPageGame: pageGame)
                            }
                        }
                        .containerRelativeFrame(.horizontal)
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .allowsHitTesting(page.id == currentID)
                        .id(page.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .safeAreaPadding(.horizontal, 24)
            .scrollPosition(id: $currentID)
            .background(Color(red: 0.03, green: 0.03, blue: 0.05).ignoresSafeArea())
            .onAppear {
                // The scrollPosition binding's initial value alone lands on
                // the wrong page in a lazy carousel — anchor it explicitly.
                proxy.scrollTo(currentID, anchor: .center)
            }
            .onChange(of: currentID) { _, _ in
                ChannelViewModel.shared.triggerSelectionHaptic()
            }
            .preferredColorScheme(.dark)
        }
    }

    /// Steps the carousel one game left/right. Fired by the tab pager when
    /// the user swipes past its first/last chip — the overscroll reads as
    /// "next page", so it pages games the same way the header swipe does.
    private func pageGame(_ delta: Int) {
        guard let current = currentID,
              let index = pages.firstIndex(where: { $0.id == current }),
              pages.indices.contains(index + delta) else { return }
        withAnimation(.easeOut(duration: 0.35)) { currentID = pages[index + delta].id }
    }
}

/// Vertical scroll readings the detail page reacts to each frame: the
/// scrolled distance (drives the compact-bar fade) and the deepest valid
/// offset (so a tab switch that shrinks the content can detect a stranded
/// scroll position).
private struct GDScrollMetrics: Equatable {
    let scrolled: CGFloat
    let maxScrolled: CGFloat
}

/// FotMob-style match detail page, split into tabs:
///   • Overview — live situation, momentum ribbon, headline stats, shot map,
///     match events (with a halftime divider), lineups/top performers, H2H,
///     venue.
///   • Stats — the full team-stat list (and player box scores for US sports).
///   • Table — league/tournament standings with both teams highlighted.
/// Sections render only when the summary payload actually carries their
/// data, so the same screen works across every sport the hub shows.
struct GameDetailContentView: View {
    let request: GameDetailRequest
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color
    let onPageGame: (Int) -> Void

    @StateObject private var detail: GameDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var lineupSide = "home"
    @State private var boxSide = "home"
    @State private var scrolledTab: GDTab? = .overview
    /// 0 at rest, 1 once the big header has scrolled past. Tracks the live
    /// scroll offset directly (no withAnimation) so the compact score bar
    /// crossfades in lockstep with the finger — same pattern as the home
    /// header and the player panel collapse. Held in its own object so
    /// scrolling doesn't re-render this whole page each frame.
    @State private var collapseProgress = ScrollProgress()
    /// How far past their natural position the tab chips are being held
    /// (0 while riding with the content, growing as they dock under the
    /// compact bar). Same leaf-only re-render trick as collapseProgress.
    @State private var chipStick = ScrollProgress()
    /// Measured height of each tab's content, so the pager can be framed to
    /// the visible tab and a short tab can't scroll as deep as its tallest
    /// neighbor.
    @State private var tabHeights: [GDTab: CGFloat] = [:]
    /// Measured height of the compact score bar — the dock line for the
    /// sticky chips.
    @State private var barHeight: CGFloat = 64
    @State private var scrollTarget = ScrollPosition(edge: .top)
    /// Per-gesture latch for the edge-overscroll game paging; a box so the
    /// per-frame writes never invalidate the page.
    @State private var edgeFired = ValueBox(false)
    /// True while the vertical scroll is untouched — rubber-band overshoot
    /// while dragging must not be mistaken for a stranded offset.
    @State private var scrollIdle = ValueBox(true)

    private var tab: GDTab { scrolledTab ?? .overview }

    private enum GDTab: String, CaseIterable {
        case overview = "Overview"
        case stats = "Stats"
        case table = "Table"
    }

    init(request: GameDetailRequest, viewModel: ChannelViewModel, accentColor: Color, onPageGame: @escaping (Int) -> Void = { _ in }) {
        self.request = request
        self.viewModel = viewModel
        self.accentColor = accentColor
        self.onPageGame = onPageGame
        _detail = StateObject(wrappedValue: GameDetailViewModel(request: request))
    }

    private var isSoccer: Bool { request.leagueCode != nil || request.sport.isSoccer }

    private var hasBoxScore: Bool {
        !detail.boxGroups(homeAway: "home").isEmpty || !detail.boxGroups(homeAway: "away").isEmpty
    }

    private var availableTabs: [GDTab] {
        var tabs: [GDTab] = [.overview]
        if !detail.allStats.isEmpty || (!isSoccer && hasBoxScore) { tabs.append(.stats) }
        if !detail.standingsGroups.isEmpty { tabs.append(.table) }
        return tabs
    }

    var body: some View {
        ZStack {
            backgroundLayer

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    headerCard

                    watchButton

                    if detail.isLoading && detail.summary == nil {
                        CustomSpinner(color: .white, lineWidth: 4, size: 36)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if detail.failed && detail.summary == nil {
                        EmptyStateView(
                            title: "No Match Data",
                            systemImage: "chart.bar.xaxis",
                            description: "Detailed stats aren't available for this game."
                        )
                        .padding(.top, 40)
                    } else {
                        if availableTabs.count > 1 {
                            // One set of chips, no pinned copy: they scroll
                            // with the content and the offset below holds
                            // them docked under the compact bar once they
                            // reach it — the hub's pin/unpin feel. The outer
                            // container is never offset, so the probe reads
                            // their natural position.
                            // No backing scrim on the chips themselves — the
                            // compact bar's PinnedHeaderGradient reaches down
                            // past the dock line and dims content passing
                            // under them, same as the hub's pinned pills.
                            ZStack(alignment: .top) {
                                tabChips
                                    .padding(.vertical, 6)
                                    .scrollProgressOffset(chipStick)
                            }
                            .background(GlobalOffsetProbe(id: "gdChips"))
                            .zIndex(1)
                        }
                        tabPager
                            .padding(.horizontal, -16)
                            .frame(height: tabHeights[tab], alignment: .top)
                            .clipped()
                            .animation(.easeOut(duration: 0.25), value: tab)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
            .scrollPosition($scrollTarget)
            // Scroll-linked, not threshold + animation: the bar's opacity
            // maps directly onto the offset (fading in over 105→155pt, where
            // the big score header scrolls out) so it moves with the finger
            // and reverses the same way — no spring, no bounce.
            .onScrollGeometryChange(for: GDScrollMetrics.self) { geometry in
                GDScrollMetrics(
                    scrolled: geometry.contentOffset.y + geometry.contentInsets.top,
                    maxScrolled: max(0, geometry.contentSize.height + geometry.contentInsets.top
                        + geometry.contentInsets.bottom - geometry.containerSize.height)
                )
            } action: { _, metrics in
                collapseProgress.set(min(max((metrics.scrolled - 105) / 50, 0), 1))
                // Content got shorter than the current offset (switched to a
                // tab with less content): bring the new tab's bottom to the
                // bottom of the screen instead of leaving empty space. Only
                // while idle — rubber-band overshoot mid-drag settles itself.
                if scrollIdle.value && metrics.scrolled > metrics.maxScrolled + 1 {
                    withAnimation(.easeOut(duration: 0.3)) { scrollTarget.scrollTo(edge: .bottom) }
                }
            }
            .onScrollPhaseChange { _, newPhase in
                scrollIdle.value = newPhase == .idle
            }
            .background(GlobalOffsetProbe(id: "gdContainer"))
            // Overlay, not safeAreaInset: the bar takes no layout space, so
            // nothing jumps when it appears — content just slides under it.
            .overlay(alignment: .top) {
                compactHeader
                    .scrollProgressReveal(collapseProgress)
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .onAppear { barHeight = g.size.height }
                                .onChangeCompat(of: g.size.height) { barHeight = $0 }
                        }
                    )
            }
        }
        .onPreferenceChange(SectionScrollOffsetsKey.self) { offsets in
            guard let containerTop = offsets["gdContainer"], let chipsTop = offsets["gdChips"] else { return }
            chipStick.set(max(0, containerTop + barHeight - chipsTop))
        }
        .preferredColorScheme(.dark)
        .task(id: request.id) {
            await detail.refreshLoop()
        }
    }

    /// Apple Sports-style pinned bar once the big header scrolls away: each
    /// team's score sits beside its logo, the status in the middle (with
    /// the mini base diamond while baseball is live). The tab chips aren't
    /// part of the bar — they're sticky content that docks just beneath it.
    private var compactHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                CachedAsyncImage(urlString: detail.awaySide.logo ?? "", size: CGSize(width: 34, height: 34))
                    .frame(width: 34, height: 34)
                if detail.statusState != "pre" {
                    Text(detail.awaySide.score)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                }
                Spacer()
                VStack(spacing: 1) {
                    HStack(spacing: 6) {
                        Text(detail.statusState == "pre" ? startTimeText : detail.statusDetail)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(detail.statusState == "in" ? .red : .primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if detail.statusState == "in", let situation = detail.baseballSituation {
                            BasesDiamondView(
                                onFirst: situation.onFirst,
                                onSecond: situation.onSecond,
                                onThird: situation.onThird,
                                fillColor: compactBattingColor(situation)
                            )
                            .scaleEffect(0.45)
                            .frame(width: 30, height: 26)
                        }
                    }
                    if let subline = compactStatusSubline {
                        Text(subline)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if detail.statusState != "pre" {
                    Text(detail.homeSide.score)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                }
                CachedAsyncImage(urlString: detail.homeSide.logo ?? "", size: CGSize(width: 34, height: 34))
                    .frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(alignment: .top) { PinnedHeaderGradient() }
    }

    private func compactBattingColor(_ situation: GDBaseballSituation) -> Color {
        switch situation.battingTeamIsHome {
        case true: return detail.homeSide.color
        case false: return detail.awaySide.color
        default: return .white
        }
    }

    /// "Today" / "Yesterday" / "Jul 12" under the compact status — matches
    /// Apple Sports' "Final / Today" stack. Hidden while live (the status
    /// line itself carries the inning/clock).
    private var compactStatusSubline: String? {
        guard detail.statusState != "in" else { return nil }
        let date = request.game.gameDate
        guard date != .distantFuture else { return nil }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: date)
    }

    /// Single path for every tab change: picks the slide direction from the
    /// chip order, fires the haptic, and animates the content push.
    private func switchTab(to newTab: GDTab) {
        guard scrolledTab != newTab else { return }
        ChannelViewModel.shared.triggerSelectionHaptic()
        withAnimation(.easeOut(duration: 0.3)) { scrolledTab = newTab }
    }

    // MARK: Tabs

    private var tabChips: some View {
        HStack(spacing: 8) {
            ForEach(availableTabs, id: \.self) { candidate in
                Button {
                    switchTab(to: candidate)
                } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 13, weight: .bold))
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(tab == candidate ? Color.white : Color.white.opacity(0.08))
                        .foregroundColor(tab == candidate ? .black : .white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
        // The tab change animates the content slide; without this the chip
        // colors crossfade too, and mid-fade the selected chip reads as
        // black-on-black. Killing the animation here makes the white
        // selection snap instantly.
        .transaction { $0.animation = nil }
    }

    private var tabPager: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(availableTabs, id: \.self) { candidate in
                    VStack(spacing: 14) {
                        tabContent(for: candidate)
                    }
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .onAppear { tabHeights[candidate] = g.size.height }
                                .onChangeCompat(of: g.size.height) { tabHeights[candidate] = $0 }
                        }
                    )
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .safeAreaPadding(.horizontal, 16)
        .scrollPosition(id: $scrolledTab)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            let restX = -geometry.contentInsets.leading
            let maxX = max(restX, geometry.contentSize.width - geometry.containerSize.width
                + geometry.contentInsets.trailing)
            if geometry.contentOffset.x < restX { return geometry.contentOffset.x - restX }
            if geometry.contentOffset.x > maxX { return geometry.contentOffset.x - maxX }
            return 0
        } action: { _, overshoot in
            if abs(overshoot) < 4 {
                edgeFired.value = false
            } else if !edgeFired.value {
                if overshoot <= -30 {
                    edgeFired.value = true
                    onPageGame(-1)
                } else if overshoot >= 30 {
                    edgeFired.value = true
                    onPageGame(1)
                }
            }
        }
    }

    @ViewBuilder
    private func tabContent(for candidate: GDTab) -> some View {
        switch candidate {
        case .overview: overviewTab
        case .stats: statsTab
        case .table: tableTab
        }
    }

    @ViewBuilder
    private var overviewTab: some View {
        if let situation = detail.baseballSituation {
            baseballSituationSection(situation)
        }
        if let situation = detail.footballSituation {
            footballSituationSection(situation)
        }
        if let momentum = detail.momentum {
            winProbabilitySection(momentum)
        } else if let momentum = detail.derivedMomentum {
            momentumSection(momentum, caption: "MOMENTUM")
        }
        if detail.possessionBar != nil || !detail.mainStats.isEmpty {
            mainStatsSection
        }
        if isSoccer && !detail.shots.isEmpty {
            shotMapSection
        }
        if !detail.timeline.isEmpty {
            timelineSection
        }
        if isSoccer {
            if detail.lineup(homeAway: "home") != nil || detail.lineup(homeAway: "away") != nil {
                soccerLineupSection
            }
        }
        if !detail.topPerformers.isEmpty {
            performersSection
        }
        h2hSection
        venueSection
    }

    @ViewBuilder
    private var statsTab: some View {
        if !detail.allStats.isEmpty {
            sectionCard("Team Stats") {
                VStack(spacing: 14) {
                    if let possession = detail.possessionBar {
                        possessionView(possession)
                    }
                    ForEach(detail.allStats) { bar in
                        statBarRow(bar)
                    }
                }
            }
        }
        if !isSoccer && hasBoxScore {
            boxScoreSection
        }
    }

    @ViewBuilder
    private var tableTab: some View {
        ForEach(detail.standingsGroups) { group in
            standingsCard(group)
        }
    }

    // MARK: Background

    private var backgroundLayer: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.08).ignoresSafeArea()
            // Strong team-color wash, Apple Sports-style: away team floods
            // in from the top-left, home from the top-right, both fading
            // into the dark base toward the bottom.
            LinearGradient(
                colors: [detail.awaySide.color.opacity(0.65), .clear],
                startPoint: .topLeading,
                endPoint: UnitPoint(x: 0.65, y: 0.75)
            )
            LinearGradient(
                colors: [detail.homeSide.color.opacity(0.55), .clear],
                startPoint: .topTrailing,
                endPoint: UnitPoint(x: 0.35, y: 0.75)
            )
        }
        .ignoresSafeArea()
    }

    // MARK: Header

    private var headerCard: some View {
        VStack(spacing: 10) {
            if let league = detail.leagueName {
                Text(league.uppercased())
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                teamHeaderColumn(detail.awaySide)
                VStack(spacing: 6) {
                    if detail.statusState == "pre" {
                        Text(startTimeText)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                    } else {
                        // One Text so a big basketball score scales down as
                        // a unit instead of wrapping "29" onto two lines.
                        Text("\(detail.awaySide.score) \(Text("–").foregroundStyle(.secondary)) \(detail.homeSide.score)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    Text(detail.statusDetail)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(detail.statusState == "in" ? .red : .secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(minWidth: 100)
                .layoutPriority(1)
                teamHeaderColumn(detail.homeSide)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private var startTimeText: String {
        let date = request.game.gameDate
        guard date != .distantFuture else { return "—" }
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df.string(from: date)
    }

    private func teamHeaderColumn(_ side: GDTeamSide) -> some View {
        VStack(spacing: 6) {
            CachedAsyncImage(urlString: side.logo ?? "", size: CGSize(width: 52, height: 52))
                .frame(width: 52, height: 52)
            Text(side.name)
                .font(.system(size: 14, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            if let record = side.record {
                Text(record)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Watch

    private var watchButton: some View {
        Button {
            let home = detail.homeSide.name
            let away = detail.awaySide.name
            dismiss()
            viewModel.runSmartSearch(
                gameID: request.game.id,
                home: home,
                away: away,
                sport: request.sport,
                network: request.game.broadcastName
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text(detail.statusState == "in" ? "Watch Live" : "Find Stream")
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
    }

    // MARK: Live situation

    /// Live baseball panel: the base diamond, ball–strike count, outs, and
    /// who's at the plate. Between innings it shows the due-up hitters.
    private func baseballSituationSection(_ situation: GDBaseballSituation) -> some View {
        let battingColor: Color = {
            switch situation.battingTeamIsHome {
            case true: return detail.homeSide.color
            case false: return detail.awaySide.color
            default: return .white
            }
        }()
        return sectionCard("Live Situation") {
            VStack(spacing: 12) {
                HStack(alignment: .center) {
                    BasesDiamondView(
                        onFirst: situation.onFirst,
                        onSecond: situation.onSecond,
                        onThird: situation.onThird,
                        fillColor: battingColor
                    )
                    Spacer()
                    VStack(spacing: 4) {
                        Text("\(situation.balls)-\(situation.strikes)")
                            .font(.system(size: 26, weight: .black, design: .rounded))
                        Text("COUNT")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(spacing: 8) {
                        HStack(spacing: 5) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle()
                                    .fill(i < situation.outs ? Color.white : Color.white.opacity(0.15))
                                    .frame(width: 11, height: 11)
                            }
                        }
                        Text("OUTS")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)

                if situation.batter != nil || situation.pitcher != nil {
                    HStack(spacing: 10) {
                        if let batter = situation.batter {
                            situationPlayerChip(role: "AB", name: batter, color: battingColor)
                        }
                        if let pitcher = situation.pitcher {
                            let fieldingColor: Color = situation.battingTeamIsHome == true
                                ? detail.awaySide.color : detail.homeSide.color
                            situationPlayerChip(role: "P", name: pitcher, color: fieldingColor)
                        }
                    }
                } else if !situation.dueUp.isEmpty {
                    HStack(spacing: 6) {
                        Text("DUE UP")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.secondary)
                        Text(situation.dueUp.prefix(3).joined(separator: ", "))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func situationPlayerChip(role: String, name: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Text(role)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 24, height: 18)
                .background(color.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    /// Live football panel: possession team, down & distance, red-zone flag,
    /// and the last play.
    private func footballSituationSection(_ situation: GDFootballSituation) -> some View {
        sectionCard("Live Situation") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if let possessionIsHome = situation.possessionIsHome {
                        let side = possessionIsHome ? detail.homeSide : detail.awaySide
                        CachedAsyncImage(urlString: side.logo ?? "", size: CGSize(width: 24, height: 24))
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "football.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    Text(situation.downDistanceText)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    if situation.isRedZone {
                        Text("RED ZONE")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.red.opacity(0.85))
                            .clipShape(Capsule())
                    }
                }
                if let lastPlay = situation.lastPlayText, !lastPlay.isEmpty {
                    Text(lastPlay)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: Momentum / win probability

    /// ESPN's real per-play win probability: the curve spans the whole game
    /// on the x-axis but only fills up to where the game currently is, with
    /// live percentages in the legend and press-and-hold scrubbing.
    private func winProbabilitySection(_ points: [Double]) -> some View {
        let last = points.last ?? 0.5
        return sectionCard("Win Probability") {
            VStack(spacing: 8) {
                MomentumChart(
                    points: points,
                    homeColor: detail.homeSide.color,
                    awayColor: detail.awaySide.color,
                    progress: detail.gameProgress,
                    homeAbbrev: detail.homeSide.abbreviation,
                    awayAbbrev: detail.awaySide.abbreviation,
                    interactive: true
                )
                .frame(height: 110)
                HStack {
                    momentumLegend(detail.awaySide, percent: 100 - Int((last * 100).rounded()))
                    Spacer()
                    Text(detail.statusState == "in" ? "LIVE · HOLD TO SCRUB" : "HOLD TO SCRUB")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    momentumLegend(detail.homeSide, percent: Int((last * 100).rounded()))
                }
            }
        }
    }

    /// Fallback pressure curve for sports with no probability feed — not a
    /// probability, so no percentages or scrubbing.
    private func momentumSection(_ points: [Double], caption: String) -> some View {
        sectionCard("Momentum") {
            VStack(spacing: 8) {
                MomentumChart(
                    points: points,
                    homeColor: detail.homeSide.color,
                    awayColor: detail.awaySide.color,
                    progress: detail.gameProgress
                )
                .frame(height: 110)
                HStack {
                    momentumLegend(detail.awaySide)
                    Spacer()
                    Text(caption)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.secondary)
                    Spacer()
                    momentumLegend(detail.homeSide)
                }
            }
        }
    }

    private func momentumLegend(_ side: GDTeamSide, percent: Int? = nil) -> some View {
        HStack(spacing: 5) {
            Circle().fill(side.color).frame(width: 9, height: 9)
            Text(side.abbreviation)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
            if let percent {
                Text("\(percent)%")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
        }
    }

    // MARK: Main stats (overview)

    private var mainStatsSection: some View {
        sectionCard("Top Stats") {
            VStack(spacing: 14) {
                if let possession = detail.possessionBar {
                    possessionView(possession)
                }
                ForEach(detail.mainStats) { bar in
                    statBarRow(bar)
                }
            }
        }
    }

    /// FotMob-style full-width possession bar with the percentages inside.
    private func possessionView(_ bar: GDStatBar) -> some View {
        VStack(spacing: 6) {
            Text("Ball Possession")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            GeometryReader { geo in
                HStack(spacing: 2) {
                    HStack {
                        Text(possessionLabel(bar.awayText))
                            .padding(.leading, 12)
                        Spacer()
                    }
                    .frame(width: max(44, geo.size.width * (1 - bar.homeFraction)))
                    .frame(maxHeight: .infinity)
                    .background(detail.awaySide.color)
                    HStack {
                        Spacer()
                        Text(possessionLabel(bar.homeText))
                            .padding(.trailing, 12)
                    }
                    .frame(maxHeight: .infinity)
                    .background(detail.homeSide.color)
                }
                .font(.system(size: 14, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .frame(height: 34)
        }
    }

    private func possessionLabel(_ raw: String) -> String {
        let value = raw.replacingOccurrences(of: "%", with: "")
        if let number = Double(value) {
            return "\(Int(number.rounded()))%"
        }
        return raw
    }

    private func statBarRow(_ bar: GDStatBar) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(bar.awayText)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                Text(bar.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(bar.homeText)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule()
                        .fill(detail.awaySide.color)
                        .frame(width: max(3, geo.size.width * (1 - bar.homeFraction)))
                    Capsule()
                        .fill(detail.homeSide.color)
                        .frame(width: max(3, geo.size.width * bar.homeFraction))
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: Shot map

    private var shotMapSection: some View {
        sectionCard("Shot Map") {
            VStack(spacing: 8) {
                ShotMapView(
                    shots: detail.shots,
                    homeColor: detail.homeSide.color,
                    awayColor: detail.awaySide.color
                )
                .frame(height: 190)
                HStack {
                    momentumLegend(detail.awaySide)
                    Spacer()
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Circle().fill(.white).frame(width: 8, height: 8)
                            Text("Goal").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            Circle().stroke(.white.opacity(0.7), lineWidth: 1.5).frame(width: 8, height: 8)
                            Text("Shot").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    momentumLegend(detail.homeSide)
                }
            }
        }
    }

    // MARK: Timeline

    private var timelineSection: some View {
        sectionCard("Match Events") {
            let entries = detail.timeline
            let firstHalf = entries.filter { $0.period <= 1 }
            let secondHalf = entries.filter { $0.period >= 2 }
            VStack(spacing: 0) {
                ForEach(firstHalf) { entry in
                    timelineRow(entry)
                }
                if !firstHalf.isEmpty && !secondHalf.isEmpty {
                    halftimeDivider
                }
                ForEach(secondHalf) { entry in
                    timelineRow(entry)
                }
            }
        }
    }

    private var halftimeDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
            Text("HALFTIME")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
        }
        .padding(.vertical, 10)
    }

    private func timelineRow(_ entry: GDTimelineEntry) -> some View {
        HStack(spacing: 10) {
            if entry.isHome { Spacer(minLength: 40) }
            if !entry.isHome { timelineBody(entry, alignRight: false) }
            Text(entry.minute)
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 40)
            if entry.isHome { timelineBody(entry, alignRight: true) }
            if !entry.isHome { Spacer(minLength: 40) }
        }
        .padding(.vertical, 7)
    }

    private func timelineBody(_ entry: GDTimelineEntry, alignRight: Bool) -> some View {
        HStack(spacing: 8) {
            if alignRight { timelineText(entry, alignment: .trailing) }
            timelineIcon(entry.kind)
            if !alignRight { timelineText(entry, alignment: .leading) }
        }
        .frame(maxWidth: .infinity, alignment: alignRight ? .trailing : .leading)
    }

    private func timelineText(_ entry: GDTimelineEntry, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(entry.playerText)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if let detailText = entry.detailText {
                Text(detailText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func timelineIcon(_ kind: GDEventKind) -> some View {
        switch kind {
        case .goal, .penaltyGoal:
            Image(systemName: "soccerball.inverse")
                .font(.system(size: 15))
                .foregroundStyle(.white)
        case .ownGoal:
            Image(systemName: "soccerball.inverse")
                .font(.system(size: 15))
                .foregroundStyle(.red)
        case .penaltyMiss:
            Image(systemName: "xmark.circle")
                .font(.system(size: 15))
                .foregroundStyle(.red)
        case .yellow:
            RoundedRectangle(cornerRadius: 2).fill(.yellow).frame(width: 11, height: 15)
        case .red:
            RoundedRectangle(cornerRadius: 2).fill(.red).frame(width: 11, height: 15)
        case .substitution:
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.green)
        }
    }

    // MARK: Lineups (soccer)

    private var soccerLineupSection: some View {
        sectionCard("Lineups") {
            VStack(spacing: 12) {
                sidePicker(selection: $lineupSide)
                if let lineup = detail.lineup(homeAway: lineupSide) {
                    let side = lineupSide == "home" ? detail.homeSide : detail.awaySide
                    if let formation = lineup.formation {
                        Text(formation)
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    if !lineup.rows.isEmpty {
                        FormationPitchView(rows: lineup.rows, teamColor: side.color)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(lineup.starters) { player in
                                lineupListRow(player)
                            }
                        }
                    }
                    if !lineup.substitutes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SUBSTITUTES")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                            ForEach(lineup.substitutes) { player in
                                lineupListRow(player)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("Lineup not available yet")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(sideSwipeGesture($lineupSide))
        }
    }

    private func lineupListRow(_ player: GDLineupPlayer) -> some View {
        HStack(spacing: 10) {
            Text(player.jersey)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            Text(player.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if player.goals > 0 {
                Image(systemName: "soccerball.inverse").font(.system(size: 12))
            }
            if player.red {
                RoundedRectangle(cornerRadius: 1.5).fill(.red).frame(width: 9, height: 12)
            } else if player.yellow {
                RoundedRectangle(cornerRadius: 1.5).fill(.yellow).frame(width: 9, height: 12)
            }
            if let onClock = player.subbedOnClock, !onClock.isEmpty {
                Text("▲ \(onClock)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
            }
            Spacer()
            RatingBadge(rating: player.rating)
        }
    }

    // MARK: Box score (US sports, Stats tab)

    private var boxScoreSection: some View {
        sectionCard("Box Score") {
            VStack(spacing: 12) {
                sidePicker(selection: $boxSide)
                let groups = detail.boxGroups(homeAway: boxSide)
                if groups.isEmpty {
                    Text("Player stats not available yet")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(groups) { group in
                        boxGroupTable(group)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(sideSwipeGesture($boxSide))
        }
    }

    private func boxGroupTable(_ group: GDBoxGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.title.uppercased())
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 0) {
                // Frozen name + rating column.
                VStack(alignment: .leading, spacing: 0) {
                    Text("PLAYER")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.secondary)
                        .frame(height: 22)
                    ForEach(group.rows) { row in
                        HStack(spacing: 6) {
                            RatingBadge(rating: row.rating, compact: true)
                            Text(row.name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .frame(height: 27)
                    }
                }
                .frame(width: 140, alignment: .leading)

                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(group.columns.indices, id: \.self) { i in
                                Text(group.columns[i])
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, height: 22)
                            }
                        }
                        ForEach(group.rows) { row in
                            HStack(spacing: 0) {
                                ForEach(row.values.indices, id: \.self) { i in
                                    Text(row.values[i])
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.8))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .frame(width: 48, height: 27)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func sidePicker(selection: Binding<String>) -> some View {
        HStack(spacing: 8) {
            sideChip(side: detail.awaySide, value: "away", selection: selection)
            sideChip(side: detail.homeSide, value: "home", selection: selection)
        }
    }

    private func sideSwipeGesture(_ selection: Binding<String>) -> some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let h = value.translation.width
                guard abs(h) > abs(value.translation.height) else { return }
                if h < 0 && selection.wrappedValue == "away" {
                    ChannelViewModel.shared.triggerSelectionHaptic()
                    withAnimation(.easeOut(duration: 0.15)) { selection.wrappedValue = "home" }
                } else if h > 0 && selection.wrappedValue == "home" {
                    ChannelViewModel.shared.triggerSelectionHaptic()
                    withAnimation(.easeOut(duration: 0.15)) { selection.wrappedValue = "away" }
                }
            }
    }

    private func sideChip(side: GDTeamSide, value: String, selection: Binding<String>) -> some View {
        Button {
            ChannelViewModel.shared.triggerSelectionHaptic()
            withAnimation(.easeOut(duration: 0.15)) { selection.wrappedValue = value }
        } label: {
            HStack(spacing: 6) {
                CachedAsyncImage(urlString: side.logo ?? "", size: CGSize(width: 18, height: 18))
                    .frame(width: 18, height: 18)
                Text(side.name)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(selection.wrappedValue == value ? Color.white.opacity(0.18) : Color.white.opacity(0.05))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(selection.wrappedValue == value ? 0.3 : 0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    // MARK: Standings (Table tab)

    private func standingsCard(_ group: GDStandingsGroup) -> some View {
        sectionCard(group.header) {
            VStack(spacing: 0) {
                // Column header row.
                HStack(spacing: 8) {
                    Text("#")
                        .frame(width: 20, alignment: .center)
                    Text("TEAM")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(group.columns.indices, id: \.self) { i in
                        Text(group.columns[i])
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)

                ForEach(group.rows) { row in
                    standingsRow(row)
                }
            }
        }
    }

    private func standingsRow(_ row: GDStandingRow) -> some View {
        let highlightColor = row.isHome ? detail.homeSide.color : detail.awaySide.color
        return HStack(spacing: 8) {
            Text("\(row.rank)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            HStack(spacing: 7) {
                CachedAsyncImage(urlString: row.logo ?? "", size: CGSize(width: 20, height: 20))
                    .frame(width: 20, height: 20)
                Text(row.name)
                    .font(.system(size: 13, weight: row.isPlaying ? .bold : .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(row.values.indices, id: \.self) { i in
                Text(row.values[i])
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .background(
            row.isPlaying
                ? RoundedRectangle(cornerRadius: 8).fill(highlightColor.opacity(0.22))
                : nil
        )
        .overlay(alignment: .leading) {
            if row.isPlaying {
                Capsule().fill(highlightColor).frame(width: 3, height: 22)
            }
        }
    }

    // MARK: Top performers

    private var performersSection: some View {
        sectionCard("Top Performers") {
            VStack(spacing: 10) {
                ForEach(detail.topPerformers) { leader in
                    HStack(spacing: 10) {
                        if let headshot = leader.headshot {
                            CachedAsyncImage(urlString: headshot, size: CGSize(width: 36, height: 36))
                                .frame(width: 36, height: 36)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Circle())
                        } else {
                            Circle()
                                .fill((leader.isHome ? detail.homeSide.color : detail.awaySide.color).opacity(0.4))
                                .frame(width: 36, height: 36)
                                .overlay(Image(systemName: "person.fill").font(.system(size: 15)).foregroundStyle(.white.opacity(0.7)))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(leader.name)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            Text(leader.category)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(leader.statLine)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        }
    }

    // MARK: H2H

    @ViewBuilder
    private var h2hSection: some View {
        let homeForm = detail.form(homeAway: "home")
        let awayForm = detail.form(homeAway: "away")
        let meetings = detail.meetings
        if !homeForm.isEmpty || !awayForm.isEmpty || !meetings.isEmpty || detail.seasonSeriesText != nil {
            sectionCard("Head to Head") {
                VStack(spacing: 12) {
                    if let series = detail.seasonSeriesText {
                        Text(series)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                    }
                    if !homeForm.isEmpty || !awayForm.isEmpty {
                        HStack {
                            formColumn(side: detail.awaySide, results: awayForm)
                            Spacer()
                            Text("FORM")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(.secondary)
                            Spacer()
                            formColumn(side: detail.homeSide, results: homeForm)
                        }
                    }
                    if !meetings.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(meetings) { meeting in
                                HStack {
                                    Text(meeting.dateText)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 64, alignment: .leading)
                                    Text(meeting.leagueText)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(meeting.awayAbbrev) \(meeting.awayTeamDisplayScore) – \(meeting.homeTeamDisplayScore) \(meeting.homeAbbrev)")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func formColumn(side: GDTeamSide, results: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(results.indices, id: \.self) { i in
                Text(results[i])
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(formColor(results[i]))
                    .clipShape(Circle())
            }
        }
    }

    private func formColor(_ result: String) -> Color {
        switch result.uppercased() {
        case "W": return .green.opacity(0.75)
        case "L": return .red.opacity(0.75)
        default: return .gray.opacity(0.5)
        }
    }

    // MARK: Venue

    @ViewBuilder
    private var venueSection: some View {
        if detail.venueLine != nil || !detail.officials.isEmpty {
            sectionCard("Match Info") {
                VStack(alignment: .leading, spacing: 10) {
                    if let venue = detail.venueLine {
                        infoRow(icon: "building.2", title: venue.name, subtitle: venue.city)
                    }
                    if let attendance = detail.attendance, attendance > 0 {
                        infoRow(icon: "person.3", title: "Attendance", subtitle: attendance.formatted())
                    }
                    if !detail.officials.isEmpty {
                        infoRow(
                            icon: "figure.walk",
                            title: detail.officials.count > 1 ? "Officials" : "Referee",
                            subtitle: detail.officials.joined(separator: ", ")
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

// MARK: - Watch button glass

/// Liquid-glass capsule for the detail pages' watch buttons — real
/// glassEffect on iOS 26, ultra-thin material below, matching the app's
/// other glass controls.
struct WatchButtonGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            AnyView(content.glassEffect(.regular, in: Capsule()))
        } else {
            AnyView(
                content
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            )
        }
    }
}

// MARK: - Bases diamond

/// Scoreboard-style base indicator: second base on top, third left, first
/// right. Occupied bases fill in the batting team's color.
struct BasesDiamondView: View {
    let onFirst: Bool
    let onSecond: Bool
    let onThird: Bool
    let fillColor: Color

    var body: some View {
        ZStack {
            base(occupied: onSecond).offset(y: -15)
            base(occupied: onThird).offset(x: -17, y: 2)
            base(occupied: onFirst).offset(x: 17, y: 2)
        }
        .frame(width: 66, height: 58)
    }

    private func base(occupied: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(occupied ? fillColor : Color.white.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(occupied ? fillColor : Color.white.opacity(0.3), lineWidth: 1.2)
            )
            .frame(width: 20, height: 20)
            .rotationEffect(.degrees(45))
    }
}

// MARK: - Rating badge

/// FotMob-style colored rating chip: red < 5, orange 5–6.9, green 7–7.9,
/// teal 8+. Hidden (dash) when no rating could be computed.
struct RatingBadge: View {
    let rating: Double?
    var compact: Bool = false

    var body: some View {
        Group {
            if let rating {
                Text(String(format: "%.1f", rating))
                    .font(.system(size: compact ? 10 : 12, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, compact ? 4 : 6)
                    .padding(.vertical, compact ? 2 : 3)
                    .background(color(for: rating))
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 5 : 6))
            } else if compact {
                Text("–")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(width: 26)
            }
        }
        .frame(minWidth: compact ? 26 : 32)
    }

    private func color(for rating: Double) -> Color {
        switch rating {
        case ..<5.0: return Color(red: 0.85, green: 0.25, blue: 0.25)
        case ..<7.0: return Color(red: 0.95, green: 0.6, blue: 0.1)
        case ..<8.0: return Color(red: 0.2, green: 0.7, blue: 0.35)
        default: return Color(red: 0.1, green: 0.65, blue: 0.85)
        }
    }
}

// MARK: - Formation pitch

/// Draws a soccer half-pitch with the team laid out by formation rows,
/// goalkeeper at the bottom, attack at the top — one team at a time, which
/// keeps every name readable on a phone (a full two-team pitch makes each
/// chip ~40pt and unreadable).
struct FormationPitchView: View {
    /// Rows from the goalkeeper outward.
    let rows: [[GDLineupPlayer]]
    let teamColor: Color

    var body: some View {
        // Attack at the top: last formation row first, GK last.
        let displayRows = Array(rows.reversed())
        GeometryReader { geo in
            let rowHeight = geo.size.height / CGFloat(max(displayRows.count, 1))
            ZStack {
                pitchLines(in: geo.size)
                ForEach(displayRows.indices, id: \.self) { rowIndex in
                    let row = displayRows[rowIndex]
                    let y = rowHeight * (CGFloat(rowIndex) + 0.5)
                    let slotWidth = geo.size.width / CGFloat(row.count)
                    ForEach(row.indices, id: \.self) { colIndex in
                        PitchPlayerChip(player: row[colIndex], teamColor: teamColor)
                            .position(x: slotWidth * (CGFloat(colIndex) + 0.5), y: y)
                    }
                }
            }
        }
        .frame(height: CGFloat(rows.count) * 76)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func pitchLines(in size: CGSize) -> some View {
        Canvas { context, _ in
            let line = Color.white.opacity(0.10)
            // Goal box at the bottom (GK end).
            let boxWidth = size.width * 0.5
            let box = CGRect(x: (size.width - boxWidth) / 2, y: size.height - 34, width: boxWidth, height: 34)
            context.stroke(Path(box), with: .color(line), lineWidth: 1)
            let smallWidth = size.width * 0.24
            let small = CGRect(x: (size.width - smallWidth) / 2, y: size.height - 14, width: smallWidth, height: 14)
            context.stroke(Path(small), with: .color(line), lineWidth: 1)
            // Center circle arc at the top (halfway line is the top edge).
            var arc = Path()
            arc.addArc(center: CGPoint(x: size.width / 2, y: 0), radius: 36,
                       startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            context.stroke(arc, with: .color(line), lineWidth: 1)
        }
    }
}

private struct PitchPlayerChip: View {
    let player: GDLineupPlayer
    let teamColor: Color

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(teamColor.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                    .overlay(
                        Text(player.jersey)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    )
                RatingBadge(rating: player.rating, compact: true)
                    .offset(x: 14, y: -6)
            }
            HStack(spacing: 2) {
                if player.goals > 0 {
                    Image(systemName: "soccerball.inverse").font(.system(size: 9))
                }
                if player.red {
                    RoundedRectangle(cornerRadius: 1).fill(.red).frame(width: 5, height: 8)
                } else if player.yellow {
                    RoundedRectangle(cornerRadius: 1).fill(.yellow).frame(width: 5, height: 8)
                }
                if player.subbedOffClock != nil {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.red)
                }
                Text(player.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: 80)
        }
    }
}

// MARK: - Shot map

/// Full-pitch shot chart: home team's shots plotted at the left goal, away
/// at the right. ESPN coordinates arrive normalized toward the attacked
/// goal (x → 100 at the goal line) for both teams, so the home side is
/// mirrored onto the left half.
struct ShotMapView: View {
    let shots: [GDShot]
    let homeColor: Color
    let awayColor: Color

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                pitchLines(in: size)
                ForEach(shots) { shot in
                    shotMarker(shot)
                        .position(markerPosition(for: shot, in: size))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func markerPosition(for shot: GDShot, in size: CGSize) -> CGPoint {
        let xFraction: Double = shot.isHome ? (100.0 - shot.x) / 100.0 : shot.x / 100.0
        let px = size.width * CGFloat(xFraction)
        let py = size.height * CGFloat(shot.y / 100.0)
        return CGPoint(
            x: min(max(px, 8), size.width - 8),
            y: min(max(py, 8), size.height - 8)
        )
    }

    @ViewBuilder
    private func shotMarker(_ shot: GDShot) -> some View {
        let color = shot.isHome ? homeColor : awayColor
        if shot.isGoal {
            ZStack {
                Circle().fill(color).frame(width: 15, height: 15)
                Image(systemName: "soccerball.inverse")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
            }
        } else {
            Circle()
                .stroke(color, lineWidth: 1.8)
                .frame(width: 12, height: 12)
        }
    }

    private func pitchLines(in size: CGSize) -> some View {
        Canvas { context, _ in
            let line = Color.white.opacity(0.10)
            // Halfway line + center circle.
            var mid = Path()
            mid.move(to: CGPoint(x: size.width / 2, y: 0))
            mid.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            context.stroke(mid, with: .color(line), lineWidth: 1)
            let circle = CGRect(x: size.width / 2 - 28, y: size.height / 2 - 28, width: 56, height: 56)
            context.stroke(Path(ellipseIn: circle), with: .color(line), lineWidth: 1)
            // Penalty boxes.
            let boxHeight = size.height * 0.56
            let boxWidth = size.width * 0.16
            let leftBox = CGRect(x: 0, y: (size.height - boxHeight) / 2, width: boxWidth, height: boxHeight)
            let rightBox = CGRect(x: size.width - boxWidth, y: (size.height - boxHeight) / 2, width: boxWidth, height: boxHeight)
            context.stroke(Path(leftBox), with: .color(line), lineWidth: 1)
            context.stroke(Path(rightBox), with: .color(line), lineWidth: 1)
            // Six-yard boxes.
            let smallHeight = size.height * 0.26
            let smallWidth = size.width * 0.06
            let leftSmall = CGRect(x: 0, y: (size.height - smallHeight) / 2, width: smallWidth, height: smallHeight)
            let rightSmall = CGRect(x: size.width - smallWidth, y: (size.height - smallHeight) / 2, width: smallWidth, height: smallHeight)
            context.stroke(Path(leftSmall), with: .color(line), lineWidth: 1)
            context.stroke(Path(rightSmall), with: .color(line), lineWidth: 1)
        }
    }
}

// MARK: - Momentum chart

/// FotMob-style momentum ribbon: the area above the midline (home on top)
/// fills in the home color, below in the away color. Points are lightly
/// smoothed so the raw per-play win-probability feed doesn't render as
/// jagged noise. The x-axis spans the WHOLE game; `progress` says how much
/// has been played, so a live game's curve stops partway with empty track
/// ahead of it. With `interactive`, press-and-hold scrubs a marker along
/// the curve and shows the probability at that moment.
struct MomentumChart: View {
    let points: [Double]
    let homeColor: Color
    let awayColor: Color
    var progress: Double = 1
    var homeAbbrev: String = ""
    var awayAbbrev: String = ""
    var interactive: Bool = false

    /// Scrub position as a fraction of the full chart width, while the
    /// finger is down.
    @State private var scrubFraction: CGFloat?

    private var smoothed: [Double] {
        guard points.count > 4 else { return points }
        return points.indices.map { i in
            let lo = max(0, i - 1), hi = min(points.count - 1, i + 1)
            var sum = 0.0
            for j in lo...hi { sum += points[j] }
            return sum / Double(hi - lo + 1)
        }
    }

    private var span: CGFloat { CGFloat(min(max(progress, 0.05), 1)) }

    var body: some View {
        let values = smoothed
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                // Midline = 50/50, across the whole game.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height / 2))
                    p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                areaPath(values, in: size, home: true)
                    .fill(homeColor.opacity(0.6))
                areaPath(values, in: size, home: false)
                    .fill(awayColor.opacity(0.6))

                if interactive, let fraction = scrubFraction, !values.isEmpty {
                    scrubOverlay(values, fraction: fraction, in: size)
                }
            }
            .simultaneousGesture(scrubGesture(in: size), isEnabled: interactive)
        }
    }

    // MARK: Scrubbing

    /// Long-press first so vertical page scrolling that starts on the chart
    /// still wins; once held, the finger drags the marker. 0.3s (not
    /// shorter): a scroll swipe often starts with the finger briefly at
    /// rest, and a quicker trigger captured those touches — the swipe then
    /// scrubbed instead of scrolling. The haptic marks the handoff into
    /// scrub mode so a held finger knows the chart has taken the touch.
    private func scrubGesture(in size: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .second(true, let drag):
                    if scrubFraction == nil { ChannelViewModel.shared.triggerSelectionHaptic() }
                    let x = drag?.location.x ?? size.width * span
                    scrubFraction = min(max(x / max(size.width, 1), 0), span)
                default:
                    break
                }
            }
            .onEnded { _ in scrubFraction = nil }
    }

    @ViewBuilder
    private func scrubOverlay(_ values: [Double], fraction: CGFloat, in size: CGSize) -> some View {
        let index = Int((fraction / span * CGFloat(values.count - 1)).rounded())
        let clamped = min(max(index, 0), values.count - 1)
        let probability = values[clamped]
        let x = size.width * fraction
        let y = size.height * CGFloat(1 - probability)
        let homeLeads = probability >= 0.5
        let percent = Int(((homeLeads ? probability : 1 - probability) * 100).rounded())
        let label = "\(homeLeads ? homeAbbrev : awayAbbrev) \(percent)%"

        Path { p in
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
        }
        .stroke(Color.white.opacity(0.5), lineWidth: 1)

        Circle()
            .fill(homeLeads ? homeColor : awayColor)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .position(x: x, y: y)

        Text(label)
            .font(.system(size: 11, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((homeLeads ? homeColor : awayColor).opacity(0.9))
            .clipShape(Capsule())
            .position(x: min(max(x, 34), size.width - 34), y: 10)
    }

    // MARK: Geometry

    private func xy(_ values: [Double], _ index: Int, in size: CGSize) -> CGPoint {
        // Data spans only the played fraction of the width.
        let x = size.width * span * CGFloat(index) / CGFloat(max(values.count - 1, 1))
        // Home win % of 1 → top edge; 0 → bottom edge.
        let y = size.height * CGFloat(1 - values[index])
        return CGPoint(x: x, y: y)
    }

    /// The probability area on one side of the midline: y clamped to the
    /// home half (above) or away half (below), closed back along the line.
    private func areaPath(_ values: [Double], in size: CGSize, home: Bool) -> Path {
        Path { p in
            guard !values.isEmpty else { return }
            let mid = size.height / 2
            func clampedY(_ i: Int) -> CGFloat {
                let y = xy(values, i, in: size).y
                return home ? min(y, mid) : max(y, mid)
            }
            p.move(to: CGPoint(x: 0, y: mid))
            for i in 0..<values.count {
                p.addLine(to: CGPoint(x: xy(values, i, in: size).x, y: clampedY(i)))
            }
            p.addLine(to: CGPoint(x: size.width * span, y: mid))
            p.closeSubpath()
        }
    }
}

private extension GDMeeting {
    var awayTeamDisplayScore: String { awayScore.isEmpty ? "–" : awayScore }
    var homeTeamDisplayScore: String { homeScore.isEmpty ? "–" : homeScore }
}
