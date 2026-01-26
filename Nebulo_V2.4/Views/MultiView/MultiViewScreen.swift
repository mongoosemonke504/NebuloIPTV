import SwiftUI
import KSPlayer
import MobileVLCKit

struct MultiViewScreen: View {
    @ObservedObject var viewModel: ChannelViewModel
    @Binding var showMultiView: Bool
    
    @State private var focusedIndex: Int = 0
    @State private var showControls = true
    @State private var controlTimer: Timer?
    @State private var showSearchSheet = false
    @State private var hasAppeared = false
    @State private var isExiting = false
    
    // Compute active indices based on which slots have channels
    var activeIndices: [Int] {
        viewModel.multiViewSlots.enumerated().compactMap { $0.element != nil ? $0.offset : nil }
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background
                NebulaBackgroundView(
                    color1: .blue.opacity(0.3),
                    color2: .purple.opacity(0.3),
                    color3: .cyan.opacity(0.3),
                    point1: .topLeading,
                    point2: .bottomTrailing,
                    point3: .center,
                    targetFPS: 30
                )
                .overlay(Color.black.opacity(0.4)) // Darken for video contrast
                .ignoresSafeArea()
                
                // Video Grid
                ForEach(0..<4) { i in
                    let rect = getRect(for: i, size: geo.size)
                    let isVisible = shouldShow(index: i)
                    
                    if isVisible {
                        MultiViewSlot(
                            channel: viewModel.multiViewSlots[i],
                            isFocused: focusedIndex == i,
                            showControls: showControls,
                            onTap: {
                                focusedIndex = i
                                toggleControls()
                            },
                            onAdd: { showSearchSheet = true },
                            onRemove: { viewModel.updateMultiViewSlot(index: i, channel: nil) }
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        // Smoothly animate frame changes
                        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: rect)
                        .transition(.opacity)
                    }
                }
                
                // Empty State / "Add First Stream"
                if activeIndices.isEmpty {
                    VStack(spacing: 20) {
                        Button(action: { showSearchSheet = true }) {
                            VStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 60))
                                    .foregroundStyle(.linearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                                
                                Text("Add First Stream")
                                    .font(.headline)
                                    .foregroundColor(.white.opacity(0.9))
                            }
                            .padding(40)
                            .background(Material.ultraThinMaterial)
                            .cornerRadius(24)
                            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                        }
                    }
                }
                
                // Overlay Controls
                VStack {
                    HStack(alignment: .center) {
                        Button(action: { handleDismiss() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Material.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        
                        Spacer()
                        
                        // Only show global "Add" if we have active streams but < 4
                        if !activeIndices.isEmpty && activeIndices.count < 4 {
                            Button(action: { showSearchSheet = true }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus")
                                    Text("Add Stream")
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Material.ultraThinMaterial)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(.white.opacity(0.2), lineWidth: 1)
                                )
                            }
                        }
                        
                        Spacer()
                        
                        Button(action: {
                            withAnimation { viewModel.multiViewSlots = [nil, nil, nil, nil] }
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.red.opacity(0.9))
                                .padding(10)
                                .background(Material.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.top, 50)
                    .padding(.horizontal, 20)
                    .opacity(showControls && !isExiting ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: showControls)
                    
                    Spacer()
                }
            }
            .opacity(isExiting ? 0 : (hasAppeared ? 1 : 0))
            .scaleEffect(isExiting ? 0.95 : (hasAppeared ? 1.0 : 0.98))
        }
        .onTapGesture { toggleControls() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) { hasAppeared = true }
            resetTimer()
        }
        .sheet(isPresented: $showSearchSheet) {
            MultiViewSearchSheet(viewModel: viewModel, onSelect: { c in
                viewModel.addToMultiView(c)
                showSearchSheet = false
            })
        }
        .gesture(DragGesture().onEnded { v in
            if v.translation.height > 100 { handleDismiss() }
        })
        .statusBar(hidden: true)
    }
    
    // MARK: - Smart Layout Logic
    
    func shouldShow(index: Int) -> Bool {
        // Only show slots that actually have a channel
        return activeIndices.contains(index)
    }
    
    func getRect(for index: Int, size: CGSize) -> CGRect {
        // If not active, hide it (size 0)
        guard let rank = activeIndices.firstIndex(of: index) else {
            return CGRect(x: size.width/2, y: size.height/2, width: 0, height: 0)
        }
        
        // Define safe area bounds (4pt from screen edges)
        let safePadding: CGFloat = 0
        let safeRect = CGRect(origin: .zero, size: size).insetBy(dx: safePadding, dy: safePadding)
        
        let count = activeIndices.count
        let w = safeRect.width
        let h = safeRect.height
        let startX = safeRect.minX
        let startY = safeRect.minY
        
        let isLandscape = w > h
        let padding: CGFloat = 4 // Increased inner gap slightly
        
        // Helper to inset rects for spacing between items
        func inset(_ r: CGRect) -> CGRect {
            return r.insetBy(dx: padding, dy: padding)
        }
        
        switch count {
        case 1:
            return inset(CGRect(x: startX, y: startY, width: w, height: h))
            
        case 2:
            if isLandscape {
                // Side-by-side
                let width = w / 2
                let x = rank == 0 ? startX : startX + width
                return inset(CGRect(x: x, y: startY, width: width, height: h))
            } else {
                // Top-bottom
                let height = h / 2
                let y = rank == 0 ? startY : startY + height
                return inset(CGRect(x: startX, y: y, width: w, height: height))
            }
            
        case 3:
            if isLandscape {
                // Hero Layout: Main Left (60%), Stacked Right (40%)
                let mainW = w * 0.60
                let sideW = w - mainW
                let sideH = h / 2
                
                if rank == 0 {
                    return inset(CGRect(x: startX, y: startY, width: mainW, height: h))
                } else if rank == 1 {
                    return inset(CGRect(x: startX + mainW, y: startY, width: sideW, height: sideH))
                } else {
                    return inset(CGRect(x: startX + mainW, y: startY + sideH, width: sideW, height: sideH))
                }
            } else {
                // Hero Layout: Main Top (60%), Split Bottom (40%)
                let mainH = h * 0.60
                let bottomH = h - mainH
                let bottomW = w / 2
                
                if rank == 0 {
                    return inset(CGRect(x: startX, y: startY, width: w, height: mainH))
                } else if rank == 1 {
                    return inset(CGRect(x: startX, y: startY + mainH, width: bottomW, height: bottomH))
                } else {
                    return inset(CGRect(x: startX + bottomW, y: startY + mainH, width: bottomW, height: bottomH))
                }
            }
            
        case 4:
            // 2x2 Grid
            let cellW = w / 2
            let cellH = h / 2
            let row = CGFloat(rank / 2)
            let col = CGFloat(rank % 2)
            return inset(CGRect(x: startX + col * cellW, y: startY + row * cellH, width: cellW, height: cellH))
            
        default:
            return .zero
        }
    }
    
    private func handleDismiss() {
        withAnimation(.easeInOut(duration: 0.25)) { isExiting = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showMultiView = false }
    }
    
    func toggleControls() {
        guard !isExiting else { return }
        withAnimation {
            showControls.toggle()
            if showControls { resetTimer() }
        }
    }
    
    func resetTimer() {
        controlTimer?.invalidate()
        controlTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
            withAnimation { showControls = false }
        }
    }
}

