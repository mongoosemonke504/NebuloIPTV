import SwiftUI
import Combine
import UIKit

// MARK: - VIEW MODELS
@MainActor
class ChannelViewModel: ObservableObject {
    static let shared = ChannelViewModel()
    
    @Published var categories: [StreamCategory] = []
    @Published var channels: [StreamChannel] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    
    // Split Search Results
    @Published var filteredEPGChannels: [StreamChannel] = []
    @Published var filteredNameChannels: [StreamChannel] = []
    @Published var filteredCategories: [StreamCategory] = []
    @Published var recentQueries: [String] = []
    
    @Published var searchText: String = "" {
        didSet {
            performSearch()
        }
    }
    @Published var isSearching: Bool = false
    @Published var sportsConfigs: [SportConfig] = []
    @Published var sportsChannels: [String: [StreamChannel]] = [:]
    @Published var favoriteIDs: Set<Int> = []
    @Published var hiddenIDs: Set<Int> = []
    @Published var excludedSportsIDs: Set<Int> = []
    @Published var recentIDs: [Int] = []
    @Published var showRenameAlert = false
    @Published var renameInput = ""
    @Published var channelToAutoPlay: StreamChannel? = nil
    @Published var multiViewSlots: [StreamChannel?] = [nil, nil, nil, nil]
    @Published var triggerMultiView = false
    @Published var multiViewModeActive = false
    @Published var showNoStreamsAlert = false
    @Published var suggestedChannels: [StreamChannel] = []
    @Published var showSelectionSheet = false
    @Published var isSearchingGame = false
    @Published var lastPlayedChannelID: Int? = nil
    @Published var lastSelectedHomeID: Int? = nil
    @Published var lastSourceCategory: StreamCategory? = nil
    @Published var scrollRestoreTrigger = UUID()
    @Published var draggingChannel: StreamChannel? = nil
    @Published var miniPlayerChannel: StreamChannel? = nil
    @Published var currentTime: Date = Date()
    
    // Manual Sort Order
    @Published var manualChannelOrder: [Int] = []
    
    // EPG State
    @Published var epgData: [String: [EPGProgram]] = [:]
    private var epgNameMap: [String: String] = [:] // Channel Name -> EPG ID
    @Published var epgProgress: Double = 0
    @Published var isUpdatingEPG: Bool = false
    @Published var loadingStatus: String = "Loading..." // New status property
    
