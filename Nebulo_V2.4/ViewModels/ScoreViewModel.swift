import Foundation
import Combine
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
class ScoreViewModel: ObservableObject {
    @Published var filteredGames: [SportType: [ESPNEvent]] = [:]
    @Published var filteredSectionsMap: [SportType: [SoccerGameSection]] = [:]
    @Published var selectedSport: SportType = .pinned
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    
    @Published var pinnedGameIDs: Set<String> = []
    @Published var hiddenScoreGameIDs: Set<String> = []
    @Published var reminderGameIDs: Set<String> = []
    @Published var allPinnedGames: [ESPNEvent] = []
    @Published var sportTabOrder: [SportType] = []
    @Published var hiddenSportTabs: Set<SportType> = []
    @Published var renamedSportTabs: [String: String] = [:]
    private var currentSearchText = ""
    
    static let noCacheSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    
    private var masterGames: [SportType: [ESPNEvent]] = [:]
    private var masterSectionsMap: [SportType: [SoccerGameSection]] = [:]
    
    private var cancellables = Set<AnyCancellable>()
    private var lastFetchTime = Date.distantPast
    private var fetchTask: Task<Void, Never>?
    
    init() {
        loadCachedData()
        Task { await fetchScores() }
    }
    
    private func loadCachedData() {
        if let data = UserDefaults.standard.data(forKey: "cachedSportsData"),
           let cached = try? JSONDecoder().decode([String: [ESPNEvent]].self, from: data) {
            var loadedGames: [SportType: [ESPNEvent]] = [:]
            for (key, value) in cached {
                if let sport = SportType(rawValue: key) {
                    loadedGames[sport] = value
                }
            }
            self.masterGames = loadedGames
            self.filteredGames = loadedGames
        }
        
        if let data = UserDefaults.standard.data(forKey: "cachedSectionsMap"),
           let cached = try? JSONDecoder().decode([String: [SoccerGameSection]].self, from: data) {
            var loadedMap: [SportType: [SoccerGameSection]] = [:]
            for (key, value) in cached {
                if let sport = SportType(rawValue: key) {
                    loadedMap[sport] = value
                }
            }
            self.masterSectionsMap = loadedMap
            self.filteredSectionsMap = loadedMap
        }
        
        if let pinned = UserDefaults.standard.stringArray(forKey: "pinnedGameIDs") { self.pinnedGameIDs = Set(pinned) }
        if let hidden = UserDefaults.standard.stringArray(forKey: "hiddenScoreGameIDs") { self.hiddenScoreGameIDs = Set(hidden) }
        if let reminders = UserDefaults.standard.stringArray(forKey: "reminderGameIDs") { self.reminderGameIDs = Set(reminders) }
        
        if let savedOrder = UserDefaults.standard.stringArray(forKey: "sportTabOrder") {
            self.sportTabOrder = savedOrder.compactMap { SportType(rawValue: $0) }
        }
        if self.sportTabOrder.isEmpty { 
            self.sportTabOrder = SportType.allCases 
        } else if !self.sportTabOrder.contains(.pinned) {
            self.sportTabOrder.insert(.pinned, at: 0)
        }
        
        if let savedHidden = UserDefaults.standard.stringArray(forKey: "hiddenSportTabs") {
            self.hiddenSportTabs = Set(savedHidden.compactMap { SportType(rawValue: $0) })
        }
        
        self.renamedSportTabs = UserDefaults.standard.object(forKey: "renamedSportTabs") as? [String: String] ?? [:]
        
        updatePinnedGames()
        self.preloadImages()
    }
    
    private func saveToCache() {
        var cacheableGames: [String: [ESPNEvent]] = [:]
        for (key, value) in masterGames {
            cacheableGames[key.rawValue] = value
        }
        
        var cacheableMap: [String: [SoccerGameSection]] = [:]
        for (key, value) in masterSectionsMap {
            cacheableMap[key.rawValue] = value
        }
        
        if let encoded = try? JSONEncoder().encode(cacheableGames) {
            UserDefaults.standard.set(encoded, forKey: "cachedSportsData")
        }
        
        if let encoded = try? JSONEncoder().encode(cacheableMap) {
            UserDefaults.standard.set(encoded, forKey: "cachedSectionsMap")
        }
        
        UserDefaults.standard.set(Array(pinnedGameIDs), forKey: "pinnedGameIDs")
        UserDefaults.standard.set(Array(hiddenScoreGameIDs), forKey: "hiddenScoreGameIDs")
        UserDefaults.standard.set(Array(reminderGameIDs), forKey: "reminderGameIDs")
        UserDefaults.standard.set(sportTabOrder.map { $0.rawValue }, forKey: "sportTabOrder")
        UserDefaults.standard.set(Array(hiddenSportTabs).map { $0.rawValue }, forKey: "hiddenSportTabs")
        UserDefaults.standard.set(renamedSportTabs, forKey: "renamedSportTabs")
    }
    
