import SwiftUI
import Combine

struct CustomVideoPlayerView: SwiftUI.View {
    let channel: StreamChannel
    var viewModel: ChannelViewModel? = nil
    var scoreViewModel: ScoreViewModel? = nil
    var epgTime: Date = Date()
    var namespace: Namespace.ID? = nil
    var onDismiss: (() -> Void)? = nil
    var onPlayChannel: ((StreamChannel) -> Void)? = nil
    /// Routes a recording tapped in the info panel up to MainView, which
    /// dismisses this player and presents the recording over home.
    var onPlayRecording: ((Recording) -> Void)? = nil
    /// When true: suppresses the record button and active-recording URL hijack.
    var isRecordingPlayback: Bool = false
    /// When true: stays fullscreen in portrait (skips the split video+info layout).
    var forceFullscreen: Bool = false
    /// Optional real channel passed to PlayerInfoPanel in recording playback mode,
    /// so EPG / schedule / channel list reflect the actual live channel.
    var infoChannel: StreamChannel? = nil

    @Binding var showQuickSwitcher: Bool


    @ObservedObject var playerManager = NebuloPlayerEngine.shared

    @State private var currentChannel: StreamChannel?
    @State private var showControls = true
    /// Dismiss-drag translation, held in its own observable object so the
    /// per-frame writes re-render ONLY the transform modifier at the root —
    /// not this entire body (video surface, controls, info panel), which
    /// was the dropped frames during the pull-down.
    @State private var dismissDrag = ScrollProgress()
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
    @State private var showAudioPanel = false
    @State private var showResolutionPanel = false
    @State private var showAspectRatioPanel = false
    @State private var captionContainerSize: CGSize = CGSize(width: 600, height: 150)
    @State private var isCaptionResizeMode = false

    /// In portrait, if true: video takes full screen (current behavior).
    /// If false: video is at top in 16:9, info panel is below.
    @State private var isFullscreenInPortrait = false

    @State private var dismissalTask: Task<Void, Never>? = nil


    @State private var isScrubbing = false
    @State private var draggingProgress: Double? = nil

    @AppStorage("accentColor") private var accentHex = "#FFFFFF"
    var accentColor: Color { Color(hex: accentHex) ?? .blue }

    // MARK: - Apple-like dismiss transform
    //
    // Pattern follows iOS native sheet/Music-app dismissal:
    //   • Drag phase: player follows the finger 1:1 vertically with a subtle
    //     depth pull-back (gentle scale + corner radius growth). No horizontal
    //     drift, no anchor tricks — keeps the motion feeling rooted to the touch.
    //   • Commit:   springs off the bottom of the screen with momentum,
    //     swapping to the miniplayer just as the slide finishes.
    //   • Cancel:   springs back to identity.
    //
    // Trying to morph the source view into the destination view (YouTube/Music's
    // illusion) is fragile in SwiftUI without matchedGeometryEffect on the
    // underlying AVPlayer layer. Instead we slide the source cleanly away and
    // let the miniplayer animate in independently — the same playback engine
    // continues, so the audio/video feels continuous regardless.

    var body: some SwiftUI.View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let useSplit = !isLandscape && !isFullscreenInPortrait && !forceFullscreen

