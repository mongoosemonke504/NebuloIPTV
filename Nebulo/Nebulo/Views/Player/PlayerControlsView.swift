import SwiftUI

struct PlayerControlsView: View {
    @ObservedObject var playerManager: NebuloPlayerEngine
    @ObservedObject var recordingManager = RecordingManager.shared
    let channel: StreamChannel
    var viewModel: ChannelViewModel?
    var isRecordingPlayback: Bool = false
    
    @Binding var showControls: Bool
    @Binding var showSubtitlePanel: Bool
    @Binding var showResolutionPanel: Bool
    @Binding var showAspectRatioPanel: Bool
    @Binding var showFullDescription: Bool
    
    
    @Binding var isScrubbing: Bool
    @Binding var draggingProgress: Double?
    
    
    @State private var isLongPaused = false
    @State private var pauseTimerTask: Task<Void, Never>? = nil
    @State private var isDescriptionExpanded = false
    
    
    var onDismiss: () -> Void
    var togglePlay: () -> Void
    var toggleControls: () -> Void
    var seekForward: () -> Void
    var seekBackward: () -> Void
    
    @AppStorage("accentColor") private var accentHex = "#007AFF"
    var accentColor: Color { Color(hex: accentHex) ?? .blue }
    
    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let currentProg = viewModel?.getCurrentProgram(for: channel)
            let isTrulyLive = !isScrubbing && !isLongPaused && playerManager.duration > 0 && playerManager.currentTime >= playerManager.duration - 15
            
