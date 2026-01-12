import SwiftUI
import AVFoundation
import Combine

// MARK: - MAIN VIEW
struct MainView: SwiftUI.View {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @AppStorage("xstreamURL") private var xstreamURL = ""; @AppStorage("username") private var username = ""; @AppStorage("password") private var password = ""; @AppStorage("loginTypeRaw") private var loginTypeRaw = LoginType.xtream.rawValue; @AppStorage("viewMode") private var viewMode = ViewMode.automatic.rawValue; @AppStorage("customAccentHex") private var customAccentHex = "#007AFF"; @AppStorage("nebColor1") private var nebColor1 = "#AF52DE"; @AppStorage("nebColor2") private var nebColor2 = "#007AFF"; @AppStorage("nebColor3") private var nebColor3 = "#FF2D55"; @AppStorage("nebX1") private var nebX1 = 0.2; @AppStorage("nebY1") private var nebY1 = 0.2; @AppStorage("nebX2") private var nebX2 = 0.8; @AppStorage("nebY2") private var nebY2 = 0.3; @AppStorage("nebX3") private var nebX3 = 0.5; @AppStorage("nebY3") private var nebY3 = 0.8
    @AppStorage("showSupportPopup") private var showSupportPopup = true
    @AppStorage("lastSupportPopupTime") private var lastSupportPopupTime: Double = 0
    
    @State private var selectedCategory: StreamCategory?
    @State private var selectedChannel: StreamChannel?
    @State private var showSettings = false
    @State private var showMultiView = false
    @State private var showQuickSwitcher = false
    @State private var showSupportAlert = false
    @State private var selectedRecording: Recording?
    @State private var isPlayerActive: Bool = false
    
    let refreshTimer = Timer.publish(every: 14400, on: .main, in: .common).autoconnect()
    var accentColor: Color { Color(hex: customAccentHex) ?? .blue }
    
