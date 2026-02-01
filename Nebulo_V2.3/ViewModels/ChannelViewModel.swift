import SwiftUI
import Combine
import UIKit

@MainActor
class ChannelViewModel: ObservableObject {
    static let shared = ChannelViewModel()
    
    @Published var categories: [StreamCategory] = []
    @Published var channels: [StreamChannel] = []
    @Published var isLoading = true
    @Published var errorMessage: String? = nil
    
    
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
    
    
    @Published var manualChannelOrder: [Int] = []
    
    
    @Published var epgData: [String: [EPGProgram]] = [:]
    private var epgNameMap: [String: String] = [:] 
    @Published var epgProgress: Double = 0
    @Published var isUpdatingEPG: Bool = false
    @Published var loadingStatus: String = "Loading..." 
    private var lastFetchedEPGUrls: [URL] = []
    
    
    @Published var preferredLanguage: LanguagePreference = .english {
        didSet { 
            UserDefaults.standard.set(preferredLanguage.rawValue, forKey: settingsPrefix + "preferredLanguage")
            self.preResolvedCache.removeAll()
        }
    }
    @Published var hapticsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: settingsPrefix + "hapticsEnabled") }
    }
    @Published var preferredQuality: StreamQuality = .best {
        didSet { 
            UserDefaults.standard.set(preferredQuality.rawValue, forKey: settingsPrefix + "preferredQuality")
            self.preResolvedCache.removeAll()
        }
    }
    
    
    private var lastFullLoadTime: Date? {
        get {
            guard let interval = UserDefaults.standard.object(forKey: settingsPrefix + "lastFullLoadTime") as? TimeInterval else { return nil }
            return Date(timeIntervalSince1970: interval)
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: settingsPrefix + "lastFullLoadTime")
            } else {
                UserDefaults.standard.removeObject(forKey: settingsPrefix + "lastFullLoadTime")
            }
        }
    }
    
    
    var activeAccountsMap: [UUID: Account] = [:]
    
    private var currentLoadTask: Task<Void, Never>? 
    private var currentLoadID: UUID?
    
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
    }
    
    func handleAppActivation() async {
        if let task = currentLoadTask {
            // If task is finished, nil it out and continue, otherwise return
            if task.isCancelled { 
                currentLoadTask = nil 
            } else {
                return
            }
        }
        
        
        if self.channels.isEmpty {
            if let (cachedChans, cachedCats) = self.loadFromCache() {
                self.channels = cachedChans
                self.categories = cachedCats
                self.categorizeSports()
            }
        }
        
        let now = Date()
        let hasData = !self.channels.isEmpty
        let isEPGStale = lastEPGUpdateTime == nil || now.timeIntervalSince(lastEPGUpdateTime!) >= 86400
        
        
        if !hasData || isEPGStale {
            print("🔄 [ChannelViewModel] Data missing or EPG stale. Triggering full update.")
            await loadActiveAccounts(silent: false, performEpgCheck: true)
        } else {
            print("✅ [ChannelViewModel] Data is fresh. Refreshing silently in background.")
            await loadActiveAccounts(silent: true, performEpgCheck: false)
        }
    }

    func prepareForLogin() {
        self.reset()
        self.isLoading = true
        self.loadingStatus = "Connecting..."
    }

    func loadActiveAccounts(silent: Bool = false, force: Bool = false, performEpgCheck: Bool = false) async {
        if currentLoadTask != nil && silent { return }
        
        let loadID = UUID()
        self.currentLoadID = loadID
        
        await MainActor.run {
            if !silent && (self.channels.isEmpty || force) {
                self.isLoading = true
                self.loadingStatus = "Loading Channels..."
            }
            
            if force {
                self.channels = []
                self.categories = []
                self.epgData = [:]
                self.epgNameMap = [:]
            } else if self.channels.isEmpty {
                if let (cachedChans, cachedCats) = self.loadFromCache() {
                    self.channels = cachedChans
                    self.categories = cachedCats
                    self.categorizeSports()
                }
            }
        }
        
        currentLoadTask?.cancel()
        currentLoadTask = Task {
            
            defer {
                Task { @MainActor in
                    if self.currentLoadID == loadID {
                        self.isLoading = false
                        self.isUpdatingEPG = false
                        self.currentLoadTask = nil
                        self.stopSmoothingTimer()
                    }
                }
            }

            var shouldUpdateEPG = performEpgCheck
            if performEpgCheck && !force {
                let now = Date()
                if let last = lastEPGUpdateTime, now.timeIntervalSince(last) < 86400 {
                    shouldUpdateEPG = false
                }
            }

            await MainActor.run {
                if shouldUpdateEPG {
                    self.isUpdatingEPG = true
                    self.loadingStatus = "Checking for updates..."
                    self.startSmoothingTimer()
                }
            }

            let accounts = AccountManager.shared.accounts.filter { $0.isActive }
            if accounts.isEmpty { return }
            
            await MainActor.run {
                self.activeAccountsMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            }
            
            var allChannels: [StreamChannel] = []
            var allCategories: [StreamCategory] = []
            var epgUrls: [URL] = []
            
            await withTaskGroup(of: ([StreamChannel], [StreamCategory], [URL]).self) { group in
                for account in accounts {
                    group.addTask {
                        if Task.isCancelled { return ([], [], []) }
                        return await self.fetchAccountData(account)
                    }
                }
                for await (chans, cats, urls) in group {
                    allChannels.append(contentsOf: chans)
                    allCategories.append(contentsOf: cats)
                    epgUrls.append(contentsOf: urls)
                }
            }
            
            if Task.isCancelled { return }
            
            await MainActor.run {
                self.channels = allChannels
                self.categories = allCategories.sorted { $0.order < $1.order }
                self.categorizeSports()
                self.saveToCache()
            }
            
            if shouldUpdateEPG {
                await self.updateEPGFromURLs(epgUrls, force: force, silent: silent)
            } else if self.epgData.isEmpty {
                if let cached = EPGService().loadFromDisk(), !cached.epg.isEmpty {
                    await MainActor.run {
                        self.epgData = cached.epg
                        self.epgNameMap = cached.map
                    }
                }
            }
            
            await MainActor.run {
                self.lastFullLoadTime = Date()
            }
        }
        await currentLoadTask?.value
    }
    
    
    func fetchAccountData(_ account: Account) async -> ([StreamChannel], [StreamCategory], [URL]) {
        let offset = account.stableID * 100_000_000
        let prefix = "acc_\(account.stableID)_" 
        
        var fetchedChannels: [StreamChannel] = []
        var fetchedCategories: [StreamCategory] = []
        var fetchedEPGs: [URL] = []
        
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        
        do {
            if account.type == .xtream {
                guard let baseURL = URL(string: account.url) else { return ([], [], []) }
                let user = account.username ?? ""
                let pass = account.password ?? ""
                
                
                let catUrl = try await ChannelViewModel.buildApiUrl(base: baseURL, user: user, pass: pass, action: "get_live_categories")
                let (cData, _) = try await session.data(from: catUrl)
                let cats = try JSONDecoder().decode([StreamCategory].self, from: cData)
                let processedCats = await ChannelViewModel.processCategories(cats, prefix: prefix, idOffset: offset)
                fetchedCategories = processedCats
                
                
                let streamUrl = try await ChannelViewModel.buildApiUrl(base: baseURL, user: user, pass: pass, action: "get_live_streams")
                let (sData, _) = try await session.data(from: streamUrl)
                let raw = try JSONDecoder().decode([StreamChannel].self, from: sData)
                let processedChans = await ChannelViewModel.processChannels(raw, safeURL: account.url, user: user, pass: pass, prefix: prefix, idOffset: offset, accountID: account.id)
                fetchedChannels = processedChans
                
                
                let epgUrl = baseURL.appendingPathComponent("xmltv.php")
                var c = URLComponents(url: epgUrl, resolvingAgainstBaseURL: false)
                c?.queryItems = [URLQueryItem(name: "username", value: user), URLQueryItem(name: "password", value: pass)]
                if let finalEPG = c?.url { fetchedEPGs.append(finalEPG) }
                
            } else {
                
                guard let baseURL = URL(string: account.url) else { return ([], [], []) }
                let (data, _) = try await session.data(from: baseURL)
                if let content = String(data: data, encoding: .utf8) {
                    let (pChannels, pCategories, epgUrl) = await ChannelViewModel.parseM3U(content: content, idOffset: offset, accountID: account.id)
                    fetchedChannels = pChannels
                    fetchedCategories = await ChannelViewModel.processCategories(pCategories, prefix: prefix, idOffset: offset)
                    if let eURL = epgUrl, let u = URL(string: eURL) { fetchedEPGs.append(u) }
                }
            }
            
        } catch {
            print("Error fetching account \(account.name): \(error)")
        }
        
        return (fetchedChannels, fetchedCategories, fetchedEPGs)
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
            
            let direct = epgNameMap[channel.name.lowercased()]
            if direct != nil { return direct }
            
            
            let cleaned = NameCleaner.clean(channel.name).lowercased()
            return epgNameMap[cleaned]
        }()
        
        guard let id = eID, let schedule = epgData[id] else { return nil }
        return schedule.first { currentTime >= $0.start && currentTime <= $0.stop }
    }

    func getNextProgram(for channel: StreamChannel) -> EPGProgram? {
        let eID: String? = {
            if let id = channel.epgID, epgData[id] != nil { return id }
            
            let direct = epgNameMap[channel.name.lowercased()]
            if direct != nil { return direct }
            
            let cleaned = NameCleaner.clean(channel.name).lowercased()
            return epgNameMap[cleaned]
        }()
        
        guard let id = eID, let schedule = epgData[id] else { return nil }
        guard let current = schedule.first(where: { currentTime >= $0.start && currentTime <= $0.stop }) else {
            return schedule.filter { $0.start > currentTime }.sorted { $0.start < $1.start }.first
        }
        return schedule.filter { $0.start >= current.stop }.sorted { $0.start < $1.start }.first
    }

    
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

    nonisolated static func prioritySort(_ channels: [StreamChannel], order: [Int], precomputedOrderMap: [Int: Int]? = nil, scores: [Int: Int]? = nil) -> [StreamChannel] {
        
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
            
            
            if let iA = idxA, let iB = idxB { return iA < iB }
            
            if idxA != nil { return true }
            if idxB != nil { return false }
            
            if let scores = scores {
                let sA = scores[a.id] ?? 0
                let sB = scores[b.id] ?? 0
                if sA != sB { return sA > sB }
            }
            
            
            if a.qualityScore != b.qualityScore { return a.qualityScore > b.qualityScore }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    
    @Published var preResolvedCache: [String: StreamChannel] = [:]

    private struct GameSearchInfo: Sendable {
        let id: String
        let home: String
        let away: String
        let network: String?
    }

    func preResolveGames(_ games: [ESPNEvent]) {
        
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
        let pLang = self.preferredLanguage
        let pQual = self.preferredQuality
        
        Task.detached(priority: .utility) { [weak self, inputChannels, inputHidden, hiddenCatIDs, currentEPG, now, infos, pLang, pQual] in
            guard let self = self else { return }
            
            for info in infos {
                if await self.preResolvedCache[info.id] != nil { continue }
                
                if let best = ChannelViewModel.resolveBestMatch(home: info.home, away: info.away, network: info.network, channels: inputChannels, hiddenIDs: inputHidden, hiddenCatIDs: hiddenCatIDs, epg: currentEPG, now: now, preferredLanguage: pLang, preferredQuality: pQual) {
                    await MainActor.run {
                        self.preResolvedCache[info.id] = best
                        
                        self.prewarmChannel(best)
                    }
                }
            }
        }
    }
    
    nonisolated static func resolveBestMatch(home: String, away: String, network: String?, channels: [StreamChannel], hiddenIDs: Set<Int>, hiddenCatIDs: Set<Int>, epg: [String: [EPGProgram]], now: Date, preferredLanguage: LanguagePreference, preferredQuality: StreamQuality) -> StreamChannel? {
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
            
            
            if !targetNetwork.isEmpty && channel.name.localizedCaseInsensitiveContains(targetNetwork) {
                score += 1000
            }
            
            
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
            
            
            
            let fullInfo = "\(channel.name) \(epgTitle) \(epgDesc)"
            
            if score > 0 {
                if SmartSearchLogic.checkLanguageMatch(fullInfo, preference: preferredLanguage) {
                    score += 2000
                } else if preferredLanguage != .any {
                    if let detected = SmartSearchLogic.detectLanguage(fullInfo) {
                        let isEnglishPref = (preferredLanguage == .english)
                        let isEnglishDet = (detected == .english)
                        
                        if detected != preferredLanguage && !(isEnglishPref && isEnglishDet) {
                            score -= 2000
                        }
                    }
                }
                
                
                if preferredLanguage != .any, let code = preferredLanguage.searchTokens.first {
                    let lower = channel.name.lowercased()
                    if lower.hasPrefix(code + ":") || lower.contains(" " + code + ":") || lower.hasPrefix("[" + code + "]") {
                        score += 5000
                    }
                }
            }
            
            let q = SmartSearchLogic.detectQuality(fullInfo, width: channel.width, height: channel.height)
            if preferredQuality == .best {
                
                if q == .fourK { score += 40 }
                else if q == .fhd { score += 30 }
                else if q == .hd { score += 20 }
            } else {
                
                if q == preferredQuality { score += 50 }
                
            }
            
            score += channel.qualityScore
            
            if score > bestScore {
                bestScore = score
                bestChannel = channel
            }
        }
        
        
        return bestScore >= 1300 ? bestChannel : nil
    }

    func runSmartSearch(gameID: String? = nil, home: String, away: String, sport: SportType, network: String? = nil) {
        
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
        let pLang = self.preferredLanguage
        let pQual = self.preferredQuality
        
        self.isSearchingGame = true; self.suggestedChannels = []; self.channelToAutoPlay = nil
        
        Task.detached(priority: .userInitiated) { [weak self, inputChannels, inputHidden, hiddenCatIDs, currentEPG, now, manualOrder, pLang, pQual] in
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
                var isNetMatch = false 
                var isContMatch = false
                
                
                if !targetNetwork.isEmpty && channel.name.localizedCaseInsensitiveContains(targetNetwork) {
                    score += 1000
                    isNetMatch = true 
                }
                
                
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
                
                
                
                if titleH > 0 { score += 500; isContMatch = true }
                if titleA > 0 { score += 500; isContMatch = true }
                
                
                if descH > 0 { score += 300; isContMatch = true }
                if descA > 0 { score += 300; isContMatch = true }
                
                
                if nameH > 0 { score += 200; isContMatch = true }
                if nameA > 0 { score += 200; isContMatch = true }
                
                
                let totalH = nameH + titleH + descH
                let totalA = nameA + titleA + descA
                if totalH > 0 && totalA > 0 { score += 300 }
                
                
                
                let fullInfo = "\(channel.name) \(epgTitle) \(epgDesc)"
                
                if score > 0 {
                    if SmartSearchLogic.checkLanguageMatch(fullInfo, preference: pLang) {
                        score += 2000
                    } else if pLang != .any {
                        if let detected = SmartSearchLogic.detectLanguage(fullInfo) {
                            let isEnglishPref = (pLang == .english)
                            let isEnglishDet = (detected == .english)
                            
                            if detected != pLang && !(isEnglishPref && isEnglishDet) {
                                score -= 2000
                            }
                        }
                    }
                    
                    if pLang != .any, let code = pLang.searchTokens.first {
                        let lower = channel.name.lowercased()
                        if lower.hasPrefix(code + ":") || lower.contains(" " + code + ":") || lower.hasPrefix("[" + code + "]") {
                            score += 5000
                        }
                    }
                }
                
                let q = SmartSearchLogic.detectQuality(fullInfo, width: channel.width, height: channel.height)
                if pQual == .best {
                    
                    if q == .fourK { score += 40 }
                    else if q == .fhd { score += 30 }
                    else if q == .hd { score += 20 }
                } else {
                    
                    if q == pQual { score += 50 }
                }
                
                
                score += channel.qualityScore
                
                if score > 0 || isNetMatch {
                    scoredChannels.append(ChannelScore(channel: channel, score: score, isNetworkMatch: isNetMatch, isContentMatch: isContMatch))
                }
            }
            
            
            scoredChannels.sort { $0.score > $1.score }
            
            
            
            
            
            if let best = scoredChannels.first, best.score >= 1300 {
                let winner = best.channel
                await MainActor.run {
                    self.isSearchingGame = false
                    self.suggestedChannels = [winner] 
                    withAnimation(.easeInOut(duration: 0.4)) { self.channelToAutoPlay = winner }
                    
                    self.prewarmChannel(winner)
                    
                    if let gid = gameID { self.preResolvedCache[gid] = winner }
                }
                return
            }
            
            
            
            let networkMatches = scoredChannels.filter { $0.isNetworkMatch }
            let contentMatches = scoredChannels.filter { $0.isContentMatch && !$0.isNetworkMatch } 
            
            var finalSelection: [StreamChannel] = []
            var usedIDs = Set<Int>()
            
            
            for item in networkMatches.prefix(3) {
                finalSelection.append(item.channel)
                usedIDs.insert(item.channel.id)
            }
            
            
            var addedContent = 0
            for item in contentMatches {
                if addedContent >= 2 { break }
                if !usedIDs.contains(item.channel.id) {
                    finalSelection.append(item.channel)
                    usedIDs.insert(item.channel.id)
                    addedContent += 1
                }
            }
            
            
            if finalSelection.count < 5 {
                for item in scoredChannels {
                    if finalSelection.count >= 5 { break }
                    if !usedIDs.contains(item.channel.id) {
                        finalSelection.append(item.channel)
                        usedIDs.insert(item.channel.id)
                    }
                }
            }
            
            
            let finalSorted = ChannelViewModel.prioritySort(finalSelection, order: manualOrder, precomputedOrderMap: orderMap)
            
            await MainActor.run {
                self.isSearchingGame = false
                if finalSorted.isEmpty {
                    self.showNoStreamsAlert = true
                } else {
                    self.suggestedChannels = finalSorted
                    self.showSelectionSheet = true
                    
                    for ch in finalSorted.prefix(3) {
                        self.prewarmChannel(ch)
                    }
                }
            }
        }
    }
    
    func showStreamOptions(home: String, away: String, sport: SportType, network: String? = nil) {
        
        let inputChannels = self.channels
        let inputHidden = self.hiddenIDs
        let hiddenCatIDs = Set(self.categories.filter { $0.isHidden }.map { $0.id })
        let currentEPG = self.epgData
        let now = self.currentTime
        let manualOrder = self.manualChannelOrder
        let pLang = self.preferredLanguage
        let pQual = self.preferredQuality
        
        self.isSearchingGame = true; self.suggestedChannels = []; self.channelToAutoPlay = nil
        
        Task.detached(priority: .userInitiated) { [weak self, inputChannels, inputHidden, hiddenCatIDs, currentEPG, now, manualOrder, pLang, pQual] in
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
                var isNetMatch = false 
                var isContMatch = false
                
                if !targetNetwork.isEmpty && channel.name.localizedCaseInsensitiveContains(targetNetwork) {
                    score += 1000
                    isNetMatch = true 
                }
                
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
                
                if titleH > 0 { score += 500; isContMatch = true }
                if titleA > 0 { score += 500; isContMatch = true }
                if descH > 0 { score += 300; isContMatch = true }
                if descA > 0 { score += 300; isContMatch = true }
                if nameH > 0 { score += 200; isContMatch = true }
                if nameA > 0 { score += 200; isContMatch = true }
                
                let totalH = nameH + titleH + descH
                let totalA = nameA + titleA + descA
                if totalH > 0 && totalA > 0 { score += 300 }
                
                let fullInfo = "\(channel.name) \(epgTitle) \(epgDesc)"
                
                if score > 0 {
                    if SmartSearchLogic.checkLanguageMatch(fullInfo, preference: pLang) {
                        score += 2000
                    } else if pLang != .any {
                        if let detected = SmartSearchLogic.detectLanguage(fullInfo) {
                            let isEnglishPref = (pLang == .english)
                            let isEnglishDet = (detected == .english)
                            
                            if detected != pLang && !(isEnglishPref && isEnglishDet) {
                                score -= 2000
                            }
                        }
                    }
                    
                    if pLang != .any, let code = pLang.searchTokens.first {
                        let lower = channel.name.lowercased()
                        if lower.hasPrefix(code + ":") || lower.contains(" " + code + ":") || lower.hasPrefix("[" + code + "]") {
                            score += 5000
                        }
                    }
                }
                
                let q = SmartSearchLogic.detectQuality(fullInfo, width: channel.width, height: channel.height)
                if pQual == .best {
                    if q == .fourK { score += 40 }
                    else if q == .fhd { score += 30 }
                    else if q == .hd { score += 20 }
                } else {
                    if q == pQual { score += 50 }
                }
                
                score += channel.qualityScore
                
                if score > 0 || isNetMatch {
                    scoredChannels.append(ChannelScore(channel: channel, score: score, isNetworkMatch: isNetMatch, isContentMatch: isContMatch))
                }
            }
            
            scoredChannels.sort { $0.score > $1.score }
            
            let networkMatches = scoredChannels.filter { $0.isNetworkMatch }
            let contentMatches = scoredChannels.filter { $0.isContentMatch && !$0.isNetworkMatch } 
            
            var finalSelection: [StreamChannel] = []
            var usedIDs = Set<Int>()
            
            for item in networkMatches.prefix(10) {
                finalSelection.append(item.channel)
                usedIDs.insert(item.channel.id)
            }
            
            var addedContent = 0
            for item in contentMatches {
                if addedContent >= 10 { break }
                if !usedIDs.contains(item.channel.id) {
                    finalSelection.append(item.channel)
                    usedIDs.insert(item.channel.id)
                    addedContent += 1
                }
            }
            
            if finalSelection.count < 20 {
                for item in scoredChannels {
                    if finalSelection.count >= 20 { break }
                    if !usedIDs.contains(item.channel.id) {
                        finalSelection.append(item.channel)
                        usedIDs.insert(item.channel.id)
                    }
                }
            }
            
            
            
            
            
            
            
            let sortedByScore = finalSelection
            let scores = Dictionary(uniqueKeysWithValues: scoredChannels.map { ($0.channel.id, $0.score) })
            
            let finalSorted = sortedByScore.sorted { a, b in
                let idxA = orderMap[a.id]
                let idxB = orderMap[b.id]
                
                
                if let iA = idxA, let iB = idxB { return iA < iB }
                if idxA != nil { return true }
                if idxB != nil { return false }
                
                
                let sA = scores[a.id] ?? 0
                let sB = scores[b.id] ?? 0
                if sA != sB { return sA > sB }
                
                
                if a.qualityScore != b.qualityScore { return a.qualityScore > b.qualityScore }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            
            await MainActor.run {
                self.isSearchingGame = false
                if finalSorted.isEmpty {
                    self.showNoStreamsAlert = true
                } else {
                    self.suggestedChannels = finalSorted
                    self.showSelectionSheet = true
                    
                    for ch in finalSorted.prefix(3) {
                        self.prewarmChannel(ch)
                    }
                }
            }
        }
    }
    
    func autoAddGameToMultiView(home: String, away: String, network: String? = nil) {
        let inputChannels = self.channels
        let inputHidden = self.hiddenIDs
        let hiddenCatIDs = Set(self.categories.filter { $0.isHidden }.map { $0.id })
        let currentEPG = self.epgData
        let now = self.currentTime
        let pLang = self.preferredLanguage
        
        Task.detached(priority: .userInitiated) { [weak self, inputChannels, inputHidden, hiddenCatIDs, currentEPG, now, pLang] in
            guard let self = self else { return }
            let homeTokens = SmartSearchLogic.tokenize(home)
            let awayTokens = SmartSearchLogic.tokenize(away)
            let targetNetwork = (network ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            func matchCount(_ text: String, tokens: [String]) -> Int {
                let lower = text.lowercased()
                return tokens.filter { lower.contains($0) }.count
            }
            
            struct ChannelScore { let channel: StreamChannel; let score: Int }
            var scoredChannels: [ChannelScore] = []
            
            for channel in inputChannels {
                if inputHidden.contains(channel.id) || hiddenCatIDs.contains(channel.categoryID) { continue }
                if SmartSearchLogic.isBanner(channel.name) { continue }
                
                var score = 0
                if !targetNetwork.isEmpty && channel.name.localizedCaseInsensitiveContains(targetNetwork) { score += 1000 }
                
                var epgTitle = ""
                var epgDesc = ""
                if let eID = channel.epgID, let schedule = currentEPG[eID], let program = schedule.first(where: { now >= $0.start && now <= $0.stop }) { 
                    epgTitle = program.title
                    epgDesc = program.description ?? ""
                }
                
                let nameH = matchCount(channel.name, tokens: homeTokens); let nameA = matchCount(channel.name, tokens: awayTokens)
                let titleH = matchCount(epgTitle, tokens: homeTokens); let titleA = matchCount(epgTitle, tokens: awayTokens)
                
                if titleH > 0 { score += 500 }; if titleA > 0 { score += 500 }
                if nameH > 0 { score += 200 }; if nameA > 0 { score += 200 }
                
                let fullInfo = "\(channel.name) \(epgTitle) \(epgDesc)"
                
                if score > 0 {
                    if SmartSearchLogic.checkLanguageMatch(fullInfo, preference: pLang) {
                        score += 2000
                    } else if pLang != .any {
                        if let detected = SmartSearchLogic.detectLanguage(fullInfo) {
                            let isEnglishPref = (pLang == .english)
                            let isEnglishDet = (detected == .english)
                            if detected != pLang && !(isEnglishPref && isEnglishDet) { score -= 2000 }
                        }
                    }
                    
                    if pLang != .any, let code = pLang.searchTokens.first {
                        let lower = channel.name.lowercased()
                        if lower.hasPrefix(code + ":") || lower.contains(" " + code + ":") || lower.hasPrefix("[" + code + "]") {
                            score += 5000
                        }
                    }
                }
                
                if score > 0 { scoredChannels.append(ChannelScore(channel: channel, score: score)) }
            }
            
            scoredChannels.sort { $0.score > $1.score }
            
            if let best = scoredChannels.first {
                await MainActor.run { self.addToMultiView(best.channel); self.triggerMultiView = true }
            } else {
                 await MainActor.run { self.showNoStreamsAlert = true }
            }
        }
    }

    func moveChannelInSearch(from source: StreamChannel, to destination: StreamChannel, save: Bool = true) {
        
        var isNameList = false
        if let _ = filteredNameChannels.firstIndex(of: source) { isNameList = true }
        else if filteredEPGChannels.firstIndex(of: source) == nil { return } 
        
        
        withAnimation {
            if isNameList {
                guard let fromIdx = filteredNameChannels.firstIndex(of: source),
                      let toIdx = filteredNameChannels.firstIndex(of: destination) else { return }
                
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
        
        
        var currentOrder = manualChannelOrder
        
        
        if let idx = currentOrder.firstIndex(of: source.id) { currentOrder.remove(at: idx) }
        
        
        if let destIdx = currentOrder.firstIndex(of: destination.id) {
            
            currentOrder.insert(source.id, at: destIdx)
        } else {
            
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
    func swapMultiViewSlots(from sourceIndex: Int, to destIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < 4, destIndex >= 0, destIndex < 4, sourceIndex != destIndex else { return }
        let temp = multiViewSlots[sourceIndex]
        multiViewSlots[sourceIndex] = multiViewSlots[destIndex]
        multiViewSlots[destIndex] = temp
    }
    func addToMultiView(_ channel: StreamChannel) { if let firstEmpty = multiViewSlots.firstIndex(where: { $0 == nil }) { multiViewSlots[firstEmpty] = channel } else { multiViewSlots[3] = channel } }
    func triggerMultiViewFromPlayer(with channel: StreamChannel) { if let firstEmpty = multiViewSlots.firstIndex(where: { $0 == nil }) { multiViewSlots[firstEmpty] = channel } else { multiViewSlots[0] = channel }; triggerMultiView = true }
    func promptRename(name: String, onConfirm: @escaping (String) -> Void) { self.renameInput = name; self.onRenameConfirm = onConfirm; self.showRenameAlert = true }
    func confirmRename() { onRenameConfirm?(renameInput); showRenameAlert = false; renameInput = "" }
    func triggerRenameChannel(_ c: StreamChannel) { promptRename(name: c.name) { [weak self] n in self?.renameChannel(id: c.id, newName: n) } }
    func triggerRenameCategory(_ c: StreamCategory) { promptRename(name: c.name) { [weak self] n in self?.renameCategory(id: c.id, newName: n) } }
    
    func categorizeSports() {
        let currentChannels = self.channels
        let currentConfigs = self.sportsConfigs
        let currentExclusions = self.excludedSportsIDs
        
        let currentEPG = self.epgData
        let currentMap = self.epgNameMap
        let now = self.currentTime
        
        Task.detached(priority: .utility) { [weak self] in
            var localGroups: [String: [StreamChannel]] = [:]
            for channel in currentChannels {
                if currentExclusions.contains(channel.id) { continue }
                let searchName = (channel.originalName ?? channel.name)
                for config in currentConfigs {
                    if config.keywords.contains(where: { searchName.localizedCaseInsensitiveContains($0) }) { localGroups[config.id, default: []].append(channel); break }
                }
            }
            
            
            func getSortDate(for channel: StreamChannel) -> Date {
                let eID = channel.epgID ?? currentMap[channel.name.lowercased()]
                guard let id = eID, let schedule = currentEPG[id] else { return Date.distantFuture }
                
                
                if let current = schedule.first(where: { now >= $0.start && now <= $0.stop }) {
                    return current.start
                }
                
                if let next = schedule.first(where: { $0.start > now }) {
                    return next.start
                }
                
                return Date.distantFuture
            }
            
            for (key, list) in localGroups {
                localGroups[key] = list.sorted { a, b in
                    let dateA = getSortDate(for: a)
                    let dateB = getSortDate(for: b)
                    
                    
                    if dateA != Date.distantFuture || dateB != Date.distantFuture {
                        if dateA != dateB { return dateA < dateB }
                    }
                    
                    
                    let aLive = NameCleaner.isLiveGameOrPPV(a.name)
                    let bLive = NameCleaner.isLiveGameOrPPV(b.name)
                    if aLive != bLive { return aLive }
                    
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
            let finalGroups = localGroups
            await MainActor.run { [weak self] in self?.sportsChannels = finalGroups }
        }
    }
    
    func loadData(url: String, user: String, pass: String, type: LoginType, silent: Bool = false) async {
        
        if !AccountManager.shared.accounts.isEmpty {
            await loadActiveAccounts(silent: silent)
            return
        }
        
        
        let tempAccount = Account(name: "Main", type: type, url: url, username: user, password: pass, isActive: true, stableID: 0)
        
        
        await MainActor.run {
            AccountManager.shared.saveAccount(tempAccount, makeActive: true)
        }
    }

    func updateEPG(baseURL: URL, user: String, pass: String, force: Bool = false, silent: Bool = false) async {
        let now = Date()
        let isStale = lastEPGUpdateTime == nil || now.timeIntervalSince(lastEPGUpdateTime!) >= 86400 
        
        
        if !force && !isStale {
            if let cached = EPGService().loadFromDisk(), !cached.epg.isEmpty {
                await MainActor.run { 
                    self.epgData = cached.epg
                    self.epgNameMap = cached.map
                }
                return
            }
        }

        
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
    
    func updateEPGFromURLs(_ urls: [URL], force: Bool = false, silent: Bool = false) async {
        let now = Date()
        let isStale = lastEPGUpdateTime == nil || now.timeIntervalSince(lastEPGUpdateTime!) >= 86400 
        
        let urlsChanged = Set(urls) != Set(lastFetchedEPGUrls)
        if urlsChanged { lastFetchedEPGUrls = urls }
        let shouldForce = force || urlsChanged
        
        if !shouldForce && !isStale && !self.epgData.isEmpty {
            print("✅ [EPG] Data is fresh. Skipping network fetch.")
            return
        }
        
        await MainActor.run {
            self.visualProgress = 0
            self.epgProgress = 0
            self.loadingStatus = "Updating Guide..."
            withAnimation(.spring()) { self.isUpdatingEPG = true }
            self.startSmoothingTimer()
        }
        
        let result = await EPGService().fetchAndMergeEPGs(urls: urls) { progress in
            Task { @MainActor in self.epgProgress = progress }
        }
        
        await MainActor.run {
            self.lastEPGUpdateTime = Date()
            self.epgProgress = 1.0
            self.visualProgress = 1.0
            self.epgData = result.epg
            self.epgNameMap = result.map
        }
    }
    
    
    func updateEPGFromURL(_ url: URL, silent: Bool = false) async {
        await updateEPGFromURLs([url], force: false, silent: silent)
    }
    
    
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
        
        let loadedRecents = load("recentChannelIDs", type: [Int].self) ?? []
        self.recentIDs = loadedRecents.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        self.manualChannelOrder = load("manualChannelOrder", type: [Int].self) ?? []
        self.recentQueries = UserDefaults.standard.stringArray(forKey: settingsPrefix + "recentQueries") ?? []
        
        if let langRaw = UserDefaults.standard.string(forKey: settingsPrefix + "preferredLanguage"), let lang = LanguagePreference(rawValue: langRaw) { self.preferredLanguage = lang }
        if let qualRaw = UserDefaults.standard.string(forKey: settingsPrefix + "preferredQuality"), let qual = StreamQuality(rawValue: qualRaw) { self.preferredQuality = qual }
        self.hapticsEnabled = UserDefaults.standard.object(forKey: settingsPrefix + "hapticsEnabled") as? Bool ?? true
        
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
    
    func saveSportsConfigs() {
        if let encoded = try? JSONEncoder().encode(sportsConfigs) { UserDefaults.standard.set(encoded, forKey: settingsPrefix + "sportsConfigs") }
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
    
    nonisolated static func parseM3U(content: String, idOffset: Int, accountID: UUID) async -> ([StreamChannel], [StreamCategory], String?) {
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
                
                
                let originalID = i 
                current = StreamChannel(id: originalID + idOffset, name: name, streamURL: "", icon: logo, categoryID: catID + idOffset, originalName: name, epgID: eID, hasArchive: false, originalID: originalID, accountID: accountID)
            } else if !line.hasPrefix("#") && !line.isEmpty && current != nil {
                var fin = current!; fin.streamURL = line; fin.name = NameCleaner.clean(fin.name); channels.append(fin); current = nil
            }
        }
        return (channels, categories, epgUrl)
    }
    
    nonisolated static private func buildApiUrl(base: URL, user: String, pass: String, action: String) async throws -> URL {
        var c = URLComponents(url: base.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "username", value: user), URLQueryItem(name: "password", value: pass), URLQueryItem(name: "action", value: action)]
        guard let url = c?.url else { throw URLError(.badURL) }
        return url
    }
    
    nonisolated static func processCategories(_ loadedCats: [StreamCategory], prefix: String, idOffset: Int) async -> [StreamCategory] {
        var mutable = loadedCats; let data = UserDefaults.standard.data(forKey: prefix + "renamedCategories") ?? Data()
        let renames = (try? JSONDecoder().decode([Int: String].self, from: data)) ?? [:]
        
        
        struct Wrapper: Codable { let id: Int; var name: String; var isHidden: Bool; var order: Int }
        if let savedData = UserDefaults.standard.data(forKey: prefix + "savedCategoriesanda"),
           let saved = try? JSONDecoder().decode([Wrapper].self, from: savedData) {
            
            
            let savedMap = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
            
            for i in 0..<mutable.count {
                let originalID = mutable[i].id
                
                mutable[i] = StreamCategory(id: originalID + idOffset, name: mutable[i].name)
                
                if let s = savedMap[originalID] {
                    var c = mutable[i]
                    c.isHidden = s.isHidden
                    c.order = s.order
                    
                    if let custom = renames[originalID] { c.name = custom }
                    else { c.name = s.name } 
                    mutable[i] = c
                } else {
                     
                    if let custom = renames[originalID] { mutable[i].name = custom }
                    mutable[i].order = 9999 + i 
                }
            }
            
             return mutable.sorted { $0.order < $1.order }
        }
        
        for i in 0..<mutable.count { 
            let originalID = mutable[i].id
            
            mutable[i] = StreamCategory(id: originalID + idOffset, name: mutable[i].name)
            if let custom = renames[originalID] { mutable[i].name = custom }
            mutable[i].order = i + idOffset
        }
        return mutable.sorted { $0.order < $1.order }
    }
    
    nonisolated static func processChannels(_ raw: [StreamChannel], safeURL: String, user: String, pass: String, prefix: String, idOffset: Int, accountID: UUID) async -> [StreamChannel] {
        let data = UserDefaults.standard.data(forKey: prefix + "renamedChannels") ?? Data()
        let renames = (try? JSONDecoder().decode([Int: String].self, from: data)) ?? [:]
        return raw.map { 
            var c = $0
            c.originalID = c.id
            c.accountID = accountID
            c.id = c.id + idOffset 
            c.categoryID = c.categoryID + idOffset 
            c.streamURL = "\(safeURL)/live/\(user)/\(pass)/\($0.id).m3u8"
            c.originalName = c.name
            if let custom = renames[c.originalID ?? 0] { c.name = custom } 
            else { c.name = NameCleaner.clean(c.name) }
            return c 
        }
    }
    
    func buildTimeshiftURL(channel: StreamChannel, targetDate: Date, program: EPGProgram) async -> URL? {
        
        guard let original = URL(string: channel.streamURL) else { return nil }
        let urlString = original.absoluteString
        
        if urlString.contains("/live/") {
            let durationMinutes = Int(program.stop.timeIntervalSince(program.start) / 60)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd:HH-mm"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let startString = formatter.string(from: targetDate)
            
            
            
            
            
            let newString = urlString.replacingOccurrences(of: "/live/", with: "/timeshift/")
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
    
    private func startSmoothingTimer() {
        stopSmoothingTimer() 
        self.visualProgress = 0
        self.epgProgress = 0
        smoothingTimer = Timer.publish(every: 0.016, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.isUpdatingEPG {
                    let diff = self.epgProgress - self.visualProgress
                    if abs(diff) > 0.001 {
                        self.visualProgress += diff * 0.04
                    } else {
                        self.visualProgress = self.epgProgress
                    }
                }
            }
    }

    func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        if hapticsEnabled {
            let generator = UIImpactFeedbackGenerator(style: style)
            generator.impactOccurred()
        }
    }
    
    func triggerSelectionHaptic() {
        if hapticsEnabled {
            let generator = UISelectionFeedbackGenerator()
            generator.selectionChanged()
        }
    }
    
    func triggerNotificationHaptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        if hapticsEnabled {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(type)
        }
    }

    private func stopSmoothingTimer() {
        smoothingTimer?.cancel()
        smoothingTimer = nil
    }
}
