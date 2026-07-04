import SwiftUI
import KSPlayer
import MobileVLCKit
import AVFoundation
import AVKit

// MARK: - Layout Mode

/// How the user wants their streams arranged in multi-view. Both layouts
/// live inside the hub (header + search pill); landscape orientation lets
/// `equal` mode auto-expand to fill the screen.
enum MultiViewLayoutMode: String, CaseIterable, Identifiable {
    /// 1 large featured stream + horizontal mini row for the rest.
    case focus
    /// Adaptive grid of equal-size cards; layout shape varies by count
    /// (1, 2×1, 1+2, 2×2) and by device orientation.
    case equal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .focus: return "Focus"
        case .equal: return "Equal"
        }
    }

    var icon: String {
        switch self {
        case .focus: return "rectangle.tophalf.inset.filled"
        case .equal: return "square.grid.2x2.fill"
        }
    }
}

// MARK: - Glass helpers

/// Capsule-shaped liquid glass — mirrors `CapsuleGlassBackground` in MainView
/// (which is `private`) so this file can adopt the exact same treatment.
struct MVCapsuleGlass: ViewModifier {
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

/// Circle-shaped liquid glass for round icon buttons.
struct MVCircleGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            AnyView(content.glassEffect(.regular, in: Circle()))
        } else {
            AnyView(
                content
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            )
        }
    }
}

// MARK: - Main Screen

struct MultiViewScreen: View {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Binding var showMultiView: Bool
    let accentColor: Color
    /// Invoked when the user taps the gear icon. The parent (MainView) sets
    /// `showSettings = true` so the same settings sheet that opens from the
    /// home screen pops up over the multi-view overlay.
    var onOpenSettings: () -> Void = {}

    // Mirror MainView's nebula-background AppStorage so multi-view feels
    // like part of the same app instead of having its own hardcoded palette.
    @AppStorage("nebColor1") private var nebColor1 = "#1A2538"
    @AppStorage("nebColor2") private var nebColor2 = "#11101A"
    @AppStorage("nebColor3") private var nebColor3 = "#1F1A24"
    @AppStorage("nebX1") private var nebX1 = 0.5
    @AppStorage("nebY1") private var nebY1 = 0.0
    @AppStorage("nebX2") private var nebX2 = 0.5
    @AppStorage("nebY2") private var nebY2 = 0.5
    @AppStorage("nebX3") private var nebX3 = 0.5
    @AppStorage("nebY3") private var nebY3 = 1.0

    @State private var focusedIndex: Int = 0
    @State private var layoutMode: MultiViewLayoutMode = .focus
    @State private var showSearchSheet = false
    @State private var showFullSearch = false
    /// True once we've picked the auto-default layout for the current
    /// session. Prevents `onChangeCompat(of: multiViewSlots)` from constantly
    /// re-overriding the user's manual choice when they add/remove streams.
    @State private var didApplyDefaultLayout = false
    /// Back/Settings chrome auto-hide state. Same pattern as the video
    /// player controls: visible on entry + any tap, fades out after 4 s of
    /// no interaction so the streams aren't obscured.
    @State private var showChrome: Bool = true
    @State private var chromeHideTask: Task<Void, Never>? = nil
    /// Mirror of the GeometryReader's `isLandscape` so modifiers attached
    /// outside the GeometryReader (toolbar, overlay) can react to rotation.
    @State private var isLandscapeOrient: Bool = false

    /// Auto-hide chrome only applies in landscape equal mode. Portrait equal
    /// mode and focus mode both keep the always-visible system toolbar.
    private var chromeAutoHideActive: Bool {
        layoutMode == .equal && isLandscapeOrient
    }

    /// Slot indices that currently hold a channel, in slot-order.
    var activeIndices: [Int] {
        viewModel.multiViewSlots.enumerated().compactMap { $0.element != nil ? $0.offset : nil }
    }

    /// Streams the user has audio routed to (only the focused one carries
    /// audio — every other slot is muted). Hub header surfaces this count.
    private var streamsWithAudio: Int {
        activeIndices.contains(focusedIndex) ? 1 : 0
    }

