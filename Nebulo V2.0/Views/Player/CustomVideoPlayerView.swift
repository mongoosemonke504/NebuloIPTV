import SwiftUI
import AVKit
import Combine
import AVFoundation

struct CustomVideoPlayerView: View {
    let channel: StreamChannel; var viewModel: ChannelViewModel? = nil; var onDismiss: (() -> Void)? = nil
    @State private var player = AVPlayer(); @State private var isPlaying = true; @State private var showControls = true; @State private var offset: CGSize = .zero; @State private var timer: AnyCancellable?; @State private var pipAdapter: PipAdapter?; @State private var resolutionLabel: String = ""; @State private var sizeObserver: NSKeyValueObservation?; @State private var isAtLiveEdge = true; @State private var liveChecker: Timer?
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea(); PlayerViewRepresentable(player: player, pipAdapter: $pipAdapter).ignoresSafeArea(); Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { toggleControls() }
            if showControls {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { toggleControls() }
                    HStack(spacing: 50) {
                        Button(action: { seek(by: -10) }) { Image(systemName: "gobackward.10").font(.system(size: 35)).foregroundColor(.white) }
                        Button(action: { togglePlay() }) { Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 60)).foregroundColor(.white).shadow(radius: 10) }
                        Button(action: { seek(by: 10) }) { Image(systemName: "goforward.10").font(.system(size: 35)).foregroundColor(isAtLiveEdge ? .white.opacity(0.3) : .white) }.disabled(isAtLiveEdge)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).allowsHitTesting(true)
                    VStack {
                        HStack(alignment: .center) {
                            Button(action: { dismissAnimate() }) { Image(systemName: "xmark").font(.title3.bold()).foregroundColor(.white).padding(12).background(Material.ultraThinMaterial).clipShape(Circle()) }
                            Spacer()
                            if let vm = viewModel { Button(action: { vm.triggerMultiViewFromPlayer(with: channel) }) { Image(systemName: "square.grid.2x2.fill").font(.title3).foregroundColor(.white).padding(12).background(Material.ultraThinMaterial).clipShape(Circle()) } }
                            AirPlayButton().frame(width: 44, height: 44)
                            if pipAdapter?.isPipPossible == true { Button(action: { if pipAdapter?.isPipActive == true { pipAdapter?.stopPip() } else { pipAdapter?.startPip() } }) { Image(systemName: pipAdapter?.isPipActive == true ? "pip.exit" : "pip.enter").font(.title3).foregroundColor(.white).padding(12).background(Material.ultraThinMaterial).clipShape(Circle()) } }
                        }.padding(.top, 50).padding(.horizontal, 20); Spacer()
                    }
                    VStack {
                        Spacer();
                        VStack(alignment: .leading, spacing: 5) {
                            Text(channel.name).font(.title3.bold()).foregroundColor(.white)
                            if let live = viewModel?.getCurrentProgram(for: channel) { Text(live.title).font(.subheadline).foregroundColor(.white.opacity(0.8)) }
                            HStack {
                                Button(action: { jumpToLive() }) { HStack(spacing: 6) { Circle().fill(isAtLiveEdge ? Color.red : Color.gray).frame(width: 8, height: 8); Text("LIVE").font(.caption.bold()).foregroundColor(isAtLiveEdge ? .white : .white.opacity(0.7)) }.padding(8).background(isAtLiveEdge ? Color.clear : Color.white.opacity(0.1)).cornerRadius(8) }.disabled(isAtLiveEdge)
                                Spacer(); if !resolutionLabel.isEmpty { Text(resolutionLabel).font(.caption2.bold()).foregroundColor(.white).padding(6).background(Color.black.opacity(0.5)).cornerRadius(4) }
                            }
                        }.padding(.bottom, 40).padding(.horizontal, 20)
                    }
                }.transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }.offset(y: offset.height).gesture(DragGesture().onChanged { if $0.translation.height > 0 { offset = $0.translation } }.onEnded { if $0.translation.height > 100 { dismissAnimate() } else { withAnimation { offset = .zero } } }).onAppear { setupPlayer(); resetTimer(); startLiveEdgeChecker() }.onDisappear { player.pause(); timer?.cancel(); liveChecker?.invalidate(); pipAdapter = nil }
    }
    func dismissAnimate() { withAnimation(.easeInOut(duration: 0.35)) { offset = CGSize(width: 0, height: UIScreen.main.bounds.height) }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onDismiss?() } }
    func seek(by s: Double) { guard let c = player.currentItem else { return }; let next = c.currentTime().seconds + s; player.seek(to: CMTime(seconds: next, preferredTimescale: 600)); resetTimer() }
    func jumpToLive() { guard let c = player.currentItem, let r = c.seekableTimeRanges.last?.timeRangeValue else { return }; player.seek(to: r.end); player.play(); isPlaying = true; isAtLiveEdge = true; resetTimer() }
    func startLiveEdgeChecker() { liveChecker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in guard let c = player.currentItem, let r = c.seekableTimeRanges.last?.timeRangeValue else { return }; let isL = (r.end.seconds - c.currentTime().seconds) < 4.0; if isL != self.isAtLiveEdge { withAnimation { self.isAtLiveEdge = isL } } } }
    func togglePlay() { if isPlaying { player.pause() } else { player.play() }; isPlaying.toggle(); resetTimer() }
    func toggleControls() { withAnimation(.easeInOut(duration: 0.15)) { if showControls { showControls = false; timer?.cancel() } else { showControls = true; resetTimer() } } }
    func setupPlayer() {
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback); try AVAudioSession.sharedInstance().setActive(true) } catch {}
        guard let url = URL(string: channel.streamURL) else { return }
        let h: [String: Any] = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": h]); let item = AVPlayerItem(asset: asset); item.preferredForwardBufferDuration = 0; item.automaticallyPreservesTimeOffsetFromLive = true; item.canUseNetworkResourcesForLiveStreamingWhilePaused = true; player.replaceCurrentItem(with: item); player.allowsExternalPlayback = true; player.automaticallyWaitsToMinimizeStalling = true; player.play()
        sizeObserver = item.observe(\.presentationSize, options: [.new]) { _, ch in guard let sz = ch.newValue, sz != .zero else { return }; DispatchQueue.main.async { if sz.height >= 2160 { resolutionLabel = "4K" } else if sz.height >= 1080 { resolutionLabel = "1080p" } else if sz.height >= 720 { resolutionLabel = "720p" } else if sz.height > 0 { resolutionLabel = "SD" } } }
    }
    func resetTimer() { timer?.cancel(); timer = Just(()).delay(for: 3.5, scheduler: RunLoop.main).sink { _ in withAnimation { showControls = false } } }
}

