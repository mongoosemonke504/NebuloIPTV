import Foundation
import Combine
import UIKit
import SwiftUI
import MobileVLCKit
import KSPlayer
import AVFoundation
import MediaPlayer

// MARK: - KSPlayer Helper Subclass
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
            if view.layer is CAMetalLayer || view.layer is AVPlayerLayer { return }
            let layerType = String(describing: type(of: view.layer))
            if layerType.contains("AVPlayerLayer") || layerType.contains("Metal") { return }
            let viewType = String(describing: type(of: view))
            if view is UILabel || view is UIImageView || viewType.contains("Control") || viewType.contains("Cover") || viewType.contains("Button") || viewType.contains("Slider") || viewType.contains("Time") || viewType.contains("Label") {
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
            updatePlaybackState()
        }
    }
    
    private var bufferWatchdogTimer: Timer?
    private var bufferStartTime: Date?
    @Published public var currentQuality: VideoQuality = .auto
    @Published public var availableQualities: [VideoQuality] = VideoQuality.allCases
    @Published public var currentTime: Double = 0
    @Published public var duration: Double = 0
    @Published public var progress: Double = 0
    @Published public var availableSubtitles: [VideoSubtitle] = []
    @Published public var currentSubtitle: VideoSubtitle? = nil
    @Published public var subtitleOffset: Double = 0.0 {
        didSet {
            if currentBackend == .vlc {
                vlcMediaPlayer.currentVideoSubTitleDelay = Int(subtitleOffset * 1000)
            } else if currentBackend == .ksplayer {
                if let player = ksPlayerView.playerLayer?.player {
                    let tracks = player.tracks(mediaType: AVMediaType.subtitle)
                    for track in tracks {
                        if track.isEnabled, let ffmpegTrack = track as? FFmpegAssetTrack {
                            ffmpegTrack.delay = subtitleOffset
                        }
                    }
                }
            }
        }
    }
    @Published public var activeCaption: String? = nil
    @Published public var currentResolution: String = ""
    @Published public var activeBackendName: String = "None" // New property
    @Published public var playbackFailed: Bool = false
    public let renderView = UIView()
    public let useNativeBridge = false
    
    public var multiViewPlayers: [NebuloKSVideoPlayerView] = []
    
    private var vlcMediaPlayer: VLCMediaPlayer = VLCMediaPlayer()
    private var ksPlayerView = NebuloKSVideoPlayerView() 
    
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
    private var userPaused = false
    private var triedFallback = false
    private var ksPlayerRetryCount = 0
    private let maxKSPlayerRetries = 3
    
    public private(set) var currentURL: URL?
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
    
    public enum VideoQuality: String, CaseIterable, Identifiable {
        case auto = "Auto", high = "1080p", medium = "720p", low = "480p"
        public var id: String { rawValue }
    }
    public enum VideoAspectRatio: String, CaseIterable, Identifiable {
        case `default` = "Default", fill = "Fill", twentyOneNine = "21:9", oneEightFive = "1.85:1", sixteenNine = "16:9", fourThree = "4:3"
        public var id: String { rawValue }
    }
    public struct VideoSubtitle: Identifiable, Hashable {
        public let id: String, name: String, index: Int
    }
    
    @Published public var currentAspectRatio: VideoAspectRatio = .default
    
    override init() {
        super.init()
        renderView.insetsLayoutMarginsFromSafeArea = false
        renderView.preservesSuperviewLayoutMargins = false
        setupKSPlayer()
        setupMultiViewPlayers()
        setupVLC()
        setupAudioSession()
        setupRemoteTransportControls()
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
        
        // Play
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in 
            self?.resume()
            return .success 
        }
        
        // Pause
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in 
            self?.pause()
            return .success 
        }
        
        // Toggle
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying { self.pause() } else { self.resume() }
            return .success
        }
        
        // Backward
        commandCenter.seekBackwardCommand.isEnabled = true
        commandCenter.seekBackwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.seek(to: self.currentTime - 15)
            return .success
        }
        
        // Forward
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
        updatePlaybackState()
    }
    
    private func updatePlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        
        // If duration is 0 or very large, it's likely a live stream
        if duration <= 0 || duration > 86400 {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
            info[MPMediaItemPropertyPlaybackDuration] = 0
        } else {
            info[MPNowPlayingInfoPropertyIsLiveStream] = false
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
                self.currentTime = current
                self.duration = total
                self.updatePlaybackState()
            }
        }
        ksPlayerView.onFinish = { [weak self] error in if error != nil { self?.handleKSPlayerError() } }
        KSOptions.isAutoPlay = true
        KSOptions.isSecondOpen = false
        KSOptions.maxBufferDuration = 60.0 
        KSOptions.preferredForwardBufferDuration = 5.0 // Reduced to 5s to prevent stalls
        ksPlayerView.allowNativeControls = useNativeBridge
    }
    
    private func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetoothA2DP])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    
    public func play(url: URL) {
        setupAudioSession() // Re-assert session on every play
        if let current = currentURL, current == url, (isPlaying || isBuffering) { return }
        self.currentURL = url
        self.ksPlayerRetryCount = 0 // Reset on new URL
        stop()
        self.isBuffering = true
        self.userPaused = false
        self.playbackFailed = false
        self.triedFallback = false
        if url.isFileURL { playVLC(url: url); return }
        if attemptKSPlayerPlayback(url: url) { currentBackend = .ksplayer; return }
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
         userPaused = false 
         if let pauseDate = lastPauseDate, -pauseDate.timeIntervalSinceNow > 15 {
             if let url = currentURL, !url.absoluteString.contains("/timeshift/") {
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
         } else if currentBackend == .ksplayer { ksPlayerView.play() }
    }
    
    // MARK: - Watchdog Logic
    
    private func startBufferWatchdog() {
        stopBufferWatchdog()
        bufferStartTime = Date()
        bufferWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isBuffering, let start = self.bufferStartTime else { return }
            let duration = Date().timeIntervalSince(start)
            
            // If buffering for more than 15 seconds, it's likely stuck
            if duration > 15.0 {
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
        print("🚨 [NebuloEngine] Buffer stuck for >7s, triggering automatic re-sync...")
        stopBufferWatchdog()
        
        // Re-play the current URL to force a fresh connection
        DispatchQueue.main.async {
            self.play(url: url)
        }
    }
    
    public func stop() {
        if currentBackend == .vlc { vlcMediaPlayer.stop(); vlcMediaPlayer.drawable = nil }
        else if currentBackend == .ksplayer { ksPlayerView.pause(); ksPlayerView.removeFromSuperview() }
        currentBackend = .none
        isPlaying = false; isBuffering = false; stopTicker(); currentTime = 0; duration = 0
    }
    
    public func seek(to time: Double) {
        self.currentTime = time; self.isInteractionSeeking = true
        pendingSeekWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.currentBackend == .vlc { self.vlcMediaPlayer.time = VLCTime(int: Int32(time * 1000)) }
            else if self.currentBackend == .ksplayer { self.ksPlayerView.seek(time: TimeInterval(time), completion: { _ in }) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.isInteractionSeeking = false }
        }
        pendingSeekWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }
    public func prepareNextChannel(url: URL) {}
    
    private func attemptKSPlayerPlayback(url: URL) -> Bool {
        DispatchQueue.main.async { [weak self] in
             guard let self = self else { return }
            let playerView = self.ksPlayerView
            if playerView.superview != self.renderView {
                playerView.backgroundColor = UIColor.black
                playerView.insetsLayoutMarginsFromSafeArea = false
                playerView.preservesSuperviewLayoutMargins = false
                self.renderView.addSubview(playerView)
                playerView.translatesAutoresizingMaskIntoConstraints = false
                 if !self.playerConstraints.isEmpty { NSLayoutConstraint.deactivate(self.playerConstraints); self.playerConstraints.removeAll() }
                let newConstraints = [
                    playerView.topAnchor.constraint(equalTo: self.renderView.topAnchor),
                    playerView.bottomAnchor.constraint(equalTo: self.renderView.bottomAnchor),
                    playerView.leadingAnchor.constraint(equalTo: self.renderView.leadingAnchor),
                    playerView.trailingAnchor.constraint(equalTo: self.renderView.trailingAnchor)
                ]
                NSLayoutConstraint.activate(newConstraints)
                self.playerConstraints = newConstraints
            }
            
            // Note: KSOptions.preferredForwardBufferDuration was set globally in setupKSPlayer
            let resource = KSPlayerResource(url: url)
            self.ksPlayerView.set(resource: resource)
            self.ksPlayerView.currentPlayingURL = url
            self.applyAspectRatio(self.currentAspectRatio)
            self.ksPlayerView.play()
        }
        return true
    }
    
    private func playVLC(url: URL) {
        currentBackend = .vlc
        ksPlayerView.removeFromSuperview()
        vlcMediaPlayer.drawable = renderView
        let media = VLCMedia(url: url)
        
        let autoBufferObj = UserDefaults.standard.object(forKey: "autoBuffer")
        let isAuto = (autoBufferObj as? Bool) ?? true
        
        var bufferMs: Int = 1500
        if !isAuto {
            let userTime = UserDefaults.standard.double(forKey: "bufferTime")
            if userTime > 0 { bufferMs = Int(userTime * 1000) } else { bufferMs = 2000 }
        }
        media.addOptions(["network-caching": bufferMs, "clock-jitter": 0, "clock-synchro": 0])
        vlcMediaPlayer.media = media
        vlcMediaPlayer.play()
        isBuffering = true; startTicker()
    }
    
    private func startTicker() {
        stopTicker()
        timeObserverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateState() }
    }
    
    private func stopTicker() { timeObserverTimer?.invalidate(); timeObserverTimer = nil }
    
    private func updateState() {
        if currentBackend == .vlc {
            let time = vlcMediaPlayer.time
            if let val = time.value, !isInteractionSeeking { self.currentTime = Double(truncating: val) / 1000.0 }
            if let media = vlcMediaPlayer.media {
                let length = media.length
                if let val = length.value { self.duration = Double(truncating: val) / 1000.0 }
            }
            self.isPlaying = vlcMediaPlayer.isPlaying
            self.updatePlaybackState()
            if availableSubtitles.isEmpty, let tracks = vlcMediaPlayer.videoSubTitlesNames as? [String] {
                if let indexes = vlcMediaPlayer.videoSubTitlesIndexes as? [Int], tracks.count == indexes.count {
                    var subs: [VideoSubtitle] = []
                    for (i, name) in tracks.enumerated() { subs.append(VideoSubtitle(id: "vlc_\(indexes[i])", name: name, index: indexes[i])) }
                    self.availableSubtitles = subs
                }
            }
        } else if currentBackend == .ksplayer {
            // KSPlayer track detection using AVMediaType
            if let player = ksPlayerView.playerLayer?.player {
                let tracks = player.tracks(mediaType: AVMediaType.subtitle)
                if !tracks.isEmpty && availableSubtitles.count != tracks.count {
                    var subs: [VideoSubtitle] = []
                    for (i, track) in tracks.enumerated() {
                        subs.append(VideoSubtitle(id: "ks_\(i)", name: track.name, index: i))
                    }
                    self.availableSubtitles = subs
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
                if !self.userPaused { self.resume() } else { self.isPlaying = false }
            case .readyToPlay: 
                self.isBuffering = false
                self.isPlaying = true
                self.ksPlayerRetryCount = 0 // Reset on success
                // Re-apply aspect ratio to ensure layer properties take effect
                self.applyAspectRatio(self.currentAspectRatio)
            default: self.isBuffering = false; self.isPlaying = true
            }
        }
    }
    
    private func handleKSPlayerError() {
        guard currentBackend == .ksplayer, let url = currentURL else { return }
        
        if ksPlayerRetryCount < maxKSPlayerRetries {
            ksPlayerRetryCount += 1
            print("⚠️ [NebuloEngine] KSPlayer error, retrying (\(ksPlayerRetryCount)/\(maxKSPlayerRetries))...")
            // Increased delay to 2.0s for better stability/recovery
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, self.currentBackend == .ksplayer else { return }
                self.ksPlayerView.play()
            }
        } else {
            print("❌ [NebuloEngine] KSPlayer failed after \(maxKSPlayerRetries) retries, falling back to VLC.")
            triedFallback = true
            ksPlayerRetryCount = 0
            ksPlayerView.pause(); ksPlayerView.removeFromSuperview(); playVLC(url: url)
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
                    if let ffmpegTrack = selectedTrack as? FFmpegAssetTrack {
                        ffmpegTrack.delay = subtitleOffset
                    }
                }
            }
        }
    }
    
    public func setQuality(_ quality: VideoQuality) { currentQuality = quality }
    
    public func setAspectRatio(_ ratio: VideoAspectRatio) {
        currentAspectRatio = ratio; applyAspectRatio(ratio)
    }
    
    public func toggleAspectRatio() {
        let all = VideoAspectRatio.allCases
        guard let idx = all.firstIndex(of: currentAspectRatio) else { return }
        let next = all[(idx + 1) % all.count]
        setAspectRatio(next)
    }
    
    private func applyAspectRatio(_ ratio: VideoAspectRatio) {
        if currentBackend == .vlc {
            // Default: Reset state to "Fit"
            vlcMediaPlayer.scaleFactor = 0
            vlcMediaPlayer.videoCropGeometry = nil
            vlcMediaPlayer.videoAspectRatio = nil
            
            var ratioString: String? = nil
            
            switch ratio {
            case .sixteenNine: ratioString = "16:9"
            case .fourThree: ratioString = "4:3"
            case .twentyOneNine: ratioString = "21:9"
            case .oneEightFive: ratioString = "185:100"
            case .fill:
                // Attempt Zoom-to-Fill (Crop) first
                let vSize = vlcMediaPlayer.videoSize
                let rSize = renderView.bounds.size
                
                if vSize.width > 0 && vSize.height > 0 && rSize.width > 0 && rSize.height > 0 {
                    let widthScale = rSize.width / vSize.width
                    let heightScale = rSize.height / vSize.height
                    let targetScale = max(widthScale, heightScale)
                    vlcMediaPlayer.scaleFactor = Float(targetScale)
                } else {
                    // Fallback: Stretch to Screen Ratio
                    if Thread.isMainThread {
                        let w = Int(renderView.bounds.width)
                        let h = Int(renderView.bounds.height)
                        if h > 0 { ratioString = "\(w):\(h)" }
                    } else {
                        DispatchQueue.main.sync {
                            let w = Int(renderView.bounds.width)
                            let h = Int(renderView.bounds.height)
                            if h > 0 { ratioString = "\(w):\(h)" }
                        }
                    }
                }
            case .default:
                break
            }
            
            if let s = ratioString {
                // Safer pointer handling
                let charArray = s.cString(using: .utf8)!
                charArray.withUnsafeBufferPointer { ptr in
                   vlcMediaPlayer.videoAspectRatio = UnsafeMutablePointer<Int8>(mutating: ptr.baseAddress)
                }
            }
        } else if currentBackend == .ksplayer {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // Ensure view is in hierarchy
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
                    
                    // Maximizing constraints (Low priority)
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

                case .twentyOneNine:
                     gravityString = .resize
                     let aspect = view.widthAnchor.constraint(equalTo: view.heightAnchor, multiplier: 21/9)
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

                case .oneEightFive:
                     gravityString = .resize
                     let aspect = view.widthAnchor.constraint(equalTo: view.heightAnchor, multiplier: 1.85)
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
                }
                
                // Helper to find and set gravity on AVPlayerLayer
                func setGravity(_ gravity: AVLayerVideoGravity, on view: UIView) {
                    if let layer = view.layer as? AVPlayerLayer {
                        layer.videoGravity = gravity
                    } else {
                        // Check sublayers recursively
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
                
                // Force Layout Update
                container.setNeedsLayout()
                container.layoutIfNeeded()
            }
        }
    }
}

// MARK: - VLC Delegate
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
            }
        case .ended, .stopped:
            self.isPlaying = false
        default:
            break
        }
    }
}
