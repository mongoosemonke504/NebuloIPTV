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
    /// Full team catalog from the ESPN team-list endpoints — every team in
    /// every covered league (clubs, national soccer sides, the F1 grid),
    /// independent of what's on today's scoreboards. Loaded from disk
    /// instantly at launch, refreshed in the background at most once a week.
    @Published private(set) var teamCatalog: [TeamCatalogService.Entry] = []
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
        loadTeamCatalog()
        Task { await fetchScores() }
    }

    private func loadTeamCatalog() {
        let cached = TeamCatalogService.loadCached()
        if let cached {
            teamCatalog = cached.entries
            migrateLegacyTeamKeys()
        }
        let isFresh = cached.map {
            !$0.entries.isEmpty && Date().timeIntervalSince($0.fetchedAt) < TeamCatalogService.refreshInterval
        } ?? false
        guard !isFresh else { return }
        let previous = cached?.entries ?? []
        Task { [weak self] in
            let entries = await TeamCatalogService.fetch(previous: previous)
            guard let self, !entries.isEmpty else { return }
            self.teamCatalog = entries
            self.migrateLegacyTeamKeys()
        }
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
                    // The soccer buckets all read from the shared competition
                    // catalog (SportType.soccerCompetitionGroups) — the same
                    // list that drives the team catalog and the pickers.
                    for (bucket, competitions) in SportType.soccerCompetitionGroups {
                        group.addTask {
                            do {
                                let (sections, games) = try await self.fetchSoccerInternal(leagues: competitions)
                                return (bucket, games, sections)
                            } catch { return (bucket, nil, nil) }
                        }
                    }

                    for sport in SportType.allCases {
                        if sport == .pinned || sport.isSoccer { continue }
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
                    self.migrateLegacyTeamKeys()
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
    
    nonisolated private func fetchSoccerInternal(leagues: [SoccerCompetition]) async throws -> ([SoccerGameSection], [ESPNEvent]) {
        var allSections: [SoccerGameSection] = []
        var allGames: [ESPNEvent] = []

        await withTaskGroup(of: (String, [ESPNEvent]?).self) { group in
            for comp in leagues {
                let code = comp.code, name = comp.name
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
            let idxA = leagues.firstIndex { $0.name == a.league } ?? 999
            let idxB = leagues.firstIndex { $0.name == b.league } ?? 999
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

    /// Composite favorite key — "<sport>|<teamID>". ESPN team ids are only
    /// unique WITHIN a sport (NFL team 1 and NBA team 1 are different
    /// franchises), so bare ids can't key favorites now that the full
    /// catalog is browsable. The four soccer buckets normalize to one
    /// "Soccer" namespace since they share a single club-id pool. Legacy
    /// bare-id keys from pre-catalog builds are still honored everywhere and
    /// migrated by `migrateLegacyTeamKeys()`.
    static func teamKey(sport: SportType?, teamID: String) -> String {
        guard let sport else { return teamID }
        let raw = sport.isSoccer ? "Soccer" : sport.rawValue
        return raw + "|" + teamID
    }

    static func decodeTeamKey(_ key: String) -> (sport: SportType?, teamID: String) {
        guard let sep = key.firstIndex(of: "|") else { return (nil, key) }
        let raw = String(key[..<sep])
        let id = String(key[key.index(after: sep)...])
        // Any soccer bucket stands in for the whole soccer pool (see
        // eventPool's compatibility rule).
        if raw == "Soccer" { return (.soccerLeagues, id) }
        return (SportType(rawValue: raw), id)
    }

    func isFavoriteTeam(_ team: ESPNTeam, sport: SportType?) -> Bool {
        favoriteTeamIDs.contains(Self.teamKey(sport: sport, teamID: team.id))
            || favoriteTeamIDs.contains(team.id)
    }

    func toggleFavoriteTeam(_ team: ESPNTeam, sport: SportType?) {
        let key = Self.teamKey(sport: sport, teamID: team.id)
        if favoriteTeamIDs.contains(key) {
            favoriteTeamIDs.remove(key)
            favoriteTeamOrder.removeAll { $0 == key }
        } else if key != team.id, favoriteTeamIDs.contains(team.id) {
            // Legacy bare-id favorite — this toggle is an unfavorite.
            favoriteTeamIDs.remove(team.id)
            favoriteTeamOrder.removeAll { $0 == team.id }
        } else {
            favoriteTeamIDs.insert(key)
            if !favoriteTeamOrder.contains(key) { favoriteTeamOrder.append(key) }
        }
        saveToCache()
    }

    /// Upgrades legacy bare-id favorites (pre-catalog builds) to composite
    /// keys whenever the known-team pool can resolve them. Runs after the
    /// catalog loads and after each scoreboard refresh; exits instantly once
    /// nothing is left to migrate.
    private func migrateLegacyTeamKeys() {
        let legacy = favoriteTeamIDs.filter { !$0.contains("|") }
        guard !legacy.isEmpty else { return }
        var sportByBareID: [String: SportType] = [:]
        for hit in allKnownTeams() where sportByBareID[hit.team.id] == nil {
            sportByBareID[hit.team.id] = hit.sport
        }
        var changed = false
        for old in legacy {
            guard let sport = sportByBareID[old] else { continue }
            let new = Self.teamKey(sport: sport, teamID: old)
            favoriteTeamIDs.remove(old)
            favoriteTeamIDs.insert(new)
            favoriteTeamOrder = favoriteTeamOrder.map { $0 == old ? new : $0 }
            changed = true
        }
        if changed { saveToCache() }
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

    /// Every team the user can browse and favorite: the persistent catalog
    /// (each league's full team list, national soccer sides, the F1 grid)
    /// plus anything on today's scoreboards the catalog doesn't know yet
    /// (e.g. MMA fighters, which have no team-list endpoint).
    func allKnownTeams() -> [(team: ESPNTeam, sport: SportType, leagueLabel: String?)] {
        var seen = Set<String>()
        var out: [(team: ESPNTeam, sport: SportType, leagueLabel: String?)] = []
        func add(_ team: ESPNTeam, _ sport: SportType, _ label: String?) {
            let sportKey = sport.isSoccer ? "Soccer" : sport.rawValue
            if seen.insert(sportKey + "#" + team.id).inserted {
                out.append((team, sport, label))
            }
        }
        for entry in teamCatalog {
            guard let sport = entry.sport else { continue }
            add(entry.team, sport, entry.leagueLabel)
        }
        for (sport, games) in masterGames {
            for game in games {
                for competitor in [game.homeCompetitor, game.awayCompetitor] {
                    if let team = competitor?.team { add(team, sport, game.leagueLabel) }
                }
            }
        }
        for (sport, sections) in masterSectionsMap {
            for section in sections {
                for game in section.games {
                    for competitor in [game.homeCompetitor, game.awayCompetitor] {
                        if let team = competitor?.team { add(team, sport, section.league) }
                    }
                }
            }
        }
        return out.sorted { ($0.team.displayName ?? "") < ($1.team.displayName ?? "") }
    }

    /// The user's Sports-hub tab order with any newly-added sports appended
    /// (and Pinned dropped) — the canonical ordering for pickers.
    var orderedSports: [SportType] {
        let saved = sportTabOrder.filter { $0 != .pinned }
        return saved + SportType.allCases.filter { $0 != .pinned && !saved.contains($0) }
    }

    /// Every league the user can favorite — the full configured catalog
    /// (all soccer competitions plus every standalone sport), then anything
    /// seen on today's scoreboards that isn't covered above. Returned in
    /// display order: soccer competitions grouped leagues → cups →
    /// continental → international, then the standalone sports in the same
    /// order as the Sports-hub tabs.
    func allKnownLeagues() -> [(sport: SportType, leagueLabel: String?, displayName: String)] {
        var seen = Set<String>()
        var out: [(SportType, String?, String)] = []
        for (bucket, competitions) in SportType.soccerCompetitionGroups {
            for comp in competitions {
                let key = Self.leagueKey(sport: bucket, leagueLabel: comp.name)
                if seen.insert(key).inserted {
                    out.append((bucket, comp.name, comp.name))
                }
            }
        }
        for sport in orderedSports where !sport.endpoint.isEmpty {
            let key = Self.leagueKey(sport: sport, leagueLabel: nil)
            if seen.insert(key).inserted {
                out.append((sport, nil, sport.rawValue))
            }
        }
        for (sport, sections) in masterSectionsMap {
            for section in sections {
                let key = Self.leagueKey(sport: sport, leagueLabel: section.league)
                if seen.insert(key).inserted {
                    out.append((sport, section.league, section.league))
                }
            }
        }
        return out
    }

    /// Resolves favorited team keys to live ESPNTeam structs. Preserves the
    /// user's chosen order and handles both composite ("NFL|22") and legacy
    /// bare-id keys. With the catalog loaded this always resolves to a real
    /// name and logo; the stub path only remains for a first launch with no
    /// network, and heals on the next catalog or scoreboard refresh.
    func resolvedFavoriteTeams() -> [(team: ESPNTeam, sport: SportType?, leagueLabel: String?)] {
        let known = allKnownTeams()
        var byKey: [String: (team: ESPNTeam, sport: SportType, leagueLabel: String?)] = [:]
        var byBareID: [String: (team: ESPNTeam, sport: SportType, leagueLabel: String?)] = [:]
        for hit in known {
            let key = Self.teamKey(sport: hit.sport, teamID: hit.team.id)
            if byKey[key] == nil { byKey[key] = hit }
            if byBareID[hit.team.id] == nil { byBareID[hit.team.id] = hit }
        }
        let ordered = favoriteTeamOrder.filter { favoriteTeamIDs.contains($0) }
            + favoriteTeamIDs.subtracting(favoriteTeamOrder).sorted()
        return ordered.compactMap { key in
            let parts = Self.decodeTeamKey(key)
            if let hit = byKey[key] ?? byBareID[parts.teamID] {
                return (hit.team, hit.sport, hit.leagueLabel)
            }
            return (ESPNTeam(id: parts.teamID, abbreviation: nil, displayName: nil, shortDisplayName: nil, logo: nil, color: nil), parts.sport, nil)
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

    /// True when any competitor in the event is the given team — or, for
    /// athlete-based sports like F1, the given driver. Scans every
    /// competitor (not just home/away) so multi-entrant events match.
    /// Scoreboard athletes carry NO id, so drivers are matched by the
    /// display name resolved from the team catalog (identical strings —
    /// both feeds use "Kimi Antonelli"-style names).
    nonisolated private static func eventInvolves(_ ev: ESPNEvent, participantID: String, athleteName: String? = nil) -> Bool {
        for comp in ev.allCompetitions {
            for c in comp.competitors ?? [] {
                if c.team?.id == participantID || c.athlete?.id == participantID { return true }
                if let name = athleteName, let a = c.athlete,
                   a.displayName == name || a.fullName == name {
                    return true
                }
            }
        }
        return false
    }

    /// Display name for athlete-based favorites — needed because scoreboard
    /// competitors don't include athlete ids (see `eventInvolves`).
    private func athleteName(sport: SportType?, id: String) -> String? {
        guard sport == .f1 else { return nil }
        return teamCatalog.first(where: { $0.sportRaw == SportType.f1.rawValue && $0.team.id == id })?.team.displayName
    }

    /// Every cached event in score buckets compatible with the favorite's
    /// sport (nil = everything). All four soccer tabs count as one sport —
    /// a favorited club's cup and continental fixtures must surface
    /// alongside its league games.
    private func eventPool(for sport: SportType?) -> [ESPNEvent] {
        func compatible(_ bucket: SportType) -> Bool {
            guard let sport else { return true }
            return bucket == sport || (bucket.isSoccer && sport.isSoccer)
        }
        var pool: [ESPNEvent] = []
        for (bucket, games) in masterGames where compatible(bucket) { pool.append(contentsOf: games) }
        for (bucket, sections) in masterSectionsMap where compatible(bucket) {
            for section in sections { pool.append(contentsOf: section.games) }
        }
        return pool
    }

    /// Returns the live (or else next) game for a favorited team or driver.
    /// Accepts either a composite favorite key ("NFL|22") or a bare team id.
    func liveOrNextGame(forTeamID key: String) -> ESPNEvent? {
        let (sport, id) = Self.decodeTeamKey(key)
        let name = athleteName(sport: sport, id: id)
        let matches = eventPool(for: sport).filter { Self.eventInvolves($0, participantID: id, athleteName: name) }
        if let live = matches.first(where: { $0.status.type.state == "in" }) { return live }
        let upcoming = matches.filter { $0.status.type.state == "pre" }.sorted { $0.gameDate < $1.gameDate }
        return upcoming.first ?? matches.first
    }

    /// Every known game for a team or driver, ordered live → upcoming →
    /// past. Accepts either a composite favorite key or a bare team id.
    /// Used by the Team detail sheet in the Favorites hub.
    func gamesForTeam(_ key: String) -> [ESPNEvent] {
        let (sport, id) = Self.decodeTeamKey(key)
        let name = athleteName(sport: sport, id: id)
        var seen = Set<String>()
        let matches = eventPool(for: sport)
            .filter { ev in
                guard Self.eventInvolves(ev, participantID: id, athleteName: name) else { return false }
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