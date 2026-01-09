import Foundation
import Combine
import SwiftUI

@MainActor
class ScoreViewModel: ObservableObject {
    @Published var filteredGames: [SportType: [ESPNEvent]] = [:]
    @Published var soccerSections: [SoccerGameSection] = []
    @Published var selectedSport: SportType = .nfl
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    
    private var masterGames: [SportType: [ESPNEvent]] = [:]
    private var masterSoccerSections: [SoccerGameSection] = []
    
    private var cancellables = Set<AnyCancellable>()
    private var lastFetchTime = Date()
    private var fetchTask: Task<Void, Never>?
    
    init() {
        Task { await fetchScores() }
    }
    
    func fetchScores(forceRefresh: Bool = false, silent: Bool = false) async {
        if !silent && !forceRefresh {
            if isLoading { return }
            if Date().timeIntervalSince(lastFetchTime) < 30 { return }
        }
        
        fetchTask?.cancel()
        
        if !silent {
            withAnimation { isLoading = true }
        }
        self.errorMessage = nil
        
        fetchTask = Task {
            do {
                // Fetch ALL sports concurrently
                await withTaskGroup(of: (SportType, [ESPNEvent]?, [SoccerGameSection]?).self) { group in
                    // 1. Add task for Soccer (special handling)
                    group.addTask {
                        do {
                            let (sections, games) = try await self.fetchSoccerInternal()
                            return (.soccer, games, sections)
                        } catch {
                            print("Error fetching soccer: \(error)")
                            return (.soccer, nil, nil)
                        }
                    }
                    
                    // 2. Add tasks for all other sports
                    for sport in SportType.allCases where sport != .soccer {
                        group.addTask {
                            guard let url = URL(string: sport.endpoint) else { return (sport, nil, nil) }
                            do {
                                let events = try await self.fetchEvents(url: url)
                                return (sport, events, nil)
                            } catch {
                                print("Error fetching \(sport.rawValue): \(error)")
                                return (sport, nil, nil)
                            }
                        }
                    }
                    
                    // 3. Collect results
                    for await (sport, events, soccerSections) in group {
                        await MainActor.run {
                            if let events = events {
                                self.masterGames[sport] = events
                                self.filteredGames[sport] = events
                            }
                            if sport == .soccer, let sections = soccerSections {
                                self.masterSoccerSections = sections
                                self.soccerSections = sections
                            }
                        }
                    }
                }
                
                await MainActor.run {
                    self.isLoading = false
                    self.lastFetchTime = Date()
                }
                
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func fetchEvents(url: URL) async throws -> [ESPNEvent] {
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(ESPNResponse.self, from: data)
        var events = response.events ?? []
        events.sort { a, b in
            let aState = a.status.type.state
            let bState = b.status.type.state
            if aState == "in" && bState != "in" { return true }
            if aState != "in" && bState == "in" { return false }
            return a.gameDate < b.gameDate
        }
        return events
    }
    
    // Extracted internal fetch for Soccer to return data instead of setting state directly
    private func fetchSoccerInternal() async throws -> ([SoccerGameSection], [ESPNEvent]) {
        let leagues = [
            ("eng.1", "Premier League"),
            ("esp.1", "La Liga"),
            ("ger.1", "Bundesliga"),
            ("ita.1", "Serie A"),
            ("fra.1", "Ligue 1"),
            ("usa.1", "MLS"),
            ("uefa.champions", "Champions League"),
            ("uefa.europa", "Europa League")
        ]
        
        var allSections: [SoccerGameSection] = []
        var allGames: [ESPNEvent] = []
        
        await withTaskGroup(of: (String, [ESPNEvent]?).self) { group in
            for (code, name) in leagues {
                group.addTask {
                    let urlStr = "https://site.api.espn.com/apis/site/v2/sports/soccer/\(code)/scoreboard"
                    guard let url = URL(string: urlStr) else { return (name, nil) }
                    do {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        let res = try JSONDecoder().decode(ESPNResponse.self, from: data)
                        let events = res.events ?? []
                        let tagged = events.map { e -> ESPNEvent in
                            var copy = e
                            copy.leagueLabel = name
                            return copy
                        }
                        return (name, tagged)
                    } catch {
                        return (name, nil)
                    }
                }
            }
            
            for await (name, events) in group {
                if let evs = events, !evs.isEmpty {
                    allSections.append(SoccerGameSection(league: name, games: evs))
                    allGames.append(contentsOf: evs)
                }
            }
        }
        
        allSections.sort { a, b in
            let idxA = leagues.firstIndex { $0.1 == a.league } ?? 999
            let idxB = leagues.firstIndex { $0.1 == b.league } ?? 999
            return idxA < idxB
        }
        
        return (allSections, allGames)
    }
    
    private func fetchSoccer() async throws {
        // Wrapper for legacy or specific calls if needed, but fetchScores now handles it.
        // Keeping this implementation to satisfy any other internal calls or just delegating.
        let (sections, games) = try await fetchSoccerInternal()
        await MainActor.run {
            self.masterSoccerSections = sections
            self.soccerSections = sections
            self.masterGames[.soccer] = games
            self.filteredGames[.soccer] = games
            self.isLoading = false
            self.lastFetchTime = Date()
        }
    }
    
    func applyFilter(text: String) {
        if text.isEmpty {
            self.filteredGames = self.masterGames
            self.soccerSections = self.masterSoccerSections
        } else {
            let lower = text.lowercased()
            
            // Filter general games
            var newFiltered: [SportType: [ESPNEvent]] = [:]
            for (sport, games) in masterGames {
                newFiltered[sport] = games.filter { game in
                    game.shortName.lowercased().contains(lower) ||
                    (game.homeCompetitor?.team?.displayName ?? "").lowercased().contains(lower) ||
                    (game.awayCompetitor?.team?.displayName ?? "").lowercased().contains(lower)
                }
            }
            self.filteredGames = newFiltered
            
            // Filter soccer sections
            self.soccerSections = self.masterSoccerSections.compactMap { sec in
                let matchingGames = sec.games.filter { game in
                    game.shortName.lowercased().contains(lower) ||
                    (game.homeCompetitor?.team?.displayName ?? "").lowercased().contains(lower) ||
                    (game.awayCompetitor?.team?.displayName ?? "").lowercased().contains(lower)
                }
                if matchingGames.isEmpty { return nil }
                return SoccerGameSection(league: sec.league, games: matchingGames)
            }
        }
    }
}

struct SoccerGameSection: Identifiable, Sendable {
    let id = UUID()
    let league: String
    let games: [ESPNEvent]
}