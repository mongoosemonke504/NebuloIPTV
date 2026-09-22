import Foundation

struct SmartSearchLogic {
    /// Words that carry no signal but appear in most channel names, EPG
    /// titles and descriptions. Left in, a query like "The Open Championship"
    /// scored a content match against half the guide on "the" alone, and the
    /// real golf channels were buried in the noise.
    nonisolated static let ignoredTokens: Set<String> = [
        "the", "a", "an", "of", "at", "in", "on", "and", "vs", "v"
    ]

    nonisolated static func tokenize(_ text: String) -> [String] {
        let raw = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let meaningful = raw.filter { !ignoredTokens.contains($0) }
        // Never return nothing: a query that is ALL function words is better
        // served by its own weak tokens than by matching everything.
        return meaningful.isEmpty ? raw : meaningful
    }
    
    // MARK: - Sides

    /// Words that name a side only when something else is with them. On
    /// their own they name half a league: "United" is Manchester, Newcastle,
    /// Leeds and West Ham; "City" is three of them; "State" is a hundred
    /// colleges. A match that rests on one of these alone is not a match.
    nonisolated static let genericSideWords: Set<String> = [
        "united", "utd", "city", "town", "county", "state", "tech", "college", "university",
        "real", "athletic", "atletico", "sporting", "inter", "club", "fc", "cf", "sc", "afc",
        "rovers", "wanderers", "albion", "hotspur", "north", "south", "east", "west", "central",
        "new", "los", "las", "san", "saint", "st", "de", "la", "el", "the", "a", "an", "of", "and"
    ]

    /// Everything a side might be called in a guide entry or a channel name,
    /// as token lists, most specific first.
    ///
    /// A guide names a team however its editor felt like it that day: "Los
    /// Angeles Lakers at Boston Celtics", "LA Lakers vs Boston", "Lakers @
    /// Celtics", "Man Utd v Liverpool", "Manchester United v Liverpool",
    /// "#3 Texas at #7 Oklahoma". One spelling of one name — the search used
    /// to carry the short name alone — finds one of those. The full name, the
    /// short name, the place, the nickname and the abbreviation between them
    /// find all of it; the alias rules add the spellings the feed never
    /// carries ("Man Utd", "St Louis", the name without its "FC").
    nonisolated struct SideNames: Sendable {
        /// A spelling of the side. A `strong` one names the side outright
        /// (its full name, its short name, its nickname). A weak one only
        /// points at it — the place on its own ("Los Angeles" is four teams;
        /// "Texas" is Texas, Texas Tech and Texas A&M), or the abbreviation
        /// ("MIN" is also ninety minutes) — and can never make a full match
        /// by itself.
        nonisolated struct Variant: Sendable {
            let tokens: [String]
            let strong: Bool
        }
        let variants: [Variant]

        nonisolated static func team(_ team: ESPNTeam) -> SideNames {
            var strong: [String] = []
            var weak: [String] = []
            func add(_ value: String?, to list: inout [String]) {
                guard let value, !value.isEmpty else { return }
                list.append(value)
            }
            add(team.displayName, to: &strong)
            add(team.shortDisplayName, to: &strong)
            if let location = team.location, let name = team.name, !location.isEmpty, !name.isEmpty {
                add("\(location) \(name)", to: &strong)
            }
            add(team.name, to: &strong)
            add(team.location, to: &weak)
            add(team.abbreviation, to: &weak)
            return SideNames(variants: expand(strong, strong: true) + expand(weak, strong: false))
        }

        /// A side given as free text — a player's surname, a race weekend,
        /// a fighter, or a team the caller only has a name for.
        nonisolated static func text(_ text: String) -> SideNames {
            SideNames(variants: expand([text], strong: true))
        }

        /// Tokenises, folds accents, applies the alias rules, and drops the
        /// duplicates — longest variants first, so the most specific spelling
        /// is the one that decides a full match.
        nonisolated private static func expand(_ raw: [String], strong: Bool) -> [Variant] {
            var out: [Variant] = []
            var seen = Set<String>()
            func push(_ tokens: [String]) {
                let key = tokens.joined(separator: " ")
                guard !tokens.isEmpty, !seen.contains(key) else { return }
                seen.insert(key)
                out.append(Variant(tokens: tokens, strong: strong))
            }
            for value in raw {
                let tokens = SmartSearchLogic.words(value)
                push(tokens)
                for alias in aliases(of: tokens) { push(alias) }
            }
            return out.sorted { $0.tokens.count > $1.tokens.count }
        }

        /// The spellings a feed never carries but a guide does.
        nonisolated private static func aliases(of tokens: [String]) -> [[String]] {
            var out: [[String]] = []
            let clubSuffixes: Set<String> = ["fc", "cf", "sc", "afc", "cfc", "bk", "club"]
            let stripped = tokens.filter { !clubSuffixes.contains($0) }
            if stripped.count != tokens.count, !stripped.isEmpty { out.append(stripped) }
            if tokens.contains("manchester") {
                out.append(tokens.map { $0 == "manchester" ? "man" : $0 })
            }
            if tokens.contains("united") {
                out.append(tokens.map { $0 == "united" ? "utd" : $0 })
                if tokens.contains("manchester") {
                    out.append(tokens.map { $0 == "manchester" ? "man" : ($0 == "united" ? "utd" : $0) })
                }
            }
            if tokens.contains("saint") { out.append(tokens.map { $0 == "saint" ? "st" : $0 }) }
            if tokens.contains("st") { out.append(tokens.map { $0 == "st" ? "saint" : $0 }) }
            if tokens.contains("los") && tokens.contains("angeles") {
                out.append(["la"] + tokens.filter { $0 != "los" && $0 != "angeles" })
            }
            if tokens == ["paris", "saint", "germain"] || tokens == ["paris", "st", "germain"] { out.append(["psg"]) }
            if tokens == ["tottenham", "hotspur"] { out.append(["spurs"]) }
            if tokens == ["wolverhampton", "wanderers"] || tokens == ["wolverhampton"] { out.append(["wolves"]) }
            if tokens == ["borussia", "dortmund"] { out.append(["dortmund"]); out.append(["bvb"]) }
            if tokens == ["bayern", "munich"] || tokens == ["bayern", "munchen"] { out.append(["bayern"]) }
            if tokens == ["inter", "miami", "cf"] || tokens == ["inter", "miami"] { out.append(["inter", "miami"]) }
            if tokens == ["internazionale"] || tokens == ["inter", "milan"] { out.append(["inter", "milan"]); out.append(["inter"]) }
            return out
        }
    }