    var body: some SwiftUI.View {
        GeometryReader { geo in
            let isL = geo.size.width > geo.size.height
            ZStack {
                backgroundLayer
                
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
        .onReceive(refreshTimer) { _ in 
            Task { 
                await viewModel.loadData(url: xstreamURL, user: username, pass: password, type: LoginType(rawValue: loginTypeRaw) ?? .xtream, silent: true) 
            } 
        }
        .onChangeCompat(of: viewModel.channelToAutoPlay) { nc in 
            if let c = nc { 
                withAnimation(.easeInOut(duration: 0.4)) { selectedChannel = c }
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
                backgroundLayer
                contentLayout(isL: isL)
                
                if viewModel.activeMultiViewCount > 0 && !showMultiView && selectedChannel == nil { 
                    MultiViewIndicator(count: viewModel.activeMultiViewCount, accentColor: nil, action: { withAnimation(.spring()) { showMultiView = true } }).zIndex(5) 
                }
            }
            .modifier(MainViewModifiers(
                viewModel: viewModel,
                scoreViewModel: scoreViewModel, // Pass scoreViewModel here
                showMultiView: $showMultiView,
                showSettings: $showSettings,
                showSupportAlert: $showSupportAlert,
                showSupportPopup: $showSupportPopup,
                selectedRecording: $selectedRecording,
                accentColor: accentColor,
                playAction: playChannel
            ))
        }
    }

    @ViewBuilder
    private func contentLayout(isL: Bool) -> some View {
        Group {
            if shouldUseSidebar(isLandscape: isL) { 
                SidebarLayout(viewModel: viewModel, scoreViewModel: scoreViewModel, selectedCategory: $selectedCategory, selectedChannel: $selectedChannel, searchText: $viewModel.searchText, isLandscape: isL, accentColor: accentColor, playAction: playChannel, showMultiView: $showMultiView, showSettings: $showSettings) 
            } else { 
                StandardLayout(viewModel: viewModel, scoreViewModel: scoreViewModel, selectedCategory: $selectedCategory, selectedChannel: $selectedChannel, searchText: $viewModel.searchText, accentColor: accentColor, playAction: playChannel, showMultiView: $showMultiView, showSettings: $showSettings, selectedRecording: $selectedRecording) 
            }
        }
        .zIndex(1)
    }
}

struct MainViewModifiers: ViewModifier {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel // Added ScoreViewModel
    @Binding var showMultiView: Bool
    @Binding var showSettings: Bool
    @Binding var showSupportAlert: Bool
    @Binding var showSupportPopup: Bool
    @Binding var selectedRecording: Recording?
    let accentColor: Color
    let playAction: (StreamChannel) -> Void

    func body(content: Content) -> some View {
        let showRenameAlert = Binding(get: { viewModel.showRenameAlert }, set: { viewModel.showRenameAlert = $0 })
        let renameInput = Binding(get: { viewModel.renameInput }, set: { viewModel.renameInput = $0 })
        let showNoStreamsAlert = Binding(get: { viewModel.showNoStreamsAlert }, set: { viewModel.showNoStreamsAlert = $0 })
        let categories = Binding(get: { viewModel.categories }, set: { viewModel.categories = $0 })
        let searchText = Binding(get: { viewModel.searchText }, set: { viewModel.searchText = $0 })

        content
            .applyIf(!showMultiView) { view in
                view.searchable(text: searchText, prompt: "Search").toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack {
                            Button(action: { withAnimation(.spring()) { showMultiView = true } }) { 
                                Image(systemName: "square.grid.2x2.fill").foregroundStyle(.white.opacity(0.8)) 
                            }
                            Button(action: { showSettings = true }) { 
                                Image(systemName: "gearshape.fill").foregroundStyle(.white.opacity(0.8)) 
                            }
                        }
                    }
                }
            }
            .fullScreenCover(item: $selectedRecording) { recording in 
                // Placeholder for RecordingPlayerView if not defined in this file
                // Assuming it exists or will be handled
                Text("Recording Player") 
            }
            .sheet(isPresented: $showSettings) { SettingsView(categories: categories, accentColor: accentColor, viewModel: viewModel, scoreViewModel: scoreViewModel, playAction: playAction, onSave: { viewModel.saveCategorySettings() }) }
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
            MultiViewScreen(viewModel: viewModel, showMultiView: $showMultiView)
                .transition(.move(edge: .bottom))
                .zIndex(50)
        }

        if let miniChannel = viewModel.miniPlayerChannel, selectedChannel == nil { 
            VStack { 
                Spacer()
                HStack { 
                    Spacer()
                    MiniPlayerView(channel: miniChannel, viewModel: viewModel, onExpand: { 
                        withAnimation(.easeInOut(duration: 0.4)) { 
                            selectedChannel = miniChannel
                            viewModel.miniPlayerChannel = nil 
                        } 
                    }, onClose: { 
                        withAnimation(.easeInOut(duration: 0.3)) { 
                            viewModel.miniPlayerChannel = nil 
                        } 
                    })
                    .padding(.trailing, 20)
                    .padding(.bottom, shouldUseSidebar(isLandscape: isL) ? 20 : 100) 
                } 
            }
            .zIndex(15)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity)) 
        }
        
        if let channel = selectedChannel { 
            CustomVideoPlayerView(channel: channel, viewModel: viewModel, onDismiss: { 
                if selectedChannel?.id == channel.id { 
                    withAnimation(.easeInOut(duration: 0.4)) { 
                        selectedChannel = nil
                        showQuickSwitcher = false 
                    }
                    // Stop engine if NOT going to mini player
                    if viewModel.miniPlayerChannel == nil {
                        NebuloPlayerEngine.shared.stop()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { 
                        viewModel.scrollRestoreTrigger = UUID() 
                    } 
                } 
            }, onPlayChannel: { newChannel in 
                playChannel(newChannel) 
            }, showQuickSwitcher: $showQuickSwitcher)
            .transition(.move(edge: .bottom))
            .zIndex(20)
            .ignoresSafeArea() 
        }
        
        // General Loading Overlay
        if viewModel.isLoading || viewModel.isUpdatingEPG {
            LoadingStatusOverlay(
                status: viewModel.loadingStatus,
                progress: viewModel.isUpdatingEPG ? viewModel.displayEPGProgress : nil,
                accentColor: accentColor,
                isBlocking: viewModel.isLoading // Only block if full loading (skeletons)
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
            withAnimation(.easeInOut(duration: 0.4)) { 
                selectedChannel = channel
                selectedCategory = nil
            } 
        } 
    }
    func shouldUseSidebar(isLandscape: Bool) -> Bool { if selectedCategory?.id == -3 { return false }; switch ViewMode(rawValue: viewMode) ?? .automatic { case .automatic: return isLandscape; case .sidebar: return true; case .standard: return false } }
}

