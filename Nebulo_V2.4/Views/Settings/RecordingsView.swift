import SwiftUI
import AVKit
import MobileVLCKit
import Combine

struct RecordingsView: View {
    @ObservedObject var manager = RecordingManager.shared
    @State private var selectedRecording: Recording?
    var viewModel: ChannelViewModel? = nil
    var playAction: ((StreamChannel) -> Void)? = nil
    var onBack: (() -> Void)? = nil
    @Environment(\.dismiss) var dismiss
    
    @AppStorage("nebColor1") private var nebColor1 = "#AF52DE"; @AppStorage("nebColor2") private var nebColor2 = "#007AFF"; @AppStorage("nebColor3") private var nebColor3 = "#FF2D55"; @AppStorage("nebX1") private var nebX1 = 0.2; @AppStorage("nebY1") private var nebY1 = 0.2; @AppStorage("nebX2") private var nebX2 = 0.8; @AppStorage("nebY2") private var nebY2 = 0.3; @AppStorage("nebX3") private var nebX3 = 0.5; @AppStorage("nebY3") private var nebY3 = 0.8

    var body: some View {
        let c1 = Color(hex: nebColor1) ?? .purple
        let c2 = Color(hex: nebColor2) ?? .blue
        let c3 = Color(hex: nebColor3) ?? .pink
        
        ZStack {
            NebulaBackgroundView(color1: c1, color2: c2, color3: c3, point1: UnitPoint(x: nebX1, y: nebY1), point2: UnitPoint(x: nebX2, y: nebY2), point3: UnitPoint(x: nebX3, y: nebY3))
                .ignoresSafeArea()

            List {
                if manager.recordings.isEmpty {
                    Text("No recordings found.")
                        .foregroundColor(.white.opacity(0.7))
                        .padding()
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(manager.recordings.sorted(by: { $0.createdAt > $1.createdAt })) { recording in
                        Button(action: {
                            if recording.status == .recording {
                                if let channel = viewModel?.channels.first(where: { $0.streamURL == recording.streamURL || $0.name == recording.channelName }) {
                                    dismiss()
                                    playAction?(channel)
                                }
                            } else if recording.status == .completed {
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
    
    @ObservedObject var playerManager = NebuloPlayerEngine.shared
    @State private var showControls = true
    @State private var timer: AnyCancellable?
    
    // UI state for bridge
    @State private var isScrubbing = false
    @State private var draggingProgress: Double? = nil
    @State private var showSubtitlePanel = false
    @State private var showResolutionPanel = false
    @State private var showAspectRatioPanel = false
    @State private var showFullDescription = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Re-use the main bridge
            UnifiedPlayerViewBridge()
                .ignoresSafeArea()
            
                                            // Overlay controls (re-using PlayerControlsView for consistency)
                                            PlayerControlsView(
                                                playerManager: playerManager,
                                                channel: StreamChannel(
                                                    id: 0, 
                                                    name: recording.channelName, 
                                                    streamURL: recording.programDescription ?? "", // Hack: Pass desc here if needed or use originalName
                                                    icon: recording.channelIcon, 
                                                    categoryID: 0, 
                                                    originalName: recording.programTitle // Pass title here
                                                ),
                                                isRecordingPlayback: true,                                showControls: $showControls,
                                showSubtitlePanel: $showSubtitlePanel,
                                showResolutionPanel: $showResolutionPanel,
                                showAspectRatioPanel: $showAspectRatioPanel,
                                showFullDescription: $showFullDescription,
                                isScrubbing: $isScrubbing,
                                draggingProgress: $draggingProgress,
                                onDismiss: { dismiss() },
                                togglePlay: { 
                                    if playerManager.isPlaying { playerManager.pause() } else { playerManager.resume() }
                                    resetTimer()
                                },
                                toggleControls: { toggleControls() },
                                seekForward: { playerManager.seek(to: playerManager.currentTime + 15); resetTimer() },
                                seekBackward: { playerManager.seek(to: playerManager.currentTime - 15); resetTimer() }
                            )            
            if playerManager.isBuffering {
                ProgressView().tint(.white).scaleEffect(1.5)
            }
        }
        .onAppear {
            if let url = RecordingManager.shared.getPlaybackURL(for: recording) {
                playerManager.play(url: url)
                resetTimer()
            }
        }
        .onDisappear {
            playerManager.stop()
            timer?.cancel()
        }
    }
    
    func toggleControls() {
        withAnimation { showControls.toggle() }
        if showControls { resetTimer() }
    }
    
    func resetTimer() {
        timer?.cancel()
        timer = Just(()).delay(for: 4.0, scheduler: RunLoop.main).sink { _ in
            withAnimation { showControls = false }
        }
    }
}
