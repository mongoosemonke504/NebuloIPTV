import SwiftUI
import UIKit
import AVFoundation
import Combine

extension View {
    @ViewBuilder
    func matchedTransitionSourceIfAvailable(id: some Hashable, in ns: Namespace.ID?) -> some View {
        if let ns {
            if #available(iOS 18.0, *) {
                self.matchedTransitionSource(id: id, in: ns)
            } else {
                self
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func navigationZoomTransitionIfAvailable(sourceID: some Hashable, in ns: Namespace.ID?) -> some View {
        if let ns {
            if #available(iOS 18.0, *) {
                self.navigationTransition(.zoom(sourceID: sourceID, in: ns))
            } else {
                self
            }
        } else {
            self
        }
    }

    /// Defers iOS edge system gestures (Control Center, Notification Center) so taps on
    /// buttons positioned at screen edges aren't intercepted by the OS. Used for the
    /// fullscreen player so the close (top-left) and multiview (top-right) buttons work.
    /// Top edge ONLY: deferring the bottom edge made the home-indicator swipe require
    /// two swipes to leave the app (first swipe just revealed the indicator).
    @ViewBuilder
    func defersSystemGesturesIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            self.defersSystemGestures(on: .top)
        } else {
            self
        }
    }
}

struct MainView: SwiftUI.View {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @AppStorage("xstreamURL") private var xstreamURL = ""; @AppStorage("username") private var username = ""; @AppStorage("password") private var password = ""; @AppStorage("loginTypeRaw") private var loginTypeRaw = LoginType.xtream.rawValue; @AppStorage("viewMode") private var viewMode = ViewMode.automatic.rawValue; @AppStorage("customAccentHex") private var customAccentHex = "#007AFF"; @AppStorage("nebColor1") private var nebColor1 = "#1A2538"; @AppStorage("nebColor2") private var nebColor2 = "#11101A"; @AppStorage("nebColor3") private var nebColor3 = "#1F1A24"; @AppStorage("nebX1") private var nebX1 = 0.5; @AppStorage("nebY1") private var nebY1 = 0.0; @AppStorage("nebX2") private var nebX2 = 0.5; @AppStorage("nebY2") private var nebY2 = 0.5; @AppStorage("nebX3") private var nebX3 = 0.5; @AppStorage("nebY3") private var nebY3 = 1.0
    @AppStorage("showSupportPopup") private var showSupportPopup = true
    @AppStorage("lastSupportPopupTime") private var lastSupportPopupTime: Double = 0
    
    @State private var selectedCategory: StreamCategory?
    @State private var selectedChannel: StreamChannel?
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showMultiView = false
    @State private var showQuickSwitcher = false
    @State private var showSupportAlert = false
    @State private var selectedRecording: Recording?
    @State private var isPlayerActive: Bool = false
    @Namespace private var zoomNS

    // Once-a-day full reload. Held as a static publisher so the Timer
    // subscription isn't rebuilt every time MainView's body re-evaluates --
    // SwiftUI re-initialises this struct on every state mutation, and the
    // previous instance-level `let` was creating (and discarding) a fresh
    // autoconnected publisher each render.
    private static let refreshTimer = Timer.publish(every: 86400, on: .main, in: .common).autoconnect()
    var accentColor: Color { Color(hex: customAccentHex) ?? .blue }
    
    var body: some SwiftUI.View {
        GeometryReader { geo in
            let isL = geo.size.width > geo.size.height
            ZStack {
                // Nebula is drawn inside mainNavigationStack (see comment
                // there) — a copy out here would be occluded by the nav
                // container's opaque background and just waste GPU.
                mainNavigationStack(isL: isL)
                    .zIndex(1)
                    .interactivePopGesture(isEnabled: !isPlayerActive)
                    .onChangeCompat(of: selectedChannel) { newValue in
                        isPlayerActive = (newValue != nil || viewModel.miniPlayerChannel != nil)
                    }
                    .onChangeCompat(of: viewModel.miniPlayerChannel) { newValue in
                        isPlayerActive = (selectedChannel != nil || newValue != nil)
                    }
                
                overlays(isL: isL)
            }
        }
        .ignoresSafeArea()
        .task { 
            if viewModel.channels.isEmpty { 
                await viewModel.loadData(url: xstreamURL, user: username, pass: password, type: LoginType(rawValue: loginTypeRaw) ?? .xtream) 
            }
            if showSupportPopup { 
                let now = Date().timeIntervalSince1970
                if now - lastSupportPopupTime > 43200 { 
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    showSupportAlert = true
                    lastSupportPopupTime = now 
                } 
            } 
        }
        .onReceive(Self.refreshTimer) { _ in
            Task { 
                await viewModel.loadData(url: xstreamURL, user: username, pass: password, type: LoginType(rawValue: loginTypeRaw) ?? .xtream, silent: true) 
            } 
        }
        .onChangeCompat(of: viewModel.channelToAutoPlay) { nc in 
            if let c = nc { 
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { selectedChannel = c }
                viewModel.channelToAutoPlay = nil 
            } 
        }
        .onChangeCompat(of: viewModel.triggerMultiView) { nv in 
            if nv { 
                selectedChannel = nil
                withAnimation(.spring()) { showMultiView = true }
                viewModel.triggerMultiView = false 
            } 
        }
    }
    
    private var backgroundLayer: some View {
        NebulaBackgroundView(color1: Color(hex: nebColor1) ?? .purple, color2: Color(hex: nebColor2) ?? .blue, color3: Color(hex: nebColor3) ?? .pink, point1: UnitPoint(x: nebX1, y: nebY1), point2: UnitPoint(x: nebX2, y: nebY2), point3: UnitPoint(x: nebX3, y: nebY3))
            .ignoresSafeArea()
            .zIndex(0)
    }
    
    @ViewBuilder
    private func mainNavigationStack(isL: Bool) -> some View {
        NavigationStack {
            ZStack {
                // The nebula must live INSIDE the NavigationStack: the nav
                // container's hosting view paints an opaque system background
                // (pure black in dark mode) over anything rendered behind the
                // stack, which is why the home screen showed no gradient when
                // the background only existed at the outer ZStack.
                backgroundLayer

                contentLayout(isL: isL)

                if viewModel.activeMultiViewCount > 0 && !showMultiView && selectedChannel == nil {
                    MultiViewIndicator(count: viewModel.activeMultiViewCount, accentColor: nil, action: { withAnimation(.spring()) { showMultiView = true } }).zIndex(5)
                }
            }
            .modifier(MainViewModifiers(
                viewModel: viewModel,
                scoreViewModel: scoreViewModel,
                showMultiView: $showMultiView,
                showSettings: $showSettings,
                showSearch: $showSearch,
                showSupportAlert: $showSupportAlert,
                showSupportPopup: $showSupportPopup,
                selectedRecording: $selectedRecording,
                selectedChannel: $selectedChannel,
                selectedCategory: $selectedCategory,
                showQuickSwitcher: $showQuickSwitcher,
                accentColor: accentColor,
                playAction: playChannel,
                zoomNS: zoomNS
            ))
        }
    }

    @ViewBuilder
    private func contentLayout(isL: Bool) -> some View {
        Group {
            if shouldUseSidebar(isLandscape: isL) { 
                SidebarLayout(viewModel: viewModel, scoreViewModel: scoreViewModel, selectedCategory: $selectedCategory, selectedChannel: $selectedChannel, searchText: $viewModel.searchText, isLandscape: isL, accentColor: accentColor, playAction: playChannel, showMultiView: $showMultiView, showSettings: $showSettings, zoomNS: zoomNS)
            } else { 
                StandardLayout(viewModel: viewModel, scoreViewModel: scoreViewModel, selectedCategory: $selectedCategory, selectedChannel: $selectedChannel, searchText: $viewModel.searchText, accentColor: accentColor, playAction: playChannel, showMultiView: $showMultiView, showSettings: $showSettings, selectedRecording: $selectedRecording, zoomNS: zoomNS)
            }
        }
        .zIndex(1)
    }
}

struct MainViewModifiers: ViewModifier {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Binding var showMultiView: Bool
    @Binding var showSettings: Bool
    @Binding var showSearch: Bool
    @Binding var showSupportAlert: Bool
    @Binding var showSupportPopup: Bool
    @Binding var selectedRecording: Recording?
    @Binding var selectedChannel: StreamChannel?
    @Binding var selectedCategory: StreamCategory?
    @Binding var showQuickSwitcher: Bool
    let accentColor: Color
    let playAction: (StreamChannel) -> Void
    var zoomNS: Namespace.ID? = nil

