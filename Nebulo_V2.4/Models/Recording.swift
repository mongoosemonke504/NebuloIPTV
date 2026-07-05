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
    var category: RecordingCategory = .other

    /// Actual recorded length in seconds, captured when the recording finishes
    /// (and refined from the remuxed MP4's real duration). Nil for legacy or
    /// still-in-progress recordings. A recording stopped early captures far
    /// less than its scheduled window, so using `endTime − startTime` there
    /// overstated the duration and let the scrubber seek past the end of the
    /// file — which hung the player. This value is the seekable truth.
    var recordedDuration: TimeInterval? = nil

    // MARK: - Computed

    var duration: TimeInterval {
        if let recorded = recordedDuration, recorded > 0 { return recorded }
        return endTime.timeIntervalSince(startTime)
    }

    var displayName: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        if let title = programTitle, !title.isEmpty { return title }
        return channelName
    }

    /// Reads the actual file size from disk (metadata only — fast).
    var fileSizeBytes: Int64 {
        guard let filename = localFileName else { return 0 }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent(filename)
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    // MARK: - Enums

    enum RecordingStatus: String, Codable {
        case scheduled
        case recording
        case completed
        case failed
        case cancelled
    }

    enum RecordingCategory: String, Codable, CaseIterable, Hashable {
        case sports
        case movies
        case tvShows
        case other

        var displayName: String {
            switch self {
            case .sports:  return "Sports"
            case .movies:  return "Movies"
            case .tvShows: return "TV"
            case .other:   return "Other"
            }
        }
    }
}