// MARK: - Components

struct MultiViewSlot: View {
    let channel: StreamChannel?
    let isFocused: Bool
    let showControls: Bool
    let onTap: () -> Void
    let onAdd: () -> Void
    let onRemove: () -> Void
    
    @State private var isPlaying = true
    
    var body: some View {
        ZStack {
            Color.black
            
            if let c = channel {
                GridVLCPlayer(url: URL(string: c.streamURL)!, isMuted: !isFocused, isPlaying: $isPlaying)
                    .allowsHitTesting(false)
                
                // Gradient overlay for better control visibility
                VStack {
                    LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 60)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 60)
                }
                .opacity(showControls ? 1 : 0)
                
                // Controls
                VStack {
                    HStack {
                        Spacer()
                        Button(action: onRemove) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Material.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .padding(12)
                    }
                    
                    Spacer()
                    
                    HStack {
                        // Sound Indicator / Toggle
                        Image(systemName: isFocused ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 16))
                            .foregroundColor(isFocused ? .black : .white.opacity(0.6))
                            .padding(8)
                            .background(
                                ZStack {
                                    if isFocused {
                                        Color.white.opacity(0.9)
                                    } else {
                                        Rectangle().fill(Material.ultraThinMaterial)
                                    }
                                }
                            )
                            .clipShape(Circle())
                        
                        Spacer()
                        
                        // Play/Pause
                        Button(action: { isPlaying.toggle() }) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16))
                                .foregroundColor(isFocused ? .black : .white)
                                .padding(8)
                                .background(
                                    ZStack {
                                        if isFocused {
                                            Color.white.opacity(0.9)
                                        } else {
                                            Rectangle().fill(Material.ultraThinMaterial)
                                        }
                                    }
                                )
                                .clipShape(Circle())
                        }
                    }
                    .padding(12)
                }
                .opacity(showControls ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: showControls)
                
                // Focus Border (Subtle)
                if isFocused {
                    RoundedRectangle(cornerRadius: 48, style: .continuous)
                        .stroke(Color.white.opacity(0.8), lineWidth: 4)
                }
            } else {
                // Empty slot styling handled by parent layout logic normally,
                // but if used directly:
                Button(action: onAdd) {
                    VStack {
                        Image(systemName: "plus")
                            .font(.title)
                        Text("Add")
                            .font(.caption)
                    }
                    .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 5, x: 0, y: 2)
    }
}

