import Foundation

/// Resolves soccer player photos by name via TheSportsDB. ESPN's soccer
/// headshot coverage is a handful of players per league (everyone else
/// 404s), so lineups would be nearly all blank circles without a second
/// source. Every result — including misses — is cached to disk, so each
/// player costs at most one lookup across all launches.
actor SoccerHeadshotService {
    static let shared = SoccerHeadshotService()

    /// Normalized player name → image URL ("" = known miss).
    private var cache: [String: String]
    private let cacheURL: URL

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // v2: v1 briefly cached rate-limit failures as permanent misses.
        cacheURL = dir.appendingPathComponent("soccerHeadshots-v2.json")
        cache = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: cacheURL))) ?? [:]
    }

    func imageURL(for name: String) async -> String? {
        let key = Self.normalize(name)
        guard !key.isEmpty else { return nil }
        if let hit = cache[key] { return hit.isEmpty ? nil : hit }
        switch await lookup(name: name) {
        case .found(let url):
            cache[key] = url
            persist()
            return url
        case .notFound:
            // A definitive "no such player / no photo" — remember it.
            cache[key] = ""
            persist()
            return nil
        case .failed:
            // Rate limit or network hiccup: do NOT cache, so the next game
            // open (or retry) can still succeed. Caching these is what made
            // whole teams permanently photo-less.
            return nil
        }
    }

    private enum LookupResult {
        case found(String)
        case notFound
        case failed
    }

    private struct SearchResponse: Decodable { let player: [SearchPlayer]? }
    private struct SearchPlayer: Decodable {
        let strPlayer: String?
        let strSport: String?
        let strCutout: String?
        let strThumb: String?
    }

    private func lookup(name: String) async -> LookupResult {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.thesportsdb.com/api/v1/json/3/searchplayers.php?p=\(encoded)") else { return .failed }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return .failed }

        let target = Self.normalize(name)
        let soccer = (decoded.player ?? []).filter { ($0.strSport ?? "") == "Soccer" }
        let best = soccer.first { Self.normalize($0.strPlayer ?? "") == target } ?? soccer.first
        guard let best else { return .notFound }
        // "/preview" is TheSportsDB's small variant — right size for the
        // lineup circles, tiny download. Cutouts are transparent-background
        // headshots; thumbs are the fallback.
        if let cutout = best.strCutout, !cutout.isEmpty { return .found(cutout + "/preview") }
        if let thumb = best.strThumb, !thumb.isEmpty { return .found(thumb + "/preview") }
        return .notFound
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