    func body(content: Content) -> some View {
        let showRenameAlert = Binding<Bool>(get: { viewModel.showRenameAlert }, set: { viewModel.showRenameAlert = $0 })
        let renameInput = Binding<String>(get: { viewModel.renameInput }, set: { viewModel.renameInput = $0 })
        let showNoStreamsAlert = Binding<Bool>(get: { viewModel.showNoStreamsAlert }, set: { viewModel.showNoStreamsAlert = $0 })
        let categories = Binding<[StreamCategory]>(get: { viewModel.categories }, set: { viewModel.categories = $0 })

        content
            .applyIf(!showMultiView) { view in
                // The system navigation bar is permanently hidden in this
                // stack: toggling it per-screen made UIKit animate the bar in
                // (Back + gear visibly sliding down) every time a section
                // opened. All chrome is drawn in-view instead — the shared
                // gear below, and each section's Back pill via StandardLayout.
                view.toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Button(action: {
                        viewModel.triggerSelectionHaptic()
                        withAnimation(.easeOut(duration: 0.22)) { showSearch = true }
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("Search")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .modifier(GlassEffect(cornerRadius: 100, isSelected: false, accentColor: nil))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .fullScreenCover(item: $selectedRecording) { recording in


                Text("Recording Player")
            }

            // isPresented stays true while ANY channel is selected, so
            // switching channels from inside the player only updates the
            // `channel` prop — CustomVideoPlayerView's .onChangeCompat(of: channel)
            // calls setupPlayer() in-place with no dismiss/re-present animation.
            .fullScreenCover(isPresented: Binding(
                get: { selectedChannel != nil },
                set: { if !$0 { selectedChannel = nil } }
            )) {
                if let channel = selectedChannel {
                    CustomVideoPlayerView(channel: channel, viewModel: viewModel, scoreViewModel: scoreViewModel, epgTime: viewModel.currentTime, onDismiss: {
                        selectedChannel = nil
                        showQuickSwitcher = false
                        if viewModel.miniPlayerChannel == nil {
                            NebuloPlayerEngine.shared.stop()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            viewModel.scrollRestoreTrigger = UUID()
                        }
                    }, onPlayChannel: { newChannel in
                        playAction(newChannel)
                    }, showQuickSwitcher: $showQuickSwitcher)
                    .ignoresSafeArea()
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(categories: categories, accentColor: accentColor, viewModel: viewModel, scoreViewModel: scoreViewModel, playAction: playAction, onSave: { viewModel.saveCategorySettings() })
                    .presentationDragIndicator(.visible)
            }
            .alert("No Streams Found", isPresented: showNoStreamsAlert) { Button("OK", role: .cancel) { } } message: { Text("No streams were found. Please search for the channel manually.") }
            .alert("Rename", isPresented: showRenameAlert) {
                TextField("New Name", text: renameInput)
                Button("Save") {
                    viewModel.confirmRename()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Support Project", isPresented: $showSupportAlert) {
                Button("Donate") { if let url = URL(string: "https://buymeacoffee.com/mongoosemonke") { UIApplication.shared.open(url) } }
                Button("Join Discord") { if let url = URL(string: "https://discord.gg/QkBUjsGCJ2") { UIApplication.shared.open(url) } }
                Button("Don't Show Again") { showSupportPopup = false }
                Button("Close", role: .cancel) {}
            } message: { Text("This is a free, open-source project that is constantly being worked on. If you enjoy using it, please consider donating to support development!") }
    }
}

extension MainView {
    @ViewBuilder
    private func overlays(isL: Bool) -> some View {
        if showMultiView {
            MultiViewScreen(viewModel: viewModel, scoreViewModel: scoreViewModel, showMultiView: $showMultiView, accentColor: accentColor, onOpenSettings: { showSettings = true })
                .transition(.blurFade)
                .zIndex(50)
        }

        if let miniChannel = viewModel.miniPlayerChannel, selectedChannel == nil { 
            VStack { 
                Spacer()
                HStack { 
                    Spacer()
                    MiniPlayerView(channel: miniChannel, viewModel: viewModel, onExpand: { 
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { 
                            selectedChannel = miniChannel
                            viewModel.miniPlayerChannel = nil 
                        } 
                    }, onClose: { 
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { 
                            viewModel.miniPlayerChannel = nil 
                        } 
                    })
                    .padding(.trailing, 20)
                    .padding(.bottom, shouldUseSidebar(isLandscape: isL) ? 20 : 100) 
                } 
            }
            .zIndex(15)
            // Apple-style: miniplayer rises into the corner with a gentle
            // scale-in, while the player view above is sliding off the bottom.
            // Two distinct motions in opposite directions read as one fluid
            // hand-off (same pattern as Apple Music's Now Playing → Mini bar).
            .transition(.asymmetric(
                insertion: .scale(scale: 0.7, anchor: .bottomTrailing).combined(with: .opacity),
                removal: .opacity
            ))
        }
        
        
        // Show a full blocking skeleton only on the very first cold load (no channels yet).
        // During EPG guide updates when channels are already available, show a non-blocking
        // pill indicator so the user can keep browsing.
        // EPGProgressBanner observes epgState directly so 10-fps progress ticks
        // never cause MainView or any channel list to re-render.
        // Search overlay — blur-fades in/out like CategoryDetailView.
        // Keyboard avoidance is tracked manually inside SearchView itself.
        if showSearch {
            SearchView(
                viewModel: viewModel,
                scoreViewModel: scoreViewModel,
                accentColor: accentColor,
                playAction: playChannel,
                onCategorySelect: { cat in
                    viewModel.lastSelectedHomeID = cat.id
                    viewModel.lastSourceCategory = cat
                    withAnimation {
                        selectedCategory = cat
                        showSearch = false
                    }
                    viewModel.searchText = ""
                },
                onDismiss: {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    viewModel.searchText = ""
                    withAnimation { showSearch = false }
                }
            )
            .transition(.opacity)
            .zIndex(90)
        }

        let isInitialLoad = viewModel.isLoading
        if isInitialLoad || viewModel.isUpdatingEPG {
            EPGProgressBanner(
                epgState: viewModel.epgState,
                status: viewModel.loadingStatus,
                accentColor: accentColor,
                isBlocking: isInitialLoad,
                onDismiss: {
                    withAnimation {
                        viewModel.isLoading = false
                        viewModel.isUpdatingEPG = false
                    }
                }
            )
            .transition(.opacity)
            .zIndex(100)
        }
    }
    
    func playChannel(_ channel: StreamChannel) { 
        hideKeyboard()
        if viewModel.multiViewModeActive { 
            viewModel.addToMultiView(channel)
            viewModel.multiViewModeActive = false
            withAnimation(.spring()) { showMultiView = true } 
        } else { 
            viewModel.addToRecent(channel.id)
            viewModel.lastPlayedChannelID = channel.id
            viewModel.lastSourceCategory = selectedCategory
            selectedChannel = channel

        } 
    }
    func shouldUseSidebar(isLandscape: Bool) -> Bool { if selectedCategory?.id == -3 { return false }; switch ViewMode(rawValue: viewMode) ?? .automatic { case .automatic: return isLandscape; case .sidebar: return true; case .standard: return false } }
}

struct StandardLayout: SwiftUI.View {
    @AppStorage("glassOpacity") private var glassOpacity = 0.15
    @AppStorage("glassShade") private var glassShade = 1.0
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Binding var selectedCategory: StreamCategory?; @Binding var selectedChannel: StreamChannel?; @Binding var searchText: String
    let accentColor: Color; let playAction: (StreamChannel) -> Void; @Binding var showMultiView: Bool; @Binding var showSettings: Bool
    @Binding var selectedRecording: Recording?
    @State private var categoryForColor: StreamCategory?
    var zoomNS: Namespace.ID? = nil

    /// When `false` the active detail view doesn't intercept touches.
    /// Set to `false` the moment a back navigation fires so the departing
    /// view (still visible at opacity > 0 during its blurFade removal
    /// transition) can't block taps on the Quick Access buttons beneath it.
    /// Automatically reset to `true` whenever a new category is selected.
    @State private var isDetailInteractive: Bool = true

    // groupedCategories is cheap (O(categories) ≈ few hundred) but still
    // cached so the ForEach never re-evaluates on every viewModel publish.
    @State private var cachedGrouped: [(HomeCategoryGroup, [StreamCategory])] = []

    /// Selected chip filter at the top of the home screen.
    /// `nil` means "For You" (default mixed view).
    @State private var selectedHomeGroup: HomeCategoryGroup? = nil

    // ── Cached lookups ───────────────────────────────────────────────────
    // Recomputing these on every body render burns frames and produces a hot
    // device. They're populated once via `.task(id:)` modifiers below and
    // refreshed only when their inputs actually change.

    /// O(1) lookup from channel id → StreamChannel. Used by Continue Watching
    /// (`recentIDs` resolution) instead of `first(where:)` which is O(n*m).
    @State private var idToChannel: [Int: StreamChannel] = [:]

    /// Featured carousel content for the active chip — cached to avoid
    /// rebuilding the category Dictionary on every render.
    @State private var cachedDisplayedFeatured: [StreamChannel] = []

    /// Continue Watching channel objects, resolved from `recentIDs` once.
    @State private var cachedRecent: [StreamChannel] = []

    /// Live games shelf content for the home page — cached snapshot.
    @State private var cachedHomeLiveGames: [ESPNEvent] = []

    /// Count of today's games that haven't started yet — drives the
    /// "M starting today" subtitle in the adaptive home header.
    @State private var startingTodayCount: Int = 0

    /// Favorite-team override for the adaptive header. When a favorited team
    /// is live or plays today, the header shows the matchup instead of the
    /// generic live counts — e.g. "White Sox at 7:10 PM" / "Today · vs Guardians".
    @State private var favHeader: (title: String, subtitle: String)? = nil

    /// Live-game count for the adaptive header, read from the cached snapshot.
    private var liveGameCount: Int { cachedHomeLiveGames.count }

    /// 0 at rest, 1 once the big header has fully scrolled past. Tracks the
    /// live scroll offset directly (no withAnimation) so the compact overlay
    /// crossfades in lockstep with the user's finger instead of snapping in
    /// after a fixed-duration animation once a threshold is crossed. Held in
    /// its own object (observed only by the two crossfading headers) so
    /// scrolling the home screen doesn't re-render its whole body each frame.
    @State private var homeHeaderProgress = ScrollProgress()

    /// Same idea for the hub sections (Sports/Favorites/Recordings): their
    /// scroll probes bubble up via preference, and this drives the compact
    /// title shown in the chrome row between the Back pill and the gear.
    /// Scoped the same way so scrolling a hub doesn't re-render this layout
    /// (which would in turn re-render the whole hub view inside it).
    @State private var sectionTitleProgress = ScrollProgress()

    /// One-line info shown under the compact chrome title for hubs.
    private func sectionChromeDetail(for cat: StreamCategory) -> String? {
        switch cat.id {
        case -3:
            return "\(scoreViewModel.allLiveGames.count) live"
        case -4:
            let c = viewModel.favoriteIDs.count
            let t = scoreViewModel.favoriteTeamIDs.count
            return "\(c) channel\(c == 1 ? "" : "s") · \(t) team\(t == 1 ? "" : "s")"
        default:
            return nil
        }
    }

    private static let headerTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// Walks the user's favorite teams (in their chosen order) and returns the
    /// header override: a live favorite game wins; otherwise the first favorite
    /// with a game later today. Returns nil when no favorite plays today.
    private func computeFavoriteHeader() -> (title: String, subtitle: String)? {
        let ids = scoreViewModel.favoriteTeamOrder.filter { scoreViewModel.favoriteTeamIDs.contains($0) }
            + scoreViewModel.favoriteTeamIDs.subtracting(scoreViewModel.favoriteTeamOrder).sorted()
        guard !ids.isEmpty else { return nil }

        let cal = Calendar.current
        var todayResult: (title: String, subtitle: String)? = nil

        for id in ids {
            guard let game = scoreViewModel.liveOrNextGame(forTeamID: id) else { continue }
            let isHome = game.homeCompetitor?.team?.id == id
            let mine = isHome ? game.homeCompetitor : game.awayCompetitor
            let opp  = isHome ? game.awayCompetitor : game.homeCompetitor
            guard let myName = mine?.team?.shortDisplayName ?? mine?.team?.displayName else { continue }
            let oppName = opp?.team?.shortDisplayName ?? opp?.team?.displayName ?? ""

            switch game.status.type.state {
            case "in":
                // Live favorite game — top priority, return immediately.
                let myScore = mine?.score ?? "0"
                let oppScore = opp?.score ?? "0"
                return (title: "\(myName) \(myScore)–\(oppScore)",
                        subtitle: "LIVE · vs \(oppName)")
            case "pre" where cal.isDateInToday(game.gameDate):
                if todayResult == nil {
                    let time = Self.headerTimeFormatter.string(from: game.gameDate)
                    todayResult = (title: "\(myName) at \(time)",
                                   subtitle: "Today · vs \(oppName)")
                }
            default:
                break
            }
        }
        return todayResult
    }

    /// Recompute the "starting today" count: today's games still in the
    /// pre-game state. Walks the cached score maps once, off the body.
    private func computeStartingToday() -> Int {
        let cal = Calendar.current
        var ids = Set<String>()
        for games in scoreViewModel.filteredGames.values {
            for g in games where g.status.type.state == "pre" && cal.isDateInToday(g.gameDate) {
                ids.insert(g.id)
            }
        }
        for sections in scoreViewModel.filteredSectionsMap.values {
            for s in sections {
                for g in s.games where g.status.type.state == "pre" && cal.isDateInToday(g.gameDate) {
                    ids.insert(g.id)
                }
            }
        }
        return ids.count
    }

    var body: some SwiftUI.View {
        ZStack(alignment: .bottom) {
            if viewModel.isLoading {
                VStack(spacing: 0) {
                    // Header pinned above scroll content — outside the ScrollView
                    // so it is never affected by content insets or scroll position.
                    HStack {
                        SkeletonBox(width: 110, height: 28)
                        Spacer()
                        // No gear placeholder — the real gear is a fixed
                        // overlay that is already visible during loading.
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 16)

                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 30) {

                            // 1. Chip bar
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach([70, 60, 80, 65, 75, 55] as [CGFloat], id: \.self) { w in
                                        SkeletonBox(width: w, height: 36, cornerRadius: 18)
                                    }
                                }.padding(.horizontal)
                            }
                            .frame(height: 44)

                            // 2. Featured carousel
                            VStack(spacing: 10) {
                                SkeletonBox(height: 200, cornerRadius: 20)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 16)
                                HStack(spacing: 5) {
                                    ForEach(0..<4, id: \.self) { i in
                                        SkeletonBox(width: i == 0 ? 20 : 6, height: 6, cornerRadius: 3)
                                    }
                                }
                            }

                            // 3. Continue Watching shelf
                            VStack(alignment: .leading, spacing: 14) {
                                SkeletonBox(width: 180, height: 22).padding(.horizontal)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 16) {
                                        ForEach(0..<4, id: \.self) { _ in
                                            HorizontalCardSkeleton()
                                        }
                                    }.padding(.horizontal)
                                }
                                .frame(height: 152)
                            }

                            // 4. Quick Access panel
                            VStack(alignment: .leading, spacing: 14) {
                                SkeletonBox(width: 140, height: 22).padding(.horizontal)
                                SkeletonBox(height: 90, cornerRadius: 20)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal)
                            }

                            // 5. Category shelves (2 groups)
                            ForEach(0..<2, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 14) {
                                    SkeletonBox(width: 120, height: 22).padding(.horizontal)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 12) {
                                            ForEach(0..<5, id: \.self) { _ in
                                                SkeletonBox(width: 170, height: 96, cornerRadius: 20)
                                            }
                                        }.padding(.horizontal)
                                    }
                                }
                            }
                        }
                        .padding(.bottom)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if !searchText.isEmpty {
                searchView
                    .modifier(SwipeBackModifier(onBack: { withAnimation { searchText = "" } }))
            } else if let cat = selectedCategory {
                // `.allowsHitTesting(isDetailInteractive)` is the key fix for
                // Quick Access buttons becoming unresponsive after navigation.
                // During the blurFade removal animation the departing view stays
                // in the hierarchy at opacity > 0, which normally lets it swallow
                // taps meant for the home screen below. Setting this to `false`
                // (via handleBackNavigation) before the animation starts removes
                // `userInteractionEnabled` from UIKit so the home screen is
                // immediately tappable the moment the user navigates back.
                Group {
                    if cat.id == -3 {
                        SportsHubView(viewModel: viewModel, accentColor: accentColor, playAction: playAction, onBack: handleBackNavigation, scoreViewModel: scoreViewModel)
                            .transition(.blurFade)
                            .modifier(SwipeBackModifier(onBack: handleBackNavigation))
                    } else if cat.id == -4 {
                        FavoritesView(viewModel: viewModel, scoreViewModel: scoreViewModel, accentColor: accentColor, playAction: playAction, onBack: handleBackNavigation)
                            .transition(.blurFade)
                            .modifier(SwipeBackModifier(onBack: handleBackNavigation))
                    } else if cat.id == -5 {
                        RecordingsView(viewModel: viewModel, playAction: playAction, onBack: handleBackNavigation)
                            .transition(.blurFade)
                            .modifier(SwipeBackModifier(onBack: handleBackNavigation))
                    } else {
                        CategoryDetailView(title: cat.name, channels: getChannelsToShow(for: cat), accentColor: accentColor, playAction: playAction, toggleFav: viewModel.toggleFavorite, promptRename: viewModel.triggerRenameChannel, hideChannel: viewModel.hideChannel, favoriteIDs: viewModel.favoriteIDs, viewModel: viewModel, showMultiView: $showMultiView, onBack: handleBackNavigation, onCategorySelect: { cat in withAnimation { selectedCategory = cat; searchText = "" } }, zoomNS: zoomNS)
                            .transition(.blurFade)
                            .modifier(SwipeBackModifier(onBack: handleBackNavigation))
                    }
                }
                // The hubs publish their scroll offset via preference (the
                // probe rides on each big title). Reading it here lets the
                // chrome row itself host the compact title — level with the
                // Back pill and gear — instead of a separate bar below them.
                .onPreferenceChange(SectionScrollOffsetsKey.self) { offsets in
                    let key: String? = cat.id == -3 ? "sports" : cat.id == -4 ? "fav" : cat.id == -5 ? "rec" : nil
                    guard let key, let y = offsets[key] else { return }
                    sectionTitleProgress.set(min(max(-y / 40, 0), 1))
                }
                // Static chrome row: the Back pill (and, for plain categories,
                // a centred title) lives OUTSIDE the transition group so it
                // appears instantly — no slide-in — while the section content
                // blur-fades beneath it. The system nav bar is permanently
                // hidden (see MainViewModifiers), so this is the only chrome.
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        Button(action: handleBackNavigation) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.body.weight(.semibold))
                                Text("Back")
                                    .font(.body)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .modifier(GlassEffect(cornerRadius: 22, isSelected: false, accentColor: nil))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        SettingsGearButton {
                            viewModel.triggerSelectionHaptic()
                            showSettings = true
                        }
                    }
                    .overlay {
                        if cat.id >= 0 || cat.id == -2 {
                            Text(cat.name)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 80)
                        } else if cat.id == -3 || cat.id == -4 || cat.id == -5 {
                            // Hub sections: the compact title crossfades in
                            // between Back and the gear as the big in-scroll
                            // title departs — pure opacity, no layout shift,
                            // so the transition stays perfectly smooth.
                            VStack(spacing: 0) {
                                Text(cat.name)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                                if let detail = sectionChromeDetail(for: cat) {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }
                            .lineLimit(1)
                            .padding(.horizontal, 80)
                            .scrollProgressOpacity(sectionTitleProgress) { Double($0) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                .allowsHitTesting(isDetailInteractive)
            } else {
                ScrollView(showsIndicators: false) {
                    // Batch every liquid-glass element on the home screen into a
                    // single coordinated render pass. Each `.glassEffect` card
                    // otherwise samples and blurs the backdrop independently
                    // every scroll frame — the home screen's unique cost vs the
                    // solid-fill Favorites/Sports screens. spacing 0 keeps the
                    // separate cards from merging into one another.
                    GlassEffectContainer(spacing: 0) {
                        VStack(alignment: .leading, spacing: 30) {

                            // 1. Adaptive live header — large "N live" with a
                            //    "M starting today" subtitle, plus the circular
                            //    settings gear. Scrolls away with the content
                            //    (matches the skeleton header shown while loading).
                            //    Fades out over the same distance the compact
                            //    overlay fades in, so the two crossfade instead
                            //    of one popping in after the other disappears.
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(favHeader?.title ?? "\(liveGameCount) live")
                                        .font(.system(size: 34, weight: .bold))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(favHeader?.subtitle ?? "\(startingTodayCount) starting today")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                // Fade ONLY the title text, not the whole header.
                                // The settings gear is a liquid-glass button, and
                                // animating opacity on glass forces an expensive
                                // offscreen re-render every scroll frame — the one
                                // thing that made the home header crossfade jitter
                                // where the text-only hub headers stay smooth. The
                                // gear still scrolls away with the header; it just
                                // isn't alpha-blended, so the crossfade is now as
                                // cheap as the other screens'.
                                .scrollProgressOpacity(homeHeaderProgress) { 1 - Double($0) }
                                Spacer()
                                SettingsGearButton {
                                    viewModel.triggerSelectionHaptic()
                                    showSettings = true
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)

                            // 2. Genre chips — "For You" + each non-empty home category group.
                            //    Tapping a chip filters the rest of the home page in-place
                            //    (featured carousel, categories) without leaving the home
                            //    view. Sports is intentionally not in the chip list — the
                            //    Quick Access panel + Live Now shelf already give the user
                            //    two ways to reach the Sports hub from this screen.
                            HomeFilterChips(
                                groups: chipGroups,
                                selected: $selectedHomeGroup
                            )

                            // 3. Featured Carousel — uses cached snapshot. Updated by the
                            //     `.task` modifiers below whenever the chip selection or
                            //     underlying featured list changes. When a favorite team is
                            //     live, the channel broadcasting their game leads the carousel.
                            if !cachedDisplayedFeatured.isEmpty {
                                FeaturedCarousel(
                                    channels: cachedDisplayedFeatured,
                                    viewModel: viewModel,
                                    accentColor: accentColor,
                                    playAction: playAction
                                )
                                .id(selectedHomeGroup?.rawValue ?? "for-you")
                            }

                            // 4. Continue Watching shelf — uses cached resolved channels
                            //    instead of `first(where:)` per recent id (O(n*m) → O(n)).
                            if !cachedRecent.isEmpty {
                                VStack(alignment: .leading, spacing: 14) {
                                    HomeSectionHeader(
                                        title: "Continue Watching",
                                        icon: "play.circle.fill",
                                        iconColor: .primary,
                                        showsChevron: true
                                    ) {
                                        viewModel.triggerSelectionHaptic()
                                        viewModel.lastSelectedHomeID = -2
                                        withAnimation { selectedCategory = StreamCategory(id: -2, name: "Recently Watched") }
                                    }

                                    HorizontalPreviewList(
                                        channels: cachedRecent,
                                        isRecent: true,
                                        accentColor: accentColor,
                                        viewModel: viewModel,
                                        playAction: playAction,
                                        promptRenameChannel: viewModel.triggerRenameChannel,
                                        hideChannel: viewModel.hideChannel,
                                        removeFromRecent: viewModel.removeFromRecent
                                    )
                                }
                            }

                            // 5. Quick Access — one unified glass panel
                            VStack(alignment: .leading, spacing: 14) {
                                HomeSectionHeader(title: "Quick Access", icon: nil, iconColor: .primary, showsChevron: false, action: nil)

                                QuickAccessPanel(
                                    accentColor: accentColor,
                                    sportsAction: {
                                        viewModel.triggerSelectionHaptic()
                                        viewModel.lastSelectedHomeID = -3
                                        withAnimation { selectedCategory = StreamCategory(id: -3, name: "Sports") }
                                    },
                                    favoritesAction: {
                                        viewModel.triggerSelectionHaptic()
                                        viewModel.lastSelectedHomeID = -4
                                        withAnimation { selectedCategory = StreamCategory(id: -4, name: "Favorites") }
                                    },
                                    recordingsAction: {
                                        viewModel.triggerSelectionHaptic()
                                        viewModel.lastSelectedHomeID = -5
                                        withAnimation { selectedCategory = StreamCategory(id: -5, name: "Recordings") }
                                    },
                                    multiViewAction: {
                                        viewModel.triggerSelectionHaptic()
                                        viewModel.lastSelectedHomeID = -99
                                        withAnimation { showMultiView = true }
                                    }
                                )
                                .padding(.horizontal)
                            }

                            // 6. Below Quick Access:
                            //    • "For You" view → "Live Now" sports games shelf, then all
                            //      genre category shelves.
                            //    • Specific chip selected → only the subcategory shelves
                            //      that belong to that chip's group.
                            if selectedHomeGroup == nil && !cachedHomeLiveGames.isEmpty {
                                // Live Now shelf — uses cached snapshot of live games to
                                // avoid the O(games × sports) walk on every render.
                                VStack(alignment: .leading, spacing: 14) {
                                    HomeSectionHeader(
                                        title: "Live Now",
                                        icon: "dot.radiowaves.left.and.right",
                                        iconColor: .red,
                                        showsChevron: true
                                    ) {
                                        viewModel.triggerSelectionHaptic()
                                        viewModel.lastSelectedHomeID = -3
                                        withAnimation { selectedCategory = StreamCategory(id: -3, name: "Sports") }
                                    }

                                    LiveGamesPreviewList(
                                        games: cachedHomeLiveGames,
                                        scoreViewModel: scoreViewModel,
                                        viewModel: viewModel,
                                        accentColor: accentColor
                                    )
                                }
                            }

                            // 7. Category shelves — filtered by selected chip.
                            ForEach(displayedGroupedCategories, id: \.0) { entry in
                                let group = entry.0
                                let cats = entry.1
                                VStack(alignment: .leading, spacing: 14) {
                                    HomeSectionHeader(
                                        title: group.rawValue,
                                        icon: group.icon,
                                        iconColor: .primary,
                                        showsChevron: false,
                                        action: nil
                                    )

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 12) {
                                            ForEach(cats) { cat in
                                                Button(action: {
                                                    viewModel.triggerSelectionHaptic()
                                                    viewModel.lastSelectedHomeID = cat.id
                                                    withAnimation { selectedCategory = cat }
                                                }) {
                                                    CategoryHeroCard(
                                                        title: cat.name,
                                                        color: viewModel.categoryColor(for: cat.id)
                                                    )
                                                    .frame(width: 170)
                                                }
                                                .buttonStyle(PressableCardStyle())
                                                .id(cat.id)
                                                .contextMenu {
                                                    Button { viewModel.triggerRenameCategory(cat) } label: { Label("Rename", systemImage: "pencil") }
                                                    Button { categoryForColor = cat } label: { Label("Change Color", systemImage: "paintpalette") }
                                                    if viewModel.categoryColor(for: cat.id) != nil {
                                                        Button(role: .destructive) {
                                                            viewModel.setCategoryColor(id: cat.id, hex: nil)
                                                        } label: {
                                                            Label("Reset Color", systemImage: "arrow.counterclockwise")
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        .padding(.horizontal)
                                    }
                                }
                            }

                        }
                        .padding(.top)
                        .sheet(item: $categoryForColor) { cat in
                            CategoryColorPicker(category: cat, viewModel: viewModel)
                                .presentationDetents([.medium])
                                .presentationDragIndicator(.visible)
                        }
                    }
                    }
                    .onAppear {
                        // Populate every cache synchronously so the first
                        // frame of the home screen has the carousel, recent
                        // channels and live games already in place — no
                        // flicker / empty state on appear.
                        if cachedGrouped.isEmpty { cachedGrouped = groupedCategories }
                        if idToChannel.isEmpty {
                            var map = [Int: StreamChannel]()
                            map.reserveCapacity(viewModel.channels.count)
                            for c in viewModel.channels { map[c.id] = c }
                            idToChannel = map
                        }
                        if cachedDisplayedFeatured.isEmpty {
                            cachedDisplayedFeatured = computeDisplayedFeatured()
                        }
                        if cachedRecent.isEmpty {
                            cachedRecent = viewModel.recentIDs.compactMap { idToChannel[$0] }
                        }
                        if cachedHomeLiveGames.isEmpty {
                            cachedHomeLiveGames = scoreViewModel.allLiveGames
                        }
                        startingTodayCount = computeStartingToday()
                        favHeader = computeFavoriteHeader()

                        viewModel.lastSelectedHomeID = nil
                    }
                    // ── Cache refresh tasks ──────────────────────────────
                    // Each `.task(id:)` only re-fires when its key actually
                    // changes. Without these, the body would do all of these
                    // computations on every viewModel/scoreViewModel publish.
                    .task(id: viewModel.categories.count) {
                        cachedGrouped = groupedCategories
                    }
                    .task(id: viewModel.channels.count) {
                        // Build the id → channel lookup. Done off the body so
                        // recent/featured filtering can use O(1) lookups.
                        var map = [Int: StreamChannel]()
                        map.reserveCapacity(viewModel.channels.count)
                        for c in viewModel.channels { map[c.id] = c }
                        idToChannel = map
                    }
                    .task(id: featuredCacheKey) {
                        cachedDisplayedFeatured = computeDisplayedFeatured()
                    }
                    .task(id: recentCacheKey) {
                        cachedRecent = viewModel.recentIDs.compactMap { idToChannel[$0] }
                    }
                    .task(id: scoreViewModel.allLiveGameIDsKey) {
                        cachedHomeLiveGames = scoreViewModel.allLiveGames
                        startingTodayCount = computeStartingToday()
                        favHeader = computeFavoriteHeader()
                    }
                    // Header counts depend on the score maps, which stream in
                    // sport-by-sport after launch. `filteredGames.count` bumps
                    // as each sport lands, so the "N starting today" number and
                    // the favorite-team headline fill in without needing a
                    // live-set change to trigger them.
                    .task(id: scoreViewModel.filteredGames.count) {
                        startingTodayCount = computeStartingToday()
                        favHeader = computeFavoriteHeader()
                    }
                    .task(id: scoreViewModel.favoriteTeamIDs) {
                        favHeader = computeFavoriteHeader()
                    }
                    // Read the scroll offset directly instead of routing it
                    // through a GeometryReader probe + preference key. The
                    // preference pipeline recomputes across the home screen's
                    // large view tree every frame, which is what made the header
                    // crossfade hitch at the very start of a scroll; this reads
                    // the offset synchronously with no tree-wide propagation.
                    .onScrollGeometryChange(for: CGFloat.self) { geo in
                        geo.contentOffset.y + geo.contentInsets.top
                    } action: { _, scrolled in
                        homeHeaderProgress.set(min(max(scrolled / 40, 0), 1))
                    }
                    // Compact header — always present, crossfading in as the
                    // big title above fades/scrolls away. Transparent scrim
                    // (no material) so everything scrolled past stays visible
                    // behind the text.
                    .overlay(alignment: .top) {
                        VStack(spacing: 1) {
                            Text(favHeader?.title ?? "\(liveGameCount) live")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(.white)
                            Text(favHeader?.subtitle ?? "\(startingTodayCount) starting today")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                        .padding(.bottom, 12)
                        .background(
                            LinearGradient(
                                colors: [Color.black.opacity(0.55), Color.black.opacity(0.3), .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .allowsHitTesting(false)
                        .scrollProgressOpacity(homeHeaderProgress) { Double($0) }
                    }
                    .transition(.blurFade)
            }
        }
        // easeOut, not a spring: the spring's overshoot read as sections
        // "bouncing in" as they blur-faded into place.
        .animation(.easeOut(duration: 0.3), value: selectedCategory)
        // Re-enable detail interaction the moment any forward navigation fires,
        // so the arriving view is always fully tappable even if the user
        // navigates back and forward again within the 0.8 s reset window.
        .onChangeCompat(of: selectedCategory) { cat in
            if cat != nil { isDetailInteractive = true }
            sectionTitleProgress.set(0)
        }
    }

    private var searchView: some SwiftUI.View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                if viewModel.isSearching {
                    VStack(alignment: .leading, spacing: 20) {
                        SkeletonBox(width: 150, height: 14).padding(.horizontal)
                        ScrollView(.horizontal) { HStack { ForEach(0..<4) { _ in HorizontalCardSkeleton() } } }.padding(.horizontal)
                        SkeletonBox(width: 150, height: 14).padding(.horizontal)
                        ScrollView(.horizontal) { HStack { ForEach(0..<4) { _ in HorizontalCardSkeleton() } } }.padding(.horizontal)
                    }.padding(.top, 20)
                } else {
                    if !viewModel.filteredEPGChannels.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("EPG GUIDE RESULTS")
                                .font(.caption2.weight(.black))
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                            HorizontalSearchList(channels: viewModel.filteredEPGChannels, viewModel: viewModel, accentColor: accentColor, playAction: playAction)
                        }
                    }
                    if !viewModel.filteredNameChannels.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("CHANNEL NAME RESULTS")
                                .font(.caption2.weight(.black))
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                            HorizontalSearchList(channels: viewModel.filteredNameChannels, viewModel: viewModel, accentColor: accentColor, playAction: playAction)
                        }
                    }
                    
                    if !viewModel.filteredCategories.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("EXPLORE CATEGORIES")
                                .font(.caption2.weight(.black))
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(viewModel.filteredCategories) { cat in
                                        Button(action: { withAnimation { selectedCategory = cat; searchText = "" } }) {
                                            CategoryCard(title: cat.name, color: .secondary, lineLimit: 1)
                                                .multilineTextAlignment(.leading)
                                                .frame(width: 200, height: 85)
                                        }.buttonStyle(.plain)
                                    }
                                }.padding(.horizontal)
                            }
                        }
                    }
                    
                    RecentSearchesView(viewModel: viewModel, accentColor: accentColor)
                        .padding(.top, 10)
                    
                    if viewModel.filteredEPGChannels.isEmpty && viewModel.filteredNameChannels.isEmpty && viewModel.filteredCategories.isEmpty {
                        EmptyStateView(title: "No Results", systemImage: "magnifyingglass", description: "Try searching for a show or channel.")
                            .padding(.top, 100)
                    }
                }
            }
            .padding(.top, 20)
        }
    }
    
    func getChannelsToShow(for cat: StreamCategory) -> [StreamChannel] {
        // -2 = Recently Watched. Use the cached id-to-channel map so this is
        // O(recent) instead of O(recent × channels) -- the latter was the
        // single largest hitch when entering this list with a populated
        // playlist (thousands of channels × dozens of recents).
        if cat.id == -2 {
            return viewModel.recentIDs.compactMap { idToChannel[$0] }
        }
        if cat.id == -4 { return viewModel.channels.filter { viewModel.favoriteIDs.contains($0.id) } }
        if cat.id == -1 { return viewModel.channels.filter { !viewModel.hiddenIDs.contains($0.id) } }
        return viewModel.channels.filter { $0.categoryID == cat.id && !viewModel.hiddenIDs.contains($0.id) }
    }

    /// Visible categories grouped by broader genre (Sports, News, Movies, etc.)
    /// in `HomeCategoryGroup.allCases` order. Empty groups are omitted.
    var groupedCategories: [(HomeCategoryGroup, [StreamCategory])] {
        let visible = viewModel.categories.filter { !$0.isHidden }
        let buckets = Dictionary(grouping: visible) { HomeCategoryGroup.classify($0) }
        return HomeCategoryGroup.allCases.compactMap { group in
            guard let cats = buckets[group], !cats.isEmpty else { return nil }
            return (group, cats)
        }
    }

    var chipGroups: [HomeCategoryGroup] {
        var groups = cachedGrouped.compactMap { $0.0 == .international ? nil : $0.0 }
        if let idx = groups.firstIndex(of: .sports) {
            groups.remove(at: idx)
            groups.insert(.sports, at: 0)
        }
        return groups
    }

    /// Cache key for `cachedDisplayedFeatured`. Hashes only the inputs that
    /// can actually change the result, so the cache rebuilds only on
    /// genuine changes (chip toggle, new featured list).
    private var featuredCacheKey: String {
        let g = selectedHomeGroup?.rawValue ?? "for-you"
        let ids = viewModel.featuredChannels.map { String($0.id) }.joined(separator: ",")
        let live = scoreViewModel.allLiveGameIDsKey
        let favCount = scoreViewModel.favoriteTeamIDs.count + scoreViewModel.favoriteLeagueKeys.count
        return "\(g)|\(ids)|\(live)|\(favCount)"
    }

    /// Cache key for `cachedRecent`. Triggers a refresh when the user's
    /// recent list mutates or when the global channel list reloads.
    private var recentCacheKey: String {
        viewModel.recentIDs.map { String($0) }.joined(separator: ",")
            + "|\(viewModel.channels.count)"
    }

    /// Featured carousel content for the current chip selection. Called only
    /// from `.task(id: featuredCacheKey)` — never directly from `body` so
    /// the body itself stays cheap.
    /// • "For You" → pre-computed mixed-genre list from ChannelViewModel.
    /// • Specific group → channels from that group, preferring ones with a
    ///   currently-live program (better hero cards) and limiting to 6.
    func computeDisplayedFeatured() -> [StreamChannel] {
        if let group = selectedHomeGroup {
            let catLookup: [Int: StreamCategory] = Dictionary(uniqueKeysWithValues: viewModel.categories.map { ($0.id, $0) })
            var inGroup: [StreamChannel] = []
            inGroup.reserveCapacity(64)
            for channel in viewModel.channels {
                if viewModel.hiddenIDs.contains(channel.id) { continue }
                guard let cat = catLookup[channel.categoryID] else { continue }
                guard HomeCategoryGroup.classify(cat) == group else { continue }
                inGroup.append(channel)
                if inGroup.count > 60 { break }
            }
            let withLive = inGroup.filter { viewModel.getCurrentProgram(for: $0) != nil }
            let pool = withLive.isEmpty ? inGroup : withLive
            return Array(pool.prefix(6))
        }

        var result: [StreamChannel] = []
        var usedIDs = Set<Int>()

        for game in scoreViewModel.favoriteLiveGames() {
            if let ch = viewModel.resolveChannel(forGame: game), usedIDs.insert(ch.id).inserted {
                result.append(ch)
            }
        }

        for ch in viewModel.featuredChannels where usedIDs.insert(ch.id).inserted {
            result.append(ch)
        }

        return result
    }

    /// Category shelves to render below Quick Access for the current chip.
    /// • "For You" → all groups (matches the pre-chip behaviour).
    /// • Specific group → just that group's categories.
    var displayedGroupedCategories: [(HomeCategoryGroup, [StreamCategory])] {
        guard let group = selectedHomeGroup else { return cachedGrouped }
        return cachedGrouped.filter { $0.0 == group }
    }

    /// Navigates back to the home screen while ensuring the departing detail
    /// view cannot block Quick Access taps.
    ///
    /// SwiftUI keeps a transitioning view (blurFade removal) in the hierarchy
    /// at opacity > 0 for ~600 ms. Because opacity alone doesn't disable hit
    /// testing, the fading view intercepts taps meant for the home screen.
    /// Setting `isDetailInteractive = false` before the animation removes
    /// `userInteractionEnabled` from the UIKit layer first, so the home screen
    /// is tappable the instant the transition starts.
    private func handleBackNavigation() {
        isDetailInteractive = false
        // Defer the state flip to the next run-loop turn so SwiftUI can
        // commit `isDetailInteractive = false` as its own update pass —
        // batching both changes together would apply `allowsHitTesting(false)`
        // only to the CURRENT render's view, not the one kept alive for the
        // removal transition.
        DispatchQueue.main.async {
            withAnimation { selectedCategory = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                isDetailInteractive = true
            }
        }
    }
}