// ... (Rest of file: MultiViewSearchSheet and GridVLCPlayer remains same)

struct MultiViewSearchSheet: View {
    @ObservedObject var viewModel: ChannelViewModel; var onSelect: (StreamChannel) -> Void; @State private var localSearchText = ""; @Environment(\.dismiss) var dismiss
    var body: some View { VStack(spacing: 0) { HStack { Text("Add Stream").font(.headline); Spacer(); Button("Done") { dismiss() }.fontWeight(.bold) }.padding(); HStack { Image(systemName: "magnifyingglass").foregroundColor(.gray); TextField("Search channels...", text: $localSearchText).textFieldStyle(.plain).submitLabel(.search); if !localSearchText.isEmpty { Button(action: { localSearchText = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(.gray) } } }.padding(10).background(Color.primary.opacity(0.05)).cornerRadius(10).padding(.horizontal).padding(.bottom, 10); List { let res = viewModel.channels.filter { localSearchText.isEmpty || $0.name.localizedCaseInsensitiveContains(localSearchText) }; ForEach(res.prefix(100)) { c in Button(action: { onSelect(c) }) { HStack(spacing: 12) { CachedAsyncImage(urlString: c.icon ?? "", size: CGSize(width: 35, height: 35)).frame(width: 35, height: 35).padding(2).cornerRadius(6); Text(c.name).font(.body).foregroundColor(.primary) } } } }.listStyle(.plain) }.presentationDetents([.medium, .large]) }
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
            
            
            
            
            
            
            if let audio = player.audio {
                audio.volume = isMuted ? 0 : 100
            }
            
            
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
                
                
                
                let currentTime = self.player.time.intValue
                
                
                
                
                
                if abs(currentTime - self.lastTime) < 100 { 
                    self.stuckCount += 1
                    if self.stuckCount >= 5 { 
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
