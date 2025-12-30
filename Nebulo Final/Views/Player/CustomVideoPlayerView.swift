import SwiftUI
import AVKit
import Combine
import AVFoundation

struct CustomVideoPlayerView: View {
    let channel: StreamChannel; var viewModel: ChannelViewModel? = nil; var onDismiss: (() -> Void)? = nil; var onPlayChannel: ((StreamChannel) -> Void)? = nil
    @Binding var showQuickSwitcher: Bool
    
    @State private var player = AVPlayer(); @State private var isPlaying = true; @State private var showControls = true; @State private var offset: CGSize = .zero; @State private var timer: AnyCancellable?; @State private var pipAdapter: PipAdapter?; @State private var resolutionLabel: String = ""; @State private var sizeObserver: NSKeyValueObservation?; @State private var isAtLiveEdge = true; @State private var liveChecker: Timer?; @State private var showFullDescription = false; @State private var descriptionHeight: CGFloat = 0
    
    // Quick Switcher State
    @State private var quickSwitcherOffset: CGFloat = -200
    @State private var switcherCategory: StreamCategory = StreamCategory(id: -2, name: "Recently Watched")
    @State private var showCategoryPicker = false
    @State private var frozenRecentIDs: [Int] = []
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea(); PlayerViewRepresentable(player: player, pipAdapter: $pipAdapter).ignoresSafeArea(); Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { if showFullDescription { withAnimation { showFullDescription = false }; resetTimer() } else { toggleControls() } }
            ZStack {
                Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { if showFullDescription { withAnimation { showFullDescription = false }; resetTimer() } else { toggleControls() } }
                HStack(spacing: 50) {
                    Button(action: { seek(by: -10) }) { Image(systemName: "gobackward.10").font(.system(size: 35)).foregroundColor(.white) }
                    Button(action: { togglePlay() }) { Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 60)).foregroundColor(.white).shadow(radius: 10) }
                    Button(action: { seek(by: 10) }) { Image(systemName: "goforward.10").font(.system(size: 35)).foregroundColor(isAtLiveEdge ? .white.opacity(0.3) : .white) }.disabled(isAtLiveEdge)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).allowsHitTesting(true).opacity(showFullDescription ? 0 : 1)
                VStack {
                    HStack(alignment: .center) {
                        Button(action: { dismissAnimate() }) { Image(systemName: "xmark").font(.title3.bold()).foregroundColor(.white).padding(12).background(Material.ultraThinMaterial).clipShape(Circle()) }
                        
                        Button(action: {
                            frozenRecentIDs = viewModel?.recentIDs ?? []
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                showQuickSwitcher = true
                                quickSwitcherOffset = 0
                                showControls = false
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "list.bullet.indent")
                                Text("Channels")
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Material.ultraThinMaterial)
                            .clipShape(Capsule())
                        }
                        .padding(.leading, 8)
                        
                        Spacer()
                        if let vm = viewModel {
                            HStack(spacing: 12) {
                                Button(action: {
                                    vm.miniPlayerChannel = channel
                                    onDismiss?()
                                }) {
                                    Image(systemName: "rectangle.on.rectangle.angled.fill")
                                        .font(.title3)
                                        .foregroundColor(.white)
                                        .padding(12)
                                        .background(Material.ultraThinMaterial)
                                        .clipShape(Circle())
                                }
                                
                                Button(action: { vm.triggerMultiViewFromPlayer(with: channel) }) { Image(systemName: "square.grid.2x2.fill").font(.title3).foregroundColor(.white).padding(12).background(Material.ultraThinMaterial).clipShape(Circle()) }
                            }
                        }
                        AirPlayButton().frame(width: 44, height: 44)
                        if pipAdapter?.isPipPossible == true { Button(action: { if pipAdapter?.isPipActive == true { pipAdapter?.stopPip() } else { pipAdapter?.startPip() } }) { Image(systemName: pipAdapter?.isPipActive == true ? "pip.exit" : "pip.enter").font(.title3).foregroundColor(.white).padding(12).background(Material.ultraThinMaterial).clipShape(Circle()) } }
                    }.padding(.top, 70).padding(.horizontal, 20); Spacer()
                }.opacity(showFullDescription ? 0 : 1)
                VStack {
                    Spacer();
                    VStack(alignment: .leading, spacing: 8) {
                        Text(channel.name).font(.title3.bold()).foregroundColor(.white)
                                                    if let live = viewModel?.getCurrentProgram(for: channel) {
                                                        Text(live.title).font(.subheadline.bold()).foregroundColor(.white.opacity(0.9))
                                                                                    if let desc = live.description, !desc.isEmpty {
                                                                                        ZStack(alignment: .topLeading) {
                                                                                            // Expanded State
                                                                                            ScrollView(showsIndicators: false) {
                                                                                                Text(desc)
                                                                                                    .font(.system(size: 11))
                                                                                                    .foregroundColor(.white.opacity(0.6))
                                                                                                    .multilineTextAlignment(.leading)
                                                                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                                                                    .background(GeometryReader { gp in Color.clear.onAppear { descriptionHeight = gp.size.height }.onChangeCompat(of: gp.size.height) { val in descriptionHeight = val } })
                                                                                            }
                                                                                            .frame(height: showFullDescription ? min(descriptionHeight, 150) : 15)
                                                                                            .opacity(showFullDescription ? 1 : 0)
                                                                                            
                                                                                            // Collapsed State
                                                                                            Text(desc)
                                                                                                .font(.system(size: 11))
                                                                                                .foregroundColor(.white.opacity(0.6))
                                                                                                .lineLimit(1)
                                                                                                .multilineTextAlignment(.leading)
                                                                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                                                                .frame(height: 15)
                                                                                                .opacity(showFullDescription ? 0 : 1)
                                                                                        }
                                                                                        .onTapGesture { 
                                                                                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { 
                                                                                                showFullDescription.toggle()
                                                                                                if showFullDescription { timer?.cancel() } else { resetTimer() }
                                                                                            }
                                                                                        }
                                                                                    }
                                                        
                                                    }
                                                    HStack {
                                                        Button(action: { jumpToLive() }) { HStack(spacing: 6) { Circle().fill(isAtLiveEdge ? Color.red : Color.gray).frame(width: 8, height: 8); Text("LIVE").font(.caption.bold()).foregroundColor(isAtLiveEdge ? .white : .white.opacity(0.7)) }.padding(8).background(isAtLiveEdge ? Color.clear : Color.white.opacity(0.1)).cornerRadius(8) }.disabled(isAtLiveEdge)
                                                        Spacer(); if !resolutionLabel.isEmpty { Text(resolutionLabel).font(.caption2.bold()).foregroundColor(.white).padding(6).background(Color.black.opacity(0.5)).cornerRadius(4) }
                                                    }
                                                }
                                                .padding(20)
                                                .padding(.bottom, 40).padding(.horizontal, 20)
                                                .gesture(
                                                    DragGesture()
                                                        .onEnded { value in
                                                            if value.translation.height < -20 && !showFullDescription {
                                                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                                                    showFullDescription = true
                                                                    timer?.cancel()
                                                                }
                                                            } else if value.translation.height > 20 && showFullDescription {
                                                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                                                    showFullDescription = false
                                                                    resetTimer()
                                                                }
                                                            }
                                                        }
                                                )
                                            }
                        
            }
            .opacity(showControls ? 1 : 0)
            .allowsHitTesting(showControls)
            
            // QUICK SWITCHER OVERLAY
            if showQuickSwitcher {
                // Dimmed background to catch taps outside
                Color.black.opacity(0.01)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showQuickSwitcher = false
                        }
                    }
                
                VStack(spacing: 0) {
                    // Header
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
                                Text(switcherCategory.name)
                                    .font(.headline)
                                    .fontWeight(.bold)
                                Image(systemName: "chevron.down").font(.caption.bold())
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Material.ultraThinMaterial)
                            .clipShape(Capsule())
                        }
                        Spacer()
                    }
                    .padding(.top, 60) // Safe area
                    .padding(.horizontal)
                    .padding(.bottom, 10)
                    
                    // Channel List
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            let channels = getChannelsForSwitcher()
                            ForEach(channels) { c in
                                Button(action: {
                                    onPlayChannel?(c)
                                }) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        CachedAsyncImage(urlString: c.icon ?? "", size: CGSize(width: 140, height: 80))
                                            .frame(width: 140, height: 80)
                                            .background(Color.black.opacity(0.3))
                                            .cornerRadius(8)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(c.id == channel.id ? Color.white : Color.clear, lineWidth: 2)
                                            )
                                        
                                        Text(c.name)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                            .frame(width: 140, alignment: .leading)
                                        
                                        if let prog = viewModel?.getCurrentProgram(for: c) {
                                            Text(prog.title)
                                                .font(.caption2)
                                                .foregroundColor(.white.opacity(0.7))
                                                .lineLimit(1)
                                                .frame(width: 140, alignment: .leading)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 20)
                    
                    // Pull Handle Indicator
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 40, height: 5)
                        .padding(.bottom, 10)
                }
                .background(
                    LinearGradient(colors: [Color.black.opacity(0.9), Color.black.opacity(0.8), Color.clear], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                )
                .frame(maxHeight: .infinity, alignment: .top) // Force top alignment
                .offset(y: quickSwitcherOffset)
                .transition(.move(edge: .top))
                .gesture(
                    DragGesture()
                        .onChanged { val in
                            // Allow pushing back up
                            if val.translation.height < 0 {
                                quickSwitcherOffset = max(-200, val.translation.height)
                            }
                        }
                        .onEnded { val in
                            if val.translation.height < -50 {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    showQuickSwitcher = false
                                }
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    quickSwitcherOffset = 0
                                }
                            }
                        }
                )
            }

        }.offset(y: offset.height).gesture(DragGesture().onChanged { 
            if $0.translation.height > 0 && !showQuickSwitcher { 
                // Normal dismiss logic
                offset = $0.translation 
            }
        }.onEnded { 
            if showQuickSwitcher { return } 
            if $0.translation.height > 100 { dismissAnimate() } else { withAnimation { offset = .zero } } 
        })
        .onAppear { 
            setupPlayer(); resetTimer(); startLiveEdgeChecker()
            if showQuickSwitcher { 
                frozenRecentIDs = viewModel?.recentIDs ?? []
                quickSwitcherOffset = 0; showControls = false 
            }
        }.onDisappear { player.pause(); timer?.cancel(); liveChecker?.invalidate(); pipAdapter = nil }
        .onChangeCompat(of: channel) { _ in setupPlayer() }
        .onChangeCompat(of: showQuickSwitcher) { isOpen in
            if isOpen { 
                frozenRecentIDs = viewModel?.recentIDs ?? [] 
            } else {
                quickSwitcherOffset = -200
            }
        }
    }
    
    func getChannelsForSwitcher() -> [StreamChannel] {
        guard let vm = viewModel else { return [] }
        if switcherCategory.id == -2 { 
            let ids = frozenRecentIDs.isEmpty ? vm.recentIDs : frozenRecentIDs
            return ids.compactMap { id in vm.channels.first(where: { $0.id == id }) } 
        }
        if switcherCategory.id == -4 { return vm.channels.filter { vm.favoriteIDs.contains($0.id) } }
        if switcherCategory.id == -1 { return vm.channels.filter { !vm.hiddenIDs.contains($0.id) } }
        return vm.channels.filter { $0.categoryID == switcherCategory.id && !vm.hiddenIDs.contains($0.id) }
    }

    func dismissAnimate() { withAnimation(.easeInOut(duration: 0.35)) { offset = CGSize(width: 0, height: UIScreen.main.bounds.height) }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onDismiss?() } }
    func seek(by s: Double) { guard let c = player.currentItem else { return }; let next = c.currentTime().seconds + s; player.seek(to: CMTime(seconds: next, preferredTimescale: 600)); resetTimer() }
    func jumpToLive() { guard let c = player.currentItem, let r = c.seekableTimeRanges.last?.timeRangeValue else { return }; player.seek(to: r.end); player.play(); isPlaying = true; isAtLiveEdge = true; resetTimer() }
    func startLiveEdgeChecker() { liveChecker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in guard let c = player.currentItem, let r = c.seekableTimeRanges.last?.timeRangeValue else { return }; let isL = (r.end.seconds - c.currentTime().seconds) < 4.0; if isL != self.isAtLiveEdge { withAnimation { self.isAtLiveEdge = isL } } } }
    func togglePlay() { if isPlaying { player.pause() } else { player.play() }; isPlaying.toggle(); resetTimer() }
    func toggleControls() { withAnimation(.easeInOut(duration: 0.15)) { if showControls { showControls = false; timer?.cancel() } else { showControls = true; resetTimer() } } }
    func setupPlayer() {
        pipAdapter?.stopPip()
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback); try AVAudioSession.sharedInstance().setActive(true) } catch {}
        guard let url = URL(string: channel.streamURL) else { return }
        let h: [String: Any] = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": h]); let item = AVPlayerItem(asset: asset); item.preferredForwardBufferDuration = 0; item.automaticallyPreservesTimeOffsetFromLive = true; item.canUseNetworkResourcesForLiveStreamingWhilePaused = true; player.replaceCurrentItem(with: item); player.allowsExternalPlayback = true
        if #available(iOS 15.0, *) {
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        }
        player.automaticallyWaitsToMinimizeStalling = true; player.play()
        sizeObserver = item.observe(\.presentationSize, options: [.new]) { _, ch in guard let sz = ch.newValue, sz != .zero else { return }; DispatchQueue.main.async { if sz.height >= 2160 { resolutionLabel = "4K" } else if sz.height >= 1080 { resolutionLabel = "1080p" } else if sz.height >= 720 { resolutionLabel = "720p" } else if sz.height > 0 { resolutionLabel = "SD" } } }
    }
    func resetTimer() { timer?.cancel(); timer = Just(()).delay(for: 3.5, scheduler: RunLoop.main).sink { _ in withAnimation(.easeInOut(duration: 0.15)) { showControls = false } } }
}

