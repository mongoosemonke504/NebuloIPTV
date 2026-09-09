import SwiftUI
import Combine
import UIKit

/// Holds transient EPG-update progress state in its own ObservableObject so that
/// high-frequency progress publishes (10 fps timer) only cause the tiny loading
/// banner to re-render — never the main channel list or category views.
final class EPGLoadingState: ObservableObject {
    @Published fileprivate(set) var progress: Double = 0
}

@MainActor
class ChannelViewModel: ObservableObject {
    static let shared = ChannelViewModel()
    
    @Published var categories: [StreamCategory] = []
    @Published var channels: [StreamChannel] = [] {
        didSet { resolvedEPGIDCache.removeAll(keepingCapacity: true) }
    }
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
    @Published var currentTime: Date = Date() {
        didSet { invalidateProgramCaches() }
    }
    
    
    @Published var manualChannelOrder: [Int] = []
    
    
    @Published var epgData: [String: [EPGProgram]] = [:] {
        didSet { invalidateEPGLookupCaches() }
    }
    private var epgNameMap: [String: String] = [:] {
        didSet { invalidateEPGLookupCaches() }
    }

    // MARK: - EPG lookup memoisation
    //
    // `getCurrentProgram(for:)` is the single most-called function in the app:
    // roughly forty call sites, nearly all of them inside row bodies, and
    // several rows ask for the same channel two or three times in ONE body
    // evaluation ("is something live?", then the title, then the description).
    // Uncached each of those calls ran `NameCleaner.clean` — twenty-six
    // case-insensitive `range(of:)` searches and a handful of String
    // allocations — and then linearly scanned a whole day of programmes.
    // Multiplied by the visible rows and repeated on every frame of a scroll,
    // that alone kept a core busy and is what made the phone warm up just
    // browsing.
    //
    // Two caches replace it, both pure memoisation — same answers, computed
    // once:
    //  • `resolvedEPGIDCache` — channel id → guide id. This is the expensive
    //    half (the name cleaning) and only depends on the channel list and the
    //    guide, so it survives the 30-second clock tick.
    //  • `currentProgramCache` — guide id → what is on now. Depends on the
    //    clock, so it is dropped on each tick.
    private var resolvedEPGIDCache: [Int: String?] = [:]
    private var currentProgramCache: [String: EPGProgram?] = [:]
    private var nextProgramCache: [String: EPGProgram?] = [:]

    /// Guide data changed underneath us — every memoised answer is suspect.
    private func invalidateEPGLookupCaches() {
        resolvedEPGIDCache.removeAll(keepingCapacity: true)
        currentProgramCache.removeAll(keepingCapacity: true)
        nextProgramCache.removeAll(keepingCapacity: true)
    }

    /// The clock moved — which programme is on has changed, but the channel →
    /// guide-id mapping has not.
    private func invalidateProgramCaches() {
        currentProgramCache.removeAll(keepingCapacity: true)
        nextProgramCache.removeAll(keepingCapacity: true)
    }
    /// Pre-computed curated carousel — one live channel per broad genre group.
    /// Populated on a background thread before isLoading flips to false so the
    /// home screen never has to compute this on first render.
    @Published var featuredChannels: [StreamChannel] = []
    /// The best-known networks this playlist carries, most-watched first —
    /// ranked once alongside the featured picks, never re-derived per render.
    @Published var popularChannels: [StreamChannel] = []

    /// Channels the user has PINNED to the hero carousel. Empty means the
    /// automatic picks; anything here replaces them wholesale, in this order.
    @Published var customHeroIDs: [Int] = [] {
        didSet {
            guard customHeroIDs != oldValue else { return }
            if let d = try? JSONEncoder().encode(customHeroIDs) {
                UserDefaults.standard.set(d, forKey: settingsPrefix + "customHeroIDs")
            }
        }
    }

    func toggleHeroChannel(_ id: Int) {
        if let idx = customHeroIDs.firstIndex(of: id) { customHeroIDs.remove(at: idx) }
        else { customHeroIDs.append(id) }
    }

    /// The themed rows of big cards, in the order the home screen shows them.
    @Published var spotlightGroups: [SpotlightGroup] = []