struct DashboardCard: View {
    let title: String
    let icon: String
    let color: Color
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                Circle()
                    .fill(color.opacity(0.55))
                    .frame(width: 130, height: 130)
                    .blur(radius: 38)
                    .offset(x: 35, y: -30)

                Image(systemName: icon)
                    .font(.system(size: 42, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color)
                    .shadow(color: color.opacity(0.6), radius: 8, x: 0, y: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 14)
                    .padding(.trailing, 16)

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .modifier(TintedGlassCard(cornerRadius: 20, tint: color))
        }
        .buttonStyle(PressableCardStyle())
    }
}

struct TintedGlassCard: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color

    private var isTinted: Bool {
        tint != .clear
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            let glass: Glass = isTinted
                ? .regular.tint(tint.opacity(0.18))
                : .regular
            return AnyView(
                content
                    .glassEffect(glass, in: shape)
                    .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: isTinted ? tint.opacity(0.28) : Color.black.opacity(0.2), radius: isTinted ? 14 : 6, x: 0, y: isTinted ? 6 : 3)
                    .clipShape(shape)
            )
        } else {
            return AnyView(
                content
                    .background(isTinted ? tint.opacity(0.15) : Color.white.opacity(0.08))
                    .background(.ultraThinMaterial)
                    .clipShape(shape)
                    .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: isTinted ? tint.opacity(0.28) : Color.black.opacity(0.2), radius: isTinted ? 14 : 6, x: 0, y: isTinted ? 6 : 3)
            )
        }
    }
}

