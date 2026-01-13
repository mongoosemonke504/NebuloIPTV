import SwiftUI
import Combine
import KSPlayer

// MARK: - UI COMPONENTS

struct CustomVideoPlayerView: SwiftUI.View {
    let channel: StreamChannel
    var viewModel: ChannelViewModel? = nil
    var namespace: Namespace.ID? = nil
    var onDismiss: (() -> Void)? = nil
    var onPlayChannel: ((StreamChannel) -> Void)? = nil
    
    @Binding var showQuickSwitcher: Bool
    
    // OBSERVE THE PLAYER MANAGER
    @ObservedObject var playerManager = NebuloPlayerEngine.shared
    
    @State private var showControls = true
    @State private var offset: CGSize = .zero
    @State private var timer: AnyCancellable?
    @State private var showFullDescription = false
    @State private var descriptionHeight: CGFloat = 0
    @State private var currentStreamURL: URL?
    @Environment(\.scenePhase) var scenePhase
    
    // Quick Switcher
    @State private var quickSwitcherOffset: CGFloat = 200
    @State private var switcherCategory: StreamCategory = StreamCategory(id: -2, name: "Recently Watched")
    @State private var showCategoryPicker = false
    @State private var frozenRecentIDs: [Int] = []
    
    // Menu Interaction State
    @State private var isMenuOpen = false
    @State private var showSubtitlePanel = false
    @State private var showResolutionPanel = false
    @State private var showAspectRatioPanel = false
    @State private var captionContainerSize: CGSize = CGSize(width: 600, height: 150)
    @State private var isCaptionResizeMode = false
    
    // Safety for dismissal race conditions
    @State private var dismissalTask: Task<Void, Never>? = nil
    
    // Progress Bar State
    @State private var isScrubbing = false
    @State private var draggingProgress: Double? = nil
    
    @AppStorage("accentColor") private var accentHex = "#007AFF"
    var accentColor: Color { Color(hex: accentHex) ?? .blue }
    
    var body: some SwiftUI.View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // THE PLAYER VIEW (Bridge to KSPlayer/VLC)
            UnifiedPlayerViewBridge()
                .applyIf(namespace != nil) { $0.matchedGeometryEffect(id: "videoPlayer", in: namespace!) }
                .ignoresSafeArea()
                .persistentSystemOverlays(.hidden)
            
            // CONTROLS OVERLAY
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
            