            ZStack {
                
                Color.black.opacity(0.01)
                    .ignoresSafeArea()
                    .onTapGesture {
                        toggleControls()
                    }
                
                if showControls {
                    
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture {
                            toggleControls()
                        }
                    
                    ZStack {
                        
                        HStack(spacing: 60) {
                            
                            Button(action: {
                                ChannelViewModel.shared.triggerSelectionHaptic()
                                if !playerManager.playbackFailed {
                                    togglePlay()
                                }
                            }) {
                                Image(systemName: playerManager.playbackFailed ? "xmark" : (playerManager.isPlaying ? "pause.fill" : "play.fill"))
                                    .font(.system(size: 34, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 82, height: 82)
                                    .modifier(GlassEffect(cornerRadius: 42, isSelected: true, accentColor: nil))
                            }
                            .buttonStyle(.plain)
                            .opacity(playerManager.isBuffering ? 0 : 1)
                            .disabled(playerManager.isBuffering || playerManager.playbackFailed)
                        }
                        .allowsHitTesting(!playerManager.isBuffering)
                        
                        
                        
                        VStack {
                            
                            
                            Group {
                                if isLandscape {
                                    ZStack {
                                        HStack {
                                            Button(action: {
                                                ChannelViewModel.shared.triggerSelectionHaptic()
                                                onDismiss()
                                            }) {
                                                Image(systemName: "xmark")
                                                    .font(.system(size: 18, weight: .bold))
                                                    .foregroundColor(.white)
                                                    .padding(12)
                                                    .modifier(GlassEffect(cornerRadius: 22, isSelected: true, accentColor: nil))
                                            }
                                            .buttonStyle(.plain)
                                            
                                            Spacer()
                                            
                                            
                                            HStack(spacing: 16) {
                                                if let vm = viewModel {
                                                    Button(action: {
                                                        vm.triggerSelectionHaptic()
                                                        vm.miniPlayerChannel = channel
                                                        onDismiss()
                                                    }) {
                                                        Image(systemName: "pip.enter")
                                                            .font(.system(size: 18, weight: .bold))
                                                            .foregroundColor(.white)
                                                            .padding(12)
                                                            .modifier(GlassEffect(cornerRadius: 22, isSelected: true, accentColor: nil))
                                                    }
                                                    .buttonStyle(.plain)
                                                    
                                                    Button(action: {
                                                        vm.triggerSelectionHaptic()
                                                        vm.triggerMultiViewFromPlayer(with: channel)
                                                    }) {
                                                        Image(systemName: "square.grid.2x2.fill")
                                                            .font(.system(size: 18, weight: .bold))
                                                            .foregroundColor(.white)
                                                            .padding(12)
                                                            .modifier(GlassEffect(cornerRadius: 22, isSelected: true, accentColor: nil))
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        }
                                        
                                        Text(channel.name)
                                            .font(.headline)
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                            .lineLimit(1)
                                            .frame(maxWidth: geo.size.width * 0.5)
                                    }
                                } else {
                                    HStack {
                                        Button(action: {
                                            ChannelViewModel.shared.triggerSelectionHaptic()
                                            onDismiss()
                                        }) {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 18, weight: .bold))
                                                .foregroundColor(.white)
                                                .padding(12)
                                                .modifier(GlassEffect(cornerRadius: 22, isSelected: true, accentColor: nil))
                                        }
                                        .buttonStyle(.plain)
                                        
                                        Spacer()
                                        
                                        Text(channel.name)
                                            .font(.headline)
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                        
                                        Spacer()
                                        
                                        
                                        HStack(spacing: 16) {
                                            if let vm = viewModel {
                                                Button(action: {
                                                    vm.triggerSelectionHaptic()
                                                    vm.miniPlayerChannel = channel
                                                    onDismiss()
                                                }) {
                                                    Image(systemName: "pip.enter")
                                                        .font(.system(size: 18, weight: .bold))
                                                        .foregroundColor(.white)
                                                        .padding(12)
                                                        .modifier(GlassEffect(cornerRadius: 22, isSelected: true, accentColor: nil))
                                                }
                                                .buttonStyle(.plain)
                                                
                                                Button(action: {
                                                    vm.triggerSelectionHaptic()
                                                    vm.triggerMultiViewFromPlayer(with: channel)
                                                }) {
                                                    Image(systemName: "square.grid.2x2.fill")
                                                        .font(.system(size: 18, weight: .bold))
                                                        .foregroundColor(.white)
                                                        .padding(12)
                                                        .modifier(GlassEffect(cornerRadius: 22, isSelected: true, accentColor: nil))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.top, isLandscape ? 40 : 60)
                            .padding(.horizontal)
                            
                            Spacer()
                            
                            
                            VStack(spacing: 8) {
                                
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(isRecordingPlayback ? (channel.originalName ?? channel.name) : (currentProg?.title ?? "No Information"))
                                            .font(.subheadline.bold())
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        
                                        
                                        Button(action: {
                                            if false { 
                                                ChannelViewModel.shared.triggerSelectionHaptic()
                                                playerManager.toggleBackend()
                                            }
                                        }) {
                                            Text(playerManager.activeBackendName)
                                                .font(.system(size: 9, weight: .black))
                                                .foregroundColor(.white.opacity(0.6))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.white.opacity(0.12))
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                        }
                                        .buttonStyle(.plain)
                                        
                                        Spacer()
                                    }
                                    
                                    let displayDesc = isRecordingPlayback ? channel.streamURL : (currentProg?.description ?? "")
                                    
                                    if !displayDesc.isEmpty {
                                        Text(displayDesc)
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.7))
                                            .lineLimit(isDescriptionExpanded ? nil : 1)
                                            .frame(width: geo.size.width - 40, alignment: .leading)
                                            .id(isDescriptionExpanded)
                                            .transition(.opacity)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                ChannelViewModel.shared.triggerSelectionHaptic()
                                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                                    isDescriptionExpanded.toggle()
                                                }
                                            }
                                    }
                                }
                                .shadow(radius: 2)
                                .padding(.bottom, -4) 
                                
                                
                                VStack(spacing: 4) {
                                    
                                    let currentPos = draggingProgress ?? (playerManager.duration > 0 ? playerManager.currentTime / playerManager.duration : 0)
                                    
                                    VStack(spacing: 8) {
                                        HStack {
                                            Text(formatTime(draggingProgress != nil ? draggingProgress! * playerManager.duration : playerManager.currentTime))
                                                .font(.caption2.monospacedDigit())
                                                .foregroundColor(.white.opacity(0.7))
                                            Spacer()
                                            Text(formatTime(playerManager.duration))
                                                .font(.caption2.monospacedDigit())
                                                .foregroundColor(.white.opacity(0.7))
                                        }
                                        
                                        GeometryReader { barGeo in
                                            ZStack(alignment: .leading) {
                                                Capsule()
                                                    .fill(Color.white.opacity(0.2))
                                                    .frame(height: 6)
                                                
                                                Capsule()
                                                    .fill(Color.white)
                                                    .frame(width: barGeo.size.width * CGFloat(currentPos), height: 6)
                                                
                                                Circle()
                                                    .fill(Color.white)
                                                    .frame(width: 14, height: 14)
                                                    .shadow(radius: 2)
                                                    .offset(x: barGeo.size.width * CGFloat(currentPos) - 7)
                                            }
                                            .frame(height: 20)
                                            .contentShape(Rectangle())
                                            .gesture(
                                                DragGesture(minimumDistance: 0)
                                                    .onChanged { value in
                                                        isScrubbing = true
                                                        draggingProgress = max(0, min(1, value.location.x / barGeo.size.width))
                                                    }
                                                    .onEnded { value in
                                                        ChannelViewModel.shared.triggerSelectionHaptic()
                                                        let dragPercent = max(0, min(1, value.location.x / barGeo.size.width))
                                                        playerManager.seek(to: playerManager.duration * dragPercent)
                                                        isScrubbing = false
                                                        draggingProgress = nil
                                                    }
                                            )
                                        }
                                        .frame(height: 20)
                                    }
                                }
                                
                                
                                HStack(spacing: 8) {
                                    
                                    Button(action: {
                                        ChannelViewModel.shared.triggerSelectionHaptic()
                                        if !isTrulyLive {
                                            withAnimation {
                                                playerManager.seek(to: playerManager.duration)
                                            }
                                        }
                                    }) {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(isTrulyLive ? Color.red : Color.gray)
                                                .frame(width: 6, height: 6)
                                            Text("LIVE")
                                                .font(.caption.bold())
                                                .foregroundColor(isTrulyLive ? .red : .gray)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 40)
                                        .modifier(GlassEffect(cornerRadius: 20, isSelected: true, accentColor: nil))
                                    }
                                    .buttonStyle(.plain)
                                    
                                    
                                    Button(action: {
                                        ChannelViewModel.shared.triggerSelectionHaptic()
                                        withAnimation { showSubtitlePanel.toggle() }
                                    }) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "captions.bubble.fill")
                                                .font(.caption.bold())
                                            Text(playerManager.availableSubtitles.isEmpty ? "None" : (playerManager.currentSubtitle?.name ?? "Off"))
                                                .font(.caption.bold())
                                        }
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 40)
                                        .modifier(GlassEffect(cornerRadius: 20, isSelected: true, accentColor: nil))
                                        .opacity(playerManager.availableSubtitles.isEmpty ? 0.6 : (playerManager.currentSubtitle != nil ? 1.0 : 0.7))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(playerManager.availableSubtitles.isEmpty)
                                    
                                    
                                    Button(action: {
                                        ChannelViewModel.shared.triggerSelectionHaptic()
                                        withAnimation { showAspectRatioPanel.toggle() }
                                    }) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "aspectratio")
                                                .font(.caption.bold())
                                            Text(playerManager.currentAspectRatio.rawValue)
                                                .font(.caption.bold())
                                        }
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 40)
                                        .modifier(GlassEffect(cornerRadius: 20, isSelected: true, accentColor: nil))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, isLandscape ? 20 : 40)
                            .background(
                                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                                    .ignoresSafeArea()
                            )
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .onChangeCompat(of: playerManager.isPlaying) { isPlaying in
            pauseTimerTask?.cancel()
            if isPlaying {
                isLongPaused = false
            } else {
                pauseTimerTask = Task {
                    try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                    if !Task.isCancelled {
                        await MainActor.run { isLongPaused = true }
                    }
                }
            }
        }
    }
    
    func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN, !seconds.isInfinite else { return "--:--" }
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
    
    func formatClockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