class PipAdapter: NSObject, AVPictureInPictureControllerDelegate, ObservableObject { private var pipController: AVPictureInPictureController?; @Published var isPipPossible = false; @Published var isPipActive = false; func setup(layer: AVPlayerLayer) { if AVPictureInPictureController.isPictureInPictureSupported() { pipController = AVPictureInPictureController(playerLayer: layer); pipController?.delegate = self; if #available(iOS 14.2, *) { pipController?.canStartPictureInPictureAutomaticallyFromInline = false }; pipController?.addObserver(self, forKeyPath: "isPictureInPicturePossible", options: [.new, .initial], context: nil) } }; func startPip() { pipController?.startPictureInPicture() }; func stopPip() { pipController?.stopPictureInPicture() }; override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) { if keyPath == "isPictureInPicturePossible" { DispatchQueue.main.async { self.isPipPossible = self.pipController?.isPictureInPicturePossible ?? false } } }; func pictureInPictureControllerDidStartPictureInPicture(_ pc: AVPictureInPictureController) { DispatchQueue.main.async { self.isPipActive = true } }; func pictureInPictureControllerDidStopPictureInPicture(_ pc: AVPictureInPictureController) { DispatchQueue.main.async { self.isPipActive = false } } }
struct PlayerViewRepresentable: UIViewRepresentable { let player: AVPlayer; @Binding var pipAdapter: PipAdapter?; func makeUIView(context: Context) -> PlayerUIView { let v = PlayerUIView(); v.playerLayer.player = player; v.playerLayer.videoGravity = .resizeAspect; let a = PipAdapter(); a.setup(layer: v.playerLayer); DispatchQueue.main.async { self.pipAdapter = a }; return v }; func updateUIView(_ ui: PlayerUIView, context: Context) {} }
class PlayerUIView: UIView { override class var layerClass: AnyClass { AVPlayerLayer.self }; var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer } }
struct AirPlayButton: UIViewRepresentable { func makeUIView(context: Context) -> AVRoutePickerView { let v = AVRoutePickerView(); v.activeTintColor = .white; v.tintColor = .white; v.backgroundColor = .clear; v.prioritizesVideoDevices = true; return v }; func updateUIView(_ ui: AVRoutePickerView, context: Context) {} }
