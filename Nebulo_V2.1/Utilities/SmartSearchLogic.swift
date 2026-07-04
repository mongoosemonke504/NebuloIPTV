import Foundation

struct SmartSearchLogic: Sendable {
    nonisolated static let blockers: Set<String> = ["univ", "university", "state", "st", "vs", "at", "the", "club", "fc", "team"]
    nonisolated static let bannerSymbols: CharacterSet = CharacterSet(charactersIn: "✦●★|•▬▭▬□■◈▣◦✧")
    
    nonisolated static func isBanner(_ name: String) -> Bool {
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        // Optimization: Check for banner symbols using the pre-computed set
        let symbolCount = cleanName.unicodeScalars.reduce(0) { count, scalar in
            bannerSymbols.contains(scalar) ? count + 1 : count
        }
        let alphanumericCount = cleanName.filter { $0.isLetter || $0.isNumber }.count
        return symbolCount > alphanumericCount || cleanName.contains("---") || cleanName.count < 3
    }
    
    nonisolated static func tokenize(_ input: String) -> [String] {
        let cleaned = input.lowercased().replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)
        // Optimization: Use the Set for faster filtering
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