enum CategoryPalette {
    private static let palette: [Color] = [
        Color(red: 0.94, green: 0.36, blue: 0.38),
        Color(red: 0.96, green: 0.58, blue: 0.22),
        Color(red: 0.98, green: 0.78, blue: 0.27),
        Color(red: 0.34, green: 0.78, blue: 0.44),
        Color(red: 0.29, green: 0.69, blue: 0.91),
        Color(red: 0.38, green: 0.48, blue: 0.97),
        Color(red: 0.65, green: 0.42, blue: 0.93),
        Color(red: 0.93, green: 0.44, blue: 0.76),
        Color(red: 0.27, green: 0.73, blue: 0.72),
        Color(red: 0.82, green: 0.53, blue: 0.35)
    ]

    static func color(for name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = ((hash &<< 5) &+ hash) &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

struct CategoryColorPicker: View {
    let category: StreamCategory
    @ObservedObject var viewModel: ChannelViewModel
    @Environment(\.dismiss) private var dismiss

    private let swatches: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE",
        "#30B0C7", "#007AFF", "#5856D6", "#AF52DE", "#FF2D55",
        "#A2845E", "#8E8E93"
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                CategoryHeroCard(
                    title: category.name,
                    color: viewModel.categoryColor(for: category.id)
                )
                .frame(maxWidth: 240)
                .frame(maxWidth: .infinity)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 6), spacing: 16) {
                    ForEach(swatches, id: \.self) { hex in
                        Button {
                            viewModel.setCategoryColor(id: category.id, hex: hex)
                            viewModel.triggerSelectionHaptic()
                        } label: {
                            Circle()
                                .fill(Color(hex: hex) ?? .gray)
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Circle()
                                        .stroke(
                                            viewModel.categoryColors[category.id] == hex
                                                ? Color.white
                                                : Color.white.opacity(0.15),
                                            lineWidth: viewModel.categoryColors[category.id] == hex ? 2.5 : 0.5
                                        )
                                )
                                .shadow(color: (Color(hex: hex) ?? .gray).opacity(0.4), radius: 6, x: 0, y: 3)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if viewModel.categoryColor(for: category.id) != nil {
                    Button(role: .destructive) {
                        viewModel.setCategoryColor(id: category.id, hex: nil)
                        viewModel.triggerSelectionHaptic()
                    } label: {
                        Label("Reset to Default", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.red)
                }

                Spacer()
            }
            .padding(24)
            .navigationTitle("Category Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct CategoryHeroCard: View {
    let title: String
    var color: Color? = nil
    var subtitle: String? = nil

    var body: some View {
        ZStack {
            if let color {
                Circle()
                    .fill(color.opacity(0.55))
                    .frame(width: 110, height: 110)
                    .blur(radius: 30)
                    .offset(x: 32, y: -24)
            }

            VStack(spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .modifier(TintedGlassCard(cornerRadius: 20, tint: color ?? .clear))
    }
}

struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct SidebarLayout: SwiftUI.View {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Binding var selectedCategory: StreamCategory?; @Binding var selectedChannel: StreamChannel?; @Binding var searchText: String
    let isLandscape: Bool; let accentColor: Color; let playAction: (StreamChannel) -> Void; @Binding var showMultiView: Bool; @Binding var showSettings: Bool
    var zoomNS: Namespace.ID? = nil
    @State private var channelForDescription: StreamChannel?

    // O(1) id → channel cache. Refreshed only when the channel list size
    // changes; prevents the O(recent × channels) walk that getChannelsToShow
    // would otherwise perform every time the user selects Recently Watched.
    @State private var idToChannel: [Int: StreamChannel] = [:]
    
    var body: some SwiftUI.View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ClockView().padding(.vertical, 20)
                        if !searchText.isEmpty { GlassSidebarRow(title: "Search Results", isSelected: true, accentColor: accentColor) }
                        else {
                            Button(action: { viewModel.triggerSelectionHaptic(); withAnimation { selectedCategory = StreamCategory(id: -2, name: "Recently Watched") } }) { GlassSidebarRow(title: "Recently Watched", isSelected: selectedCategory?.id == -2, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { viewModel.triggerSelectionHaptic(); withAnimation { selectedCategory = StreamCategory(id: -4, name: "Favorites") } }) { GlassSidebarRow(title: "Favorites", isSelected: selectedCategory?.id == -4, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { viewModel.triggerSelectionHaptic(); withAnimation { selectedCategory = StreamCategory(id: -3, name: "Sports") } }) { GlassSidebarRow(title: "Sports", isSelected: selectedCategory?.id == -3, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { viewModel.triggerSelectionHaptic(); withAnimation { selectedCategory = StreamCategory(id: -5, name: "Recordings") } }) { GlassSidebarRow(title: "Recordings", isSelected: selectedCategory?.id == -5, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { viewModel.triggerSelectionHaptic(); withAnimation { showMultiView = true } }) { GlassSidebarRow(title: "Multi-View", isSelected: false, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { viewModel.triggerSelectionHaptic(); withAnimation { selectedCategory = StreamCategory(id: -1, name: "All Channels") } }) { GlassSidebarRow(title: "All Channels", isSelected: selectedCategory?.id == -1, accentColor: accentColor) }.buttonStyle(.plain)
                            Divider().background(Color.white.opacity(0.3)).padding(.vertical, 8)
                            ForEach(viewModel.categories.filter { !$0.isHidden }) { cat in Button(action: { viewModel.triggerSelectionHaptic(); withAnimation { selectedCategory = cat } }) { GlassSidebarRow(title: cat.name, isSelected: selectedCategory?.id == cat.id, accentColor: accentColor) }.buttonStyle(.plain).contextMenu { Button { viewModel.triggerRenameCategory(cat) } label: { Label("Rename", systemImage: "pencil") }; Button { viewModel.hideCategory(cat.id) } label: { Label("Hide", systemImage: "eye.slash") } } }
                        }
                    }.padding(.horizontal, 10)
                }
            }.frame(width: isLandscape ? 260 : 170).background(Color.clear); Divider().overlay(Color.white.opacity(0.2))
            ZStack {
                if viewModel.isLoading {
                    ScrollView {
                        VStack {
                            ForEach(0..<15, id: \.self) { _ in ChannelRowSkeleton() }
                        }
                    }
                }
                else if !searchText.isEmpty {
                    
                    
                    
                    StandardLayout(viewModel: viewModel, scoreViewModel: scoreViewModel, selectedCategory: $selectedCategory, selectedChannel: $selectedChannel, searchText: $searchText, accentColor: accentColor, playAction: playAction, showMultiView: $showMultiView, showSettings: $showSettings, selectedRecording: .constant(nil), zoomNS: zoomNS)
                        .id("SearchOverride") 
                } else if selectedCategory?.id == -3 { SportsHubView(viewModel: viewModel, accentColor: accentColor, playAction: playAction, onBack: nil, scoreViewModel: scoreViewModel).transition(.blurFade) }
                else if selectedCategory?.id == -5 { RecordingsView(viewModel: viewModel, playAction: playAction, onBack: { withAnimation { selectedCategory = nil } }).transition(.blurFade) }
                else {
                    ScrollViewReader { proxy in
                        let channels = getChannelsToShow()
                        Group {
                            if channels.isEmpty {
                                EmptyStateView(title: "No Channels", systemImage: "tv.slash", description: "Select a category.")
                            } else {
                                List {
                                    ForEach(channels) { c in
                                        ChannelRow(channel: c, epgProgram: viewModel.getCurrentProgram(for: c), isFavorite: viewModel.favoriteIDs.contains(c.id), accentColor: accentColor, isCompact: !isLandscape, playAction: { playAction(c) }, toggleFav: { viewModel.toggleFavorite(c.id) })
                                            .equatable()
                                            .id(c.id)
                                            .matchedTransitionSourceIfAvailable(id: c.id, in: zoomNS)
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                            .listRowInsets(EdgeInsets())
                                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                                Button {
                                                    viewModel.toggleFavorite(c.id)
                                                } label: {
                                                    Label(viewModel.favoriteIDs.contains(c.id) ? "Unfavorite" : "Favorite", systemImage: viewModel.favoriteIDs.contains(c.id) ? "star.slash.fill" : "star.fill")
                                                }
                                                .tint(.yellow)
                                            }
                                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                                Button(role: .destructive) {
                                                    viewModel.hideChannel(c.id)
                                                } label: {
                                                    Label("Hide", systemImage: "eye.slash.fill")
                                                }
                                                if selectedCategory?.id == -2 || viewModel.recentIDs.contains(c.id) {
                                                    Button {
                                                        viewModel.removeFromRecent(c.id)
                                                    } label: {
                                                        Label("Remove", systemImage: "clock.badge.xmark")
                                                    }
                                                    .tint(.orange)
                                                }
                                            }
                                            .contextMenu {
                                                Button { playAction(c) } label: { Label("Play", systemImage: "play.fill") }
                                                Button { viewModel.toggleFavorite(c.id) } label: { Label(viewModel.favoriteIDs.contains(c.id) ? "Unfavorite" : "Favorite", systemImage: viewModel.favoriteIDs.contains(c.id) ? "star.slash" : "star") }
                                                Button { viewModel.triggerRenameChannel(c) } label: { Label("Rename", systemImage: "pencil") }
                                                Button { viewModel.hideChannel(c.id) } label: { Label("Hide", systemImage: "eye.slash") }
                                                if let prog = viewModel.getCurrentProgram(for: c), let desc = prog.description, !desc.isEmpty {
                                                    Button { channelForDescription = c } label: { Label("Description", systemImage: "text.alignleft") }
                                                }
                                                if selectedCategory?.id == -2 || viewModel.recentIDs.contains(c.id) { Button(role: .destructive) { viewModel.removeFromRecent(c.id) } label: { Label("Remove", systemImage: "clock.badge.xmark") } }
                                            }
                                    }
                                }
                                .listStyle(.plain)
                                .scrollContentBackground(.hidden)
                                .environment(\.defaultMinListRowHeight, 0)
                            }
                        }
                        .transition(.blurFade)
                        .onAppear {
                            if let last = viewModel.lastPlayedChannelID {
                                DispatchQueue.main.async { proxy.scrollTo(last, anchor: .center) }
                            }
                        }
                            .onChangeCompat(of: viewModel.lastPlayedChannelID) { id in
                            if let id = id { proxy.scrollTo(id, anchor: .center) }
                        }
                            .onChangeCompat(of: viewModel.scrollRestoreTrigger) { _ in
                            if let last = viewModel.lastPlayedChannelID {
                                proxy.scrollTo(last, anchor: .center)
                            }
                        }
                    }
                }
            }.animation(.spring(response: 0.4, dampingFraction: 0.8), value: selectedCategory)
        }
        .alert(item: $channelForDescription) { channel in
            Alert(
                title: Text("Program Description"),
                message: Text(viewModel.getCurrentProgram(for: channel)?.description ?? "No description available."),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            if idToChannel.isEmpty {
                var map = [Int: StreamChannel]()
                map.reserveCapacity(viewModel.channels.count)
                for c in viewModel.channels { map[c.id] = c }
                idToChannel = map
            }
        }
        .task(id: viewModel.channels.count) {
            var map = [Int: StreamChannel]()
            map.reserveCapacity(viewModel.channels.count)
            for c in viewModel.channels { map[c.id] = c }
            idToChannel = map
        }
    }

    func getChannelsToShow() -> [StreamChannel] {
        guard let cat = selectedCategory else { return [] }
        if cat.id == -2 {
            return viewModel.recentIDs.compactMap { idToChannel[$0] }
        }
        if cat.id == -4 { return viewModel.channels.filter { viewModel.favoriteIDs.contains($0.id) } }
        if cat.id == -1 { return viewModel.channels.filter { !viewModel.hiddenIDs.contains($0.id) } }
        return viewModel.channels.filter { $0.categoryID == cat.id && !viewModel.hiddenIDs.contains($0.id) }
    }
}

struct CategoryDetailView: SwiftUI.View {
    let title: String; let channels: [StreamChannel]; let accentColor: Color; let playAction: (StreamChannel) -> Void; let toggleFav: (Int) -> Void; let promptRename: (StreamChannel) -> Void; let hideChannel: (Int) -> Void; let favoriteIDs: Set<Int>; @ObservedObject var viewModel: ChannelViewModel; @Binding var showMultiView: Bool; var onBack: (() -> Void)? = nil; var onCategorySelect: ((StreamCategory) -> Void)? = nil; var zoomNS: Namespace.ID? = nil
    @AppStorage("nebColor1") private var nebColor1 = "#1A2538"; @AppStorage("nebColor2") private var nebColor2 = "#11101A"; @AppStorage("nebColor3") private var nebColor3 = "#1F1A24"; @AppStorage("nebX1") private var nebX1 = 0.5; @AppStorage("nebY1") private var nebY1 = 0.0; @AppStorage("nebX2") private var nebX2 = 0.5; @AppStorage("nebY2") private var nebY2 = 0.5; @AppStorage("nebX3") private var nebX3 = 0.5; @AppStorage("nebY3") private var nebY3 = 1.0
    @State private var channelForDescription: StreamChannel?
    
    var body: some SwiftUI.View {
        ZStack {
            NebulaBackgroundView(color1: Color(hex: nebColor1) ?? .purple, color2: Color(hex: nebColor2) ?? .blue, color3: Color(hex: nebColor3) ?? .pink, point1: UnitPoint(x: nebX1, y: nebY1), point2: UnitPoint(x: nebX2, y: nebY2), point3: UnitPoint(x: nebX3, y: nebY3))
            
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    Group {
                        if !viewModel.searchText.isEmpty {
                            Text("Search Results").font(.headline).padding()
                        } else {
                            List {
                                ForEach(channels) { c in
                                    ChannelRow(channel: c, epgProgram: viewModel.getCurrentProgram(for: c), isFavorite: favoriteIDs.contains(c.id), accentColor: accentColor, playAction: { playAction(c) }, toggleFav: { toggleFav(c.id) })
                                        .equatable()
                                        .id(c.id)
                                        .matchedTransitionSourceIfAvailable(id: c.id, in: zoomNS)
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets())
                                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                            Button {
                                                toggleFav(c.id)
                                            } label: {
                                                Label(favoriteIDs.contains(c.id) ? "Unfavorite" : "Favorite", systemImage: favoriteIDs.contains(c.id) ? "star.slash.fill" : "star.fill")
                                            }
                                            .tint(.yellow)
                                        }
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                hideChannel(c.id)
                                            } label: {
                                                Label("Hide", systemImage: "eye.slash.fill")
                                            }
                                        }
                                        .contextMenu {
                                            Button { playAction(c) } label: { Label("Play", systemImage: "play.fill") }
                                            Button { toggleFav(c.id) } label: { Label(favoriteIDs.contains(c.id) ? "Unfavorite" : "Favorite", systemImage: favoriteIDs.contains(c.id) ? "star.slash" : "star") }
                                            Button { promptRename(c) } label: { Label("Rename", systemImage: "pencil") }
                                            Button { hideChannel(c.id) } label: { Label("Hide", systemImage: "eye.slash") }
                                            if let prog = viewModel.getCurrentProgram(for: c), let desc = prog.description, !desc.isEmpty {
                                                Button { channelForDescription = c } label: { Label("Description", systemImage: "text.alignleft") }
                                            }
                                        }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .environment(\.defaultMinListRowHeight, 0)
                        }
                    }
                    .onAppear {
                        if let last = viewModel.lastPlayedChannelID {
                            DispatchQueue.main.async { proxy.scrollTo(last, anchor: .center) }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let onBack = onBack {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
        }
        .alert(item: $channelForDescription) { channel in
            Alert(
                title: Text("Program Description"),
                message: Text(viewModel.getCurrentProgram(for: channel)?.description ?? "No description available."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

struct MiniPlayerView: SwiftUI.View {
    let channel: StreamChannel
    let viewModel: ChannelViewModel
    let onExpand: () -> Void
    let onClose: () -> Void
    
    @ObservedObject var playerManager = NebuloPlayerEngine.shared
    
    @State private var showControls = false
    @State private var pipOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some SwiftUI.View {
        ZStack {
            UnifiedPlayerViewBridge()
                .frame(width: 240, height: 135)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
            
            
            Color.black.opacity(0.001)
                .frame(width: 240, height: 135)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        showControls.toggle()
                    }
                }
            
            if showControls {
                ZStack {
                    Color.black.opacity(0.3)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .allowsHitTesting(false)
                    
                    Button(action: {
                        if playerManager.isPlaying { playerManager.pause() } else { playerManager.resume() }
                    }) {
                        Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2.weight(.bold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .padding(12)
                            .modifier(GlassEffect(cornerRadius: 22, isSelected: true, accentColor: nil))
                    }
                    .buttonStyle(.plain)
                    
                    VStack {
                        HStack {
                            Button(action: {
                                onClose()
                                NebuloPlayerEngine.shared.stop()
                            }) {
                                Image(systemName: "xmark")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .modifier(GlassEffect(cornerRadius: 16, isSelected: true, accentColor: nil))
                            }
                            .buttonStyle(.plain)
                            
                            Spacer()
                            
                            Button(action: onExpand) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .modifier(GlassEffect(cornerRadius: 16, isSelected: true, accentColor: nil))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(8)
                        Spacer()
                    }
                }
                .frame(width: 240, height: 135)
                .zIndex(10)
            }
        }
        .frame(width: 240, height: 135)
        .offset(pipOffset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    pipOffset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                }
                .onEnded { value in
                    let screenWidth = UIScreen.main.bounds.width
                    let screenHeight = UIScreen.main.bounds.height
                    let pipWidth: CGFloat = 240
                    let pipHeight: CGFloat = 135
                    
                    let horizontalRange = screenWidth - pipWidth - 40
                    let verticalRange = screenHeight - pipHeight - 120
                    
                    let targetX: CGFloat = pipOffset.width > -horizontalRange / 2 ? 0 : -horizontalRange
                    let targetY: CGFloat = pipOffset.height < -verticalRange / 2 ? -verticalRange + 60 : 0
                    
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        pipOffset = CGSize(width: targetX, height: targetY)
                        lastOffset = pipOffset
                    }
                }
        )
    }
}

struct SwipeBackModifier: ViewModifier {
    let onBack: () -> Void
    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            content
            
            
            Color.clear
                .frame(width: 25)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture()
                        .onEnded { value in
                            if value.translation.width > 60 {
                                onBack()
                            }
                        }
                )
        }
    }
}

struct MultiViewIndicator: SwiftUI.View { 
    let count: Int; let accentColor: Color?; let action: () -> Void; 
    var body: some SwiftUI.View { 
        VStack {
            Spacer()
            Button(action: action) { 
                HStack { Image(systemName: "square.grid.2x2.fill"); Text("Multi-View Active: \(count)/4") }
                    .font(.caption.bold()).foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .modifier(GlassEffect(cornerRadius: 20, isSelected: true, accentColor: accentColor)) 
            }
            .padding(.bottom, 15) 
        }
    } 
}

/// Thin wrapper that observes `EPGLoadingState` directly so high-frequency
/// progress ticks (10 fps) only re-render this small view — never the main
/// channel list, category grid, or any other part of the app.
private struct EPGProgressBanner: View {
    @ObservedObject var epgState: EPGLoadingState
    let status: String
    let accentColor: Color
    let isBlocking: Bool
    let onDismiss: () -> Void

    var body: some View {
        LoadingStatusOverlay(
            status: status,
            progress: epgState.progress > 0 ? epgState.progress : nil,
            accentColor: accentColor,
            isBlocking: isBlocking,
            onDismiss: onDismiss
        )
    }
}

struct LoadingStatusOverlay: View {
    let status: String
    var progress: Double? = nil
    let accentColor: Color
    var isBlocking: Bool = true
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height

            VStack {
                HStack(spacing: 12) {
                    if progress != nil {
                        CircularProgressRing(progress: progress ?? 0, accent: accentColor)
                            .frame(width: 22, height: 22)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.primary)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(status)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let progress {
                            Text("\(Int(progress * 100))%")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .modifier(CapsuleGlassBackground())
                .padding(.top, isLandscape ? 16 : 54)
                .gesture(
                    DragGesture()
                        .onEnded { value in
                            if value.translation.height < -20 {
                                onDismiss?()
                            }
                        }
                )

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(
                isBlocking
                    ? Color.black.opacity(0.35)
                    : Color.clear
            )
            .ignoresSafeArea()
            .allowsHitTesting(isBlocking)
        }
    }
}

private struct CapsuleGlassBackground: ViewModifier {
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

private struct CircularProgressRing: View {
    let progress: Double
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: progress)
        }
    }
}

// MARK: - Home Screen Components
// Apple-style typography hierarchy with YouTube TV-inspired hero card,
// glass chips, and tinted section accents. Matches the player slide aesthetic.

/// Time-aware greeting at the top of the home screen.
/// "Good Morning, Good Afternoon, Good Evening" + the current weekday/date.
struct HomeGreetingHeader: View {
    @State private var now: Date = Date()

    /// Static formatter — DateFormatter init is surprisingly expensive,
    /// and we don't want to allocate one on every body render.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: now)
        switch hour {
        case 5..<12:  return "Good Morning"
        case 12..<17: return "Good Afternoon"
        case 17..<22: return "Good Evening"
        default:      return "Good Night"
        }
    }

    private var dateString: String {
        Self.dateFormatter.string(from: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.system(size: 32, weight: .bold, design: .default))
                .foregroundStyle(.primary)
            Text(dateString)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reusable section header used across the home screen. Appears as a tappable
/// row with optional icon + chevron when an action is provided, or a static
/// label otherwise.
/// The one settings gear used everywhere — a circular liquid-glass button
/// (real glassEffect on iOS 26, ultra-thin material below) pinned to the
/// top-right of every screen so it never moves or changes style. 44×44 to
/// match the system toolbar buttons on the Sports / detail screens exactly.
struct SettingsGearButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .modifier(GlassEffect(cornerRadius: 22, isSelected: false, accentColor: nil))
        }
        .buttonStyle(.plain)
    }
}

struct HomeSectionHeader: View {
    let title: String
    var icon: String? = nil
    var iconColor: Color = .primary
    var showsChevron: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .padding(.horizontal)
    }

    private var content: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor)
            }
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Session cache of logo URL → extracted glow colour so each icon is
/// analysed at most once.
@MainActor
private enum LogoGlowCache {
    static var colors: [String: Color] = [:]
}