// MARK: - STANDARD LAYOUT (Restored)
struct StandardLayout: SwiftUI.View {
    @AppStorage("glassOpacity") private var glassOpacity = 0.15
    @AppStorage("glassShade") private var glassShade = 1.0
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Binding var selectedCategory: StreamCategory?; @Binding var selectedChannel: StreamChannel?; @Binding var searchText: String
    let accentColor: Color; let playAction: (StreamChannel) -> Void; @Binding var showMultiView: Bool; @Binding var showSettings: Bool
    @Binding var selectedRecording: Recording?
    
    var body: some SwiftUI.View {
        ZStack(alignment: .bottom) {
            if viewModel.isLoading {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        // 1. Recent Preview Skeleton
                        VStack(alignment: .leading, spacing: 12) {
                            SkeletonBox(width: 180, height: 20).padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(0..<4, id: \.self) { _ in
                                        HorizontalCardSkeleton()
                                    }
                                }.padding(.horizontal)
                            }
                        }
                        
                        // 2. Quick Access Skeleton
                        VStack(alignment: .leading, spacing: 12) {
                            SkeletonBox(width: 140, height: 20).padding(.horizontal)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                                ForEach(0..<4, id: \.self) { _ in
                                    DashboardCardSkeleton()
                                }
                            }.padding(.horizontal)
                        }
                        
                        // 3. Browse All Skeleton
                        FullWidthCardSkeleton()
                            .padding(.horizontal)
                        
