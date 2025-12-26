import SwiftUI
import Combine

// MARK: - VIEW MODELS
@MainActor
class ChannelViewModel: ObservableObject {
    @Published var categories: [StreamCategory] = []
    @Published var channels: [StreamChannel] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    
    // Split Search Results
    @Published var filteredEPGChannels: [StreamChannel] = []
    @Published var filteredNameChannels: [StreamChannel] = []
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
    
    // EPG State
    @Published var epgData: [String: [EPGProgram]] = [:]
    @Published var currentTime = Date()
    @Published var epgProgress: Double = 0
    @Published var isUpdatingEPG: Bool = false
    
    // Smoothing / Fake Progress state
    private var visualProgress: Double = 0
    private var epgClockTimer: AnyCancellable?
    private var smoothingTimer: AnyCancellable?
    
    private var onRenameConfirm: ((String) -> Void)?
    private var renamedChannels: [Int: String] = [:]
    private var renamedCategories: [Int: String] = [:]
    private var searchTask: Task<Void, Never>?
    var activeMultiViewCount: Int { multiViewSlots.compactMap { $0 }.count }
    
    init() {
        loadSettings()
        startEPGClock()
    }
    
    func reset() {
        self.channels = []; self.categories = []; self.filteredEPGChannels = []; self.filteredNameChannels = []; self.sportsChannels = [:]
        self.searchText = ""; self.errorMessage = nil; self.isLoading = false; self.isSearchingGame = false
        self.multiViewSlots = [nil, nil, nil, nil]; self.multiViewModeActive = false; self.suggestedChannels = []
        self.showSelectionSheet = false; self.epgData = [:]
    }

