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
    
    
    var programTitle: String? = nil
    var programDescription: String? = nil
    
    
    var customTitle: String? = nil
    
    var status: RecordingStatus
    var localFileName: String? 
    
    var duration: TimeInterval {
        return endTime.timeIntervalSince(startTime)
    }
    
    var displayName: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        if let title = programTitle, !title.isEmpty { return title }
        return channelName
    }
    
    enum RecordingStatus: String, Codable {
        case scheduled
        case recording
        case completed
        case failed
        case cancelled
    }
}
