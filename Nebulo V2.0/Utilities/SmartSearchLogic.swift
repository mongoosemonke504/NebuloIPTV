import Foundation

struct SmartSearchLogic: Sendable {
    nonisolated static let blockers = ["univ", "university", "state", "st", "vs", "at", "the", "club", "fc", "team"]
    
    nonisolated static func isBanner(_ name: String) -> Bool {
        let symbols = CharacterSet(charactersIn: "✦●★|•▬▭▬□■◈▣◦✧")
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        let symbolCount = cleanName.filter { char in char.unicodeScalars.contains { symbols.contains($0) } }.count
        let alphanumericCount = cleanName.filter { $0.isLetter || $0.isNumber }.count
        return symbolCount > alphanumericCount || cleanName.contains("---") || cleanName.count < 3
    }
    
    nonisolated static func tokenize(_ input: String) -> [String] {
        let cleaned = input.lowercased().replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)
        return cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 && !blockers.contains($0) }
    }
    
    nonisolated static func calculateStreamScore(name: String, sport: SportType, targetNetwork: String? = nil) -> Int {
        if isBanner(name) { return -100000 }
        var score = 0
        let lowerName = name.lowercased()
        let lowerNet = (targetNetwork ?? "").lowercased()
        
        if lowerNet == "espn+" && lowerName.contains("espn+") { score += 80000 }
        
        let internationalTags = ["(es)", "(fr)", "(it)", "(pl)", "(ar)", "spanish", "french", "latino"]
        if internationalTags.contains(where: { lowerName.contains($0) }) { score -= 50000 }
        if lowerName.contains("usa") || lowerName.contains("(us)") { score += 10000 }
        if lowerName.contains("4k") || lowerName.contains("uhd") { score += 5000 }
        if lowerName.contains("fhd") || lowerName.contains("1080") { score += 3000 }
        return score
    }
}