private extension UIImage {
    /// The logo's "brand colour": average of its saturated opaque pixels
    /// (falling back to all opaque pixels for monochrome logos), brightened
    /// so it reads as a glow on a dark card. Samples a 16×16 downscale, so
    /// the cost is negligible.
    func glowColor() -> UIColor? {
        guard let cg = cgImage else { return nil }
        let w = 16, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        var satR = 0.0, satG = 0.0, satB = 0.0, satN = 0.0
        var allR = 0.0, allG = 0.0, allB = 0.0, allN = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }
            let r = Double(pixels[i]) / 255 / a
            let g = Double(pixels[i + 1]) / 255 / a
            let b = Double(pixels[i + 2]) / 255 / a
            allR += r; allG += g; allB += b; allN += 1
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            if sat > 0.3 && mx > 0.15 {
                satR += r; satG += g; satB += b; satN += 1
            }
        }
        guard allN > 0 else { return nil }
        let useSat = satN >= max(4, allN * 0.05)
        var r = useSat ? satR / satN : allR / allN
        var g = useSat ? satG / satN : allG / allN
        var b = useSat ? satB / satN : allB / allN
        // Brighten dark brand colours so the glow stays visible on the card.
        let mx = max(r, g, b)
        if mx > 0, mx < 0.55 { let k = 0.55 / mx; r *= k; g *= k; b *= k }
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}

