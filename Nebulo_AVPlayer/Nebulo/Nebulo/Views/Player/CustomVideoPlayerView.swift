import SwiftUI
import Combine

struct CustomVideoPlayerView: SwiftUI.View {
    let channel: StreamChannel
    var viewModel: ChannelViewModel? = nil
    var epgTime: Date = Date()
    var namespace: Namespace.ID? = nil
    var onDismiss: (() -> Void)? = nil
    var onPlayChannel: ((StreamChannel) -> Void)? = nil
    
    @Binding var showQuickSwitcher: Bool
    
    
    @ObservedObject var playerManager = NebuloPlayerEngine.shared
    
    @State private var showControls = true
    @State private var offset: CGSize = .zero
    @State private var timer: AnyCancellable?
    @State private var showFullDescription = false
    @State private var descriptionHeight: CGFloat = 0
    @State private var currentStreamURL: URL?
    @Environment(\.scenePhase) var scenePhase
    
    
    @State private var quickSwitcherOffset: CGFloat = 200
    @State private var switcherCategory: StreamCategory = StreamCategory(id: -2, name: "Recently Watched")
    @State private var showCategoryPicker = false
    @State private var frozenRecentIDs: [Int] = []
    @State private var switcherChannels: [StreamChannel] = []
    
    
    @State private var isMenuOpen = false
    @State private var showSubtitlePanel = false
    @State private var showResolutionPanel = false
    @State private var showAspectRatioPanel = false
    @State private var captionContainerSize: CGSize = CGSize(width: 600, height: 150)
    @State private var isCaptionResizeMode = false
    
    
    @State private var dismissalTask: Task<Void, Never>? = nil
    
    
    @State private var isScrubbing = false
    @State private var draggingProgress: Double? = nil
    
    @AppStorage("accentColor") private var accentHex = "#007AFF"
    var accentColor: Color { Color(hex: accentHex) ?? .blue }
    