    var body: some View {
        ZStack {
            NavigationStack {
                GeometryReader { geo in
                    let topInset = max(geo.safeAreaInsets.top, 54)
                    let bottomInset = max(geo.safeAreaInsets.bottom, 16)
                    let isLandscape = geo.size.width > geo.size.height

                    ZStack {
                        NebulaBackgroundView(
                            color1: Color(hex: nebColor1) ?? .purple,
                            color2: Color(hex: nebColor2) ?? .blue,
                            color3: Color(hex: nebColor3) ?? .pink,
                            point1: UnitPoint(x: nebX1, y: nebY1),
                            point2: UnitPoint(x: nebX2, y: nebY2),
                            point3: UnitPoint(x: nebX3, y: nebY3)
                        )
                        .ignoresSafeArea()

                        MultiViewHubLayout(
                            viewModel: viewModel,
                            scoreViewModel: scoreViewModel,
                            focusedIndex: $focusedIndex,
                            layoutMode: $layoutMode,
                            showSearchSheet: $showSearchSheet,
                            activeIndices: activeIndices,
                            streamsWithAudio: streamsWithAudio,
                            topInset: topInset,
                            bottomInset: bottomInset,
                            leadingInset: geo.safeAreaInsets.leading,
                            trailingInset: geo.safeAreaInsets.trailing,
                            screenWidth: geo.size.width,
                            accentColor: accentColor,
                            isLandscape: isLandscape,
                            onLiveGameTap: handleLiveGameTap,
                            onSearchTap: openFullSearch
                        )
                    }
                // Bidirectional auto-switch on rotation. Safe in the unified
                // architecture because EqualStreamGrid is always mounted —
                // changing layoutMode only updates the per-tile rects
                // returned by rectFor, never destroys or recreates view
                // subtrees. KSPlayer instances stay anchored to the same
                // containers, no re-parenting, no possible freeze on rapid
                // rotations.
                .onChangeCompat(of: isLandscape) { nowLandscape in
                    isLandscapeOrient = nowLandscape
                    guard !activeIndices.isEmpty else { return }
                    let target: MultiViewLayoutMode = nowLandscape ? .equal : .focus
                    if layoutMode != target {
                        layoutMode = target
                    }
                }
                .onAppear {
                    // Seed initial orientation + apply orientation default so
                    // the first render lands on the correct mode for whichever
                    // way the device is held when multi-view opens.
                    isLandscapeOrient = isLandscape
                    if !activeIndices.isEmpty {
                        let target: MultiViewLayoutMode = isLandscape ? .equal : .focus
                        if layoutMode != target {
                            layoutMode = target
                        }
                    }
                }
            }
            .modifier(SwipeBackModifier(onBack: handleDismiss))
            .onAppear {
                if !activeIndices.contains(focusedIndex), let first = activeIndices.first {
                    focusedIndex = first
                }
                if !didApplyDefaultLayout {
                    layoutMode = defaultLayout(forStreamCount: activeIndices.count)
                    didApplyDefaultLayout = true
                }
                PlayerOrientationManager.shared.allowsLandscape = true
                showChromeAndArmTimer()
            }
            .onDisappear {
                PlayerOrientationManager.shared.allowsLandscape = false
                MultiViewPlayerPool.shared.releaseAll()
                chromeHideTask?.cancel()
            }
            .onChangeCompat(of: viewModel.multiViewSlots) { _ in
                if !activeIndices.contains(focusedIndex), let first = activeIndices.first {
                    focusedIndex = first
                }
                let activeURLs = Set(viewModel.multiViewSlots.compactMap { $0?.streamURL })
                MultiViewPlayerPool.shared.reconcile(activeURLs: activeURLs)
            }
            .sheet(isPresented: $showSearchSheet) {
                MultiViewSearchSheet(viewModel: viewModel, onSelect: { c in
                    viewModel.addToMultiView(c)
                    showSearchSheet = false
                })
            }
            .statusBar(hidden: false)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            // Landscape + equal = full-bleed video; hide the system toolbar
            // so the auto-hide custom glass chrome owns the top edge. Every
            // other state (focus mode in either orientation, equal mode in
            // portrait) keeps the always-visible system toolbar.
            .toolbar(chromeAutoHideActive ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                if !chromeAutoHideActive {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: handleDismiss) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                            .foregroundStyle(.white)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        SettingsGearButton(action: onOpenSettings)
                    }
                }
            }
            .overlay(alignment: .top) {
                if chromeAutoHideActive {
                    HStack(spacing: 10) {
                        // Fixed 44pt height capsule pill — same dimensions as
                        // the + / layout-chooser buttons in the multi-view
                        // header and the system toolbar items in focus mode.
                        Button(action: {
                            handleDismiss()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                            .font(.body)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                            .modifier(GlassEffect(cornerRadius: 22, isSelected: false, accentColor: nil))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        // Add-stream button — the header (where the home + lives)
                        // is collapsed in landscape immersive mode, so this is
                        // the only way to add a stream without rotating back to
                        // portrait.
                        Button(action: {
                            openFullSearch()
                        }) {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .modifier(GlassEffect(cornerRadius: 22, isSelected: false, accentColor: nil))
                        }
                        .buttonStyle(.plain)

                        // Perfect 44x44 circle to match the + / layout-chooser
                        // glass buttons in the multi-view header.
                        Button(action: {
                            onOpenSettings()
                        }) {
                            Image(systemName: "gearshape.fill")
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .modifier(GlassEffect(cornerRadius: 22, isSelected: false, accentColor: nil))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .opacity(showChrome ? 1 : 0)
                    .allowsHitTesting(showChrome)
                    .animation(.easeInOut(duration: 0.25), value: showChrome)
                }
            }
            // Toggle the back / settings chrome on tap: a tap while it's
            // hidden brings it in and starts the 4-second auto-hide timer;
            // a tap while it's visible dismisses it immediately. Mirrors the
            // video player overlay behavior. simultaneousGesture means the
            // underlying tile taps (focus / audio routing) still fire — we
            // just piggy-back on the same touch event. Only active in
            // landscape equal mode since that's where the chrome auto-hides.
            .simultaneousGesture(
                TapGesture()
                    .onEnded {
                        if chromeAutoHideActive {
                            toggleChrome()
                        }
                    }
            )
            } // end NavigationStack

            // Search overlay sits OUTSIDE the NavigationStack so its
            // `safeAreaInsets` math measures against the device screen, not
            // the toolbar-inset content area. The previous version nested
            // the overlay inside the GeometryReader, which made the search
            // title's `topInset + 10` get added on top of the navigation
            // toolbar's reserved height — the search bar ended up too far
            // down and visually below the result list.
            if showFullSearch {
                SearchOverlayView(
                    viewModel: viewModel,
                    searchText: $viewModel.searchText,
                    accentColor: accentColor,
                    playAction: { channel in
                        viewModel.triggerSelectionHaptic()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            viewModel.addToMultiView(channel)
                            if let idx = viewModel.multiViewSlots.firstIndex(where: { $0?.id == channel.id }) {
                                focusedIndex = idx
                            }
                        }
                        closeFullSearch()
                    },
                    onCategorySelect: { _ in closeFullSearch() },
                    onDismiss: closeFullSearch
                )
                .transition(.move(edge: .bottom))
                .zIndex(100)
                .ignoresSafeArea()
            }
        } // end outer ZStack
    }

    /// Show the back / settings chrome and arm the 4-second auto-hide timer.
    /// Used on the screen's initial appearance.
    private func showChromeAndArmTimer() {
        chromeHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { showChrome = true }
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showChrome = false }
        }
    }

    /// Tap-handler version: hides the chrome immediately when it's visible,
    /// shows it (and arms the auto-hide timer) when it's hidden.
    private func toggleChrome() {
        chromeHideTask?.cancel()
        if showChrome {
            withAnimation(.easeInOut(duration: 0.25)) { showChrome = false }
        } else {
            showChromeAndArmTimer()
        }
    }

    /// User tapped a `LiveGameCard`. Try the synchronous best-match resolver
    /// first; fall back to the async smart search (which sets
    /// channelToAutoPlay → handled by MainView with multiViewModeActive).
    private func handleLiveGameTap(_ game: ESPNEvent) {
        viewModel.triggerSelectionHaptic()
        let h = game.homeCompetitor?.team?.shortDisplayName
            ?? game.homeCompetitor?.athlete?.shortName ?? ""
        let a = game.awayCompetitor?.team?.shortDisplayName
            ?? game.awayCompetitor?.athlete?.shortName ?? ""

        // Fast path: pre-resolution cache or direct synchronous match.
        let hiddenCatIDs = Set(viewModel.categories.filter { $0.isHidden }.map { $0.id })
        if let match = ChannelViewModel.resolveBestMatch(
            home: h, away: a, network: game.broadcastName,
            channels: viewModel.channels,
            hiddenIDs: viewModel.hiddenIDs,
            hiddenCatIDs: hiddenCatIDs,
            epg: viewModel.epgData,
            now: Date(),
            preferredLanguage: viewModel.preferredLanguage,
            preferredQuality: viewModel.preferredQuality
        ) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                viewModel.addToMultiView(match)
                if let idx = viewModel.multiViewSlots.firstIndex(where: { $0?.id == match.id }) {
                    focusedIndex = idx
                }
            }
            return
        }

        // Slow path: kick off smart search; MainView's channelToAutoPlay
        // handler will route the result through playChannel which honors
        // multiViewModeActive.
        viewModel.multiViewModeActive = true
        let sport = scoreViewModel.sportType(for: game)
        viewModel.runSmartSearch(gameID: game.id, home: h, away: a, sport: sport, network: game.broadcastName)
    }

    private func openFullSearch() {
        viewModel.multiViewModeActive = true
        viewModel.searchText = ""
        withAnimation(.spring(response: 0.42, dampingFraction: 0.92)) {
            showFullSearch = true
        }
    }

    private func closeFullSearch() {
        viewModel.multiViewModeActive = false
        viewModel.searchText = ""
        withAnimation(.easeInOut(duration: 0.25)) {
            showFullSearch = false
        }
    }

    /// Dismiss the multi-view overlay. The outer `.blurFade` transition on
    /// the parent's `if showMultiView` already handles the visual fade —
    /// we just flip the binding and let SwiftUI animate.
    private func handleDismiss() {
        withAnimation(.easeInOut(duration: 0.35)) { showMultiView = false }
    }

    /// Choose the most efficient layout for `count` active streams:
    ///   • 0–1 → focus (single big stream + add controls; the mini row is
    ///           hidden when there's nothing to mini-row).
    ///   • 2–4 → equal — every stream renders at the same size, which is
    ///           the best use of screen real estate for true multi-view.
    private func defaultLayout(forStreamCount count: Int) -> MultiViewLayoutMode {
        return count >= 2 ? .equal : .focus
    }
}

// MARK: - Hub Layout

