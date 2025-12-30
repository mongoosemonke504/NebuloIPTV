import SwiftUI
import AVFoundation
import Combine

// MARK: - MAIN VIEW
struct MainView: View {
    @ObservedObject var viewModel: ChannelViewModel
    @AppStorage("xstreamURL") private var xstreamURL = ""; @AppStorage("username") private var username = ""; @AppStorage("password") private var password = ""; @AppStorage("loginTypeRaw") private var loginTypeRaw = LoginType.xtream.rawValue; @AppStorage("viewMode") private var viewMode = ViewMode.automatic.rawValue; @AppStorage("customAccentHex") private var customAccentHex = "#007AFF"; @AppStorage("nebColor1") private var nebColor1 = "#AF52DE"; @AppStorage("nebColor2") private var nebColor2 = "#007AFF"; @AppStorage("nebColor3") private var nebColor3 = "#FF2D55"; @AppStorage("nebX1") private var nebX1 = 0.2; @AppStorage("nebY1") private var nebY1 = 0.2; @AppStorage("nebX2") private var nebX2 = 0.8; @AppStorage("nebY2") private var nebY2 = 0.3; @AppStorage("nebX3") private var nebX3 = 0.5; @AppStorage("nebY3") private var nebY3 = 0.8
    @AppStorage("showSupportPopup") private var showSupportPopup = true
    @AppStorage("lastSupportPopupTime") private var lastSupportPopupTime: Double = 0
    
    @State private var selectedCategory: StreamCategory?; @State private var selectedChannel: StreamChannel?; @State private var showSettings = false; @State private var showMultiView = false
    @State private var showQuickSwitcher = false
    @State private var showSupportAlert = false
    let refreshTimer = Timer.publish(every: 14400, on: .main, in: .common).autoconnect(); var accentColor: Color { Color(hex: customAccentHex) ?? .blue }
    
    var body: some View {
        GeometryReader { geo in
            let isL = geo.size.width > geo.size.height
            ZStack {
                // Root background that always fills the screen
                NebulaBackgroundView(color1: Color(hex: nebColor1) ?? .purple, color2: Color(hex: nebColor2) ?? .blue, color3: Color(hex: nebColor3) ?? .pink, point1: UnitPoint(x: nebX1, y: nebY1), point2: UnitPoint(x: nebX2, y: nebY2), point3: UnitPoint(x: nebX3, y: nebY3))
                    .ignoresSafeArea()
                    .zIndex(0)
                
                NavigationStack {
                    ZStack {
                        // Background inside the stack to handle navigation transitions
                        NebulaBackgroundView(color1: Color(hex: nebColor1) ?? .purple, color2: Color(hex: nebColor2) ?? .blue, color3: Color(hex: nebColor3) ?? .pink, point1: UnitPoint(x: nebX1, y: nebY1), point2: UnitPoint(x: nebX2, y: nebY2), point3: UnitPoint(x: nebX3, y: nebY3)).zIndex(0)
                        
                        Group {
                            if shouldUseSidebar(isLandscape: isL) { SidebarLayout(viewModel: viewModel, selectedCategory: $selectedCategory, selectedChannel: $selectedChannel, searchText: $viewModel.searchText, isLandscape: isL, accentColor: accentColor, playAction: playChannel, showMultiView: $showMultiView, showSettings: $showSettings) }
                            else { StandardLayout(viewModel: viewModel, selectedCategory: $selectedCategory, selectedChannel: $selectedChannel, searchText: $viewModel.searchText, accentColor: accentColor, playAction: playChannel, showMultiView: $showMultiView, showSettings: $showSettings) }
                        }
                        .zIndex(1)
                        
                        if viewModel.activeMultiViewCount > 0 && !showMultiView && selectedChannel == nil {
                            MultiViewIndicator(count: viewModel.activeMultiViewCount, accentColor: nil, action: { withAnimation(.spring()) { showMultiView = true } }).zIndex(5)
                        }
                    }
                    .if(!showMultiView) { view in
                        view.searchable(text: $viewModel.searchText, prompt: "Search")
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    HStack {
                                        Button(action: { withAnimation(.spring()) { showMultiView = true } }) { Image(systemName: "square.grid.2x2.fill").foregroundStyle(.white.opacity(0.8)) }
                                        Button(action: { showSettings = true }) { Image(systemName: "gearshape.fill").foregroundStyle(.white.opacity(0.8)) }
                                    }
                                }
                            }
                    }
                    .fullScreenCover(isPresented: $showMultiView) { MultiViewScreen(viewModel: viewModel, showMultiView: $showMultiView) }
                    .sheet(isPresented: $showSettings) { SettingsView(categories: $viewModel.categories, accentColor: accentColor, viewModel: viewModel, onSave: { viewModel.saveCategorySettings() }) }
                    .alert("No Streams Found", isPresented: $viewModel.showNoStreamsAlert) { Button("OK", role: .cancel) { } } message: { Text("No streams were found. Please search for the channel manually.") }
                    .alert("Rename", isPresented: $viewModel.showRenameAlert) { TextField("New Name", text: $viewModel.renameInput); Button("Save") { viewModel.confirmRename() }; Button("Cancel", role: .cancel) {} }
                    .alert("Support Project", isPresented: $showSupportAlert) {
                        Button("Donate") { if let url = URL(string: "https://buymeacoffee.com/mongoosemonke") { UIApplication.shared.open(url) } }
                        Button("Join Discord") { if let url = URL(string: "https://discord.gg/QkBUjsGCJ2") { UIApplication.shared.open(url) } }
                        Button("Don't Show Again") { showSupportPopup = false }
                        Button("Close", role: .cancel) {}
                    } message: {
                        Text("This is a free, open-source project that is constantly being worked on. If you enjoy using it, please consider donating to support development!")
                    }
                }
                .zIndex(1)
                
                if let channel = selectedChannel {
                    CustomVideoPlayerView(channel: channel, viewModel: viewModel, onDismiss: { 
                        withAnimation(.easeInOut(duration: 0.4)) { selectedChannel = nil; showQuickSwitcher = false }
                        // Trigger scroll restoration slightly after animation starts/finishes to ensure view is visible
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            viewModel.scrollRestoreTrigger = UUID()
                        }
                    }, onPlayChannel: { newChannel in
                        playChannel(newChannel)
                    }, showQuickSwitcher: $showQuickSwitcher).transition(.asymmetric(insertion: .move(edge: .bottom), removal: .opacity)).zIndex(10)
                }
                
