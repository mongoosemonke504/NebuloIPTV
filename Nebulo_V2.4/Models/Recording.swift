import Foundation

struct Recording: Identifiable, Codable, Hashable {
    let id: UUID
    let channelName: String
    let channelIcon: String?
    let streamURL: String
    var hasArchive: Bool = false
    let startTime: Date
    let endTime: Date
    let createdAt: Date
    
    // EPG Data preserved from time of recording
    var programTitle: String? = nil
    var programDescription: String? = nil
    
    var status: RecordingStatus
    var localFileName: String? // Filename in Documents/Recordings/
    
    var duration: TimeInterval {
        return endTime.timeIntervalSince(startTime)
    }
    
    enum RecordingStatus: String, Codable {
        case scheduled
        case recording
        case completed
        case failed
        case cancelled
    }
}
