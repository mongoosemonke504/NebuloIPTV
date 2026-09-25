import SwiftUI
import AVKit

struct PlayerControlsView: View {
    @ObservedObject var playerManager: NebuloPlayerEngine
    @ObservedObject var recordingManager = RecordingManager.shared
    let channel: StreamChannel
    var viewModel: ChannelViewModel?
    var isRecordingPlayback: Bool = false
    /// The recording being played, in recording playback — see
    /// `CustomVideoPlayerView.recording`.
    var recording: Recording? = nil

    /// When true, the controls render with smaller paddings and hide the bottom
    /// row of feature pills (Record / Subtitles / Aspect) — those live in the
    /// info panel below the video instead.
    var isInlineMode: Bool = false

    /// Bound to the parent's portrait-fullscreen toggle so the chrome can show
    /// an "expand / shrink" button.
    @Binding var isFullscreenInPortrait: Bool

    @Binding var showControls: Bool
    @Binding var showSubtitlePanel: Bool
    @Binding var showResolutionPanel: Bool
    @Binding var showAspectRatioPanel: Bool
    @Binding var showFullDescription: Bool
    
    
    @Binding var isScrubbing: Bool
    @Binding var draggingProgress: Double?
    
    
    @State private var timeshiftStartTime: Date? = nil
    
    
    @State private var isLongPaused = false
    @State private var pauseTimerTask: Task<Void, Never>? = nil
    @State private var isDescriptionExpanded = false
    @State private var showRecordingSheet = false
    
    
    var onDismiss: () -> Void
    var togglePlay: () -> Void
    var toggleControls: () -> Void
    var seekForward: () -> Void
    var seekBackward: () -> Void
    
    @AppStorage("accentColor") private var accentHex = "#FFFFFF"
    var accentColor: Color { Color(hex: accentHex) ?? .blue }
    