/// Hero card for the featured carousel.
///
/// Uses a base Rectangle of fixed height so the card's size is never derived
/// from any child — then stacks all visual layers and content via .overlay()
/// modifiers. This is the only layout technique that is 100% immune to the
/// "ZStack children expand beyond the clip frame" problem that occurred with
/// ZStack + Spacer and ZStack + .frame(maxHeight:.infinity) approaches:
/// children with oversized frames (e.g. 260-pt glow circles) set the ZStack's
/// natural height, .frame(height:200) then centres that taller content inside
/// 200 pt, clipping both the pill at the top and the resume button at the bottom.
/// Overlay modifiers do not participate in layout — they cannot inflate the
/// base view's frame.
struct FeaturedHeroCard: View {
    let channel: StreamChannel
    let program: EPGProgram?
    let accentColor: Color
    let onPlay: () -> Void

    /// When set, the glow uses this colour and skips logo extraction —
    /// sports channels glow in the app accent so the whole sports experience
    /// (hub, featured game card, hero card) shares one identity.
    var glowOverride: Color? = nil

    /// Glow colour extracted from the channel logo (see LogoGlowCache).
    /// Neutral warm-white until the logo is loaded and analysed.
    @State private var glowColor: Color? = nil

    private static let cardHeight: CGFloat = 200

