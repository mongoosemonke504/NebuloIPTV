import Foundation

struct NameCleaner: Sendable {
    nonisolated static let globalGarbage: NSRegularExpression? = {
        // Corrected the escape sequences for \\s and escaped the pipe | character.
        try? NSRegularExpression(pattern: "^[A-Z]{2,3}\\s?[|]\\s?|^\\d+\\s?[:|]\\s?|(LIVE\\s?\\d*\\s?[:|-]?\\s?)|(HD\\s?:)|(FHD\\s?:)", options: .caseInsensitive)
    }()
    nonisolated static let suffixGarbage: NSRegularExpression? = {
        // Corrected the escape sequences for \\s and escaped the special characters [ ] ( )
        try? NSRegularExpression(pattern: "\\s?-\\s?ET\\s?/\\s?UK.*|\\s?\\[.*?\\]|\\s?\\(.*\\)", options: .caseInsensitive)
    }()
    
    nonisolated static func clean(_ name: String, isSports: Bool = false) -> String {
        var clean = name
        let range = NSRange(location: 0, length: clean.utf16.count)
        if let regex = globalGarbage { clean = regex.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "") }
        let currentRange = NSRange(location: 0, length: clean.utf16.count)
        if let regex = suffixGarbage { clean = regex.stringByReplacingMatches(in: clean, options: [], range: currentRange, withTemplate: "") }
        return clean.trimmingCharacters(in: CharacterSet(charactersIn: ":- |"))
    }
    nonisolated static func isLiveGameOrPPV(_ name: String) -> Bool {
        return name.localizedCaseInsensitiveContains(" vs ") || name.localizedCaseInsensitiveContains(" @ ") || name.localizedCaseInsensitiveContains(" v ") || name.localizedCaseInsensitiveContains("-vs-") || name.localizedCaseInsensitiveContains("ppv") || name.localizedCaseInsensitiveContains("ufc")
    }
}
