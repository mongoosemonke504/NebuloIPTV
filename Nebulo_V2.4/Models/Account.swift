import Foundation

struct Account: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var type: LoginType
    var url: String
    var username: String?
    var password: String?
    var macAddress: String?
    var externalEPGUrls: [String] = []
    var dateAdded: Date = Date()
    var isActive: Bool = true
    var stableID: Int = 0 
    
    var displayName: String {
        if !name.isEmpty { return name }
        return "Account \(url)"
    }
}
