import Foundation
import Combine
import UIKit
import SwiftUI
import MobileVLCKit
import KSPlayer
import AVFoundation
import AVKit
import MediaPlayer

public class NebuloKSVideoPlayerView: IOSVideoPlayerView {
    public var currentPlayingURL: URL?
    var onStateChange: ((KSPlayerState) -> Void)?
    var onTimeChange: ((TimeInterval, TimeInterval) -> Void)?
    var onFinish: ((Error?) -> Void)?
    
    var allowNativeControls = false

    public override func layoutSubviews() {
        super.layoutSubviews()
        if allowNativeControls { return }
        func hideControls(in view: UIView) {
            // Prevent hiding actual video layers
            if view.layer is CAMetalLayer || view.layer is AVPlayerLayer { return }
            let layerType = String(describing: type(of: view.layer))
            if layerType.contains("AVPlayerLayer") || layerType.contains("Metal") { return }
            
            let viewType = String(describing: type(of: view))
            // Only hide views that are clearly UI elements
            let uiClasses = ["UILabel", "UIImageView", "UIButton", "UISlider", "UISwitch", "UIStepper"]
            let isUIControl = uiClasses.contains(where: { viewType.contains($0) }) || 
                               viewType.contains("Control") || 
                               viewType.contains("Button")
            
            if isUIControl {
                view.alpha = 0
                view.isHidden = true
                view.isUserInteractionEnabled = false
            }
            for sub in view.subviews { hideControls(in: sub) }
        }
        for sub in subviews { hideControls(in: sub) }
    }

    public override func player(layer: KSPlayerLayer, state: KSPlayerState) {
        super.player(layer: layer, state: state)
        onStateChange?(state)
    }

    public override func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        super.player(layer: layer, currentTime: currentTime, totalTime: totalTime)
        onTimeChange?(currentTime, totalTime)
    }

    public override func player(layer: KSPlayerLayer, finish error: Error?) {
        super.player(layer: layer, finish: error)
        onFinish?(error)
    }
}

public class NebuloPlayerEngine: NSObject, ObservableObject {
    public static let shared = NebuloPlayerEngine()
    
    @Published public var isBuffering = false {
        didSet {
            if isBuffering {
                startBufferWatchdog()
            } else {
                stopBufferWatchdog()
            }
        }
    }
    @Published public var isPlaying = false {
        didSet {
            if isPlaying {
                isBuffering = false
                stopBufferWatchdog()
            }
            updatePlaybackState(force: true)
        }
    }
    
    private var bufferWatchdogTimer: Timer?
    private var bufferStartTime: Date?
    @Published public var currentQuality: VideoQuality = .auto
    @Published public var availableQualities: [VideoQuality] = VideoQuality.allCases
    @Published public var currentTime: Double = 0
    @Published public var duration: Double = 0
    @Published public var progress: Double = 0

    /// When true, the playback backends (VLC / KSPlayer) are NOT allowed to
    /// overwrite `currentTime` or `duration` from their internal clocks. Used
    /// for recording playback where:
    ///   • VLC reports TS time in broadcast-epoch PTS (huge unusable numbers)
    ///   • The true duration is already known from recording metadata
    /// The owning view supplies its own wall-clock time advance instead.
    @Published public var externalTimeManagement: Bool = false

    /// PTS offset (in seconds) captured from VLC when an external-time-managed
    /// recording first starts playing. Recording TS files keep their original
    /// broadcast PCR/PTS timestamps, so VLC's "time 0" is actually e.g. 90,000s
    /// since some broadcast epoch. Without compensating for this offset, asking
    /// VLC to seek to "300 seconds" lands before the file's actual PTS range
    /// and the seek hangs forever buffering. We capture the offset on the
    /// first non-zero VLC time reading and add it to every seek target.
    public var externalTimeOffset: Double = 0
    @Published public var availableSubtitles: [VideoSubtitle] = []
    @Published public var currentSubtitle: VideoSubtitle? = nil
    /// True when at least one REAL track exists — VLC's list always carries
    /// a "Disable" entry (index -1), which alone shouldn't light up the
    /// subtitles button.
    public var hasSelectableSubtitles: Bool {
        availableSubtitles.contains { $0.index >= 0 }
    }
    @Published public var activeCaption: String? = nil
    @Published public var currentResolution: String = ""
    @Published public var activeBackendName: String = "None" 
    @Published public var playbackFailed: Bool = false
    