    var body: some View {
        Button(action: onPlay) {
            Rectangle()
                .fill(Color.clear)
                // ── 1. Solid gradient base — always fills the card even while
                //       the image is loading or if it's transparent/square-padded
                .overlay {
                    // Neutral dark base — the blurred channel-logo layer above
                    // provides the card's colour. An accent-tinted base washed
                    // every card in blue regardless of the channel's branding.
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), Color.black.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                // ── 2. Blurred logo texture — moderate size; blur radius 55 + 1.8×
                //       scale destroys all fine detail so there's no visual
                //       difference vs 500 pt, but ~90 % less memory per card.
                .overlay {
                    CachedAsyncImage(urlString: channel.icon ?? "",
                                     size: CGSize(width: 160, height: 160))
                        .blur(radius: 55)
                        .opacity(0.48)
                        .scaleEffect(1.8)
                        .allowsHitTesting(false)
                }
                // ── 3. Brand glow circles — tinted with the dominant colour of
                //       the channel's logo (extracted async below) so every
                //       card glows in its own branding rather than the accent.
                .overlay {
                    Circle()
                        .fill((glowOverride ?? glowColor ?? Color(white: 0.75)).opacity(0.55))
                        .frame(width: 200, height: 200)
                        .blur(radius: 60)
                        .offset(x: -60, y: 20)
                        .allowsHitTesting(false)
                }
                .overlay {
                    Circle()
                        .fill((glowOverride ?? glowColor ?? Color(white: 0.75)).opacity(0.30))
                        .frame(width: 130, height: 130)
                        .blur(radius: 40)
                        .offset(x: 40, y: 10)
                        .allowsHitTesting(false)
                }
                // ── 4. Darkening gradient for text legibility ────────────
                .overlay {
                    LinearGradient(
                        colors: [Color.black.opacity(0.05),
                                 Color.black.opacity(0.65)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                // ── 4. Top bar: FEATURED pill (left) · Resume pill (right) ─
                //       Both live in one HStack so they share the same baseline
                //       and can never crowd the bottom text area.
                .overlay(alignment: .top) {
                    HStack {
                        // FEATURED pill
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8, weight: .black))
                            Text("FEATURED")
                                .font(.caption2.weight(.black))
                                .kerning(1.4)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.85), in: Capsule())

                        Spacer()

                        // Resume pill — top-right, never touches the text below
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.caption.weight(.bold))
                            Text("Resume")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.white, in: Capsule())
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 16)
                }
                // ── 5. Bottom row: logo · channel/EPG info ───────────────
                //       Resume is gone from here so the text has full width.
                .overlay(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: 14) {
                        // Channel logo box
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.ultraThinMaterial)
                            CachedAsyncImage(urlString: channel.icon ?? "", size: nil)
                                .padding(12)
                        }
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                        )

                        // Channel name + full-width EPG text
                        VStack(alignment: .leading, spacing: 3) {
                            Text(channel.name)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if let prog = program {
                                Text(prog.title)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                if let desc = prog.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.62))
                                        .lineLimit(2)
                                }
                            } else {
                                Text("Tap to resume watching")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.bottom, 16)
                    .padding(.horizontal, 16)
                }
                // ── Frame & clip ─────────────────────────────────────────
                .frame(height: Self.cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                // Rasterise the whole card once: the 55-pt logo blur and the
                // two glow blurs otherwise re-composite on the GPU every
                // scroll frame, which showed up as home-screen jitter.
                .drawingGroup()
                .shadow(color: .black.opacity(0.32), radius: 18, x: 0, y: 8)
        }
        .buttonStyle(PressableCardStyle())
        .task(id: channel.icon) {
            guard glowOverride == nil else { return }
            guard let icon = channel.icon, !icon.isEmpty else { glowColor = nil; return }
            if let cached = LogoGlowCache.colors[icon] { glowColor = cached; return }
            // The logo may still be downloading (CachedAsyncImage above owns
            // the fetch) — poll the shared cache briefly rather than kicking
            // off a duplicate download.
            for _ in 0..<12 {
                if let ui = ImageCache.shared.get(forKey: icon, size: CGSize(width: 160, height: 160)) {
                    if let extracted = ui.glowColor() {
                        let c = Color(extracted)
                        LogoGlowCache.colors[icon] = c
                        withAnimation(.easeIn(duration: 0.5)) { glowColor = c }
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}

/// Four Quick Access destinations in a single unified glass panel.
/// Hairline dividers separate each item. One continuous background is
/// cleaner than four separate tiles fighting for attention.
struct QuickAccessPanel: View {
    let accentColor: Color
    let sportsAction: () -> Void
    let favoritesAction: () -> Void
    let recordingsAction: () -> Void
    let multiViewAction: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack(spacing: 0) {
            qaItem("Sports",     "sportscourt.fill",   sportsAction)
            divider
            qaItem("Favorites",  "star.fill",          favoritesAction)
            divider
            qaItem("Recordings", "record.circle.fill", recordingsAction)
            divider
            qaItem("Multi-View", "square.grid.2x2.fill", multiViewAction)
        }
        .modifier(PanelGlass(shape: shape))
        // Pin the panel's tap target to its bounds so hit testing isn't
        // affected by `.animation()` modifiers higher up the tree. Without
        // this, returning from a CategoryDetailView could leave the trailing
        // buttons un-hittable until the implicit spring animation settled.
        .contentShape(shape)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 0.5)
            .padding(.vertical, 12)
    }

    @ViewBuilder
    private func qaItem(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelItemButtonStyle())
    }
}

/// Subtle press highlight for items inside a shared panel — no scale effect
/// (which would look wrong when only one quarter of the card moves).
private struct PanelItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.white.opacity(configuration.isPressed ? 0.08 : 0)
                    .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            )
    }
}

/// Glass backing shared by the panel. Liquid Glass on iOS 26, ultra-thin
/// material on earlier versions.
///
/// The previous implementation wrapped the result in `AnyView`, which forces
/// SwiftUI to throw away and rebuild the entire view tree on every render —
/// that broke hit testing for the trailing buttons in the Quick Access
/// panel after returning from a detail view (the buttons were getting
/// rebuilt while their tap targets were still mid-animation).
private struct PanelGlass: ViewModifier {
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular, in: shape)
                    .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 0.5))
            } else {
                content
                    .background(.ultraThinMaterial)
                    .clipShape(shape)
                    .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 0.5))
            }
        }
    }
}

/// Horizontal genre filter chips at the top of the home screen.
/// "For You" is always first and represents the default mixed-genre view
/// (selected = `nil`). The remaining chips are the home category groups
/// that actually have channels — empty buckets are hidden so the row only
/// shows what the user can actually filter to.
///
/// The chip row is rendered inside a `UIScrollView` wrapper rather than a
/// SwiftUI `ScrollView`. SwiftUI's horizontal `ScrollView` leaves its pan
/// gesture in a "tracking" state after a swipe, which then blocks taps on
/// the chips themselves AND on sibling Quick Access buttons below until
/// the app is restarted. Setting `delaysContentTouches = false` on the
/// underlying UIScrollView (which SwiftUI doesn't expose) cleanly hands
/// touches to the inner buttons immediately on every tap.
struct HomeFilterChips: View {
    let groups: [HomeCategoryGroup]
    @Binding var selected: HomeCategoryGroup?

    var body: some View {
        TouchPassingHorizontalScroll {
            HStack(spacing: 10) {
                chip(title: "For You",
                     isSelected: selected == nil,
                     onTap: { withAnimation(.easeOut(duration: 0.2)) { selected = nil } })
                ForEach(groups, id: \.self) { group in
                    chip(title: group.rawValue,
                         isSelected: selected == group,
                         onTap: {
                             withAnimation(.easeOut(duration: 0.2)) {
                                 selected = (selected == group) ? nil : group
                             }
                         })
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private func chip(title: String, isSelected: Bool, onTap: @escaping () -> Void) -> some View {
        // `onTapGesture` instead of `Button` — Button installs a long-press
        // gesture that conflicts with the scroll view's pan, making taps
        // mid-scroll fail to register. `onTapGesture` is a plain tap and
        // resolves immediately.
        Text(title)
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 10)
            .padding(.horizontal, 18)
            .background(
                // Opaque fill — uniform with the pinned chip rows in the
                // Sports and Favorites sections.
                Capsule()
                    .fill(isSelected ? Color.white : SportSelectorView.chipFill)
            )
            .foregroundStyle(isSelected ? Color.black : Color.primary)
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isSelected ? 0 : 0.18), lineWidth: 0.5)
            )
            .contentShape(Capsule())
            .onTapGesture {
                ChannelViewModel.shared.triggerSelectionHaptic()
                onTap()
            }
    }
}

/// Horizontal scroller backed by `UIScrollView` with `delaysContentTouches`
/// disabled — the missing piece that SwiftUI's `ScrollView` doesn't expose.
/// Without this, the inner pan gesture stays in a tracking state for ~half
/// a second after every swipe and silently swallows taps. Used by the chip
/// row and the home-page Live Now / Continue Watching shelves.
struct TouchPassingHorizontalScroll<Content: View>: UIViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        // The two crucial settings: don't intercept taps, don't cancel them
        // until the user is actually dragging.
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.backgroundColor = .clear

        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        // `safeAreaRegions = []` keeps SwiftUI from inset-shrinking the
        // hosted content based on the parent scroll view's safe area —
        // we manage padding inside the chip HStack ourselves.
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
        scrollView.addSubview(host.view)

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            host.view.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        context.coordinator.host = host
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.host?.rootView = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: UIHostingController<Content>?
    }
}

/// "Live Now" horizontal shelf — currently-live sports games across every
/// sport. Tapping a card runs the existing smart-search pipeline to find
/// and play the channel broadcasting that game.
struct LiveGamesPreviewList: View {
    let games: [ESPNEvent]
    @ObservedObject var scoreViewModel: ScoreViewModel
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color

