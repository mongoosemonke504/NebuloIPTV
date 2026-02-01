import SwiftUI
import KSPlayer
import MobileVLCKit
import AVFoundation

struct MultiViewScreen: View {
    @ObservedObject var viewModel: ChannelViewModel
    @Binding var showMultiView: Bool
    
    @State private var focusedIndex: Int = 0
    @State private var showControls = true
    @State private var controlTimer: Timer?
    @State private var showSearchSheet = false
    @State private var hasAppeared = false
    @State private var isExiting = false
    
    
    var activeIndices: [Int] {
        viewModel.multiViewSlots.enumerated().compactMap { $0.element != nil ? $0.offset : nil }
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                
                NebulaBackgroundView(
                    color1: .blue.opacity(0.3),
                    color2: .purple.opacity(0.3),
                    color3: .cyan.opacity(0.3),
                    point1: .topLeading,
                    point2: .bottomTrailing,
                    point3: .center,
                    targetFPS: 30
                )
                .overlay(Color.black.opacity(0.4)) 
                .ignoresSafeArea()
                
                
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
                                                
                                                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: rect)
                                                .transition(.opacity)
                                                                            .onDrag {
                                                                                return NSItemProvider(object: String(i) as NSString)
                                                                            } preview: {
                                                                                
                                                                                if let channel = viewModel.multiViewSlots[i] {
                                                                                    VStack(spacing: 12) {
                                                                                        CachedAsyncImage(urlString: channel.icon ?? "", size: CGSize(width: 60, height: 60))
                                                                                            .cornerRadius(12)
                                                                                            .shadow(radius: 5)
                                                                                        
                                                                                        Text(channel.name)
                                                                                            .font(.system(size: 14, weight: .bold))
                                                                                            .foregroundColor(.white)
                                                                                            .lineLimit(1)
                                                                                            .padding(.horizontal, 8)
                                                                                    }
                                                                                    .padding(16)
                                                                                    .frame(width: 160, height: 120)
                                                                                    .background(
                                                                                        ZStack {
                                                                                            Color.black.opacity(0.8)
                                                                                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                                                                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                                                                        }
                                                                                    )
                                                                                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                                                                }
                                                                            }
                                                                            .onDrop(of: ["public.text"], isTargeted: nil) { providers in                                                    if let first = providers.first {
                                                        _ = first.loadObject(ofClass: NSString.self) { sourceStr, _ in
                                                            if let str = sourceStr as? String, let sourceIndex = Int(str) {
                                                                DispatchQueue.main.async {
                                                                    withAnimation {
                                                                        viewModel.swapMultiViewSlots(from: sourceIndex, to: i)
                                                                        
                                                                        if focusedIndex == sourceIndex {
                                                                            focusedIndex = i
                                                                        } else if focusedIndex == i {
                                                                            focusedIndex = sourceIndex
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                        return true
                                                    }
                                                    return false
                                                }
                                            }                }
                
                
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
    
    
    
    func shouldShow(index: Int) -> Bool {
        
        return activeIndices.contains(index)
    }
    
    func getRect(for index: Int, size: CGSize) -> CGRect {
        
        guard let rank = activeIndices.firstIndex(of: index) else {
            return CGRect(x: size.width/2, y: size.height/2, width: 0, height: 0)
        }
        
        
        let safePadding: CGFloat = 0
        let safeRect = CGRect(origin: .zero, size: size).insetBy(dx: safePadding, dy: safePadding)
        
        let count = activeIndices.count
        let w = safeRect.width
        let h = safeRect.height
        let startX = safeRect.minX
        let startY = safeRect.minY
        
        let isLandscape = w > h
        let padding: CGFloat = 4 
        
        
        func inset(_ r: CGRect) -> CGRect {
            return r.insetBy(dx: padding, dy: padding)
        }
        
        switch count {
        case 1:
            return inset(CGRect(x: startX, y: startY, width: w, height: h))
            
        case 2:
            if isLandscape {
                
                let width = w / 2
                let x = rank == 0 ? startX : startX + width
                return inset(CGRect(x: x, y: startY, width: width, height: h))
            } else {
                
                let height = h / 2
                let y = rank == 0 ? startY : startY + height
                return inset(CGRect(x: startX, y: y, width: w, height: height))
            }
            
        case 3:
            if isLandscape {
                
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
                SmartGridPlayer(url: URL(string: c.streamURL)!, isMuted: !isFocused, isPlaying: $isPlaying)
                    .allowsHitTesting(false)
                
                
                VStack {
                    LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 60)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 60)
                }
                .opacity(showControls ? 1 : 0)
                
                
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
                
                
                if isFocused {
                    RoundedRectangle(cornerRadius: 48, style: .continuous)
                        .stroke(Color.white.opacity(0.8), lineWidth: 4)
                }
            } else {
                
                
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



struct MultiViewSearchSheet: View {
    @ObservedObject var viewModel: ChannelViewModel; var onSelect: (StreamChannel) -> Void; @State private var localSearchText = ""; @Environment(\.dismiss) var dismiss
    var body: some View { VStack(spacing: 0) { HStack { Text("Add Stream").font(.headline); Spacer(); Button("Done") { dismiss() }.fontWeight(.bold) }.padding(); HStack { Image(systemName: "magnifyingglass").foregroundColor(.gray); TextField("Search channels...", text: $localSearchText).textFieldStyle(.plain).submitLabel(.search); if !localSearchText.isEmpty { Button(action: { localSearchText = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(.gray) } } }.padding(10).background(Color.primary.opacity(0.05)).cornerRadius(10).padding(.horizontal).padding(.bottom, 10); List { let res = viewModel.channels.filter { localSearchText.isEmpty || $0.name.localizedCaseInsensitiveContains(localSearchText) }; ForEach(res.prefix(100)) { c in Button(action: { onSelect(c) }) { HStack(spacing: 12) { CachedAsyncImage(urlString: c.icon ?? "", size: CGSize(width: 35, height: 35)).frame(width: 35, height: 35).padding(2).cornerRadius(6); Text(c.name).font(.body).foregroundColor(.primary) } } } }.listStyle(.plain) }.presentationDetents([.medium, .large]) }
}

struct SmartGridPlayer: UIViewRepresentable {
    let url: URL; let isMuted: Bool; @Binding var isPlaying: Bool
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        context.coordinator.setup(view: view, url: url)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(url: url, isMuted: isMuted, isPlaying: isPlaying)
    }
    
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stopAll()
    }
    
    class Coordinator: NSObject, VLCMediaPlayerDelegate {
        var parent: SmartGridPlayer
        weak var containerView: UIView?
        
        
        var ksPlayerView: NebuloKSVideoPlayerView?
        
        
        var vlcPlayer: VLCMediaPlayer?
        
        var currentURL: URL?
        var isVLCFallback = false
        var retryCount = 0
        
        init(_ parent: SmartGridPlayer) {
            self.parent = parent
            super.init()
        }
        
        func setup(view: UIView, url: URL) {
            self.containerView = view
            self.currentURL = url
            startKSPlayer(url: url)
        }
        
        func update(url: URL, isMuted: Bool, isPlaying: Bool) {
            if currentURL != url {
                stopAll()
                isVLCFallback = false 
                currentURL = url
                startKSPlayer(url: url)
            }
            
            if isVLCFallback {
                updateVLC(isMuted: isMuted, isPlaying: isPlaying)
            } else {
                updateKSPlayer(isMuted: isMuted, isPlaying: isPlaying)
            }
        }
        
        
        
        func startKSPlayer(url: URL) {
            guard let container = containerView else { return }
            
            let player = NebuloKSVideoPlayerView()
            player.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(player)
            
            NSLayoutConstraint.activate([
                player.topAnchor.constraint(equalTo: container.topAnchor),
                player.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                player.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                player.trailingAnchor.constraint(equalTo: container.trailingAnchor)
            ])
            
            player.backgroundColor = .black
            
            
            
            let options = KSOptions()
            
            let resource = KSPlayerResource(url: url, options: options)
            player.set(resource: resource)
            
            
            player.onStateChange = { [weak self] state in
                guard let self = self else { return }
                if state == .error {
                    print("⚠️ [MultiView] KSPlayer Error: \(state). Retrying/Fallback...")
                    self.handleKSFailure()
                }
            }
            
            
            player.onFinish = { [weak self] error in
                if let err = error {
                    print("⚠️ [MultiView] KSPlayer Finished with Error: \(err)")
                    self?.handleKSFailure()
                }
            }
            
            self.ksPlayerView = player
        }
        
        func updateKSPlayer(isMuted: Bool, isPlaying: Bool) {
            guard let player = ksPlayerView, let avPlayer = player.playerLayer?.player else { return }
            
            
            avPlayer.isMuted = isMuted
            if let realPlayer = avPlayer as? AVPlayer {
                realPlayer.volume = isMuted ? 0 : 1.0
            }
            
            
            if isPlaying {
                if !avPlayer.isPlaying { player.play() }
            } else {
                if avPlayer.isPlaying { player.pause() }
            }
        }
        
        func handleKSFailure() {
            if retryCount < 1 {
                retryCount += 1
                print("🔄 [MultiView] Retrying KSPlayer...")
                if let url = currentURL {
                    ksPlayerView?.set(resource: KSPlayerResource(url: url))
                }
            } else {
                print("🚨 [MultiView] KSPlayer Failed. Switching to VLC...")
                switchToVLC()
            }
        }
        
        
        
        func switchToVLC() {
            DispatchQueue.main.async {
                self.ksPlayerView?.pause()
                self.ksPlayerView?.removeFromSuperview()
                self.ksPlayerView = nil
                self.isVLCFallback = true
                
                if let url = self.currentURL {
                    self.startVLC(url: url)
                }
            }
        }
        
        func startVLC(url: URL) {
            guard let container = containerView else { return }
            
            let player = VLCMediaPlayer()
            player.delegate = self
            player.drawable = container
            
            let media = VLCMedia(url: url)
            media.addOptions([
                "network-caching": 1500,
                "clock-jitter": 0,
                "clock-synchro": 0,
                "avcodec-hw": "any",
                "videotoolbox": 1
            ])
            player.media = media
            player.play()
            
            self.vlcPlayer = player
        }
        
        func updateVLC(isMuted: Bool, isPlaying: Bool) {
            guard let player = vlcPlayer else { return }
            
            
            if let audio = player.audio {
                audio.volume = isMuted ? 0 : 100
            }
            
            
            if isPlaying {
                if !player.isPlaying { player.play() }
            } else {
                if player.isPlaying { player.pause() }
            }
        }
        
        func mediaPlayerStateChanged(_ aNotification: Notification) {
            
        }
        
        
        
        func stopAll() {
            ksPlayerView?.pause()
            ksPlayerView?.removeFromSuperview()
            ksPlayerView = nil
            
            vlcPlayer?.stop()
            vlcPlayer?.drawable = nil
            vlcPlayer = nil
        }
        
        deinit {
            stopAll()
        }
    }
}