struct MultiViewHubLayout: View {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Binding var focusedIndex: Int
    @Binding var layoutMode: MultiViewLayoutMode
    @Binding var showSearchSheet: Bool
    let activeIndices: [Int]
    let streamsWithAudio: Int
    let topInset: CGFloat
    let bottomInset: CGFloat
    /// Actual leading/trailing safe-area inset — wider on whichever side the
    /// notch sits in landscape. Used to clear the notch with the smallest
    /// possible padding so equal-mode tiles get the most width available.
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    /// Geometry width passed in from the parent. Used to clamp the search
    /// pill's container to the actual screen width — prevents the pill from
    /// drifting off-center when an inner HStack (e.g. the 3-card mini row in
    /// focus mode with 4 streams) measures itself wider than the screen.
    let screenWidth: CGFloat
    let accentColor: Color
    /// When the device is held in landscape, equal mode goes full-bleed —
    /// header and search pill are hidden so every stream can grow as
    /// large as possible while staying clear of the Dynamic Island and the
    /// home indicator.
    let isLandscape: Bool
    let onLiveGameTap: (ESPNEvent) -> Void
    let onSearchTap: () -> Void

    /// True when equal mode should occupy the full screen (no chrome). We
    /// keep the chrome in portrait because there's plenty of vertical room
    /// for it without crushing the grid.
    private var isLandscapeImmersive: Bool {
        layoutMode == .equal && isLandscape
    }

    /// Slots that aren't the focused one — these populate the mini row.
    private var miniIndices: [Int] {
        activeIndices.filter { $0 != focusedIndex }
    }

    /// Channels to surface in the "Add to Multi-View" strip. Recent → favorites
    /// → all, filtering out any channel already on screen.
    private var suggestedChannels: [StreamChannel] {
        let activeIDs = Set(viewModel.multiViewSlots.compactMap { $0?.id })
        var seen = Set<Int>()
        var result: [StreamChannel] = []

        let pools: [[StreamChannel]] = [
            viewModel.recentIDs.compactMap { id in viewModel.channels.first(where: { $0.id == id }) },
            viewModel.channels.filter { viewModel.favoriteIDs.contains($0.id) },
            viewModel.channels
        ]
        for pool in pools {
            for ch in pool where !activeIDs.contains(ch.id) && seen.insert(ch.id).inserted {
                result.append(ch)
                if result.count >= 12 { return result }
            }
        }
        return result
    }

    var body: some View {
        // ONE view tree for all states. The header collapses to height 0 in
        // landscape immersive mode but the EqualStreamGrid below it is the
        // SAME instance in every orientation and every layout mode — that's
        // the architectural fix for the rotation-freeze bug. Switching
        // between focus and equal "modes" used to swap entire subtrees,
        // which forced KSPlayer's view to be re-parented to fresh
        // containers each time. With one stable tree, only the per-tile
        // rect changes — players just resize, never re-parent.
        VStack(spacing: 0) {
            MultiViewHubHeader(
                streamsCount: activeIndices.count,
                streamsWithAudio: streamsWithAudio,
                layoutMode: $layoutMode,
                onAddStream: onSearchTap
            )
            .padding(.bottom, isLandscapeImmersive ? 0 : 14)
            .frame(height: isLandscapeImmersive ? 0 : nil)
            .clipped()

            equalStreams
                // Landscape: clear the notch with a 4 pt floor for the
                // rounded corners. Portrait: leave room above the search
                // pill at the bottom (~60 pt).
                .padding(.leading, isLandscapeImmersive ? max(leadingInset, 4) : 0)
                .padding(.trailing, isLandscapeImmersive ? max(trailingInset, 4) : 0)
                .padding(.top, 4)
                .padding(.bottom, isLandscapeImmersive ? 4 : (bottomInset + 60))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: screenWidth, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if !isLandscapeImmersive {
                HStack(spacing: 0) {
                    MultiViewSearchPill(onTap: onSearchTap)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 0)
                }
                .frame(width: screenWidth)
            }
        }
    }

    // MARK: Stream area variants

    /// 1 large featured stream + horizontal mini row.
    @ViewBuilder private var focusStreams: some View {
        if let idx = activeIndices.first(where: { $0 == focusedIndex }) ?? activeIndices.first,
           let channel = viewModel.multiViewSlots[idx] {
            FeaturedStreamCard(
                channel: channel,
                slotIndex: idx,
                scoreViewModel: scoreViewModel,
                viewModel: viewModel
            )
            .padding(.horizontal, 20)
        } else {
            FeaturedEmptyCard()
                .padding(.horizontal, 20)
        }

        if !miniIndices.isEmpty {
            MiniStreamRow(
                indices: miniIndices,
                viewModel: viewModel,
                onFocus: { i in
                    viewModel.triggerSelectionHaptic()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        focusedIndex = i
                    }
                }
            )
        }
    }

    /// The single stream grid used in every state — the active layout mode
    /// (.focus = 1 big + smalls; .equal = tiled grid) is passed through so
    /// the grid can re-arrange tiles internally instead of being unmounted
    /// and remounted between modes.
    @ViewBuilder private var equalStreams: some View {
        if activeIndices.isEmpty {
            FeaturedEmptyCard()
                .padding(.horizontal, 20)
        } else {
            EqualStreamGrid(
                activeIndices: activeIndices,
                focusedIndex: $focusedIndex,
                viewModel: viewModel,
                scoreViewModel: scoreViewModel,
                layout: effectiveLayout
            )
            .padding(.horizontal, 6)
        }
    }

    /// Resolves the layout mode for the current orientation. `layoutMode` is
    /// the user's explicit choice (set via the menu in the header); for the
    /// default case it's chosen orientation-first: portrait → focus,
    /// landscape → equal. Changing this never causes view-tree destruction
    /// — only EqualStreamGrid's internal rects update.
    private var effectiveLayout: MultiViewLayoutMode {
        // When the user explicitly picks a layout, honor it. Otherwise pick
        // the orientation default.
        return layoutMode
    }
}

// MARK: - Hub Header

struct MultiViewHubHeader: View {
    let streamsCount: Int
    let streamsWithAudio: Int
    @Binding var layoutMode: MultiViewLayoutMode
    let onAddStream: () -> Void

    private let inlineTileSize: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Multi-View")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                            .opacity(streamsCount > 0 ? 1 : 0)
                        Text(subtitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Button(action: onAddStream) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: inlineTileSize, height: inlineTileSize)
                        .modifier(GlassEffect(cornerRadius: inlineTileSize / 2, isSelected: false, accentColor: nil))
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(MultiViewLayoutMode.allCases) { mode in
                        Button {
                            // easeInOut (no spring overshoot) keeps the
                            // rect-change animation in EqualStreamGrid
                            // monotonic. A spring with light damping was
                            // briefly driving rect height/width below zero
                            // during the focus→equal swap, which combined
                            // with KSPlayer view re-parenting could crash.
                            withAnimation(.easeInOut(duration: 0.3)) {
                                layoutMode = mode
                            }
                        } label: {
                            Label(mode.label, systemImage: mode.icon)
                            if mode == layoutMode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    Image(systemName: layoutMode.icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: inlineTileSize, height: inlineTileSize)
                        .modifier(GlassEffect(cornerRadius: inlineTileSize / 2, isSelected: false, accentColor: nil))
                }
                .tint(.white)
            }
            .padding(.horizontal, 20)
        }
    }

    private var subtitle: String {
        if streamsCount == 0 { return "No streams yet" }
        let s = streamsCount == 1 ? "stream" : "streams"
        return "\(streamsCount) \(s) · \(streamsWithAudio) with audio"
    }
}

// MARK: - Featured Stream Card

/// Hero card at the top of the hub. Plays the focused stream with sound,
/// shows a LIVE badge, an audio indicator, and overlay controls. The control
/// overlay auto-hides 4 s after the user interacts; tapping the card shows it
/// again.
struct FeaturedStreamCard: View {
    let channel: StreamChannel
    let slotIndex: Int
    @ObservedObject var scoreViewModel: ScoreViewModel
    @ObservedObject var viewModel: ChannelViewModel

