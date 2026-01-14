import Foundation

struct NameCleaner {
    nonisolated static func clean(_ name: String) -> String {
        
        var n = name
        let patterns = ["|US|", "|UK|", "FHD:", "HD:", "HEVC:", "4K:"]
        for p in patterns {
            n = n.replacingOccurrences(of: p, with: "")
        }
        return n.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    nonisolated static func isLiveGameOrPPV(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("ppv") || lower.contains("ufc") || lower.contains("box office") || lower.contains("live event")
    }
}