                // MODIFIED: EPG Indicator coming down and going back to the top (Dynamic Island)
                if viewModel.isUpdatingEPG {
                    VStack {
                        EPGLoadingNotification(progress: viewModel.displayEPGProgress, accentColor: accentColor, onDismiss: {
                            withAnimation(.spring()) { viewModel.isUpdatingEPG = false }
                        })
                        .padding(.top, 65) // Precise spacing for Dynamic Island positioning
                        Spacer()
                    }
                    // Use move edge top for both in and out to return back to the island
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(20)
                }
                
                // In-App Mini Player
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
                                withAnimation {
                                    viewModel.miniPlayerChannel = nil
                                }
                            })
                            .padding(.trailing, 20)
                            .padding(.bottom, shouldUseSidebar(isLandscape: isL) ? 20 : 100) // Adjust for tab bar if needed
                        }
                    }
                    .zIndex(15)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea()
        .task {
            if viewModel.channels.isEmpty {
                await viewModel.loadData(url: xstreamURL, user: username, pass: password, type: LoginType(rawValue: loginTypeRaw) ?? .xtream)
            }
            // Check for support popup
            if showSupportPopup {
                let now = Date().timeIntervalSince1970
                if now - lastSupportPopupTime > 43200 { // 12 hours
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // Delay 2s to not interrupt startup
                    showSupportAlert = true
                    lastSupportPopupTime = now
                }
            }
        }
        .onReceive(refreshTimer) { _ in
            Task { await viewModel.loadData(url: xstreamURL, user: username, pass: password, type: LoginType(rawValue: loginTypeRaw) ?? .xtream, silent: true) }
        }
        .onChangeCompat(of: viewModel.channelToAutoPlay) { nc in if let c = nc { withAnimation(.easeInOut(duration: 0.4)) { selectedChannel = c }; viewModel.channelToAutoPlay = nil } }
        .onChangeCompat(of: viewModel.triggerMultiView) { nv in if nv { selectedChannel = nil; withAnimation(.spring()) { showMultiView = true }; viewModel.triggerMultiView = false } }
    }
    func playChannel(_ channel: StreamChannel) { 
        hideKeyboard()
        if viewModel.multiViewModeActive { viewModel.addToMultiView(channel); viewModel.multiViewModeActive = false; withAnimation(.spring()) { showMultiView = true } } else { viewModel.addToRecent(channel.id); viewModel.lastPlayedChannelID = channel.id; withAnimation(.easeInOut(duration: 0.4)) { selectedChannel = channel } } }
    func shouldUseSidebar(isLandscape: Bool) -> Bool { if selectedCategory?.id == -3 { return false }; switch ViewMode(rawValue: viewMode) ?? .automatic { case .automatic: return isLandscape; case .sidebar: return true; case .standard: return false } }
}

