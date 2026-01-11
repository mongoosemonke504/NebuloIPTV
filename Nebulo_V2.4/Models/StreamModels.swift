import Foundation

// MARK: - EPG MODELS
struct EPGProgram: Identifiable, Codable, Sendable {
    var id = UUID()
    let channelID: String
    let title: String
    let description: String?
    let start: Date
    let stop: Date
}

struct StreamChannel: Identifiable, Codable, Hashable, Equatable, Sendable {
    var id: Int; var name: String; var streamURL: String; let icon: String?; var categoryID: Int; var originalName: String? = nil
    var epgID: String? = nil
    var hasArchive: Bool = false
    var originalID: Int? = nil // The ID from the provider (for API calls)
    var accountID: UUID? = nil // The source account
    
    // Optimization: Pre-computed search string
    nonisolated var searchNormalizedName: String { name.lowercased() }
    
    enum CodingKeys: String, CodingKey { 
        case id = "stream_id", name = "name", displayName = "stream_display_name", 
             streamURL = "stream_url", icon = "stream_icon", categoryID = "category_id", 
             epgID = "epg_channel_id", tvArchive = "tv_archive",
             originalID = "original_id_local", accountID = "account_id_local"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeFlexibleID(forKey: .id)
        self.categoryID = try c.decodeFlexibleID(forKey: .categoryID)
        if let n = try? c.decode(String.self, forKey: .name) { self.name = n } else if let dn = try? c.decode(String.self, forKey: .displayName) { self.name = dn } else { self.name = "Unknown Channel" }
        self.streamURL = (try? c.decode(String.self, forKey: .streamURL)) ?? ""
        self.icon = try? c.decode(String?.self, forKey: .icon)
        self.epgID = try? c.decodeIfPresent(String.self, forKey: .epgID)
        self.originalID = try? c.decodeIfPresent(Int.self, forKey: .originalID)
        self.accountID = try? c.decodeIfPresent(UUID.self, forKey: .accountID)
        
        if let archiveStr = try? c.decodeIfPresent(String.self, forKey: .tvArchive) {
            self.hasArchive = archiveStr == "1"
        } else if let archiveInt = try? c.decodeIfPresent(Int.self, forKey: .tvArchive) {
            self.hasArchive = archiveInt == 1
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(streamURL, forKey: .streamURL)
        try container.encode(icon, forKey: .icon)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(epgID, forKey: .epgID)
        try container.encode(hasArchive ? 1 : 0, forKey: .tvArchive)
        try container.encodeIfPresent(originalID, forKey: .originalID)
        try container.encodeIfPresent(accountID, forKey: .accountID)
    }
    nonisolated init(id: Int, name: String, streamURL: String, icon: String?, categoryID: Int, originalName: String?, epgID: String? = nil, hasArchive: Bool = false, originalID: Int? = nil, accountID: UUID? = nil) {
        self.id = id; self.name = name; self.streamURL = streamURL; self.icon = icon; self.categoryID = categoryID; self.originalName = originalName; self.epgID = epgID; self.hasArchive = hasArchive
        self.originalID = originalID; self.accountID = accountID
    }
    // Backward compatibility for linker
    nonisolated init(id: Int, name: String, streamURL: String, icon: String?, categoryID: Int, originalName: String?, epgID: String?) {
        self.id = id; self.name = name; self.streamURL = streamURL; self.icon = icon; self.categoryID = categoryID; self.originalName = originalName; self.epgID = epgID; self.hasArchive = false
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