            // BUFFERING INDICATOR (On Top)
            if playerManager.isBuffering {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.7)
                    .frame(width: 82, height: 82)
                    .modifier(GlassEffect(cornerRadius: 42, isSelected: true, accentColor: nil))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            
            // QUICK SWITCHER (Channel Guide)
            if showQuickSwitcher {
                Color.black.opacity(0.01).ignoresSafeArea().onTapGesture { withAnimation { showQuickSwitcher = false } }
                
                VStack(spacing: 0) {
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 40, height: 5)
                        .padding(.top, 10)
                        .padding(.bottom, 10)
                    
                    HStack {
                        Menu {
                            Button("Recently Watched") { switcherCategory = StreamCategory(id: -2, name: "Recently Watched") }
                            Button("Favorites") { switcherCategory = StreamCategory(id: -4, name: "Favorites") }
                            Button("All Channels") { switcherCategory = StreamCategory(id: -1, name: "All Channels") }
                            if let cats = viewModel?.categories {
                                ForEach(cats.filter { !$0.isHidden }) { cat in
                                    Button(cat.name) { switcherCategory = cat }
                                }
                            }
                        } label: { 
                            HStack(spacing: 4) { 
                                Text(switcherCategory.name).font(.headline).fontWeight(.bold)
                                Image(systemName: "chevron.down").font(.caption.bold()) 
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
                        HStack(spacing: 12) {
                            let channels = getChannelsForSwitcher()
                            ForEach(channels) { c in
                                Button(action: { 
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    onPlayChannel?(c) 
                                }) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        CachedAsyncImage(urlString: c.icon ?? "", size: CGSize(width: 140, height: 80))
                                            .frame(width: 140, height: 80)
                                            .background(Color.black.opacity(0.3))
                                            .cornerRadius(8)
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(c.id == channel.id ? Color.white : Color.clear, lineWidth: 2))
                                        
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
                                                // Placeholder to maintain height
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
                .background(.ultraThinMaterial)
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
            
            // SUBTITLE SETTINGS PANEL
            if showSubtitlePanel {
                settingsPanelOverlay {
                    VStack(spacing: 0) {
                        Text("Subtitles").font(.headline).foregroundColor(.white).padding()
                        Divider().background(Color.white.opacity(0.3))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(playerManager.availableSubtitles, id: \.id) { sub in
                                    Button(action: {
                                        playerManager.selectSubtitle(sub)
                                    }) {
                                        HStack {
                                            Text(sub.name)
                                            Spacer()
                                            if playerManager.currentSubtitle?.id == sub.id { Image(systemName: "checkmark") }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(playerManager.currentSubtitle?.id == sub.id ? .yellow : .white)
                                    .padding(.vertical, 4).padding(.horizontal)
                                }
                            }.padding(.top)
                        }.frame(maxHeight: 200)
                    }
                } onClose: { showSubtitlePanel = false }
            }
            
            // RESOLUTION SETTINGS PANEL
            if showResolutionPanel {
                settingsPanelOverlay {
                    VStack(spacing: 0) {
                        Text("Quality").font(.headline).foregroundColor(.white).padding()
                        Divider().background(Color.white.opacity(0.3))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(playerManager.availableQualities) { q in
                                    Button(action: {
                                        playerManager.setQuality(q)
                                        withAnimation { showResolutionPanel = false }
                                        resetTimer()
                                    }) {
                                        HStack {
                                            Text(q.rawValue)
                                            Spacer()
                                            if playerManager.currentQuality == q { Image(systemName: "checkmark") }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(playerManager.currentQuality == q ? .yellow : .white)
                                    .padding(.vertical, 4).padding(.horizontal)
                                }
                            }.padding(.top)
                        }.frame(maxHeight: 200)
                    }
                } onClose: { showResolutionPanel = false }
            }
            
            // ASPECT RATIO PANEL
            if showAspectRatioPanel {
                settingsPanelOverlay {
                    VStack(spacing: 0) {
                        Text("Aspect Ratio").font(.headline).foregroundColor(.white).padding()
                        Divider().background(Color.white.opacity(0.3))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(NebuloPlayerEngine.VideoAspectRatio.allCases) { ratio in
                                    Button(action: {
                                        playerManager.setAspectRatio(ratio)
                                        withAnimation { showAspectRatioPanel = false }
                                        resetTimer()
                                    }) {
                                        HStack {
                                            Text(ratio.rawValue)
                                            Spacer()
                                            if playerManager.currentAspectRatio == ratio { Image(systemName: "checkmark") }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(playerManager.currentAspectRatio == ratio ? .white : .white.opacity(0.5))
                                    .padding(.vertical, 4).padding(.horizontal)
                                }
                            }.padding(.top)
                        }.frame(maxHeight: 200)
                    }
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
            // Safe area for Notification Center (ignore swipes starting at the very top)
            if val.startLocation.y < 60 { return }
            
            if val.translation.height > 0 && abs(val.translation.height) > abs(val.translation.width) { offset = val.translation }
        }
        .onEnded { val in 
            if showQuickSwitcher { return }
            if val.startLocation.y < 60 { return }
            
            if val.translation.height > 100 && abs(val.translation.height) > abs(val.translation.width) { 
                // Instead of full dismissal, trigger the mini-player
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
        }
        .onDisappear {
            dismissalTask?.cancel()
            // Stop ONLY if app is active (meaning user navigated away)
            // If backgrounded, phase is not .active
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
        .onChangeCompat(of: showQuickSwitcher) { isOpen in 
            if isOpen { 
                frozenRecentIDs = viewModel?.recentIDs ?? []
                timer?.cancel()
            } else { 
                quickSwitcherOffset = 200 
                resetTimer()
            } 
        }
    }
    
    // MARK: - LOGIC
    
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
        KSOptions.isAutoPlay = true
        Task {
            // Check for active recording handoff
            if let localURL = RecordingManager.shared.getActiveRecordingURL(for: channel) {
                print("⏺️ [Player] Playing from active recording file: \(localURL.lastPathComponent)")
                await MainActor.run {
                    self.currentStreamURL = localURL
                    // Force play local file (treat as new content to avoid resume logic skipping it)
                    playerManager.play(url: localURL)
                    
                    let prog = viewModel?.getCurrentProgram(for: channel)?.title
                    playerManager.updateNowPlayingMetadata(title: channel.name, subtitle: prog, imageURL: channel.icon)
                }
                return
            }
            
            let resolvedURLString = await viewModel?.resolveStalkerStream(channel) ?? channel.streamURL
            guard let targetURL = URL(string: resolvedURLString) else { return }
            
            // Give the UI a moment to settle and renderView to get its frame
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s delay
            
            await MainActor.run {
                self.currentStreamURL = targetURL
                
                // Smart Resume Logic: Prevent restarting stream if already loaded
                // 1. Check exact match
                // 2. Check path match (ignore tokens)
                // 3. Check ID match (handle Xtream Codes /live/ vs /timeshift/ difference)
                
                var shouldResume = false
                
                if let current = playerManager.currentURL, playerManager.activeBackendName != "None" {
                    if current.absoluteString == targetURL.absoluteString {
                        shouldResume = true
                    } else if current.path == targetURL.path {
                        shouldResume = true
                    } else {
                        // Check if filenames (Stream IDs) match, ignoring extension
                        let currentID = current.deletingPathExtension().lastPathComponent
                        let targetID = targetURL.deletingPathExtension().lastPathComponent
                        if !currentID.isEmpty && currentID == targetID {
                            shouldResume = true
                        }
                    }
                }
                
                if shouldResume {
                    // Backend is active and content matches.
                    // If not playing (paused in mini-player), simply resume to preserve time-shift buffer.
                    if !playerManager.isPlaying && !playerManager.isBuffering {
                        playerManager.resume()
                    }
                    // If already playing/buffering, do nothing (seamless transition)
                } else {
                    // Different content or fully stopped -> Force load (resets buffer)
                    playerManager.play(url: targetURL)
                }
                
                // Always update metadata
                let prog = viewModel?.getCurrentProgram(for: channel)?.title
                playerManager.updateNowPlayingMetadata(title: channel.name, subtitle: prog, imageURL: channel.icon)
            }
        }
    }
}