extension View { @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View { if condition { transform(self) } else { self } } }
struct MultiViewIndicator: View { let count: Int; let accentColor: Color?; let action: () -> Void; var body: some View { VStack { Spacer(); Button(action: action) { HStack { Image(systemName: "square.grid.2x2.fill"); Text("Multi-View Active: \(count)/4") }.font(.caption.bold()).foregroundColor(.white).padding(.horizontal, 16).padding(.vertical, 12).modifier(GlassEffect(cornerRadius: 20, isSelected: true, accentColor: accentColor)) }.padding(.bottom, 20) } } }

struct SidebarLayout: View {
    @ObservedObject var viewModel: ChannelViewModel
    @Binding var selectedCategory: StreamCategory?; @Binding var selectedChannel: StreamChannel?; @Binding var searchText: String
    let isLandscape: Bool; let accentColor: Color; let playAction: (StreamChannel) -> Void; @Binding var showMultiView: Bool; @Binding var showSettings: Bool
    @State private var channelForDescription: StreamChannel?
    
    var body: some View {
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
                            Button(action: { withAnimation { showMultiView = true } }) { GlassSidebarRow(title: "Multi-View", isSelected: false, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { withAnimation { selectedCategory = StreamCategory(id: -1, name: "All Channels") } }) { GlassSidebarRow(title: "All Channels", isSelected: selectedCategory?.id == -1, accentColor: accentColor) }.buttonStyle(.plain)
                            Divider().background(Color.white.opacity(0.3)).padding(.vertical, 8)
                            ForEach(viewModel.categories.filter { !$0.isHidden }) { cat in Button(action: { withAnimation { selectedCategory = cat } }) { GlassSidebarRow(title: cat.name, isSelected: selectedCategory?.id == cat.id, accentColor: accentColor) }.buttonStyle(.plain).contextMenu { Button { viewModel.triggerRenameCategory(cat) } label: { Label("Rename", systemImage: "pencil") }; Button { viewModel.hideCategory(cat.id) } label: { Label("Hide", systemImage: "eye.slash") } } }
                        }
                    }.padding(.horizontal, 10)
                }
            }.frame(width: isLandscape ? 260 : 170).background(Color.clear); Divider().overlay(Color.white.opacity(0.2))
            ZStack {
                if !searchText.isEmpty {
                    searchView
                } else if selectedCategory?.id == -3 { SportsHubView(viewModel: viewModel, accentColor: accentColor, playAction: playAction, onBack: nil, scoreViewModel: viewModel.scoreViewModel).transition(.blurFade) }
                else if viewModel.isLoading {
                    ScrollView {
                        VStack {
                            ForEach(0..<15, id: \.self) { _ in ChannelRowSkeleton() }
                        }
                    }
                }
                else {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                let channels = getChannelsToShow()
                                if channels.isEmpty { EmptyStateView(title: "No Channels", systemImage: "tv.slash", description: "Select a category.") }
                                else {
                                    ForEach(channels) { c in
                                        ChannelRow(channel: c, epgProgram: viewModel.getCurrentProgram(for: c), isFavorite: viewModel.favoriteIDs.contains(c.id), accentColor: accentColor, isCompact: !isLandscape, playAction: { playAction(c) }, toggleFav: { viewModel.toggleFavorite(c.id) })
                                            .equatable()
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
    
    private var searchView: some View {
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
                            Text("GUIDE RESULTS (\(viewModel.filteredEPGChannels.count))")
                                .font(.system(size: 11, weight: .black))
                                .kerning(1.2)
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.horizontal)
                            HorizontalSearchList(channels: viewModel.filteredEPGChannels, viewModel: viewModel, accentColor: accentColor, playAction: playAction)
                        }
                    }
                    
                    if !viewModel.filteredNameChannels.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("CHANNEL RESULTS (\(viewModel.filteredNameChannels.count))")
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
    
    func getChannelsToShow() -> [StreamChannel] { guard let cat = selectedCategory else { return [] }; if cat.id == -2 { return viewModel.recentIDs.compactMap { id in viewModel.channels.first(where: { $0.id == id }) } }; if cat.id == -4 { return viewModel.channels.filter { viewModel.favoriteIDs.contains($0.id) } }; if cat.id == -1 { return viewModel.channels.filter { !viewModel.hiddenIDs.contains($0.id) } }; return viewModel.channels.filter { $0.categoryID == cat.id && !viewModel.hiddenIDs.contains($0.id) } }
}

struct StandardLayout: View {
    @ObservedObject var viewModel: ChannelViewModel
    @Binding var selectedCategory: StreamCategory?; @Binding var selectedChannel: StreamChannel?; @Binding var searchText: String
    let accentColor: Color; let playAction: (StreamChannel) -> Void; @Binding var showMultiView: Bool; @Binding var showSettings: Bool
    
    var body: some View {
        ZStack {
            if !searchText.isEmpty {
                searchView
            } else if let cat = selectedCategory {
                if cat.id == -3 { SportsHubView(viewModel: viewModel, accentColor: accentColor, playAction: playAction, onBack: { withAnimation { selectedCategory = nil } }, scoreViewModel: viewModel.scoreViewModel).transition(.blurFade) }
                else { CategoryDetailView(title: cat.name, channels: getChannelsToShow(for: cat), accentColor: accentColor, playAction: playAction, toggleFav: viewModel.toggleFavorite, promptRename: viewModel.triggerRenameChannel, hideChannel: viewModel.hideChannel, favoriteIDs: viewModel.favoriteIDs, viewModel: viewModel, showMultiView: $showMultiView, onBack: { withAnimation { selectedCategory = nil } }, onCategorySelect: { cat in withAnimation { selectedCategory = cat; searchText = "" } }).transition(.blurFade) }
            } else if viewModel.isLoading {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 16) {
                        // Header for Recently Watched
                        HStack {
                            SkeletonBox(width: 180, height: 24).cornerRadius(4)
                            Spacer()
                            SkeletonBox(width: 14, height: 14).cornerRadius(2)
                        }.padding(.horizontal)
                        
                        // Recently Watched Horizontal List
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(0..<4, id: \.self) { _ in
                                    SkeletonBox(height: 112).frame(width: 200).cornerRadius(12)
                                }
                            }.padding(.horizontal)
                        }.frame(height: 150)
                        
                        // Sports & Favorites Square Cards
                        HStack(spacing: 16) {
                            SquareCardSkeleton()
                            SquareCardSkeleton()
                        }.padding(.horizontal).padding(.vertical, 8)
                        
                        // Dashboard Categories (Multi-View, All Channels, and Categories)
                        CategoryCardSkeleton() // Multi View placeholder
                        CategoryCardSkeleton() // All Channels placeholder
                        ForEach(0..<10, id: \.self) { _ in
                            CategoryCardSkeleton()
                        }
                    }
                    .padding(.vertical)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 16) {
                            if !viewModel.recentIDs.isEmpty {
                                let recent = viewModel.recentIDs.compactMap { id in viewModel.channels.first(where: { $0.id == id }) }
                                if !recent.isEmpty { sectionHeader(title: "Recently Watched", channels: recent, id: -2); HorizontalPreviewList(channels: recent, isRecent: true, accentColor: accentColor, viewModel: viewModel, playAction: playAction, promptRenameChannel: viewModel.triggerRenameChannel, hideChannel: viewModel.hideChannel, removeFromRecent: viewModel.removeFromRecent) }
                            }
                            HStack(spacing: 16) {
                                Button(action: { viewModel.lastSelectedHomeID = -3; withAnimation { selectedCategory = StreamCategory(id: -3, name: "Sports Center") } }) { SquareCategoryCard(title: "Sports Center", icon: "sportscourt.fill", color: .green, accentColor: accentColor) }.buttonStyle(.plain).id(-3)
                                Button(action: { viewModel.lastSelectedHomeID = -4; withAnimation { selectedCategory = StreamCategory(id: -4, name: "Favorites") } }) { SquareCategoryCard(title: "Favorites", icon: "star.fill", color: .yellow, accentColor: accentColor) }.buttonStyle(.plain).id(-4)
                            }.padding(.horizontal).padding(.vertical, 8)
                            Button(action: { viewModel.lastSelectedHomeID = -99; withAnimation { showMultiView = true } }) { CategoryCard(title: "Multi View", icon: "square.grid.2x2.fill", color: .purple) }.buttonStyle(.plain).padding(.horizontal).id(-99)
                            Button(action: { viewModel.lastSelectedHomeID = -1; withAnimation { selectedCategory = StreamCategory(id: -1, name: "All Channels") } }) { CategoryCard(title: "All Channels", icon: "tv", color: .blue) }.buttonStyle(.plain).padding(.horizontal).id(-1)
                            ForEach(viewModel.categories.filter { !$0.isHidden }) { cat in Button(action: { viewModel.lastSelectedHomeID = cat.id; withAnimation { selectedCategory = cat } }) { CategoryCard(title: cat.name, color: .secondary) }.buttonStyle(.plain).padding(.horizontal).id(cat.id) }
                        }.padding(.vertical)
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
    
    private var searchView: some View {
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
    func sectionHeader(title: String, channels: [StreamChannel], id: Int) -> some View { Button(action: { withAnimation { selectedCategory = StreamCategory(id: id, name: title) } }) { HStack { Text(title).font(.title2.bold()).foregroundStyle(.white); Spacer(); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.white.opacity(0.7)) }.padding(.horizontal) }.buttonStyle(.plain) }
}