    /// One themed row of big cards.
    struct SpotlightGroup: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let channels: [StreamChannel]
    }

    // MARK: - Home section order

    /// One section of the home page below the hero — either a category shelf or
    /// a row of big cards. Exists so the order can be stored as a plain list of
    /// ids and reordered on a settings screen.
    struct HomeSection: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let isSpotlight: Bool
    }

    /// The user's chosen section order, as `HomeSection` ids. EMPTY means "the
    /// natural order" — which is the shipping default, so a fresh install and a
    /// user who has reset both get the interleave below with nothing stored.
    @Published var homeRowOrder: [String] = []

    /// Ids for a category shelf and a big-card row. The home page builds its
    /// rows with these too, so an id means the same thing in both places.
    nonisolated static func homeSectionID(categoryID: Int) -> String { "c\(categoryID)" }
    nonisolated static func homeSectionID(spotlightID: String) -> String { "s\(spotlightID)" }

    /// The home page's NATURAL section order: category shelves in threes with a
    /// row of big cards dropped in after each three, and any big-card rows still
    /// owed at the end rather than dropped.
    func naturalHomeSections() -> [HomeSection] {
        var out: [HomeSection] = []
        var groups = spotlightGroups[...]
        var sinceSpotlight = 0
        for cat in categories where !cat.isHidden {
            // `renameCategory` writes straight into `categories`, so this is
            // already the name the shelf header shows.
            out.append(HomeSection(id: Self.homeSectionID(categoryID: cat.id),
                                   title: cat.name,
                                   isSpotlight: false))
            sinceSpotlight += 1
            if sinceSpotlight == 3, let group = groups.first {
                groups = groups.dropFirst()
                out.append(HomeSection(id: Self.homeSectionID(spotlightID: group.id),
                                       title: group.title,
                                       isSpotlight: true))
                sinceSpotlight = 0
            }
        }
        for group in groups {
            out.append(HomeSection(id: Self.homeSectionID(spotlightID: group.id),
                                   title: group.title,
                                   isSpotlight: true))
        }
        return out
    }

    /// `naturalHomeSections()` with the saved order applied.
    ///
    /// Sections the saved order knows about come first, in that order; anything
    /// it doesn't — a category the playlist grew, a themed row that only just
    /// finished computing — keeps its natural relative position on the end. So a
    /// new category appears rather than vanishing, and never silently displaces
    /// an arrangement the user set by hand.
    func orderedHomeSections() -> [HomeSection] {
        let natural = naturalHomeSections()
        guard !homeRowOrder.isEmpty else { return natural }
        var rank: [String: Int] = [:]
        for (index, id) in homeRowOrder.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        let known = natural.filter { rank[$0.id] != nil }
            .sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
        let unknown = natural.filter { rank[$0.id] == nil }
        return known + unknown
    }

    /// Drag-to-reorder from the settings screen. Stores the FULL resolved order
    /// so sections that were only implied become explicit.
    func moveHomeSection(from source: IndexSet, to destination: Int) {
        var sections = orderedHomeSections()
        sections.move(fromOffsets: source, toOffset: destination)
        homeRowOrder = sections.map(\.id)
        saveHomeRowOrder()
    }

    /// Back to the shipping arrangement.
    func resetHomeSectionOrder() {
        homeRowOrder = []
        saveHomeRowOrder()
    }

    private func saveHomeRowOrder() {
        if let data = try? JSONEncoder().encode(homeRowOrder) {
            UserDefaults.standard.set(data, forKey: settingsPrefix + "homeRowOrder")
        }
    }

    /// The themes, in home-screen order, and the words that put a channel in
    /// one. Matched against the channel's CATEGORY name first (playlists group
    /// by exactly these) and its own name second.
    nonisolated static let spotlightThemes: [(id: String, title: String, keywords: [String])] = [
        ("sports", "Sports",  ["sport", "espn", "nfl", "nba", "mlb", "nhl", "golf", "tennis",
                               "soccer", "football", "ufc", "fight", "racing", "nascar", "f1"]),
        ("usa",    "USA",     ["usa", "united states", "america", "us |", "us -", "us:"]),
        ("news",   "News",    ["news", "cnn", "msnbc", "fox news", "bbc", "sky news"]),
        ("kids",   "Kids",    ["kid", "cartoon", "children", "disney", "nick", "family", "junior"]),
        ("latino", "Latino",  ["latino", "latin", "spanish", "espanol", "español", "mexico",
                               "univision", "telemundo", "deportes"]),
        ("247",    "24/7",    ["24/7", "24-7", "247 ", " 247", "24 7"])
    ]

    /// True only while `updateEPGFromURLs` is actually fetching. Distinct from
    /// `isUpdatingEPG`, which is the BANNER's state and is set by callers.
    private var epgFetchInFlight = false

    private var epgProgress: Double = 0          // internal only — not published
    @Published var isUpdatingEPG: Bool = false
    @Published var loadingStatus: String = "Loading..."
    @Published var categoryColors: [Int: String] = [:]
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
    
    /// The guide is considered stale after this long (12 hours) — both the
    /// in-app freshness checks and the background refresh scheduling key off
    /// this single constant.
    static let epgMaxAge: TimeInterval = 12 * 3600

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

    /// Read-only view of the last successful EPG refresh, for the background
    /// scheduler to compute the next earliest run.
    var lastEPGUpdateDate: Date? { lastEPGUpdateTime }
    
    
    private var visualProgress: Double = 0        // internal only — not published
    private var epgClockTimer: AnyCancellable?
    private var smoothingTimer: AnyCancellable?

    /// Observed only by the loading banner — isolates high-frequency progress
    /// updates from the rest of the view hierarchy.
    let epgState = EPGLoadingState()
    
    private var onRenameConfirm: ((String) -> Void)?
    private var renamedChannels: [Int: String] = [:]
    private var renamedCategories: [Int: String] = [:]
    /// Bumped whenever a category's NAME changes (rename). The home shelves
    /// cache their grouped categories keyed on `categories.count`, which a
    /// rename doesn't change — so without a separate signal the renamed name
    /// only appeared after a relaunch rebuilt the cache from scratch.
    @Published var categoryRevision: Int = 0
    private var searchTask: Task<Void, Never>?
    private var settingsPrefix: String = ""
    var activeMultiViewCount: Int { multiViewSlots.compactMap { $0 }.count }
    
    private var cancellables = Set<AnyCancellable>()
    private var lastKnownAccountCount: Int = 0
    
    init() {
        loadSettings()
        startEPGClock()
        
        
        // Seed with the current count and skip the publisher's replay of the
        // existing value: without dropFirst, every app launch looked like a
        // freshly-added account and kicked off a forced full reload + EPG
        // update that raced the normal startup load — the loser's cleanup was
        // discarded (stale loadID), leaving the "Loading Playlists…" pill
        // spinning forever.
        lastKnownAccountCount = AccountManager.shared.accounts.count
        AccountManager.shared.$accounts
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] newAccounts in
                guard let self = self else { return }
                let accountAdded = newAccounts.count > self.lastKnownAccountCount
                self.lastKnownAccountCount = newAccounts.count
                DispatchQueue.main.async {
                    if accountAdded {
                        // New login — force a full reload including EPG so the
                        // freshly-added account's guide data loads immediately.
                        Task { await self.loadActiveAccounts(force: true, performEpgCheck: true) }
                    } else {
                        Task { await self.loadActiveAccounts() }
                    }
                }
            }
            .store(in: &cancellables)
            
        
        Task { await loadActiveAccounts() }
    }
    
    func handleAppActivation() async {
        let now = Date()

        // An update already running owns the progress. Coming back to the app
        // used to call straight through to `loadActiveAccounts`, which cancels
        // the in-flight load and starts another — and the new one resets both
        // `epgProgress` and `visualProgress` to zero. The banner was not
        // counting backwards so much as starting over, which looks the same.
        if isUpdatingEPG {
            print("⏳ [ChannelViewModel] EPG update already running — leaving it alone.")
            return
        }
        
        
        if self.channels.isEmpty {
            print("🔄 [ChannelViewModel] No channels found, triggering immediate load...")
            await loadActiveAccounts(silent: false, performEpgCheck: true)
            return
        }

        
        if let lastUpdate = lastEPGUpdateTime, now.timeIntervalSince(lastUpdate) < Self.epgMaxAge {
            print("✅ [ChannelViewModel] EPG is fresh (< 12h). Skipping update.")

            await loadActiveAccounts(silent: true, performEpgCheck: false)
            return
        }

        print("🔄 [ChannelViewModel] EPG is stale (> 12h). triggering update...")
        await loadActiveAccounts(silent: false, performEpgCheck: true)
    }

    func loadActiveAccounts(silent: Bool = false, force: Bool = false, performEpgCheck: Bool = false) async {
        
        if isLoading && silent { return }
        
        
        var shouldUpdateEPG = performEpgCheck
        let now = Date()
        if performEpgCheck && !force {
            if let last = lastEPGUpdateTime, now.timeIntervalSince(last) < Self.epgMaxAge {
                print("✅ [ChannelViewModel] EPG is fresh (< 12h). Suppressing EPG update.")
                shouldUpdateEPG = false
            }
        }
        
        currentLoadTask?.cancel()
        let loadID = UUID()
        self.currentLoadID = loadID
        
        currentLoadTask = Task {
            let startTime = Date()
            var hadCachedChannels = false
            
            
            await MainActor.run {
                
                if !silent {
                    self.isLoading = true
                    self.loadingStatus = "Loading Playlists..."
                }
                
                
                if force {
                    self.channels = []
                }
                
                if !silent && !force {
                    if let (cachedChans, cachedCats) = self.loadFromCache() {
                        if !cachedChans.isEmpty {
                            hadCachedChannels = true
                            self.channels = cachedChans
                            self.categories = cachedCats
                            self.categorizeSports()
                        }
                    }
                }

                // Restore the guide from disk straight away (in parallel with
                // the network fetch) so programme info is on screen at launch
                // instead of appearing only after the full reload finishes.
                if self.epgData.isEmpty {
                    Task {
                        let loaded = await Task.detached(priority: .userInitiated) {
                            await EPGService().loadFromDisk()
                        }.value
                        if let cached = loaded, !cached.epg.isEmpty {
                            await MainActor.run {
                                if self.epgData.isEmpty {
                                    self.epgData = cached.epg
                                    self.epgNameMap = cached.map
                                }
                            }
                        }
                    }
                }
                
                
                if shouldUpdateEPG {
                    self.isUpdatingEPG = true
                    self.loadingStatus = "Checking for updates..."
                    self.startSmoothingTimer()
                } else if self.isUpdatingEPG {
                    // A previous load was cancelled mid-EPG-update (its cleanup
                    // is discarded once currentLoadID changes). This load owns
                    // the state now — clear the stale banner.
                    self.isUpdatingEPG = false
                    self.stopSmoothingTimer()
                }
            }

            let accounts = AccountManager.shared.accounts.filter { $0.isActive }
            if accounts.isEmpty {
                await MainActor.run {
                    guard self.currentLoadID == loadID else { return }
                    self.isUpdatingEPG = false
                    self.stopSmoothingTimer()
                    self.isLoading = false
                }
                return
            }
            if Task.isCancelled {
                await MainActor.run { 
                    guard self.currentLoadID == loadID else { return }
                    self.isUpdatingEPG = false; self.stopSmoothingTimer() 
                }
                return
            }
            
            if self.channels.isEmpty {
                await MainActor.run {
                    if !silent { self.isLoading = true }
                }
            }
            
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
            
            if Task.isCancelled {
                await MainActor.run { 
                    guard self.currentLoadID == loadID else { return }
                    self.isUpdatingEPG = false; self.stopSmoothingTimer() 
                }
                return
            }
            
            await MainActor.run {
                self.channels = allChannels
                self.categories = allCategories.sorted { $0.order < $1.order }
                self.categorizeSports()
                self.saveToCache()
            }
            
            let silentEpg = silent || (hadCachedChannels && !force && !shouldUpdateEPG)
            
            
            if shouldUpdateEPG {
                print("🔄 [ChannelViewModel] Starting Full EPG Update...")
                // NOT awaited before the home screen is released. A full guide
                // download and parse is the ten seconds people were staring at
                // a skeleton for, and the home screen does not need it: the
                // channels are already in, and the guide only fills in what is
                // ON each of them. The banner exists to report exactly this, so
                // the page appears immediately with the update running behind
                // it and the programme lines landing as it finishes.
                //
                // The disk cache below is still awaited — it is a local read,
                // it is quick, and having yesterday's guide beats having none
                // while the new one downloads.
                if self.epgData.isEmpty, let cached = await Task.detached(priority: .userInitiated, operation: {
                    await EPGService().loadFromDisk()
                }).value, !cached.epg.isEmpty {
                    await MainActor.run {
                        self.epgData = cached.epg
                        self.epgNameMap = cached.map
                    }
                }
                Task { [weak self] in
                    guard let self else { return }
                    await self.updateEPGFromURLs(epgUrls, force: force, silent: silentEpg)
                }
            } else {
                print("✅ [ChannelViewModel] Skipping EPG Update (Fresh or Not Requested).")
                
                
                if self.epgData.isEmpty {
                    let loaded = await Task.detached(priority: .userInitiated) {
                        return await EPGService().loadFromDisk()
                    }.value
                    
                    if let cached = loaded, !cached.epg.isEmpty {
                        print("📂 [ChannelViewModel] Loaded EPG from disk cache.")
                        await MainActor.run {
                            self.epgData = cached.epg
                            self.epgNameMap = cached.map
                        }
                    }
                }
            }
            // Pre-warm the featured carousel before the home screen appears.
            // refreshFeaturedChannels snapshots data on the main actor then
            // does the heavy O(channels) scan on a background thread, so this
            // await does NOT block the main thread — it just suspends the load
            // task until the background work finishes. isLoading = false fires
            // only after the result is ready, so the home screen is smooth
            // on first paint with no carousel pop-in.
            if !Task.isCancelled && self.currentLoadID == loadID {
                await self.refreshFeaturedChannels()
            }

            await MainActor.run {
                guard self.currentLoadID == loadID else { return }

                self.lastFullLoadTime = Date()
                self.isLoading = false
                // The EPG update is no longer part of this load, so its banner
                // is left alone here — `updateEPGFromURLs` lowers it when the
                // guide is actually in.
            }
            
            if !silent && self.isLoading {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed < 1.5 {
                    let remaining = 1.5 - elapsed
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            }
            
            if Task.isCancelled {
                await MainActor.run { 
                    guard self.currentLoadID == loadID else { return }
                    self.isUpdatingEPG = false; self.stopSmoothingTimer() 
                }
                return
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
        
        do {
            if account.type == .xtream {
                guard let baseURL = URL(string: account.url) else { return ([], [], []) }
                let user = account.username ?? ""
                let pass = account.password ?? ""
                
                
                let catUrl = try await ChannelViewModel.buildApiUrl(base: baseURL, user: user, pass: pass, action: "get_live_categories")
                let (cData, _) = try await URLSession.shared.data(from: catUrl)
                let cats = try JSONDecoder().decode([StreamCategory].self, from: cData)
                let processedCats = await ChannelViewModel.processCategories(cats, prefix: prefix, idOffset: offset)
                fetchedCategories = processedCats
                
                
                let streamUrl = try await ChannelViewModel.buildApiUrl(base: baseURL, user: user, pass: pass, action: "get_live_streams")
                let (sData, _) = try await URLSession.shared.data(from: streamUrl)
                let raw = try JSONDecoder().decode([StreamChannel].self, from: sData)
                let processedChans = await ChannelViewModel.processChannels(raw, safeURL: account.url, user: user, pass: pass, prefix: prefix, idOffset: offset, accountID: account.id)
                fetchedChannels = processedChans
                
                
                let epgUrl = baseURL.appendingPathComponent("xmltv.php")
                var c = URLComponents(url: epgUrl, resolvingAgainstBaseURL: false)
                c?.queryItems = [URLQueryItem(name: "username", value: user), URLQueryItem(name: "password", value: pass)]
                if let finalEPG = c?.url { fetchedEPGs.append(finalEPG) }
                
            } else {
                
                guard let baseURL = URL(string: account.url) else { return ([], [], []) }
                let (data, _) = try await URLSession.shared.data(from: baseURL)
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

    /// Channel → guide id, memoised. The uncached path cleans the channel
    /// name (twenty-six case-insensitive searches), so this is the half worth
    /// remembering; the answer only changes when the playlist or the guide
    /// does, and both invalidate the cache.
    private func resolvedEPGID(for channel: StreamChannel) -> String? {
        if let cached = resolvedEPGIDCache[channel.id] { return cached }

        let resolved: String? = {
            if let id = channel.epgID, epgData[id] != nil { return id }
            if let direct = epgNameMap[channel.searchNormalizedName] { return direct }
            let cleaned = NameCleaner.clean(channel.name).lowercased()
            return epgNameMap[cleaned]
        }()

        resolvedEPGIDCache[channel.id] = resolved
        return resolved
    }

    func getCurrentProgram(for channel: StreamChannel) -> EPGProgram? {
        guard let id = resolvedEPGID(for: channel) else { return nil }
        if let cached = currentProgramCache[id] { return cached }

        let program = epgData[id]?.first { currentTime >= $0.start && currentTime <= $0.stop }
        currentProgramCache[id] = program
        return program
    }

    func getNextProgram(for channel: StreamChannel) -> EPGProgram? {
        guard let id = resolvedEPGID(for: channel) else { return nil }
        if let cached = nextProgramCache[id] { return cached }

        let program: EPGProgram? = {
            guard let schedule = epgData[id] else { return nil }
            // One pass instead of filter-then-sort over the whole day: the
            // "next" programme is just the earliest start after the cutoff,
            // and the cutoff is the end of what's on now (or now itself, when
            // the channel is between listings).
            var current: EPGProgram? = nil
            for p in schedule where currentTime >= p.start && currentTime <= p.stop {
                current = p
                break
            }
            let cutoff = current?.stop ?? currentTime
            var best: EPGProgram? = nil
            for p in schedule where p.start >= cutoff {
                if best == nil || p.start < best!.start { best = p }
            }
            return best
        }()

        nextProgramCache[id] = program
        return program
    }

    /// Re-computes the curated featured carousel on a background thread.
    /// All required data is snapshotted on the main actor before the detached
    /// task starts — the closure therefore needs no actor isolation.
    /// Awaiting this before `isLoading = false` guarantees the carousel is
    /// ready the instant the home screen first appears.
    func refreshFeaturedChannels() async {
        // Snapshot everything needed — avoids actor-crossing inside the detached task.
        let channels    = self.channels
        let hiddenIDs   = self.hiddenIDs
        let categories  = self.categories
        let epgData     = self.epgData
        let epgNameMap  = self.epgNameMap
        let currentTime = self.currentTime
        let favoriteIDs = self.favoriteIDs
        let recentIDs   = self.recentIDs
        let pinnedHero  = self.customHeroIDs

        let picked = await Task.detached(priority: .userInitiated) { () -> (channels: [StreamChannel], popular: [StreamChannel], groups: [ChannelViewModel.SpotlightGroup]) in
            // Fast lookups
            let catLookup = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
            let chanByID  = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
            let visible   = channels.filter { !hiddenIDs.contains($0.id) }

            // Inline EPG check — operates entirely on snapshotted value-types.
            @inline(__always)
            func hasLiveProgram(_ channel: StreamChannel) -> Bool {
                let eID: String? = {
                    if let id = channel.epgID, epgData[id] != nil { return id }
                    if let d = epgNameMap[channel.name.lowercased()]  { return d }
                    let c = NameCleaner.clean(channel.name).lowercased()
                    return epgNameMap[c]
                }()
                guard let id = eID, let sched = epgData[id] else { return false }
                return sched.first { currentTime >= $0.start && currentTime <= $0.stop } != nil
            }

            @inline(__always)
            func groupOf(_ channel: StreamChannel) -> HomeCategoryGroup {
                catLookup[channel.categoryID]
                    .map { HomeCategoryGroup.classify($0) } ?? .other
            }

            // ── Personalization: weight genres by recency-ranked watch history.
            // Most-recent watch gets the highest weight (1/(rank+1)). Bias toward
            // genres the user actually watches without rigidly excluding others.
            var genreScores: [HomeCategoryGroup: Double] = [:]
            for (rank, id) in recentIDs.enumerated() {
                guard let ch = chanByID[id], !hiddenIDs.contains(id) else { continue }
                let g = groupOf(ch)
                guard g != .other else { continue }
                genreScores[g, default: 0] += 1.0 / Double(rank + 1)
            }

            // Cold-start defaults: popular news / local-broadcast / sports / kids,
            // padded with movies/docs/lifestyle so the carousel still has variety
            // for users with sparse libraries.
            //
            // Note: "local" channels (US ABC/NBC/CBS/Fox affiliates, regional UK,
            // etc.) classify as `.news` via the broadcast-network keywords in
            // HomeCategoryGroup.classify, so .news doubles as the local bucket.
            let defaultGenres: [HomeCategoryGroup] = [.news, .sports, .kids, .lifestyle, .movies, .documentary, .international]

            // Trigger personalization once the user has watched roughly three
            // channels (weighted: 1 + 1/2 + 1/3 ≈ 1.83). Below that, defaults win.
            let hasHistory = genreScores.values.reduce(0, +) >= 1.5

            // Hero slots allocated PROPORTIONALLY to watch share: a user
            // who mostly watches sports gets several sports cards, not one
            // card per genre. Capped at 4 per genre so the carousel always
            // keeps some variety; remaining slots fill from the defaults.
            var slotGenres: [HomeCategoryGroup]
            if hasHistory {
                let total = genreScores.values.reduce(0, +)
                var slots: [HomeCategoryGroup] = []
                for (genre, score) in genreScores.sorted(by: { $0.value > $1.value }) {
                    let share = score / max(total, 0.001)
                    let count = min(4, max(1, Int((share * 6).rounded())))
                    slots.append(contentsOf: Array(repeating: genre, count: count))
                    if slots.count >= 6 { break }
                }
                slots = Array(slots.prefix(6))
                for g in defaultGenres where slots.count < 6 && !slots.contains(g) {
                    slots.append(g)
                }
                slotGenres = slots
            } else {
                slotGenres = defaultGenres
            }

            // ── ONE ranking pass over the playlist.
            // Everything below reads this map instead of re-deriving a rank,
            // because ranking inside a sort comparator meant re-cleaning every
            // channel name tens of thousands of times — enough to hang a big
            // playlist on the loading screen.
            var rankOf: [Int: Int] = [:]
            var bestForNetwork: [Int: StreamChannel] = [:]
            for ch in visible {
                guard let rank = ChannelViewModel.popularityRank(of: ch.name) else { continue }
                rankOf[ch.id] = rank
                // One channel per network: prefer the feed the guide covers.
                if let existing = bestForNetwork[rank] {
                    if !hasLiveProgram(existing), hasLiveProgram(ch) { bestForNetwork[rank] = ch }
                } else {
                    bestForNetwork[rank] = ch
                }
            }
            let popularPicks = bestForNetwork.keys.sorted().compactMap { bestForNetwork[$0] }

            // Bucket all visible channels by genre once — avoids repeatedly
            // scanning the full channel list for each preferred genre.
            //
            // Each bucket is then sorted by how well-known the channel is,
            // because picking `pool.first` meant picking whatever sorted first
            // in the PLAYLIST — i.e. alphabetically, which is how the hero
            // ended up leading with Australian channels beginning with "A".
            var byGenre: [HomeCategoryGroup: [StreamChannel]] = [:]
            for ch in visible {
                let g = groupOf(ch)
                byGenre[g, default: []].append(ch)
            }
            for (genre, pool) in byGenre {
                byGenre[genre] = pool.sorted { a, b in
                    let ra = rankOf[a.id] ?? Int.max
                    let rb = rankOf[b.id] ?? Int.max
                    if ra != rb { return ra < rb }
                    // Among equally unknown channels, one with a logo beats one
                    // without — still deterministic, just not alphabetical.
                    let la = !(a.icon ?? "").isEmpty
                    let lb = !(b.icon ?? "").isEmpty
                    if la != lb { return la }
                    return a.id < b.id
                }
            }

            var result: [StreamChannel] = []
            var seen = Set<Int>()
            // Brands already on a hero card. "ESPN", "ESPN News", "ESPNU" and
            // "Latino ESPN" are all the same brand, and a carousel of four of
            // them is what this exists to prevent — the genre slots pull
            // several channels from one bucket, and that bucket is sorted by
            // popularity, so the ESPN family sat at the front of it together.
            var usedRoots = Set<String>()

            @inline(__always)
            func brandRoot(_ channel: StreamChannel) -> String {
                var cleaned = NameCleaner.clean(channel.name).lowercased()
                // NameCleaner strips "US:" but not "US :", and this playlist
                // writes the spaced form — which left EVERY channel sharing the
                // brand root "us", so the hero could accept exactly one of
                // them. Drop a leading country token before anything else.
                cleaned = cleaned.replacingOccurrences(
                    of: "^[a-z]{2,3}\\s*[:|\\-]\\s*",
                    with: "",
                    options: [.regularExpression]
                )
                // LONGEST match wins, so "US: Fox News HD" resolves to
                // "fox news" and not to "fox" — taking the first match in list
                // order collapsed the two, which both broke the hero's
                // exclusion list and stopped FOX and Fox News being told apart.
                var best: String?
                for target in ChannelViewModel.popularNetworksLower
                where ChannelViewModel.matches(cleaned: cleaned, target: target) {
                    if best == nil || target.count > best!.count { best = target }
                }
                if let best { return best }
                // No word-boundary match: fold a suffixed variant onto its
                // parent brand, which is what makes "espnu" the same brand as
                // "espn". Longest first, for the same reason as above.
                let first = cleaned.split(separator: " ").first.map(String.init) ?? cleaned
                var prefixed: String?
                for target in ChannelViewModel.popularNetworksLower where first.hasPrefix(target) {
                    if prefixed == nil || target.count > prefixed!.count { prefixed = target }
                }
                return prefixed ?? first
            }

            /// Takes a channel for the hero unless its brand is already there.
            @discardableResult
            @inline(__always)
            func accept(_ channel: StreamChannel) -> Bool {
                guard !seen.contains(channel.id) else { return false }
                let root = brandRoot(channel)
                guard !ChannelViewModel.heroExcludedNetworks.contains(root) else { return false }
                guard usedRoots.insert(root).inserted else { return false }
                seen.insert(channel.id)
                result.append(channel)
                return true
            }

            // ── Cold start: the BIG networks lead.
            // With no watch history there's nothing to personalise from, and
            // "one channel per genre" surfaced whatever happened to sort first
            // in each bucket. Lead with the networks people actually watch
            // instead — ranked by 2024-2026 Nielsen total-viewer standings
            // (CBS/NBC/ABC/Fox, then Fox News/ESPN, then the big cable
            // entertainment and sports nets), matched against the playlist by
            // name. Anything not carried is simply skipped, and the genre
            // logic below fills whatever's left.
            if !hasHistory {
                // Variety matters more than rank order here: taken straight,
                // the list opens with several sports networks in a row. One
                // card per genre, on top of the brand-root rule below.
                var usedGenres = Set<HomeCategoryGroup>()
                for pick in popularPicks {
                    guard result.count < 6 else { break }
                    guard usedGenres.insert(groupOf(pick)).inserted else { continue }
                    guard accept(pick) else { continue }
                }
            }

            // Pick: one channel per slot (a genre with 3 slots contributes
            // its 3 best channels), live programming first, falling back to
            // any visible channel in the genre. Cap 6.
            for genre in slotGenres {
                guard let pool = byGenre[genre], !pool.isEmpty else { continue }
                // `accept` rejects a repeat brand, so keep walking the bucket
                // until a genuinely different channel takes the slot.
                if !pool.filter({ hasLiveProgram($0) }).contains(where: { accept($0) }) {
                    _ = pool.contains { accept($0) }
                }
                if result.count >= 6 { break }
            }

            // Pad to ≥5 with any other live channel (genre-agnostic) so the
            // carousel still has hero-card-worthy content even when the user's
            // top genres are sparse.
            if result.count < 5 {
                for ch in visible {
                    guard hasLiveProgram(ch) else { continue }
                    _ = accept(ch)
                    if result.count >= 5 { break }
                }
            }

            // The big home cards want the best-known channels the playlist
            // carries, capped — the same ranking, no second pass.
            let popular = Array(popularPicks.prefix(8))

            // ── Themed rows, built from the SAME single pass.
            // Each channel is filed under a theme by its category name (which
            // is how playlists are organised) or its own name, then the theme's
            // channels are ordered by the popularity rank already computed and
            // thinned to one per brand so a Sports row isn't four ESPNs.
            var themeBuckets: [String: [StreamChannel]] = [:]
            for ch in visible {
                let haystack = ((catLookup[ch.categoryID]?.name ?? "") + " " + ch.name).lowercased()
                for theme in ChannelViewModel.spotlightThemes
                where theme.keywords.contains(where: { haystack.contains($0) }) {
                    themeBuckets[theme.id, default: []].append(ch)
                    break
                }
            }

            var groups: [ChannelViewModel.SpotlightGroup] = []
            if !popular.isEmpty {
                groups.append(.init(id: "popular", title: "Popular Channels", channels: popular))
            }
            for theme in ChannelViewModel.spotlightThemes {
                guard let bucket = themeBuckets[theme.id], !bucket.isEmpty else { continue }
                let ordered = bucket.sorted { a, b in
                    let ra = rankOf[a.id] ?? Int.max
                    let rb = rankOf[b.id] ?? Int.max
                    if ra != rb { return ra < rb }
                    let la = hasLiveProgram(a), lb = hasLiveProgram(b)
                    if la != lb { return la }
                    return a.id < b.id
                }
                var picks: [StreamChannel] = []
                var roots = Set<String>()
                for ch in ordered {
                    guard picks.count < 8 else { break }
                    let cleaned = NameCleaner.clean(ch.name).lowercased()
                    let root = cleaned.split(separator: " ").first.map(String.init) ?? cleaned
                    guard roots.insert(root).inserted else { continue }
                    picks.append(ch)
                }
                guard picks.count >= 3 else { continue }
                groups.append(.init(id: theme.id, title: theme.title, channels: picks))
            }

            // ── The user's own choice wins outright.
            // Settings -> Content Management -> Hero Channels pins an explicit
            // list; when it's set, none of the ranking above applies to the
            // carousel. Live games still lead it — that's decided on the home
            // screen, not here — and the themed rows are unaffected.
            if !pinnedHero.isEmpty {
                let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
                let chosen = pinnedHero.compactMap { byID[$0] }
                if !chosen.isEmpty { return (chosen, popular, groups) }
            }

            // Last resort — surface favourites for users with no EPG at all.
            if result.isEmpty {
                return (Array(channels.filter { favoriteIDs.contains($0.id) }.prefix(5)), popular, groups)
            }
            return (result, popular, groups)
        }.value

        // Prefetch carousel icons before flipping isLoading off so the home
        // screen never appears with empty/loading hero cards. Bounded by a
        // 2-second wall clock so a single slow CDN icon can't hold the
        // loading screen forever — anything not back in time will just
        // pop in once it does, but the home view appears on schedule.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            group.addTask {
                await withTaskGroup(of: Void.self) { inner in
                    for channel in picked.channels {
                        guard let url = channel.icon, !url.isEmpty else { continue }
                        inner.addTask {
                            await ImageCache.prefetchAndWait(urlString: url)
                        }
                    }
                }
            }
            // Whichever finishes first wins — either all icons cached, or
            // the 2s timeout fires.
            await group.next()
            group.cancelAll()
        }

        // Also prefetch a few Continue Watching icons so the second shelf
        // is ready by the time the user scrolls past the carousel.
        let recentIcons = self.recentIDs.prefix(8).compactMap { id in
            channels.first(where: { $0.id == id })?.icon
        }
        Task.detached(priority: .background) {
            await withTaskGroup(of: Void.self) { group in
                for url in recentIcons where !url.isEmpty {
                    group.addTask { await ImageCache.prefetchAndWait(urlString: url) }
                }
            }
        }

        self.featuredChannels = picked.channels
        self.popularChannels = picked.popular
        self.spotlightGroups = picked.groups
    }


    /// The networks a brand-new user's hero carousel leads with, most-watched
    /// first. Ranked from Nielsen total-viewer standings — the four broadcast
    /// networks and Fox News/ESPN top every published table — then the biggest
    /// cable news, sports and entertainment channels.
    ///
    /// Order matters twice over: the first six that the playlist actually
    /// carries are the ones that get hero cards, and a network is consumed
    /// once, so the SPECIFIC names (Fox News, Fox Sports 1) deliberately come
    /// before the generic ones (FOX) — otherwise "Fox Sports 1" would be
    /// claimed by "FOX".
    nonisolated static let popularNetworks: [String] = [
        "ESPN", "CBS", "Fox News", "NBC", "CNN", "ABC",
        "Fox Sports 1", "FS1", "TNT", "USA Network", "FOX", "MSNBC",
        "TBS", "HGTV", "Discovery", "History", "Food Network", "TLC",
        "AMC", "A&E", "Bravo", "FX", "Paramount Network", "Comedy Central",
        "NFL Network", "NBA TV", "MLB Network", "Golf Channel", "CBS Sports Network",
        "National Geographic", "Syfy", "Lifetime", "Hallmark Channel",
        "Cartoon Network", "Nickelodeon", "Disney Channel", "CNBC",
        "Sky Sports Main Event", "TSN", "BBC One", "ITV1"
    ]

    /// Country codes playlists prefix names with. Used to keep the US-centric
    /// popular list from claiming another country's channel of the same name —
    /// "AU: ABC" is the Australian broadcaster, not the American one, and it is
    /// exactly what "ABC" was matching before this existed.
    nonisolated static let foreignPrefixes: [String] = [
        "au", "uk", "gb", "ca", "nz", "ie", "za", "in", "ph", "sg", "my",
        "de", "fr", "es", "it", "nl", "pt", "br", "mx", "ar", "pl", "ro",
        "tr", "gr", "se", "no", "dk", "fi", "ru", "ua", "ar", "ae", "sa"
    ]

    /// The country marker a playlist name carries, lowercased, or nil.
    /// Recognises "US: Foo", "US| Foo", "(US) Foo", "[US] Foo", "USA - Foo".
    nonisolated static func countryMarker(of name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        for sep in [":", "|", ")", "]", " -"] {
            guard let idx = trimmed.firstIndex(of: sep.last!) else { continue }
            let head = trimmed[trimmed.startIndex..<idx]
                .trimmingCharacters(in: CharacterSet(charactersIn: "([| -"))
            guard head.count >= 2, head.count <= 3,
                  head.allSatisfy({ $0.isLetter }) else { continue }
            return head
        }
        return nil
    }

    /// `popularNetworks` lowercased once, so matching never re-lowercases
    /// forty strings per channel.
    nonisolated static let popularNetworksLower: [String] = popularNetworks.map { $0.lowercased() }

    /// Word-boundary match against an ALREADY cleaned, lowercased name:
    /// "espn hd" matches "espn", "espn2" does not.
    nonisolated static func matches(cleaned: String, target: String) -> Bool {
        if cleaned == target { return true }
        return cleaned.hasPrefix(target + " ")
            || cleaned.hasSuffix(" " + target)
            || cleaned.contains(" " + target + " ")
    }

    /// How well-known a channel is: its index in `popularNetworks`, or nil if
    /// it isn't one of them. Lower is more popular.
    ///
    /// The name is cleaned ONCE here and then compared against every network.
    /// Doing it the other way round — asking "does this channel match network
    /// N?" forty times — re-ran the cleaner forty times per channel, which on
    /// a ten-thousand-channel playlist was minutes of work and hung the app on
    /// its loading screen.
    nonisolated static func popularityRank(of channelName: String) -> Int? {
        // A non-US country marker disqualifies the channel outright: "AU: ABC"
        // is the Australian broadcaster, not the American one.
        if let marker = countryMarker(of: channelName),
           marker != "us", marker != "usa",
           foreignPrefixes.contains(marker) {
            return nil
        }
        let cleaned = NameCleaner.clean(channelName).lowercased()
        for (idx, target) in popularNetworksLower.enumerated()
        where matches(cleaned: cleaned, target: target) { return idx }
        return nil
    }

    /// Networks that are popular enough to belong in the Popular Channels row
    /// and the themed rows, but that the user does not want the hero carousel
    /// opening on.
    nonisolated static let heroExcludedNetworks: Set<String> = ["fox news"]

    /// Whether a playlist channel IS the given US network. Convenience over
    /// `popularityRank` for the rare one-off check — never call this in a loop
    /// over the whole playlist.
    nonisolated static func channelMatches(_ channelName: String, network: String) -> Bool {
        if let marker = countryMarker(of: channelName),
           marker != "us", marker != "usa",
           foreignPrefixes.contains(marker) {
            return false
        }
        return matches(cleaned: NameCleaner.clean(channelName).lowercased(),
                       target: network.lowercased())
    }

    /// Maximum number of results returned per result bucket (EPG matches and
    /// channel-name matches). The UI never shows more than this and computing
    /// past the cap just heats the device — a phone with a 10k-channel
    /// playlist was previously scanning the entire list on every keystroke.
    private static let searchResultCap: Int = 80

    /// Minimum query length that triggers a full search. Single-character
    /// queries match thousands of channels and are almost never useful — we
    /// short-circuit them so typing the first letter doesn't kick off a
    /// 10k-channel scan that gets cancelled on the second letter anyway.
    private static let searchMinChars: Int = 2

    private func performSearch() {
        searchTask?.cancel()

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty query — clear everything and bail. (Don't show a spinner.)
        if query.isEmpty {
            self.filteredEPGChannels = []
            self.filteredNameChannels = []
            self.filteredCategories = []
            self.isSearching = false
            return
        }

        // Sub-threshold query — clear results but keep `isSearching` false so
        // the empty-results panel doesn't flash a skeleton. The user will hit
        // the threshold on the next keystroke and we'll run for real then.
        if query.count < Self.searchMinChars {
            self.filteredEPGChannels = []
            self.filteredNameChannels = []
            self.filteredCategories = []
            self.isSearching = false
            return
        }

        self.isSearching = true
        let searchQuery = query
        let resultCap = Self.searchResultCap

        searchTask = Task.detached(priority: .userInitiated) { [weak self, searchQuery, resultCap] in
            guard let self = self else { return }

            // Light debounce only — SearchView already debounces keystrokes
            // for 250 ms before handing the query over, so this just absorbs
            // programmatic double-sets.
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }

            let allChannels   = await self.channels
            let allCategories = await self.categories
            let hidden        = await self.hiddenIDs
            let epg           = await self.epgData
            let now           = await self.currentTime
            let manualOrder   = await self.manualChannelOrder
            let tokens        = searchQuery.lowercased()
                                    .components(separatedBy: " ")
                                    .filter { !$0.isEmpty }

            var orderMap: [Int: Int] = [:]
            for (index, id) in manualOrder.enumerated() { orderMap[id] = index }

            var epgMatches:  [StreamChannel] = []
            var nameMatches: [StreamChannel] = []
            var catMatches:  [StreamCategory] = []

            // Cap-aware scan — once both buckets are full we can stop scanning
            // entirely. Categories are tiny so we always finish those.
            for channel in allChannels {
                if hidden.contains(channel.id) { continue }

                let lowerName = channel.searchNormalizedName
                let nameMatch = tokens.allSatisfy { lowerName.contains($0) }

                // Skip the EPG dictionary lookup unless the channel has an
                // EPG id at all — saves a hash probe per channel for
                // playlists that don't ship guide data for every entry.
                var guideMatch = false
                if let eID = channel.epgID,
                   let schedule = epg[eID],
                   let program = schedule.first(where: { now >= $0.start && now <= $0.stop }) {
                    let lowerGuide = program.title.lowercased()
                    guideMatch = tokens.allSatisfy { lowerGuide.contains($0) }
                }

                if guideMatch {
                    if epgMatches.count < resultCap { epgMatches.append(channel) }
                } else if nameMatch {
                    if nameMatches.count < resultCap { nameMatches.append(channel) }
                }

                // Early exit — both buckets full, nothing more to find.
                if epgMatches.count >= resultCap && nameMatches.count >= resultCap {
                    break
                }
            }

            for cat in allCategories where !cat.isHidden {
                let lowerCat = cat.name.lowercased()
                if tokens.allSatisfy({ lowerCat.contains($0) }) {
                    catMatches.append(cat)
                }
            }

            let sortedEPG  = ChannelViewModel.prioritySort(epgMatches,  order: manualOrder, precomputedOrderMap: orderMap)
            let sortedName = ChannelViewModel.prioritySort(nameMatches, order: manualOrder, precomputedOrderMap: orderMap)

            guard !Task.isCancelled else { return }

            let finalCatMatches = catMatches
            await MainActor.run {
                self.filteredEPGChannels  = sortedEPG
                self.filteredNameChannels = sortedName
                self.filteredCategories   = finalCatMatches
                self.isSearching = false

                // Only persist queries the user clearly committed to — skip
                // the partial-typing noise that fired on every keystroke.
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

    
    // Not @Published: this is a private resolver cache read only inside this
    // view model (see runSmartSearch / preResolveGames). Publishing it made
    // every pre-resolved game emit objectWillChange, needlessly re-rendering
    // the whole channel UI while the Sports hub warmed matchups in the
    // background.
    var preResolvedCache: [String: StreamChannel] = [:]

    private struct GameSearchInfo: Sendable {
        let id: String
        let home: String
        let away: String
        let network: String?
    }

    func preResolveGames(_ games: [ESPNEvent]) {
        // Golf is EXCLUDED. The generic resolver scores a channel largely on
        // the broadcaster, and a tournament's broadcaster is a whole network —
        // "ESPN" matches "24/7 ESPN 30 for 30" for the full network bonus, and
        // that got cached as the answer for the BMW Championship. Since
        // runSmartSearch consults this cache first, a poisoned entry beat the
        // golf search every time. Golf resolves through runGolfSearch alone.
        let games = games.filter { !($0.isFieldEvent && !$0.isRaceEvent) }

        let infos: [GameSearchInfo] = games.map {
            let terms = $0.searchTerms
            return GameSearchInfo(id: $0.id, home: terms.home, away: terms.away, network: $0.streamNetworkHint)
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

    func resolveChannel(forGame game: ESPNEvent) -> StreamChannel? {
        if let cached = preResolvedCache[game.id] { return cached }
        // Same reasoning as preResolveGames: this scores on the broadcaster and
        // on team names a tournament does not have, so for golf it would cache
        // a network's channel as the answer.
        if game.isFieldEvent && !game.isRaceEvent { return nil }
        let targetNetwork = (game.broadcastName ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let home = (game.homeCompetitor?.team?.shortDisplayName ?? game.homeCompetitor?.team?.displayName ?? "").lowercased()
        let away = (game.awayCompetitor?.team?.shortDisplayName ?? game.awayCompetitor?.team?.displayName ?? "").lowercased()
        let hiddenCatIDs = Set(categories.filter { $0.isHidden }.map { $0.id })
        var bestScore = 0
        var bestChan: StreamChannel? = nil
        for channel in channels {
            if hiddenIDs.contains(channel.id) || hiddenCatIDs.contains(channel.categoryID) { continue }
            var score = 0
            if !targetNetwork.isEmpty && channel.name.localizedCaseInsensitiveContains(targetNetwork) { score += 1000 }
            if let epgID = channel.epgID, let schedule = epgData[epgID],
               let program = schedule.first(where: { currentTime >= $0.start && currentTime <= $0.stop }) {
                let title = program.title.lowercased()
                if !home.isEmpty && title.contains(home) { score += 500 }
                if !away.isEmpty && title.contains(away) { score += 500 }
            }
            if !home.isEmpty && channel.name.lowercased().contains(home) { score += 200 }
            if !away.isEmpty && channel.name.lowercased().contains(away) { score += 200 }
            score += channel.qualityScore
            if score > bestScore { bestScore = score; bestChan = channel }
        }
        guard bestScore >= 500, let winner = bestChan else { return nil }
        preResolvedCache[game.id] = winner
        return winner
    }

    func runSmartSearch(gameID: String? = nil, home: String, away: String, sport: SportType, network: String? = nil) {
        // Golf has its own search, and it goes FIRST — ahead of the resolved
        // cache, which the generic resolver may have filled with a channel
        // picked for carrying the right broadcaster rather than the right
        // event. One delegation here covers every caller in the app.
        if sport == .golf {
            runGolfSearch(tournament: home, gameID: gameID)
            return
        }

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
                
                
                
                // Weighted by how MANY of the query's words the guide entry
                // carries, not merely whether one did. A golf search is the
                // tournament's name plus the sport, and every golf channel
                // matches "golf" — so a flat bonus left the channel actually
                // showing the tournament level with one showing anything else.
                // The per-word bonus is what separates them.
                if titleH > 0 { score += 500 + 120 * min(titleH - 1, 3); isContMatch = true }
                if titleA > 0 { score += 500; isContMatch = true }
                
                
                if descH > 0 { score += 300 + 90 * min(descH - 1, 3); isContMatch = true }
                if descA > 0 { score += 300; isContMatch = true }
                
                
                if nameH > 0 { score += 200; isContMatch = true }
                if nameA > 0 { score += 200; isContMatch = true }
                
                
                let totalH = nameH + titleH + descH
                let totalA = nameA + titleA + descA
                if totalH > 0 && totalA > 0 { score += 300 }
                
                
                

                // EVERY word of the event's name found somewhere on this
                // channel — its name, its guide title, its description — is the
                // one signal that says "this is the thing", and it is what a
                // person does when they type the tournament into search and
                // pick the obvious hit. Without it a golf search topped out at
                // the generic +1000 network match plus a single +200 name hit,
                // which is under the confidence threshold, so it never played
                // anything by itself.
                let haystack = "\(channel.name) \(epgTitle) \(epgDesc)".lowercased()
                if !homeTokens.isEmpty, homeTokens.allSatisfy({ haystack.contains($0) }) {
                    score += 800
                    isContMatch = true
                }

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
    
    /// Finds the stream for a golf tournament, on its own terms.
    ///
    /// The general smart search is built around two named sides and scores a
    /// channel on how many of them it can find. Golf has no sides — it has one
    /// event, whose name lives in the GUIDE rather than in a channel called
    /// "Golf Channel" — so that search kept topping out on the generic sport
    /// match and never reached the confidence needed to play anything. This
    /// looks for the one thing that actually identifies the broadcast: the
    /// tournament's name, in the channel name, the programme title, or the
    /// programme description.
    ///
    /// Ranked strictly, best first:
    ///   1. the full name as a PHRASE in the programme title
    ///   2. every word of it in the title
    ///   3. the phrase in the description
    ///   4. every word of it in the description
    ///   5. the phrase, or every word, in the channel's own name
    ///   6. failing all of that, a channel that is simply about golf
    /// Anything in the first five is specific enough to play outright; a bare
    /// golf channel is offered as a choice instead of guessed at.
    func runGolfSearch(tournament: String, gameID: String? = nil) {
        let phrase = tournament.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = SmartSearchLogic.tokenize(tournament)
        guard !phrase.isEmpty || !words.isEmpty else { return }

        let inputChannels = self.channels
        let inputHidden = self.hiddenIDs
        let hiddenCatIDs = Set(self.categories.filter { $0.isHidden }.map { $0.id })
        let currentEPG = self.epgData
        let now = self.currentTime

        self.isSearchingGame = true
        self.suggestedChannels = []
        self.channelToAutoPlay = nil

        Task.detached(priority: .userInitiated) { [weak self, inputChannels, inputHidden, hiddenCatIDs, currentEPG, now] in
            guard let self else { return }

            func allWords(in text: String) -> Bool {
                guard !words.isEmpty else { return false }
                let lower = text.lowercased()
                return words.allSatisfy { lower.contains($0) }
            }
            func hasPhrase(in text: String) -> Bool {
                guard phrase.count > 3 else { return false }
                return text.lowercased().contains(phrase)
            }

            var ranked: [(channel: StreamChannel, rank: Int)] = []
            for channel in inputChannels {
                if inputHidden.contains(channel.id) || hiddenCatIDs.contains(channel.categoryID) { continue }
                if SmartSearchLogic.isBanner(channel.name) { continue }

                var title = ""
                var desc = ""
                if let eID = channel.epgID, let schedule = currentEPG[eID],
                   let programme = schedule.first(where: { now >= $0.start && now <= $0.stop }) {
                    title = programme.title
                    desc = programme.description ?? ""
                }

                let rank: Int
                if hasPhrase(in: title)            { rank = 6 }
                else if allWords(in: title)        { rank = 5 }
                else if hasPhrase(in: desc)        { rank = 4 }
                else if allWords(in: desc)         { rank = 3 }
                else if hasPhrase(in: channel.name) || allWords(in: channel.name) { rank = 2 }
                else if channel.name.localizedCaseInsensitiveContains("golf")
                            || title.localizedCaseInsensitiveContains("golf") { rank = 1 }
                else { continue }

                ranked.append((channel, rank))
            }

            // Best rank first, then the app's usual quality preference.
            let sorted = ranked.sorted {
                $0.rank != $1.rank ? $0.rank > $1.rank : $0.channel.qualityScore > $1.channel.qualityScore
            }

            await MainActor.run {
                self.isSearchingGame = false
                guard let best = sorted.first else {
                    self.showNoStreamsAlert = true
                    return
                }
                let picks = Array(sorted.prefix(15).map(\.channel))
                self.suggestedChannels = picks
                for channel in picks.prefix(3) { self.prewarmChannel(channel) }

                // ALWAYS plays the top of the ranking, including the bare
                // golf-channel tier. Holding that tier back for the picker was
                // the remaining reason golf did not play by itself: plenty of
                // providers carry a tournament on a channel whose guide entry
                // says nothing more specific than "PGA TOUR Golf", and there is
                // no better answer to offer than the best of those. The rest of
                // the ranking is still in `suggestedChannels`, so Stream List
                // shows the alternatives.
                withAnimation(.easeInOut(duration: 0.4)) { self.channelToAutoPlay = best.channel }
                if let gameID { self.preResolvedCache[gameID] = best.channel }
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
                
                // Weighted by how MANY of the query's words the guide entry
                // carries, not merely whether one did. A golf search is the
                // tournament's name plus the sport, and every golf channel
                // matches "golf" — so a flat bonus left the channel actually
                // showing the tournament level with one showing anything else.
                // The per-word bonus is what separates them.
                if titleH > 0 { score += 500 + 120 * min(titleH - 1, 3); isContMatch = true }
                if titleA > 0 { score += 500; isContMatch = true }
                if descH > 0 { score += 300 + 90 * min(descH - 1, 3); isContMatch = true }
                if descA > 0 { score += 300; isContMatch = true }
                if nameH > 0 { score += 200; isContMatch = true }
                if nameA > 0 { score += 200; isContMatch = true }
                
                let totalH = nameH + titleH + descH
                let totalA = nameA + titleA + descA
                if totalH > 0 && totalA > 0 { score += 300 }
                

                // Same exact-name signal as the smart search above: every word
                // of the event's name present on this channel is what marks it
                // as the one, rather than a generic sport match.
                let haystack = "\(channel.name) \(epgTitle) \(epgDesc)".lowercased()
                if !homeTokens.isEmpty, homeTokens.allSatisfy({ haystack.contains($0) }) {
                    score += 800
                    isContMatch = true
                }

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
        let isStale = lastEPGUpdateTime == nil || now.timeIntervalSince(lastEPGUpdateTime!) >= Self.epgMaxAge
        
        
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
        // Two fetches must never share one progress value, but the flag for
        // that CANNOT be `isUpdatingEPG`: callers set that themselves to raise
        // the banner before calling in, so keying off it made this refuse the
        // very work the banner was announcing. This one is owned here alone.
        if await MainActor.run(body: { self.epgFetchInFlight }) {
            print("⏳ [EPG] A fetch is already in flight — skipping this one.")
            return
        }
        let now = Date()
        let isStale = lastEPGUpdateTime == nil || now.timeIntervalSince(lastEPGUpdateTime!) >= Self.epgMaxAge
        
        let urlsChanged = Set(urls) != Set(lastFetchedEPGUrls)
        if urlsChanged { lastFetchedEPGUrls = urls }
        let shouldForce = force || urlsChanged
        
        if self.epgData.isEmpty {
             if let cached = EPGService().loadFromDisk(), !cached.epg.isEmpty {
                await MainActor.run {
                    self.epgData = cached.epg
                    self.epgNameMap = cached.map
                }
            }
        }
        
        
        if !shouldForce && !isStale && !self.epgData.isEmpty {
            print("✅ [EPG] Data is fresh. Skipping network fetch.")
            // The caller raises the banner before calling in, so lower it again
            // rather than leaving "Checking for updates..." on screen forever.
            await MainActor.run {
                if self.isUpdatingEPG {
                    self.isUpdatingEPG = false
                    self.stopSmoothingTimer()
                }
            }
            return
        }
        
        
        
        let effectivelySilent = silent || (!self.epgData.isEmpty && !shouldForce)
        
        await MainActor.run {
            self.epgFetchInFlight = true

            if !silent {
                self.isLoading = true
            }
            
            self.visualProgress = 0
            self.epgProgress = 0
            self.loadingStatus = "Updating Guide..."
            
            
            if !effectivelySilent {
                withAnimation(.spring()) { self.isUpdatingEPG = true }
                self.startSmoothingTimer()
            }
        }
        
        let result = await EPGService().fetchAndMergeEPGs(urls: urls) { progress in
            Task { @MainActor in
                self.epgProgress = progress
            }
        }
        
        await MainActor.run {
            self.epgFetchInFlight = false
            self.lastEPGUpdateTime = Date()
            self.epgProgress = 1.0
            self.visualProgress = 1.0
            self.epgState.progress = 1.0   // ensure banner shows 100%
            self.epgData = result.epg
            self.epgNameMap = result.map

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(.spring()) { self.isUpdatingEPG = false }
                self.stopSmoothingTimer()
                self.epgState.progress = 0
            }

            self.isLoading = false
        }
    }
    
    
    func updateEPGFromURL(_ url: URL, silent: Bool = false) async {
        await updateEPGFromURLs([url], force: false, silent: silent)
    }
    
    
    var displayEPGProgress: Double {
        return epgState.progress
    }

    func loadSettings() {
        func load<T: Decodable>(_ key: String, type: T.Type) -> T? {
            guard let data = UserDefaults.standard.data(forKey: settingsPrefix + key) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        self.customHeroIDs = load("customHeroIDs", type: [Int].self) ?? []
        self.renamedChannels = load("renamedChannels", type: [Int: String].self) ?? [:]
        self.renamedCategories = load("renamedCategories", type: [Int: String].self) ?? [:]
        self.categoryColors = load("categoryColors", type: [Int: String].self) ?? [:]
        self.excludedSportsIDs = Set(load("excludedSportsIDs", type: [Int].self) ?? [])
        self.favoriteIDs = Set(load("favoriteChannelIDs", type: [Int].self) ?? [])
        self.hiddenIDs = Set(load("hiddenChannelIDs", type: [Int].self) ?? [])
        
        let loadedRecents = load("recentChannelIDs", type: [Int].self) ?? []
        self.recentIDs = loadedRecents.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        self.manualChannelOrder = load("manualChannelOrder", type: [Int].self) ?? []
        // Empty is the shipping default — see `homeRowOrder`.
        self.homeRowOrder = load("homeRowOrder", type: [String].self) ?? []
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
        // Reordering or hiding a category changes neither the category COUNT
        // nor any name, so without this the home shelves kept their old order
        // until the next launch. Every caller of this is a deliberate save, so
        // it's the right place to tell the home screen to rebuild.
        categoryRevision += 1
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
        categoryRevision += 1
    }
    
    func toggleFavorite(_ id: Int) { if favoriteIDs.contains(id) { triggerHaptic(.light); favoriteIDs.remove(id) } else { triggerHaptic(.medium); favoriteIDs.insert(id) }; if let d = try? JSONEncoder().encode(Array(favoriteIDs)) { UserDefaults.standard.set(d, forKey: settingsPrefix + "favoriteChannelIDs") } }
    func hideChannel(_ id: Int) { hiddenIDs.insert(id); if let d = try? JSONEncoder().encode(Array(hiddenIDs)) { UserDefaults.standard.set(d, forKey: settingsPrefix + "hiddenChannelIDs") } }
    func unhideChannel(_ id: Int) { hiddenIDs.remove(id); if let d = try? JSONEncoder().encode(Array(hiddenIDs)) { UserDefaults.standard.set(d, forKey: settingsPrefix + "hiddenChannelIDs") } }
    func hideCategory(_ id: Int) { if let idx = categories.firstIndex(where: { $0.id == id }) { categories[idx].isHidden = true; saveCategorySettings() } }
    func categoryColor(for id: Int) -> Color? { guard let hex = categoryColors[id] else { return nil }; return Color(hex: hex) }
    func setCategoryColor(id: Int, hex: String?) { if let hex { categoryColors[id] = hex } else { categoryColors.removeValue(forKey: id) }; if let d = try? JSONEncoder().encode(categoryColors) { UserDefaults.standard.set(d, forKey: settingsPrefix + "categoryColors") } }
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
        // Renames are written by renameCategory under the GLOBAL key (its
        // settingsPrefix is empty), keyed by the displayed category id
        // (originalID + idOffset). Reading them here under the account-prefixed
        // key is why renames never survived a reload — the two keys never
        // matched. Read the same global key the write uses.
        var mutable = loadedCats; let data = UserDefaults.standard.data(forKey: "renamedCategories") ?? Data()
        let renames = (try? JSONDecoder().decode([Int: String].self, from: data)) ?? [:]
        
        
        struct Wrapper: Codable { let id: Int; var name: String; var isHidden: Bool; var order: Int }
        // The key had a stray "anda" on it while saveCategorySettings writes
        // plain "savedCategories" — so the saved order, hidden flags and names
        // were written every time and read back never. That is why reordering
        // categories in Settings appeared to do nothing: the list fell through
        // to the bottom path below, which re-derives order from raw playlist
        // position on every load.
        if let savedData = UserDefaults.standard.data(forKey: prefix + "savedCategories"),
           let saved = try? JSONDecoder().decode([Wrapper].self, from: savedData) {
            
            
            let savedMap = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
            
            for i in 0..<mutable.count {
                let originalID = mutable[i].id
                
                mutable[i] = StreamCategory(id: originalID + idOffset, name: mutable[i].name)
                
                // Saved under the DISPLAYED id (raw + idOffset), which is what
                // saveCategorySettings writes, so look it up the same way.
                if let s = savedMap[originalID + idOffset] {
                    var c = mutable[i]
                    c.isHidden = s.isHidden
                    c.order = s.order
                    
                    if let custom = renames[originalID + idOffset] { c.name = custom }
                    else { c.name = s.name } 
                    mutable[i] = c
                } else {
                    if let custom = renames[originalID + idOffset] { mutable[i].name = custom }
                    mutable[i].order = 9999 + i
                }
            }
            
             return mutable.sorted { $0.order < $1.order }
        }
        
        for i in 0..<mutable.count { 
            let originalID = mutable[i].id
            
            mutable[i] = StreamCategory(id: originalID + idOffset, name: mutable[i].name)
            // Renames are stored under the DISPLAYED id (raw + idOffset) — the
            // same id renameCategory is handed. Looking them up under the raw
            // id here meant a rename made before the first saveCategorySettings
            // was dropped on the next launch.
            if let custom = renames[originalID + idOffset] { mutable[i].name = custom }
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
        self.epgState.progress = 0
        // 10 fps is imperceptibly smooth for a progress ring and avoids
        // flooding ChannelViewModel.objectWillChange (which would force
        // re-renders of every channel list, category grid, etc.).
        smoothingTimer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, self.isUpdatingEPG else { return }
                let diff = self.epgProgress - self.visualProgress
                if abs(diff) > 0.001 {
                    self.visualProgress += diff * 0.25   // faster catch-up at 10 fps
                } else {
                    self.visualProgress = self.epgProgress
                }
                // Write only to the isolated state object — never to self.
                self.epgState.progress = self.visualProgress
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

    func orderedFavoriteChannels() -> [StreamChannel] {
        let favOrder = UserDefaults.standard.array(forKey: settingsPrefix + "favoriteChannelOrder") as? [Int] ?? []
        let favSet = favoriteIDs
        var orderMap: [Int: Int] = [:]
        for (i, id) in favOrder.enumerated() { orderMap[id] = i }

        return channels
            .filter { favSet.contains($0.id) }
            .sorted { a, b in
                let ia = orderMap[a.id]
                let ib = orderMap[b.id]
                if let ia = ia, let ib = ib { return ia < ib }
                if ia != nil { return true }
                if ib != nil { return false }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    func moveFavoriteChannels(from source: IndexSet, to destination: Int) {
        var ordered = orderedFavoriteChannels()
        ordered.move(fromOffsets: source, toOffset: destination)
        let newOrder = ordered.map { $0.id }
        UserDefaults.standard.set(newOrder, forKey: settingsPrefix + "favoriteChannelOrder")
        objectWillChange.send()
    }

    func scheduledRecording(for game: ESPNEvent) -> Recording? {
        let key = game.shortName.lowercased()
        return RecordingManager.shared.recordings.first { rec in
            rec.status == .scheduled &&
            ((rec.programTitle?.lowercased() == key) || (rec.customTitle?.lowercased() == key))
        }
    }

    func toggleGameRecording(game: ESPNEvent, sport: SportType) {
        if let existing = scheduledRecording(for: game) {
            triggerHaptic(.light)
            RecordingManager.shared.deleteRecording(existing)
            return
        }

        let home = game.homeCompetitor?.team?.shortDisplayName ?? game.homeCompetitor?.athlete?.shortName ?? ""
        let away = game.awayCompetitor?.team?.shortDisplayName ?? game.awayCompetitor?.athlete?.shortName ?? ""
        let hiddenCatIDs = Set(categories.filter { $0.isHidden }.map { $0.id })

        guard let channel = ChannelViewModel.resolveBestMatch(
            home: home, away: away, network: game.streamNetworkHint,
            channels: channels, hiddenIDs: hiddenIDs,
            hiddenCatIDs: hiddenCatIDs,
            epg: epgData, now: currentTime,
            preferredLanguage: preferredLanguage, preferredQuality: preferredQuality
        ) else {
            triggerNotificationHaptic(.error)
            showNoStreamsAlert = true
            return
        }

        let startTime = game.gameDate
        let endTime = startTime.addingTimeInterval(3 * 3600)

        // Full team names ("Los Angeles Lakers at Boston Celtics") for the
        // recording title, rather than the three-letter shortName.
        let fullAway = game.awayCompetitor?.team?.displayName ?? game.awayCompetitor?.athlete?.displayName
        let fullHome = game.homeCompetitor?.team?.displayName ?? game.homeCompetitor?.athlete?.displayName
        let title: String = {
            if let fullAway, let fullHome, !fullAway.isEmpty, !fullHome.isEmpty {
                return "\(fullAway) at \(fullHome)"
            }
            return game.shortName
        }()

        // A recording got armed — the one state change here that deserves
        // the full "success" tap.
        triggerNotificationHaptic(.success)
        RecordingManager.shared.scheduleRecording(
            channel: channel,
            startTime: startTime,
            endTime: endTime,
            programTitle: title,
            category: .sports
        )
    }
}
