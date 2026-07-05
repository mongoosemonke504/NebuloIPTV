import Foundation
import Combine
import AVFoundation

class RecordingManager: NSObject, ObservableObject {
    static let shared = RecordingManager()
    
    @Published var recordings: [Recording] = []
    
    
    private var activeRecorders: [UUID: StreamRecorder] = [:]
    
    private let recordingsKey = "saved_recordings_v1"
    
    override init() {
        super.init()
        loadRecordings()
        restoreActiveRecordings()
    }
    
    private func restoreActiveRecordings() {
        let now = Date()
        for i in recordings.indices {
            let rec = recordings[i]
            if rec.status == .recording {
                if rec.endTime > now {
                    print("🔄 [RecordingManager] Restoring interrupted recording: \(rec.channelName)")
                    startRecording(rec)
                } else {
                    print("⚠️ [RecordingManager] Found stale recording: \(rec.channelName)")
                    finalizeStaleRecording(index: i)
                }
            } else if rec.status == .scheduled {
                if rec.endTime <= now {
                    // Entire window passed while the app was not running — nothing to record.
                    print("⚠️ [RecordingManager] Missed scheduled recording: \(rec.channelName)")
                    recordings[i].status = .failed
                    saveRecordings()
                } else if rec.startTime <= now {
                    // Inside the recording window — start immediately.
                    print("🔄 [RecordingManager] Starting overdue scheduled recording: \(rec.channelName)")
                    startRecording(rec)
                } else {
                    // Still in the future — re-arm the DispatchQueue timer (lost on kill).
                    let delay = rec.startTime.timeIntervalSince(now)
                    let capturedRec = rec
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.startRecording(capturedRec)
                    }
                }
            }
        }
    }
    
    private func finalizeStaleRecording(index: Int) {
        let rec = recordings[index]
        let filename = "\(rec.id.uuidString).ts"
        let url = getDocumentsDirectory().appendingPathComponent(filename)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        if size > 1024 * 1024 {
            recordings[index].status = .completed
            recordings[index].localFileName = filename
            saveRecordings()
            // Remux any stale .ts left from a previous crash so it gets a
            // seek table and switches to KSPlayer on next playback.
            remuxToMP4(tsFilename: filename, recordingID: rec.id)
        } else {
            recordings[index].status = .failed
            saveRecordings()
        }
    }
    
    func scheduleRecording(channel: StreamChannel, startTime: Date, endTime: Date, programTitle: String? = nil, programDescription: String? = nil, category: Recording.RecordingCategory = .other) {
        let recording = Recording(
            id: UUID(),
            channelName: channel.name,
            channelIcon: channel.icon,
            streamURL: channel.streamURL,
            hasArchive: channel.hasArchive,
            startTime: startTime,
            endTime: endTime,
            createdAt: Date(),
            programTitle: programTitle,
            programDescription: programDescription,
            status: .scheduled,
            localFileName: nil,
            category: category
        )
        
        recordings.append(recording)
        saveRecordings()
        
        
        let now = Date()
        if startTime <= now {
            startRecording(recording)
        } else {
            let delay = startTime.timeIntervalSince(now)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.startRecording(recording)
            }
        }
    }
    
    private func startRecording(_ recording: Recording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        
        
        if activeRecorders[recording.id] != nil { return }
        
        recordings[index].status = .recording
        saveRecordings()
        
        guard let url = URL(string: recording.streamURL) else {
            failRecording(recording, reason: "Invalid URL")
            return
        }

        let filename = "\(recording.id.uuidString).ts"
        let outputURL = getDocumentsDirectory().appendingPathComponent(filename)

        // ── No hijack ──────────────────────────────────────────────────────────
        // The recorder downloads HLS segments via its own URLSession; the player
        // can continue streaming the same channel in parallel without conflict.
        // Stopping the player here was the root cause of "stream stops on record".
        // ──────────────────────────────────────────────────────────────────────

        let recorder = StreamRecorder(streamURL: url, outputURL: outputURL)

        recorder.onCompletion = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self,
                      let idx = self.recordings.firstIndex(where: { $0.id == recording.id }) else { return }

                let fileURL = self.getDocumentsDirectory().appendingPathComponent(filename)
                let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0

                if size > 1024 * 1024 {
                    // Mark completed with the .ts file first so the recording is
                    // immediately playable (via VLC) while the remux runs.
                    self.recordings[idx].status = .completed
                    self.recordings[idx].localFileName = filename
                    // Capture the actual recorded length. A recording stopped
                    // early runs far shorter than its scheduled window, so the
                    // wall-clock elapsed since start is the real seekable length
                    // (clamped so it can never exceed the scheduled end). The
                    // exact value is refined from the MP4 once the remux runs.
                    let wall = Date().timeIntervalSince(recording.startTime)
                    let scheduled = recording.endTime.timeIntervalSince(recording.startTime)
                    self.recordings[idx].recordedDuration = max(1, min(wall, scheduled))
                    self.saveRecordings()
                    self.activeRecorders.removeValue(forKey: recording.id)

                    // Remux to MP4 in the background.  KSPlayer/AVPlayer will then
                    // give perfectly accurate scrubbing via the moov seek table.
                    self.remuxToMP4(tsFilename: filename, recordingID: recording.id)
                } else {
                    print("⚠️ Recording too small (\(size) bytes), marking as failed.")
                    self.recordings[idx].status = .failed
                    try? FileManager.default.removeItem(at: fileURL)
                    self.saveRecordings()
                    self.activeRecorders.removeValue(forKey: recording.id)
                }
            }
        }

        recorder.onError = { [weak self] error in
            DispatchQueue.main.async {
                print("Recording error: \(error)")
                self?.failRecording(recording, reason: error.localizedDescription)
                self?.activeRecorders.removeValue(forKey: recording.id)
            }
        }

        activeRecorders[recording.id] = recorder
        recorder.start()

        let timeUntilEnd = recording.endTime.timeIntervalSince(Date())
        if timeUntilEnd > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeUntilEnd) { [weak self] in
                self?.stopRecording(recording.id)
            }
        } else {
            stopRecording(recording.id)
        }
    }
    
    func stopRecording(_ id: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        
        if let recorder = activeRecorders[id] {
            recorder.stop() 
        } else {
            
            if recordings[index].status == .recording {
                recordings[index].status = .completed
                saveRecordings()
            }
        }
    }
    
    func renameRecording(_ recording: Recording, newName: String) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index].customTitle = newName
            saveRecordings()
        }
    }
    
    func deleteRecording(_ recording: Recording) {
        
        if activeRecorders[recording.id] != nil {
            stopRecording(recording.id)
        }
        
        
        if let path = recording.localFileName {
            let fileURL = getDocumentsDirectory().appendingPathComponent(path)
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        recordings.removeAll { $0.id == recording.id }
        saveRecordings()
    }
    
    private func failRecording(_ recording: Recording, reason: String) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index].status = .failed
            saveRecordings()
        }
        print("Recording failed: \(reason)")
    }
    
    func isRecording(channelName: String) -> Bool {
        let recordingStatus = recordings.contains(where: { $0.channelName == channelName && $0.status == .recording })
        print("RecordingManager: isRecording for \(channelName): \(recordingStatus)")
        return recordingStatus
    }
    
    func getActiveRecordingURL(for channel: StreamChannel) -> URL? {
        
        if let rec = recordings.first(where: { $0.channelName == channel.name && $0.status == .recording }) {
            let filename = "\(rec.id.uuidString).ts"
            let url = getDocumentsDirectory().appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
    
    
    private func loadRecordings() {
        if let data = UserDefaults.standard.data(forKey: recordingsKey),
           let decoded = try? JSONDecoder().decode([Recording].self, from: data) {
            recordings = decoded
        }
    }
    
    private func saveRecordings() {
        if let encoded = try? JSONEncoder().encode(recordings) {
            UserDefaults.standard.set(encoded, forKey: recordingsKey)
        }
    }
    
    // MARK: - MP4 remux

    /// Remuxes a completed .ts recording into .mp4 without re-encoding.
    ///
    /// Why: MPEG-TS doesn't carry a seek index.  The MP4 container has a moov
    /// atom that AVPlayer (KSPlayer) can use to seek instantly and accurately.
    /// No re-encoding means zero quality loss and a fast operation — typically
    /// 5-20 seconds for a 1-hour recording.
    ///
    /// On success:  localFileName is updated to the .mp4 path; the .ts is deleted.
    /// On failure:  the .ts is kept as-is and VLC continues to play it.
    private func remuxToMP4(tsFilename: String, recordingID: UUID) {
        let docsDir = getDocumentsDirectory()
        let tsURL   = docsDir.appendingPathComponent(tsFilename)
        let mp4Filename = tsFilename.replacingOccurrences(of: ".ts", with: ".mp4")
        let mp4URL  = docsDir.appendingPathComponent(mp4Filename)

        // Clean up any stale file from a previous failed attempt.
        try? FileManager.default.removeItem(at: mp4URL)

        let asset = AVURLAsset(url: tsURL)

        // Prefer passthrough (no transcode).  Fall back to high-quality preset
        // if the container or codec isn't compatible with passthrough.
        let supportedPresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let preset: String
        if supportedPresets.contains(AVAssetExportPresetPassthrough) {
            preset = AVAssetExportPresetPassthrough
        } else if supportedPresets.contains(AVAssetExportPresetHighestQuality) {
            preset = AVAssetExportPresetHighestQuality
        } else {
            print("⚠️ [RecordingManager] No compatible export preset for \(tsFilename). Keeping .ts.")
            return
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            print("⚠️ [RecordingManager] Could not create export session for \(tsFilename).")
            return
        }
        session.outputURL      = mp4URL
        session.outputFileType = .mp4

        print("🔄 [RecordingManager] Remuxing \(tsFilename) → \(mp4Filename) …")
        session.exportAsynchronously { [weak self] in
            guard let self else { return }
            switch session.status {
            case .completed:
                // Probe the remuxed MP4's real duration — reliable now that the
                // container has a moov atom — and store it as the seekable
                // truth, replacing the wall-clock estimate. This is what stops
                // the scrubber from running past the end of the recording.
                Task { [weak self] in
                    guard let self else { return }
                    let probed = (try? await AVURLAsset(url: mp4URL).load(.duration))?.seconds
                    await MainActor.run {
                        if let idx = self.recordings.firstIndex(where: { $0.id == recordingID }) {
                            self.recordings[idx].localFileName = mp4Filename
                            if let d = probed, d.isFinite, d > 0 {
                                self.recordings[idx].recordedDuration = d
                            }
                            self.saveRecordings()
                        }
                        try? FileManager.default.removeItem(at: tsURL)
                        print("✅ [RecordingManager] Remux complete: \(mp4Filename)")
                    }
                }
            case .failed:
                print("⚠️ [RecordingManager] Remux failed (\(session.error?.localizedDescription ?? "?")). Keeping .ts file.")
            default:
                break
            }
        }
    }

    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func getPlaybackURL(for recording: Recording) -> URL? {
        if let filename = recording.localFileName {
            let url = getDocumentsDirectory().appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return resolveFallbackURL(for: recording)
    }
    
    private func resolveFallbackURL(for recording: Recording) -> URL? {
        guard recording.hasArchive, let original = URL(string: recording.streamURL) else { return nil }
        let urlString = original.absoluteString
        
        
        if urlString.contains("/live/") {
            let durationMinutes = Int(recording.duration / 60)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd:HH-mm"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let startString = formatter.string(from: recording.startTime)
            
            let newString = urlString.replacingOccurrences(of: "/live/", with: "/timeshift/")
            if let lastSlash = newString.lastIndex(of: "/") {
                let prefix = newString[..<lastSlash]
                let idPart = newString[newString.index(after: lastSlash)...]
                let streamID = idPart.components(separatedBy: ".").first ?? String(idPart)
                
                
                let finalURLString = "\(prefix)/\(durationMinutes)/\(startString)/\(streamID).m3u8"
                return URL(string: finalURLString)
            }
        }
        return nil
    }
}
