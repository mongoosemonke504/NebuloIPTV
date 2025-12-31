import SwiftUI
import Combine

// MARK: - SCORE VIEW MODEL
@MainActor
class ScoreViewModel: ObservableObject {
    @AppStorage("lastSelectedSport") var selectedSport: SportType = .soccer
    @Published var gamesData: [SportType: [ESPNEvent]] = [:]
    @Published var lastFetchTimes: [SportType: Date] = [:]
    @Published var isLoading = false
    
    // Filtered data source for the View
    @Published var filteredGames: [SportType: [ESPNEvent]] = [:]
    @Published var soccerSections: [(league: String, games: [ESPNEvent])] = []
    
    // Keep track of current search text to re-filter if data changes
    private var currentSearchText: String = ""
    private var refreshTask: Task<Void, Never>?

    init() {
        startAutoRefresh()
    }
    
    deinit {
        refreshTask?.cancel()
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000) // 60 seconds refresh
                await fetchScores(forceRefresh: true, silent: true)
            }
        }
    }

    nonisolated private func fetchMultiLeagueSoccer() async -> [ESPNEvent] {
        let leagues = [
            ("eng.1", "Premier League"), ("eng.2", "Championship"), ("esp.1", "La Liga"),
            ("ger.1", "Bundesliga"), ("ita.1", "Serie A"), ("fra.1", "Ligue 1"),
            ("usa.1", "MLS"), ("mex.1", "Liga MX"), ("sau.1", "Saudi Pro League"),
            ("ned.1", "Eredivisie"), ("arg.1", "Argentine Primera"), ("bra.1", "Brazilian Serie A"),
            ("por.1", "Liga Portugal"), ("tur.1", "Super Lig"), ("bel.1", "Jupiler Pro League")
        ]
        return await withTaskGroup(of: [ESPNEvent].self) { group in
            for league in leagues {
                group.addTask {
                    let urlString = "https://site.api.espn.com/apis/site/v2/sports/soccer/\(league.0)/scoreboard"
                    guard let url = URL(string: urlString),
                          let (data, _) = try? await URLSession.shared.data(from: url),
                          let decoded = try? JSONDecoder().decode(ESPNResponse.self, from: data) else { return [] }
                    return (decoded.events ?? []).map { var m = $0; m.leagueLabel = league.1; return m }
                }
            }
            var all = [ESPNEvent]()
            for await events in group { all.append(contentsOf: events) }
            return all
        }
    }

    private func getSoccerSections(from games: [ESPNEvent]) -> [(league: String, games: [ESPNEvent])] {
        let priority = ["Premier League", "La Liga", "MLS", "Bundesliga", "Serie A"]
        let filtered = games.filter {
            let label = $0.leagueLabel ?? ""
            return label != "Champions League" && label != "Europa League" && label != "Euro"
        }
        let grouped = Dictionary(grouping: filtered) { $0.leagueLabel ?? "International" }
        return grouped.keys.sorted { a, b in
            let idxA = priority.firstIndex(of: a) ?? 999
            let idxB = priority.firstIndex(of: b) ?? 999
            return idxA != idxB ? idxA < idxB : a < b
        }.map { (league: $0, games: grouped[$0]!) }
    }

    @MainActor
    func fetchScores(forceRefresh: Bool = false, silent: Bool = false) async {
        if isLoading { return }
        
        // If we have recent data for the *selected* sport, we assume others are also relatively fresh or will be loaded.
        // But the user wants EVERYTHING pre-loaded.
        // So we check if *any* sport is missing or if forceRefresh is true.
        // Or simply, check if the selected sport is stale, then refresh ALL to be safe.
        // Actually, let's just refresh all if selected is stale, or if we haven't fetched all.
        // For simplicity and to meet the requirement "Make sure every section ... is fully loaded":
        
        let now = Date()
        let needsRefresh = forceRefresh || SportType.allCases.contains { sport in
            guard let last = lastFetchTimes[sport] else { return true }
            return now.timeIntervalSince(last) > 300
        }
        
        if !needsRefresh {
            applyFilter(text: currentSearchText)
            return
        }
        
        if !silent { isLoading = true }
        
        // Fetch ALL sports concurrently
        let results = await withTaskGroup(of: (SportType, [ESPNEvent]).self) { group in
            for sport in SportType.allCases {
                group.addTask {
                    let games = (sport == .soccer) ? await self.fetchMultiLeagueSoccer() : await self.fetchSingleSport(url: sport.endpoint)
                    return (sport, games)
                }
            }
            
            var collected: [SportType: [ESPNEvent]] = [:]
            for await (sport, games) in group {
                collected[sport] = games
            }
            return collected
        }
        
        let statusPriority: [String: Int] = ["in": 0, "pre": 1, "post": 2]
        
        for (sport, newGames) in results {
            let sorted = newGames.sorted { a, b in
                let pA = statusPriority[a.status.type.state] ?? 3
                let pB = statusPriority[b.status.type.state] ?? 3
                if pA != pB { return pA < pB }
                return a.gameDate > b.gameDate
            }
            self.gamesData[sport] = sorted
            self.lastFetchTimes[sport] = Date()
            
            // Prefetch images for the new games
            prefetchImages(for: sorted)
        }
        
        applyFilter(text: currentSearchText)
        if !silent { isLoading = false }
    }
    
    private func prefetchImages(for games: [ESPNEvent]) {
        for game in games {
            // 1. Team/Athlete logos for Team Sports (32x32)
            if let home = game.homeCompetitor {
                let logo = home.team?.logo ?? home.athlete?.flag?.href ?? home.athlete?.headshot ?? ""
                if !logo.isEmpty { ImageCache.prefetch(urlString: logo, size: CGSize(width: 32, height: 32)) }
            }
            if let away = game.awayCompetitor {
                let logo = away.team?.logo ?? away.athlete?.flag?.href ?? away.athlete?.headshot ?? ""
                if !logo.isEmpty { ImageCache.prefetch(urlString: logo, size: CGSize(width: 32, height: 32)) }
            }
            
            // 2. Individual sport leaders (38x38)
            let comps = game.allCompetitions
            if let firstComp = comps.first {
                // Structured leaders
                if let leaders = firstComp.leaders {
                    for group in leaders {
                        for entry in group.leaders ?? [] {
                            if let headshot = entry.athlete?.headshot, !headshot.isEmpty {
                                ImageCache.prefetch(urlString: headshot, size: CGSize(width: 38, height: 38))
                            }
                        }
                    }
                }
                // Competitor as fallback leader
                if let firstCompetitor = firstComp.competitors?.sorted(by: { ($0.order ?? 99) < ($1.order ?? 99) }).first {
                    let image = firstCompetitor.athlete?.headshot ?? firstCompetitor.athlete?.flag?.href ?? firstCompetitor.team?.logo ?? ""
                    if !image.isEmpty {
                        ImageCache.prefetch(urlString: image, size: CGSize(width: 38, height: 38))
                    }
                }
            }
        }
    }
    
    @MainActor
    func applyFilter(text: String) {
        self.currentSearchText = text
        
        // Filter for the currently selected sport (or all if necessary, but usually we just view one)
        // To be safe for the TabView, we can filter all or just lazy load. 
        // For performance, let's filter all available data in gamesData since the user might swipe.
        
        for (sport, games) in gamesData {
            let filtered: [ESPNEvent]
            if text.isEmpty {
                filtered = games
            } else {
                filtered = games.filter { g in
                    let h = g.homeCompetitor?.team?.displayName ?? g.homeCompetitor?.athlete?.displayName ?? ""
                    let a = g.awayCompetitor?.team?.displayName ?? g.awayCompetitor?.athlete?.displayName ?? ""
                    return h.localizedCaseInsensitiveContains(text) || a.localizedCaseInsensitiveContains(text) || g.shortName.localizedCaseInsensitiveContains(text)
                }
            }
            self.filteredGames[sport] = filtered
            
            if sport == .soccer {
                self.soccerSections = self.getSoccerSections(from: filtered)
            }
        }
    }
    
    nonisolated private func fetchSingleSport(url: String) async -> [ESPNEvent] {
        guard !url.isEmpty, let url = URL(string: url) else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ESPNResponse.self, from: data)
            if url.absoluteString.contains("uefa.champions") { return (response.events ?? []).map { var m = $0; m.leagueLabel = "Champions League"; return m } }
            else if url.absoluteString.contains("uefa.europa") { return (response.events ?? []).map { var m = $0; m.leagueLabel = "Europa League"; return m } }
            return response.events ?? []
        } catch { return [] }
    }
}