    func moveSportTab(from source: IndexSet, to destination: Int) {
        sportTabOrder.move(fromOffsets: source, toOffset: destination)
        saveToCache()
    }
    
    func toggleSportTabVisibility(_ sport: SportType) {
        if hiddenSportTabs.contains(sport) { hiddenSportTabs.remove(sport) } else { hiddenSportTabs.insert(sport) }
        saveToCache()
    }
    
    func renameSportTab(_ sport: SportType, to newName: String) {
        renamedSportTabs[sport.rawValue] = newName
        saveToCache()
    }
    
    func getSportName(_ sport: SportType) -> String {
        return renamedSportTabs[sport.rawValue] ?? sport.rawValue
    }
    
    func togglePin(_ id: String) {
        if pinnedGameIDs.contains(id) { pinnedGameIDs.remove(id) } else { pinnedGameIDs.insert(id) }
        updatePinnedGames()
        saveToCache()
        applyFilter(text: currentSearchText)
    }
    
    func toggleHideScore(_ id: String) {
        if hiddenScoreGameIDs.contains(id) { hiddenScoreGameIDs.remove(id) } else { hiddenScoreGameIDs.insert(id) }
        saveToCache()
    }
    
    func toggleReminder(_ game: ESPNEvent) {
        if reminderGameIDs.contains(game.id) {
            reminderGameIDs.remove(game.id)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["game_\(game.id)"])
        } else {
            reminderGameIDs.insert(game.id)
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted {
                    let content = UNMutableNotificationContent()
                    content.title = "Game Reminder"
                    content.body = "\(game.shortName) is starting soon!"
                    content.sound = .default
                    let triggerDate = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: game.gameDate.addingTimeInterval(-600))
                    let trigger = UNCalendarNotificationTrigger(dateMatching: triggerDate, repeats: false)
                    let request = UNNotificationRequest(identifier: "game_\(game.id)", content: content, trigger: trigger)
                    UNUserNotificationCenter.current().add(request)
                }
            }
        }
        saveToCache()
    }
    
    private func updatePinnedGames() {
        var pinned: [ESPNEvent] = []
        for games in masterGames.values {
            pinned.append(contentsOf: games.filter { pinnedGameIDs.contains($0.id) })
        }
        for sections in masterSectionsMap.values {
            for section in sections {
                pinned.append(contentsOf: section.games.filter { pinnedGameIDs.contains($0.id) })
            }
        }
        
        var seen = Set<String>()
        var uniquePinned: [ESPNEvent] = []
        for p in pinned {
            if !seen.contains(p.id) {
                seen.insert(p.id)
                uniquePinned.append(p)
            }
        }
        self.allPinnedGames = sortGames(uniquePinned)
    }
    
    private func sortGames(_ games: [ESPNEvent]) -> [ESPNEvent] {
        return games.sorted { a, b in
            let aPinned = pinnedGameIDs.contains(a.id)
            let bPinned = pinnedGameIDs.contains(b.id)
            if aPinned != bPinned { return aPinned }
            
            let aState = a.status.type.state
            let bState = b.status.type.state
            if aState == "in" && bState != "in" { return true }
            if aState != "in" && bState == "in" { return false }
            if aState == "in" && bState == "in" { return a.gameDate > b.gameDate }
            if aState == "pre" && bState == "post" { return true }
            if aState == "post" && bState == "pre" { return false }
            if aState == "pre" && bState == "pre" { return a.gameDate > b.gameDate }
            return a.gameDate > b.gameDate
        }
    }
    
    private func preloadImages() {
        var urls = Set<String>()
        for games in masterGames.values {
            for game in games {
                if let url = game.homeCompetitor?.team?.logo ?? game.homeCompetitor?.athlete?.flag?.href ?? game.homeCompetitor?.athlete?.headshot, !url.isEmpty { urls.insert(url) }
                if let url = game.awayCompetitor?.team?.logo ?? game.awayCompetitor?.athlete?.flag?.href ?? game.awayCompetitor?.athlete?.headshot, !url.isEmpty { urls.insert(url) }
            }
        }
        for sections in masterSectionsMap.values {
            for section in sections {
                for game in section.games {
                    if let url = game.homeCompetitor?.team?.logo ?? game.homeCompetitor?.athlete?.flag?.href ?? game.homeCompetitor?.athlete?.headshot, !url.isEmpty { urls.insert(url) }
                    if let url = game.awayCompetitor?.team?.logo ?? game.awayCompetitor?.athlete?.flag?.href ?? game.awayCompetitor?.athlete?.headshot, !url.isEmpty { urls.insert(url) }
                }
            }
        }
        
        let urlsToLoad = urls
        
        Task.detached(priority: .background) {
            await withTaskGroup(of: Void.self) { group in
                var active = 0
                let limit = 20
                
                for url in urlsToLoad {
                    if await ImageCache.shared.hasImage(forKey: url) { continue }
                    if active >= limit { await group.next(); active -= 1 }
                    group.addTask { await ImageCache.prefetchAndWait(urlString: url) }
                    active += 1
                }
            }
        }
    }
    
    func fetchScores(forceRefresh: Bool = false, silent: Bool = false) async {
        if !silent && !forceRefresh {
            if !masterGames.isEmpty && !masterSectionsMap.isEmpty {
                 if Date().timeIntervalSince(lastFetchTime) < 300 { return }
            }
            if isLoading { return }
        }
        
        fetchTask?.cancel()
        if !silent { withAnimation { isLoading = true } }
        self.errorMessage = nil
        
        let newTask = Task {
            do {
                await withTaskGroup(of: (SportType, [ESPNEvent]?, [SoccerGameSection]?).self) { group in
                    group.addTask {
                        let leagues = [
                            ("eng.1", "Premier League"), ("esp.1", "La Liga"), ("ger.1", "Bundesliga"),
                            ("ita.1", "Serie A"), ("fra.1", "Ligue 1"), ("usa.1", "MLS"),
                            ("eng.2", "EFL Championship"), ("mex.1", "Liga MX"), ("ned.1", "Eredivisie"),
                            ("por.1", "Primeira Liga"), ("sco.1", "Scottish Premiership"), ("bra.1", "Brasileirão"), ("arg.1", "Argentine Primera")
                        ]
                        do {
                            let (sections, games) = try await self.fetchSoccerInternal(leagues: leagues)
                            return (.soccerLeagues, games, sections)
                        } catch { return (.soccerLeagues, nil, nil) }
                    }
                    
                    group.addTask {
                        let leagues = [
                            ("eng.fa", "FA Cup"), ("eng.league_cup", "Carabao Cup"), ("esp.copa_del_rey", "Copa del Rey"),
                            ("ger.dfb_pokal", "DFB-Pokal"), ("ita.coppa_italia", "Coppa Italia"), ("fra.coupe_de_france", "Coupe de France"),
                            ("usa.open", "US Open Cup")
                        ]
                        do {
                            let (sections, games) = try await self.fetchSoccerInternal(leagues: leagues)
                            return (.domesticCups, games, sections)
                        } catch { return (.domesticCups, nil, nil) }
                    }
                    
                    group.addTask {
                        let leagues = [
                            ("uefa.champions", "Champions League"), ("uefa.europa", "Europa League"), ("uefa.europa.conf", "Conference League"),
                            ("conmebol.libertadores", "Libertadores"), ("concacaf.champions", "Concacaf Champions"), ("afc.champions", "AFC Champions")
                        ]
                        do {
                            let (sections, games) = try await self.fetchSoccerInternal(leagues: leagues)
                            return (.continental, games, sections)
                        } catch { return (.continental, nil, nil) }
                    }
                    
                    group.addTask {
                        let leagues = [
                            ("fifa.world", "World Cup"), ("uefa.euro", "Euro"), ("conmebol.america", "Copa América"),
                            ("concacaf.gold", "Gold Cup"), ("uefa.nations", "Nations League"), ("fifa.friendly", "Friendlies"),
                            ("fifa.cwc", "Club World Cup")
                        ]
                        do {
                            let (sections, games) = try await self.fetchSoccerInternal(leagues: leagues)
                            return (.international, games, sections)
                        } catch { return (.international, nil, nil) }
                    }
                    
                    for sport in SportType.allCases {
                        if sport == .pinned || sport == .soccerLeagues || sport == .domesticCups || sport == .continental || sport == .international { continue }
                        group.addTask {
                            guard let url = URL(string: sport.endpoint) else { return (sport, nil, nil) }
                            do {
                                let events = try await self.fetchEvents(url: url)
                                return (sport, events, nil)
                            } catch { return (sport, nil, nil) }
                        }
                    }
                    
                    for await (sport, events, sections) in group {
                        await MainActor.run {
                            if let events = events {
                                self.masterGames[sport] = events
                                self.filteredGames[sport] = events
                            }
                            if let secs = sections {
                                self.masterSectionsMap[sport] = secs
                                self.filteredSectionsMap[sport] = secs
                            }
                        }
                    }
                }
                
                await MainActor.run {
                    self.updatePinnedGames()
                    self.saveToCache()
                    self.lastFetchTime = Date()
                    self.applyFilter(text: self.currentSearchText)
                    self.preloadImages()
                    self.isLoading = false
                }
            }
        }
        self.fetchTask = newTask
        _ = await newTask.result
    }
    
    nonisolated private func fetchEvents(url: URL) async throws -> [ESPNEvent] {
        let (data, _) = try await ScoreViewModel.noCacheSession.data(from: url)
        let response = try JSONDecoder().decode(ESPNResponse.self, from: data)
        var events = response.events ?? []
        events.sort { a, b in
            let aState = a.status.type.state
            let bState = b.status.type.state
            if aState == "in" && bState != "in" { return true }
            if aState != "in" && bState == "in" { return false }
            if aState == "in" && bState == "in" { return a.gameDate > b.gameDate }
            if aState == "pre" && bState == "post" { return true }
            if aState == "post" && bState == "pre" { return false }
            if aState == "pre" && bState == "pre" { return a.gameDate > b.gameDate }
            return a.gameDate > b.gameDate
        }
        return events
    }
    
    nonisolated private func fetchSoccerInternal(leagues: [(String, String)]) async throws -> ([SoccerGameSection], [ESPNEvent]) {
        var allSections: [SoccerGameSection] = []
        var allGames: [ESPNEvent] = []
        
        await withTaskGroup(of: (String, [ESPNEvent]?).self) { group in
            for (code, name) in leagues {
                group.addTask {
                    let urlStr = "https://site.api.espn.com/apis/site/v2/sports/soccer/\(code)/scoreboard"
                    guard let url = URL(string: urlStr) else { return (name, nil) }
                    do {
                        let (data, _) = try await ScoreViewModel.noCacheSession.data(from: url)
                        let res = try JSONDecoder().decode(ESPNResponse.self, from: data)
                        var events = res.events ?? []
                        events.sort { a, b in
                            let aState = a.status.type.state
                            let bState = b.status.type.state
                            if aState == "in" && bState != "in" { return true }
                            if aState != "in" && bState == "in" { return false }
                            if aState == "in" && bState == "in" { return a.gameDate > b.gameDate }
                            if aState == "pre" && bState == "post" { return true }
                            if aState == "post" && bState == "pre" { return false }
                            if aState == "pre" && bState == "pre" { return a.gameDate < b.gameDate }
                            return a.gameDate < b.gameDate
                        }
                        let tagged = events.map { e -> ESPNEvent in
                            var copy = e
                            copy.leagueLabel = name
                            return copy
                        }
                        return (name, tagged)
                    } catch { return (name, nil) }
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
    
    func applyFilter(text: String) {
        self.currentSearchText = text
        if text.isEmpty {
            var newFiltered: [SportType: [ESPNEvent]] = [:]
            for (sport, games) in masterGames {
                newFiltered[sport] = sortGames(games)
            }
            self.filteredGames = newFiltered
            self.filteredGames[.pinned] = allPinnedGames
            
            var newFilteredMap: [SportType: [SoccerGameSection]] = [:]
            for (sport, sections) in masterSectionsMap {
                newFilteredMap[sport] = sections.map { sec in
                    SoccerGameSection(id: sec.id, league: sec.league, games: sortGames(sec.games))
                }
            }
            self.filteredSectionsMap = newFilteredMap
        } else {
            let lower = text.lowercased()
            var newFiltered: [SportType: [ESPNEvent]] = [:]
            for (sport, games) in masterGames {
                let matches = games.filter { game in
                    game.shortName.lowercased().contains(lower) ||
                    (game.homeCompetitor?.team?.displayName ?? "").lowercased().contains(lower) ||
                    (game.awayCompetitor?.team?.displayName ?? "").lowercased().contains(lower)
                }
                newFiltered[sport] = sortGames(matches)
            }
            self.filteredGames = newFiltered
            self.filteredGames[.pinned] = allPinnedGames
            
            var newFilteredMap: [SportType: [SoccerGameSection]] = [:]
            for (sport, sections) in masterSectionsMap {
                let filteredSections = sections.compactMap { sec in
                    let matchingGames = sec.games.filter { game in
                        game.shortName.lowercased().contains(lower) ||
                        (game.homeCompetitor?.team?.displayName ?? "").lowercased().contains(lower) ||
                        (game.awayCompetitor?.team?.displayName ?? "").lowercased().contains(lower)
                    }
                    return matchingGames.isEmpty ? nil : SoccerGameSection(league: sec.league, games: sortGames(matchingGames))
                }
                if !filteredSections.isEmpty { newFilteredMap[sport] = filteredSections }
            }
            self.filteredSectionsMap = newFilteredMap
        }
    }
}

struct SoccerGameSection: Identifiable, Sendable, Codable {
    let id: UUID
    let league: String
    let games: [ESPNEvent]
    
    nonisolated init(id: UUID = UUID(), league: String, games: [ESPNEvent]) {
        self.id = id
        self.league = league
        self.games = games
    }
}