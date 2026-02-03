import Foundation

struct SmartSearchLogic {
    nonisolated static func tokenize(_ text: String) -> [String] {
        return text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    
    nonisolated static func isBanner(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("header") || lower.contains("marker") || lower.contains("separator") || lower.contains("****")
    }
    
    nonisolated static func detectQuality(_ text: String, width: Int? = nil, height: Int? = nil) -> StreamQuality {
        if let h = height {
            if h >= 2160 { return .fourK }
            if h >= 1080 { return .fhd }
            if h >= 720 { return .hd }
            if h >= 480 { return .sd }
        }
        
        let lower = text.lowercased()
        if lower.contains("4k") || lower.contains("uhd") || lower.contains("2160") { return .fourK }
        if lower.contains("fhd") || lower.contains("1080") { return .fhd }
        if lower.contains("hd") || lower.contains("720") || lower.contains("hevc") || lower.contains("h265") || lower.contains("h.265") || lower.contains("60fps") || lower.contains("hdr") { return .hd }
        if lower.contains("sd") || lower.contains("576") || lower.contains("480") { return .sd }
        return .unknown
    }
    
    nonisolated static func checkLanguageMatch(_ text: String, preference: LanguagePreference) -> Bool {
        if preference == .any { return true }
        
        
        if let detected = detectLanguage(text) {
            return detected == preference
        }
        
        
        let lowerText = text.lowercased()
        let tokens = tokenize(lowerText) 
        for tag in preference.searchTokens {
            if tokens.contains(tag) { return true }
        }
        return false
    }
    
    nonisolated static func detectLanguage(_ text: String) -> LanguagePreference? {
        let lower = text.lowercased()
        let tokens = tokenize(lower)
        
        var scores: [LanguagePreference: Int] = [:]
        
        for lang in LanguagePreference.allCases {
            if lang == .any { continue }
            var score = 0
            
            
            if let code = lang.searchTokens.first {
                if lower.hasPrefix(code + ":") || lower.contains(" " + code + ":") || lower.hasPrefix("[" + code + "]") {
                    score += 100
                }
            }
            
            
            for token in lang.searchTokens {
                if tokens.contains(token) { score += 20 }
            }
            
            
            for indicator in lang.languageIndicators {
                if indicator.contains("'") {
                    
                    if lower.contains(indicator) { score += 5 }
                } else {
                    
                    if tokens.contains(indicator) { score += 2 }
                }
            }
            
            
            
            
            if score > 0 { scores[lang] = score }
        }
        
        
        if let best = scores.max(by: { $0.value < $1.value }) {
            return best.key
        }
        
        
        return .english
    }
}
