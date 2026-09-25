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
    
    /// Regional and affiliate qualifiers that get trimmed off the END of a
    /// channel name for display. "NBC Sports Bay Area" is the Bay Area feed of
    /// NBC Sports, and on a hero card the brand is the useful part.
    ///
    /// Ordered longest-first at use, so "bay area" is taken before "area" ever
    /// could be, and "new england" before "england".
    nonisolated static let regionSuffixes: [String] = [
        "bay area", "new england", "mid atlantic", "mid-atlantic", "rocky mountain",
        "great lakes", "north west", "south west", "south east", "north east",
        "new york", "los angeles", "san francisco", "san diego", "san antonio",
        "kansas city", "las vegas", "salt lake city", "new orleans", "st louis",
        "st. louis", "washington dc",
        "atlanta", "boston", "chicago", "philadelphia", "washington", "detroit",
        "pittsburgh", "cleveland", "cincinnati", "dallas", "houston", "miami",
        "orlando", "phoenix", "denver", "seattle", "portland", "minneapolis",
        "milwaukee", "charlotte", "nashville", "memphis", "baltimore", "tampa",
        "sacramento", "indianapolis", "columbus", "buffalo", "albany",
        "california", "florida", "texas", "ohio", "arizona", "carolina",
        "georgia", "michigan", "virginia", "oregon", "nevada", "utah",
        "colorado", "kansas", "missouri", "tennessee", "alabama", "louisiana",
        "oklahoma", "kentucky", "indiana", "wisconsin", "minnesota", "iowa",
        "nebraska", "arkansas", "mississippi", "connecticut", "maryland",
        "massachusetts", "pennsylvania", "illinois",
        "northwest", "southwest", "southeast", "northeast", "midwest",
        "northern", "southern", "eastern", "western", "regional",
        "atlantic", "pacific", "mountain", "central",
        "north", "south", "east", "west"
    ]

    /// The name as a hero card should show it: no country prefix, no quality
    /// tag, no regional affiliate. "US: NBC Sports Bay Area FHD" reads as
    /// "NBC Sports".
    ///
    /// Falls back to the plain cleaned name whenever trimming would leave
    /// nothing useful, so an unusual name is never mangled into a stub.
    nonisolated static func simplifiedBrand(_ name: String) -> String {
        // Country tokens the shared cleaner doesn't catch: it strips "US:" but
        // not "US :" or "US -", and playlists write every variant.
        var n = clean(name).replacingOccurrences(
            of: "^[A-Za-z]{2,3}\\s*[:|\\-]\\s*",
            with: "",
            options: [.regularExpression]
        )
        n = n.trimmingCharacters(in: .whitespacesAndNewlines)

        let ordered = regionSuffixes.sorted { $0.count > $1.count }
        var trimming = true
        while trimming {
            trimming = false
            let lower = n.lowercased()
            for suffix in ordered where lower.hasSuffix(" " + suffix) {
                let candidate = String(n.dropLast(suffix.count + 1))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|"))
                // Never trim away the brand itself.
                guard candidate.count >= 2 else { break }
                n = candidate
                trimming = true
                break
            }
        }

        let trimmed = n.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|"))
        return trimmed.count >= 2 ? trimmed : clean(name)
    }

    nonisolated static func isLiveGameOrPPV(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("ppv") || lower.contains("ufc") || lower.contains("box office") || lower.contains("live event")
    }
}