    @State private var isPlaying = true
    @State private var showInfoSheet = false
    @State private var showControls = true
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = width * (9.0 / 16.0)

            ZStack {
                // Logo backdrop (visible until the video frame arrives)
                ChannelLogoBackdrop(channel: channel)

                // Video
                SmartGridPlayer(
                    url: URL(string: channel.streamURL) ?? URL(string: "about:blank")!,
                    isMuted: false,
                    isPlaying: $isPlaying
                )
                .allowsHitTesting(false)

                // Vignettes for legibility (only while controls visible)
                VStack {
                    LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 70)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 90)
                }
                .opacity(showControls ? 1 : 0)

                // Top bar
                VStack {
                    HStack(alignment: .top) {
                        LiveStatusBadge(channel: channel, scoreViewModel: scoreViewModel)
                        Spacer()
                        AudioChip(isOn: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    Spacer()
                }
                .opacity(showControls ? 1 : 0)

                // Bottom bar
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        ChannelChip(channel: channel)
                        Spacer()
                        GlassIconButton(systemName: "xmark") {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                viewModel.updateMultiViewSlot(index: slotIndex, channel: nil)
                            }
                        }
                        GlassIconButton(systemName: "info") {
                            showInfoSheet = true
                            scheduleHide()
                        }
                        Button(action: {
                            isPlaying.toggle()
                            scheduleHide()
                        }) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(Color.white))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .opacity(showControls ? 1 : 0)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 18, x: 0, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showControls.toggle()
                }
                if showControls { scheduleHide() } else { hideWorkItem?.cancel() }
            }
            .onAppear { scheduleHide() }
            .onDisappear { hideWorkItem?.cancel() }
            .animation(.easeInOut(duration: 0.25), value: showControls)
            .sheet(isPresented: $showInfoSheet) {
                ChannelInfoSheet(
                    channel: channel,
                    program: viewModel.getCurrentProgram(for: channel)
                )
                .presentationDetents([.medium])
            }
        }
        .aspectRatio(16.0/9.0, contentMode: .fit)
    }

    /// Cancels any pending hide and re-arms a 4-second auto-hide. Called on
    /// every user interaction so controls stay up while you're tapping.
    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }
}

/// Empty state shown when no streams are queued yet. Graphic-only —
/// the + button in the header is how the user adds their first stream.
struct FeaturedEmptyCard: View {
    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.white.opacity(0.95))
                .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)

            VStack(spacing: 8) {
                Text("Start your Multi-View")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                Text("Watch up to four channels side by side.\nTap + above to add your first stream.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Equal Stream Grid (same-size live cards filling the screen)

/// All active streams rendered at the same size, filling the available area.
/// Audio is routed to whichever card is "focused" (tapped); other cards are
/// muted.
///
/// Layout adapts to the active count so single/two/three-stream cases also
/// take advantage of the extra real estate:
///   • 1 stream  → fills the entire frame
///   • 2 streams → side-by-side (or stacked in portrait)
///   • 3 streams → 1 large + 2 stacked
///   • 4 streams → 2×2 grid
///
/// Cards are rendered into a fixed-shape ZStack with computed rects so the
/// same `EqualStreamCard` view at slot index `N` stays at the same SwiftUI
/// position across orientation/count changes — only its frame changes.
/// That preserves the underlying `SmartGridPlayer`'s state so streams keep
/// playing through layout changes instead of buffering from scratch.
struct EqualStreamGrid: View {
    let activeIndices: [Int]
    @Binding var focusedIndex: Int
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    /// When `.focus`, the grid arranges tiles as 1 big (focused) + (N-1)
    /// small along the bottom — same KSPlayer views, just different rects.
    /// When `.equal`, uses the count-based equal-area layouts. Changing this
    /// only triggers rect animations, not view tree destruction.
    let layout: MultiViewLayoutMode

    // Tighter inter-tile gutter so each video gets more pixels. Visually still
    // reads as a grid since each tile has its own rounded-corner clip and
    // overlay chrome.
    private let spacing: CGFloat = 4

    // Drag-to-swap state — all managed here so only one card floats at a time.
    @State private var draggingSlot: Int? = nil
    @State private var dragOffset: CGSize = .zero
    @State private var dropTargetSlot: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let containerSize = geo.size
            ZStack(alignment: .topLeading) {
                ForEach(activeIndices, id: \.self) { slot in
                    if let channel = viewModel.multiViewSlots[slot] {
                        let rect = rectFor(
                            slot: slot,
                            in: containerSize,
                            isLandscape: isLandscape
                        )
                        let isDragging = draggingSlot == slot
                        EqualStreamCard(
                            channel: channel,
                            isFocused: focusedIndex == slot,
                            scoreViewModel: scoreViewModel,
                            fillsAvailableSpace: true,
                            isDropTarget: dropTargetSlot == slot,
                            onTap: {
                                viewModel.triggerSelectionHaptic()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    focusedIndex = slot
                                }
                            },
                            onRemove: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    viewModel.updateMultiViewSlot(index: slot, channel: nil)
                                }
                            }
                        )
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                        .position(
                            x: rect.midX + (isDragging ? dragOffset.width : 0),
                            y: rect.midY + (isDragging ? dragOffset.height : 0)
                        )
                        .scaleEffect(isDragging ? 1.07 : (dropTargetSlot == slot ? 0.93 : 1.0))
                        .opacity(isDragging ? 0.88 : 1.0)
                        .zIndex(isDragging ? 10 : 1)
                        .id("equal-slot-\(slot)")
                        // Use a critically-damped easeInOut for rect changes
                        // instead of a spring. When the user adds a 4th
                        // stream and the grid reshapes from 3-tile (1+2) to
                        // 2×2, the previous spring overshoot read as a brief
                        // "zoom in then zoom out" while existing tiles
                        // bounced toward their new frames. easeInOut keeps
                        // the transition smooth without the visual rebound.
                        .animation(isDragging ? nil : .easeInOut(duration: 0.28), value: rect)
                        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isDragging)
                        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: dropTargetSlot)
                        // Canonical SwiftUI drag-to-reorder gesture: a sequenced
                        // composition of LongPressGesture → DragGesture. .gesture()
                        // uses the lowest priority so the card's inner .onTapGesture
                        // still wins for quick taps; the long press only recognizes
                        // after 0.4 s of holding, at which point the drag phase
                        // takes over the same touch event with no re-grab needed.
                        // The X button (a `Button` subview) has its own recognizer
                        // and isn't blocked by this gesture.
                        .gesture(
                            LongPressGesture(minimumDuration: 0.4)
                                .sequenced(before: DragGesture(minimumDistance: 0))
                                .onChanged { value in
                                    switch value {
                                    case .first:
                                        break
                                    case .second(let pressed, let drag):
                                        guard pressed else { return }
                                        if draggingSlot != slot {
                                            draggingSlot = slot
                                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        }
                                        if let drag = drag {
                                            dragOffset = drag.translation
                                            dropTargetSlot = nearestActiveSlot(
                                                to: CGPoint(
                                                    x: rect.midX + drag.translation.width,
                                                    y: rect.midY + drag.translation.height
                                                ),
                                                excluding: slot,
                                                in: containerSize,
                                                isLandscape: isLandscape
                                            )
                                        }
                                    }
                                }
                                .onEnded { value in
                                    defer {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            draggingSlot = nil
                                            dragOffset = .zero
                                            dropTargetSlot = nil
                                        }
                                    }
                                    if case .second(_, let drag) = value,
                                       let drag = drag,
                                       draggingSlot == slot,
                                       let to = dropTargetSlot, to != slot {
                                        let dist = sqrt(pow(drag.translation.width, 2) + pow(drag.translation.height, 2))
                                        guard dist >= 5 else { return }
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                            viewModel.swapMultiViewSlots(from: slot, to: to)
                                        }
                                    }
                                }
                        )
                    }
                }
            }
        }
    }

    /// Returns the slot index whose rect contains `point`, excluding `excluded`.
    private func nearestActiveSlot(to point: CGPoint, excluding excluded: Int, in size: CGSize, isLandscape: Bool) -> Int? {
        for slot in activeIndices {
            guard slot != excluded else { continue }
            let r = rectFor(slot: slot, in: size, isLandscape: isLandscape)
            if r.contains(point) { return slot }
        }
        return nil
    }

    /// Returns the on-screen rect for `slot`. Combines the active layout
    /// mode (`.focus` → 1 big focused + others small; `.equal` → tiled grid)
    /// with the current count and orientation. Changing the inputs never
    /// destroys any view — only the returned rect changes, so SwiftUI
    /// animates the existing EqualStreamCard's frame instead of unmounting
    /// it (which is what was destabilising KSPlayer on prior rotations).
    private func rectFor(slot: Int, in size: CGSize, isLandscape: Bool) -> CGRect {
        // Guard against transient zero-or-negative container sizes that can
        // briefly happen during orientation changes while SwiftUI is still
        // resolving the new geometry. A 1×1 sentinel keeps the math below
        // from producing negative widths or heights.
        let w = max(size.width, 1)
        let h = max(size.height, 1)
        let s = spacing
        let count = activeIndices.count

        // Focus layout: 1 big focused tile + (count-1) small tiles. Same
        // shape in both orientations — the big tile gets ~60% of the cross
        // axis, smalls split the remainder along the bottom (portrait) or
        // right (landscape).
        if layout == .focus && count >= 2 {
            let isFocused = (slot == focusedIndex)
            let nonFocused = activeIndices.filter { $0 != focusedIndex }
            let pos = nonFocused.firstIndex(of: slot) ?? 0
            let smallCount = max(count - 1, 1)

            if isLandscape {
                // Big left, smalls stacked right
                let mainW = (w * 0.65) - s / 2
                let smallStripW = w - mainW - s
                let smallH = (h - CGFloat(smallCount - 1) * s) / CGFloat(smallCount)
                if isFocused {
                    return CGRect(x: 0, y: 0, width: mainW, height: h)
                }
                return CGRect(
                    x: mainW + s,
                    y: CGFloat(pos) * (smallH + s),
                    width: smallStripW,
                    height: smallH
                )
            } else {
                // Big top, smalls in a row along the bottom
                let mainH = (h * 0.6) - s / 2
                let smallStripH = h - mainH - s
                let smallW = (w - CGFloat(smallCount - 1) * s) / CGFloat(smallCount)
                if isFocused {
                    return CGRect(x: 0, y: 0, width: w, height: mainH)
                }
                return CGRect(
                    x: CGFloat(pos) * (smallW + s),
                    y: mainH + s,
                    width: smallW,
                    height: smallStripH
                )
            }
        }

        // Equal layout — same logic as before, keyed off rank.
        let rank = activeIndices.firstIndex(of: slot) ?? 0
        switch count {
        case 1:
            return CGRect(x: 0, y: 0, width: w, height: h)
        case 2:
            if isLandscape {
                let cw = (w - s) / 2
                return CGRect(x: CGFloat(rank) * (cw + s), y: 0, width: cw, height: h)
            } else {
                let ch = (h - s) / 2
                return CGRect(x: 0, y: CGFloat(rank) * (ch + s), width: w, height: ch)
            }
        case 3:
            if isLandscape {
                let mainW = (w * 0.6) - s / 2
                let sideW = w - mainW - s
                let sideH = (h - s) / 2
                if rank == 0 { return CGRect(x: 0, y: 0, width: mainW, height: h) }
                if rank == 1 { return CGRect(x: mainW + s, y: 0, width: sideW, height: sideH) }
                return CGRect(x: mainW + s, y: sideH + s, width: sideW, height: sideH)
            } else {
                let mainH = (h * 0.6) - s / 2
                let bottomH = h - mainH - s
                let bottomW = (w - s) / 2
                if rank == 0 { return CGRect(x: 0, y: 0, width: w, height: mainH) }
                if rank == 1 { return CGRect(x: 0, y: mainH + s, width: bottomW, height: bottomH) }
                return CGRect(x: bottomW + s, y: mainH + s, width: bottomW, height: bottomH)
            }
        default:
            // 4 cells: 2×2 grid
            let cw = (w - s) / 2
            let ch = (h - s) / 2
            let row = CGFloat(rank / 2)
            let col = CGFloat(rank % 2)
            return CGRect(x: col * (cw + s), y: row * (ch + s), width: cw, height: ch)
        }
    }
}

