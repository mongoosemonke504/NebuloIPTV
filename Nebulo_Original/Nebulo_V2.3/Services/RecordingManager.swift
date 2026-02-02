import Foundation
import Combine

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
        } else {
            recordings[index].status = .failed
        }
        saveRecordings()
    }
    
    func scheduleRecording(channel: StreamChannel, startTime: Date, endTime: Date, programTitle: String? = nil, programDescription: String? = nil) {
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
            localFileName: nil
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
        
        
        
        let player = NebuloPlayerEngine.shared
        var hijackedPlayer = false
        
        if let current = player.currentURL, (current.absoluteString == url.absoluteString || current.path == url.path) {
            print("🔀 [RecordingManager] Conflict detected! Switching player to local recording file...")
            player.stop() 
            hijackedPlayer = true
        }
        
        
        let recorder = StreamRecorder(streamURL: url, outputURL: outputURL)
        
        
        recorder.onCompletion = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, let idx = self.recordings.firstIndex(where: { $0.id == recording.id }) else { return }
                
                let url = self.getDocumentsDirectory().appendingPathComponent(filename)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                
                
                if size > 1024 * 1024 {
                    self.recordings[idx].status = .completed
                    self.recordings[idx].localFileName = filename
                } else {
                    print("⚠️ Recording too small (\(size) bytes), marking as failed.")
                    self.recordings[idx].status = .failed
                    try? FileManager.default.removeItem(at: url)
                }
                
                self.saveRecordings()
                self.activeRecorders.removeValue(forKey: recording.id)
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
        
        
        if hijackedPlayer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                print("▶️ [RecordingManager] Resuming player from local file: \(outputURL)")
                player.play(url: outputURL)
            }
        }
        
        
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
