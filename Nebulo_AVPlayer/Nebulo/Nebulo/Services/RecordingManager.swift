import Foundation
import Combine

class RecordingManager: NSObject, ObservableObject {
    static let shared = RecordingManager()
    
    @Published var recordings: [Recording] = []
    
    
    // private var activeRecorders: [UUID: StreamRecorder] = [:] // Removed
    
    private let recordingsKey = "saved_recordings_v1"
    
    override init() {
        super.init()
        loadRecordings()
        // restoreActiveRecordings() // Disabled
    }
    
    private func restoreActiveRecordings() {
       // Disabled
    }
    
    private func finalizeStaleRecording(index: Int) {
       // Disabled
    }
    
    func scheduleRecording(channel: StreamChannel, startTime: Date, endTime: Date, programTitle: String? = nil, programDescription: String? = nil) {
        print("⚠️ [RecordingManager] Recording is disabled in this version.")
    }
    
    private func startRecording(_ recording: Recording) {
        print("⚠️ [RecordingManager] Recording is disabled.")
    }
    
    func stopRecording(_ id: UUID) {
       // No-op
    }
    
    func renameRecording(_ recording: Recording, newName: String) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index].customTitle = newName
            saveRecordings()
        }
    }
    
    func deleteRecording(_ recording: Recording) {
        if let path = recording.localFileName {
            let fileURL = getDocumentsDirectory().appendingPathComponent(path)
            try? FileManager.default.removeItem(at: fileURL)
        }
        recordings.removeAll { $0.id == recording.id }
        saveRecordings()
    }
    
    private func failRecording(_ recording: Recording, reason: String) {}
    
    func isRecording(channelName: String) -> Bool {
        return false
    }
    
    func getActiveRecordingURL(for channel: StreamChannel) -> URL? {
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