    private var lastEPGUpdateTime: Date? {
        get {
            guard let interval = UserDefaults.standard.object(forKey: settingsPrefix + "lastEPGUpdate") as? TimeInterval else { return nil }
            return Date(timeIntervalSince1970: interval)
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: settingsPrefix + "lastEPGUpdate")
            } else {
                UserDefaults.standard.removeObject(forKey: settingsPrefix + "lastEPGUpdate")
            }
        }
    }
    
    // Smoothing / Fake Progress state
    @Published private var visualProgress: Double = 0
    private var epgClockTimer: AnyCancellable?
    private var smoothingTimer: AnyCancellable?
    
    private var onRenameConfirm: ((String) -> Void)?
    private var renamedChannels: [Int: String] = [:]
    private var renamedCategories: [Int: String] = [:]
    private var searchTask: Task<Void, Never>?
    private var settingsPrefix: String = ""
    var activeMultiViewCount: Int { multiViewSlots.compactMap { $0 }.count }
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        loadSettings()
        startEPGClock()
        
        // Observe Account Changes
        AccountManager.shared.$currentAccount
            .receive(on: RunLoop.main)
            .sink { [weak self] account in
                guard let self = self, let _ = account else { return }
                Task {
                    await self.loadCurrentAccount()
                }
            }
            .store(in: &cancellables)
            
        // Trigger initial load if account is already present
        if AccountManager.shared.currentAccount != nil {
            Task { await self.loadCurrentAccount() }
        }
    }
    
    func loadCurrentAccount() async {
        guard let account = AccountManager.shared.currentAccount else { return }
        self.reset()
        
        // 1. Instant Load from Cache
        if let (cachedChannels, cachedCategories) = loadFromCache() {
            self.channels = cachedChannels
            self.categories = cachedCategories
            self.categorizeSports()
            print("🚀 [ChannelViewModel] Instant loaded \(channels.count) channels from disk cache.")
        }
        
        // 2. Network Refresh
        await loadData(url: account.url, user: account.username ?? "", pass: account.password ?? "", mac: account.macAddress, type: account.type)
    }
    
    private func saveToCache() {
        let prefix = self.settingsPrefix
        let channelsToCache = self.channels
        let categoriesToCache = self.categories
        
        Task.detached(priority: .background) {
            let channelsData = try? JSONEncoder().encode(channelsToCache)
            let categoriesData = try? JSONEncoder().encode(categoriesToCache)
            
            if let data = channelsData {
                UserDefaults.standard.set(data, forKey: prefix + "cached_channels_v2")
            }
            if let data = categoriesData {
                UserDefaults.standard.set(data, forKey: prefix + "cached_categories_v2")
            }
        }
    }
    
    private func loadFromCache() -> ([StreamChannel], [StreamCategory])? {
        let prefix = self.settingsPrefix
        guard let channelsData = UserDefaults.standard.data(forKey: prefix + "cached_channels_v2"),
              let categoriesData = UserDefaults.standard.data(forKey: prefix + "cached_categories_v2") else {
            return nil
        }
        
        let channels = (try? JSONDecoder().decode([StreamChannel].self, from: channelsData)) ?? []
        let categories = (try? JSONDecoder().decode([StreamCategory].self, from: categoriesData)) ?? []
        
        if channels.isEmpty { return nil }
        return (channels, categories)
    }
    
    func reset() {
        self.channels = []; self.categories = []; self.filteredEPGChannels = []; self.filteredNameChannels = []; self.filteredCategories = []; self.sportsChannels = [:]
        self.searchText = ""; self.errorMessage = nil; self.isLoading = false; self.isSearchingGame = false
        self.multiViewSlots = [nil, nil, nil, nil]; self.multiViewModeActive = false; self.suggestedChannels = []
        self.showSelectionSheet = false; self.epgData = [:]
    }
    
    func prewarmChannel(_ channel: StreamChannel) {
        if let url = URL(string: channel.streamURL) {
            NebuloPlayerEngine.shared.prepareNextChannel(url: url)
        }
    }

    func backgroundFetch() async -> UIBackgroundFetchResult {
        let url = UserDefaults.standard.string(forKey: "xstreamURL") ?? ""
        let user = UserDefaults.standard.string(forKey: "username") ?? ""
        let pass = UserDefaults.standard.string(forKey: "password") ?? ""
        
        guard !url.isEmpty, let baseURL = URL(string: url) else { return .noData }
        
        // Force update EPG in background (silent)
        await updateEPG(baseURL: baseURL, user: user, pass: pass, force: true, silent: true)
        return .newData
    }

    private func startEPGClock() {
        epgClockTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.currentTime = Date() }
    }

    func getCurrentProgram(for channel: StreamChannel) -> EPGProgram? {
        let eID: String? = {
            if let id = channel.epgID, epgData[id] != nil { return id }
            // Fallback: Check name map
            return epgNameMap[channel.name.lowercased()]
        }()
        
        guard let id = eID, let schedule = epgData[id] else { return nil }
        return schedule.first { currentTime >= $0.start && currentTime <= $0.stop }
    }

    func getNextProgram(for channel: StreamChannel) -> EPGProgram? {
        let eID: String? = {
            if let id = channel.epgID, epgData[id] != nil { return id }
            return epgNameMap[channel.name.lowercased()]
        }()
        
        guard let id = eID, let schedule = epgData[id] else { return nil }
        guard let current = schedule.first(where: { currentTime >= $0.start && currentTime <= $0.stop }) else {
            return schedule.filter { $0.start > currentTime }.sorted { $0.start < $1.start }.first
        }
        return schedule.filter { $0.start >= current.stop }.sorted { $0.start < $1.start }.first
    }

    // High performance search logic
    private func performSearch() {
        searchTask?.cancel()
        
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            self.filteredEPGChannels = []
            self.filteredNameChannels = []
            self.filteredCategories = []
            self.isSearching = false
            return
        }
        
        self.isSearching = true
        let searchQuery = query
        
        searchTask = Task.detached(priority: .userInitiated) { [weak self, searchQuery] in
            guard let self = self else { return }
            
            // Debounce manually inside the task
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            
            let allChannels = await self.channels
            let allCategories = await self.categories
            let hidden = await self.hiddenIDs
            let epg = await self.epgData
            let now = await self.currentTime
            let manualOrder = await self.manualChannelOrder
            let tokens = query.lowercased().components(separatedBy: " ").filter { !$0.isEmpty }
            
            var orderMap: [Int: Int] = [:]
            for (index, id) in manualOrder.enumerated() { orderMap[id] = index }
            
            var epgMatches: [StreamChannel] = []
            var nameMatches: [StreamChannel] = []
            var catMatches: [StreamCategory] = []
            
            for channel in allChannels {
                if hidden.contains(channel.id) { continue }
                
                var currentProgramTitleLower = ""
                if let eID = channel.epgID, let schedule = epg[eID] {
                    if let program = schedule.first(where: { now >= $0.start && now <= $0.stop }) {
                        currentProgramTitleLower = program.title.lowercased()
                    }
                }
                
                let lowerName = channel.searchNormalizedName
                let lowerGuide = currentProgramTitleLower
                
                let guideMatch = tokens.allSatisfy { lowerGuide.contains($0) }
                let nameMatch = tokens.allSatisfy { lowerName.contains($0) }
                
                if guideMatch { epgMatches.append(channel) }
                else if nameMatch { nameMatches.append(channel) }
            }
            
            for cat in allCategories {
                if !cat.isHidden {
                    let lowerCat = cat.name.lowercased()
                    if tokens.allSatisfy({ lowerCat.contains($0) }) {
                        catMatches.append(cat)
                    }
                }
            }
            
            let sortedEPG = ChannelViewModel.prioritySort(epgMatches, order: manualOrder, precomputedOrderMap: orderMap)
            let sortedName = ChannelViewModel.prioritySort(nameMatches, order: manualOrder, precomputedOrderMap: orderMap)
            
            guard !Task.isCancelled else { return }
            
            let finalCatMatches = catMatches
            await MainActor.run {
                self.filteredEPGChannels = sortedEPG
                self.filteredNameChannels = sortedName
                self.filteredCategories = finalCatMatches
                self.isSearching = false
                
                // Add to recent queries if it actually returned results and is long enough
                if (!sortedEPG.isEmpty || !sortedName.isEmpty || !finalCatMatches.isEmpty) && searchQuery.count > 2 {
                    self.addRecentQuery(searchQuery)
                }
            }
        }
    }

    func addRecentQuery(_ query: String) {
        let clean = query.lowercased().trimmingCharacters(in: .whitespaces)
        if let idx = recentQueries.firstIndex(of: clean) { recentQueries.remove(at: idx) }
        recentQueries.insert(clean, at: 0)
        if recentQueries.count > 10 { recentQueries = Array(recentQueries.prefix(10)) }
        UserDefaults.standard.set(recentQueries, forKey: settingsPrefix + "recentQueries")
    }
    
    func removeRecentQuery(_ query: String) {
        recentQueries.removeAll { $0 == query }
        UserDefaults.standard.set(recentQueries, forKey: settingsPrefix + "recentQueries")
    }
    
    func clearRecentQueries() {
        recentQueries = []
        UserDefaults.standard.removeObject(forKey: settingsPrefix + "recentQueries")
    }

    nonisolated static func qualityScore(for name: String) -> Int {
        var score = 0
        let lower = name.lowercased()
        if lower.contains("4k") || lower.contains("uhd") { score += 100 }
        if lower.contains("fhd") || lower.contains("1080") { score += 80 }
        if lower.contains("720") || lower.contains("hd") { score += 50 }
        if lower.contains("usa") || lower.contains("(us)") || lower.contains("uk") || lower.contains("english") { score += 150 }
        let intTags = ["(es)", "(fr)", "(it)", "(pl)", "(ar)", "spanish", "french", "latino"]
        if intTags.contains(where: { lower.contains($0) }) { score -= 300 }
        return score
    }

    nonisolated static func prioritySort(_ channels: [StreamChannel], order: [Int], precomputedOrderMap: [Int: Int]? = nil) -> [StreamChannel] {
        // Optimally use a lookup
        let orderMap: [Int: Int]
        if let p = precomputedOrderMap {
            orderMap = p
        } else {
            var map: [Int: Int] = [:]
            for (index, id) in order.enumerated() { map[id] = index }
            orderMap = map
        }
        
        return channels.sorted { a, b in
            let idxA = orderMap[a.id]
            let idxB = orderMap[b.id]
            
            // If both are manually ordered, respect that order
            if let iA = idxA, let iB = idxB { return iA < iB }
            // If only one is manually ordered, it takes precedence (pushed to top)
            if idxA != nil { return true }
            if idxB != nil { return false }
            
            // Fallback to quality score
            let scoreA = qualityScore(for: a.name)
            let scoreB = qualityScore(for: b.name)
            if scoreA != scoreB { return scoreA > scoreB }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // Cache for pre-resolved games
    @Published var preResolvedCache: [String: StreamChannel] = [:]

    private struct GameSearchInfo: Sendable {
        let id: String
        let home: String
        let away: String
        let network: String?
    }

    func preResolveGames(_ games: [ESPNEvent]) {
        // Extract data on Main Actor to avoid isolation issues
        let infos: [GameSearchInfo] = games.map {
            let h = $0.homeCompetitor?.team?.shortDisplayName ?? $0.homeCompetitor?.athlete?.shortName ?? ""
            let a = $0.awayCompetitor?.team?.shortDisplayName ?? $0.awayCompetitor?.athlete?.shortName ?? ""
            return GameSearchInfo(id: $0.id, home: h, away: a, network: $0.broadcastName)
        }
        
        let inputChannels = self.channels
        let inputHidden = self.hiddenIDs
        let hiddenCatIDs = Set(self.categories.filter { $0.isHidden }.map { $0.id })
        let currentEPG = self.epgData
        let now = self.currentTime
        
        Task.detached(priority: .utility) { [weak self, inputChannels, inputHidden, hiddenCatIDs, currentEPG, now, infos] in
            guard let self = self else { return }
            
            for info in infos {
                if await self.preResolvedCache[info.id] != nil { continue }
                
                if let best = ChannelViewModel.resolveBestMatch(home: info.home, away: info.away, network: info.network, channels: inputChannels, hiddenIDs: inputHidden, hiddenCatIDs: hiddenCatIDs, epg: currentEPG, now: now) {
                    await MainActor.run {
                        self.preResolvedCache[info.id] = best
                        // Smarters Logic: Warm up the connection immediately
                        self.prewarmChannel(best)
                    }
                }
            }
        }
    }
    
    nonisolated static func resolveBestMatch(home: String, away: String, network: String?, channels: [StreamChannel], hiddenIDs: Set<Int>, hiddenCatIDs: Set<Int>, epg: [String: [EPGProgram]], now: Date) -> StreamChannel? {
        let homeTokens = SmartSearchLogic.tokenize(home)
        let awayTokens = SmartSearchLogic.tokenize(away)
        let targetNetwork = (network ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        func matchCount(_ text: String, tokens: [String]) -> Int {
            let lower = text.lowercased()
            return tokens.filter { lower.contains($0) }.count
        }
        
        var bestChannel: StreamChannel? = nil
        var bestScore = 0
        
        for channel in channels {
            if hiddenIDs.contains(channel.id) || hiddenCatIDs.contains(channel.categoryID) { continue }
            if SmartSearchLogic.isBanner(channel.name) { continue }
            
            var score = 0
            
            // 1. Network Match
            if !targetNetwork.isEmpty && channel.name.localizedCaseInsensitiveContains(targetNetwork) {
                score += 1000
            }
            
            // 2. Content Match
            var epgTitle = ""
            var epgDesc = ""
            
            if let eID = channel.epgID, let schedule = epg[eID],
               let program = schedule.first(where: { now >= $0.start && now <= $0.stop }) {
                epgTitle = program.title
                epgDesc = program.description ?? ""
            }
            
            let nameH = matchCount(channel.name, tokens: homeTokens)
            let nameA = matchCount(channel.name, tokens: awayTokens)
            let titleH = matchCount(epgTitle, tokens: homeTokens)
            let titleA = matchCount(epgTitle, tokens: awayTokens)
            let descH = matchCount(epgDesc, tokens: homeTokens)
            let descA = matchCount(epgDesc, tokens: awayTokens)
            
            if titleH > 0 { score += 500 }
            if titleA > 0 { score += 500 }
            if descH > 0 { score += 300 }
            if descA > 0 { score += 300 }
            if nameH > 0 { score += 200 }
            if nameA > 0 { score += 200 }
            
            let totalH = nameH + titleH + descH
            let totalA = nameA + titleA + descA
            if totalH > 0 && totalA > 0 { score += 300 }
            
            score += ChannelViewModel.qualityScore(for: channel.name)
            
            if score > bestScore {
                bestScore = score
                bestChannel = channel
            }
        }
        
        // Only return if High Confidence (Perfect Match)
        return bestScore >= 1300 ? bestChannel : nil
    }

    func runSmartSearch(gameID: String? = nil, home: String, away: String, sport: SportType, network: String? = nil) {
        // 1. Check Pre-Resolved Cache (Instant Play)
        if let gid = gameID, let cached = preResolvedCache[gid] {
            self.isSearchingGame = false
            withAnimation(.easeInOut(duration: 0.4)) { self.channelToAutoPlay = cached }
            self.prewarmChannel(cached)
            return
        }
    
        let inputChannels = self.channels
        let inputHidden = self.hiddenIDs
        let hiddenCatIDs = Set(self.categories.filter { $0.isHidden }.map { $0.id })
        let currentEPG = self.epgData
        let now = self.currentTime
        let manualOrder = self.manualChannelOrder
        
        self.isSearchingGame = true; self.suggestedChannels = []; self.channelToAutoPlay = nil
        
        Task.detached(priority: .userInitiated) { [weak self, inputChannels, inputHidden, hiddenCatIDs, currentEPG, now, manualOrder] in
            guard let self = self else { return }
            let homeTokens = SmartSearchLogic.tokenize(home)
            let awayTokens = SmartSearchLogic.tokenize(away)
            let targetNetwork = (network ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            var orderMap: [Int: Int] = [:]
            for (index, id) in manualOrder.enumerated() { orderMap[id] = index }
            
            func matchCount(_ text: String, tokens: [String]) -> Int {
                let lower = text.lowercased()
                return tokens.filter { lower.contains($0) }.count
            }
            
            struct ChannelScore {
                let channel: StreamChannel
                let score: Int
                let isNetworkMatch: Bool
                let isContentMatch: Bool
            }
            
            var scoredChannels: [ChannelScore] = []
            
            for channel in inputChannels {
                if inputHidden.contains(channel.id) || hiddenCatIDs.contains(channel.categoryID) { continue }
                if SmartSearchLogic.isBanner(channel.name) { continue }
                
                var score = 0
                var isNetMatch = false // This variable is no longer needed and can be removed
                var isContMatch = false
                
                // 1. Network Match
                if !targetNetwork.isEmpty && channel.name.localizedCaseInsensitiveContains(targetNetwork) {
                    score += 1000
                    isNetMatch = true // This assignment is now unused
                }
                
                // 2. Content Match (EPG & Name)
                var epgTitle = ""
                var epgDesc = ""
                
                if let eID = channel.epgID, let schedule = currentEPG[eID],
                   let program = schedule.first(where: { now >= $0.start && now <= $0.stop }) {
                    epgTitle = program.title
                    epgDesc = program.description ?? ""
                }
                
                let nameH = matchCount(channel.name, tokens: homeTokens)
                let nameA = matchCount(channel.name, tokens: awayTokens)
                
                let titleH = matchCount(epgTitle, tokens: homeTokens)
                let titleA = matchCount(epgTitle, tokens: awayTokens)
                
                let descH = matchCount(epgDesc, tokens: homeTokens)
                let descA = matchCount(epgDesc, tokens: awayTokens)
                
                // Scoring Weights
                // EPG Title is most reliable for specific game
                if titleH > 0 { score += 500; isContMatch = true }
                if titleA > 0 { score += 500; isContMatch = true }
                
                // EPG Description is next best
                if descH > 0 { score += 300; isContMatch = true }
                if descA > 0 { score += 300; isContMatch = true }
                
                // Channel Name is good but can be generic (e.g. "Team Channel")
                if nameH > 0 { score += 200; isContMatch = true }
                if nameA > 0 { score += 200; isContMatch = true }
                
                // Bonus for matching both teams in any combination
                let totalH = nameH + titleH + descH
                let totalA = nameA + titleA + descA
                if totalH > 0 && totalA > 0 { score += 300 }
                
                // Quality & Language Adjustments
                score += ChannelViewModel.qualityScore(for: channel.name)
                
                if score > 0 || isNetMatch {
                    scoredChannels.append(ChannelScore(channel: channel, score: score, isNetworkMatch: isNetMatch, isContentMatch: isContMatch))
                }
            }
            
            // Sort by score descending
            scoredChannels.sort { $0.score > $1.score }
            
            // --- Decision Logic ---
            
            // Check for Perfect Match (Network Match AND Content Match AND High Confidence)
            // A score > 1500 typically implies Network (1000) + Content (500+)
            if let best = scoredChannels.first, best.score >= 1300 {
                let winner = best.channel
                await MainActor.run {
                    self.isSearchingGame = false
                    self.suggestedChannels = [winner] 
                    withAnimation(.easeInOut(duration: 0.4)) { self.channelToAutoPlay = winner }
                    // Optimization: Pre-warm
                    self.prewarmChannel(winner)
                    // Update cache for future
                    if let gid = gameID { self.preResolvedCache[gid] = winner }
                }
                return
            }
            
            // Fallback: 5 Options
            
            let networkMatches = scoredChannels.filter { $0.isNetworkMatch }
            let contentMatches = scoredChannels.filter { $0.isContentMatch && !$0.isNetworkMatch } // Exclude duplicates primarily
            
            var finalSelection: [StreamChannel] = []
            var usedIDs = Set<Int>()
            
            // Take top 3 Network matches
            for item in networkMatches.prefix(3) {
                finalSelection.append(item.channel)
                usedIDs.insert(item.channel.id)
            }
            
            // Take top 2 Content matches
            var addedContent = 0
            for item in contentMatches {
                if addedContent >= 2 { break }
                if !usedIDs.contains(item.channel.id) {
                    finalSelection.append(item.channel)
                    usedIDs.insert(item.channel.id)
                    addedContent += 1
                }
            }
            
            // If we still don't have 5, fill with remaining best matches (any type)
            if finalSelection.count < 5 {
                for item in scoredChannels {
                    if finalSelection.count >= 5 { break }
                    if !usedIDs.contains(item.channel.id) {
                        finalSelection.append(item.channel)
                        usedIDs.insert(item.channel.id)
                    }
                }
            }
            
            // Final Sort: Apply Manual Order or Quality Sort on the selected subset
            let finalSorted = ChannelViewModel.prioritySort(finalSelection, order: manualOrder, precomputedOrderMap: orderMap)
            
            await MainActor.run {
                self.isSearchingGame = false
                if finalSorted.isEmpty {
                    self.showNoStreamsAlert = true
                } else {
                    self.suggestedChannels = finalSorted
                    self.showSelectionSheet = true
                    // Optimization: Pre-warm top 3
                    for ch in finalSorted.prefix(3) {
                        self.prewarmChannel(ch)
                    }
                }
            }
        }
    }
    
    func moveChannelInSearch(from source: StreamChannel, to destination: StreamChannel, save: Bool = true) {
        // Identify which list we are modifying
        var isNameList = false
        if let _ = filteredNameChannels.firstIndex(of: source) { isNameList = true }
        else if filteredEPGChannels.firstIndex(of: source) == nil { return } // Item not found
        
        // Update UI List immediately
        withAnimation {
            if isNameList {
                guard let fromIdx = filteredNameChannels.firstIndex(of: source),
                      let toIdx = filteredNameChannels.firstIndex(of: destination) else { return }
                // Move logic for Array
                if fromIdx != toIdx {
                    var list = filteredNameChannels
                    let item = list.remove(at: fromIdx)
                    list.insert(item, at: toIdx)
                    filteredNameChannels = list
                }
            } else {
                guard let fromIdx = filteredEPGChannels.firstIndex(of: source),
                      let toIdx = filteredEPGChannels.firstIndex(of: destination) else { return }
                if fromIdx != toIdx {
                    var list = filteredEPGChannels
                    let item = list.remove(at: fromIdx)
                    list.insert(item, at: toIdx)
                    filteredEPGChannels = list
                }
            }
        }
        
        // Update Global Manual Order
        var currentOrder = manualChannelOrder
        
        // Remove source if present
        if let idx = currentOrder.firstIndex(of: source.id) { currentOrder.remove(at: idx) }
        
        // Find destination index in global order
        if let destIdx = currentOrder.firstIndex(of: destination.id) {
            // Insert source at destination's index (taking its spot)
            currentOrder.insert(source.id, at: destIdx)
        } else {
            // Destination wasn't manually ordered.
            currentOrder.append(destination.id)
            currentOrder.insert(source.id, at: currentOrder.count - 1)
        }
        
        manualChannelOrder = currentOrder
        if save {
            UserDefaults.standard.set(manualChannelOrder, forKey: settingsPrefix + "manualChannelOrder")
        }
    }
    
    func commitChannelOrder() {
        UserDefaults.standard.set(manualChannelOrder, forKey: settingsPrefix + "manualChannelOrder")
    }

    func updateMultiViewSlot(index: Int, channel: StreamChannel?) { guard index >= 0 && index < 4 else { return }; multiViewSlots[index] = channel }
    func addToMultiView(_ channel: StreamChannel) { if let firstEmpty = multiViewSlots.firstIndex(where: { $0 == nil }) { multiViewSlots[firstEmpty] = channel } else { multiViewSlots[3] = channel } }
    func triggerMultiViewFromPlayer(with channel: StreamChannel) { if let firstEmpty = multiViewSlots.firstIndex(where: { $0 == nil }) { multiViewSlots[firstEmpty] = channel } else { multiViewSlots[0] = channel }; triggerMultiView = true }
    func promptRename(name: String, onConfirm: @escaping (String) -> Void) { self.renameInput = name; self.onRenameConfirm = onConfirm; self.showRenameAlert = true }
    func confirmRename() { onRenameConfirm?(renameInput); showRenameAlert = false; renameInput = "" }
    func triggerRenameChannel(_ c: StreamChannel) { promptRename(name: c.name) { [weak self] n in self?.renameChannel(id: c.id, newName: n) } }
    func triggerRenameCategory(_ c: StreamCategory) { promptRename(name: c.name) { [weak self] n in self?.renameCategory(id: c.id, newName: n) } }
    
    func categorizeSports() {
        let currentChannels = self.channels; let currentConfigs = self.sportsConfigs; let currentExclusions = self.excludedSportsIDs
        Task.detached(priority: .utility) { [weak self] in
            var localGroups: [String: [StreamChannel]] = [:]
            for channel in currentChannels {
                if currentExclusions.contains(channel.id) { continue }
                let searchName = (channel.originalName ?? channel.name)
                for config in currentConfigs {
                    if config.keywords.contains(where: { searchName.localizedCaseInsensitiveContains($0) }) { localGroups[config.id, default: []].append(channel); break }
                }
            }
            for (key, list) in localGroups {
                localGroups[key] = list.sorted { a, b in
                    let aLive = NameCleaner.isLiveGameOrPPV(a.name); let bLive = NameCleaner.isLiveGameOrPPV(b.name)
                    if aLive != bLive { return aLive }; return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
            let finalGroups = localGroups
            await MainActor.run { [weak self] in self?.sportsChannels = finalGroups }
        }
    }
    
    func loadData(url: String, user: String, pass: String, mac: String? = nil, type: LoginType, silent: Bool = false) async {
        guard !url.isEmpty else { return }
        
        // Update settings prefix based on login to isolate settings per user
        let prefixKey = "\(url)_\(user)_\(mac ?? "")".components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        self.settingsPrefix = prefixKey.isEmpty ? "" : prefixKey + "_"
        self.loadSettings()
        
        // Show loading state if not silent (force refresh) or if empty
        if !silent || channels.isEmpty { 
            await MainActor.run { 
                isLoading = true
                loadingStatus = "Connecting to Server..."
                errorMessage = nil 
            }
        }
        
        var safeURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !safeURL.lowercased().hasPrefix("http") { safeURL = "http://" + safeURL }
        guard let baseURL = URL(string: safeURL) else { 
            await MainActor.run { isLoading = false }
            return 
        }
        
        let prefix = self.settingsPrefix
        
        do {
            if type == .xtream {
                await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self, baseURL, user, pass, prefix] in
                        guard let self = self else { return }
                        await MainActor.run { self.loadingStatus = "Fetching Categories..." }
                        let catUrl = try await ChannelViewModel.buildApiUrl(base: baseURL, user: user, pass: pass, action: "get_live_categories")
                        let (data, _) = try await URLSession.shared.data(from: catUrl)
                        let cats = try JSONDecoder().decode([StreamCategory].self, from: data)
                        let processed = await ChannelViewModel.processCategories(cats, prefix: prefix)
                        await MainActor.run { [weak self] in self?.categories = processed }
                    }
                    group.addTask { [weak self, baseURL, user, pass, safeURL, prefix] in
                        guard let self = self else { return }
                        await MainActor.run { self.loadingStatus = "Fetching Channels..." }
                        let streamUrl = try await ChannelViewModel.buildApiUrl(base: baseURL, user: user, pass: pass, action: "get_live_streams")
                        let (data, _) = try await URLSession.shared.data(from: streamUrl)
                        let raw = try JSONDecoder().decode([StreamChannel].self, from: data)
                        let processed = await ChannelViewModel.processChannels(raw, safeURL: safeURL, user: user, pass: pass, prefix: prefix)
                        await MainActor.run { [weak self] in 
                            self?.channels = processed; 
                            self?.categorizeSports()
                            self?.saveToCache()
                        }
                        // Await image preloading to ensure cache is hot
                        await self.preloadImages()
                        await MainActor.run { self.loadingStatus = "Updating TV Guide..." }
                        await self.updateEPG(baseURL: baseURL, user: user, pass: pass, force: false, silent: silent)
                    }
                }
            } else if type == .mac, let macAddress = mac {
                // Stalker / MAC Portal Logic
                await MainActor.run { self.loadingStatus = "Authenticating Portal..." }
                let (channels, categories, token) = try await ChannelViewModel.fetchStalkerData(portalURL: baseURL, mac: macAddress, prefix: prefix)
                await MainActor.run {
                    self.channels = channels
                    self.categories = categories
                    self.stalkerToken = token
                    self.stalkerPortalURL = baseURL
                    self.categorizeSports()
                    self.saveToCache()
                }
                await self.preloadImages()
            } else {
                await MainActor.run { self.loadingStatus = "Downloading Playlist..." }
                let (data, _) = try await URLSession.shared.data(from: baseURL)
                if let content = String(data: data, encoding: .utf8) {
                    await MainActor.run { self.loadingStatus = "Parsing Channels..." }
                    let (pChannels, pCategories, epgUrl) = await ChannelViewModel.parseM3U(content: content)
                    self.channels = pChannels; self.categories = pCategories; self.categorizeSports()
                    self.saveToCache()
                    await self.preloadImages()
                    if let eURL = epgUrl, let xmlURL = URL(string: eURL) {
                        await MainActor.run { self.loadingStatus = "Updating TV Guide..." }
                        await self.updateEPGFromURL(xmlURL, silent: silent)
                    }
                }
            }
        } catch { 
            await MainActor.run { self.errorMessage = "Error: " + error.localizedDescription }
        }
        await MainActor.run { self.isLoading = false }
    }
    
    func preloadImages() async {
        await MainActor.run { self.loadingStatus = "Smart Caching Images..." }
        
        // Capture data on MainActor to avoid isolation issues
        let allChannels = self.channels
        let favorites = self.favoriteIDs
        let recents = self.recentIDs
        
        // Build Priority Set (Smart Cache Strategy)
        var targetIDs = Set<Int>()
        
        // 1. Favorites & Recents (High Priority)
        targetIDs.formUnion(favorites)
        targetIDs.formUnion(recents)
        
        // 2. Top 100 Channels (Buffer for initial lists)
        targetIDs.formUnion(allChannels.prefix(100).map { $0.id })
        
        print("🚀 [ChannelViewModel] Starting Smart Cache for \(targetIDs.count) priority channels...")
        
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            let limit = 50 
            
            for channel in allChannels {
                // FILTER: Only process priority channels
                if !targetIDs.contains(channel.id) { continue }
                
                if let icon = channel.icon, !icon.isEmpty {
                    // FAST CHECK: Skip if already on disk
                    if ImageCache.shared.hasImage(forKey: icon) { continue }
                    
                    if active >= limit { await group.next(); active -= 1 }
                    
                    group.addTask {
                        await ImageCache.prefetchAndWait(urlString: icon, size: CGSize(width: 50, height: 50))
                    }
                    active += 1
                }
            }
        }
        
        print("✅ [ChannelViewModel] Smart Cache complete.")
    }

    func updateEPG(baseURL: URL, user: String, pass: String, force: Bool = false, silent: Bool = false) async {
        let now = Date()
        let isStale = lastEPGUpdateTime == nil || now.timeIntervalSince(lastEPGUpdateTime!) >= 14400
        
        if !force && !isStale {
            if let cached = EPGService().loadFromDisk(), !cached.epg.isEmpty {
                await MainActor.run { 
                    self.epgData = cached.epg
                    self.epgNameMap = cached.map
                }
                return
            }
        }

        // Primary EPG
        var urls: [URL] = []
        let epgUrl = baseURL.appendingPathComponent("xmltv.php")
        var c = URLComponents(url: epgUrl, resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "username", value: user), URLQueryItem(name: "password", value: pass)]
        if let finalEPG = c?.url { urls.append(finalEPG) }
        
        if let current = AccountManager.shared.currentAccount {
            for ext in current.externalEPGUrls {
                if let u = URL(string: ext) { urls.append(u) }
            }
        }
        
        await updateEPGFromURLs(urls, silent: silent)
    }
    
    func updateEPGFromURLs(_ urls: [URL], silent: Bool = false) async {
        var shouldManageLoading = false
        
        await MainActor.run {
            if !silent && !self.isLoading {
                self.isLoading = true
                shouldManageLoading = true
            }
            
            self.visualProgress = 0
            self.epgProgress = 0
            if !silent {
                withAnimation(.spring()) { self.isUpdatingEPG = true }
            }
            
            self.smoothingTimer?.cancel()
            self.smoothingTimer = Timer.publish(every: 0.04, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    let real = self.epgProgress
                    let current = self.visualProgress
                    if Double.random(in: 0...1) < 0.6 { return }
                    
                    if current < real {
                        let jump = Double.random(in: 0.01...0.08)
                        self.visualProgress += min(real - current, jump)
                    } else if current < 0.92 {
                        let creep = Double.random(in: 0.001...0.005)
                        self.visualProgress += creep
                    }
                    
                    if real < 1.0 && self.visualProgress > 0.95 { self.visualProgress = 0.95 } 
                    
                    if real >= 1.0 {
                        if self.visualProgress < 1.0 { self.visualProgress = 1.0 }
                        self.smoothingTimer?.cancel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            withAnimation(.spring()) { self.isUpdatingEPG = false }
                        }
                    }
                }
        }
        
        let result = await EPGService().fetchAndMergeEPGs(urls: urls) { progress in
            self.epgProgress = progress
        }
        
        await MainActor.run {
            self.lastEPGUpdateTime = Date()
            self.epgProgress = 1.0
            self.epgData = result.epg
            self.epgNameMap = result.map
            
            if shouldManageLoading { self.isLoading = false }
        }
    }
    
    // Legacy support (redirects to list version)
    func updateEPGFromURL(_ url: URL, silent: Bool = false) async {
        await updateEPGFromURLs([url], silent: silent)
    }
    
    // Exposed property for the UI to use the smooth progress
    var displayEPGProgress: Double {
        return visualProgress
    }

    func loadSettings() {
        func load<T: Decodable>(_ key: String, type: T.Type) -> T? {
            guard let data = UserDefaults.standard.data(forKey: settingsPrefix + key) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        self.renamedChannels = load("renamedChannels", type: [Int: String].self) ?? [:]
        self.renamedCategories = load("renamedCategories", type: [Int: String].self) ?? [:]
        self.excludedSportsIDs = Set(load("excludedSportsIDs", type: [Int].self) ?? [])
        self.favoriteIDs = Set(load("favoriteChannelIDs", type: [Int].self) ?? [])
        self.hiddenIDs = Set(load("hiddenChannelIDs", type: [Int].self) ?? [])
        // Deduplicate recentIDs while preserving order
        let loadedRecents = load("recentChannelIDs", type: [Int].self) ?? []
        self.recentIDs = loadedRecents.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        self.manualChannelOrder = load("manualChannelOrder", type: [Int].self) ?? []
        self.recentQueries = UserDefaults.standard.stringArray(forKey: settingsPrefix + "recentQueries") ?? []
        
        if let saved = load("sportsConfigs", type: [SportConfig].self) {
            self.sportsConfigs = saved.filter { $0.id != "Other" }.sorted { $0.order < $1.order }
        } else {
            self.sportsConfigs = [
                SportConfig(id: "NFL", name: "NFL", keywords: ["NFL"], order: 0),
                SportConfig(id: "NBA", name: "NBA", keywords: ["NBA"], order: 1),
                SportConfig(id: "MLB", name: "MLB", keywords: ["MLB"], order: 2),
                SportConfig(id: "NHL", name: "NHL", keywords: ["NHL"], order: 3),
                SportConfig(id: "Soccer", name: "Soccer", keywords: ["Soccer", "Premier League", "La Liga", "MLS", "Bundesliga", "Serie A"], order: 4)
            ]
        }
    }
    
    func saveCategorySettings() {
        struct Wrapper: Codable { let id: Int; var name: String; var isHidden: Bool; var order: Int }
        let wrappers = categories.map { Wrapper(id: $0.id, name: $0.name, isHidden: $0.isHidden, order: $0.order) }
        if let encoded = try? JSONEncoder().encode(wrappers) { UserDefaults.standard.set(encoded, forKey: settingsPrefix + "savedCategories") }
    }

    func renameChannel(id: Int, newName: String) {
        renamedChannels[id] = newName
        if let encoded = try? JSONEncoder().encode(renamedChannels) { UserDefaults.standard.set(encoded, forKey: settingsPrefix + "renamedChannels") }
        if let index = channels.firstIndex(where: { $0.id == id }) { channels[index].name = newName; performSearch(); categorizeSports(); objectWillChange.send() }
    }
    
    func renameCategory(id: Int, newName: String) {
        renamedCategories[id] = newName
        if let encoded = try? JSONEncoder().encode(renamedCategories) { UserDefaults.standard.set(encoded, forKey: settingsPrefix + "renamedCategories") }
        if let index = categories.firstIndex(where: { $0.id == id }) { categories[index].name = newName; objectWillChange.send() }
    }
    
    func toggleFavorite(_ id: Int) { if favoriteIDs.contains(id) { favoriteIDs.remove(id) } else { favoriteIDs.insert(id) }; if let d = try? JSONEncoder().encode(Array(favoriteIDs)) { UserDefaults.standard.set(d, forKey: settingsPrefix + "favoriteChannelIDs") } }
    func hideChannel(_ id: Int) { hiddenIDs.insert(id); if let d = try? JSONEncoder().encode(Array(hiddenIDs)) { UserDefaults.standard.set(d, forKey: settingsPrefix + "hiddenChannelIDs") } }
    func unhideChannel(_ id: Int) { hiddenIDs.remove(id); if let d = try? JSONEncoder().encode(Array(hiddenIDs)) { UserDefaults.standard.set(d, forKey: settingsPrefix + "hiddenChannelIDs") } }
    func hideCategory(_ id: Int) { if let idx = categories.firstIndex(where: { $0.id == id }) { categories[idx].isHidden = true; saveCategorySettings() } }
    func addToRecent(_ id: Int) { recentIDs.removeAll { $0 == id }; recentIDs.insert(id, at: 0); if recentIDs.count > 20 { recentIDs = Array(recentIDs.prefix(20)) }; if let d = try? JSONEncoder().encode(recentIDs) { UserDefaults.standard.set(d, forKey: settingsPrefix + "recentChannelIDs") } }
    func removeFromRecent(_ id: Int) { if let idx = recentIDs.firstIndex(of: id) { recentIDs.remove(at: idx); if let d = try? JSONEncoder().encode(recentIDs) { UserDefaults.standard.set(d, forKey: settingsPrefix + "recentChannelIDs") } } }
    
    nonisolated static func parseM3U(content: String) async -> ([StreamChannel], [StreamCategory], String?) {
        var channels: [StreamChannel] = []; var categories: [StreamCategory] = []; var catNames = Set<String>()
        var epgUrl: String? = nil
        let lines = content.components(separatedBy: .newlines); var current: StreamChannel? = nil
        for i in 0..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTM3U") {
                if let urlRange = line.range(of: "url-tvg=\"(.*?)\"", options: .regularExpression) {
                    epgUrl = line[urlRange].replacingOccurrences(of: "url-tvg=\"", with: "").replacingOccurrences(of: "\"", with: "")
                }
            } else if line.hasPrefix("#EXTINF") {
                var name = "Unknown Channel"; var logo: String? = nil; var group = "Uncategorized"; var eID: String? = nil
                if let comma = line.lastIndex(of: ",") { name = String(line[comma...].dropFirst()).trimmingCharacters(in: .whitespaces) }
                if let gr = line.range(of: "group-title=\"(.*?)\"", options: .regularExpression) { group = String(line[gr]).replacingOccurrences(of: "group-title=\"", with: "").replacingOccurrences(of: "\"", with: "") }
                if let lo = line.range(of: "tvg-logo=\"(.*?)\"", options: .regularExpression) { logo = String(line[lo]).replacingOccurrences(of: "tvg-logo=\"", with: "").replacingOccurrences(of: "\"", with: "") }
                if let tid = line.range(of: "tvg-id=\"(.*?)\"", options: .regularExpression) { eID = String(line[tid]).replacingOccurrences(of: "tvg-id=\"", with: "").replacingOccurrences(of: "\"", with: "") }
                let catID = abs(group.hashValue)
                if !catNames.contains(group) { categories.append(StreamCategory(id: catID, name: group)); catNames.insert(group) }
                current = StreamChannel(id: i, name: name, streamURL: "", icon: logo, categoryID: catID, originalName: name, epgID: eID)
            } else if !line.hasPrefix("#") && !line.isEmpty && current != nil {
                var fin = current!; fin.streamURL = line; fin.name = NameCleaner.clean(fin.name); channels.append(fin); current = nil
            }
        }
        return (channels, categories.sorted { $0.name < $1.name }, epgUrl)
    }
    
    nonisolated static private func buildApiUrl(base: URL, user: String, pass: String, action: String) async throws -> URL {
        var c = URLComponents(url: base.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "username", value: user), URLQueryItem(name: "password", value: pass), URLQueryItem(name: "action", value: action)]
        guard let url = c?.url else { throw URLError(.badURL) }
        return url
    }
    
    nonisolated static func processCategories(_ loadedCats: [StreamCategory], prefix: String) async -> [StreamCategory] {
        var mutable = loadedCats; let data = UserDefaults.standard.data(forKey: prefix + "renamedCategories") ?? Data()
        let renames = (try? JSONDecoder().decode([Int: String].self, from: data)) ?? [:]
        
        // Also load hidden/saved state using the prefix
        struct Wrapper: Codable { let id: Int; var name: String; var isHidden: Bool; var order: Int }
        if let savedData = UserDefaults.standard.data(forKey: prefix + "savedCategoriesנדה"),
           let saved = try? JSONDecoder().decode([Wrapper].self, from: savedData) {
            
            // Map saved settings to loaded categories
            let savedMap = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
            
            for i in 0..<mutable.count {
                let id = mutable[i].id
                if let s = savedMap[id] {
                    mutable[i].isHidden = s.isHidden
                    mutable[i].order = s.order
                    // Use saved name if available, or rename override
                    if let custom = renames[id] { mutable[i].name = custom }
                    else { mutable[i].name = s.name } // Use saved name (might be same as original)
                } else {
                     // Not saved, apply rename if exists
                    if let custom = renames[id] { mutable[i].name = custom }
                    mutable[i].order = 9999 + i // Default order for new categories
                }
            }
            // Sort by order
             return mutable.sorted { $0.order < $1.order }
        }
        
        for i in 0..<mutable.count { let id = mutable[i].id; if let custom = renames[id] { mutable[i].name = custom }; mutable[i].order = i }
        return mutable.sorted { $0.order < $1.order }
    }
    
    nonisolated static func processChannels(_ raw: [StreamChannel], safeURL: String, user: String, pass: String, prefix: String) async -> [StreamChannel] {
        let data = UserDefaults.standard.data(forKey: prefix + "renamedChannels") ?? Data()
        let renames = (try? JSONDecoder().decode([Int: String].self, from: data)) ?? [:]
        return raw.map { var c = $0; c.streamURL = "\(safeURL)/live/\(user)/\(pass)/\($0.id).m3u8"; c.originalName = c.name; if let custom = renames[c.id] { c.name = custom } else { c.name = NameCleaner.clean(c.name) }; return c }
    }
    
    // Stalker State
    @Published var stalkerToken: String? = nil
    @Published var stalkerPortalURL: URL? = nil

    // Stalker / MAC Implementation
    nonisolated static func fetchStalkerData(portalURL: URL, mac: String, prefix: String) async throws -> ([StreamChannel], [StreamCategory], String) {
        let components = URLComponents(url: portalURL.appendingPathComponent("portal.php"), resolvingAgainstBaseURL: false)
        
        func createRequest(action: String, token: String? = nil) throws -> URLRequest {
            var c = components
            var items = [
                URLQueryItem(name: "type", value: "stb"),
                URLQueryItem(name: "action", value: action),
                URLQueryItem(name: "mac", value: mac)
            ]
            if let t = token {
                items.append(URLQueryItem(name: "token", value: t))
                if action != "handshake" { items[0].value = "itv" }
            }
            c?.queryItems = items
            guard let url = c?.url else { throw URLError(.badURL) }
            var req = URLRequest(url: url)
            req.setValue("Bearer " + (token ?? ""), forHTTPHeaderField: "Authorization")
            req.setValue("mac="+mac, forHTTPHeaderField: "Cookie")
            return req
        }
        
        // Handshake
        let handshakeReq = try createRequest(action: "handshake")
        let (hData, _) = try await URLSession.shared.data(for: handshakeReq)
        
        struct StalkerResponse: Codable {
            struct JS: Codable { let token: String? }
            let js: JS?
        }
        
        let hRes = try JSONDecoder().decode(StalkerResponse.self, from: hData)
        guard let token = hRes.js?.token else { throw URLError(.userAuthenticationRequired) }
        
        // Fetch Categories
        let catReq = try createRequest(action: "get_genres", token: token)
        let (cData, _) = try await URLSession.shared.data(for: catReq)
        
        struct StalkerCategory: Codable {
            let id: String
            let title: String
        }
        struct GenreResponse: Codable {
            let js: [StalkerCategory]?
        }
        
        let cRes = try JSONDecoder().decode(GenreResponse.self, from: cData)
        
        var categories: [StreamCategory] = []
        let loadedCats = (cRes.js ?? []).compactMap { cat -> StreamCategory? in
            guard let id = Int(cat.id) else { return nil }
            return StreamCategory(id: id, name: cat.title)
        }
        categories = await processCategories(loadedCats, prefix: prefix)
        
        // Fetch Channels
        let chReq = try createRequest(action: "get_all_channels", token: token)
        let (chData, _) = try await URLSession.shared.data(for: chReq)
        
        struct StalkerChannel: Codable {
            let id: String?
            let name: String
            let cmd: String?
            let tv_genre_id: String?
            let logo: String?
        }
        struct ChannelResponse: Codable {
            let js: [StalkerChannel]?
        }
        
        let chRes = try JSONDecoder().decode(ChannelResponse.self, from: chData)
        
        let data = UserDefaults.standard.data(forKey: prefix + "renamedChannels") ?? Data()
        let renames = (try? JSONDecoder().decode([Int: String].self, from: data)) ?? [:]
        
        let channels = (chRes.js ?? []).compactMap { c -> StreamChannel? in
            guard let sid = c.id, let intID = Int(sid) else { return nil }
            guard let catID = Int(c.tv_genre_id ?? "0") else { return nil }
            
            // Keep the cmd as is for Stalker, we resolve it later if needed
            let url = c.cmd ?? ""
            
            var name = c.name
            if let custom = renames[intID] { name = custom } 
            else { name = NameCleaner.clean(name) }
            
            return StreamChannel(id: intID, name: name, streamURL: url, icon: c.logo, categoryID: catID, originalName: c.name, epgID: nil)
        }
        
        return (channels, categories, token)
    }
    
    func resolveStalkerStream(_ channel: StreamChannel) async -> String {
        guard let token = stalkerToken, let portalURL = stalkerPortalURL else { return channel.streamURL }
        // If it looks like a direct link already, just use it (simple heuristic)
        if channel.streamURL.hasPrefix("http") && !channel.streamURL.contains("ffmpeg") { return channel.streamURL }
        
        // Call create_link
        // action=create_link&cmd=...
        var components = URLComponents(url: portalURL.appendingPathComponent("portal.php"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "type", value: "itv"),
            URLQueryItem(name: "action", value: "create_link"),
            URLQueryItem(name: "cmd", value: channel.streamURL),
            URLQueryItem(name: "token", value: token)
        ]
        
        guard let url = components?.url else { return channel.streamURL }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct LinkResponse: Codable {
                struct JS: Codable { let cmd: String? }
                let js: JS?
            }
            let res = try JSONDecoder().decode(LinkResponse.self, from: data)
            if let finalURL = res.js?.cmd {
                return finalURL
            }
        } catch {
            print("Stalker resolve error: \(error)")
        }
        
        // Fallback: try basic cleaning
        var clean = channel.streamURL
        clean = clean.replacingOccurrences(of: "ffmpeg ", with: "")
        clean = clean.replacingOccurrences(of: "auto ", with: "")
        return clean
    }
    
    func buildTimeshiftURL(channel: StreamChannel, targetDate: Date, program: EPGProgram) async -> URL? {
        // Handle Stalker
        if let _ = stalkerToken, let _ = stalkerPortalURL {
            let resolvedURL = await resolveStalkerStream(channel)
            guard let url = URL(string: resolvedURL) else { return nil }
            
            // Stalker Timeshift offset is from program start in seconds
            let offset = Int(targetDate.timeIntervalSince(program.start))
            
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var queryItems = components?.queryItems ?? []
            queryItems.removeAll { $0.name == "timeshift" }
            queryItems.append(URLQueryItem(name: "timeshift", value: "\(offset)"))
            components?.queryItems = queryItems
            
            return components?.url
        }
        
        // Handle Xtream Codes
        guard let original = URL(string: channel.streamURL) else { return nil }
        let urlString = original.absoluteString
        
        if urlString.contains("/live/") {
            // duration is usually total program duration in minutes
            let durationMinutes = Int(program.stop.timeIntervalSince(program.start) / 60)
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd:HH-mm"
            formatter.timeZone = TimeZone(secondsFromGMT: 0) // IMPORTANT: Servers expect UTC
            let startString = formatter.string(from: targetDate)
            
            // Format: http://domain:port/timeshift/user/pass/duration/timestamp/id.ts
            let newString = urlString.replacingOccurrences(of: "/live/", with: "/timeshift/")
            
            // Extract numeric ID and remove extension (like .m3u8)
            if let lastSlash = newString.lastIndex(of: "/") {
                let prefix = newString[..<lastSlash]
                let idPart = newString[newString.index(after: lastSlash)...]
                let streamID = idPart.components(separatedBy: ".").first ?? String(idPart)
                
                let finalURLString = "\(prefix)/\(durationMinutes)/\(startString)/\(streamID).ts"
                return URL(string: finalURLString)
            }
        }
        
        return nil
    }
}