    var body: some SwiftUI.View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            
            UnifiedPlayerViewBridge()
                .applyIf(namespace != nil) { $0.matchedGeometryEffect(id: "videoPlayer", in: namespace!) }
                .ignoresSafeArea()
                .persistentSystemOverlays(.hidden)
            
            
            PlayerControlsView(
                playerManager: playerManager,
                channel: channel,
                viewModel: viewModel,
                showControls: $showControls,
                showSubtitlePanel: $showSubtitlePanel,
                showResolutionPanel: $showResolutionPanel,
                showAspectRatioPanel: $showAspectRatioPanel,
                showFullDescription: $showFullDescription,
                isScrubbing: $isScrubbing,
                draggingProgress: $draggingProgress,
                onDismiss: { dismissAnimate() },
                togglePlay: { togglePlay() },
                toggleControls: { toggleControls() },
                seekForward: { playerManager.seek(to: playerManager.currentTime + 15); resetTimer() },
                seekBackward: { playerManager.seek(to: playerManager.currentTime - 15); resetTimer() }
            )
            
            
            if playerManager.isBuffering {
                CustomSpinner(color: .white, lineWidth: 5, size: 50)
                    .frame(width: 82, height: 82)
                    .modifier(GlassEffect(cornerRadius: 42, isSelected: true, accentColor: nil))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            
            
            if showQuickSwitcher {
                Color.black.opacity(0.01).ignoresSafeArea().onTapGesture { withAnimation { showQuickSwitcher = false } }
                
                QuickSwitcherView(
                    channels: switcherChannels,
                    currentChannelID: channel.id,
                    switcherCategory: $switcherCategory,
                    categories: viewModel?.categories ?? [],
                    viewModel: viewModel,
                    onPlay: { c in
                        UISelectionFeedbackGenerator().selectionChanged()
                        onPlayChannel?(c)
                    }
                )
                .frame(maxHeight: .infinity, alignment: .bottom)
                .offset(y: quickSwitcherOffset)
                .transition(.move(edge: .bottom))
                .gesture(
                    DragGesture()
                        .onChanged { val in
                            if val.translation.height > 0 { quickSwitcherOffset = min(200, val.translation.height) }
                        }
                        .onEnded { val in
                            if val.translation.height > 50 { withAnimation { showQuickSwitcher = false } }
                            else { withAnimation { quickSwitcherOffset = 0 } }
                        }
                )
            }
            
            
            if showSubtitlePanel {
                settingsPanelOverlay {
                    SettingsList(
                        items: playerManager.availableSubtitles,
                        selectedItem: playerManager.currentSubtitle,
                        title: "Subtitles",
                        onSelect: { sub in playerManager.selectSubtitle(sub) },
                        itemLabel: { $0.name }
                    )
                } onClose: { showSubtitlePanel = false }
            }
            
            
            if showResolutionPanel {
                settingsPanelOverlay {
                    SettingsList(
                        items: playerManager.availableQualities,
                        selectedItem: playerManager.currentQuality,
                        title: "Quality",
                        onSelect: { q in
                            playerManager.setQuality(q)
                            withAnimation { showResolutionPanel = false }
                            resetTimer()
                        },
                        itemLabel: { $0.rawValue }
                    )
                } onClose: { showResolutionPanel = false }
            }
            
            
            if showAspectRatioPanel {
                settingsPanelOverlay {
                    SettingsList(
                        items: NebuloPlayerEngine.VideoAspectRatio.allCases,
                        selectedItem: playerManager.currentAspectRatio,
                        title: "Aspect Ratio",
                        onSelect: { ratio in
                            playerManager.setAspectRatio(ratio)
                            withAnimation { showAspectRatioPanel = false }
                            resetTimer()
                        },
                        itemLabel: { $0.rawValue }
                    )
                } onClose: { showAspectRatioPanel = false }
            }
        }
        .ignoresSafeArea()
        .statusBar(hidden: true)
        .preferredColorScheme(.dark)
        .tint(.white)
        .offset(y: offset.height)
        .gesture(DragGesture().onChanged { val in
            if showQuickSwitcher { return }
            
            if val.startLocation.y < 60 { return }
            
            if val.translation.height > 0 && abs(val.translation.height) > abs(val.translation.width) { offset = val.translation }
        }
        .onEnded { val in 
            if showQuickSwitcher { return }
            if val.startLocation.y < 60 { return }
            
            if val.translation.height > 100 && abs(val.translation.height) > abs(val.translation.width) { 
                
                withAnimation(.easeInOut(duration: 0.35)) {
                    viewModel?.miniPlayerChannel = channel
                    onDismiss?()
                }
            } else if val.translation.height < -100 && abs(val.translation.height) > abs(val.translation.width) {
                frozenRecentIDs = viewModel?.recentIDs ?? []
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showQuickSwitcher = true
                    quickSwitcherOffset = 0
                    showControls = true
                    timer?.cancel()
                }
            } else if val.translation.width < -50 && abs(val.translation.width) > abs(val.translation.height) { 
                switchChannel(offset: 1); withAnimation { offset = .zero } 
            } else if val.translation.width > 50 && abs(val.translation.width) > abs(val.translation.height) { 
                switchChannel(offset: -1); withAnimation { offset = .zero } 
            } else { withAnimation { offset = .zero } } 
        })
        .onAppear {
            setupPlayer()
            if showQuickSwitcher { 
                frozenRecentIDs = viewModel?.recentIDs ?? []
                quickSwitcherOffset = 0
                showControls = false 
            } else {
                showControls = true
                resetTimer()
            }
            switcherChannels = getChannelsForSwitcher()
        }
        .onDisappear {
            dismissalTask?.cancel()
            
            
            if scenePhase == .active && viewModel?.miniPlayerChannel == nil && viewModel?.triggerMultiView != true {
                playerManager.stop()
            }
            timer?.cancel()
        }
        .onChangeCompat(of: channel) { _ in 
            setupPlayer()
            withAnimation { showControls = true }
            resetTimer()
        }
        .onChangeCompat(of: playerManager.isPlaying) { playing in
            if playing && showControls {
                resetTimer()
            }
        }
        .onChangeCompat(of: epgTime) { _ in
            updateMetadata()
        }
        .onChangeCompat(of: switcherCategory) { _ in
            switcherChannels = getChannelsForSwitcher()
        }
        .onChangeCompat(of: showQuickSwitcher) { isOpen in 
            if isOpen { 
                frozenRecentIDs = viewModel?.recentIDs ?? []
                switcherChannels = getChannelsForSwitcher()
                timer?.cancel()
            } else { 
                quickSwitcherOffset = 200 
                resetTimer()
            } 
        }
    }
    
    func updateMetadata() {
        let prog = viewModel?.getCurrentProgram(for: channel)?.title
        if let p = prog, !p.isEmpty {
            playerManager.updateNowPlayingMetadata(title: p, subtitle: channel.name, imageURL: channel.icon)
        } else {
            playerManager.updateNowPlayingMetadata(title: channel.name, subtitle: nil, imageURL: channel.icon)
        }
    }
    
    
    
    @ViewBuilder
    private func settingsPanelOverlay<Content: View>(@ViewBuilder content: () -> Content, onClose: @escaping () -> Void) -> some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture {
                withAnimation { onClose() }
                resetTimer()
            }
            content()
                .frame(width: 300)
                .background(Material.ultraThinMaterial)
                .cornerRadius(16)
                .shadow(radius: 20)
                .transition(.scale.combined(with: .opacity))
                .zIndex(100)
        }
    }

    func getChannelsForSwitcher() -> [StreamChannel] {
        guard let vm = viewModel else { return [] }
        if switcherCategory.id == -2 { let ids = frozenRecentIDs.isEmpty ? vm.recentIDs : frozenRecentIDs; return ids.compactMap { id in vm.channels.first(where: { $0.id == id }) } }
        if switcherCategory.id == -4 { return vm.channels.filter { vm.favoriteIDs.contains($0.id) } }
        if switcherCategory.id == -1 { return vm.channels.filter { !vm.hiddenIDs.contains($0.id) } }
        return vm.channels.filter { $0.categoryID == switcherCategory.id && !vm.hiddenIDs.contains($0.id) }
    }
    
    func switchChannel(offset: Int) {
        guard let vm = viewModel else { return }
        let allChannels = vm.channels.filter { !vm.hiddenIDs.contains($0.id) }
        guard let idx = allChannels.firstIndex(where: { $0.id == channel.id }) else { return }
        var nextIdx = idx + offset
        if nextIdx < 0 { nextIdx = allChannels.count - 1 }
        if nextIdx >= allChannels.count { nextIdx = 0 }
        if allChannels.indices.contains(nextIdx) { onPlayChannel?(allChannels[nextIdx]); resetTimer() }
    }
    
    func dismissAnimate() {
        withAnimation(.easeInOut(duration: 0.35)) { offset = CGSize(width: 0, height: UIScreen.main.bounds.height) }
        dismissalTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { await MainActor.run { onDismiss?() } }
        }
    }
    
    func togglePlay() { 
        if playerManager.isPlaying { playerManager.pause() }
        else { playerManager.resume() }
        resetTimer()
    }
    
    func toggleControls() { 
        isMenuOpen = false
        if showSubtitlePanel { withAnimation { showSubtitlePanel = false }; resetTimer(); return }
        if showResolutionPanel { withAnimation { showResolutionPanel = false }; resetTimer(); return }
        if showAspectRatioPanel { withAnimation { showAspectRatioPanel = false }; resetTimer(); return }
        if isCaptionResizeMode { withAnimation { isCaptionResizeMode = false }; resetTimer(); return }
        
        withAnimation(.easeInOut(duration: 0.15)) { 
            if showControls { showControls = false; timer?.cancel() }
            else { showControls = true; resetTimer() } 
        } 
    }
    
    func resetTimer() { 
        timer?.cancel()
        if isMenuOpen || showQuickSwitcher || showSubtitlePanel || showResolutionPanel || showAspectRatioPanel || isCaptionResizeMode { return }
        timer = Just(()).delay(for: 4.0, scheduler: RunLoop.main).sink { _ in withAnimation(.easeInOut(duration: 0.15)) { showControls = false } } 
    }
    
    func setupPlayer() {
        // KSPlayer options removed
        Task {
            
            if let localURL = RecordingManager.shared.getActiveRecordingURL(for: channel) {
                print("⏺️ [Player] Playing from active recording file: \(localURL.lastPathComponent)")
                await MainActor.run {
                    self.currentStreamURL = localURL
                    
                    playerManager.play(url: localURL)
                    
                    let prog = viewModel?.getCurrentProgram(for: channel)?.title
                    if let p = prog, !p.isEmpty {
                        playerManager.updateNowPlayingMetadata(title: p, subtitle: channel.name, imageURL: channel.icon)
                    } else {
                        playerManager.updateNowPlayingMetadata(title: channel.name, subtitle: nil, imageURL: channel.icon)
                    }
                }
                return
            }
            
            let resolvedURLString = channel.streamURL
            guard let targetURL = URL(string: resolvedURLString) else { return }
            
            
            try? await Task.sleep(nanoseconds: 500_000_000) 
            
            await MainActor.run {
                self.currentStreamURL = targetURL
                
                
                
                
                
                
                var shouldResume = false
                
                if let current = playerManager.currentURL, playerManager.activeBackendName != "None" {
                    if current.absoluteString == targetURL.absoluteString {
                        shouldResume = true
                    } else if current.path == targetURL.path {
                        shouldResume = true
                    } else {
                        
                        let currentID = current.deletingPathExtension().lastPathComponent
                        let targetID = targetURL.deletingPathExtension().lastPathComponent
                        if !currentID.isEmpty && currentID == targetID {
                            shouldResume = true
                        }
                    }
                }
                
                if shouldResume {
                    
                    
                    if !playerManager.isPlaying && !playerManager.isBuffering {
                        playerManager.resume()
                    }
                    
                } else {
                    
                    playerManager.play(url: targetURL)
                }
                
                
                let prog = viewModel?.getCurrentProgram(for: channel)?.title
                if let p = prog, !p.isEmpty {
                    playerManager.updateNowPlayingMetadata(title: p, subtitle: channel.name, imageURL: channel.icon)
                } else {
                    playerManager.updateNowPlayingMetadata(title: channel.name, subtitle: nil, imageURL: channel.icon)
                }
            }
        }
    }
}

