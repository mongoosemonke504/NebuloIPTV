import SwiftUI

// MARK: - COMMON COMPONENTS
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String?
    
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundColor(.gray)
            Text(title)
                .font(.headline)
                .foregroundColor(.gray)
            if let description = description {
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}

// MARK: - LAYOUTS
struct SidebarLayout: View {
    @ObservedObject var viewModel: ChannelViewModel
    @Binding var selectedCategory: StreamCategory?
    @Binding var selectedChannel: StreamChannel?
    @Binding var searchText: String
    let isLandscape: Bool
    let accentColor: Color
    let playAction: (StreamChannel) -> Void
    @Binding var showMultiView: Bool
    @Binding var showSettings: Bool
    
    @State private var channelForDescription: StreamChannel?
    
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ClockView().padding(.vertical, 20)
                        if !searchText.isEmpty {
                            GlassSidebarRow(title: "Search Results", isSelected: true, accentColor: accentColor)
                        } else {
                            sidebarButtons
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            .frame(width: isLandscape ? 260 : 170)
            .background(Color.clear)
            
            Divider().overlay(Color.white.opacity(0.2))
            
            mainContentArea
        }
        .alert(item: $channelForDescription) { channel in
            Alert(
                title: Text("Program Description"),
                message: Text(viewModel.getCurrentProgram(for: channel)?.description ?? "No description available."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
    
    @ViewBuilder
    private var sidebarButtons: some View {
        Button(action: { withAnimation { selectedCategory = StreamCategory(id: -2, name: "Recently Watched") } }) { GlassSidebarRow(title: "Recently Watched", isSelected: selectedCategory?.id == -2, accentColor: accentColor) }.buttonStyle(.plain)
        Button(action: { withAnimation { selectedCategory = StreamCategory(id: -4, name: "Favorites") } }) { GlassSidebarRow(title: "Favorites", isSelected: selectedCategory?.id == -4, accentColor: accentColor) }.buttonStyle(.plain)
        Button(action: { withAnimation { selectedCategory = StreamCategory(id: -5, name: "Recordings") } }) { GlassSidebarRow(title: "Recordings", isSelected: selectedCategory?.id == -5, accentColor: accentColor) }.buttonStyle(.plain)
        Button(action: { withAnimation { selectedCategory = StreamCategory(id: -3, name: "Sports Center") } }) { GlassSidebarRow(title: "Sports Center", isSelected: selectedCategory?.id == -3, accentColor: accentColor) }.buttonStyle(.plain)
        Button(action: { withAnimation { showMultiView = true } }) { GlassSidebarRow(title: "Multi-View", isSelected: false, accentColor: accentColor) }.buttonStyle(.plain)
        Button(action: { withAnimation { selectedCategory = StreamCategory(id: -1, name: "All Channels") } }) { GlassSidebarRow(title: "All Channels", isSelected: selectedCategory?.id == -1, accentColor: accentColor) }.buttonStyle(.plain)
        
        Divider().background(Color.white.opacity(0.3)).padding(.vertical, 8)
        
        ForEach(viewModel.categories.filter { !$0.isHidden }) { cat in
            Button(action: { withAnimation { selectedCategory = cat } }) {
                GlassSidebarRow(title: cat.name, isSelected: selectedCategory?.id == cat.id, accentColor: accentColor)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { viewModel.triggerRenameCategory(cat) } label: { Label("Rename", systemImage: "pencil") }
                Button { viewModel.hideCategory(cat.id) } label: { Label("Hide", systemImage: "eye.slash") }
            }
        }
    }
    
    @ViewBuilder
    private var mainContentArea: some View {
        ZStack {
            if !searchText.isEmpty {
                searchView
            } else if selectedCategory?.id == -3 {
                SportsHubView(viewModel: viewModel, accentColor: accentColor, playAction: playAction, onBack: nil, scoreViewModel: viewModel.scoreViewModel).transition(.blurFade)
            } else if viewModel.isLoading {
                loadingView
            } else {
                channelListView
            }
        }
        .animation(.easeInOut(duration: 0.4), value: selectedCategory)
    }
    
    private var loadingView: some View {
        ScrollView {
            VStack {
                ForEach(0..<15, id: \.self) { _ in ChannelRowSkeleton() }
            }
        }
    }
    
    private var channelListView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    let channels = getChannelsToShow()
                    if channels.isEmpty {
                        EmptyStateView(title: "No Channels", systemImage: "tv.slash", description: "Select a category.")
                    } else {
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
                                    if selectedCategory?.id == -2 || viewModel.recentIDs.contains(c.id) {
                                        Button(role: .destructive) { viewModel.removeFromRecent(c.id) } label: { Label("Remove", systemImage: "clock.badge.xmark") }
                                    }
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
    
    private var searchView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                if viewModel.isSearching {
                    searchSkeletons
                } else {
                    searchResultsContent
                }
            }
            .padding(.top, 20)
        }
    }
    
    @ViewBuilder
    private var searchSkeletons: some View {
        VStack(alignment: .leading, spacing: 20) {
            SkeletonBox(width: 150, height: 14).padding(.horizontal)
            ScrollView(.horizontal) { HStack { ForEach(0..<4) { _ in HorizontalCardSkeleton() } } }.padding(.horizontal)
            SkeletonBox(width: 150, height: 14).padding(.horizontal)
            ScrollView(.horizontal) { HStack { ForEach(0..<4) { _ in HorizontalCardSkeleton() } } }.padding(.horizontal)
        }.padding(.top, 20)
    }
    
    @ViewBuilder
    private var searchResultsContent: some View {
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
    
    func getChannelsToShow() -> [StreamChannel] {
        guard let cat = selectedCategory else { return [] }
        if cat.id == -2 { return viewModel.recentIDs.compactMap { id in viewModel.channels.first(where: { $0.id == id }) } }
        if cat.id == -4 { return viewModel.channels.filter { viewModel.favoriteIDs.contains($0.id) } }
        if cat.id == -1 { return viewModel.channels.filter { !viewModel.hiddenIDs.contains($0.id) } }
        return viewModel.channels.filter { $0.categoryID == cat.id && !viewModel.hiddenIDs.contains($0.id) }
    }
}

struct StandardLayout: View {
    @ObservedObject var viewModel: ChannelViewModel
    @Binding var selectedCategory: StreamCategory?
    @Binding var selectedChannel: StreamChannel?
    @Binding var searchText: String
    let accentColor: Color
    let playAction: (StreamChannel) -> Void
    @Binding var showMultiView: Bool
    @Binding var showSettings: Bool
    @Binding var selectedRecording: Recording?
    
    @ObservedObject var recordingManager = RecordingManager.shared
    
    var body: some View {
        ZStack {
            if !searchText.isEmpty {
                searchView
            } else if let cat = selectedCategory {
                if cat.id == -3 {
                    SportsHubView(viewModel: viewModel, accentColor: accentColor, playAction: playAction, onBack: { withAnimation { selectedCategory = nil } }, scoreViewModel: viewModel.scoreViewModel).transition(.blurFade)
                } else if cat.id == -5 {
                    RecordingsView(onBack: { withAnimation { selectedCategory = nil } }).transition(.blurFade)
                } else {
                    CategoryDetailView(title: cat.name, channels: getChannelsToShow(for: cat), accentColor: accentColor, playAction: playAction, toggleFav: viewModel.toggleFavorite, promptRename: viewModel.triggerRenameChannel, hideChannel: viewModel.hideChannel, favoriteIDs: viewModel.favoriteIDs, viewModel: viewModel, showMultiView: $showMultiView, onBack: { withAnimation { selectedCategory = nil } }, onCategorySelect: { cat in withAnimation { selectedCategory = cat; searchText = "" } }).transition(.blurFade)
                }
            } else if viewModel.isLoading {
                loadingView
            } else {
                dashboardView
            }
        }
        .animation(.easeInOut(duration: 0.4), value: selectedCategory)
    }
    
    private var loadingView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 16) {
                HStack { SkeletonBox(width: 180, height: 24).cornerRadius(4); Spacer(); SkeletonBox(width: 14, height: 14).cornerRadius(2) }.padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 16) { ForEach(0..<4, id: \.self) { _ in SkeletonBox(height: 112).frame(width: 200).cornerRadius(12) } }.padding(.horizontal) }.frame(height: 150)
                HStack(spacing: 16) { SquareCardSkeleton(); SquareCardSkeleton() }.padding(.horizontal).padding(.vertical, 8)
                CategoryCardSkeleton(); CategoryCardSkeleton(); ForEach(0..<10, id: \.self) { _ in CategoryCardSkeleton() }
            }
            .padding(.vertical)
        }
    }
    
    private var dashboardView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 28) {
                    HStack { ClockView(); Spacer() }.padding(.horizontal, 20).padding(.top, 10)
                    
                    if !viewModel.recentIDs.isEmpty {
                        let recent = viewModel.recentIDs.compactMap { id in viewModel.channels.first(where: { $0.id == id }) }
                        if !recent.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                sectionHeader(title: "Recently Watched", id: -2)
                                HorizontalPreviewList(channels: recent, isRecent: true, accentColor: accentColor, viewModel: viewModel, playAction: playAction, promptRenameChannel: viewModel.triggerRenameChannel, hideChannel: viewModel.hideChannel, removeFromRecent: viewModel.removeFromRecent)
                            }
                        }
                    }
                    
                    if !recordingManager.recordings.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader(title: "Recent Recordings", id: -5)
                            HorizontalRecordingList(recordings: recordingManager.recordings.sorted(by: { $0.createdAt > $1.createdAt }), onSelect: { recording in selectedRecording = recording }, onDelete: { recording in recordingManager.deleteRecording(recording) })
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                            Button(action: { withAnimation { selectedCategory = StreamCategory(id: -4, name: "Favorites") } }) { SquareCategoryCard(title: "Favorites", icon: "star.fill", color: .yellow, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { withAnimation { selectedCategory = StreamCategory(id: -3, name: "Sports Center") } }) { SquareCategoryCard(title: "Sports Center", icon: "sportscourt.fill", color: .green, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { withAnimation { selectedCategory = StreamCategory(id: -5, name: "Recordings") } }) { SquareCategoryCard(title: "Recordings", icon: "film.fill", color: .blue, accentColor: accentColor) }.buttonStyle(.plain)
                            Button(action: { withAnimation { showMultiView = true } }) { SquareCategoryCard(title: "Multi-View", icon: "square.grid.2x2.fill", color: .purple, accentColor: accentColor) }.buttonStyle(.plain)
                        }
                        .padding(.horizontal)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Button(action: { withAnimation { selectedCategory = StreamCategory(id: -1, name: "All Channels") } }) { CategoryCard(title: "All Channels", icon: "tv.fill", color: .blue) }.buttonStyle(.plain).padding(.horizontal)
                        ForEach(viewModel.categories.filter { !$0.isHidden }) { cat in
                            Button(action: { withAnimation { selectedCategory = cat } }) {
                                CategoryCard(title: cat.name, color: accentColor)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                            .contextMenu {
                                Button { viewModel.triggerRenameCategory(cat) } label: { Label("Rename", systemImage: "pencil") }
                                Button { viewModel.hideCategory(cat.id) } label: { Label("Hide", systemImage: "eye.slash") }
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
        }
    }
    
    private var searchView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                if viewModel.isSearching {
                    VStack(alignment: .leading, spacing: 20) {
                        SkeletonBox(width: 150, height: 14).padding(.horizontal)
                        ScrollView(.horizontal) { HStack { ForEach(0..<4) { _ in HorizontalCardSkeleton() } } }.padding(.horizontal)
                    }.padding(.top, 20)
                } else {
                    searchResultsContent
                }
            }
            .padding(.top, 20)
        }
    }
    
    @ViewBuilder
    private var searchResultsContent: some View {
        if !viewModel.filteredEPGChannels.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("EPG GUIDE RESULTS").font(.system(size: 11, weight: .black)).kerning(1.2).foregroundColor(.white.opacity(0.5)).padding(.horizontal)
                HorizontalSearchList(channels: viewModel.filteredEPGChannels, viewModel: viewModel, accentColor: accentColor, playAction: playAction)
            }
        }
        if !viewModel.filteredNameChannels.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("CHANNEL NAME RESULTS").font(.system(size: 11, weight: .black)).kerning(1.2).foregroundColor(.white.opacity(0.5)).padding(.horizontal)
                HorizontalSearchList(channels: viewModel.filteredNameChannels, viewModel: viewModel, accentColor: accentColor, playAction: playAction)
            }
        }
        if !viewModel.filteredCategories.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("EXPLORE CATEGORIES").font(.system(size: 11, weight: .black)).kerning(1.2).foregroundColor(.white.opacity(0.5)).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.filteredCategories) { cat in
                            Button(action: { withAnimation { selectedCategory = cat; searchText = "" } }) {
                                CategoryCard(title: cat.name, color: .secondary, lineLimit: 1).multilineTextAlignment(.leading).frame(width: 200, height: 85)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal)
                }
            }
        }
        RecentSearchesView(viewModel: viewModel, accentColor: accentColor).padding(.top, 10)
    }
    
    func getChannelsToShow(for cat: StreamCategory) -> [StreamChannel] {
        if cat.id == -2 { return viewModel.recentIDs.compactMap { id in viewModel.channels.first(where: { $0.id == id }) } }
        if cat.id == -4 { return viewModel.channels.filter { viewModel.favoriteIDs.contains($0.id) } }
        if cat.id == -1 { return viewModel.channels.filter { !viewModel.hiddenIDs.contains($0.id) } }
        return viewModel.channels.filter { $0.categoryID == cat.id && !viewModel.hiddenIDs.contains($0.id) }
    }
    
    func sectionHeader(title: String, id: Int) -> some View {
        Button(action: { withAnimation { selectedCategory = StreamCategory(id: id, name: title) } }) {
            HStack {
                Text(title.uppercased()).font(.system(size: 11, weight: .black)).kerning(1.2).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
    }
}

struct MultiViewIndicator: View {
    let count: Int
    let accentColor: Color?
    let action: () -> Void
    var body: some View {
        VStack {
            Spacer()
            Button(action: action) {
                HStack {
                    Image(systemName: "square.grid.2x2.fill")
                    Text("Multi-View Active: \(count)/4")
                }
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .modifier(GlassEffect(cornerRadius: 20, isSelected: true, accentColor: accentColor))
            }
            .padding(.bottom, 20)
        }
    }
}

struct MiniPlayerView: View {
    let channel: StreamChannel
    @ObservedObject var viewModel: ChannelViewModel
    let onExpand: () -> Void
    let onClose: () -> Void
    
    @ObservedObject var playerManager = PlaybackManager.shared
    @State private var showControls = false
    @State private var pipOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        ZStack {
            UnifiedPlayerViewBridge()
                .frame(width: 240, height: 135)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 10)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() } }
            
            if showControls {
                ZStack {
                    Color.black.opacity(0.3).clipShape(RoundedRectangle(cornerRadius: 16))
                    Button(action: { if playerManager.isPlaying { playerManager.pause() } else { playerManager.resume() } }) {
                        Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill").font(.title).foregroundColor(.white).padding(16).background(.ultraThinMaterial).clipShape(Circle())
                    }.buttonStyle(.plain)
                    
                    VStack {
                        HStack {
                            Button(action: { onClose(); playerManager.stop() }) {
                                Image(systemName: "xmark").font(.caption.bold()).foregroundColor(.white).padding(8).background(.ultraThinMaterial).clipShape(Circle())
                            }.buttonStyle(.plain)
                            Spacer()
                            Button(action: onExpand) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption.bold()).foregroundColor(.white).padding(8).background(.ultraThinMaterial).clipShape(Circle())
                            }.buttonStyle(.plain)
                        }.padding(8)
                        Spacer()
                    }
                }
            }
        }
        .frame(width: 240, height: 135)
        .offset(pipOffset)
        .gesture(
            DragGesture()
                .onChanged { value in pipOffset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height) }
                .onEnded { value in
                    let screen = UIScreen.main.bounds
                    let tx = pipOffset.width > -((screen.width - 240 - 40) / 2) ? 0 : -(screen.width - 240 - 40)
                    let ty = pipOffset.height < -((screen.height - 135 - 120) / 2) ? -(screen.height - 135 - 120) + 60 : 0
                    withAnimation(.spring()) { pipOffset = CGSize(width: tx, height: ty); lastOffset = pipOffset }
                }
        )
        .onAppear { if let url = URL(string: channel.streamURL) { playerManager.play(url: url) } }
    }
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
                                searchResultsView
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
                    .onAppear { if let last = viewModel.lastPlayedChannelID { DispatchQueue.main.async { proxy.scrollTo(last, anchor: .center) } } }
                    .onChangeCompat(of: viewModel.lastPlayedChannelID) { id in if let id = id { proxy.scrollTo(id, anchor: .center) } }
                    .onChangeCompat(of: viewModel.scrollRestoreTrigger) { _ in if let last = viewModel.lastPlayedChannelID { proxy.scrollTo(last, anchor: .center) } }
                }
            }
            if viewModel.activeMultiViewCount > 0 { MultiViewIndicator(count: viewModel.activeMultiViewCount, accentColor: nil, action: { withAnimation(.easeInOut(duration: 0.35)) { showMultiView = true } }) }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { if let onBack = onBack { Button(action: onBack) { HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Back") }.foregroundStyle(.white) } } } }
        .alert(item: $channelForDescription) { channel in Alert(title: Text("Program Description"), message: Text(viewModel.getCurrentProgram(for: channel)?.description ?? "No description available."), dismissButton: .default(Text("OK"))) }
    }
    
    @ViewBuilder
    private var searchResultsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            if viewModel.isSearching {
                VStack(alignment: .leading, spacing: 20) {
                    SkeletonBox(width: 150, height: 14).padding(.horizontal)
                    ScrollView(.horizontal) { HStack { ForEach(0..<4) { _ in HorizontalCardSkeleton() } } }.padding(.horizontal)
                }.padding(.top, 20)
            } else {
                if !viewModel.filteredEPGChannels.isEmpty { Text("EPG RESULTS").font(.caption.bold()).foregroundColor(.white.opacity(0.5)).padding(.horizontal); HorizontalSearchList(channels: viewModel.filteredEPGChannels, viewModel: viewModel, accentColor: accentColor, playAction: playAction) }
                if !viewModel.filteredNameChannels.isEmpty { Text("NAME RESULTS").font(.caption.bold()).foregroundColor(.white.opacity(0.5)).padding(.horizontal); HorizontalSearchList(channels: viewModel.filteredNameChannels, viewModel: viewModel, accentColor: accentColor, playAction: playAction) }
                if !viewModel.filteredCategories.isEmpty {
                    Text("EXPLORE CATEGORIES").font(.caption.bold()).foregroundColor(.white.opacity(0.5)).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 12) { ForEach(viewModel.filteredCategories) { cat in Button(action: { onCategorySelect?(cat) }) { CategoryCard(title: cat.name, color: .secondary, lineLimit: 1).multilineTextAlignment(.leading).frame(width: 200, height: 85) }.buttonStyle(.plain) } }.padding(.horizontal) }
                }
                RecentSearchesView(viewModel: viewModel, accentColor: accentColor)
            }
        }.padding(.top)
    }
}

// MARK: - SKELETONS
struct SkeletonBox: View {
    var width: CGFloat? = nil
    var height: CGFloat
    @State private var opacity = 0.3
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(opacity))
            .frame(width: width, height: height)
            .onAppear { withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { opacity = 0.1 } }
    }
}

struct ChannelRowSkeleton: View {
    var body: some View {
        HStack(spacing: 16) {
            SkeletonBox(width: 50, height: 50).cornerRadius(12)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBox(width: 150, height: 16)
                SkeletonBox(width: 100, height: 12)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

struct HorizontalCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBox(width: 200, height: 112).cornerRadius(16)
            SkeletonBox(width: 120, height: 14)
            SkeletonBox(width: 80, height: 12)
        }
    }
}

struct SquareCardSkeleton: View {
    var body: some View {
        SkeletonBox(height: 120).frame(maxWidth: .infinity).cornerRadius(16)
    }
}

struct CategoryCardSkeleton: View {
    var body: some View {
        SkeletonBox(height: 80).frame(maxWidth: .infinity).cornerRadius(16).padding(.horizontal)
    }
}