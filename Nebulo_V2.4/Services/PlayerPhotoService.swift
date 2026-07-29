import Foundation

/// Squad photos for the team page.
///
/// ESPN's headshot coverage is a cliff edge: near-total for the US leagues,
/// and 4 players out of 49 for a Premier League club. Everyone ESPN has no
/// picture of is resolved from Wikipedia instead — but one lookup per player
/// would be 45 round trips for a single squad, which is why this batches:
/// `action=query&prop=pageimages` accepts up to 50 titles at a time, so a
/// whole squad costs ONE request.
///
/// `prop=description` rides along in the same request as a namesake guard.
/// "Ben Davies" alone could be any of a dozen people; requiring the Wikidata
/// short description to name the sport ("Welsh footballer (born 1993)") keeps
/// a cricketer's photo off a football squad.
///
/// Anyone the batch misses is a player whose plain title is taken, and
/// Wikipedia files those under birth-year disambiguators ("Antonín Kinský
/// (footballer, born 2003)") that can't be guessed. Those fall through to
/// TheSportsDB by name, which is what `SoccerHeadshotService` already does for
/// match lineups — so the cheap batch does the bulk and the per-player lookups
/// only cover the remainder.
///
/// Every answer — misses included — is cached to disk, so a squad costs at
/// most one pass ever, not one per launch.
actor PlayerPhotoService {
    static let shared = PlayerPhotoService()

    /// "sportKey|normalized name" → photo URL. "" is a known miss, and is
    /// cached deliberately: without it a photo-less squad re-queried forever.
    private var cache: [String: String]
    private let cacheURL: URL

    /// Titles per request. Wikipedia's limit is 50 for anonymous callers.
    private static let batchSize = 45

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheURL = dir.appendingPathComponent("playerPhotos-v1.json")
        cache = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: cacheURL))) ?? [:]
    }

    // MARK: - Sport vocabulary

    /// What a Wikipedia short description has to say for the page to be about
    /// this sport's player rather than a namesake.
    private static func keywords(for sport: SportType?) -> [String] {
        switch sport {
        case .nba, .wnba, .cbb:     return ["basketball"]
        case .mlb:                  return ["baseball"]
        case .nhl, .collegeHockey:  return ["hockey"]
        case .nfl, .cfb:            return ["football"]
        // Every football competition, and the safest default for anything this
        // app grows into.
        default:                    return ["football", "soccer"]
        }
    }

    /// TheSportsDB only helps for football — it's where its coverage is, and
    /// it's the only sport ESPN leaves photo-less.
    private static func usesSportsDBFallback(_ sport: SportType?) -> Bool {
        switch sport {
        case .nba, .wnba, .cbb, .mlb, .nhl, .collegeHockey, .nfl, .cfb: return false
        default: return true
        }
    }

    private static func sportKey(_ sport: SportType?) -> String {
        switch sport {
        case .nba, .wnba, .cbb: return "bball"
        case .mlb: return "mlb"
        case .nhl, .collegeHockey: return "hockey"
        case .nfl, .cfb: return "usfootball"
        default: return "soccer"
        }
    }

    // MARK: - Lookup

    /// Photo URLs for `names`, keyed by the ORIGINAL name string so callers can
    /// look up straight from their roster. Names with no picture are simply
    /// absent from the result.
    func photos(for names: [String], sport: SportType?) async -> [String: String] {
        let keywords = Self.keywords(for: sport)
        let key = Self.sportKey(sport)

        var result: [String: String] = [:]
        var pending: [String] = []

        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let hit = cache[key + "|" + Self.normalize(trimmed)] {
                if !hit.isEmpty { result[name] = hit }
            } else {
                pending.append(trimmed)
            }
        }
        guard !pending.isEmpty else { return result }

        // Pass 1: one batched request per 45 names.
        var stillMissing: [String] = []
        for chunk in stride(from: 0, to: pending.count, by: Self.batchSize).map({
            Array(pending[$0..<min($0 + Self.batchSize, pending.count)])
        }) {
            let found = await lookup(titles: chunk, keywords: keywords)
            for name in chunk {
                if let url = found[name] { result[name] = url } else { stillMissing.append(name) }
            }
        }

        // Pass 2: whoever's left, one at a time, through TheSportsDB.
        var confirmedMisses = Set(stillMissing)
        if !stillMissing.isEmpty, Self.usesSportsDBFallback(sport) {
            let pass = await sportsDBPass(stillMissing)
            for (name, url) in pass.found { result[name] = url }
            // Only a lookup that came back with a definite "no photo" is
            // remembered as a miss. A rate-limited or offline lookup answers
            // neither way, and caching those is what would leave a whole squad
            // permanently photo-less after one bad moment on the network.
            confirmedMisses = pass.definiteMisses
        }

        for (name, url) in result { cache[key + "|" + Self.normalize(name)] = url }
        for name in confirmedMisses { cache[key + "|" + Self.normalize(name)] = "" }
        persist()
        return result
    }

    /// The per-player fallback, four at a time — TheSportsDB rate-limits
    /// anonymous callers, and a squad's worth of parallel requests trips it.
    ///
    /// `definiteMisses` are the names the lookup answered for and had no photo
    /// of, as opposed to the ones it never managed to answer at all.
    private func sportsDBPass(
        _ names: [String]
    ) async -> (found: [String: String], definiteMisses: Set<String>) {
        var found: [String: String] = [:]
        var misses = Set<String>()
        var index = 0
        while index < names.count {
            let slice = Array(names[index..<min(index + 4, names.count)])
            let answers = await withTaskGroup(of: (String, String?).self) { group in
                for name in slice {
                    group.addTask {
                        // nil = no answer; "" = answered, no photo.
                        let info = await SoccerHeadshotService.shared.info(for: name)
                        return (name, info.map(\.url))
                    }
                }
                var partial: [String: String?] = [:]
                for await (name, url) in group { partial[name] = url }
                return partial
            }
            for (name, url) in answers {
                guard let url else { continue }
                if url.isEmpty { misses.insert(name) } else { found[name] = url }
            }
            index += 4
        }
        return (found, misses)
    }

    // MARK: - Wikipedia

    private struct QueryResponse: Decodable {
        struct Query: Decodable {
            struct Mapping: Decodable { let from: String; let to: String }
            struct Page: Decodable {
                struct Thumbnail: Decodable { let source: String? }
                let title: String?
                let description: String?
                let thumbnail: Thumbnail?
            }
            let normalized: [Mapping]?
            let redirects: [Mapping]?
            let pages: [String: Page]?
        }
        let query: Query?
    }

    /// One batched request, keyed back to the names that were asked for.
    private func lookup(titles: [String], keywords: [String]) async -> [String: String] {
        guard let joined = titles.joined(separator: "|")
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string:
                "https://en.wikipedia.org/w/api.php?action=query"
                + "&prop=pageimages%7Cdescription&piprop=thumbnail&pithumbsize=240"
                + "&redirects=1&format=json&titles=\(joined)")
        else { return [:] }

        var request = URLRequest(url: url)
        // Wikipedia throttles callers that don't identify themselves.
        request.setValue("Nebulo/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(QueryResponse.self, from: data),
              let query = decoded.query
        else { return [:] }

        // Wikipedia answers under the FINAL title, so a request for "Ben
        // Davies" comes back as "Benjamin Davies". Follow the normalize →
        // redirect chain to pair each answer back to what was asked for.
        var forward: [String: String] = [:]
        for m in query.normalized ?? [] { forward[m.from] = m.to }
        for m in query.redirects ?? [] { forward[m.from] = m.to }

        var byTitle: [String: QueryResponse.Query.Page] = [:]
        for page in (query.pages ?? [:]).values {
            if let title = page.title { byTitle[title] = page }
        }

        var out: [String: String] = [:]
        for (index, title) in titles.enumerated() {
            var resolved = title
            // Bounded walk: a redirect loop would otherwise spin here.
            for _ in 0..<3 {
                guard let next = forward[resolved], next != resolved else { break }
                resolved = next
            }
            guard let page = byTitle[resolved],
                  let photo = page.thumbnail?.source, !photo.isEmpty else { continue }
            // The namesake guard: no short description, or one that doesn't
            // name the sport, and the photo is rejected rather than risked.
            let description = (page.description ?? "").lowercased()
            guard keywords.contains(where: { description.contains($0) }) else { continue }
            out[titles[index]] = photo
        }
        return out
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL) }
    }

    nonisolated static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
    }
}