    var body: some View {
        GeometryReader { geo in
            // In inline (portrait split) mode, the GeometryReader is sized to
            // the 16:9 video tile — which is always wider than tall, so
            // measuring `width > height` here would wrongly read as landscape
            // and hide the portrait-fullscreen toggle. Inline mode only ever
            // exists in portrait, so we force the flag false there. In all
            // other cases the actual geometry is authoritative.
            let isLandscape = isInlineMode ? false : (geo.size.width > geo.size.height)
            let currentProg = viewModel?.getCurrentProgram(for: channel)
            let isRecording = recordingManager.isRecording(channelName: channel.name)
            let isTrulyLive: Bool = {
                if isScrubbing { return false }
                if isLongPaused { return false }
                if timeshiftStartTime == nil { return true }
                return playerManager.duration > 0 && playerManager.currentTime >= playerManager.duration - 15
            }()
            
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
                        
                        
                        
                        HStack(spacing: isInlineMode ? 32 : 48) {

                            if isRecordingPlayback {
                                Button(action: {
                                    ChannelViewModel.shared.triggerSelectionHaptic()
                                    seekBackward()
                                }) {
                                    Image(systemName: "gobackward.10")
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundStyle(.primary)
                                        .frame(width: 56, height: 56)
                                        .modifier(GlassEffect(cornerRadius: 28, isSelected: true, accentColor: nil))
                                }
                                .buttonStyle(.plain)
                            }

                            Button(action: {
                                ChannelViewModel.shared.triggerSelectionHaptic()
                                if !playerManager.playbackFailed {
                                    togglePlay()
                                }
                            }) {
                                Image(systemName: playerManager.playbackFailed ? "xmark" : (playerManager.isPlaying ? "pause.fill" : "play.fill"))
                                    .font(.system(size: 34, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .frame(width: 82, height: 82)
                                    .modifier(GlassEffect(cornerRadius: 42, isSelected: true, accentColor: nil))
                            }
                            .buttonStyle(.plain)
                            .disabled(playerManager.playbackFailed)

                            if isRecordingPlayback {
                                Button(action: {
                                    ChannelViewModel.shared.triggerSelectionHaptic()
                                    seekForward()
                                }) {
                                    Image(systemName: "goforward.10")
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundStyle(.primary)
                                        .frame(width: 56, height: 56)
                                        .modifier(GlassEffect(cornerRadius: 28, isSelected: true, accentColor: nil))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        
                        
                        
                        VStack {
                            
                            
                            Group {
                                if isLandscape {
                                    HStack {
                                        closeButton
                                        Spacer()
                                        topRightActions(isLandscape: true)
                                    }
                                } else {
                                    // Portrait mode - hide channel name to avoid crowding buttons
                                    HStack(spacing: 8) {
                                        closeButton
                                        Spacer()
                                        topRightActions(isLandscape: false)
                                    }
                                }
                            }
                            // Landscape was 40. There is no notch along the top
                            // edge in landscape — the cut-outs are on the sides —
                            // so the row can sit considerably higher without
                            // being clipped, which also frees the band for the
                            // live score to sit level with it.
                            .padding(.top, isInlineMode ? 8 : (isLandscape ? 20 : 60))
                            .padding(.horizontal, isInlineMode ? 8 : 16)
                            
                            Spacer()


                            VStack(spacing: 8) {

                                // Title and description — only shown in landscape, not in portrait split mode
                                if !isInlineMode {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 8) {
                                            Text(isRecordingPlayback ? (recording?.displayName ?? channel.name) : (currentProg?.title ?? "No Information"))
                                                .font(.subheadline.bold())
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)

                                            Spacer()
                                        }

                                        let displayDesc = isRecordingPlayback ? (recording?.programDescription ?? channel.epgID ?? "") : (currentProg?.description ?? "")

                                        if !displayDesc.isEmpty {
                                            Text(displayDesc)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
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
                                } 
                                
                                
                                VStack(spacing: 4) {
                                    if isRecordingPlayback {
                                        
                                        let currentPos = draggingProgress ?? (playerManager.duration > 0 ? playerManager.currentTime / playerManager.duration : 0)
                                        
                                        VStack(spacing: 8) {
                                            HStack {
                                                Text(formatTime(draggingProgress != nil ? draggingProgress! * playerManager.duration : playerManager.currentTime))
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                                Spacer()
                                                Text(formatTime(playerManager.duration))
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(.secondary)
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
                                    } else if let prog = currentProg {
                                        let totalDuration = prog.stop.timeIntervalSince(prog.start)
                                        
                                        
                                        let currentPlaybackDate: Date = {
                                            if let start = timeshiftStartTime {
                                                return start.addingTimeInterval(playerManager.currentTime)
                                            } else {
                                                return Date()
                                            }
                                        }()
                                        
                                        let elapsed = currentPlaybackDate.timeIntervalSince(prog.start)
                                        let actualProgress = max(0, min(1, elapsed / totalDuration))
                                        
                                        
                                        let liveElapsed = Date().timeIntervalSince(prog.start)
                                        let liveProgress = max(0, min(1, liveElapsed / totalDuration))
                                        
                                        let displayProgress = draggingProgress ?? actualProgress
                                        
                                        
                                        HStack {
                                            Text(formatClockTime(prog.start))
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                            
                                            Spacer()
                                            
                                            if timeshiftStartTime != nil {
                                                Text("Timeshift: \(formatClockTime(currentPlaybackDate))")
                                                    .font(.caption2.bold())
                                                    .foregroundColor(.yellow)
                                            }
                                            
                                            Spacer()
                                            
                                            Text(formatClockTime(prog.stop))
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        
                                        
                                        GeometryReader { barGeo in
                                            ZStack(alignment: .leading) {
                                                
                                                Capsule()
                                                    .fill(Color.white.opacity(channel.hasArchive ? 0.2 : 0.1))
                                                    .frame(height: 6)
                                                
                                                
                                                Capsule()
                                                    .fill(timeshiftStartTime == nil ? Color.white : Color.yellow)
                                                    .opacity(channel.hasArchive ? 1.0 : 0.3) 
                                                    .frame(width: barGeo.size.width * CGFloat(displayProgress), height: 6)
                                                
                                                
                                                if channel.hasArchive {
                                                    Rectangle()
                                                        .fill(Color.white.opacity(0.3))
                                                        .frame(width: 1, height: 10)
                                                        .offset(x: barGeo.size.width * CGFloat(liveProgress))
                                                }
                                                
                                                
                                                if channel.hasArchive {
                                                    Circle()
                                                        .fill(Color.white)
                                                        .frame(width: 14, height: 14)
                                                        .shadow(radius: 2)
                                                        .offset(x: barGeo.size.width * CGFloat(displayProgress) - 7)
                                                }
                                            }
                                            .frame(height: 20) 
                                            .contentShape(Rectangle())
                                            .applyIf(channel.hasArchive) { view in
                                                view.gesture(
                                                    DragGesture(minimumDistance: 0)
                                                        .onChanged { value in
                                                            isScrubbing = true
                                                            let dragPercent = max(0, min(1, value.location.x / barGeo.size.width))
                                                            
                                                            draggingProgress = min(dragPercent, liveProgress)
                                                        }
                                                        .onEnded { value in
                                                            ChannelViewModel.shared.triggerSelectionHaptic()
                                                            let dragPercent = max(0, min(1, value.location.x / barGeo.size.width))
                                                            let finalPercent = min(dragPercent, liveProgress)
                                                            
                                                            
                                                            if finalPercent >= liveProgress - 0.01 {
                                                                timeshiftStartTime = nil
                                                                if let url = URL(string: channel.streamURL) {
                                                                    playerManager.play(url: url)
                                                                }
                                                            } else {
                                                                let targetDate = prog.start.addingTimeInterval(totalDuration * Double(finalPercent))
                                                                handleTimeshift(to: targetDate, program: prog)
                                                            }
                                                            
                                                            
                                                            isScrubbing = false
                                                            draggingProgress = nil
                                                        }
                                                )
                                            }
                                        }
                                        .frame(height: 20)
                                    } else {
                                        
                                        VStack(spacing: 8) {
                                            HStack {
                                                Text("--:--")
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                                
                                                Spacer()
                                                
                                                Text(formatClockTime(viewModel?.currentTime ?? Date()))
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                            }
                                            
                                            ZStack(alignment: .trailing) {
                                                Capsule()
                                                    .fill(Color.white)
                                                    .frame(height: 6)
                                                
                                                Circle()
                                                    .fill(Color.white)
                                                    .frame(width: 14, height: 14)
                                                    .shadow(radius: 2)
                                                    .offset(x: 7)
                                            }
                                            .frame(height: 20)
                                        }
                                    }
                                }
                                

                                if !isInlineMode {
                                HStack(spacing: 8) {
                                    if !isRecordingPlayback {
                                        
                                        Button(action: {
                                            ChannelViewModel.shared.triggerSelectionHaptic()
                                            if !isTrulyLive {
                                                withAnimation {
                                                    if timeshiftStartTime != nil {
                                                        timeshiftStartTime = nil
                                                        if let url = URL(string: channel.streamURL) {
                                                            playerManager.play(url: url)
                                                        }
                                                    } else {
                                                        playerManager.seek(to: playerManager.duration)
                                                    }
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
                                            if isRecording {
                                                
                                                if let rec = recordingManager.recordings.first(where: { $0.channelName == channel.name && $0.status == .recording }) {
                                                    recordingManager.stopRecording(rec.id)
                                                }
                                            } else {
                                                showRecordingSheet = true
                                            }
                                        }) {
                                            HStack(spacing: 6) {
                                                Image(systemName: isRecording ? "record.circle.fill" : "record.circle")
                                                    .font(.caption.bold())
                                                    .foregroundColor(isRecording ? .red : .white)
                                                Text(isRecording ? "Stop & Save" : "Record")
                                                    .font(.caption.bold())
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.7)
                                            }
                                            .padding(.horizontal, 4)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 40)
                                            .modifier(GlassEffect(cornerRadius: 20, isSelected: true, accentColor: isRecording ? .red : nil))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 20)
                                                    .stroke(Color.red, lineWidth: isRecording ? 2 : 0)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        
                                        .opacity(1.0)
                                    }
                                    
                                    
                                    Button(action: {
                                        ChannelViewModel.shared.triggerSelectionHaptic()
                                        withAnimation { showSubtitlePanel.toggle() }
                                    }) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "captions.bubble.fill")
                                                .font(.caption.bold())
                                            Text(!playerManager.hasSelectableSubtitles ? "None" : (playerManager.currentSubtitle?.name ?? "Off"))
                                                .font(.caption.bold())
                                        }
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 40)
                                        .modifier(GlassEffect(cornerRadius: 20, isSelected: true, accentColor: nil))
                                        .opacity(!playerManager.hasSelectableSubtitles ? 0.6 : (playerManager.currentSubtitle != nil ? 1.0 : 0.7))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!playerManager.hasSelectableSubtitles)
                                    
                                    
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
                                }   // end if !isInlineMode
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, isLandscape ? 20 : (isInlineMode ? 12 : 40))
                            .background(
                                LinearGradient(colors: [.clear, .black.opacity(isInlineMode ? 0.6 : 0.8)], startPoint: .top, endPoint: .bottom)
                            )
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .sheet(isPresented: $showRecordingSheet) {
            let initialStart: Date = {
                if let tsStart = timeshiftStartTime {
                    return tsStart.addingTimeInterval(playerManager.currentTime)
                }
                return Date()
            }()
            
            RecordingSetupSheet(channel: channel, initialStartTime: initialStart) {
                showRecordingSheet = false
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
        .onAppear {
            if timeshiftStartTime == nil {
                timeshiftStartTime = playerManager.currentTimeshiftStartDate
            }
        }
    }
    
    // MARK: - Top bar helpers (shared between portrait & landscape)

    private var closeButton: some View {
        Button(action: {
            ChannelViewModel.shared.triggerSelectionHaptic()
            timeshiftStartTime = nil
            onDismiss()
        }) {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
                .padding(12)
                .modifier(GlassEffect(cornerRadius: 22, isSelected: true, accentColor: nil))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func topRightActions(isLandscape: Bool) -> some View {
        HStack(spacing: isLandscape ? 12 : 8) {
            // AirPlay (system route picker, universal)
            AirPlayButton()
                .frame(width: 22, height: 22)
                .padding(isLandscape ? 11 : 8)
                .modifier(GlassEffect(cornerRadius: 22, isSelected: true, accentColor: nil))

            if let vm = viewModel {
                // System Picture-in-Picture: floats the video over the home
                // screen (and outside the app). Falls back to the in-app
                // miniplayer for streams AVPlayer can't decode.
                Button(action: {
                    vm.triggerSelectionHaptic()
                    playerManager.enablePictureInPicture()
                    // Give PiP a beat to appear; when it did, close the
                    // full player (the floating window carries on). If the
                    // stream can't PiP, fall back to the in-app miniplayer.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if playerManager.isPiPSessionActive {
                            onDismiss()
                        } else if !AVPictureInPictureController.isPictureInPictureSupported() {
                            vm.miniPlayerRecording = recording
                            vm.miniPlayerChannel = channel
                            onDismiss()
                        }
                    }
                }) {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(isLandscape ? 12 : 8)
                        .modifier(GlassEffect(cornerRadius: 22, isSelected: true, accentColor: nil))
                }
                .buttonStyle(.plain)

                // Multi-view
                Button(action: {
                    vm.triggerSelectionHaptic()
                    vm.triggerMultiViewFromPlayer(with: channel)
                }) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(isLandscape ? 12 : 8)
                        .modifier(GlassEffect(cornerRadius: 22, isSelected: true, accentColor: nil))
                }
                .buttonStyle(.plain)
                .disabled(timeshiftStartTime != nil)
                .opacity(timeshiftStartTime != nil ? 0.5 : 1.0)
            }

            // Fullscreen toggle — portrait only (in landscape we're already fullscreen)
            if !isLandscape {
                Button(action: {
                    ChannelViewModel.shared.triggerSelectionHaptic()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isFullscreenInPortrait.toggle()
                    }
                }) {
                    Image(systemName: isFullscreenInPortrait
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(8)
                        .modifier(GlassEffect(cornerRadius: 22, isSelected: true, accentColor: nil))
                }
                .buttonStyle(.plain)
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
    
    func handleTimeshift(to date: Date, program: EPGProgram) {
        Task {
            let url = await viewModel?.buildTimeshiftURL(channel: channel, targetDate: date, program: program)
            
            await MainActor.run {
                if let finalURL = url {
                    timeshiftStartTime = date
                    playerManager.play(url: finalURL)
                } else {
                    if let original = URL(string: channel.streamURL) {
                        playerManager.play(url: original)
                    }
                }
            }
        }
    }
}
