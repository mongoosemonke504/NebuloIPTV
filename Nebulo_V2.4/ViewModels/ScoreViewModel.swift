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
    /// Favorited ESPN teams (keyed by `ESPNTeam.id`). Surfaced in the Favorites
    /// hub and used to suggest games/streams across the app.
    @Published var favoriteTeamIDs: Set<String> = []
    /// User-chosen order for favorited teams in the Favorites hub.
    @Published var favoriteTeamOrder: [String] = []
    /// Favorited leagues. Keyed as `"<SportType.rawValue>"` for top-level
    /// sports, or `"<SportType.rawValue>|<leagueLabel>"` for the soccer/cup
    /// buckets where multiple leagues share one tab (Premier League, La Liga…).
    @Published var favoriteLeagueKeys: Set<String> = []
    @Published var favoriteLeagueOrder: [String] = []
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
        if let teams = UserDefaults.standard.stringArray(forKey: "favoriteTeamIDs") { self.favoriteTeamIDs = Set(teams) }
        if let teamOrder = UserDefaults.standard.stringArray(forKey: "favoriteTeamOrder") { self.favoriteTeamOrder = teamOrder }
        if let leagues = UserDefaults.standard.stringArray(forKey: "favoriteLeagueKeys") { self.favoriteLeagueKeys = Set(leagues) }
        if let leagueOrder = UserDefaults.standard.stringArray(forKey: "favoriteLeagueOrder") { self.favoriteLeagueOrder = leagueOrder }
        
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
        recomputeLiveGames()
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
        UserDefaults.standard.set(Array(favoriteTeamIDs), forKey: "favoriteTeamIDs")
        UserDefaults.standard.set(favoriteTeamOrder, forKey: "favoriteTeamOrder")
        UserDefaults.standard.set(Array(favoriteLeagueKeys), forKey: "favoriteLeagueKeys")
        UserDefaults.standard.set(favoriteLeagueOrder, forKey: "favoriteLeagueOrder")
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
    
    /// Pre-computed snapshot of all currently-live games across every sport.
    /// Refreshed by `recomputeLiveGames()` whenever `filteredGames` or
    /// `filteredSectionsMap` mutate — never re-walked from `body`. Views
    /// can read this directly with zero per-frame cost.
    @Published private(set) var allLiveGames: [ESPNEvent] = []

    /// Monotonically-increasing revision counter — bumped each time the live
    /// games snapshot is refreshed. Used as a `.task(id:)` key in views that
    /// want to react only when the live set actually changes (not on every
    /// score tick or filter input).
    @Published private(set) var allLiveGameIDsKey: Int = 0

    /// Recompute `allLiveGames` from the current `filteredGames` /
    /// `filteredSectionsMap`. Call after either of those publishes.
    private func recomputeLiveGames() {
        var pool: [ESPNEvent] = []
        for games in filteredGames.values { pool.append(contentsOf: games) }
        for sections in filteredSectionsMap.values {
            for section in sections { pool.append(contentsOf: section.games) }
        }
        var seen = Set<String>()
        var result: [ESPNEvent] = []
        for game in pool where game.status.type.state == "in" {
            if seen.insert(game.id).inserted {
                result.append(game)
            }
        }
        let sorted = result.sorted { $0.gameDate > $1.gameDate }
        // Only publish when the set actually changed — avoids spurious
        // re-renders when scores tick on the same set of games.
        let newIDs = sorted.map { $0.id }
        let oldIDs = self.allLiveGames.map { $0.id }
        if newIDs != oldIDs {
            self.allLiveGames = sorted
            self.allLiveGameIDsKey &+= 1
        } else if !newIDs.isEmpty {
            // Same id list — refresh the array so detail/score changes flow
            // through to subscribers, but don't bump the key (no tasks fire).
            self.allLiveGames = sorted
        }
    }

    /// Best-guess sport classification for an arbitrary live game, used by
    /// the Live Now shelf for tap handling (it needs a SportType to call
    /// `runSmartSearch`). Walks the master maps and returns the first sport
    /// whose game list contains the event id.
    func sportType(for game: ESPNEvent) -> SportType {
        for (sport, games) in masterGames where games.contains(where: { $0.id == game.id }) {
            return sport
        }
        for (sport, sections) in masterSectionsMap {
            for section in sections where section.games.contains(where: { $0.id == game.id }) {
                return sport
            }
        }
        return .nfl // safe fallback — runSmartSearch only uses this for sport-specific lookups
    }

    /// Look up a currently-live ESPN game that matches a given channel.
    /// Match priority: broadcast-name match → both team names appear in EPG title → shortName in EPG title.
    func liveGame(for channel: StreamChannel, currentEPGTitle: String?) -> ESPNEvent? {
        // Collect every event we know about (master + soccer sections)
        var pool: [ESPNEvent] = []
        for games in masterGames.values { pool.append(contentsOf: games) }
        for sections in masterSectionsMap.values {
            for section in sections { pool.append(contentsOf: section.games) }
        }
        // Only live ones
        let live = pool.filter { $0.status.type.state == "in" }
        if live.isEmpty { return nil }

        let channelLower = channel.name.lowercased()
        let epgLower = (currentEPGTitle ?? "").lowercased()

        // 1) Broadcast name overlaps the channel name
        if let match = live.first(where: { ev in
            guard let bn = ev.broadcastName?.lowercased(), !bn.isEmpty else { return false }
            return channelLower.contains(bn) || bn.contains(channelLower)
        }) { return match }

        // 2) Both team display names appear in the EPG title
        if !epgLower.isEmpty {
            if let match = live.first(where: { ev in
                let home = (ev.homeCompetitor?.team?.shortDisplayName ?? ev.homeCompetitor?.team?.displayName ?? "").lowercased()
                let away = (ev.awayCompetitor?.team?.shortDisplayName ?? ev.awayCompetitor?.team?.displayName ?? "").lowercased()
                guard !home.isEmpty && !away.isEmpty else { return false }
                return epgLower.contains(home) && epgLower.contains(away)
            }) { return match }
        }

        // 3) shortName (e.g. "MAN VS LIV") appears in EPG title
        if !epgLower.isEmpty {
            if let match = live.first(where: { ev in
                let parts = ev.shortName.lowercased().components(separatedBy: CharacterSet(charactersIn: " @-/")).filter { !$0.isEmpty && $0 != "vs" && $0 != "v" }
                guard parts.count >= 2 else { return false }
                return parts.allSatisfy { epgLower.contains($0) }
            }) { return match }
        }

        return nil
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
        // Filtered maps changed → refresh the live games snapshot once.
        recomputeLiveGames()
    }

    // MARK: - Favorite teams & leagues

    /// Stable key for a league favorite. Soccer/cup buckets reuse the same
    /// SportType for many leagues, so we disambiguate with `|<leagueLabel>`.
    static func leagueKey(sport: SportType, leagueLabel: String?) -> String {
        if let label = leagueLabel, !label.isEmpty { return "\(sport.rawValue)|\(label)" }
        return sport.rawValue
    }

    /// Decomposes a league key back into its parts.
    static func decodeLeagueKey(_ key: String) -> (sport: SportType, leagueLabel: String?) {
        if let sep = key.firstIndex(of: "|") {
            let sportRaw = String(key[..<sep])
            let label = String(key[key.index(after: sep)...])
            return (SportType(rawValue: sportRaw) ?? .nfl, label)
        }
        return (SportType(rawValue: key) ?? .nfl, nil)
    }

    func isFavoriteTeam(_ team: ESPNTeam) -> Bool { favoriteTeamIDs.contains(team.id) }

    func toggleFavoriteTeam(_ team: ESPNTeam) {
        if favoriteTeamIDs.contains(team.id) {
            favoriteTeamIDs.remove(team.id)
            favoriteTeamOrder.removeAll { $0 == team.id }
        } else {
            favoriteTeamIDs.insert(team.id)
            if !favoriteTeamOrder.contains(team.id) { favoriteTeamOrder.append(team.id) }
        }
        saveToCache()
    }

    func isFavoriteLeague(sport: SportType, leagueLabel: String?) -> Bool {
        favoriteLeagueKeys.contains(Self.leagueKey(sport: sport, leagueLabel: leagueLabel))
    }

    func toggleFavoriteLeague(sport: SportType, leagueLabel: String?) {
        let key = Self.leagueKey(sport: sport, leagueLabel: leagueLabel)
        if favoriteLeagueKeys.contains(key) {
            favoriteLeagueKeys.remove(key)
            favoriteLeagueOrder.removeAll { $0 == key }
        } else {
            favoriteLeagueKeys.insert(key)
            if !favoriteLeagueOrder.contains(key) { favoriteLeagueOrder.append(key) }
        }
        saveToCache()
    }

    func moveFavoriteTeams(from source: IndexSet, to destination: Int) {
        favoriteTeamOrder.move(fromOffsets: source, toOffset: destination)
        saveToCache()
    }

    func moveFavoriteLeagues(from source: IndexSet, to destination: Int) {
        favoriteLeagueOrder.move(fromOffsets: source, toOffset: destination)
        saveToCache()
    }

    /// Walks the master game pool and returns every unique ESPNTeam — used by
    /// the "Add team to favorites" picker so the user can browse the entire
    /// roster the API has surfaced this session.
    func allKnownTeams() -> [(team: ESPNTeam, sport: SportType, leagueLabel: String?)] {
        var seen = Set<String>()
        var out: [(ESPNTeam, SportType, String?)] = []
        for (sport, games) in masterGames {
            for game in games {
                for competitor in [game.homeCompetitor, game.awayCompetitor] {
                    if let team = competitor?.team, seen.insert(team.id).inserted {
                        out.append((team, sport, game.leagueLabel))
                    }
                }
            }
        }
        for (sport, sections) in masterSectionsMap {
            for section in sections {
                for game in section.games {
                    for competitor in [game.homeCompetitor, game.awayCompetitor] {
                        if let team = competitor?.team, seen.insert(team.id).inserted {
                            out.append((team, sport, section.league))
                        }
                    }
                }
            }
        }
        return out.sorted { ($0.0.displayName ?? "") < ($1.0.displayName ?? "") }
    }

    /// All league keys the user could favorite — the cartesian product of
    /// (sport, leagueLabel) we've actually seen this session.
    func allKnownLeagues() -> [(sport: SportType, leagueLabel: String?, displayName: String)] {
        var seen = Set<String>()
        var out: [(SportType, String?, String)] = []
        for (sport, sections) in masterSectionsMap {
            for section in sections {
                let key = Self.leagueKey(sport: sport, leagueLabel: section.league)
                if seen.insert(key).inserted {
                    out.append((sport, section.league, section.league))
                }
            }
        }
        for (sport, games) in masterGames {
            guard !games.isEmpty else { continue }
            let key = Self.leagueKey(sport: sport, leagueLabel: nil)
            if seen.insert(key).inserted {
                out.append((sport, nil, sport.rawValue))
            }
        }
        return out.sorted { $0.2 < $1.2 }
    }

    /// Resolves favorited team IDs to live ESPNTeam structs (using whatever
    /// pool we've seen this session). Preserves the user's chosen order;
    /// teams not yet seen this session are returned without a sport context.
    func resolvedFavoriteTeams() -> [(team: ESPNTeam, sport: SportType?, leagueLabel: String?)] {
        let known = Dictionary(uniqueKeysWithValues: allKnownTeams().map { ($0.team.id, $0) })
        let ordered = favoriteTeamOrder.filter { favoriteTeamIDs.contains($0) }
            + favoriteTeamIDs.subtracting(favoriteTeamOrder).sorted()
        return ordered.compactMap { id in
            if let hit = known[id] { return (hit.team, hit.sport, hit.leagueLabel) }
            // Unknown team — synthesize a stub so it still renders. Sport/league
            // will resolve next time the scoreboard refresh surfaces it.
            return (ESPNTeam(id: id, abbreviation: nil, displayName: nil, shortDisplayName: nil, logo: nil, color: nil), nil, nil)
        }
    }

    /// Resolves favorited league keys to (sport, label) pairs in user order.
    func resolvedFavoriteLeagues() -> [(sport: SportType, leagueLabel: String?, displayName: String)] {
        let ordered = favoriteLeagueOrder.filter { favoriteLeagueKeys.contains($0) }
            + favoriteLeagueKeys.subtracting(favoriteLeagueOrder).sorted()
        return ordered.map { key in
            let parts = Self.decodeLeagueKey(key)
            let name = parts.leagueLabel ?? parts.sport.rawValue
            return (parts.sport, parts.leagueLabel, name)
        }
    }

    /// Returns the next live game for a given team, if any.
    func liveOrNextGame(forTeamID teamID: String) -> ESPNEvent? {
        var pool: [ESPNEvent] = []
        for games in masterGames.values { pool.append(contentsOf: games) }
        for sections in masterSectionsMap.values {
            for section in sections { pool.append(contentsOf: section.games) }
        }
        let matches = pool.filter { ev in
            ev.homeCompetitor?.team?.id == teamID || ev.awayCompetitor?.team?.id == teamID
        }
        if let live = matches.first(where: { $0.status.type.state == "in" }) { return live }
        let upcoming = matches.filter { $0.status.type.state == "pre" }.sorted { $0.gameDate < $1.gameDate }
        return upcoming.first ?? matches.first
    }

    /// Every known game for a team, ordered live → upcoming → past. Used by
    /// the Team detail sheet to surface a roster of fixtures the user can dig
    /// into from the Favorites hub.
    func gamesForTeam(_ teamID: String) -> [ESPNEvent] {
        var pool: [ESPNEvent] = []
        for games in masterGames.values { pool.append(contentsOf: games) }
        for sections in masterSectionsMap.values {
            for section in sections { pool.append(contentsOf: section.games) }
        }
        var seen = Set<String>()
        let matches = pool
            .filter { ev in
                let homeID = ev.homeCompetitor?.team?.id
                let awayID = ev.awayCompetitor?.team?.id
                guard homeID == teamID || awayID == teamID else { return false }
                return seen.insert(ev.id).inserted
            }
        return matches.sorted { a, b in
            // Live first
            if a.status.type.state == "in" && b.status.type.state != "in" { return true }
            if a.status.type.state != "in" && b.status.type.state == "in" { return false }
            // Then upcoming chronologically, then past chronologically reversed
            let aPre = a.status.type.state == "pre"
            let bPre = b.status.type.state == "pre"
            if aPre && bPre { return a.gameDate < b.gameDate }
            if aPre && !bPre { return true }
            if !aPre && bPre { return false }
            return a.gameDate > b.gameDate
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