    /// How well a text names a side: `.none`, `.partial` (a real word of it,
    /// but not a whole spelling — "Angeles" without "Lakers", or half of a
    /// long name), or `.full` (a whole spelling, in any order).
    nonisolated enum SideMatch: Int, Comparable {
        case none = 0, partial = 1, full = 2
        nonisolated static func < (lhs: SideMatch, rhs: SideMatch) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Words that turn a name into a different team when they follow it:
    /// "Texas" is not "Texas Tech" or "Texas A&M", "Ohio" is not "Ohio
    /// State", "Manchester" alone is not "Manchester City". A word in the
    /// text counts for a side only where it is NOT followed by one of these
    /// — unless the side's own spelling has that word next, which is how
    /// "Ohio State" still matches "Ohio State".
    nonisolated static let compoundQualifiers: Set<String> = [
        "state", "tech", "a", "am", "southern", "northern", "western", "eastern", "central",
        "christian", "international", "city", "united", "utd", "county", "town",
        "wanderers", "rovers", "athletic", "wesleyan", "valley", "poly"
    ]

    /// Matches whole words, never substrings: "man" no longer finds Germany,
    /// and "st" no longer finds everything. A hit counts only when it includes
    /// a word that is the side's own — never one of `genericSideWords`, never
    /// under three letters — and only where the text isn't naming a compound
    /// team (see `compoundQualifiers`). A whole strong spelling is a full
    /// match; a whole weak one, or half or more of any spelling, is partial.
    nonisolated static func sideMatch(_ words: [String], _ side: SideNames) -> SideMatch {
        let present = Set(words)
        /// Whether `token` appears somewhere it isn't the front half of a
        /// compound this spelling doesn't have.
        func counts(_ token: String, in variant: [String]) -> Bool {
            guard present.contains(token) else { return false }
            for (index, word) in words.enumerated() where word == token {
                let next = index + 1 < words.count ? words[index + 1] : ""
                if next.isEmpty || !compoundQualifiers.contains(next) || variant.contains(next) { return true }
            }
            return false
        }
        var best = SideMatch.none
        for variant in side.variants {
            let hit = variant.tokens.filter { counts($0, in: variant.tokens) }
            guard hit.contains(where: { !genericSideWords.contains($0) && $0.count >= 3 }) else { continue }
            if hit.count == variant.tokens.count && variant.strong { return .full }
            if Double(hit.count) / Double(variant.tokens.count) >= 0.5 { best = max(best, .partial) }
        }
        return best
    }

    /// The words of a text: lower-cased, accents folded ("São" and "Sao" are
    /// one word), split on anything that isn't a letter or a digit.
    nonisolated static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
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