    private func startEPGClock() {
        epgClockTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.currentTime = Date() }
    }

    func getCurrentProgram(for channel: StreamChannel) -> EPGProgram? {
        guard let eID = channel.epgID, let schedule = epgData[eID] else { return nil }
        return schedule.first { currentTime >= $0.start && currentTime <= $0.stop }
    }

    // High performance search logic
    private func performSearch() {
        searchTask?.cancel()
        
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            self.filteredEPGChannels = []
            self.filteredNameChannels = []
            self.isSearching = false
            return
        }
        
        self.isSearching = true
        
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            // Debounce manually inside the task
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            
            let allChannels = await self.channels
            let hidden = await self.hiddenIDs
            let epg = await self.epgData
            let now = await self.currentTime
            let tokens = query.lowercased().components(separatedBy: " ").filter { !$0.isEmpty }
            
            var epgMatches: [StreamChannel] = []
            var nameMatches: [StreamChannel] = []
            
            for channel in allChannels {
                if hidden.contains(channel.id) { continue }
                
                var currentProgramTitle = ""
                if let eID = channel.epgID, let schedule = epg[eID] {
                    if let program = schedule.first(where: { now >= $0.start && now <= $0.stop }) {
                        currentProgramTitle = program.title
                    }
                }
                
                let lowerName = channel.name.lowercased()
                let lowerGuide = currentProgramTitle.lowercased()
                
                let guideMatch = tokens.allSatisfy { lowerGuide.contains($0) }
                let nameMatch = tokens.allSatisfy { lowerName.contains($0) }
                
                if guideMatch { epgMatches.append(channel) }
                else if nameMatch { nameMatches.append(channel) }
            }
            
            let sortedEPG = ChannelViewModel.prioritySort(epgMatches)
            let sortedName = ChannelViewModel.prioritySort(nameMatches)
            
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                self.filteredEPGChannels = sortedEPG
                self.filteredNameChannels = sortedName
                self.isSearching = false
                
                // Add to recent queries if it actually returned results and is long enough
                if (!sortedEPG.isEmpty || !sortedName.isEmpty) && query.count > 2 {
                    self.addRecentQuery(query)
                }
            }
        }
    }

    func addRecentQuery(_ query: String) {
        let clean = query.lowercased().trimmingCharacters(in: .whitespaces)
        if let idx = recentQueries.firstIndex(of: clean) { recentQueries.remove(at: idx) }
        recentQueries.insert(clean, at: 0)
        if recentQueries.count > 10 { recentQueries = Array(recentQueries.prefix(10)) }
        UserDefaults.standard.set(recentQueries, forKey: "recentQueries")
    }
    
    func removeRecentQuery(_ query: String) {
        recentQueries.removeAll { $0 == query }
        UserDefaults.standard.set(recentQueries, forKey: "recentQueries")
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

    nonisolated static func prioritySort(_ channels: [StreamChannel]) -> [StreamChannel] {
        return channels.sorted { a, b in
            let scoreA = qualityScore(for: a.name)
            let scoreB = qualityScore(for: b.name)
            if scoreA != scoreB { return scoreA > scoreB }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func runSmartSearch(home: String, away: String, sport: SportType, network: String? = nil) {
        let inputChannels = self.channels
        let inputHidden = self.hiddenIDs
        let currentEPG = self.epgData
        let now = self.currentTime
        
        self.isSearchingGame = true; self.suggestedChannels = []; self.channelToAutoPlay = nil
        
        Task.detached(priority: .userInitiated) { [weak self, inputChannels, inputHidden, currentEPG, now] in
            guard let self = self else { return }
            let homeTokens = SmartSearchLogic.tokenize(home)
            let awayTokens = SmartSearchLogic.tokenize(away)
            
            var exactMatches: [StreamChannel] = []
            for channel in inputChannels {
                if inputHidden.contains(channel.id) { continue }
                if let eID = channel.epgID, let schedule = currentEPG[eID] {
                    if let program = schedule.first(where: { now >= $0.start && now <= $0.stop }) {
                        let lowerTitle = program.title.lowercased()
                        if homeTokens.allSatisfy({ lowerTitle.contains($0) }) && awayTokens.allSatisfy({ lowerTitle.contains($0) }) {
                            exactMatches.append(channel)
                        }
                    }
                }
            }
            
            let sortedMatches = ChannelViewModel.prioritySort(exactMatches)
            
            if let winner = sortedMatches.first, ChannelViewModel.qualityScore(for: winner.name) > 100 {
                await MainActor.run {
                    self.isSearchingGame = false
                    withAnimation(.easeInOut(duration: 0.4)) { self.channelToAutoPlay = winner }
                }
                return
            }
            
            let scored = inputChannels.compactMap { channel -> (StreamChannel, Int)? in
                if inputHidden.contains(channel.id) || SmartSearchLogic.isBanner(channel.name) { return nil }
                var score = SmartSearchLogic.calculateStreamScore(name: channel.name, sport: sport, targetNetwork: network)
                let lowerName = channel.name.lowercased()
                if homeTokens.contains(where: { lowerName.contains($0) }) && awayTokens.contains(where: { lowerName.contains($0) }) { score += 60000 }
                else if homeTokens.contains(where: { lowerName.contains($0) }) || awayTokens.contains(where: { lowerName.contains($0) }) { score += 15000 }
                score += ChannelViewModel.qualityScore(for: channel.name) * 10
                return (channel, score)
            }.sorted { $0.1 > $1.1 }

            await MainActor.run {
                self.isSearchingGame = false
                let topOptions = scored.prefix(5).map { $0.0 }
                if let winner = sortedMatches.first {
                    withAnimation(.easeInOut(duration: 0.4)) { self.channelToAutoPlay = winner }
                } else if !topOptions.isEmpty {
                    self.suggestedChannels = topOptions; self.showSelectionSheet = true
                } else {
                    self.showNoStreamsAlert = true
                }
            }
        }
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
    
    func loadData(url: String, user: String, pass: String, type: LoginType) async {
        guard !url.isEmpty else { return }
        if channels.isEmpty { isLoading = true; errorMessage = nil }
        var safeURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !safeURL.lowercased().hasPrefix("http") { safeURL = "http://" + safeURL }
        guard let baseURL = URL(string: safeURL) else { isLoading = false; return }
        
        do {
            if type == .xtream {
                await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self, baseURL, user, pass] in
                        guard let self = self else { return }
                        let catUrl = try await self.buildApiUrl(base: baseURL, user: user, pass: pass, action: "get_live_categories")
                        let (data, _) = try await URLSession.shared.data(from: catUrl)
                        let cats = try JSONDecoder().decode([StreamCategory].self, from: data)
                        let processed = await self.processCategories(cats)
                        await MainActor.run { [weak self] in self?.categories = processed }
                    }
                    group.addTask { [weak self, baseURL, user, pass, safeURL] in
                        guard let self = self else { return }
                        let streamUrl = try await self.buildApiUrl(base: baseURL, user: user, pass: pass, action: "get_live_streams")
                        let (data, _) = try await URLSession.shared.data(from: streamUrl)
                        let raw = try JSONDecoder().decode([StreamChannel].self, from: data)
                        let processed = await self.processChannels(raw, safeURL: safeURL, user: user, pass: pass)
                        await MainActor.run { [weak self] in self?.channels = processed; self?.categorizeSports() }
                        await self.updateEPG(baseURL: baseURL, user: user, pass: pass)
                    }
                }
            } else {
                let (data, _) = try await URLSession.shared.data(from: baseURL)
                if let content = String(data: data, encoding: .utf8) {
                    let (pChannels, pCategories, epgUrl) = await parseM3U(content: content)
                    self.channels = pChannels; self.categories = pCategories; self.categorizeSports()
                    if let eURL = epgUrl, let xmlURL = URL(string: eURL) {
                        await self.updateEPGFromURL(xmlURL)
                    }
                }
            }
        } catch { self.errorMessage = "Error: " + error.localizedDescription }
        self.isLoading = false
    }
    
    func updateEPG(baseURL: URL, user: String, pass: String) async {
        let epgUrl = baseURL.appendingPathComponent("xmltv.php")
        var c = URLComponents(url: epgUrl, resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "username", value: user), URLQueryItem(name: "password", value: pass)]
        if let finalEPG = c?.url { await updateEPGFromURL(finalEPG) }
    }
    
    func updateEPGFromURL(_ url: URL) async {
        await MainActor.run {
            self.visualProgress = 0
            self.epgProgress = 0
            withAnimation(.spring()) { self.isUpdatingEPG = true }
            
            // Start a smoothing timer that ticks up progress visually
            self.smoothingTimer?.cancel()
            self.smoothingTimer = Timer.publish(every: 0.15, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    // If real data is ahead, jump to it. Otherwise, increment 1%
                    if self.epgProgress < self.visualProgress {
                        if self.visualProgress < 0.98 {
                            self.visualProgress += 0.01 // Slow, steady increment
                        }
                    } else {
                        // Zip up to catch real data, but don't exceed 100
                        self.visualProgress = min(self.epgProgress, 1.0)
                    }
                }
        }
        
        let epgMap = await EPGService().fetchAndParseEPG(url: url) { progress in
            self.epgProgress = progress
        }
        
        await MainActor.run {
            // Once finished, ensure progress shows 100% then hide
            self.epgProgress = 1.0
            self.visualProgress = 1.0
            self.epgData = epgMap
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(.easeOut(duration: 0.5)) {
                    self.isUpdatingEPG = false
                    self.smoothingTimer?.cancel()
                }
            }
        }
    }
    
    // Exposed property for the UI to use the smooth progress
    var displayEPGProgress: Double {
        return visualProgress
    }

    func loadSettings() {
        func load<T: Decodable>(_ key: String, type: T.Type) -> T? {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        self.renamedChannels = load("renamedChannels", type: [Int: String].self) ?? [:]
        self.renamedCategories = load("renamedCategories", type: [Int: String].self) ?? [:]
        self.excludedSportsIDs = Set(load("excludedSportsIDs", type: [Int].self) ?? [])
        self.favoriteIDs = Set(load("favoriteChannelIDs", type: [Int].self) ?? [])
        self.hiddenIDs = Set(load("hiddenChannelIDs", type: [Int].self) ?? [])
        self.recentIDs = load("recentChannelIDs", type: [Int].self) ?? []
        self.recentQueries = UserDefaults.standard.stringArray(forKey: "recentQueries") ?? []
        
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
        if let encoded = try? JSONEncoder().encode(wrappers) { UserDefaults.standard.set(encoded, forKey: "savedCategories") }
    }

    func renameChannel(id: Int, newName: String) {
        renamedChannels[id] = newName
        if let encoded = try? JSONEncoder().encode(renamedChannels) { UserDefaults.standard.set(encoded, forKey: "renamedChannels") }
        if let index = channels.firstIndex(where: { $0.id == id }) { channels[index].name = newName; performSearch(); categorizeSports(); objectWillChange.send() }
    }
    
    func renameCategory(id: Int, newName: String) {
        renamedCategories[id] = newName
        if let encoded = try? JSONEncoder().encode(renamedCategories) { UserDefaults.standard.set(encoded, forKey: "renamedCategories") }
        if let index = categories.firstIndex(where: { $0.id == id }) { categories[index].name = newName; objectWillChange.send() }
    }
    
    func toggleFavorite(_ id: Int) { if favoriteIDs.contains(id) { favoriteIDs.remove(id) } else { favoriteIDs.insert(id) }; if let d = try? JSONEncoder().encode(Array(favoriteIDs)) { UserDefaults.standard.set(d, forKey: "favoriteChannelIDs") } }
    func hideChannel(_ id: Int) { hiddenIDs.insert(id); if let d = try? JSONEncoder().encode(Array(hiddenIDs)) { UserDefaults.standard.set(d, forKey: "hiddenChannelIDs") } }
    func unhideChannel(_ id: Int) { hiddenIDs.remove(id); if let d = try? JSONEncoder().encode(Array(hiddenIDs)) { UserDefaults.standard.set(d, forKey: "hiddenChannelIDs") } }
    func hideCategory(_ id: Int) { if let idx = categories.firstIndex(where: { $0.id == id }) { categories[idx].isHidden = true; saveCategorySettings() } }
    func addToRecent(_ id: Int) { if let idx = recentIDs.firstIndex(of: id) { recentIDs.remove(at: idx) }; recentIDs.insert(id, at: 0); if recentIDs.count > 20 { recentIDs = Array(recentIDs.prefix(20)) }; if let d = try? JSONEncoder().encode(recentIDs) { UserDefaults.standard.set(d, forKey: "recentChannelIDs") } }
    func removeFromRecent(_ id: Int) { if let idx = recentIDs.firstIndex(of: id) { recentIDs.remove(at: idx); if let d = try? JSONEncoder().encode(recentIDs) { UserDefaults.standard.set(d, forKey: "recentChannelIDs") } } }

    nonisolated func parseM3U(content: String) async -> ([StreamChannel], [StreamCategory], String?) {
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
    
    nonisolated private func buildApiUrl(base: URL, user: String, pass: String, action: String) async throws -> URL {
        var c = URLComponents(url: base.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "username", value: user), URLQueryItem(name: "password", value: pass), URLQueryItem(name: "action", value: action)]
        guard let url = c?.url else { throw URLError(.badURL) }
        return url
    }
    
    nonisolated func processCategories(_ loadedCats: [StreamCategory]) async -> [StreamCategory] {
        var mutable = loadedCats; let data = UserDefaults.standard.data(forKey: "renamedCategories") ?? Data()
        let renames = (try? JSONDecoder().decode([Int: String].self, from: data)) ?? [:]
        for i in 0..<mutable.count { let id = mutable[i].id; if let custom = renames[id] { mutable[i].name = custom }; mutable[i].order = i }
        return mutable.sorted { $0.order < $1.order }
    }
    
    nonisolated func processChannels(_ raw: [StreamChannel], safeURL: String, user: String, pass: String) async -> [StreamChannel] {
        let data = UserDefaults.standard.data(forKey: "renamedChannels") ?? Data()
        let renames = (try? JSONDecoder().decode([Int: String].self, from: data)) ?? [:]
        return raw.map { var c = $0; c.streamURL = "\(safeURL)/live/\(user)/\(pass)/\($0.id).m3u8"; c.originalName = c.name; if let custom = renames[c.id] { c.name = custom } else { c.name = NameCleaner.clean(c.name) }; return c }
    }
}