struct QuickSwitcherView: View {
    let channels: [StreamChannel]
    let currentChannelID: Int
    @Binding var switcherCategory: StreamCategory
    let categories: [StreamCategory]
    var viewModel: ChannelViewModel?
    let onPlay: (StreamChannel) -> Void
    
    @State private var showCategoryList = false
    
    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 40, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 10)
            
            HStack {
                Button(action: { withAnimation { showCategoryList.toggle() } }) {
                    HStack(spacing: 4) { 
                        Text(switcherCategory.name).font(.headline).fontWeight(.bold)
                        Image(systemName: showCategoryList ? "chevron.up" : "chevron.down").font(.caption.bold()) 
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .modifier(GlassEffect(cornerRadius: 20, isSelected: true, accentColor: nil))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 15)
            
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(channels) { c in
                        Button(action: { 
                            ChannelViewModel.shared.triggerSelectionHaptic()
                            onPlay(c) 
                        }) {
                            VStack(alignment: .leading, spacing: 6) {
                                CachedAsyncImage(urlString: c.icon ?? "", size: CGSize(width: 140, height: 80))
                                    .frame(width: 140, height: 80)
                                    .background(Color.black.opacity(0.3))
                                    .cornerRadius(8)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(c.id == currentChannelID ? Color.white : Color.clear, lineWidth: 2))
                                
                                Text(c.name)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .frame(width: 140, alignment: .leading)
                                
                                VStack(alignment: .leading) {
                                    if let prog = viewModel?.getCurrentProgram(for: c) {
                                        Text(prog.title)
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.7))
                                            .lineLimit(1)
                                            .frame(width: 140, alignment: .leading)
                                    } else {
                                        Text(" ")
                                            .font(.caption2)
                                            .frame(width: 140, alignment: .leading)
                                    }
                                }
                                .frame(height: 15)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 40)
        }
        .background(Material.ultraThinMaterial)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottomLeading) {
            if showCategoryList {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            categoryButton(id: -2, name: "Recently Watched")
                            categoryButton(id: -4, name: "Favorites")
                            categoryButton(id: -1, name: "All Channels")
                            
                            if !categories.isEmpty {
                                Divider().background(Color.white.opacity(0.2)).padding(.vertical, 4)
                                ForEach(categories.filter { !$0.isHidden }) { cat in
                                    categoryButton(id: cat.id, name: cat.name, cat: cat)
                                }
                            }
                        }
                        .padding(8)
                    }
                }
                .frame(width: 250, height: 300)
                .background(Material.thickMaterial)
                .cornerRadius(12)
                .shadow(radius: 10)
                .padding(.leading, 16)
                .padding(.bottom, 130)
                .transition(.scale.combined(with: .opacity).animation(.spring()))
            }
        }
    }
    
    private func categoryButton(id: Int, name: String, cat: StreamCategory? = nil) -> some View {
        Button(action: {
            ChannelViewModel.shared.triggerSelectionHaptic()
            if let c = cat { switcherCategory = c }
            else { switcherCategory = StreamCategory(id: id, name: name) }
            withAnimation { showCategoryList = false }
        }) {
            HStack {
                Text(name)
                    .font(.subheadline)
                    .foregroundColor(switcherCategory.id == id ? .white : .white.opacity(0.7))
                Spacer()
                if switcherCategory.id == id { Image(systemName: "checkmark").font(.caption).foregroundColor(.yellow) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(switcherCategory.id == id ? Color.white.opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}