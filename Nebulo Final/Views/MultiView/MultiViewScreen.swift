import SwiftUI
import AVKit

// MARK: - MULTI VIEW
struct MultiViewScreen: View {
    @ObservedObject var viewModel: ChannelViewModel; @Binding var showMultiView: Bool; @State private var focusedIndex: Int = 0; @State private var showControls = true; @State private var controlTimer: Timer?; @State private var showSearchSheet = false; @State private var hasAppeared = false; @State private var isExiting = false
    var activeIndices: [Int] { viewModel.multiViewSlots.enumerated().compactMap { $0.element != nil ? $0.offset : nil } }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 2) {
                if activeIndices.count <= 1 { let target = activeIndices.first ?? 0; MultiViewSlot(channel: viewModel.multiViewSlots[target], isFocused: true, showControls: showControls, onTap: { toggleControls() }, onAdd: { showSearchSheet = true }, onRemove: { viewModel.updateMultiViewSlot(index: target, channel: nil) }) } else if activeIndices.count == 2 { ForEach(activeIndices, id: \.self) { i in MultiViewSlot(channel: viewModel.multiViewSlots[i], isFocused: focusedIndex == i, showControls: showControls, onTap: { focusedIndex = i; toggleControls() }, onAdd: { showSearchSheet = true }, onRemove: { viewModel.updateMultiViewSlot(index: i, channel: nil) }) } } else { HStack(spacing: 2) { slotView(0); slotView(1) }; HStack(spacing: 2) { slotView(2); slotView(3) } }
            }.opacity(isExiting ? 0 : (hasAppeared ? 1 : 0)).scaleEffect(isExiting ? 0.95 : (hasAppeared ? 1.0 : 0.98)).edgesIgnoringSafeArea(.all)
            VStack { HStack(alignment: .center) { Button(action: { handleDismiss() }) { Image(systemName: "xmark").font(.system(size: 20, weight: .bold)).foregroundColor(.white).padding(12).background(.ultraThinMaterial).clipShape(Circle()) }; Spacer(); if activeIndices.count < 4 { Button(action: { showSearchSheet = true }) { HStack { Image(systemName: "plus"); Text("Add Stream") }.font(.caption.bold()).foregroundColor(.white).padding(.horizontal, 16).padding(.vertical, 10).background(.ultraThinMaterial).cornerRadius(20) } }; Spacer(); Button(action: { withAnimation { viewModel.multiViewSlots = [nil, nil, nil, nil] } }) { Image(systemName: "trash").font(.system(size: 20, weight: .bold)).foregroundColor(.red).padding(12).background(.ultraThinMaterial).clipShape(Circle()) } }.padding(.top, 60).padding(.horizontal, 25).opacity(showControls && !isExiting ? 1 : 0); Spacer() }
        }.onTapGesture { toggleControls() }.onAppear { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers]); try? AVAudioSession.sharedInstance().setActive(true); withAnimation(.easeOut(duration: 0.4).delay(0.1)) { hasAppeared = true }; resetTimer() }.sheet(isPresented: $showSearchSheet) { MultiViewSearchSheet(viewModel: viewModel, onSelect: { c in viewModel.addToMultiView(c); showSearchSheet = false }) }.gesture(DragGesture().onEnded { v in if v.translation.height > 100 { handleDismiss() } })
    }
    private func handleDismiss() { withAnimation(.easeInOut(duration: 0.25)) { isExiting = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showMultiView = false } }
    func slotView(_ i: Int) -> some View { MultiViewSlot(channel: viewModel.multiViewSlots[i], isFocused: focusedIndex == i, showControls: showControls, onTap: { focusedIndex = i; toggleControls() }, onAdd: { showSearchSheet = true }, onRemove: { viewModel.updateMultiViewSlot(index: i, channel: nil) }) }
    func toggleControls() { guard !isExiting else { return }; withAnimation { showControls.toggle(); if showControls { resetTimer() } } }
    func resetTimer() { controlTimer?.invalidate(); controlTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in withAnimation { showControls = false } } }
}

