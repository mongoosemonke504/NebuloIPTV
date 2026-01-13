import SwiftUI
import KSPlayer
import MobileVLCKit

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
        let isLandscape = w > h
        
        if count == 0 { return index == 0 ? CGRect(x: 0, y: 0, width: w, height: h) : CGRect(x: w/2, y: h/2, width: 0, height: 0) }
        
        if count == 1 { return indices.contains(index) ? CGRect(x: 0, y: 0, width: w, height: h) : CGRect(x: w/2, y: h/2, width: 0, height: 0) }
        
        if count == 2 {
            if indices.contains(index) {
                let isFirst = indices.first == index
                if isLandscape {
                    // Side-by-Side in Landscape
                    return CGRect(x: isFirst ? 0 : w/2, y: 0, width: w/2, height: h)
                } else {
                    // Top-Bottom in Portrait
                    return CGRect(x: 0, y: isFirst ? 0 : h/2, width: w, height: h/2)
                }
            }
            return CGRect(x: w/2, y: h/2, width: 0, height: 0)
        }
        
        // 3 or 4 streams: 2x2 Grid
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
                GridVLCPlayer(url: URL(string: c.streamURL)!, isMuted: !isFocused, isPlaying: $isPlaying)
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
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .padding(2) // Add spacing for cleaner grid
    }
}

struct GridVLCPlayer: UIViewRepresentable {
    let url: URL; let isMuted: Bool; @Binding var isPlaying: Bool
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        context.coordinator.setupPlayer(view: view, url: url)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(url: url, isMuted: isMuted, isPlaying: isPlaying)
    }
    
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.player.stop()
        coordinator.player.drawable = nil
    }
    
    class Coordinator: NSObject, VLCMediaPlayerDelegate {
        var parent: GridVLCPlayer
        let player = VLCMediaPlayer()
        var currentURL: URL?
        var watchdogTimer: Timer?
        var lastTime: Int32 = -1
        var stuckCount = 0
        
        init(_ parent: GridVLCPlayer) {
            self.parent = parent
            super.init()
            player.delegate = self
        }
        
        func setupPlayer(view: UIView, url: URL) {
            player.drawable = view
            playURL(url)
            startWatchdog()
        }
        
        func playURL(_ url: URL) {
            currentURL = url
            let media = VLCMedia(url: url)
            // Consistent robust options optimized for Multi-View
            // Enable hardware decoding to reduce CPU load with 4 streams
            media.addOptions([
                "network-caching": 2000,
                "clock-jitter": 0,
                "clock-synchro": 0,
                "avcodec-hw": "any",
                "videotoolbox": 1,
                "framedrop": 1
            ])
            player.media = media
            player.play()
        }
        
        func update(url: URL, isMuted: Bool, isPlaying: Bool) {
            if currentURL != url {
                playURL(url)
            }
            
            // Handle Audio
            // Note: VLCMediaPlayer doesn't have a simple isMuted property exposed in all bindings?
            // We use audio volume. 0 = Muted.
            // But we need to check if 'audio' property is accessible.
            // Assuming standard MobileVLCKit.
            if let audio = player.audio {
                audio.volume = isMuted ? 0 : 100
            }
            
            // Handle Play/Pause
            if isPlaying {
                if !player.isPlaying { player.play() }
            } else {
                if player.isPlaying { player.pause() }
            }
        }
        
        func startWatchdog() {
            watchdogTimer?.invalidate()
            watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                guard self.parent.isPlaying else { return }
                
                // If time hasn't moved for 6 seconds (3 checks * 2s), reload
                // player.time.intValue is in ms
                let currentTime = self.player.time.intValue
                
                // Check if valid time (sometimes -1 or 0 at start)
                // We only count stuck if it's > 0 or if we've been trying to start for a while?
                // Let's rely on change.
                
                if abs(currentTime - self.lastTime) < 100 { // Less than 100ms change
                    self.stuckCount += 1
                    if self.stuckCount >= 5 { // 10 seconds stuck
                        print("♻️ [MultiView-VLC] Stream stuck, reloading: \(self.currentURL?.lastPathComponent ?? "")")
                        self.stuckCount = 0
                        if let url = self.currentURL {
                            self.playURL(url)
                        }
                    }
                } else {
                    self.stuckCount = 0
                }
                self.lastTime = currentTime
            }
        }
        
        deinit {
            watchdogTimer?.invalidate()
            player.stop()
        }
    }
}