struct CategoryDetailView: View {
    let title: String; let channels: [StreamChannel]; let accentColor: Color; let playAction: (StreamChannel) -> Void; let toggleFav: (Int) -> Void; let promptRename: (StreamChannel) -> Void; let hideChannel: (Int) -> Void; let favoriteIDs: Set<Int>; @ObservedObject var viewModel: ChannelViewModel; @Binding var showMultiView: Bool; var onBack: (() -> Void)? = nil; var onCategorySelect: ((StreamCategory) -> Void)? = nil
    @AppStorage("nebColor1") private var nebColor1 = "#AF52DE"; @AppStorage("nebColor2") private var nebColor2 = "#007AFF"; @AppStorage("nebColor3") private var nebColor3 = "#FF2D55"; @AppStorage("nebX1") private var nebX1 = 0.2; @AppStorage("nebY1") private var nebY1 = 0.2; @AppStorage("nebX2") private var nebX2 = 0.8; @AppStorage("nebY2") private var nebY2 = 0.3; @AppStorage("nebX3") private var nebX3 = 0.5; @AppStorage("nebY3") private var nebY3 = 0.8
    @State private var channelForDescription: StreamChannel?
    
    var body: some View {
        ZStack {
            NebulaBackgroundView(color1: Color(hex: nebColor1) ?? .purple, color2: Color(hex: nebColor2) ?? .blue, color3: Color(hex: nebColor3) ?? .pink, point1: UnitPoint(x: nebX1, y: nebY1), point2: UnitPoint(x: nebX2, y: nebY2), point3: UnitPoint(x: nebX3, y: nebY3))
            
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            if !viewModel.searchText.isEmpty {
                                VStack(alignment: .leading, spacing: 20) {
                                    if viewModel.isSearching {
                                        VStack(alignment: .leading, spacing: 20) {
                                            SkeletonBox(width: 150, height: 14).padding(.horizontal)
                                            ScrollView(.horizontal) { HStack { ForEach(0..<4) { _ in HorizontalCardSkeleton() } } }.padding(.horizontal)
                                        }.padding(.top, 20)
                                    } else {
                                        if !viewModel.filteredEPGChannels.isEmpty {
                                            Text("EPG RESULTS").font(.caption.bold()).foregroundColor(.white.opacity(0.5)).padding(.horizontal)
                                            HorizontalSearchList(channels: viewModel.filteredEPGChannels, viewModel: viewModel, accentColor: accentColor, playAction: playAction)
                                        }
                                        if !viewModel.filteredNameChannels.isEmpty {
                                            Text("NAME RESULTS").font(.caption.bold()).foregroundColor(.white.opacity(0.5)).padding(.horizontal)
                                            HorizontalSearchList(channels: viewModel.filteredNameChannels, viewModel: viewModel, accentColor: accentColor, playAction: playAction)
                                        }
                                        
                                        if !viewModel.filteredCategories.isEmpty {
                                            Text("EXPLORE CATEGORIES").font(.caption.bold()).foregroundColor(.white.opacity(0.5)).padding(.horizontal)
                                            ScrollView(.horizontal, showsIndicators: false) {
                                                HStack(spacing: 12) {
                                                    ForEach(viewModel.filteredCategories) { cat in
                                                        Button(action: { 
                                                            onCategorySelect?(cat)
                                                        }) {
                                                            CategoryCard(title: cat.name, color: .secondary, lineLimit: 1)
                                                                .multilineTextAlignment(.leading)
                                                                .frame(width: 200, height: 85)
                                                        }.buttonStyle(.plain)
                                                    }
                                                }.padding(.horizontal)
                                            }
                                        }
                                        
                                        RecentSearchesView(viewModel: viewModel, accentColor: accentColor)                                    }
                                }.padding(.top)
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
            if viewModel.activeMultiViewCount > 0 {
                MultiViewIndicator(count: viewModel.activeMultiViewCount, accentColor: nil, action: { withAnimation(.easeInOut(duration: 0.35)) { showMultiView = true } })
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

struct MiniPlayerView: View {
    let channel: StreamChannel
    let viewModel: ChannelViewModel
    let onExpand: () -> Void
    let onClose: () -> Void
    
    @State private var player = AVPlayer()
    @State private var isPlaying = true
    @State private var showControls = false
    @State private var pipOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Video Content
                PlayerViewRepresentable(player: player, pipAdapter: .constant(nil))
                    .frame(width: 240, height: 135)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 10)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showControls.toggle()
                        }
                    }
                
                if showControls {
                    // Dimmed Overlay
                    Color.black.opacity(0.3)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .allowsHitTesting(false)
                    
                    // Center Pause/Play
                    Button(action: {
                        if isPlaying { player.pause() } else { player.play() }
                        isPlaying.toggle()
                    }) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding(16)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    
                                    // Close and Expand Buttons at the top
                                    VStack {
                                        HStack(spacing: 12) {
                                            Button(action: onClose) {
                                                Image(systemName: "xmark")
                                                    .font(.caption.bold())
                                                    .foregroundColor(.white)
                                                    .padding(8)
                                                    .background(.ultraThinMaterial)
                                                    .clipShape(Circle())
                                            }
                                            
                                            Spacer()
                                            
                                            Button(action: onExpand) {
                                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                                    .font(.caption.bold())
                                                    .foregroundColor(.white)
                                                    .padding(8)
                                                    .background(.ultraThinMaterial)
                                                    .clipShape(Circle())
                                            }
                                        }
                                        .padding(8)
                                        Spacer()
                                    }
                                }
                            }            .frame(width: 240, height: 135)
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
                        
                        // Define corners (relative to the bottom-right starting position)
                        // Note: Geometry/Padding in parent affects this, but we can approximate
                        let horizontalRange = screenWidth - pipWidth - 40
                        let verticalRange = screenHeight - pipHeight - 120
                        
                    let targetX: CGFloat = pipOffset.width > -horizontalRange / 2 ? 0 : -horizontalRange
                    // Added 60pt offset when snapping to top to avoid overlapping Dynamic Island/Toolbar
                    let targetY: CGFloat = pipOffset.height < -verticalRange / 2 ? -verticalRange + 60 : 0
                    
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            pipOffset = CGSize(width: targetX, height: targetY)
                            lastOffset = pipOffset
                        }
                    }
            )
        }
        .frame(width: 240, height: 135)
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            player.pause()
        }
    }
    
    private func setupPlayer() {
        guard let url = URL(string: channel.streamURL) else { return }
        let h: [String: Any] = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": h])
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.play()
    }
}

