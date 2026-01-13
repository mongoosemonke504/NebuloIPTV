import Foundation

struct SmartSearchLogic {
    nonisolated static func tokenize(_ text: String) -> [String] {
        return text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    
    nonisolated static func isBanner(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("header") || lower.contains("marker") || lower.contains("separator") || lower.contains("****")
    }
    
    nonisolated static func detectQuality(_ name: String) -> StreamQuality {
        let lower = name.lowercased()
        if lower.contains("4k") || lower.contains("uhd") { return .fourK }
        if lower.contains("fhd") || lower.contains("1080") { return .fhd }
        if lower.contains("hd") || lower.contains("720") || lower.contains("hevc") { return .hd }
        if lower.contains("sd") || lower.contains("576") || lower.contains("480") { return .sd }
        return .sd // Default assumption if unlabeled
    }
    
    nonisolated static func checkLanguageMatch(_ text: String, preference: LanguagePreference) -> Bool {
        if preference == .any { return true }
        
        let lowerText = text.lowercased()
        let tokens = tokenize(lowerText) // Splits by non-alphanumeric, handles whitespace
        
        // 1. Check Explicit Channel Tags (e.g. "US", "UK", "ES")
        // Only valid if the text actually contains the specific country code/tag
        let explicitTags = preference.searchTokens
        for tag in explicitTags {
            // We check if the tag exists as a standalone token to avoid false positives (e.g. "bus" containing "us")
            if tokens.contains(tag) { return true }
        }
        
        // 2. Check Linguistic Indicators (Stopwords in EPG/Description)
        let indicators = preference.languageIndicators
        if !indicators.isEmpty {
            // Count how many indicators appear in the text
            var matchCount = 0
            for indicator in indicators {
                // Handle "d'" prefix for French specifically or generic tokens
                if indicator.contains("'") {
                    if lowerText.contains(indicator) { matchCount += 1 }
                } else {
                    if tokens.contains(indicator) { matchCount += 1 }
                }
            }
            
            // Threshold: If we find at least 1 indicator, consider it a match.
            // Since the user explicitly selected a preference, we can be more aggressive.
            if matchCount >= 1 { return true }
        }
        
        return false
    }
    
    nonisolated static func detectLanguage(_ text: String) -> LanguagePreference? {
        let lower = text.lowercased()
        let tokens = tokenize(lower)
        
        // Check for specific language indicators
        for lang in LanguagePreference.allCases {
            if lang == .any { continue }
            
            // 1. Explicit Tags
            if lang.searchTokens.contains(where: { tokens.contains($0) }) { return lang }
            
            // 2. Indicators
            let indicators = lang.languageIndicators
            if !indicators.isEmpty {
                var matchCount = 0
                for indicator in indicators {
                    if indicator.contains("'") {
                        if lower.contains(indicator) { matchCount += 1 }
                    } else {
                        if tokens.contains(indicator) { matchCount += 1 }
                    }
                }
                if matchCount >= 2 { return lang } // Require 2 for auto-detection to be safe
            }
        }
        return nil
    }
}