/// Equal-size live card used in the 2×2 layout. Tap to focus (route audio),
/// long-press for remove menu.
///
/// When `fillsAvailableSpace` is true the card drops its 16:9 aspect-ratio
/// constraint and stretches to whatever frame its parent hands it — the
/// underlying video layer already handles letterboxing internally.
struct EqualStreamCard: View {
    let channel: StreamChannel
    let isFocused: Bool
    @ObservedObject var scoreViewModel: ScoreViewModel
    var fillsAvailableSpace: Bool = false
    var isDropTarget: Bool = false
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var isPlaying = true
    /// Chrome (LIVE dot, speaker icon, channel chip) auto-hides 4 s after
    /// the user last interacted with this card.
    @State private var showOverlays = true
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack {
            ChannelLogoBackdrop(channel: channel)

            SmartGridPlayer(
                url: URL(string: channel.streamURL) ?? URL(string: "about:blank")!,
                isMuted: !isFocused,
                isPlaying: $isPlaying
            )
            .allowsHitTesting(false)

            // All chrome lives inside a single group whose opacity is
            // driven by `showOverlays`, so the LIVE badge, speaker chip,
            // and channel chip fade out together every 4 seconds.
            ZStack {
                VStack {
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 50)
                }

                VStack {
                    HStack(alignment: .top) {
                        LiveDot()
                        Spacer()
                        // X closes this stream; always visible in the overlay.
                        Button(action: onRemove) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .modifier(MVCircleGlass())
                        }
                        .buttonStyle(.plain)
                        Image(systemName: isFocused ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 24, height: 24)
                            .modifier(MVCircleGlass())
                    }
                    .padding(8)
                    Spacer()
                }

                VStack {
                    Spacer()
                    HStack {
                        ChannelChip(channel: channel)
                        Spacer()
                    }
                    .padding(8)
                }
            }
            .opacity(showOverlays ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: showOverlays)
        }
        .applyIf(!fillsAvailableSpace) { $0.aspectRatio(16.0/9.0, contentMode: .fit) }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    isDropTarget ? Color.white : (isFocused ? Color.white.opacity(0.85) : Color.white.opacity(0.08)),
                    lineWidth: isDropTarget ? 2.5 : (isFocused ? 2 : 0.5)
                )
                .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            if !showOverlays {
                showOverlays = true
            } else {
                onTap()
            }
            scheduleHide()
        }
        .onAppear { scheduleHide() }
        .onDisappear { hideWorkItem?.cancel() }
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.25)) { showOverlays = false }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }
}

// MARK: - Mini Stream Row

