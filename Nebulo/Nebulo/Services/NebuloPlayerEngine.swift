import Foundation
import Combine
import UIKit
import SwiftUI
import MobileVLCKit
import AVFoundation
import MediaPlayer

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
    @Published public var availableSubtitles: [VideoSubtitle] = []
    @Published public var currentSubtitle: VideoSubtitle? = nil
    @Published public var activeCaption: String? = nil
    @Published public var currentResolution: String = ""
    @Published public var activeBackendName: String = "VLC" 
    @Published public var playbackFailed: Bool = false
    
    public let renderView = UIView()
    public let useNativeBridge = false
    
    private var vlcMediaPlayer: VLCMediaPlayer = VLCMediaPlayer()
    
    private var isInteractionSeeking = false
    private var pendingSeekWorkItem: DispatchWorkItem?
    private var userPaused = false
    
    public private(set) var currentURL: URL?
    
    public func toggleBackend() {
        // Only VLC backend is available
        print("⚠️ [NebuloEngine] Only VLC backend is available.")
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
    
    private var lastProgressCheckTime: Date?
    private var lastProgressValue: Double = -1
    
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
        setupVLC()
        setupAudioSession()
        setupRemoteTransportControls()
    }
    
    public func pauseAllMultiViewPlayers() {
        // MultiView players are managed separately in MultiViewScreen, but if any were attached here:
        // This function was mainly for the KSPlayer instances stored in the array.
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
    
    private func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetoothA2DP, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
    }
    
    public func play(url: URL) {
        setupAudioSession() 
        if let current = currentURL, current == url, (isPlaying || isBuffering) { return }
        self.currentURL = url
        stop()
        self.isBuffering = true
        self.userPaused = false
        self.playbackFailed = false
        
        self.lastProgressValue = -1
        self.lastProgressCheckTime = Date()
        
        playVLC(url: url)
    }
    
    public func pause() {
        userPaused = true
        lastPauseDate = Date()
        if vlcMediaPlayer.isPlaying { vlcMediaPlayer.pause() }
        isPlaying = false
    }
    
    public func resume() {
         setupAudioSession()
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
         if !vlcMediaPlayer.isPlaying { vlcMediaPlayer.play() }
         isPlaying = true
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
        
        DispatchQueue.main.async {
            self.play(url: url)
        }
    }
    
    public func stop() {
        vlcMediaPlayer.stop()
        vlcMediaPlayer.drawable = nil
        isPlaying = false; isBuffering = false; stopTicker(); currentTime = 0; duration = 0
    }
    
    public func seek(to time: Double) {
        self.currentTime = time; self.isInteractionSeeking = true
        pendingSeekWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.vlcMediaPlayer.time = VLCTime(int: Int32(time * 1000))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.isInteractionSeeking = false }
        }
        pendingSeekWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }
    public func prepareNextChannel(url: URL) {}
    
    private func playVLC(url: URL) {
        vlcMediaPlayer.drawable = renderView
        let media = VLCMedia(url: url)
        
        let autoBufferObj = UserDefaults.standard.object(forKey: "autoBuffer")
        let isAuto = (autoBufferObj as? Bool) ?? true
        
        var bufferMs: Int = 10000
        if !isAuto {
            let userTime = UserDefaults.standard.double(forKey: "bufferTime")
            if userTime > 0 { bufferMs = Int(userTime * 1000) } else { bufferMs = 10000 }
        }
        
        let userAgent = "com.apple.avfoundation.videoplayer (iPhone; iOS 17.5.1; Scale/3.00)"
        media.addOptions([
            "network-caching": bufferMs,
            "clock-jitter": 0,
            "clock-synchro": 0,
            "user-agent": userAgent
        ])
        
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
    }
    
    public func selectSubtitle(_ subtitle: VideoSubtitle) {
        currentSubtitle = subtitle
        vlcMediaPlayer.currentVideoSubTitleIndex = Int32(subtitle.index)
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
            let vSize = vlcMediaPlayer.videoSize
            let rSize = renderView.bounds.size
            
            if vSize.width > 0 && vSize.height > 0 && rSize.width > 0 && rSize.height > 0 {
                let widthScale = rSize.width / vSize.width
                let heightScale = rSize.height / vSize.height
                let targetScale = max(widthScale, heightScale)
                vlcMediaPlayer.scaleFactor = Float(targetScale)
            } else {
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
            let charArray = s.cString(using: .utf8)!
            charArray.withUnsafeBufferPointer { ptr in
               vlcMediaPlayer.videoAspectRatio = UnsafeMutablePointer<Int8>(mutating: ptr.baseAddress)
            }
        }
    }
}

extension NebuloPlayerEngine: VLCMediaPlayerDelegate {
    public func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        
        switch player.state {
        case .buffering:
            self.isBuffering = true
        case .playing:
            self.isBuffering = false
            self.isPlaying = true
        case .error:
            self.isBuffering = false
            print("❌ [NebuloEngine] VLC Error")
            if currentURL?.isFileURL == true {
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