            ZStack {
                Color.black.ignoresSafeArea()

                if useSplit {
                    splitLayoutWithBuffering(geo: geo)
                } else {
                    fullscreenLayoutWithBuffering
                }

                if showQuickSwitcher {
                    Color.black.opacity(0.01).ignoresSafeArea().onTapGesture { withAnimation { showQuickSwitcher = false } }

                    QuickSwitcherView(
                        channels: switcherChannels,
                        currentChannelID: (currentChannel ?? channel).id,
                        switcherCategory: $switcherCategory,
                        categories: viewModel?.categories ?? [],
                        viewModel: viewModel,
                        onPlay: { c in
                            currentChannel = c
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

                if showAudioPanel {
                    settingsPanelOverlay {
                        SettingsList(
                            items: playerManager.availableAudioTracks,
                            selectedItem: playerManager.currentAudioTrack,
                            title: "Audio",
                            onSelect: { track in playerManager.selectAudioTrack(track) },
                            itemLabel: { $0.name }
                        )
                    } onClose: { showAudioPanel = false }
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
        }
        // Apple-like dismiss transform applied to the whole view:
        //   • finger-tracked vertical translation
        //   • subtle scale-down for depth
        //   • corner radius growth so it feels like a card being pulled away
        // The fullScreenCover's own slide-down handles the final removal once
        // we set selectedChannel = nil.
        .modifier(PlayerDismissTransform(drag: dismissDrag))
        .ignoresSafeArea()
        .statusBar(hidden: true)
        .preferredColorScheme(.dark)
        .tint(.white)
        .defersSystemGesturesIfAvailable()
        .simultaneousGesture(playerSwipeGesture)
        .onAppear {
            // Unlock landscape so the player can rotate while watching.
            PlayerOrientationManager.shared.enableLandscape("player")

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

            // Re-lock to portrait now that the player is gone.
            PlayerOrientationManager.shared.disableLandscape("player")
            lockToPortrait()

            if scenePhase == .active && viewModel?.miniPlayerChannel == nil && viewModel?.triggerMultiView != true {
                playerManager.stop()
            }
            timer?.cancel()
        }
        .onAppear {
            if currentChannel == nil {
                currentChannel = channel
            }
        }
        .onChangeCompat(of: channel) { newChannel in
            // If parent updates the channel prop, sync currentChannel
            currentChannel = newChannel
        }
        .onChangeCompat(of: currentChannel) { _ in
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
    
    // MARK: - Layouts

    /// Original full-bleed layout: video fills the screen, controls overlay it.
    /// Used in landscape orientation, and in portrait when the user expands to fullscreen.
    @ViewBuilder
    private var fullscreenLayout: some View {
        UnifiedPlayerViewBridge()
            .applyIf(namespace != nil) { $0.matchedGeometryEffect(id: "videoPlayer", in: namespace!) }
            .ignoresSafeArea()
            .persistentSystemOverlays(.hidden)

        PlayerControlsView(
            playerManager: playerManager,
            channel: currentChannel ?? channel,
            viewModel: viewModel,
            isRecordingPlayback: isRecordingPlayback,
            isInlineMode: false,
            isFullscreenInPortrait: $isFullscreenInPortrait,
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
            seekForward: { playerManager.seek(to: min(playerManager.duration, playerManager.currentTime + 10)); resetTimer() },
            seekBackward: { playerManager.seek(to: max(0, playerManager.currentTime - 10)); resetTimer() }
        )

        // Portrait fullscreen puts the close/AirPlay/Mini/Multi-view/expand row
        // at ~60pt, so the score still sits below it there. LANDSCAPE now shares
        // the row's band: the buttons start at 20pt (see PlayerControlsView) and
        // the badge is centred in a 44pt box from the same offset, so the two
        // line up across the top instead of the score hanging underneath.
        liveScoreOverlay(topInset: isFullscreenInPortrait ? 120 : 20,
                         matchesButtonRow: !isFullscreenInPortrait)
    }

    /// Wrapper for fullscreen layout with buffering spinner properly positioned
    @ViewBuilder
    private var fullscreenLayoutWithBuffering: some View {
        ZStack {
            fullscreenLayout

            if playerManager.isBuffering && !playerManager.isPlaying && !playerManager.userPaused {
                CustomSpinner(color: .white, lineWidth: 5, size: 50)
                    .frame(width: 82, height: 82)
                    .modifier(GlassEffect(cornerRadius: 42, isSelected: true, accentColor: nil))
                    .allowsHitTesting(false)
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            }
        }
    }

    /// Wrapper for split layout with buffering spinner positioned at video center
    @ViewBuilder
    private func splitLayoutWithBuffering(geo: GeometryProxy) -> some View {
        let videoWidth = geo.size.width
        let videoHeight = videoWidth * 9.0 / 16.0

        ZStack {
            splitLayout(geo: geo)

            // Buffering spinner positioned at the center of the video area in portrait split mode
            if playerManager.isBuffering && !playerManager.isPlaying && !playerManager.userPaused {
                VStack {
                    let topInset = max(geo.safeAreaInsets.top + 12, 60)
                    Spacer()
                        .frame(height: topInset + videoHeight / 2 - 41) // Center in video area

                    CustomSpinner(color: .white, lineWidth: 5, size: 50)
                        .frame(width: 82, height: 82)
                        .modifier(GlassEffect(cornerRadius: 42, isSelected: true, accentColor: nil))
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(.easeInOut(duration: 0.3)))

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Live ESPN score badge — only shown when `ScoreViewModel.liveGame(for:)` finds a match.
    /// In portrait bottom mode, always shown. In fullscreen/landscape, only shown when controls are visible.
    @ViewBuilder
    private func liveScoreOverlay(topInset: CGFloat,
                                  isPortraitBottom: Bool = false,
                                  matchesButtonRow: Bool = false) -> some View {
        let shouldShow = isPortraitBottom ? true : showControls

        if shouldShow,
           let svm = scoreViewModel,
           let game = svm.liveGame(for: currentChannel ?? channel, currentEPGTitle: viewModel?.getCurrentProgram(for: currentChannel ?? channel)?.title) {
            if isPortraitBottom {
                // Bottom position for portrait split mode — always visible
                VStack {
                    LiveScoreBadge(game: game)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.3))
                .allowsHitTesting(false)
                .transition(.opacity)
            } else {
                // Top position for landscape/fullscreen — shown when controls visible
                VStack {
                    LiveScoreBadge(game: game)
                        // 44pt is the button row's own height, so centring in it
                        // puts the badge on the buttons' centre line without
                        // either having to know the other's size.
                        .applyIf(matchesButtonRow) { $0.frame(height: 44) }
                        .padding(.top, topInset)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }

    /// Portrait split layout: video at top in 16:9, info panel below.
    @ViewBuilder
    private func splitLayout(geo: GeometryProxy) -> some View {
        let videoWidth = geo.size.width
        let videoHeight = videoWidth * 9.0 / 16.0
        let topInset = max(geo.safeAreaInsets.top + 12, 60) // Account for dynamic island with extra padding

        VStack(spacing: 0) {
            // Spacer to push the video below the dynamic island
            Color.black
                .frame(height: topInset)

            // Video region — same controls overlay, but in inline mode (no bottom row of pills)
            ZStack {
                Color.black
                UnifiedPlayerViewBridge()
                    .applyIf(namespace != nil) { $0.matchedGeometryEffect(id: "videoPlayer", in: namespace!) }
                    .frame(width: videoWidth, height: videoHeight)
                    .clipped()

                PlayerControlsView(
                    playerManager: playerManager,
                    channel: currentChannel ?? channel,
                    viewModel: viewModel,
                    isRecordingPlayback: isRecordingPlayback,
                    isInlineMode: true,
                    isFullscreenInPortrait: $isFullscreenInPortrait,
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
                    seekForward: { playerManager.seek(to: min(playerManager.duration, playerManager.currentTime + 10)); resetTimer() },
                    seekBackward: { playerManager.seek(to: max(0, playerManager.currentTime - 10)); resetTimer() }
                )
            }
            .frame(width: videoWidth, height: videoHeight)

            // Live score badge at bottom of video in portrait split mode
            liveScoreOverlay(topInset: 0, isPortraitBottom: true)

            // Info panel below the video.
            // For recording playback, infoChannel carries the real live channel so
            // EPG schedule, channels, and recordings show meaningful content.
            if let vm = viewModel {
                PlayerInfoPanel(
                    channel: infoChannel ?? currentChannel ?? channel,
                    onPlayChannel: onPlayChannel,
                    onPlayRecording: onPlayRecording,
                    viewModel: vm,
                    playerManager: playerManager,
                    isRecordingPlayback: isRecordingPlayback,
                    showSubtitlePanel: $showSubtitlePanel,
                    showAudioPanel: $showAudioPanel
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.black
            }
        }
    }

    // MARK: - Player swipe gesture

    /// Drag gesture for swipe-down (mini-player), swipe-up (quick switcher), swipe-left/right (channel switch).
    /// In portrait split mode, only swipe-down from video area is allowed to minimize.
    private var playerSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { val in
                if showQuickSwitcher { return }
                if val.startLocation.y < 60 { return }
                // Don't interfere with system home gesture at bottom
                let screenHeight = UIScreen.main.bounds.height
                if val.startLocation.y > screenHeight - 50 { return }

                // In portrait split mode, only process swipes from video area (not info panel)
                let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
                if isPortraitSplitMode && !isLandscape {
                    let videoAreaHeight = UIScreen.main.bounds.width * 9.0 / 16.0 + max(60 + 12, 60)
                    if val.startLocation.y > videoAreaHeight { return }
                    // Only allow downward swipes in portrait split
                    if val.translation.height <= 0 { return }
                }

                if val.translation.height > 0 && abs(val.translation.height) > abs(val.translation.width) {
                    // Track the drag 1:1 — writes only invalidate the
                    // transform modifier, never this whole view.
                    dismissDrag.set(val.translation.height)
                }
            }
            .onEnded { val in
                if showQuickSwitcher { return }
                if val.startLocation.y < 60 { return }
                // Don't interfere with system home gesture at bottom
                let screenHeight = UIScreen.main.bounds.height
                if val.startLocation.y > screenHeight - 50 { return }

                // In portrait split mode, only process swipes from video area
                let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
                if isPortraitSplitMode && !isLandscape {
                    let videoAreaHeight = UIScreen.main.bounds.width * 9.0 / 16.0 + max(60 + 12, 60)
                    if val.startLocation.y > videoAreaHeight { return }
                }

                // YouTube-style commit: trigger miniplayer if the user passed
                // the threshold OR flicked downward fast.
                let velocityY = val.predictedEndTranslation.height - val.translation.height
                let committed = (val.translation.height > 120 && abs(val.translation.height) > abs(val.translation.width))
                              || (velocityY > 200 && val.translation.height > 40)

                if committed {
                    // Apple-style hand-off:
                    //   1. Stage the miniplayer with a soft spring so it
                    //      animates into the corner from below.
                    //   2. Carry the card the REST of the way down ourselves,
                    //      continuing from wherever the finger let go, then
                    //      remove the (transparent) cover with animations
                    //      off. Letting the cover's own slide-down run after
                    //      an offset reset was the visible snap-glitch.
                    // Continue at the finger's release speed — a fixed-curve
                    // exit restarted from zero velocity, which read as
                    // fast → stop → fast on a hard flick. Linear over the
                    // REMAINING distance at the throw's own pace keeps one
                    // continuous motion.
                    viewModel?.triggerHaptic(.light)
                    let screenHeight = UIScreen.main.bounds.height
                    let remaining = max(0, screenHeight - max(0, val.translation.height))
                    let throwSpeed = max(val.velocity.height, 1400)
                    let duration = min(0.3, remaining / throwSpeed)
                    withAnimation(.linear(duration: duration)) {
                        dismissDrag.value = screenHeight
                    }
                    // Stage the miniplayer on the NEXT runloop turn: setting
                    // it re-renders the whole home screen, and doing that in
                    // the same frame that commits the exit animation delayed
                    // the commit — the one-frame stall visible at release.
                    // A beat later the rebuild happens while the card is
                    // already moving in the render server.
                    let vm = viewModel
                    let departingChannel = channel
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                            vm?.miniPlayerChannel = departingChannel
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.03) {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { onDismiss?() }
                    }
                } else if val.translation.height < -100 && abs(val.translation.height) > abs(val.translation.width) {
                    frozenRecentIDs = viewModel?.recentIDs ?? []
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showQuickSwitcher = true
                        quickSwitcherOffset = 0
                        showControls = true
                        timer?.cancel()
                    }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { dismissDrag.value = 0 }
                } else if val.translation.width < -50 && abs(val.translation.width) > abs(val.translation.height) {
                    switchChannel(offset: 1)
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { dismissDrag.value = 0 }
                } else if val.translation.width > 50 && abs(val.translation.width) > abs(val.translation.height) {
                    switchChannel(offset: -1)
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { dismissDrag.value = 0 }
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { dismissDrag.value = 0 }
                }
            }
    }

    /// Tracks portrait-split mode so the player swipe gesture can be disabled
    /// (the info panel ScrollView needs the touches).
    private var isPortraitSplitMode: Bool {
        let bounds = UIScreen.main.bounds
        let isLandscape = bounds.width > bounds.height
        return !isLandscape && !isFullscreenInPortrait
    }

    func updateMetadata() {
        let activeChannel = currentChannel ?? channel

        // A live game gets the game's own card: the matchup as the title and
        // the Live Now graphic as the artwork, rather than the programme name
        // over the channel's logo.
        if let svm = scoreViewModel,
           let game = svm.liveGame(for: activeChannel,
                                   currentEPGTitle: viewModel?.getCurrentProgram(for: activeChannel)?.title) {
            let title = Self.nowPlayingTitle(for: game)
            // Title first so the lock screen is never empty, then the artwork
            // once its crests have loaded.
            playerManager.updateNowPlayingMetadata(title: title,
                                                   subtitle: activeChannel.name,
                                                   imageURL: nil)
            Task { @MainActor in
                guard let art = await Self.liveArtwork(for: game) else { return }
                playerManager.updateNowPlayingMetadata(title: title,
                                                       subtitle: activeChannel.name,
                                                       imageURL: nil,
                                                       artworkImage: art)
            }
            return
        }

        let prog = viewModel?.getCurrentProgram(for: activeChannel)?.title
        if let p = prog, !p.isEmpty {
            playerManager.updateNowPlayingMetadata(title: p, subtitle: activeChannel.name, imageURL: activeChannel.icon)
        } else {
            playerManager.updateNowPlayingMetadata(title: activeChannel.name, subtitle: nil, imageURL: activeChannel.icon)
        }
    }

    /// What a live event is called on the lock screen.
    ///
    /// A race weekend and a golf tournament have no two sides to name, so those
    /// carry the event itself — the same reasoning the scorelines and the
    /// stream search use.
    static func nowPlayingTitle(for game: ESPNEvent) -> String {
        if game.isRaceEvent || game.isFieldEvent { return game.shortName }
        // shortDisplayName is the NAME — "Lakers", "Arsenal" — where
        // displayName carries the city with it ("Los Angeles Lakers"). The feed
        // gives no separate nickname field, so the abbreviation stands in ahead
        // of the long form rather than falling back to the place.
        func name(_ competitor: ESPNCompetitor?) -> String? {
            let team = competitor?.team
            if let short = team?.shortDisplayName, !short.isEmpty { return short }
            if let abbreviation = team?.abbreviation, !abbreviation.isEmpty { return abbreviation }
            return team?.displayName
        }
        guard let away = name(game.awayCompetitor), let home = name(game.homeCompetitor),
              !away.isEmpty, !home.isEmpty else { return game.shortName }
        return "\(away) vs \(home)"
    }

    /// The matchup art, drawn to an image for the lock screen.
    ///
    /// ASYNC, because the crests have to be in hand before the render: an
    /// `ImageRenderer` draws in one synchronous pass, so a view that loads its
    /// own images would be rendered with none of them. Fetching them first —
    /// memory, then disk, then network, all off the main thread — is what makes
    /// the logos actually appear.
    static func liveArtwork(for game: ESPNEvent) async -> UIImage? {
        if let cached = await MainActor.run(body: { artworkCache[game.id] }) { return cached }

        func crest(_ competitor: ESPNCompetitor?) async -> UIImage? {
            let url = competitor?.team?.logo
                ?? competitor?.athlete?.flag?.href
                ?? competitor?.athlete?.headshot
            guard let url, !url.isEmpty else { return nil }
            return await ImageCache.shared.image(forKey: url, size: CGSize(width: 190, height: 190))
        }

        let away = await crest(game.awayCompetitor)
        let home = await crest(game.homeCompetitor)

        return await MainActor.run {
            let renderer = ImageRenderer(
                content: NowPlayingMatchupArt(game: game, awayCrest: away, homeCrest: home)
                    .frame(width: 600, height: 600)
            )
            renderer.scale = UIScreen.main.scale
            guard let image = renderer.uiImage else { return nil }
            // Only kept once both crests were there to draw; otherwise a card
            // rendered a moment too early would be the one held all session.
            if away != nil && home != nil {
                if artworkCache.count > 24 { artworkCache.removeAll() }
                artworkCache[game.id] = image
            }
            return image
        }
    }

    @MainActor private static var artworkCache: [String: UIImage] = [:]
    
    
    
    @ViewBuilder
    private func settingsPanelOverlay<Content: View>(@ViewBuilder content: () -> Content, onClose: @escaping () -> Void) -> some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture {
                withAnimation { onClose() }
                resetTimer()
            }
            content()
                .frame(width: 300)
                .modifier(GlassEffect(cornerRadius: 24, isSelected: false, accentColor: nil))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
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
        let activeChannel = currentChannel ?? channel
        guard let idx = allChannels.firstIndex(where: { $0.id == activeChannel.id }) else { return }
        var nextIdx = idx + offset
        if nextIdx < 0 { nextIdx = allChannels.count - 1 }
        if nextIdx >= allChannels.count { nextIdx = 0 }
        if allChannels.indices.contains(nextIdx) {
            currentChannel = allChannels[nextIdx]
            onPlayChannel?(allChannels[nextIdx])
            resetTimer()
        }
    }
    
    func dismissAnimate() {
        // Close the player completely
        onDismiss?()
    }

    /// Forces the device back to portrait after the player is dismissed.
    private func lockToPortrait() {
        if #available(iOS 16.0, *) {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .forEach { $0.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
        } else {
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
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
        let activeChannel = currentChannel ?? channel
        Task {

            // Skip active-recording redirect when already in recording-playback mode
            // (avoids an infinite loop where playing a completed .ts file would be
            //  redirected back to the still-running live recorder for that channel).
            if !isRecordingPlayback,
               let localURL = RecordingManager.shared.getActiveRecordingURL(for: activeChannel) {
                print("⏺️ [Player] Playing from active recording file: \(localURL.lastPathComponent)")
                await MainActor.run {
                    self.currentStreamURL = localURL

                    playerManager.play(url: localURL)

                    let prog = viewModel?.getCurrentProgram(for: activeChannel)?.title
                    if let p = prog, !p.isEmpty {
                        playerManager.updateNowPlayingMetadata(title: p, subtitle: activeChannel.name, imageURL: activeChannel.icon)
                    } else {
                        playerManager.updateNowPlayingMetadata(title: activeChannel.name, subtitle: nil, imageURL: activeChannel.icon)
                    }
                }
                return
            }

            let resolvedURLString = activeChannel.streamURL
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



                let prog = viewModel?.getCurrentProgram(for: activeChannel)?.title
                if let p = prog, !p.isEmpty {
                    playerManager.updateNowPlayingMetadata(title: p, subtitle: activeChannel.name, imageURL: activeChannel.icon)
                } else {
                    playerManager.updateNowPlayingMetadata(title: activeChannel.name, subtitle: nil, imageURL: activeChannel.icon)
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

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 40, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 10)

            HStack {
                Menu {
                    Picker("Category", selection: $switcherCategory) {
                        Section {
                            Label("Recently Watched", systemImage: "clock")
                                .tag(StreamCategory(id: -2, name: "Recently Watched"))
                            Label("Favorites", systemImage: "star.fill")
                                .tag(StreamCategory(id: -4, name: "Favorites"))
                        }
                        if !categories.isEmpty {
                            Section {
                                ForEach(categories.filter { !$0.isHidden }) { cat in
                                    Text(cat.name).tag(cat)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(switcherCategory.name).font(.headline).fontWeight(.bold)
                        Image(systemName: "chevron.up.chevron.down").font(.caption.bold())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .modifier(GlassEffect(cornerRadius: 20, isSelected: true, accentColor: nil))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .onChangeCompat(of: switcherCategory) { _ in
                    ChannelViewModel.shared.triggerSelectionHaptic()
                }

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
        .modifier(GlassEffect(cornerRadius: 20, isSelected: false, accentColor: nil))
        .fixedSize(horizontal: false, vertical: true)
    }
}
/// The dismiss-drag transform, isolated so the per-frame drag writes
/// re-render only this modifier — the player content underneath is reused,
/// not rebuilt. Scale eases toward 0.94 for depth, and the corners round while
/// the card is pulled away, mirroring Apple's modal pull-away.
///
/// The corner radius is intentionally BINARY — off at rest, a fixed 18 the
/// instant a drag begins — rather than growing continuously with the drag.
/// A radius that changed every frame rebuilt the rounded-rect clip mask each
/// frame, and that mask is a full-screen offscreen composite over the LIVE
/// video surface: the single most expensive thing happening during the swipe,
/// and why it wasn't as smooth as the (pure-offset) game card. Held constant,
/// the mask is rasterised once and only the cheap offset + scale layer
/// transforms change while the finger moves. The pop from 0→18 is a single
/// frame at the very start of the drag and is imperceptible in motion.
private struct PlayerDismissTransform: ViewModifier {
    @ObservedObject var drag: ScrollProgress

    func body(content: Content) -> some View {
        let d = max(0, drag.value)
        let progress = min(d / 240, 1)
        content
            .scaleEffect(1.0 - progress * 0.06)
            .offset(y: d)
            .clipShape(RoundedRectangle(cornerRadius: d > 0.5 ? 18 : 0, style: .continuous))
    }
}
