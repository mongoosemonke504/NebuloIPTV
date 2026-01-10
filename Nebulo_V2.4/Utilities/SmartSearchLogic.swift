import Foundation

struct SmartSearchLogic {
    nonisolated static func tokenize(_ text: String) -> [String] {
        return text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    
    nonisolated static func isBanner(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("header") || lower.contains("marker") || lower.contains("separator") || lower.contains("****")
    }
}
