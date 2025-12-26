import Foundation

// MARK: - EPG MODELS
struct EPGProgram: Identifiable, Codable, Sendable {
    var id = UUID()
    let channelID: String
    let title: String
    let start: Date
    let stop: Date
}

struct StreamChannel: Identifiable, Codable, Hashable, Equatable, Sendable {
    let id: Int; var name: String; var streamURL: String; let icon: String?; let categoryID: Int; var originalName: String? = nil
    var epgID: String? = nil
    enum CodingKeys: String, CodingKey { case id = "stream_id", name = "name", displayName = "stream_display_name", streamURL = "stream_url", icon = "stream_icon", categoryID = "category_id", epgID = "epg_channel_id" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeFlexibleID(forKey: .id)
        self.categoryID = try c.decodeFlexibleID(forKey: .categoryID)
        if let n = try? c.decode(String.self, forKey: .name) { self.name = n } else if let dn = try? c.decode(String.self, forKey: .displayName) { self.name = dn } else { self.name = "Unknown Channel" }
        self.streamURL = (try? c.decode(String.self, forKey: .streamURL)) ?? ""
        self.icon = try? c.decode(String?.self, forKey: .icon)
        self.epgID = try? c.decodeIfPresent(String.self, forKey: .epgID)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(streamURL, forKey: .streamURL)
        try container.encode(icon, forKey: .icon)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(epgID, forKey: .epgID)
    }
    nonisolated init(id: Int, name: String, streamURL: String, icon: String?, categoryID: Int, originalName: String?, epgID: String? = nil) {
        self.id = id; self.name = name; self.streamURL = streamURL; self.icon = icon; self.categoryID = categoryID; self.originalName = originalName; self.epgID = epgID
    }
}

struct StreamCategory: Identifiable, Codable, Hashable, Equatable, Sendable {
    let id: Int; var name: String; var isHidden: Bool; var order: Int
    enum CodingKeys: String, CodingKey { case id = "category_id", name = "category_name" }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeFlexibleID(forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.isHidden = false
        self.order = Int.max
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
    }
    nonisolated init(id: Int, name: String, isHidden: Bool = false, order: Int = 0) {
        self.id = id; self.name = name; self.isHidden = isHidden; self.order = order
    }
}

struct SportConfig: Identifiable, Codable, Hashable, Sendable { var id: String; var name: String; var keywords: [String]; var order: Int }