    var body: some View {
        // UIScrollView wrapper — see comment on TouchPassingHorizontalScroll.
        // Prevents the post-swipe gesture lockout that makes Quick Access
        // buttons un-tappable after scrolling this shelf.
        TouchPassingHorizontalScroll {
            HStack(spacing: 14) {
                ForEach(games) { game in
                    LiveGameCard(game: game, accentColor: accentColor)
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .onTapGesture {
                            viewModel.triggerSelectionHaptic()
                            let h = game.homeCompetitor?.team?.shortDisplayName ?? game.homeCompetitor?.athlete?.shortName ?? ""
                            let a = game.awayCompetitor?.team?.shortDisplayName ?? game.awayCompetitor?.athlete?.shortName ?? ""
                            let sport = scoreViewModel.sportType(for: game)
                            viewModel.runSmartSearch(gameID: game.id, home: h, away: a, sport: sport, network: game.broadcastName)
                        }
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 170)
    }
}

/// Compact card for a live sports game on the home shelf — team logos,
/// score, and broadcast network. Mirrors the visual weight of the
/// Continue Watching cards so the home page reads as one coherent list.
struct LiveGameCard: View {
    let game: ESPNEvent
    let accentColor: Color

    private var homeName: String {
        game.homeCompetitor?.team?.shortDisplayName
            ?? game.homeCompetitor?.team?.abbreviation
            ?? game.homeCompetitor?.athlete?.shortName
            ?? "—"
    }
    private var awayName: String {
        game.awayCompetitor?.team?.shortDisplayName
            ?? game.awayCompetitor?.team?.abbreviation
            ?? game.awayCompetitor?.athlete?.shortName
            ?? "—"
    }
    private var homeLogo: String {
        game.homeCompetitor?.team?.logo
            ?? game.homeCompetitor?.athlete?.flag?.href
            ?? game.homeCompetitor?.athlete?.headshot
            ?? ""
    }
    private var awayLogo: String {
        game.awayCompetitor?.team?.logo
            ?? game.awayCompetitor?.athlete?.flag?.href
            ?? game.awayCompetitor?.athlete?.headshot
            ?? ""
    }
    private var homeScore: String { game.homeCompetitor?.score ?? "0" }
    private var awayScore: String { game.awayCompetitor?.score ?? "0" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: LIVE badge + status detail
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("LIVE")
                        .font(.system(size: 10, weight: .black))
                        .kerning(0.6)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.85), in: Capsule())

                Text(game.status.type.detail.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 12)

            // Teams + scores
            HStack(spacing: 0) {
                teamColumn(name: awayName, logo: awayLogo, score: awayScore)
                Text("vs")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                teamColumn(name: homeName, logo: homeLogo, score: homeScore)
            }

            Spacer(minLength: 0)

            // Footer: broadcast network
            if let network = game.broadcastName, !network.isEmpty {
                Text(network)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(.top, 10)
            }
        }
        .padding(14)
        .frame(width: 230, height: 160, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func teamColumn(name: String, logo: String, score: String) -> some View {
        VStack(spacing: 6) {
            CachedAsyncImage(urlString: logo, size: CGSize(width: 36, height: 36))
                .frame(width: 36, height: 36)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(score)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Swipeable hero carousel backed by TabView(.page) — the most gesture-stable
/// paging API in SwiftUI (uses UIPageViewController underneath). The earlier
/// custom-ScrollView + .scrollTargetBehavior + .scrollPosition(id:) approach
/// left UIScrollView gesture recognisers in a stuck state after a swipe,
/// permanently blocking taps on sibling views. TabView avoids this entirely.
struct FeaturedCarousel: View {
    let channels: [StreamChannel]
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color
    let playAction: (StreamChannel) -> Void

    /// Tracks the visible page index for the pill dots and TabView selection.
    @State private var currentIndex: Int = 0

    var body: some View {
        VStack(spacing: 10) {
            TabView(selection: $currentIndex) {
                ForEach(0 ..< channels.count, id: \.self) { i in
                    let channel = channels[i]
                    // Sports channels glow in the accent colour (matching the
                    // Sports hub's featured card); everything else glows in
                    // the dominant colour of its own logo.
                    let isSports = viewModel.categories.first(where: { $0.id == channel.categoryID })
                        .map { HomeCategoryGroup.classify($0) == .sports } ?? false
                    FeaturedHeroCard(
                        channel: channel,
                        program: viewModel.getCurrentProgram(for: channel),
                        accentColor: accentColor,
                        onPlay: {
                            viewModel.triggerSelectionHaptic()
                            playAction(channel)
                        },
                        glowOverride: isSports ? accentColor : nil
                    )
                    // Horizontal padding gives the card breathing room and
                    // lets the nebula gradient peek at the edges — same visual
                    // weight as the previous scroll-based design.
                    .padding(.horizontal, 16)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // TabView's own background must be clear so the nebula shows through.
            .background(Color.clear)
            .frame(height: 200)

            // Pill-style page dots — only when there is more than one card.
            if channels.count > 1 {
                HStack(spacing: 5) {
                    ForEach(channels.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == currentIndex
                                  ? Color.primary.opacity(0.75)
                                  : Color.primary.opacity(0.22))
                            .frame(width: i == currentIndex ? 20 : 6, height: 6)
                            .animation(.spring(response: 0.35, dampingFraction: 0.8),
                                       value: currentIndex)
                    }
                }
            }
        }
    }
}

// MARK: - Category Grouping
// Classifies user categories into broader genre buckets for the home screen
// shelves. Uses keyword matching against the lowercased category name with
// common country-code prefixes (e.g. "US:", "UK -") stripped out first.

enum HomeCategoryGroup: String, CaseIterable, Hashable {
    case sports        = "Sports"
    case news          = "News"
    case movies        = "Movies"
    case kids          = "Kids"
    case documentary   = "Documentaries"
    case lifestyle     = "Lifestyle"
    case international = "International"
    case other         = "More"

    var icon: String {
        switch self {
        case .sports:        return "sportscourt.fill"
        case .news:          return "newspaper.fill"
        case .movies:        return "film.fill"
        case .kids:          return "face.smiling.fill"
        case .documentary:   return "books.vertical.fill"
        case .lifestyle:     return "leaf.fill"
        case .international: return "globe"
        case .other:         return "rectangle.grid.2x2.fill"
        }
    }

    /// Strip common country-code prefixes ("US:", "USA |", "UK -", etc.) so
    /// that "US: Animal Planet" still classifies as Documentary.
    nonisolated private static func cleanedName(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let pattern = #"^([a-z]{2,4})\s*[:|\-–—]\s*"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(lowered.startIndex..., in: lowered)
            return regex.stringByReplacingMatches(in: lowered, options: [], range: range, withTemplate: "")
        }
        return lowered
    }

    nonisolated private static func contains(_ haystack: String, _ keywords: [String]) -> Bool {
        keywords.contains { haystack.contains($0) }
    }

    nonisolated static func classify(_ category: StreamCategory) -> HomeCategoryGroup {
        let n = cleanedName(category.name)

        // Sports — checked FIRST so "Fox Sports", "ESPN", "Bein Sport", etc. never leak
        // into news. Covers all mainstream and niche sports worldwide.
        if contains(n, [
            // Generic
            "sport", "deport", "ppv", "pay-per-view", "pay per view",
            // Football / Soccer
            "football", "soccer", "fútbol", "futbol",
            "nfl", "ncaa", "college football",
            "premier league", "champions league", "europa league", "conference league",
            "mls", "la liga", "serie a", "bundesliga", "ligue 1", "liga mx",
            "eredivisie", "primeira liga", "super lig",
            "brasileirao", "brasileirão", "campeonato brasileiro",
            "j league", "j-league", "j1 league",
            "k league", "k-league",
            "a-league", "a league",
            "scottish premiership", "scottish prem", "spfl",
            "efl", "fa cup", "carabao cup", "dfb pokal", "coppa italia", "copa del rey",
            "copa america", "euro ", "euros ", "world cup",
            "africa cup", "afcon", "concacaf", "libertadores", "sudamericana",
            // Basketball
            "nba", "basketball", "wnba", "euroleague", "fiba",
            // Baseball / Hockey
            "mlb", "nhl", "baseball", "hockey",
            // Combat sports
            "ufc", "wwe", "aew", "boxing", "bellator", "pfl", "mma", "wrestling",
            "kickboxing", "muay thai", "judo", "taekwondo", "karate",
            // Motorsport
            "motogp", "moto gp", "f1", "formula 1", "formula one", "nascar",
            "indycar", "racing", "race ", "supercross", "superbike",
            "dtm", "wrc", "rally", "le mans", "lemans", "endurance racing",
            // Golf
            "golf", "pga", "lpga",
            // Tennis
            "tennis", "atp", "wta", "wimbledon", "us open tennis",
            // Cricket
            "cricket", "ipl", "bbl", "test match",
            // Rugby
            "rugby", "nrl", "afl", "gaelic",
            // Olympic / multi-sport
            "olympic", "paralympic",
            // Networks
            "espn", "beinsport", "bein sport", "sky sport", "fox sport",
            "nbcsn", "golf channel", "tennis channel", "tnt sport",
            "dazn", "eleven sport",
            // Darts / Snooker / Cue sports
            "darts", "snooker", "billiard",
            // Cycling
            "cycling", "tour de france", "giro d'italia", "giro d italia",
            "vuelta a españa", "vuelta a espana", "velodrome",
            // Athletics / Track and Field
            "athletics", "track and field", "marathon",
            // Swimming / Aquatics
            "swimming", "aquatic",
            // Gymnastics / Winter sports
            "gymnastics", "figure skat", "biathlon", "curling", "bobsled", "luge",
            "ski", "skiing", "snowboard",
            // Volleyball / Handball / Water polo / Racket
            "volleyball", "handball", "waterpolo", "water polo",
            "badminton", "table tennis", "ping pong", "squash",
            // Esports / Gaming
            "esport", "e-sport", "esports", "gaming league",
            // Horse racing / Equestrian
            "horse racing", "equestrian",
            // Poker / Card
            "poker", "wsop",
            // Misc
            "kabaddi", "sumo", "netball", "lacrosse", "field hockey",
            "beach volley", "beach soccer", "futsal"
        ]) { return .sports }

        // News — major broadcast networks (ABC, NBC, CBS, PBS, Fox) plus cable/intl news.
        // Comes after Sports so "Fox Sports" is already captured, leaving plain "Fox" for news.
        if contains(n, [
            "news", "noticias",
            // US broadcast & cable
            "abc", "nbc", "cbs", "pbs", "fox",
            "cnn", "msnbc", "cnbc", "bloomberg", "cspan", "oann", "newsmax",
            // International
            "bbc", "sky news", "itv", "channel 4", "channel 5",
            "ctv", "cbc", "sbs",
            "al jazeera", "france 24", "dw", "euronews", "trt world",
            "abc news", "nbc news", "cbs news"
        ]) { return .news }

        // Kids — checked before Movies so "Disney Channel" / "Cartoon Network"
        // map to Kids rather than Movies. Common kids networks worldwide.
        if contains(n, [
            "kids", "child", "children",
            "cartoon", "cartoons",
            "nick", "nickelodeon", "nick jr", "nickjr",
            "disney",
            "cbeebies", "cbbc", "milkshake",
            "pbs kids", "pbskids",
            "boomerang", "cartoonito",
            "baby tv", "babyfirst", "babytv",
            "cocomelon", "paw patrol", "peppa", "sesame"
        ]) { return .kids }

        // Movies — checked before documentaries so "movie history" still hits Movies.
        if contains(n, [
            "movie", "movies", "film", "films", "cinema", "cinemax",
            "hbo", "showtime", "starz", "epix",
            "mgm", "tcm", "amc", "fxm", "fxx",
            "thriller", "horror", "action", "drama", "romance",
            "blockbuster", "indie", "independent film",
            "bollywood", "hollywood", "kollywood",
            "24/7", "marathon", "saga", "franchise"
        ]) { return .movies }

        if contains(n, ["doc", "history", "discovery", "national geographic", "nat geo",
                        "smithsonian", "science", "animal planet", "viasat"]) { return .documentary }

        if contains(n, ["food", "cooking", "home", "garden", "travel", "lifestyle", "fashion",
                        "hgtv", "diy", "fitness", "health", "wellness"]) { return .lifestyle }

        // International — country names, language identifiers, and regional labels.
        // Checked after all specific genres so e.g. "France 24" (news) is already matched.
        if contains(n, [
            // Regional / group labels
            "international", "world", "global",
            "latin", "latino", "latina", "hispanic",
            "africa", "afrique", "asia", "europe", "middle east",
            // Language names
            "arabic", "français", "french", "deutsch", "german",
            "español", "spanish", "italiano", "italian",
            "português", "portuguese",
            "hindi", "urdu", "farsi", "persian",
            "turkish", "korean", "japanese", "chinese", "mandarin", "cantonese",
            "russian", "polish", "romanian", "hungarian", "czech", "slovak",
            "bulgarian", "serbian", "croatian", "albanian", "greek", "hebrew",
            "ukrainian", "armenian", "azerbaijani", "georgian",
            "thai", "vietnamese", "indonesian", "malay", "tagalog", "filipino",
            "punjabi", "bengali", "tamil", "telugu", "marathi", "gujarati",
            "swahili", "somali", "amharic", "hausa",
            // Country names
            "france", "germany", "spain", "italy", "portugal",
            "brazil", "mexico", "argentina", "colombia", "venezuela",
            "chile", "peru", "ecuador", "bolivia", "paraguay", "uruguay",
            "india", "pakistan", "bangladesh", "nepal", "sri lanka",
            "china", "japan", "korea", "taiwan", "thailand", "vietnam",
            "philippines", "indonesia", "malaysia", "singapore", "myanmar",
            "turkey", "iran", "iraq", "saudi", "egypt", "algeria", "morocco",
            "tunisia", "nigeria", "kenya", "ghana", "ethiopia", "tanzania",
            "south africa", "cameroon", "ivory coast", "senegal",
            "australia", "new zealand",
            "poland", "romania", "hungary", "ukraine", "russia",
            "netherlands", "belgium", "sweden", "norway", "denmark", "finland",
            "austria", "switzerland", "israel", "lebanon", "jordan", "syria",
            "qatar", "uae", "kuwait", "bahrain", "oman"
        ]) { return .international }

        return .other
    }
}