struct MultiViewSearchSheet: View {
    @ObservedObject var viewModel: ChannelViewModel; var onSelect: (StreamChannel) -> Void; @State private var localSearchText = ""; @Environment(\.dismiss) var dismiss
    var body: some View { VStack(spacing: 0) { HStack { Text("Add Stream").font(.headline); Spacer(); Button("Done") { dismiss() }.fontWeight(.bold) }.padding(); HStack { Image(systemName: "magnifyingglass").foregroundColor(.gray); TextField("Search channels...", text: $localSearchText).textFieldStyle(.plain).submitLabel(.search); if !localSearchText.isEmpty { Button(action: { localSearchText = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(.gray) } } }.padding(10).background(Color.primary.opacity(0.05)).cornerRadius(10).padding(.horizontal).padding(.bottom, 10); List { let res = viewModel.channels.filter { localSearchText.isEmpty || $0.name.localizedCaseInsensitiveContains(localSearchText) }; ForEach(res.prefix(100)) { c in Button(action: { onSelect(c) }) { HStack(spacing: 12) { CachedAsyncImage(urlString: c.icon ?? "", size: CGSize(width: 35, height: 35)).frame(width: 35, height: 35).padding(2).cornerRadius(6); Text(c.name).font(.body).foregroundColor(.primary) } } } }.listStyle(.plain) }.presentationDetents([.medium, .large]) }
}

struct MultiViewSlot: View {
    let channel: StreamChannel?; let isFocused: Bool; let showControls: Bool; let onTap: () -> Void; let onAdd: () -> Void; let onRemove: () -> Void
    var body: some View { ZStack { Color.gray.opacity(0.15); if let c = channel { GridVideoPlayer(url: URL(string: c.streamURL)!, isMuted: !isFocused).allowsHitTesting(false); VStack { Spacer(); HStack { Button(action: onRemove) { Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.8)) }.padding(30); Spacer(); Image(systemName: isFocused ? "speaker.wave.2.fill" : "speaker.slash.fill").foregroundStyle(.white.opacity(isFocused ? 1 : 0.5)).font(.system(size: 26)).padding(30) } }.opacity(showControls ? 1 : 0).animation(.easeInOut(duration: 0.2), value: showControls) } else { Button(action: onAdd) { VStack { Image(systemName: "plus.circle").font(.largeTitle); Text("Add Channel").font(.caption) }.foregroundStyle(.white.opacity(0.5)) } } }.contentShape(Rectangle()).onTapGesture { onTap() }.clipShape(RoundedRectangle(cornerRadius: 24)) }
}

struct GridVideoPlayer: UIViewRepresentable {
    let url: URL; let isMuted: Bool
    
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        let player = AVPlayer()
        player.isMuted = isMuted
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        
        context.coordinator.player = player
        context.coordinator.setup(url: url)
        
        return view
    }
    
    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        context.coordinator.player?.isMuted = isMuted
        if context.coordinator.currentURL != url {
            context.coordinator.setup(url: url)
        } else {
            // Ensure playing if visible
            if context.coordinator.player?.rate == 0 {
                context.coordinator.player?.play()
            }
        }
    }
    
    class Coordinator: NSObject {
        var player: AVPlayer?
        var currentURL: URL?
        var itemObserver: NSKeyValueObservation?
        
        func setup(url: URL) {
            currentURL = url
            let h: [String: Any] = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"]
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": h])
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 0
            item.automaticallyPreservesTimeOffsetFromLive = true
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            
            player?.replaceCurrentItem(with: item)
            player?.automaticallyWaitsToMinimizeStalling = true
            
            // Observe status to force play when ready
            itemObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .readyToPlay {
                    self?.player?.play()
                    self?.player?.rate = 1.0
                }
            }
            player?.play()
        }
    }
}