    /// Layout-aware container: Fill/Stretch depend on the screen's current
    /// shape, so a size change (rotation, split-mode toggle) re-applies the
    /// active aspect mode instead of leaving a stale crop.
    public final class PlayerRenderView: UIView {
        var onLayoutSizeChange: (() -> Void)?
        private var lastSize: CGSize = .zero
        public override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != lastSize {
                lastSize = bounds.size
                onLayoutSizeChange?()
            }
        }
    }

    public let renderView = PlayerRenderView()
    public let useNativeBridge = false
    
    public var multiViewPlayers: [NebuloKSVideoPlayerView] = []
    
    private var vlcMediaPlayer: VLCMediaPlayer = VLCMediaPlayer()
    private var ksPlayerView = NebuloKSVideoPlayerView()
    private var pipController: AVPictureInPictureController?

    private enum ActiveBackend { case none, ksplayer, vlc }
    private var currentBackend: ActiveBackend = .none {
        didSet {
            switch currentBackend {
            case .ksplayer: activeBackendName = "KSPlayer"
            case .vlc: activeBackendName = "VLC"
            case .none: activeBackendName = "None"
            }
        }
    }
    private var isInteractionSeeking = false
    private var pendingSeekWorkItem: DispatchWorkItem?
    private var playerConstraints: [NSLayoutConstraint] = []
    @Published public var userPaused = false
    private var triedFallback = false
    private var ksPlayerRetryCount = 0
    private var unexpectedPauseCount = 0
    private let maxKSPlayerRetries = 10 
    
    public private(set) var currentURL: URL?
    
    public func toggleBackend() {
        guard let url = currentURL else { return }
        
        if currentBackend == .ksplayer {
            
            print("🔄 [NebuloEngine] Manually switching to VLC...")
            ksPlayerView.pause()
            ksPlayerView.removeFromSuperview()
            playVLC(url: url)
        } else if currentBackend == .vlc {
            
            if let streamURLString = currentURL?.absoluteString, 
               RecordingManager.shared.recordings.contains(where: { $0.streamURL == streamURLString && $0.status == .recording }) {
                print("⚠️ [NebuloEngine] Cannot switch to KSPlayer while recording.")
                return
            }
            
            print("🔄 [NebuloEngine] Manually switching to KSPlayer...")
            vlcMediaPlayer.stop()
            vlcMediaPlayer.drawable = nil
            if attemptKSPlayerPlayback(url: url) {
                currentBackend = .ksplayer
            }
        }
    }
    public var onRequestTimeshiftURL: ((Date) async -> URL?)?
    private var lastPauseDate: Date?
    
    public var currentTimeshiftStartDate: Date? {
        guard let url = currentURL else { return nil }
        let urlString = url.absoluteString
        if let range = urlString.range(of: "\\d{4}-\\d{2}-\\d{2}:\\d{2}-\\d{2}", options: .regularExpression) {
            let dateString = String(urlString[range])
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd:HH-mm"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter.date(from: dateString)
        }
        return nil
    }
    
    private var timeObserverTimer: Timer?
    private var localStartUnmuteTimer: Timer?


    private var lastProgressCheckTime: Date?
    private var lastProgressValue: Double = -1
    
    public enum VideoQuality: String, CaseIterable, Identifiable {
        case auto = "Auto", high = "1080p", medium = "720p", low = "480p"
        public var id: String { rawValue }
    }
    /// Fit letterboxes at the source ratio; Fill crops to cover the whole
    /// screen; Stretch distorts to cover it; 16:9 / 4:3 force the video
    /// into that shape.
    public enum VideoAspectRatio: String, CaseIterable, Identifiable {
        case `default` = "Fit", fill = "Fill", stretch = "Stretch", sixteenNine = "16:9", fourThree = "4:3"
        public var id: String { rawValue }
    }
    public struct VideoSubtitle: Identifiable, Hashable {
        public let id: String, name: String, index: Int
    }
    public struct VideoAudioTrack: Identifiable, Hashable {
        public let id: String, name: String, index: Int
    }

    @Published public var availableAudioTracks: [VideoAudioTrack] = []
    @Published public var currentAudioTrack: VideoAudioTrack? = nil

    @Published public var currentAspectRatio: VideoAspectRatio = .default
    
    override init() {
        super.init()
        renderView.insetsLayoutMarginsFromSafeArea = false
        renderView.preservesSuperviewLayoutMargins = false
        // Fill overflows the container by design — never paint outside it.
        renderView.clipsToBounds = true
        setupKSPlayer()
        setupMultiViewPlayers()
        setupVLC()
        setupAudioSession()
        setupRemoteTransportControls()
        renderView.onLayoutSizeChange = { [weak self] in
            guard let self else { return }
            // VLC's fill/stretch bake the container's shape into a crop or
            // aspect string — recompute for the new shape. (KSPlayer's
            // constraints adapt on their own.)
            if self.currentBackend == .vlc,
               self.currentAspectRatio == .fill || self.currentAspectRatio == .stretch {
                self.applyAspectRatio(self.currentAspectRatio)
            }
            self.pipAVLayer?.frame = self.renderView.bounds
        }
        setupPiPLifecycleObservers()
    }

    /// iOS only auto-starts PiP if the side player is actually PLAYING at
    /// the instant the app backgrounds — a quietly-stalled one means the
    /// float never appears. These hooks keep the handoff honest at the
    /// moments that matter.
    private func setupPiPLifecycleObservers() {
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let side = self.pipAVPlayer, !self.isPiPSessionActive else { return }
            if self.currentBackend == .vlc && self.isPlaying {
                // Last chance before the auto-PiP eligibility check.
                if side.timeControlStatus != .playing { side.play() }
            } else {
                // The user paused (or playback is gone) — a surprise PiP
                // window would be wrong, and a playing side player is
                // exactly what would summon one.
                side.pause()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.vlcSuspendedForPiP && !self.isPiPSessionActive && self.currentBackend == .vlc {
                // PiP was closed while backgrounded; the on-screen player
                // is still up, so reconnect VLC now that we're visible.
                self.vlcSuspendedForPiP = false
                self.vlcMediaPlayer.play()
                if self.pipAVPlayer == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                        self?.armAutoPiP()
                    }
                }
            } else if let side = self.pipAVPlayer, !self.isPiPSessionActive,
                      self.currentBackend == .vlc, self.isPlaying,
                      side.timeControlStatus != .playing {
                // Re-arm the hidden channel paused on the way out.
                side.play()
            }
        }
    }
    
    private func setupMultiViewPlayers() {
        ksPlayerView.allowNativeControls = false
        ksPlayerView.backgroundColor = .black
        multiViewPlayers.append(ksPlayerView)
        for _ in 1..<4 {
            let player = NebuloKSVideoPlayerView() 
            player.allowNativeControls = false
            player.backgroundColor = .black
            multiViewPlayers.append(player)
        }
    }
    
    public func pauseAllMultiViewPlayers() {
        for player in multiViewPlayers { player.pause() }
    }
    
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in 
            self?.resume()
            return .success 
        }
        
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in 
            self?.pause()
            return .success 
        }
        
        
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying { self.pause() } else { self.resume() }
            return .success
        }
        
        
        commandCenter.seekBackwardCommand.isEnabled = true
        commandCenter.seekBackwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.seek(to: self.currentTime - 15)
            return .success
        }
        
        
        commandCenter.seekForwardCommand.isEnabled = true
        commandCenter.seekForwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.seek(to: self.currentTime + 15)
            return .success
        }
    }
     
    public func updateNowPlayingMetadata(title: String, subtitle: String?, imageURL: String?) {
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        if let sub = subtitle { 
            nowPlayingInfo[MPMediaItemPropertyArtist] = sub 
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtist)
        }
        
        if let urlStr = imageURL, let url = URL(string: urlStr) {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                if let data = data, let image = UIImage(data: data) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    DispatchQueue.main.async {
                        var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
                        currentInfo[MPMediaItemPropertyArtwork] = artwork
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
                    }
                }
            }.resume()
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        updatePlaybackState(force: true)
    }
    
    private var lastInfoUpdateTime: Date?
    
    private func updatePlaybackState(force: Bool = false) {
        let now = Date()
        
        if !force, let last = lastInfoUpdateTime, now.timeIntervalSince(last) < 2.0 { return }
        
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        
        
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPMediaItemPropertyPlaybackDuration] = 0 
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastInfoUpdateTime = now
    }
    
    private func setupVLC() { vlcMediaPlayer.delegate = self }
    
    private func setupKSPlayer() {
        ksPlayerView.onStateChange = { [weak self] state in self?.handleKSPlayerState(state) }
        ksPlayerView.onTimeChange = { [weak self] current, total in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.isInteractionSeeking { return }
                if current > 0 && current != self.currentTime {
                    if self.isBuffering { self.isBuffering = false }
                    if !self.isPlaying { self.isPlaying = true }
                }
                if !self.externalTimeManagement {
                    self.currentTime = current
                    self.duration = total
                }

                self.updatePlaybackState()
            }
        }
        ksPlayerView.onFinish = { [weak self] error in if error != nil { self?.handleKSPlayerError() } }
        
        KSOptions.isAutoPlay = true
        KSOptions.isSecondOpen = true 
        KSOptions.maxBufferDuration = 100.0 
        KSOptions.preferredForwardBufferDuration = 3.0
        KSOptions.isAccurateSeek = false
        
        ksPlayerView.allowNativeControls = useNativeBridge
    }
    
    private func setupAudioSession() {
        // NON-mixable on purpose: a session with .mixWithOthers is treated
        // as secondary audio and never becomes the system's "Now Playing"
        // app — which made the lock-screen / Dynamic Island media card only
        // show up sporadically during background playback.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetoothA2DP])
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
    }
    
    public func play(url: URL) {
        setupAudioSession()
        if let current = currentURL, current == url, (isPlaying || isBuffering) { return }
        self.currentURL = url
        self.ksPlayerRetryCount = 0
        self.unexpectedPauseCount = 0
        stop()
        self.isBuffering = true
        self.userPaused = false
        self.playbackFailed = false
        self.triedFallback = false
        // Clear per-stream audio-track list so the next stream re-detects fresh tracks
        self.availableAudioTracks = []
        self.currentAudioTrack = nil
        
        self.lastProgressValue = -1
        self.lastProgressCheckTime = Date()
        
        // Local file routing:
        //  • .mp4  → KSPlayer (AVPlayer). MP4 has a moov atom seek table so
        //            scrubbing is instant and accurate. No crashes.
        //  • .ts   → VLC. Concatenated TS files lack a seek index and KSPlayer's
        //            FFmpeg backend (MEPlayerItem) crashes with EXC_BAD_ACCESS when
        //            the recording file handle is closed while it's still open.
        //            VLC handles both conditions gracefully.
        if url.isFileURL {
            if url.pathExtension.lowercased() == "mp4" {
                _ = attemptKSPlayerPlayback(url: url)
                currentBackend = .ksplayer
            } else {
                playVLC(url: url)
                // VLC often reports duration = -1 for concatenated .ts files until it
                // has scanned to the end. Probe via AVURLAsset (which reads the TS
                // container header) so the scrub bar has a valid total-time immediately.
                probeAndSetDuration(from: url)
            }
            return
        }
        
        
        let defaultEngine = UserDefaults.standard.string(forKey: "defaultPlayerEngine") ?? "VLC"
        if defaultEngine == "KSPlayer" {
            attemptKSPlayerPlayback(url: url); currentBackend = .ksplayer; return
        }
        
        playVLC(url: url)
    }
    
    public func pause() {
        userPaused = true
        lastPauseDate = Date()
        if currentBackend == .vlc {
            if vlcMediaPlayer.isPlaying { vlcMediaPlayer.pause() }
            isPlaying = false
        } else if currentBackend == .ksplayer { ksPlayerView.pause() }
    }
    
    public func resume() {
         setupAudioSession()
         userPaused = false 
         if let pauseDate = lastPauseDate, -pauseDate.timeIntervalSinceNow > 15 {
             if let url = currentURL, !url.isFileURL, !url.absoluteString.contains("/timeshift/") {
                 Task {
                     if let tsURL = await onRequestTimeshiftURL?(pauseDate) {
                         await MainActor.run { self.play(url: tsURL) }
                         return
                     }
                     await MainActor.run { self.standardResume() }
                 }
                 return
             }
         }
         standardResume()
    }
    
    private func standardResume() {
          if currentBackend == .vlc {
             if !vlcMediaPlayer.isPlaying { vlcMediaPlayer.play() }
             isPlaying = true
         } else if currentBackend == .ksplayer {
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                 self.ksPlayerView.play()
             }
         }
    }
    
    
    
    private func startBufferWatchdog() {
        stopBufferWatchdog()
        
        
        bufferStartTime = Date()
        bufferWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isBuffering, let start = self.bufferStartTime else { return }
            let duration = Date().timeIntervalSince(start)
            
            
            if duration > 25.0 {
                self.handleStuckBuffer()
            }
        }
    }
    
    private func stopBufferWatchdog() {
        bufferWatchdogTimer?.invalidate()
        bufferWatchdogTimer = nil
        bufferStartTime = nil
    }
    
    private func handleStuckBuffer() {
        guard let url = currentURL, !userPaused else { return }
        print("🚨 [NebuloEngine] Buffer stuck for >20s or playback stalled.")
        stopBufferWatchdog()
        
        if currentBackend == .ksplayer {
            if ksPlayerRetryCount < maxKSPlayerRetries {
                print("⚠️ [NebuloEngine] KSPlayer stalled. Reloading...")
                ksPlayerRetryCount += 1
                _ = attemptKSPlayerPlayback(url: url)
            } else {
                print("⚠️ [NebuloEngine] KSPlayer unstable. Falling back to VLC...")
                let savedTime = currentTime
                
                DispatchQueue.main.async {
                    self.ksPlayerView.pause()
                    self.ksPlayerView.removeFromSuperview()
                    
                    self.playVLC(url: url)
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if self.currentBackend == .vlc {
                            self.vlcMediaPlayer.time = VLCTime(int: Int32(savedTime * 1000))
                        }
                    }
                }
            }
        } else {
            
            DispatchQueue.main.async {
                self.play(url: url)
            }
        }
    }
    
    public func stop() {
        // Never carry a startup mute into the next stream.
        localStartUnmuteTimer?.invalidate(); localStartUnmuteTimer = nil
        vlcMediaPlayer.audio?.isMuted = false
        // An active floating window outlives the on-screen player; its side
        // player is the one thing playback teardown must not touch. With the
        // player UI gone there's also no VLC session left to resume later.
        vlcSuspendedForPiP = false
        if !isPiPSessionActive { teardownPiPPlayer() }
        if currentBackend == .vlc { vlcMediaPlayer.stop(); vlcMediaPlayer.drawable = nil }
        else if currentBackend == .ksplayer { ksPlayerView.pause(); ksPlayerView.removeFromSuperview() }
        currentBackend = .none
        isPlaying = false; isBuffering = false; stopTicker(); currentTime = 0; duration = 0
        // A closed stream must not linger as "playing" on the Lock Screen /
        // Control Center. An active PiP window is the one exception.
        if !isPiPSessionActive {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }
    
    public func seek(to time: Double) {
        // Lazy-capture VLC's PTS offset if a user scrubs before the ticker has
        // had a chance to record it. Without this, the first scrub on a freshly
        // opened recording would seek with offset 0 and hang.
        if currentBackend == .vlc && externalTimeManagement && externalTimeOffset == 0 {
            if let val = vlcMediaPlayer.time.value {
                let valSec = Double(truncating: val) / 1000.0
                if valSec > 0 { externalTimeOffset = valSec }
            }
        }

        self.currentTime = time; self.isInteractionSeeking = true
        pendingSeekWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.currentBackend == .vlc {
                // For recordings, target = user-facing seconds + captured PTS offset
                // so VLC lands inside the file's actual PTS range.
                let targetSec = self.externalTimeManagement
                    ? (time + self.externalTimeOffset)
                    : time
                self.vlcMediaPlayer.time = VLCTime(int: Int32(targetSec * 1000))
            } else if self.currentBackend == .ksplayer {
                self.ksPlayerView.seek(time: TimeInterval(time), completion: { _ in })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.isInteractionSeeking = false }
        }
        pendingSeekWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }
    public func prepareNextChannel(url: URL) {}

    /// Reads the duration of a local file via AVURLAsset and publishes it.
    /// Used for .ts recordings where VLC reports –1 until it has read the whole file.
    private func probeAndSetDuration(from url: URL) {
        Task { [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else { return }
            let seconds = duration.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            await MainActor.run {
                // Only set if VLC hasn't already found a positive duration itself.
                if self.duration <= 0 { self.duration = seconds }
            }
        }
    }
    
    private func attemptKSPlayerPlayback(url: URL) -> Bool {
        DispatchQueue.main.async { [weak self] in
             guard let self = self else { return }
            
            
            self.ksPlayerView.pause()
            self.ksPlayerView.removeFromSuperview()
            
            let playerView = self.ksPlayerView
            playerView.backgroundColor = UIColor.black
            playerView.insetsLayoutMarginsFromSafeArea = false
            playerView.preservesSuperviewLayoutMargins = false
            
            self.renderView.addSubview(playerView)
            playerView.translatesAutoresizingMaskIntoConstraints = false
            
            
            if !self.playerConstraints.isEmpty { 
                NSLayoutConstraint.deactivate(self.playerConstraints)
                self.playerConstraints.removeAll() 
            }
            
            let newConstraints = [
                playerView.topAnchor.constraint(equalTo: self.renderView.topAnchor),
                playerView.bottomAnchor.constraint(equalTo: self.renderView.bottomAnchor),
                playerView.leadingAnchor.constraint(equalTo: self.renderView.leadingAnchor),
                playerView.trailingAnchor.constraint(equalTo: self.renderView.trailingAnchor)
            ]
            NSLayoutConstraint.activate(newConstraints)
            self.playerConstraints = newConstraints
            
            
            let resource = KSPlayerResource(url: url)
            self.ksPlayerView.set(resource: resource)
            self.ksPlayerView.currentPlayingURL = url
            self.applyAspectRatio(self.currentAspectRatio)
            
        }
        return true
    }
    
    private func playVLC(url: URL) {
        currentBackend = .vlc
        ksPlayerView.removeFromSuperview()
        
        DispatchQueue.main.async {
            self.renderView.isHidden = false
            self.renderView.alpha = 1.0
            self.vlcMediaPlayer.drawable = self.renderView
            let media = VLCMedia(url: url)
            
            let autoBufferObj = UserDefaults.standard.object(forKey: "autoBuffer")
            let isAuto = (autoBufferObj as? Bool) ?? true
            
            var bufferMs: Int = 10000
            if !isAuto {
                let userTime = UserDefaults.standard.double(forKey: "bufferTime")
                if userTime > 0 { bufferMs = Int(userTime * 1000) }
            }
            
            media.addOptions([
                "network-caching": bufferMs,
                "clock-jitter": 500,
                "clock-synchro": 0,
                "drop-late-frames": 1,
                "skip-frames": 1
            ])
            
            self.vlcMediaPlayer.media = media
            if url.isFileURL {
                // Recordings capture the raw stream mid-GOP: audio decodes from
                // the first packet, but video can't render until the first
                // keyframe — so sound runs ahead of a black screen for a second
                // or two. Keep audio muted until the video output exists so
                // picture and sound start together.
                self.vlcMediaPlayer.audio?.isMuted = true
                self.startLocalUnmutePoll()
            }
            self.vlcMediaPlayer.play()

            // Arm the auto-PiP side channel a few seconds in, once VLC has
            // its own buffers — closing the app then floats the video
            // automatically (live streams only, not recordings).
            if !url.isFileURL {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self, self.currentBackend == .vlc, self.currentURL == url else { return }
                    self.armAutoPiP()
                }
            }
        }
    }

    private func startLocalUnmutePoll() {
        localStartUnmuteTimer?.invalidate()
        let deadline = Date().addingTimeInterval(5)
        localStartUnmuteTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.vlcMediaPlayer.hasVideoOut || Date() > deadline {
                timer.invalidate()
                self.localStartUnmuteTimer = nil
                self.vlcMediaPlayer.audio?.isMuted = false
            } else {
                // VLC creates its audio output lazily; a mute set before the
                // aout exists is dropped, so re-assert until video appears.
                self.vlcMediaPlayer.audio?.isMuted = true
            }
        }
    }
    
    private func startTicker() {
        stopTicker()
        timeObserverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateState() }
    }
    
    private func stopTicker() { timeObserverTimer?.invalidate(); timeObserverTimer = nil }
    
    private func updateState() {
        
        if isPlaying && !userPaused && !isBuffering {
            let now = Date()
            
            
            if abs(currentTime - lastProgressValue) < 0.1 {
                if let lastCheck = lastProgressCheckTime, now.timeIntervalSince(lastCheck) > 30.0 {
                    print("🚨 [NebuloEngine] Playback stalled (time not advancing). Triggering Watchdog.")
                    handleStuckBuffer()
                    lastProgressCheckTime = now 
                }
            } else {
                
                lastProgressValue = currentTime
                lastProgressCheckTime = now
            }
        }
        
    
        if currentBackend == .vlc {
            let time = vlcMediaPlayer.time
            if let val = time.value {
                let valSec = Double(truncating: val) / 1000.0
                if externalTimeManagement {
                    // First time we see a nonzero PTS reading, snapshot it as
                    // the offset. Subsequent reads are ignored — external code
                    // (the recording view's wall-clock ticker) owns currentTime.
                    if externalTimeOffset == 0 && valSec > 0 {
                        externalTimeOffset = valSec
                    }
                } else if !isInteractionSeeking {
                    self.currentTime = valSec
                }
            }
            if let media = vlcMediaPlayer.media, !externalTimeManagement {
                let length = media.length
                if let val = length.value {
                    let d = Double(truncating: val) / 1000.0
                    // Only accept a positive duration from VLC so we don't overwrite
                    // the value probed via AVURLAsset for files where VLC returns -1.
                    if d > 0 { self.duration = d }
                }
            }
            self.isPlaying = vlcMediaPlayer.isPlaying
            self.updatePlaybackState()
            // Refresh on every count change, NOT just once: live TS streams
            // announce their closed-caption/teletext tracks seconds or
            // minutes into playback, and the old fill-once guard locked the
            // list before they ever appeared — which is why most streams
            // showed no subtitles.
            if let tracks = vlcMediaPlayer.videoSubTitlesNames as? [String],
               let indexes = vlcMediaPlayer.videoSubTitlesIndexes as? [Int],
               tracks.count == indexes.count {
                if availableSubtitles.count != tracks.count {
                    var subs: [VideoSubtitle] = []
                    for (i, name) in tracks.enumerated() { subs.append(VideoSubtitle(id: "vlc_\(indexes[i])", name: name, index: indexes[i])) }
                    self.availableSubtitles = subs
                }
                // Mirror VLC's actual selection so the UI never lies about
                // which track (or Disable) is active.
                let current = Int(vlcMediaPlayer.currentVideoSubTitleIndex)
                if currentSubtitle?.index != current {
                    self.currentSubtitle = availableSubtitles.first { $0.index == current }
                }
            }
            // Audio tracks (VLC)
            if let names = vlcMediaPlayer.audioTrackNames as? [String],
               let indexes = vlcMediaPlayer.audioTrackIndexes as? [Int],
               names.count == indexes.count {
                if availableAudioTracks.count != names.count {
                    var tracks: [VideoAudioTrack] = []
                    for (i, name) in names.enumerated() {
                        tracks.append(VideoAudioTrack(id: "vlc_\(indexes[i])", name: name, index: indexes[i]))
                    }
                    self.availableAudioTracks = tracks
                }
                let cur = Int(vlcMediaPlayer.currentAudioTrackIndex)
                if currentAudioTrack?.index != cur, let match = availableAudioTracks.first(where: { $0.index == cur }) {
                    self.currentAudioTrack = match
                }
            }
        } else if currentBackend == .ksplayer {

            if let player = ksPlayerView.playerLayer?.player {
                let tracks = player.tracks(mediaType: AVMediaType.subtitle)
                if !tracks.isEmpty && availableSubtitles.count != tracks.count {
                    var subs: [VideoSubtitle] = []
                    for (i, track) in tracks.enumerated() {
                        subs.append(VideoSubtitle(id: "ks_\(i)", name: track.name, index: i))
                    }
                    self.availableSubtitles = subs
                }
                // Audio tracks (KSPlayer)
                let audioTracks = player.tracks(mediaType: AVMediaType.audio)
                if !audioTracks.isEmpty && availableAudioTracks.count != audioTracks.count {
                    var tracks: [VideoAudioTrack] = []
                    for (i, t) in audioTracks.enumerated() {
                        tracks.append(VideoAudioTrack(id: "ks_\(i)", name: t.name, index: i))
                    }
                    self.availableAudioTracks = tracks
                }
                if currentAudioTrack == nil, let first = availableAudioTracks.first {
                    self.currentAudioTrack = first
                }
            }
        }
    }
    
    private func handleKSPlayerState(_ state: KSPlayerState) {
        DispatchQueue.main.async {
            switch state {
            case .buffering, .preparing: self.isBuffering = true
            case .error: self.isBuffering = false; self.handleKSPlayerError()
            case .paused:
                self.isBuffering = false
                if !self.userPaused {
                    self.unexpectedPauseCount += 1
                    if self.unexpectedPauseCount > 5 {
                        print("🚨 [NebuloEngine] KSPlayer stuck in pause loop. Performing hard reload...")
                        self.unexpectedPauseCount = 0
                        self.handleKSPlayerError()
                    } else {
                        print("⚠️ [NebuloEngine] KSPlayer paused unexpectedly (\(self.unexpectedPauseCount)). Attempting auto-resume...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if !self.userPaused { self.resume() }
                        }
                    }
                } else {
                    self.isPlaying = false
                    self.unexpectedPauseCount = 0
                }
            case .readyToPlay:
                self.isBuffering = false
                self.isPlaying = true
                self.ksPlayerRetryCount = 0
                self.unexpectedPauseCount = 0

                self.applyAspectRatio(self.currentAspectRatio)
            default: self.isBuffering = false; self.isPlaying = true
            }
        }
    }
    
    private func handleKSPlayerError() {
        guard currentBackend == .ksplayer, let url = currentURL else { return }
        
        if ksPlayerRetryCount < maxKSPlayerRetries {
            ksPlayerRetryCount += 1
            print("⚠️ [NebuloEngine] KSPlayer error/stall, performing hard reload (\(ksPlayerRetryCount)/\(maxKSPlayerRetries))...")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, self.currentBackend == .ksplayer else { return }
                
                _ = self.attemptKSPlayerPlayback(url: url)
            }
        } else {
            print("❌ [NebuloEngine] KSPlayer failed after \(maxKSPlayerRetries) retries.")
            self.playbackFailed = true
            self.ksPlayerView.pause()
        }
    }
    
    public func selectSubtitle(_ subtitle: VideoSubtitle) {
        currentSubtitle = subtitle
        if currentBackend == .vlc {
            vlcMediaPlayer.currentVideoSubTitleIndex = Int32(subtitle.index)
        } else if currentBackend == .ksplayer {
            if let player = ksPlayerView.playerLayer?.player {
                let tracks = player.tracks(mediaType: AVMediaType.subtitle)
                if subtitle.index < tracks.count {
                    let selectedTrack = tracks[subtitle.index]
                    player.select(track: selectedTrack)
                }
            }
        }
    }

    public func selectAudioTrack(_ track: VideoAudioTrack) {
        currentAudioTrack = track
        if currentBackend == .vlc {
            vlcMediaPlayer.currentAudioTrackIndex = Int32(track.index)
        } else if currentBackend == .ksplayer {
            if let player = ksPlayerView.playerLayer?.player {
                let tracks = player.tracks(mediaType: AVMediaType.audio)
                if track.index < tracks.count {
                    let selectedTrack = tracks[track.index]
                    player.select(track: selectedTrack)
                }
            }
        }
    }
    
    public func setQuality(_ quality: VideoQuality) { currentQuality = quality }
    
    public func setAspectRatio(_ ratio: VideoAspectRatio) {
        currentAspectRatio = ratio
        applyAspectRatio(ratio)
        // Re-assert once the current render pass has settled: VLC's video
        // output occasionally eats a geometry change applied mid-frame
        // (which is why a mode sometimes needed a second tap), and
        // KSPlayer's constraint swap can land before its layer exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.currentAspectRatio == ratio else { return }
            self.applyAspectRatio(ratio)
        }
    }
    
    public func toggleAspectRatio() {
        let all = VideoAspectRatio.allCases
        guard let idx = all.firstIndex(of: currentAspectRatio) else { return }
        let next = all[(idx + 1) % all.count]
        setAspectRatio(next)
    }

    /// Dedicated AVPlayer used ONLY for the system PiP window — VLC stays
    /// the playback engine, but its renderer can't feed PiP. While VLC
    /// plays a compatible (HLS) stream, this side player runs MUTED behind
    /// VLC's view with `canStartPictureInPictureAutomaticallyFromInline`
    /// set, so iOS floats the video automatically when the app closes.
    private var pipAVPlayer: AVPlayer?
    private var pipAVLayer: AVPlayerLayer?
    private var pipStatusObservation: NSKeyValueObservation?
    private var pipTimeControlObservation: NSKeyValueObservation?
    private var pipItemNotifTokens: [NSObjectProtocol] = []
    /// The stream the side player carries. Captured at arm time because the
    /// engine's currentURL is cleared when the on-screen player is dismissed,
    /// but a detached floating window still needs to reconnect after stalls.
    private var pipStreamURL: URL?
    private var lastPiPRecovery = Date.distantPast
    /// VLC was stopped (not paused) to hand its stream connection to the
    /// PiP player — most IPTV servers allow one connection per stream, so
    /// both can't run at once. Survives teardown so returning to the app
    /// knows to restart VLC.
    private var vlcSuspendedForPiP = false
    /// While hidden behind VLC the side player only needs to stay alive,
    /// not look good — cap it so it doesn't fight VLC for bandwidth.
    private let pipHiddenBitrateCap: Double = 1_200_000
    /// True from PiP start until it ends — dismissal paths check this so
    /// closing the player screen doesn't kill an active floating window.
    public private(set) var isPiPSessionActive = false
    /// A manual PiP-button tap arrived before the side player was ready.
    private var startPiPWhenReady = false

    /// Arms the auto-PiP side-channel for the current VLC stream. Safe to
    /// call repeatedly; no-ops when already armed or unsupported.
    public func armAutoPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              currentBackend == .vlc,
              let url = currentURL,
              pipAVPlayer == nil else { return }

        let item = AVPlayerItem(url: url)
        item.preferredPeakBitRate = pipHiddenBitrateCap
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = renderView.bounds
        // Behind VLC's drawable — rendering (required for auto-PiP) but
        // never visible.
        renderView.layer.insertSublayer(layer, at: 0)
        pipAVPlayer = player
        pipAVLayer = layer
        pipStreamURL = url
        attachPiPItemObservers(item)
        watchPiPTimeControl(player)

        pipStatusObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.pipStatusObservation = nil
                    player.play()
                    let controller = AVPictureInPictureController(playerLayer: layer)
                    controller?.canStartPictureInPictureAutomaticallyFromInline = true
                    controller?.delegate = self
                    self.pipController = controller
                    if self.startPiPWhenReady {
                        self.startPiPWhenReady = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            controller?.startPictureInPicture()
                        }
                    }
                case .failed:
                    // Raw TS/unsupported container — AVPlayer can't carry
                    // this stream; PiP simply stays unavailable for it.
                    print("⚠️ [NebuloEngine] PiP side-player failed: \(item.error?.localizedDescription ?? "unknown")")
                    self.teardownPiPPlayer()
                default:
                    break
                }
            }
        }
    }

    /// A stalled live stream never comes back with a plain play() — the
    /// server has dropped the connection. Reconnect by swapping in a fresh
    /// item at the live edge; the layer (and any active PiP window bound to
    /// it) carries straight on.
    private func recoverPiPSidePlayer() {
        guard let player = pipAVPlayer, let url = pipStreamURL else { return }
        guard Date().timeIntervalSince(lastPiPRecovery) > 3 else { return }
        lastPiPRecovery = Date()
        print("🔄 [NebuloEngine] PiP side-player reconnecting")
        let item = AVPlayerItem(url: url)
        item.preferredPeakBitRate = isPiPSessionActive ? 0 : pipHiddenBitrateCap
        attachPiPItemObservers(item)
        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func attachPiPItemObservers(_ item: AVPlayerItem) {
        pipItemNotifTokens.forEach { NotificationCenter.default.removeObserver($0) }
        pipItemNotifTokens = [
            // Momentary stalls at the live edge are routine and AVPlayer
            // digs itself out — reloading on every one is what made the
            // window flash grey. Only a stall that DOESN'T clear is a
            // dead connection.
            NotificationCenter.default.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
                self?.verifyThenRecoverPiP()
            },
            NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                self?.recoverPiPSidePlayer()
            },
            // A live stream "ending" means the playlist stopped updating —
            // nudge it first; reconnect only if it stays down.
            NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                self?.pipAVPlayer?.play()
                self?.verifyThenRecoverPiP(treatPausedAsDead: true)
            }
        ]
    }

    /// Waits a beat after a trouble signal, then reconnects only if the
    /// player genuinely isn't making progress. A deliberately-paused but
    /// healthy player is left alone (unless the caller says paused = dead,
    /// as after a live stream "ended").
    private func verifyThenRecoverPiP(treatPausedAsDead: Bool = false) {
        guard let player = pipAVPlayer else { return }
        let mark = player.currentTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, let player = self.pipAVPlayer else { return }
            let advanced = CMTimeGetSeconds(CMTimeSubtract(player.currentTime(), mark))
            let item = player.currentItem
            let itemDead = item == nil || item?.status == .failed || item?.error != nil
            switch player.timeControlStatus {
            case .playing where advanced > 0.5:
                return
            case .paused where !treatPausedAsDead && !itemDead:
                return
            default:
                self.recoverPiPSidePlayer()
            }
        }
    }

    private func watchPiPTimeControl(_ player: AVPlayer) {
        pipTimeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self, self.pipAVPlayer === p else { return }
                switch p.timeControlStatus {
                case .waitingToPlayAtSpecifiedRate:
                    // Buffering is normal; buffering that never ends is a
                    // dead connection. Give it 5s, then reconnect.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                        guard let self, let player = self.pipAVPlayer, player === p,
                              player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
                        self.recoverPiPSidePlayer()
                    }
                case .paused:
                    // Respect a deliberate pause from the PiP window's own
                    // button — only step in when the item itself is dead,
                    // which is why "play" appears to do nothing.
                    if self.isPiPSessionActive,
                       p.currentItem == nil || p.currentItem?.status == .failed || p.currentItem?.error != nil {
                        self.recoverPiPSidePlayer()
                    }
                default:
                    break
                }
            }
        }
    }

    /// Manual PiP trigger (the player's PiP button). Uses the pre-armed
    /// side player when it's ready; otherwise arms it and starts as soon
    /// as it is.
    public func enablePictureInPicture() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

        if currentBackend == .ksplayer {
            startSystemPiP()
            return
        }
        guard currentBackend == .vlc else { return }

        if let controller = pipController, let side = pipAVPlayer, pipStatusObservation == nil {
            // Hand the window a healthy, playing player — a stalled one
            // opens paused with a play button that does nothing.
            if side.currentItem == nil || side.currentItem?.status == .failed || side.currentItem?.error != nil {
                recoverPiPSidePlayer()
            } else if side.timeControlStatus != .playing {
                side.play()
            }
            controller.startPictureInPicture()
        } else {
            startPiPWhenReady = true
            armAutoPiP()
        }
    }

    /// Tears down the PiP side-player. Deliberately leaves
    /// `vlcSuspendedForPiP` alone — returning to the foreground uses it to
    /// know VLC still needs restarting.
    private func teardownPiPPlayer() {
        pipStatusObservation = nil
        pipTimeControlObservation = nil
        pipItemNotifTokens.forEach { NotificationCenter.default.removeObserver($0) }
        pipItemNotifTokens = []
        startPiPWhenReady = false
        isPiPSessionActive = false
        pipAVPlayer?.pause()
        pipAVLayer?.removeFromSuperlayer()
        pipAVPlayer = nil
        pipAVLayer = nil
        pipStreamURL = nil
        pipController = nil
    }

    /// Finds the AVPlayerLayer inside KSPlayer's view tree (it's nested a
    /// few layers deep, never the root layer) and starts PiP on it.
    private func startSystemPiP() {
        func findPlayerLayer(_ layer: CALayer) -> AVPlayerLayer? {
            if let player = layer as? AVPlayerLayer { return player }
            for sub in layer.sublayers ?? [] {
                if let found = findPlayerLayer(sub) { return found }
            }
            return nil
        }
        guard let avPlayerLayer = findPlayerLayer(ksPlayerView.layer) else {
            print("⚠️ [NebuloEngine] No AVPlayerLayer available for PiP (non-AVPlayer track).")
            return
        }
        if pipController?.isPictureInPictureActive ?? false {
            pipController?.stopPictureInPicture()
        }
        let controller = AVPictureInPictureController(playerLayer: avPlayerLayer)
        controller?.delegate = self
        self.pipController = controller
        controller?.startPictureInPicture()
    }

    private func applyAspectRatio(_ ratio: VideoAspectRatio) {
        // Fill/Stretch read the container's live bounds — main thread only.
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.applyAspectRatio(ratio) }
            return
        }
        if currentBackend == .vlc {

            vlcMediaPlayer.scaleFactor = 0
            vlcMediaPlayer.videoCropGeometry = nil
            vlcMediaPlayer.videoAspectRatio = nil

            // The container's current shape as a VLC geometry string.
            let bounds = renderView.bounds.size
            let screenAspect: String? = (bounds.width > 0 && bounds.height > 0)
                ? "\(Int(bounds.width)):\(Int(bounds.height))"
                : nil

            var aspectString: String? = nil
            var cropString: String? = nil

            switch ratio {
            case .default:
                break
            case .sixteenNine:
                aspectString = "16:9"
            case .fourThree:
                aspectString = "4:3"
            case .stretch:
                // Distort the frame to the screen's exact shape.
                aspectString = screenAspect
            case .fill:
                // Crop to the screen's shape — VLC scales the remainder
                // edge-to-edge with no distortion. Re-applied on every
                // container size change (see onLayoutSizeChange), so it
                // covers the screen in portrait AND landscape.
                cropString = screenAspect
            }

            if let s = aspectString {
                let chars = s.cString(using: .utf8)!
                chars.withUnsafeBufferPointer { ptr in
                    vlcMediaPlayer.videoAspectRatio = UnsafeMutablePointer<Int8>(mutating: ptr.baseAddress)
                }
            }
            if let s = cropString {
                let chars = s.cString(using: .utf8)!
                chars.withUnsafeBufferPointer { ptr in
                    vlcMediaPlayer.videoCropGeometry = UnsafeMutablePointer<Int8>(mutating: ptr.baseAddress)
                }
            }
        } else if currentBackend == .ksplayer {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                
                if self.ksPlayerView.superview != self.renderView {
                    return
                }
                
                NSLayoutConstraint.deactivate(self.playerConstraints); self.playerConstraints.removeAll()
                let view = self.ksPlayerView; let container = self.renderView; var newConstraints: [NSLayoutConstraint] = []; 
                
                var gravityString = AVLayerVideoGravity.resizeAspect
                
                switch ratio {
                case .fill:
                    gravityString = .resizeAspectFill
                    newConstraints = [
                        view.topAnchor.constraint(equalTo: container.topAnchor),
                        view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                        view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                    ]
                case .default: 
                    gravityString = .resizeAspect
                    newConstraints = [
                        view.topAnchor.constraint(equalTo: container.topAnchor),
                        view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                        view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                    ]
                case .sixteenNine:  
                    gravityString = .resize
                    let aspect = view.widthAnchor.constraint(equalTo: view.heightAnchor, multiplier: 16/9)
                    aspect.priority = .required
                    
                    newConstraints = [
                        view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                        view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                        view.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor),
                        view.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor),
                        aspect
                    ]
                    
                    
                    let wMax = view.widthAnchor.constraint(equalTo: container.widthAnchor); wMax.priority = .defaultHigh
                    let hMax = view.heightAnchor.constraint(equalTo: container.heightAnchor); hMax.priority = .defaultHigh
                    newConstraints.append(contentsOf: [wMax, hMax])
                    
                case .fourThree:  
                    gravityString = .resize
                    let aspect = view.widthAnchor.constraint(equalTo: view.heightAnchor, multiplier: 4/3)
                    aspect.priority = .required
                    
                    newConstraints = [
                        view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                        view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                        view.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor),
                        view.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor),
                        aspect
                    ]
                    
                    let wMax = view.widthAnchor.constraint(equalTo: container.widthAnchor); wMax.priority = .defaultHigh
                    let hMax = view.heightAnchor.constraint(equalTo: container.heightAnchor); hMax.priority = .defaultHigh
                    newConstraints.append(contentsOf: [wMax, hMax])

                case .stretch:
                     // Full-bleed with distortion: pin every edge and let
                     // the layer resize the frame into the container.
                     gravityString = .resize
                     newConstraints = [
                         view.topAnchor.constraint(equalTo: container.topAnchor),
                         view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                         view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                         view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                     ]
                }
                
                
                func setGravity(_ gravity: AVLayerVideoGravity, on view: UIView) {
                    if let layer = view.layer as? AVPlayerLayer { 
                        layer.videoGravity = gravity
                    } else {
                        
                         func findLayer(in layers: [CALayer]) -> AVPlayerLayer? {
                            for layer in layers {
                                if let pLayer = layer as? AVPlayerLayer { return pLayer }
                                if let sub = layer.sublayers, let found = findLayer(in: sub) { return found }
                            }
                            return nil
                        }
                        if let sublayers = view.layer.sublayers, let playerLayer = findLayer(in: sublayers) {
                             playerLayer.videoGravity = gravity
                        }
                    }
                }
                
                setGravity(gravityString, on: view)
                
                NSLayoutConstraint.activate(newConstraints)
                self.playerConstraints = newConstraints
                
                
                container.setNeedsLayout()
                container.layoutIfNeeded()
            }
        }
    }
}

