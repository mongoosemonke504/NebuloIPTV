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
        // Language-neutral channel — no penalty, treat as matching any preference
        return true
    }

    // Returns nil when no language can be confidently detected (channel is language-neutral).
    // Returning nil avoids incorrectly penalising neutral channels (e.g. "ESPN HD") when the
    // user has a non-English preference.
    nonisolated static func detectLanguage(_ text: String) -> LanguagePreference? {
        let lower = text.lowercased()
        let tokens = tokenize(lower)

        var scores: [LanguagePreference: Int] = [:]

        for lang in LanguagePreference.allCases {
            if lang == .any { continue }
            var score = 0

            // Strong explicit prefix/bracket markers, e.g. "ES: La Liga" or "[FR]"
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

        guard let best = scores.max(by: { $0.value < $1.value }), best.value >= 20 else {
            // Threshold of 20 (at least one strong token match) required to assign a language.
            // Below that the detection is noise — treat the channel as language-neutral.
            return nil
        }
        return best.key
    }
}