struct MiniStreamRow: View {
    let indices: [Int]
    @ObservedObject var viewModel: ChannelViewModel
    let onFocus: (Int) -> Void

    private let spacing: CGFloat = 10
    private let horizontalPadding: CGFloat = 20

    var body: some View {
        // Non-scrolling row — each cell opts into flex layout via
        // `.frame(maxWidth: .infinity)`, so HStack splits the row width
        // evenly. Combined with `.aspectRatio(16/9, .fit)` per cell, the
        // row self-sizes for any screen width and any stream count. No
        // trailing Add tile here — the `+` lives in the header now.
        HStack(spacing: spacing) {
            ForEach(indices, id: \.self) { i in
                if let channel = viewModel.multiViewSlots[i] {
                    MiniStreamCard(
                        channel: channel,
                        onTap: { onFocus(i) },
                        onRemove: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                viewModel.updateMultiViewSlot(index: i, channel: nil)
                            }
                        }
                    )
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    // Stable id keyed to the slot so SwiftUI keeps the
                    // same MiniStreamCard (and its SmartGridPlayer)
                    // across count/layout changes.
                    .id("mini-slot-\(i)")
                }
            }
        }
        // Force the HStack to span the parent's full width. Without this
        // the HStack would size to its children (which use maxWidth ∞ but
        // can collapse in some layout passes after rotation), causing the
        // 3-card mini row to appear shifted toward one side relative to
        // the featured card above it.
        .frame(maxWidth: .infinity)
        .padding(.horizontal, horizontalPadding)
    }
}

struct MiniStreamCard: View {
    let channel: StreamChannel
    let onTap: () -> Void
    let onRemove: () -> Void

    /// Drives `SmartGridPlayer`'s `isPlaying` binding. Mini cards always play
    /// (just muted) so the user gets a live preview of every active stream,
    /// not a static logo.
    @State private var isPlaying = true
    /// 4-second auto-hiding chrome (LIVE dot + speaker icon + channel name).
    /// Tap brings it back and re-arms the timer.
    @State private var showOverlays = true
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack {
            // Logo backdrop is rendered behind the player so the card still
            // looks reasonable while the first frame is decoding.
            ChannelLogoBackdrop(channel: channel)

            // Live video preview — muted, since audio belongs to whichever
            // slot is currently focused. allowsHitTesting(false) keeps the
            // tap gesture on the wrapping card working.
            if let url = URL(string: channel.streamURL) {
                SmartGridPlayer(url: url, isMuted: true, isPlaying: $isPlaying)
                    .allowsHitTesting(false)
            }

            // Chrome — mirrors FeaturedStreamCard so top/bottom streams share
            // the same overlay vocabulary: top-left LiveDot, top-right speaker
            // chip, bottom-left ChannelChip, bottom-right X button. Sizes are
            // scaled down for the mini footprint.
            ZStack {
                VStack {
                    LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 44)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 56)
                }

                VStack {
                    HStack(alignment: .top) {
                        LiveDot()
                        Spacer()
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 24, height: 24)
                            .modifier(MVCircleGlass())
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    Spacer()
                    HStack(spacing: 8) {
                        ChannelChip(channel: channel)
                        Spacer()
                        Button(action: onRemove) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .modifier(MVCircleGlass())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
            .opacity(showOverlays ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: showOverlays)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            if !showOverlays {
                showOverlays = true
                scheduleHide()
            } else {
                onTap()
                scheduleHide()
            }
        }
        .onAppear { scheduleHide() }
        .onDisappear { hideWorkItem?.cancel() }
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.25)) { showOverlays = false }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }
}

// MARK: - Channel Logo Backdrop (the visual pattern used across the app)

/// Mirrors the `SearchChannelContent` / `HorizontalPreviewList` look — a
/// blurred channel-icon backdrop with the same icon on top at a sensible size.
struct ChannelLogoBackdrop: View {
    let channel: StreamChannel
    var foregroundPadding: CGFloat = 16
    /// 0 hides the foreground icon (useful for the featured card, where the
    /// video covers everything once it starts playing).
    var showForegroundIcon: Bool = true

    var body: some View {
        ZStack {
            CachedAsyncImage(urlString: channel.icon ?? "", size: nil)
                .blur(radius: 22)
                .opacity(0.45)
                .clipped()
            if showForegroundIcon {
                CachedAsyncImage(urlString: channel.icon ?? "", size: nil)
                    .padding(foregroundPadding)
            }
        }
    }
}

// MARK: - Live Scores Strip (uses LiveGameCard from MainView)

struct LiveScoresStrip: View {
    @ObservedObject var scoreViewModel: ScoreViewModel
    let onTap: (ESPNEvent) -> Void
    @State private var showAllScoresSheet = false

    var body: some View {
        if scoreViewModel.allLiveGames.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Live scores")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button(action: { showAllScoresSheet = true }) {
                        Text("See all")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.blue)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)

                // Reuses the exact same card the home screen uses. Tap adds
                // the broadcasting channel to multi-view.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(scoreViewModel.allLiveGames) { game in
                            LiveGameCard(game: game, accentColor: .blue)
                                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .onTapGesture { onTap(game) }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .sheet(isPresented: $showAllScoresSheet) {
                AllLiveScoresSheet(games: scoreViewModel.allLiveGames, onTap: { game in
                    showAllScoresSheet = false
                    // Defer the tap so the sheet dismiss animation completes
                    // before we mutate the multi-view slots (otherwise SwiftUI
                    // discards the dismissal).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onTap(game) }
                })
            }
        }
    }
}

