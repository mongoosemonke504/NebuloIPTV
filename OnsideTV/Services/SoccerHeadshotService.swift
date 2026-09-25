import Foundation

/// Resolves soccer player photos AND birth dates by name via TheSportsDB,
/// with Wikipedia as the photo/age fallback. ESPN's soccer feed carries
/// neither headshots (for ~90% of players) nor ages, so both come from the
/// same lookups. Every result — including misses — is cached to disk, so
/// each player costs at most one lookup across all launches.
actor SoccerHeadshotService {
    static let shared = SoccerHeadshotService()

    struct PlayerInfo: Codable {
        /// "" = known photo miss.
        let url: String
        /// "yyyy-MM-dd" from TheSportsDB, or a bare "yyyy" from Wikipedia.
        let born: String?
    }

    /// Normalized player name → resolved info.
    private var cache: [String: PlayerInfo]
    private let cacheURL: URL

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // v3: adds birth dates alongside photo URLs.
        cacheURL = dir.appendingPathComponent("soccerHeadshots-v3.json")
        cache = (try? JSONDecoder().decode([String: PlayerInfo].self, from: Data(contentsOf: cacheURL))) ?? [:]
    }

    /// The answer already on disk, or nil when this name has never been
    /// looked up. Never touches the network, so a caller can settle every
    /// known player in one pass before paying the lookup cadence for the rest.
    func cached(for name: String) -> PlayerInfo? {
        let key = Self.normalize(name)
        guard !key.isEmpty else { return PlayerInfo(url: "", born: nil) }
        return cache[key]
    }

    /// nil = transient failure (rate limit / network) — retry later.
    /// Otherwise a definitive answer, possibly with an empty photo.
    func info(for name: String) async -> PlayerInfo? {
        let key = Self.normalize(name)
        guard !key.isEmpty else { return PlayerInfo(url: "", born: nil) }
        if let hit = cache[key] { return hit }
        switch await lookup(name: name) {
        case .resolved(let info):
            cache[key] = info
            persist()
            return info
        case .failed:
            // Rate limit or network hiccup: do NOT cache, so the next game
            // open (or retry) can still succeed. Caching these is what made
            // whole teams permanently photo-less.
            return nil
        }
    }

    private enum LookupResult {
        case resolved(PlayerInfo)
        case failed
    }

    private struct SearchResponse: Decodable { let player: [SearchPlayer]? }
    private struct SearchPlayer: Decodable {
        let strPlayer: String?
        let strSport: String?
        let strCutout: String?
        let strThumb: String?
        let dateBorn: String?
    }

    private func lookup(name: String) async -> LookupResult {
        let sportsDB = await sportsDBLookup(name)
        if case .resolved(let info) = sportsDB, !info.url.isEmpty { return sportsDB }
        // Wikipedia sweeps up players TheSportsDB lacks — its footballer
        // coverage is near-total for anyone starting a televised match.
        let wiki = await wikipediaLookup(name)
        switch (sportsDB, wiki) {
        case (.resolved(let db), .resolved(let wk)):
            // Merge: best photo available, best birth info available.
            let url = !db.url.isEmpty ? db.url : wk.url
            return .resolved(PlayerInfo(url: url, born: db.born ?? wk.born))
        case (.resolved(let db), .failed):
            return db.url.isEmpty ? .failed : .resolved(db)
        case (.failed, .resolved(let wk)):
            return wk.url.isEmpty ? .failed : .resolved(wk)
        case (.failed, .failed):
            return .failed
        }
    }

    private func sportsDBLookup(_ name: String) async -> LookupResult {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.thesportsdb.com/api/v1/json/3/searchplayers.php?p=\(encoded)") else { return .failed }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return .failed }

        let target = Self.normalize(name)
        let soccer = (decoded.player ?? []).filter { ($0.strSport ?? "") == "Soccer" }
        let best = soccer.first { Self.normalize($0.strPlayer ?? "") == target } ?? soccer.first
        guard let best else { return .resolved(PlayerInfo(url: "", born: nil)) }
        // "/preview" is TheSportsDB's small variant — right size for the
        // lineup circles, tiny download. Cutouts are transparent-background
        // headshots; thumbs are the fallback.
        var photo = ""
        if let cutout = best.strCutout, !cutout.isEmpty { photo = cutout + "/preview" }
        else if let thumb = best.strThumb, !thumb.isEmpty { photo = thumb + "/preview" }
        let born = (best.dateBorn?.isEmpty == false) ? best.dateBorn : nil
        return .resolved(PlayerInfo(url: photo, born: born))
    }

    private struct WikiSummary: Decodable {
        struct Thumb: Decodable { let source: String? }
        let type: String?
        let description: String?
        let thumbnail: Thumb?
    }

    private func wikipediaLookup(_ name: String) async -> LookupResult {
        for title in [name, name + " (footballer)"] {
            let path = title.replacingOccurrences(of: " ", with: "_")
            guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else { continue }
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { return .failed }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { continue }          // no such page — next title
            guard status == 200,
                  let summary = try? JSONDecoder().decode(WikiSummary.self, from: data) else { return .failed }
            if summary.type == "disambiguation" { continue }
            // Guard against namesakes: only accept a page that is clearly
            // about a footballer (or was found via the footballer title).
            let description = (summary.description ?? "").lowercased()
            let isFootballer = title.contains("(footballer)")
                || description.contains("football")
                || description.contains("soccer")
            guard isFootballer else { continue }
            // "Spanish footballer (born 2007)" → birth year.
            var born: String?
            if let range = description.range(of: #"born (\d{4})"#, options: .regularExpression) {
                born = String(description[range].suffix(4))
            }
            let photo = summary.thumbnail?.source ?? ""
            if !photo.isEmpty || born != nil {
                return .resolved(PlayerInfo(url: photo, born: born))
            }
        }
        return .resolved(PlayerInfo(url: "", born: nil))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL) }
    }

    nonisolated static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
    }

    /// Age in years from a cached born string ("yyyy-MM-dd" or bare "yyyy").
    nonisolated static func age(fromBorn born: String?) -> Int? {
        guard let born, !born.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: born) {
            return Calendar.current.dateComponents([.year], from: date, to: Date()).year
        }
        if let year = Int(born.prefix(4)), year > 1900 {
            return Calendar.current.component(.year, from: Date()) - year
        }
        return nil
    }
}