class PipAdapter: NSObject, AVPictureInPictureControllerDelegate, ObservableObject { private var pipController: AVPictureInPictureController?; @Published var isPipPossible = false; @Published var isPipActive = false; func setup(layer: AVPlayerLayer) { if AVPictureInPictureController.isPictureInPictureSupported() { pipController = AVPictureInPictureController(playerLayer: layer); pipController?.delegate = self; if #available(iOS 14.2, *) { pipController?.canStartPictureInPictureAutomaticallyFromInline = true }; pipController?.addObserver(self, forKeyPath: "isPictureInPicturePossible", options: [.new, .initial], context: nil) } }; func startPip() { pipController?.startPictureInPicture() }; func stopPip() { pipController?.stopPictureInPicture() }; override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) { if keyPath == "isPictureInPicturePossible" { DispatchQueue.main.async { self.isPipPossible = self.pipController?.isPictureInPicturePossible ?? false } } }; func pictureInPictureControllerDidStartPictureInPicture(_ pc: AVPictureInPictureController) { DispatchQueue.main.async { self.isPipActive = true } }; func pictureInPictureControllerDidStopPictureInPicture(_ pc: AVPictureInPictureController) { DispatchQueue.main.async { self.isPipActive = false } } }
struct PlayerViewRepresentable: UIViewRepresentable { let player: AVPlayer; @Binding var pipAdapter: PipAdapter?; func makeUIView(context: Context) -> PlayerUIView { let v = PlayerUIView(); v.playerLayer.player = player; v.playerLayer.videoGravity = .resizeAspect; let a = PipAdapter(); a.setup(layer: v.playerLayer); DispatchQueue.main.async { self.pipAdapter = a }; return v }; func updateUIView(_ ui: PlayerUIView, context: Context) {} }
class PlayerUIView: UIView { override class var layerClass: AnyClass { AVPlayerLayer.self }; var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer } }
struct AirPlayButton: UIViewRepresentable { func makeUIView(context: Context) -> AVRoutePickerView { let v = AVRoutePickerView(); v.activeTintColor = .white; v.tintColor = .white; v.backgroundColor = .clear; v.prioritizesVideoDevices = true; return v }; func updateUIView(_ ui: AVRoutePickerView, context: Context) {} }