                        // 4. Categories Skeleton
                        VStack(alignment: .leading, spacing: 12) {
                            SkeletonBox(width: 120, height: 20).padding(.horizontal)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                                ForEach(0..<12, id: \.self) { _ in
                                    CategoryCardSkeleton()
                                }
                            }.padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            } else if !searchText.isEmpty {
                searchView
                    .modifier(SwipeBackModifier(onBack: { withAnimation { searchText = "" } }))
            } else if let cat = selectedCategory {
                if cat.id == -3 { 
                    SportsHubView(viewModel: viewModel, accentColor: accentColor, playAction: playAction, onBack: { withAnimation { selectedCategory = nil } }, scoreViewModel: scoreViewModel)
                        .transition(.blurFade)
                        .modifier(SwipeBackModifier(onBack: { withAnimation { selectedCategory = nil } }))
                }
                else if cat.id == -5 { 
                    RecordingsView(viewModel: viewModel, playAction: playAction, onBack: { withAnimation { selectedCategory = nil } })
                        .transition(.blurFade)
                        .modifier(SwipeBackModifier(onBack: { withAnimation { selectedCategory = nil } }))
                }
                else { 
                    CategoryDetailView(title: cat.name, channels: getChannelsToShow(for: cat), accentColor: accentColor, playAction: playAction, toggleFav: viewModel.toggleFavorite, promptRename: viewModel.triggerRenameChannel, hideChannel: viewModel.hideChannel, favoriteIDs: viewModel.favoriteIDs, viewModel: viewModel, showMultiView: $showMultiView, onBack: { withAnimation { selectedCategory = nil } }, onCategorySelect: { cat in withAnimation { selectedCategory = cat; searchText = "" } })
                        .transition(.blurFade)
                        .modifier(SwipeBackModifier(onBack: { withAnimation { selectedCategory = nil } }))
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 24) {
                            
                            // MARK: - Header
                            // Greeting removed as requested
                            
                            // MARK: - Recent
                            if !viewModel.recentIDs.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Button(action: {
                                        viewModel.lastSelectedHomeID = -2; withAnimation { selectedCategory = StreamCategory(id: -2, name: "Recently Watched") }
                                    }) {
                                        HStack {
                                            Label("Continue Watching", systemImage: "play.circle.fill")
                                                .font(.headline)
                                                .foregroundStyle(.white.opacity(0.8))
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(.white.opacity(0.5))
                                        }
                                        .padding(.horizontal)
                                    }
                                    .buttonStyle(.plain)
                                    
                                    let recent = viewModel.recentIDs.compactMap { id in viewModel.channels.first(where: { $0.id == id }) }
                                    HorizontalPreviewList(channels: recent, isRecent: true, accentColor: accentColor, viewModel: viewModel, playAction: playAction, promptRenameChannel: viewModel.triggerRenameChannel, hideChannel: viewModel.hideChannel, removeFromRecent: viewModel.removeFromRecent)
                                }
                            }
                            
                            // MARK: - Quick Access
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Quick Access", systemImage: "square.grid.2x2.fill")
                                    .font(.headline)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .padding(.horizontal)
                                
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                                    DashboardCard(title: "Sports Center", icon: "sportscourt.fill", color: .green, accentColor: accentColor) {
                                        viewModel.lastSelectedHomeID = -3; withAnimation { selectedCategory = StreamCategory(id: -3, name: "Sports Center") }
                                    }
                                    DashboardCard(title: "Favorites", icon: "star.fill", color: .yellow, accentColor: accentColor) {
                                        viewModel.lastSelectedHomeID = -4; withAnimation { selectedCategory = StreamCategory(id: -4, name: "Favorites") }
                                    }
                                    DashboardCard(title: "Recordings", icon: "record.circle.fill", color: .red, accentColor: accentColor) {
                                        viewModel.lastSelectedHomeID = -5; withAnimation { selectedCategory = StreamCategory(id: -5, name: "Recordings") }
                                    }
                                    DashboardCard(title: "Multi-View", icon: "square.grid.2x2", color: .purple, accentColor: accentColor) {
                                        viewModel.lastSelectedHomeID = -99; withAnimation { showMultiView = true }
                                    }
                                }
                                .padding(.horizontal)
                            }
                            
                            // MARK: - All Channels
                            Button(action: {
                                viewModel.lastSelectedHomeID = -1; withAnimation { selectedCategory = StreamCategory(id: -1, name: "All Channels") }
                            }) {
                                HStack {
                                    Image(systemName: "tv.fill")
                                        .font(.title2)
                                        .foregroundColor(accentColor)
                                        .frame(width: 40)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Browse All Channels")
                                            .font(.headline)
                                            .foregroundColor(.white)
                                        Text("\(viewModel.channels.count) channels available")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                    
                                    Spacer()
                                    
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                        .foregroundColor(.white.opacity(0.3))
                                }
                                .padding(16)
                                .background(Color(white: glassShade).opacity(glassOpacity))
                                .cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                            
                            // MARK: - Categories
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Categories", systemImage: "list.bullet")
                                    .font(.headline)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .padding(.horizontal)
                                
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                                    ForEach(viewModel.categories.filter { !$0.isHidden }) { cat in
                                        Button(action: {
                                            viewModel.lastSelectedHomeID = cat.id; withAnimation { selectedCategory = cat }
                                        }) {
                                            Text(cat.name)
                                                .font(.subheadline.bold())
                                                .foregroundStyle(.white)
                                                .multilineTextAlignment(.center) // Centered
                                                .frame(maxWidth: .infinity, alignment: .center) // Centered
                                                .padding(14)
                                                .frame(height: 70)
                                                .background(Color(white: glassShade).opacity(glassOpacity))
                                                .cornerRadius(12)
                                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                        .id(cat.id)
                                    }
                                }
                                .padding(.horizontal)
                            }
                            
                            Spacer(minLength: 40)
                        }
                        .padding(.vertical)
                    }
                    .onAppear {
                        if let last = viewModel.lastSelectedHomeID {
                            DispatchQueue.main.async { proxy.scrollTo(last, anchor: .center) }
                        }
                    }
                }.transition(.blurFade)
            }
        }.animation(.easeInOut(duration: 0.4), value: selectedCategory)
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
                                .font(.system(size: 11, weight: .black))
                                .kerning(1.2)
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.horizontal)
                            HorizontalSearchList(channels: viewModel.filteredEPGChannels, viewModel: viewModel, accentColor: accentColor, playAction: playAction)
                        }
                    }
                    if !viewModel.filteredNameChannels.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("CHANNEL NAME RESULTS")
                                .font(.system(size: 11, weight: .black))
                                .kerning(1.2)
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.horizontal)
                            HorizontalSearchList(channels: viewModel.filteredNameChannels, viewModel: viewModel, accentColor: accentColor, playAction: playAction)
                        }
                    }
                    
                    if !viewModel.filteredCategories.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("EXPLORE CATEGORIES")
                                .font(.system(size: 11, weight: .black))
                                .kerning(1.2)
                                .foregroundColor(.white.opacity(0.5))
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
    
    func getChannelsToShow(for cat: StreamCategory) -> [StreamChannel] { if cat.id == -2 { return viewModel.recentIDs.compactMap { id in viewModel.channels.first(where: { $0.id == id }) } }; if cat.id == -4 { return viewModel.channels.filter { viewModel.favoriteIDs.contains($0.id) } }; if cat.id == -1 { return viewModel.channels.filter { !viewModel.hiddenIDs.contains($0.id) } }; return viewModel.channels.filter { $0.categoryID == cat.id && !viewModel.hiddenIDs.contains($0.id) } }
}

