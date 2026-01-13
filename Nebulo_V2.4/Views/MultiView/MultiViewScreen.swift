import SwiftUI
import KSPlayer

// MARK: - MULTI VIEW
struct MultiViewScreen: View {
    @ObservedObject var viewModel: ChannelViewModel; @Binding var showMultiView: Bool; @State private var focusedIndex: Int = 0; @State private var showControls = true; @State private var controlTimer: Timer?; @State private var showSearchSheet = false; @State private var hasAppeared = false; @State private var isExiting = false
    var activeIndices: [Int] { viewModel.multiViewSlots.enumerated().compactMap { $0.element != nil ? $0.offset : nil } }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                ForEach(0..<4) { i in
                    let rect = getRect(for: i, size: geo.size)
                    let visible = shouldShow(index: i)
                    MultiViewSlot(channel: viewModel.multiViewSlots[i], isFocused: focusedIndex == i, showControls: showControls, onTap: { focusedIndex = i; toggleControls() }, onAdd: { showSearchSheet = true }, onRemove: { viewModel.updateMultiViewSlot(index: i, channel: nil) })
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(visible ? 1 : 0)
                        .allowsHitTesting(visible)
                        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: rect)
                }
            }
            .opacity(isExiting ? 0 : (hasAppeared ? 1 : 0)).scaleEffect(isExiting ? 0.95 : (hasAppeared ? 1.0 : 0.98))
            VStack { HStack(alignment: .center) { Button(action: { handleDismiss() }) { Image(systemName: "xmark").font(.system(size: 20, weight: .bold)).foregroundColor(.white).padding(12).background(.ultraThinMaterial).clipShape(Circle()) }; Spacer(); if activeIndices.count < 4 { Button(action: { showSearchSheet = true }) { HStack { Image(systemName: "plus"); Text("Add Stream") }.font(.caption.bold()).foregroundColor(.white).padding(.horizontal, 16).padding(.vertical, 10).background(.ultraThinMaterial).cornerRadius(20) } }; Spacer(); Button(action: { withAnimation { viewModel.multiViewSlots = [nil, nil, nil, nil] } }) { Image(systemName: "trash").font(.system(size: 20, weight: .bold)).foregroundColor(.red).padding(12).background(.ultraThinMaterial).clipShape(Circle()) } }.padding(.top, 60).padding(.horizontal, 25).opacity(showControls && !isExiting ? 1 : 0); Spacer() }
        }.onTapGesture { toggleControls() }.onAppear { withAnimation(.easeOut(duration: 0.4).delay(0.1)) { hasAppeared = true }; resetTimer() }.sheet(isPresented: $showSearchSheet) { MultiViewSearchSheet(viewModel: viewModel, onSelect: { c in viewModel.addToMultiView(c); showSearchSheet = false }) }.gesture(DragGesture().onEnded { v in if v.translation.height > 100 { handleDismiss() } })
    }
    func getRect(for index: Int, size: CGSize) -> CGRect {
        let indices = activeIndices, count = indices.count, w = size.width, h = size.height
        if count == 0 { return index == 0 ? CGRect(x: 0, y: 0, width: w, height: h) : CGRect(x: w/2, y: h/2, width: 0, height: 0) }
        if count == 1 { return indices.contains(index) ? CGRect(x: 0, y: 0, width: w, height: h) : CGRect(x: w/2, y: h/2, width: 0, height: 0) }
        if count == 2 { if indices.contains(index) { let isFirst = indices.first == index; return CGRect(x: 0, y: isFirst ? 0 : h/2, width: w, height: h/2) }; return CGRect(x: w/2, y: h/2, width: 0, height: 0) }
        let halfW = w / 2, halfH = h / 2, row = CGFloat(index / 2), col = CGFloat(index % 2)
        return CGRect(x: col * halfW, y: row * halfH, width: halfW, height: halfH)
    }
    func shouldShow(index: Int) -> Bool { let indices = activeIndices, count = indices.count; if count == 0 { return index == 0 }; if count <= 2 { return indices.contains(index) }; return true }
    private func handleDismiss() { withAnimation(.easeInOut(duration: 0.25)) { isExiting = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showMultiView = false } }
    func toggleControls() { guard !isExiting else { return }; withAnimation { showControls.toggle(); if showControls { resetTimer() } } }
    func resetTimer() { controlTimer?.invalidate(); controlTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in withAnimation { showControls = false } } }
}

