import Foundation

/// Finds a photograph for a programme the guide gave us no still for.
///
/// TMDB was the obvious candidate and it's the wrong shape for live TV: it
/// catalogues films and scripted series, so a news hour, a golf major or a
/// regional sports show returns nothing. These two are keyless, and between
/// them they cover what actually runs on a live channel:
///
///   • **TVmaze** — a TV database with proper show artwork. Strong on series
///     and returning shows (including news and talk formats, which it lists as
///     shows), and its `singlesearch` endpoint does the fuzzy matching for us.
///   • **Wikipedia** — everything else. A summary lookup returns the article's
///     lead image, which for "Anderson Cooper 360°" is Cooper and for "The Open
///     Championship" is the golf. Broad where a TV database is narrow.
///
/// Results — including misses — are cached on disk, so a title is looked up
/// once and never again. Nothing here blocks the UI: a card shows the channel's
/// own treatment until artwork arrives, then swaps to it.
actor ProgramArtworkService {
    static let shared = ProgramArtworkService()

    /// Title → artwork URL. A stored empty string is a remembered MISS, which
    /// is what stops a channel with no findable artwork from being looked up
    /// on every launch.
    private var cache: [String: String] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]
    private var loaded = false
    private var dirty = false

    private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("program-artwork.json")
    }()

    /// Artwork for a programme title, or nil when neither source has one.
    func artwork(for rawTitle: String) async -> String? {
        loadIfNeeded()
        let key = Self.normalise(rawTitle)
        guard key.count >= 3 else { return nil }
        if let hit = cache[key] { return hit.isEmpty ? nil : hit }
        if let running = inFlight[key] { return await running.value }

        let task = Task<String?, Never> { [key] in
            if let fromTV = await Self.lookupTVmaze(key) { return fromTV }
            return await Self.lookupWikipedia(key)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        cache[key] = result ?? ""
        dirty = true
        persist()
        return result
    }

    // MARK: Sources

    private static func lookupTVmaze(_ title: String) async -> String? {
        guard let escaped = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.tvmaze.com/singlesearch/shows?q=\(escaped)")
        else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let show = try? JSONDecoder().decode(TVmazeShow.self, from: data)
        else { return nil }
        return show.image?.original ?? show.image?.medium
    }

    private static func lookupWikipedia(_ title: String) async -> String? {
        // The summary endpoint resolves redirects and near-misses itself, so a
        // programme title usually lands on the right article without a
        // separate search step.
        guard let escaped = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(escaped)?redirect=true")
        else { return nil }
        var request = URLRequest(url: url)
        // Wikimedia asks API clients to identify themselves.
        request.setValue("Nebulo/3.0 (iOS TV app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let summary = try? JSONDecoder().decode(WikiSummary.self, from: data)
        else { return nil }
        // Disambiguation pages carry a generic icon, never a photograph.
        guard summary.type != "disambiguation" else { return nil }
        return summary.originalimage?.source ?? summary.thumbnail?.source
    }

    // MARK: Normalising

    /// Strips the decoration guide titles carry — "(NEW)", "[HD]", a trailing
    /// episode number, "LIVE:" — so two spellings of the same show share one
    /// cache entry and one lookup.
    nonisolated static func normalise(_ title: String) -> String {
        var t = title
        for pattern in ["\\([^)]*\\)", "\\[[^\\]]*\\]", "^live:?\\s*", "^new:?\\s*"] {
            t = t.replacingOccurrences(of: pattern, with: "",
                                       options: [.regularExpression, .caseInsensitive])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Disk cache

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let stored = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        cache = stored
    }

    private func persist() {
        guard dirty else { return }
        dirty = false
        let snapshot = cache
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    // MARK: Wire models

    private struct TVmazeShow: Decodable {
        struct Image: Decodable { let medium: String?; let original: String? }
        let image: Image?
    }

    private struct WikiSummary: Decodable {
        struct Image: Decodable { let source: String? }
        let type: String?
        let originalimage: Image?
        let thumbnail: Image?
    }
}