struct DashboardCard: View {
    @AppStorage("glassOpacity") private var glassOpacity = 0.15
    @AppStorage("glassShade") private var glassShade = 1.0
    let title: String
    let icon: String
    let color: Color
    let accentColor: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(color)
                
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .background(Color(white: glassShade).opacity(glassOpacity))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct SidebarLayout: SwiftUI.View {
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Binding var selectedCategory: StreamCategory?; @Binding var selectedChannel: StreamChannel?; @Binding var searchText: String
    let isLandscape: Bool; let accentColor: Color; let playAction: (StreamChannel) -> Void; @Binding var showMultiView: Bool; @Binding var showSettings: Bool
    @State private var channelForDescription: StreamChannel?
    
    var body: some SwiftUI.View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ClockView().padding(.vertical, 20)
                        if !searchText.isEmpty { GlassSidebarRow(title: "Search Results", isSelected: true, accentColor: accentColor) }
                        else {
                            Button(action: { withAnimation { selectedCategory = StreamCategory(id: -2, name: "Recently Watched") } }) { GlassSidebarRow(title: "Recently Watched", isSelected: selectedCategory?.id == -2, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { withAnimation { selectedCategory = StreamCategory(id: -4, name: "Favorites") } }) { GlassSidebarRow(title: "Favorites", isSelected: selectedCategory?.id == -4, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { withAnimation { selectedCategory = StreamCategory(id: -3, name: "Sports Center") } }) { GlassSidebarRow(title: "Sports Center", isSelected: selectedCategory?.id == -3, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { withAnimation { selectedCategory = StreamCategory(id: -5, name: "Recordings") } }) { GlassSidebarRow(title: "Recordings", isSelected: selectedCategory?.id == -5, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { withAnimation { showMultiView = true } }) { GlassSidebarRow(title: "Multi-View", isSelected: false, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { withAnimation { selectedCategory = StreamCategory(id: -1, name: "All Channels") } }) { GlassSidebarRow(title: "All Channels", isSelected: selectedCategory?.id == -1, accentColor: accentColor) }.buttonStyle(.plain)
                            Divider().background(Color.white.opacity(0.3)).padding(.vertical, 8)
                            ForEach(viewModel.categories.filter { !$0.isHidden }) { cat in Button(action: { withAnimation { selectedCategory = cat } }) { GlassSidebarRow(title: cat.name, isSelected: selectedCategory?.id == cat.id, accentColor: accentColor) }.buttonStyle(.plain).contextMenu { Button { viewModel.triggerRenameCategory(cat) } label: { Label("Rename", systemImage: "pencil") }; Button { viewModel.hideCategory(cat.id) } label: { Label("Hide", systemImage: "eye.slash") } } }
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
                    // searchView is private to StandardLayout, so we need a similar view here or reuse components.
                    // For Sidebar layout, we usually reuse the same logic. 
                    // To keep it simple and safe, we can reuse the components directly.
                    StandardLayout(viewModel: viewModel, scoreViewModel: scoreViewModel, selectedCategory: $selectedCategory, selectedChannel: $selectedChannel, searchText: $searchText, accentColor: accentColor, playAction: playAction, showMultiView: $showMultiView, showSettings: $showSettings, selectedRecording: .constant(nil))
                        .id("SearchOverride") // Hack to force reload if needed
                } else if selectedCategory?.id == -3 { SportsHubView(viewModel: viewModel, accentColor: accentColor, playAction: playAction, onBack: nil, scoreViewModel: scoreViewModel).transition(.blurFade) }
                else if selectedCategory?.id == -5 { RecordingsView(viewModel: viewModel, playAction: playAction, onBack: { withAnimation { selectedCategory = nil } }).transition(.blurFade) }
                else {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                let channels = getChannelsToShow()
                                if channels.isEmpty { EmptyStateView(title: "No Channels", systemImage: "tv.slash", description: "Select a category.") }
                                else {
                                    ForEach(channels) { c in
                                        ChannelRow(channel: c, epgProgram: viewModel.getCurrentProgram(for: c), isFavorite: viewModel.favoriteIDs.contains(c.id), accentColor: accentColor, isCompact: !isLandscape, playAction: { playAction(c) }, toggleFav: { viewModel.toggleFavorite(c.id) })                                            .equatable()
                                            .id(c.id)
                                            .contextMenu {
                                                Button { viewModel.triggerRenameChannel(c) } label: { Label("Rename", systemImage: "pencil") }
                                                Button { viewModel.hideChannel(c.id) } label: { Label("Hide", systemImage: "eye.slash") }
                                                if let prog = viewModel.getCurrentProgram(for: c), let desc = prog.description, !desc.isEmpty {
                                                    Button { channelForDescription = c } label: { Label("Description", systemImage: "text.alignleft") }
                                                }
                                                if selectedCategory?.id == -2 || viewModel.recentIDs.contains(c.id) { Button(role: .destructive) { viewModel.removeFromRecent(c.id) } label: { Label("Remove", systemImage: "clock.badge.xmark") } }
                                            }
                                    }
                                }
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
            }.animation(.easeInOut(duration: 0.4), value: selectedCategory)
        }
        .alert(item: $channelForDescription) { channel in
            Alert(
                title: Text("Program Description"),
                message: Text(viewModel.getCurrentProgram(for: channel)?.description ?? "No description available."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
    
    func getChannelsToShow() -> [StreamChannel] { guard let cat = selectedCategory else { return [] }; if cat.id == -2 { return viewModel.recentIDs.compactMap { id in viewModel.channels.first(where: { $0.id == id }) } }; if cat.id == -4 { return viewModel.channels.filter { viewModel.favoriteIDs.contains($0.id) } }; if cat.id == -1 { return viewModel.channels.filter { !viewModel.hiddenIDs.contains($0.id) } }; return viewModel.channels.filter { $0.categoryID == cat.id && !viewModel.hiddenIDs.contains($0.id) } }
}

struct CategoryDetailView: SwiftUI.View {
    let title: String; let channels: [StreamChannel]; let accentColor: Color; let playAction: (StreamChannel) -> Void; let toggleFav: (Int) -> Void; let promptRename: (StreamChannel) -> Void; let hideChannel: (Int) -> Void; let favoriteIDs: Set<Int>; @ObservedObject var viewModel: ChannelViewModel; @Binding var showMultiView: Bool; var onBack: (() -> Void)? = nil; var onCategorySelect: ((StreamCategory) -> Void)? = nil
    @AppStorage("nebColor1") private var nebColor1 = "#AF52DE"; @AppStorage("nebColor2") private var nebColor2 = "#007AFF"; @AppStorage("nebColor3") private var nebColor3 = "#FF2D55"; @AppStorage("nebX1") private var nebX1 = 0.2; @AppStorage("nebY1") private var nebY1 = 0.2; @AppStorage("nebX2") private var nebX2 = 0.8; @AppStorage("nebY2") private var nebY2 = 0.3; @AppStorage("nebX3") private var nebX3 = 0.5; @AppStorage("nebY3") private var nebY3 = 0.8
    @State private var channelForDescription: StreamChannel?
    
    var body: some SwiftUI.View {
        ZStack {
            NebulaBackgroundView(color1: Color(hex: nebColor1) ?? .purple, color2: Color(hex: nebColor2) ?? .blue, color3: Color(hex: nebColor3) ?? .pink, point1: UnitPoint(x: nebX1, y: nebY1), point2: UnitPoint(x: nebX2, y: nebY2), point3: UnitPoint(x: nebX3, y: nebY3))
            
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            if !viewModel.searchText.isEmpty {
                                // Search Logic
                                Text("Search Results").font(.headline).padding()
                            } else {
                                ForEach(channels) { c in
                                    ChannelRow(channel: c, epgProgram: viewModel.getCurrentProgram(for: c), isFavorite: favoriteIDs.contains(c.id), accentColor: accentColor, playAction: { playAction(c) }, toggleFav: { toggleFav(c.id) })
                                        .equatable()
                                        .id(c.id)
                                        .contextMenu {
                                            Button { promptRename(c) } label: { Label("Rename", systemImage: "pencil") }
                                            Button { hideChannel(c.id) } label: { Label("Hide", systemImage: "eye.slash") }
                                            if let prog = viewModel.getCurrentProgram(for: c), let desc = prog.description, !desc.isEmpty {
                                                Button { channelForDescription = c } label: { Label("Description", systemImage: "text.alignleft") }
                                            }
                                        }
                                }
                            }
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

// MARK: - Mini Player View
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
            
            // Interaction Layer
            Color.black.opacity(0.001)
                .frame(width: 240, height: 135)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
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
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
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
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .modifier(GlassEffect(cornerRadius: 16, isSelected: true, accentColor: nil))
                            }
                            .buttonStyle(.plain)
                            
                            Spacer()
                            
                            Button(action: onExpand) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
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
        .gesture(
            DragGesture()
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

// MARK: - Swipe Back Modifier
struct SwipeBackModifier: ViewModifier {
    let onBack: () -> Void
    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            content
            
            // Invisible edge trigger
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
            .padding(.bottom, 15) // Moved lower
        }
    } 
}

struct LoadingStatusOverlay: View {
    let status: String
    var progress: Double? = nil
    let accentColor: Color
    var isBlocking: Bool = true
    
    var body: some View {
        VStack {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                    
                    Text(status)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                }
                
                if let progress = progress {
                    VStack(spacing: 4) {
                        ProgressView(value: progress, total: 1.0)
                            .tint(accentColor)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())
                            .frame(width: 150)
                        
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Material.ultraThin)
            .cornerRadius(20)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
            .padding(.top, 60) // Safe area padding
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(
            isBlocking 
            ? Color.black.opacity(0.3)
            : Color.clear
        )
        .ignoresSafeArea()
        .allowsHitTesting(isBlocking) // Pass through touches if not blocking (except the overlay itself ideally, but VStacks capture space. We need contentShape)
    }
}
