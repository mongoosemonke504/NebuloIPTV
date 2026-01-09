import Foundation
import Combine

class ScoreViewModel: ObservableObject {
    // Placeholder properties and methods
    @Published var scores: [String] = [] // Example
    
    // --- New properties/methods added for SportsHubView.swift ---
    @Published var selectedSport: SportType = .mlb // Changed to .mlb
    @Published var filteredGames: [SportType: [ESPNEvent]] = [:] // Changed to ESPNEvent
    @Published var soccerSections: [SoccerGameSection] = [] // Placeholder for soccer sections
    @Published var isLoading: Bool = false // Added for SportsHubView.swift
    
    init() {
        // Placeholder init
    }
    
    // --- New methods added for SportsHubView.swift ---
    func fetchScores(forceRefresh: Bool = false, silent: Bool = false) async {
        // Placeholder for fetching scores
        print("Fetching scores for \(selectedSport)")
        self.isLoading = true
        defer { self.isLoading = false } // Ensure isLoading is reset
        
        // Populate filteredGames with some dummy data
        self.filteredGames[selectedSport] = [
            ESPNEvent(id: "game1", shortName: "TB@NYY", status: ESPNStatus(type: ESPNStatusType(detail: "Final", state: "final")), competitions: [], date: ISO8601DateFormatter().string(from: Date()), groupings: nil, leagueLabel: "MLB"),
            ESPNEvent(id: "game2", shortName: "BOS@TOR", status: ESPNStatus(type: ESPNStatusType(detail: "Live", state: "in")), competitions: [], date: ISO8601DateFormatter().string(from: Date()), groupings: nil, leagueLabel: "MLB")
        ]
        // Placeholder for soccerSections
        self.soccerSections = [
            SoccerGameSection(league: "Premier League", games: [
                ESPNEvent(id: "sg1", shortName: "ARS vs CHE", status: ESPNStatus(type: ESPNStatusType(detail: "Final", state: "final")), competitions: [], date: ISO8601DateFormatter().string(from: Date()), groupings: nil, leagueLabel: "Premier League")
            ])
        ]
    }
    
    func applyFilter(text: String) {
        // Placeholder for applying filter
        print("Applying filter: \(text)")
        // Filter `filteredGames` based on `text`
        if text.isEmpty {
            // Restore all games if filter is empty
            // This logic assumes a full set of games is available somewhere.
            // For now, it will just clear the filter.
            self.filteredGames = [:] // Clear current filter
            // await fetchScores(silent: true) // Re-fetch all scores without showing loading indicator - commented out as this needs implementation
        } else {
            var newFilteredGames: [SportType: [ESPNEvent]] = [:]
            for (sportType, games) in filteredGames {
                newFilteredGames[sportType] = games.filter { game in
                    (game.homeCompetitor?.team?.displayName ?? "").localizedCaseInsensitiveContains(text) ||
                    (game.awayCompetitor?.team?.displayName ?? "").localizedCaseInsensitiveContains(text) ||
                    (game.leagueLabel ?? "").localizedCaseInsensitiveContains(text) ||
                    game.shortName.localizedCaseInsensitiveContains(text)
                }
            }
            self.filteredGames = newFilteredGames
        }
    }
}

// Placeholder for SoccerGameSection
struct SoccerGameSection: Identifiable {
    let id = UUID()
    let league: String
    let games: [ESPNEvent] // Changed to ESPNEvent
}

// ESPNGame struct is now replaced by ESPNEvent from ESPNModels.swift
// struct ESPNGame: Identifiable, Codable, Hashable { ... } // Removed
