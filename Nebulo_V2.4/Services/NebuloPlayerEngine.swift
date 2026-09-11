import Foundation
import Combine
import UIKit
import SwiftUI
import MobileVLCKit
import AVFoundation
import AVKit
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
    /// Last time the VLC subtitle/audio track lists were polled — see the
    /// note in `updateState()`.
    private var lastTrackPollTime: Date = .distantPast
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

    private var vlcMediaPlayer: VLCMediaPlayer = VLCMediaPlayer()
    private var pipController: AVPictureInPictureController?

    // VLC is the only playback backend. `.none` when nothing is loaded. (PiP
    // uses a separate short-lived AVPlayer; see the PiP section.)
    private enum ActiveBackend { case none, vlc }
    private var currentBackend: ActiveBackend = .none {
        didSet {
            activeBackendName = currentBackend == .vlc ? "VLC" : "None"
        }
    }
    private var isInteractionSeeking = false
    private var pendingSeekWorkItem: DispatchWorkItem?
    @Published public var userPaused = false
    private var unexpectedPauseCount = 0

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
        setupVLC()
        setupAudioSession()
        setupRemoteTransportControls()
        observeAppLifecycle()
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
     
    /// `artworkImage` wins over `imageURL` when both are given: the lock screen
    /// card for a live game is drawn in-app rather than fetched, so there is no
    /// URL to hand over.
    public func updateNowPlayingMetadata(title: String, subtitle: String?, imageURL: String?, artworkImage: UIImage? = nil) {
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        if let sub = subtitle { 
            nowPlayingInfo[MPMediaItemPropertyArtist] = sub 
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtist)
        }

        if let artworkImage {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in artworkImage }
        } else if let urlStr = imageURL, let url = URL(string: urlStr) {
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
        self.unexpectedPauseCount = 0
        stop()
        self.isBuffering = true
        self.userPaused = false
        self.playbackFailed = false
        // Clear per-stream audio-track list so the next stream re-detects fresh tracks
        self.availableAudioTracks = []
        self.currentAudioTrack = nil
        // …and let the first tick of the new stream poll immediately rather
        // than waiting out the throttle.
        self.lastTrackPollTime = .distantPast

        self.lastProgressValue = -1
        self.lastProgressCheckTime = Date()

        // VLC plays everything — live streams and local recordings (.ts and the
        // remuxed .mp4 alike). For local files, probe the duration via AVURLAsset
        // since VLC often reports -1 for a concatenated .ts until it has scanned
        // to the end.
        playVLC(url: url)
        if url.isFileURL {
            probeAndSetDuration(from: url)
        }
    }

    public func pause() {
        userPaused = true
        lastPauseDate = Date()
        if currentBackend == .vlc {
            if vlcMediaPlayer.isPlaying { vlcMediaPlayer.pause() }
            isPlaying = false
        }
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
        }
    }
    
    
    
    // MARK: - Returning to the app

    /// When the app went away, if it did.
    private var backgroundedAt: Date?
    /// Below this, a live stream is very likely still inside VLC's buffer and
    /// picks up on its own; past it, it is stale and only the stall watchdog
    /// would ever notice — twenty-five to thirty seconds later, which is the
    /// frozen picture you come back to.
    private static let staleAfterBackground: TimeInterval = 4

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.backgroundedAt = Date()
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadIfStaleAfterBackground()
        }
    }

    /// Re-opens a LIVE stream that went stale while the app was away.
    ///
    /// A live stream has no meaningful "resume": the buffer VLC was holding
    /// describes a moment that has passed, and it neither catches up nor
    /// errors — it just sits there. The only thing that noticed was the stall
    /// watchdog, on a half-minute timer.
    ///
    /// Deliberately narrow. It does nothing for a recording (a file resumes
    /// exactly where it was, and reloading would throw away the position),
    /// nothing while paused (you left it paused on purpose), nothing while
    /// Picture in Picture is up (that kept playing the whole time, so there is
    /// nothing stale to replace), and nothing for a short trip away.
    private func reloadIfStaleAfterBackground() {
        guard let away = backgroundedAt else { return }
        backgroundedAt = nil

        guard Date().timeIntervalSince(away) >= Self.staleAfterBackground,
              let url = currentURL,
              !url.isFileURL,
              !userPaused,
              pipController?.isPictureInPictureActive != true else { return }

        reloadCurrentStream()
    }

    /// Reopens the current URL from scratch, bypassing `play(url:)`'s
    /// "already on this URL" guard — which exists so re-selecting the channel
    /// you are watching doesn't restart it, and is exactly what stops a
    /// reload here.
    public func reloadCurrentStream() {
        guard let url = currentURL else { return }
        currentURL = nil
        play(url: url)
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
        print("🚨 [NebuloEngine] Buffer stuck for >20s or playback stalled. Reloading VLC...")
        stopBufferWatchdog()
        DispatchQueue.main.async {
            self.play(url: url)
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
    
    private func playVLC(url: URL) {
        currentBackend = .vlc

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
                } else if !isInteractionSeeking, self.currentTime != valSec {
                    self.currentTime = valSec
                }
            }
            if let media = vlcMediaPlayer.media, !externalTimeManagement {
                let length = media.length
                if let val = length.value {
                    let d = Double(truncating: val) / 1000.0
                    // Only accept a positive duration from VLC so we don't overwrite
                    // the value probed via AVURLAsset for files where VLC returns -1.
                    // Assigning an unchanged value still fires objectWillChange,
                    // and a live stream reports the same number twice a second
                    // forever — so re-render only on a real change.
                    if d > 0, self.duration != d { self.duration = d }
                }
            }
            // Guarded, because `isPlaying`'s didSet calls
            // `updatePlaybackState(force: true)` — which reads and writes
            // MPNowPlayingInfoCenter, a round trip to the media server.
            // Assigning the same `true` on every tick meant doing that twice a
            // second for the whole time something was playing, deliberately
            // skipping the two-second throttle sitting right below it. Now the
            // forced path runs on genuine play/pause transitions and the
            // throttled call below handles the periodic refresh.
            let playing = vlcMediaPlayer.isPlaying
            if self.isPlaying != playing { self.isPlaying = playing }
            self.updatePlaybackState()
            // Refresh on every count change, NOT just once: live TS streams
            // announce their closed-caption/teletext tracks seconds or
            // minutes into playback, and the old fill-once guard locked the
            // list before they ever appeared — which is why most streams
            // showed no subtitles.
            //
            // Every two seconds rather than every tick, though. Each pass
            // asks VLC for four bridged NSArrays and throws them away again,
            // and a track list that takes seconds to appear is in no hurry.
            let pollNow = Date()
            guard pollNow.timeIntervalSince(lastTrackPollTime) >= 2.0 else { return }
            lastTrackPollTime = pollNow

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
        }
    }

    public func selectSubtitle(_ subtitle: VideoSubtitle) {
        currentSubtitle = subtitle
        if currentBackend == .vlc {
            vlcMediaPlayer.currentVideoSubTitleIndex = Int32(subtitle.index)
        }
    }

    public func selectAudioTrack(_ track: VideoAudioTrack) {
        currentAudioTrack = track
        if currentBackend == .vlc {
            vlcMediaPlayer.currentAudioTrackIndex = Int32(track.index)
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
            // A local recording that errors has genuinely failed; a live
            // stream error gets one reload attempt via the buffer recovery.
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