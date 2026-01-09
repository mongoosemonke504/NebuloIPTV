import SwiftUI
import AVKit
import MobileVLCKit

struct RecordingsView: View {
    @ObservedObject var manager = RecordingManager.shared
    @State private var selectedRecording: Recording?
    var onBack: (() -> Void)? = nil
    
    @AppStorage("nebColor1") private var nebColor1 = "#AF52DE"; @AppStorage("nebColor2") private var nebColor2 = "#007AFF"; @AppStorage("nebColor3") private var nebColor3 = "#FF2D55"; @AppStorage("nebX1") private var nebX1 = 0.2; @AppStorage("nebY1") private var nebY1 = 0.2; @AppStorage("nebX2") private var nebX2 = 0.8; @AppStorage("nebY2") private var nebY2 = 0.3; @AppStorage("nebX3") private var nebX3 = 0.5; @AppStorage("nebY3") private var nebY3 = 0.8

    var body: some View {
        let c1 = Color(hex: nebColor1) ?? .purple
        let c2 = Color(hex: nebColor2) ?? .blue
        let c3 = Color(hex: nebColor3) ?? .pink
        
        ZStack {
            NebulaBackgroundView(color1: c1, color2: c2, color3: c3, point1: UnitPoint(x: nebX1, y: nebY1), point2: UnitPoint(x: nebX2, y: nebY2), point3: UnitPoint(x: nebX3, y: nebY3))
                .ignoresSafeArea()

            List {
                // ... (rest of the list code remains same)
                if manager.recordings.isEmpty {
                    Text("No recordings found.")
                        .foregroundColor(.white.opacity(0.7))
                        .padding()
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(manager.recordings.sorted(by: { $0.createdAt > $1.createdAt })) { recording in
                        Button(action: {
                            if recording.status == .completed || recording.status == .recording {
                                selectedRecording = recording
                            }
                        }) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Rectangle().fill(Color.white.opacity(0.1))
                                    if let icon = recording.channelIcon {
                                        CachedAsyncImage(urlString: icon, size: CGSize(width: 50, height: 30))
                                    } else {
                                        Image(systemName: "film").foregroundColor(.white.opacity(0.5))
                                    }
                                }
                                .frame(width: 60, height: 40)
                                .cornerRadius(4)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recording.channelName)
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    
                                    HStack {
                                        Text(formatDate(recording.startTime))
                                        Text("•")
                                        Text(recording.status == .recording ? "In Progress" : recording.status.rawValue.capitalized)
                                            .foregroundColor(statusColor(recording.status))
                                    }
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                                }
                                
                                Spacer()
                                
                                if recording.status == .recording {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                        .foregroundColor(.red)
                                } else if recording.status == .completed {
                                    Image(systemName: "play.circle")
                                        .font(.title2)
                                        .foregroundColor(.white)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.white.opacity(0.2))
                        .swipeActions {
                            Button(role: .destructive) {
                                manager.deleteRecording(recording)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let onBack = onBack {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
        }
        .fullScreenCover(item: $selectedRecording) { recording in
            RecordingPlayerView(recording: recording)
        }
    }
    
    func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
    
    func statusColor(_ status: Recording.RecordingStatus) -> Color {
        switch status {
        case .completed: return .green
        case .recording: return .red
        case .failed: return .orange
        case .scheduled: return .blue
        case .cancelled: return .gray
        }
    }
}

struct RecordingPlayerView: View {
    let recording: Recording
    @Environment(\.dismiss) var dismiss
    @State private var playbackURL: URL?
    @State private var playbackError = false
    
    // VLC State
    @State private var isPlaying = true
    @State private var progress: Float = 0.0
    @State private var duration: Double = 0.0
    @State private var showControls = true
    @State private var isScrubbing = false
    @State private var controlsTimer: Timer?
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let url = playbackURL {
                VLCPlayerView(
                    url: url,
                    isPlaying: $isPlaying,
                    progress: $progress,
                    duration: $duration,
                    isScrubbing: $isScrubbing
                )
                .ignoresSafeArea()
            } else if playbackError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Recording Not Available")
                        .foregroundColor(.white)
                    Text("The file could not be found.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            } else {
                ProgressView()
            }
            
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture {
                    if !showControls {
                        withAnimation { showControls = true }
                        resetTimer()
                    }
                }
            
            if showControls && !playbackError {
                VLCControlsView(
                    isPlaying: $isPlaying,
                    progress: $progress,
                    isScrubbing: $isScrubbing,
                    duration: duration,
                    onSeek: { _ in resetTimer() },
                    onClose: { dismiss() },
                    onInteraction: { resetTimer() },
                    onTapBackground: {
                        showControls = false
                        controlsTimer?.invalidate()
                    }
                )
                .transition(.opacity)
            }
        }
        .onAppear {
            if let url = RecordingManager.shared.getPlaybackURL(for: recording) {
                playbackURL = url
                resetTimer()
            } else {
                playbackError = true
            }
        }
        .onDisappear {
            controlsTimer?.invalidate()
        }
    }
    
    func resetTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
            withAnimation { showControls = false }
        }
    }
}

struct VLCPlayerView: UIViewRepresentable {
    let url: URL
    @Binding var isPlaying: Bool
    @Binding var progress: Float
    @Binding var duration: Double
    @Binding var isScrubbing: Bool
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        
        let player = VLCMediaPlayer()
        player.drawable = view
        
        // Configure media
        let media = VLCMedia(url: url)
        // Add options to ensure hardware decoding and better format support
        media.addOptions([
            "network-caching": 1500,
            "clock-jitter": 0,
            "clock-synchro": 0
        ])
        player.media = media
        player.delegate = context.coordinator
        
        context.coordinator.player = player
        
        // Start playback with a slight delay to ensure the view is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            player.play()
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        guard let player = context.coordinator.player else { return }
        
        if isPlaying && !player.isPlaying {
            player.play()
        } else if !isPlaying && player.isPlaying {
            player.pause()
        }
        
        if !isScrubbing && duration > 0 {
            let playerTime = Double(player.time.intValue)
            let bindingTime = Double(progress) * duration
            
            // If Binding is far from Player Time, it means a Seek happened (User released slider)
            if abs(bindingTime - playerTime) > 1000 {
                player.time = VLCTime(int: Int32(bindingTime))
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, VLCMediaPlayerDelegate {
        var parent: VLCPlayerView
        var player: VLCMediaPlayer?
        
        init(_ parent: VLCPlayerView) {
            self.parent = parent
        }
        
        deinit {
            player?.stop()
            player?.drawable = nil
        }
        
        func mediaPlayerStateChanged(_ aNotification: Notification?) {
            guard let notification = aNotification, let player = notification.object as? VLCMediaPlayer else { return }
            if player.state == .ended || player.state == .stopped {
                parent.isPlaying = false
            }
        }
        
        func mediaPlayerTimeChanged(_ aNotification: Notification?) {
            guard let notification = aNotification, let player = notification.object as? VLCMediaPlayer, !parent.isScrubbing else { return }
            
            let time = Double(player.time.intValue)
            let len = Double(player.media?.length.intValue ?? 0)
            
            if len > 0 {
                parent.duration = len
                parent.progress = Float(time / len)
            }
        }
    }
}