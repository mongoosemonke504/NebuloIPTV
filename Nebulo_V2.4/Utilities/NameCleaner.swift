import Foundation

struct NameCleaner {
    static func clean(_ name: String) -> String {
        // Remove common prefixes/suffixes
        var n = name
        let patterns = ["|US|", "|UK|", "FHD:", "HD:", "HEVC:", "4K:"]
        for p in patterns {
            n = n.replacingOccurrences(of: p, with: "")
        }
        return n.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    static func isLiveGameOrPPV(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("ppv") || lower.contains("ufc") || lower.contains("box office") || lower.contains("live event")
    }
}