struct MultiViewSearchSheet: View {
    @ObservedObject var viewModel: ChannelViewModel; var onSelect: (StreamChannel) -> Void; @State private var localSearchText = ""; @Environment(\.dismiss) var dismiss
    var body: some View { VStack(spacing: 0) { HStack { Text("Add Stream").font(.headline); Spacer(); Button("Done") { dismiss() }.fontWeight(.bold) }.padding(); HStack { Image(systemName: "magnifyingglass").foregroundColor(.gray); TextField("Search channels...", text: $localSearchText).textFieldStyle(.plain).submitLabel(.search); if !localSearchText.isEmpty { Button(action: { localSearchText = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(.gray) } } }.padding(10).background(Color.primary.opacity(0.05)).cornerRadius(10).padding(.horizontal).padding(.bottom, 10); List { let res = viewModel.channels.filter { localSearchText.isEmpty || $0.name.localizedCaseInsensitiveContains(localSearchText) }; ForEach(res.prefix(100)) { c in Button(action: { onSelect(c) }) { HStack(spacing: 12) { CachedAsyncImage(urlString: c.icon ?? "", size: CGSize(width: 35, height: 35)).frame(width: 35, height: 35).padding(2).cornerRadius(6); Text(c.name).font(.body).foregroundColor(.primary) } } } }.listStyle(.plain) }.presentationDetents([.medium, .large]) }
}

struct MultiViewSlot: View {
    let channel: StreamChannel?; let isFocused: Bool; let showControls: Bool; let onTap: () -> Void; let onAdd: () -> Void; let onRemove: () -> Void
    @State private var isPlaying = true
    
    var body: some View { 
        ZStack { 
            Color.gray.opacity(0.15); 
            if let c = channel { 
                GridVideoPlayer(url: URL(string: c.streamURL)!, isMuted: !isFocused, isPlaying: $isPlaying)
                    .allowsHitTesting(false); 
                VStack { 
                    Spacer(); 
                    HStack { 
                        Button(action: onRemove) { Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.8)) }.padding(30); 
                        Spacer(); 
                        Button(action: { isPlaying.toggle() }) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 26)).foregroundStyle(.white).padding(10).background(.ultraThinMaterial).clipShape(Circle())
                        }
                        Image(systemName: isFocused ? "speaker.wave.2.fill" : "speaker.slash.fill").foregroundStyle(.white.opacity(isFocused ? 1 : 0.5)).font(.system(size: 26)).padding(30) 
                    } 
                }.opacity(showControls ? 1 : 0).animation(.easeInOut(duration: 0.2), value: showControls) 
            } else { 
                Button(action: onAdd) { VStack { Image(systemName: "plus.circle").font(.largeTitle); Text("Add Channel").font(.caption) }.foregroundStyle(.white.opacity(0.5)) } 
            } 
        }.contentShape(Rectangle()).onTapGesture { onTap() }.clipShape(RoundedRectangle(cornerRadius: 24)) 
    }
}

struct GridVideoPlayer: UIViewRepresentable {
    typealias UIViewType = NebuloKSVideoPlayerView
    let url: URL; let isMuted: Bool; @Binding var isPlaying: Bool
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeUIView(context: Context) -> NebuloKSVideoPlayerView {
        let player = NebuloKSVideoPlayerView()
        player.backgroundColor = UIColor.black
        player.allowNativeControls = false
        context.coordinator.player = player
        context.coordinator.startPlayback(url: url)
        return player
    }
    
    func updateUIView(_ uiView: NebuloKSVideoPlayerView, context: Context) {
        if context.coordinator.currentURL != url { 
            context.coordinator.startPlayback(url: url)
        }
        uiView.playerLayer?.player.isMuted = isMuted
        
        if isPlaying {
            if !uiView.playerLayer!.player.isPlaying { uiView.play() }
        } else {
            if uiView.playerLayer!.player.isPlaying { uiView.pause() }
        }
    }
    
    class Coordinator: NSObject {
        var parent: GridVideoPlayer
        var player: NebuloKSVideoPlayerView?
        var currentURL: URL?
        var watchdogTimer: Timer?
        var lastTime: TimeInterval = -1
        var stuckCount = 0
        
        init(_ parent: GridVideoPlayer) { self.parent = parent }
        
        func startPlayback(url: URL) {
            self.currentURL = url
            // Use same robust options as main player
            let resource = KSPlayerResource(url: url)
            player?.set(resource: resource)
            player?.play()
            
            startWatchdog()
            
            player?.onTimeChange = { [weak self] current, _ in
                self?.lastTime = current
                self?.stuckCount = 0
            }
        }
        
        func startWatchdog() {
            watchdogTimer?.invalidate()
            watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self = self, let player = self.player else { return }
                guard self.parent.isPlaying else { return }
                
                // If time hasn't moved for 6 seconds (3 checks * 2s), reload
                if abs(player.playerLayer!.player.currentPlaybackTime - self.lastTime) < 0.1 {
                    self.stuckCount += 1
                    if self.stuckCount >= 3 {
                        print("♻️ [MultiView] Stream stuck, reloading: \(self.currentURL?.lastPathComponent ?? "")")
                        self.stuckCount = 0
                        if let url = self.currentURL {
                            let resource = KSPlayerResource(url: url)
                            player.set(resource: resource)
                            player.play()
                        }
                    }
                } else {
                    self.stuckCount = 0
                }
                self.lastTime = player.playerLayer!.player.currentPlaybackTime
            }
        }
        
        deinit { watchdogTimer?.invalidate() }
    }
}