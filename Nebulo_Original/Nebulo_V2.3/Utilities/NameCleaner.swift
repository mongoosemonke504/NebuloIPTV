import Foundation

struct NameCleaner {
    nonisolated static func clean(_ name: String) -> String {
        
        var n = name
        let patterns = [
            "|US|", "|UK|", "|CA|", "|AU|",
            "FHD:", "HD:", "SD:", "HEVC:", "4K:", "H.265",
            "(US)", "(UK)", "(CA)", "(AU)",
            "[US]", "[UK]", "[CA]", "[AU]",
            "US:", "UK:", "CA:", "AU:",
            "50 FPS", "60 FPS", "RAW",
            "FHD", "HD", "SD", "4K" 
        ]
        
        for p in patterns {
            
            if let range = n.range(of: p, options: .caseInsensitive) {
                n = n.replacingCharacters(in: range, with: "")
            }
        }
        
        
        n = n.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.hasSuffix("-") { n = String(n.dropLast()) }
        if n.hasSuffix(":") { n = String(n.dropLast()) }
        
        return n.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    nonisolated static func isLiveGameOrPPV(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("ppv") || lower.contains("ufc") || lower.contains("box office") || lower.contains("live event")
    }
}