struct AllLiveScoresSheet: View {
    let games: [ESPNEvent]
    let onTap: (ESPNEvent) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(games) { game in
                        LiveGameCard(game: game, accentColor: .blue)
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .onTapGesture { onTap(game) }
                    }
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Live Scores")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Suggested Channels Strip

struct SuggestedChannelsStrip: View {
    let channels: [StreamChannel]
    @ObservedObject var viewModel: ChannelViewModel
    let onAdd: (StreamChannel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to Multi-View")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(channels) { channel in
                        SuggestedChannelCard(channel: channel, viewModel: viewModel, onAdd: { onAdd(channel) })
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct SuggestedChannelCard: View {
    let channel: StreamChannel
    @ObservedObject var viewModel: ChannelViewModel
    let onAdd: () -> Void

    var body: some View {
        // The whole card is now the tap target — no more blue floating
        // plus circle. Tapping anywhere adds the channel to multi-view.
        Button(action: onAdd) {
            VStack(alignment: .leading, spacing: 8) {
                ChannelLogoBackdrop(channel: channel, foregroundPadding: 18)
                    .frame(width: 180, height: 101)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .modifier(GlassEffect(cornerRadius: 12, isSelected: false, accentColor: nil))

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if let prog = viewModel.getCurrentProgram(for: channel) {
                        Text(prog.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    } else {
                        Text("Live now")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .frame(width: 172, alignment: .topLeading)
                .padding(.horizontal, 4)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search Pill (matches home-screen bottomSearchPill exactly)

struct MultiViewSearchPill: View {
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Search")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .modifier(MVCapsuleGlass())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Small Reusable Bits

/// Pulsing red dot used on every "live now" chip / badge in this screen.
struct LiveDot: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 0.5 : 1)
                .scaleEffect(pulse ? 0.9 : 1.0)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
            Text("LIVE")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.red.opacity(0.85)))
        .onAppear { pulse = true }
    }
}

/// LIVE badge that surfaces matching ESPN score/clock info when we can find
/// a live game broadcasting on this channel.
struct LiveStatusBadge: View {
    let channel: StreamChannel
    @ObservedObject var scoreViewModel: ScoreViewModel
    var body: some View {
        let match = scoreViewModel.liveGame(for: channel, currentEPGTitle: nil)
        HStack(spacing: 8) {
            LiveDot()
            if let m = match {
                Text(scoreLine(for: m))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .modifier(MVCapsuleGlass())
            }
        }
    }
    private func scoreLine(for game: ESPNEvent) -> String {
        let away = game.awayCompetitor?.team?.abbreviation ?? ""
        let home = game.homeCompetitor?.team?.abbreviation ?? ""
        let aScore = game.awayCompetitor?.score ?? ""
        let hScore = game.homeCompetitor?.score ?? ""
        let clock = game.status.type.detail
        if !away.isEmpty && !home.isEmpty {
            return "\(away) \(aScore) — \(hScore) \(home) · \(clock)"
        }
        return clock
    }
}

struct AudioChip: View {
    let isOn: Bool
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 11, weight: .bold))
            Text("Audio")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .modifier(MVCapsuleGlass())
    }
}

struct ChannelChip: View {
    let channel: StreamChannel
    var body: some View {
        HStack(spacing: 8) {
            CachedAsyncImage(urlString: channel.icon ?? "", size: CGSize(width: 22, height: 22))
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(channel.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .modifier(MVCapsuleGlass())
    }
}

struct GlassIconButton: View {
    let systemName: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .modifier(MVCircleGlass())
        }
        .buttonStyle(.plain)
    }
}

struct ChannelInfoSheet: View {
    let channel: StreamChannel
    let program: EPGProgram?
    @Environment(\.dismiss) private var dismiss

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 14) {
                CachedAsyncImage(urlString: channel.icon ?? "", size: CGSize(width: 56, height: 56))
                    .frame(width: 56, height: 56)
                    .cornerRadius(12)
                    .clipped()
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                        .font(.title3.weight(.bold))
                    if let prog = program {
                        Text(prog.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Streaming live")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
            }
            .padding()

            Divider()

            // Program detail
            if let prog = program {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Time range
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("\(Self.timeFmt.string(from: prog.start)) – \(Self.timeFmt.string(from: prog.stop))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        // Description
                        if let desc = prog.description, !desc.isEmpty {
                            Text(desc)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("No description available.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "tv.slash")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No guide information available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Search Sheet (unchanged)

struct MultiViewSearchSheet: View {
    @ObservedObject var viewModel: ChannelViewModel
    var onSelect: (StreamChannel) -> Void
    @State private var localSearchText = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Stream").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.fontWeight(.bold)
            }
            .padding()

            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.gray)
                TextField("Search channels...", text: $localSearchText)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                if !localSearchText.isEmpty {
                    Button(action: { localSearchText = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(10)
            .padding(.horizontal)
            .padding(.bottom, 10)

            List {
                let res = viewModel.channels.filter {
                    localSearchText.isEmpty || $0.name.localizedCaseInsensitiveContains(localSearchText)
                }
                ForEach(res.prefix(100)) { c in
                    Button(action: { onSelect(c) }) {
                        HStack(spacing: 12) {
                            CachedAsyncImage(urlString: c.icon ?? "", size: CGSize(width: 35, height: 35))
                                .frame(width: 35, height: 35)
                                .padding(2)
                                .cornerRadius(6)
                                .clipped()
                            Text(c.name).font(.body).foregroundColor(.primary)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Smart Player

/// Thin SwiftUI wrapper around the per-URL player entries owned by
/// `MultiViewPlayerPool`. The pool keeps the underlying `NebuloKSVideoPlayerView`
/// (or VLC fallback) alive across view rebuilds, so flipping orientation
/// or switching between focus and equal layouts re-parents the existing
/// player instead of tearing it down and re-buffering from scratch.
struct SmartGridPlayer: UIViewRepresentable {
    let url: URL
    let isMuted: Bool
    @Binding var isPlaying: Bool

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        MultiViewPlayerPool.shared.mount(
            url: url,
            in: container,
            isMuted: isMuted,
            isPlaying: isPlaying
        )
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Re-mount in case SwiftUI rebuilt the container (different cell,
        // different layout, etc.). The pool detects a same-URL entry and
        // re-parents the existing player rather than restarting it.
        MultiViewPlayerPool.shared.mount(
            url: url,
            in: uiView,
            isMuted: isMuted,
            isPlaying: isPlaying
        )
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        // Intentionally do nothing — releasing the underlying player is the
        // pool's job, triggered by slot changes or multi-view dismissal.
    }
}

// MARK: - Multi-View Player Pool

/// Per-URL store of `NebuloKSVideoPlayerView` / `VLCMediaPlayer` instances
/// that survives SwiftUI view rebuilds. Each `SmartGridPlayer` defers to
/// this pool — when SwiftUI rebuilds (orientation flip, layout switch,
/// count change), the pool detects an existing entry and re-parents the
/// already-playing player into the new container UIView instead of
/// re-creating it. Streams keep playing without reloading.
///
/// Lifecycle:
///   • `mount(url:, in:, isMuted:, isPlaying:)` — get-or-create, re-parent,
///     apply mute/play.
///   • `reconcile(activeURLs:)` — release entries for URLs not currently in
///     any multi-view slot.
///   • `releaseAll()` — tear everything down (called on multi-view close).
@MainActor
final class MultiViewPlayerPool {
    static let shared = MultiViewPlayerPool()
    private init() {}

    /// Per-URL playback state. Reference type so it can be captured weakly
    /// by KSPlayer callbacks and the watchdog timer.
    fileprivate final class Entry {
        let url: URL
        var ksPlayer: NebuloKSVideoPlayerView?
        var vlcPlayer: VLCMediaPlayer?
        var isVLCFallback = false
        var retryCount = 0
        var wantsPlaying = true
        /// Latest desired mute state. Stored on the entry so the deferred
        /// play() callbacks and the watchdog can re-apply it after the
        /// AVPlayer becomes ready — otherwise the very first applyMute call
        /// would silently no-op (avPlayer == nil at mount time) and the
        /// stream would start playing audio even when the card is muted.
        var wantsMuted: Bool = true
        var watchdog: Timer?

        init(url: URL) { self.url = url }
    }

    private var entries: [String: Entry] = [:]

    /// Configures audio session + KSOptions exactly once per app launch
    /// so we don't re-apply them on every mount.
    private var didConfigureGlobals = false

    /// Creates the player for `url` if needed, then re-parents it to
    /// `container`. Safe to call repeatedly with the same URL — the pool
    /// only spins up one player per URL.
    func mount(url: URL, in container: UIView, isMuted: Bool, isPlaying: Bool) {
        configureGlobalsIfNeeded()

        let key = url.absoluteString
        let entry: Entry
        if let existing = entries[key] {
            entry = existing
        } else {
            entry = Entry(url: url)
            entries[key] = entry
            startKSPlayer(for: entry)
            startWatchdog(for: entry)
        }

        entry.wantsPlaying = isPlaying
        entry.wantsMuted = isMuted
        attachPlayerView(of: entry, to: container)
        applyMuteAndPlay(entry: entry, isMuted: isMuted, isPlaying: isPlaying)
    }

    /// Releases every entry whose URL isn't in `activeURLs`. Call from
    /// MultiViewScreen whenever `multiViewSlots` changes so we don't
    /// keep streaming channels the user removed.
    func reconcile(activeURLs: Set<String>) {
        for key in Array(entries.keys) where !activeURLs.contains(key) {
            if let entry = entries.removeValue(forKey: key) {
                cleanup(entry)
            }
        }
    }

    /// Tears down every cached player. Called on `MultiViewScreen.onDisappear`.
    func releaseAll() {
        let all = Array(entries.values)
        entries.removeAll()
        for entry in all { cleanup(entry) }
    }

    // MARK: Private helpers

    private func configureGlobalsIfNeeded() {
        guard !didConfigureGlobals else { return }
        didConfigureGlobals = true

        // `.mixWithOthers` lets all 4 streams hold AVPlayer instances
        // simultaneously without auto-pausing each other.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .moviePlayback,
            options: [.allowAirPlay, .allowBluetoothA2DP, .mixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

        KSOptions.isAutoPlay = true
        KSOptions.isSecondOpen = true
    }

    private func startKSPlayer(for entry: Entry) {
        let player = NebuloKSVideoPlayerView()
        player.translatesAutoresizingMaskIntoConstraints = false
        player.backgroundColor = .black

        let options = KSOptions()
        let resource = KSPlayerResource(url: entry.url, options: options)
        player.set(resource: resource)
        // Belt-and-suspenders: explicit play() even with isAutoPlay = true.
        player.play()

        // Capture entry weakly so we can self-reference state without
        // creating a retain cycle; the pool's dictionary owns the strong
        // reference and lives as long as the URL is in any slot.
        player.onStateChange = { [weak entry] state in
            guard let entry = entry else { return }
            if state == .error {
                Task { @MainActor in MultiViewPlayerPool.shared.handleKSFailure(for: entry) }
            } else if state == .paused, entry.wantsPlaying {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak entry] in
                    guard let entry = entry, entry.wantsPlaying else { return }
                    entry.ksPlayer?.play()
                }
            }
        }
        player.onFinish = { [weak entry] error in
            guard let entry = entry else { return }
            if error != nil {
                Task { @MainActor in MultiViewPlayerPool.shared.handleKSFailure(for: entry) }
            } else if entry.wantsPlaying {
                if let p = entry.ksPlayer {
                    p.set(resource: KSPlayerResource(url: entry.url))
                    p.play()
                }
            }
        }
        entry.ksPlayer = player
    }

    private func startWatchdog(for entry: Entry) {
        entry.watchdog?.invalidate()
        // Faster (0.3 s) watchdog to recover stalled streams quickly. With 4
        // simultaneous players competing for bandwidth, individual streams
        // pause more often, so we re-kick them aggressively. If the AVPlayer
        // hasn't been initialised yet (KSPlayer still resolving the
        // resource), we still call `play()` on the KSPlayer wrapper —
        // play() is idempotent and queues the request until the player is
        // ready.
        //
        // The watchdog also reaffirms the desired mute state every tick.
        // applyMuteAndPlay only sets isMuted when the AVPlayer is ready, so
        // for newly-mounted streams the very first mute call is a no-op
        // and the stream would otherwise start playing audio in the
        // background (every card audible at once). Reaffirming here means
        // the right mute lands as soon as the AVPlayer exists.
        entry.watchdog = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak entry] _ in
            guard let entry = entry, entry.wantsPlaying else { return }
            if entry.isVLCFallback {
                if let vp = entry.vlcPlayer {
                    if let audio = vp.audio { audio.volume = entry.wantsMuted ? 0 : 100 }
                    if !vp.isPlaying { vp.play() }
                }
            } else if let player = entry.ksPlayer {
                if let avPlayer = player.playerLayer?.player {
                    avPlayer.isMuted = entry.wantsMuted
                    if let realPlayer = avPlayer as? AVPlayer {
                        realPlayer.volume = entry.wantsMuted ? 0 : 1.0
                    }
                    if !avPlayer.isPlaying { player.play() }
                } else {
                    // AVPlayer not ready yet — keep kicking the wrapper.
                    player.play()
                }
            }
        }
    }

    private func attachPlayerView(of entry: Entry, to container: UIView) {
        if entry.isVLCFallback {
            entry.vlcPlayer?.drawable = container
            return
        }
        guard let player = entry.ksPlayer else { return }
        // No-op if already parented to this container.
        if player.superview === container { return }
        player.removeFromSuperview()
        container.addSubview(player)
        NSLayoutConstraint.activate([
            player.topAnchor.constraint(equalTo: container.topAnchor),
            player.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            player.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        container.layoutIfNeeded()
        // Re-parenting triggers KSPlayer UIView lifecycle hooks that can
        // internally pause the stream. Fire play() at several short
        // intervals so playback resumes regardless of which hook runs or
        // how long the KSPlayer state machine takes to settle. Reaffirm
        // the desired mute state in the same callbacks so the AVPlayer
        // never has a brief unmuted window between becoming ready and the
        // next watchdog tick.
        guard entry.wantsPlaying else { return }
        for delay in [0.05, 0.15, 0.4, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak entry] in
                guard let e = entry, e.wantsPlaying, !e.isVLCFallback else { return }
                if let av = e.ksPlayer?.playerLayer?.player {
                    av.isMuted = e.wantsMuted
                    if let realPlayer = av as? AVPlayer {
                        realPlayer.volume = e.wantsMuted ? 0 : 1.0
                    }
                    if !av.isPlaying { e.ksPlayer?.play() }
                }
            }
        }
    }

    private func applyMuteAndPlay(entry: Entry, isMuted: Bool, isPlaying: Bool) {
        if entry.isVLCFallback {
            guard let player = entry.vlcPlayer else { return }
            if let audio = player.audio { audio.volume = isMuted ? 0 : 100 }
            if isPlaying, !player.isPlaying { player.play() }
            else if !isPlaying, player.isPlaying { player.pause() }
            return
        }
        guard let player = entry.ksPlayer else { return }
        // Apply mute/volume only when AVPlayer is ready — otherwise the
        // setting will be applied by the deferred play() calls in
        // attachPlayerView once the player initialises.
        if let avPlayer = player.playerLayer?.player {
            avPlayer.isMuted = isMuted
            if let realPlayer = avPlayer as? AVPlayer { realPlayer.volume = isMuted ? 0 : 1.0 }
        }
        // Always issue play()/pause() on the KSPlayer wrapper directly. These
        // calls are idempotent and queue the request until the AVPlayer is
        // ready — required for streams still resolving their resource when
        // the cell first appears (common with 3-4 simultaneous streams).
        if isPlaying {
            player.play()
        } else {
            player.pause()
        }
    }

    fileprivate func handleKSFailure(for entry: Entry) {
        if entry.retryCount < 1 {
            entry.retryCount += 1
            entry.ksPlayer?.set(resource: KSPlayerResource(url: entry.url))
            entry.ksPlayer?.play()
        } else {
            switchToVLC(entry: entry)
        }
    }

    private func switchToVLC(entry: Entry) {
        DispatchQueue.main.async { [weak entry] in
            guard let entry = entry else { return }
            let container = entry.ksPlayer?.superview
            entry.ksPlayer?.pause()
            entry.ksPlayer?.removeFromSuperview()
            entry.ksPlayer = nil
            entry.isVLCFallback = true

            let player = VLCMediaPlayer()
            if let container = container { player.drawable = container }
            let media = VLCMedia(url: entry.url)
            media.addOptions([
                "network-caching": 1500,
                "clock-jitter": 0,
                "clock-synchro": 0,
                "avcodec-hw": "any",
                "videotoolbox": 1
            ])
            player.media = media
            player.play()
            entry.vlcPlayer = player
        }
    }

    private func cleanup(_ entry: Entry) {
        entry.watchdog?.invalidate()
        entry.watchdog = nil
        entry.ksPlayer?.pause()
        entry.ksPlayer?.removeFromSuperview()
        entry.ksPlayer = nil
        entry.vlcPlayer?.stop()
        entry.vlcPlayer?.drawable = nil
        entry.vlcPlayer = nil
    }
}