extension NebuloPlayerEngine: VLCMediaPlayerDelegate {
    public func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer,
              currentBackend == .vlc else { return }

        switch player.state {
        case .buffering:
            self.isBuffering = true
        case .playing:
            self.isBuffering = false
            self.isPlaying = true
        case .error:
            self.isBuffering = false
            print("❌ [NebuloEngine] VLC Error")
            if triedFallback || currentURL?.isFileURL == true {
                self.playbackFailed = true
            } else {
                handleStuckBuffer()
            }
        case .ended, .stopped:
            self.isPlaying = false
        default:
            break
        }
    }
}

extension NebuloPlayerEngine: AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("📱 [NebuloEngine] PiP started")
        isPiPSessionActive = true
        // The floating window takes over. VLC is STOPPED, not paused —
        // a paused VLC still holds its stream connection, and single-
        // connection IPTV servers would starve the PiP player of the
        // very stream it's showing.
        if currentBackend == .vlc {
            vlcSuspendedForPiP = true
            vlcMediaPlayer.stop()
            // VLC tearing down its audio unit must not take the shared
            // session down with it.
            try? AVAudioSession.sharedInstance().setActive(true)
            pipAVPlayer?.currentItem?.preferredPeakBitRate = 0
            pipAVPlayer?.isMuted = false
            if pipAVPlayer?.timeControlStatus != .playing { pipAVPlayer?.play() }
        }
    }

    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("📱 [NebuloEngine] PiP stopped")
        isPiPSessionActive = false
        if currentBackend == .vlc {
            if UIApplication.shared.applicationState != .active {
                // The user closed the window from the background — that
                // means "stop", not "keep streaming invisibly".
                teardownPiPPlayer()
                return
            }
            // Back inline: side player re-mutes and keeps rendering (armed
            // for the next auto-PiP), VLC reconnects and takes the screen.
            pipAVPlayer?.isMuted = true
            pipAVPlayer?.currentItem?.preferredPeakBitRate = pipHiddenBitrateCap
            vlcSuspendedForPiP = false
            vlcMediaPlayer.play()
        } else {
            // The on-screen player is already gone — the floating window
            // was the last piece, so tear everything down.
            teardownPiPPlayer()
        }
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("⚠️ [NebuloEngine] PiP failed to start: \(error.localizedDescription)")
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // The window's "back to full screen" button — MainView re-presents
        // the full player if it was dismissed behind the float.
        NotificationCenter.default.post(name: .nebuloPiPRestore, object: nil)
        completionHandler(true)
    }
}