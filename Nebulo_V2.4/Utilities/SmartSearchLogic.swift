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
        
        // Use the robust detection logic
        if let detected = detectLanguage(text) {
            return detected == preference
        }
        
        // Fallback to simple token match if detection failed (short strings)
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
            
            // 1. Explicit Prefix (e.g. "FR:", "US:", "UK:")
            if let code = lang.searchTokens.first {
                if lower.hasPrefix(code + ":") || lower.contains(" " + code + ":") || lower.hasPrefix("[" + code + "]") {
                    score += 100
                }
            }
            
            // 2. Search Tokens (Strong Indicators)
            for token in lang.searchTokens {
                if tokens.contains(token) { score += 20 }
            }
            
            // 3. Language Indicators (Common Words)
            for indicator in lang.languageIndicators {
                if indicator.contains("'") {
                    // Substring match for things like "l'", "d'"
                    if lower.contains(indicator) { score += 5 }
                } else {
                    // Token match for whole words
                    if tokens.contains(indicator) { score += 2 }
                }
            }
            
            // Penalize English slightly if it's just "is" or "on" to prevent false positives on short strings? 
            // No, scoring should handle it.
            
            if score > 0 { scores[lang] = score }
        }
        
        // Return the language with the highest score
        if let best = scores.max(by: { $0.value < $1.value }) {
            return best.key
        }
        
        // If no identifiers found, default to English (US)
        return .us
    }
}
