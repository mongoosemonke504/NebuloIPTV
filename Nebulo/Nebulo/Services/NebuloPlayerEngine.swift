import Foundation
import Combine
import UIKit
import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer
// import FFmpegKit // Removed dependency

public class NebuloPlayerEngine: NSObject, ObservableObject {
    public static let shared = NebuloPlayerEngine()
    
    @Published public var isBuffering = false
    @Published public var isPlaying = false {
        didSet {
            updatePlaybackState(force: true)
        }
    }
    
    @Published public var currentQuality: VideoQuality = .auto
    @Published public var availableQualities: [VideoQuality] = VideoQuality.allCases
    @Published public var currentTime: Double = 0
    @Published public var duration: Double = 0
    @Published public var progress: Double = 0
    @Published public var availableSubtitles: [VideoSubtitle] = []
    @Published public var currentSubtitle: VideoSubtitle? = nil
    @Published public var activeCaption: String? = nil
    @Published public var currentResolution: String = ""
    @Published public var activeBackendName: String = "AVPlayer" // Changed from VLC
    @Published public var playbackFailed: Bool = false
    
    public let renderView = PlayerView() // Custom UIView subclass for Layer management
    public let useNativeBridge = true
    
    private var avPlayer: AVPlayer?
    private var avPlayerItem: AVPlayerItem?
    private var pipController: AVPictureInPictureController?
    private var timeObserver: Any?
    
    private var isInteractionSeeking = false
    private var userPaused = false
    
    public private(set) var currentURL: URL?
    
    public func toggleBackend() {
        print("⚠️ [NebuloEngine] Backend switching is disabled (AVPlayer Only).")
    }
    
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
        setupAudioSession()
        setupRemoteTransportControls()
        setupPiP()
    }
    
    private func setupPiP() {
        if pipController != nil { return }
        if AVPictureInPictureController.isPictureInPictureSupported(),
           let layer = renderView.layer as? AVPlayerLayer {
            pipController = AVPictureInPictureController(playerLayer: layer)
            if #available(iOS 14.2, *) {
                pipController?.canStartPictureInPictureAutomaticallyFromInline = true
            }
        }
    }
    
    public func pauseAllMultiViewPlayers() {}
    
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
    }
     
    public func updateNowPlayingMetadata(title: String, subtitle: String?, imageURL: String?) {
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        if let sub = subtitle { 
            nowPlayingInfo[MPMediaItemPropertyArtist] = sub 
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
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastInfoUpdateTime = now
    }
    
    private func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetoothA2DP, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
    }
    
    public func prepareNextChannel(url: URL) {
        // AVPlayer handles its own buffering; this is a no-op for now.
    }

    public func play(url: URL) {
        setupAudioSession()
        if let current = currentURL, current == url, (isPlaying || isBuffering) { return }
        self.currentURL = url
        stop()
        
        self.isBuffering = true
        self.userPaused = false
        self.playbackFailed = false
        
        let item = AVPlayerItem(url: url)
        self.avPlayerItem = item
        
        let player = AVPlayer(playerItem: item)
        self.avPlayer = player
        
        // Attach to render view
        renderView.player = player
        
        // Ensure PiP is ready
        setupPiP()
        
        // Observers
        item.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
        item.addObserver(self, forKeyPath: "playbackBufferEmpty", options: [.new], context: nil)
        item.addObserver(self, forKeyPath: "playbackLikelyToKeepUp", options: [.new], context: nil)
        
        player.play()
        self.isPlaying = true
        
        // Time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.handleTimeUpdate(time)
        }
    }
    
    public func pause() {
        userPaused = true
        avPlayer?.pause()
        isPlaying = false
    }
    
    public func resume() {
         setupAudioSession()
         userPaused = false 
         avPlayer?.play()
         isPlaying = true
    }
    
    public func stop() {
        if let item = avPlayerItem {
            item.removeObserver(self, forKeyPath: "status")
            item.removeObserver(self, forKeyPath: "playbackBufferEmpty")
            item.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
        }
        
        if let observer = timeObserver {
            avPlayer?.removeTimeObserver(observer)
            timeObserver = nil
        }
        
        avPlayer?.pause()
        avPlayer = nil
        avPlayerItem = nil
        renderView.player = nil
        
        isPlaying = false
        isBuffering = false
        currentTime = 0
        duration = 0
    }
    
    public func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
        avPlayer?.seek(to: cmTime)
    }
    
    private func handleTimeUpdate(_ time: CMTime) {
        self.currentTime = time.seconds
        if let dur = avPlayerItem?.duration.seconds, !dur.isNaN {
            self.duration = dur
        }
    }
    
    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath = keyPath else { return }
        
        if keyPath == "status" {
            if let item = avPlayerItem, item.status == .readyToPlay {
                // Ready
            } else if let item = avPlayerItem, item.status == .failed {
                print("❌ [NebuloEngine] AVPlayer Error: \(String(describing: item.error))")
                self.playbackFailed = true
            }
        } else if keyPath == "playbackBufferEmpty" {
            self.isBuffering = true
        } else if keyPath == "playbackLikelyToKeepUp" {
            self.isBuffering = false
            if !userPaused { self.isPlaying = true }
        }
    }
    
    public func selectSubtitle(_ subtitle: VideoSubtitle) {}
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
        guard let layer = renderView.layer as? AVPlayerLayer else { return }
        switch ratio {
        case .fill, .sixteenNine, .twentyOneNine: 
            layer.videoGravity = .resizeAspectFill
        default:
            layer.videoGravity = .resizeAspect
        }
    }
}

// Custom UIView to host AVPlayerLayer
public class PlayerView: UIView {
    public override static var layerClass: AnyClass { AVPlayerLayer.self }
    
    public var player: AVPlayer? {
        get { (layer as? AVPlayerLayer)?.player }
        set { (layer as? AVPlayerLayer)?.player = newValue }
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        (layer as? AVPlayerLayer)?.videoGravity = .resizeAspect
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}