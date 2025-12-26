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

    init() {}

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
    func fetchScores(forceRefresh: Bool = false) async {
        if isLoading { return }
        // If data is fresh, just re-filter (in case search text changed or view re-appeared) and return
        if !forceRefresh, let lastFetch = lastFetchTimes[selectedSport], Date().timeIntervalSince(lastFetch) < 300 {
            applyFilter(text: currentSearchText)
            return
        }
        
        isLoading = true
        let newGames = (selectedSport == .soccer) ? await fetchMultiLeagueSoccer() : await fetchSingleSport(url: selectedSport.endpoint)
        let statusPriority: [String: Int] = ["in": 0, "pre": 1, "post": 2]
        let sorted = newGames.sorted { a, b in
            let pA = statusPriority[a.status.type.state] ?? 3
            let pB = statusPriority[b.status.type.state] ?? 3
            if pA != pB { return pA < pB }
            return a.gameDate > b.gameDate
        }
        self.gamesData[selectedSport] = sorted
        self.lastFetchTimes[selectedSport] = Date()
        
        applyFilter(text: currentSearchText)
        isLoading = false
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
                    let h = g.homeCompetitor?.team.displayName ?? ""
                    let a = g.awayCompetitor?.team.displayName ?? ""
                    return h.localizedCaseInsensitiveContains(text) || a.localizedCaseInsensitiveContains(text)
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
