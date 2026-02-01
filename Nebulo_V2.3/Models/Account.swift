import Foundation

struct Account: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var type: LoginType
    var url: String
    var username: String?
    var password: String?
    var externalEPGUrls: [String]
    var dateAdded: Date
    var isActive: Bool
    var stableID: Int
    
    var displayName: String {
        if !name.isEmpty { return name }
        return "Account \(url)"
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, type, url, username, password, externalEPGUrls, dateAdded, isActive, stableID
    }
    
    init(id: UUID = UUID(), name: String, type: LoginType, url: String, username: String? = nil, password: String? = nil, externalEPGUrls: [String] = [], dateAdded: Date = Date(), isActive: Bool = true, stableID: Int = 0) {
        self.id = id
        self.name = name
        self.type = type
        self.url = url
        self.username = username
        self.password = password
        self.externalEPGUrls = externalEPGUrls
        self.dateAdded = dateAdded
        self.isActive = isActive
        self.stableID = stableID
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try container.decodeIfPresent(LoginType.self, forKey: .type) ?? .xtream
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        externalEPGUrls = try container.decodeIfPresent([String].self, forKey: .externalEPGUrls) ?? []
        dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        stableID = try container.decodeIfPresent(Int.self, forKey: .stableID) ?? 0
    }
}