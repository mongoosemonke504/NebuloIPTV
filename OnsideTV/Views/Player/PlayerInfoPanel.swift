import SwiftUI

// MARK: - Tab definition
private enum InfoTab: Int, CaseIterable {
    case channels = 0, schedule, recordings

    var title: String {
        switch self {
        case .channels:   return "Channels"
        case .schedule:   return "Schedule"
        case .recordings: return "Recordings"
        }
    }
    var icon: String {
        switch self {
        case .channels:   return "list.bullet"
        case .schedule:   return "calendar"
        case .recordings: return "record.circle"
        }
    }
}

// MARK: - Main panel
struct PlayerInfoPanel: View {
    let channel: StreamChannel
    var onPlayChannel: ((StreamChannel) -> Void)? = nil
    /// Tapping a finished recording routes UP to the presenter (MainView) so it
    /// can dismiss this live player and present the recording over the home
    /// screen — otherwise a nested cover leaves the old player underneath and
    /// minimising the recording drops back onto it, not home.
    var onPlayRecording: ((Recording) -> Void)? = nil
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var playerManager: NebuloPlayerEngine
    @ObservedObject var recordingManager = RecordingManager.shared

    /// When true (recording playback), hides the record button in the header
    /// and removes the bell record buttons from the schedule rows.
    var isRecordingPlayback: Bool = false
    /// The recording being played, in recording playback. `channel` is then
    /// the real live channel — that is what the schedule and the related
    /// channels are for — but the HEADER is about the recording: its own
    /// title, its own description, the time it was made. Reading the live
    /// guide for it showed whatever happened to be on the channel right now.
    var recording: Recording? = nil

    @Binding var showSubtitlePanel: Bool
    @Binding var showAudioPanel: Bool

    @AppStorage("accentColor") private var accentHex = "#FFFFFF"
    private var accentColor: Color { Color(hex: accentHex) ?? .blue }

    @State private var selectedTab: InfoTab = .channels
    @State private var showFullDescription = false
    @State private var showRecordingSheet = false

    /// 0 at rest, 1 once the active tab's list has been scrolled. Tracked
    /// 1:1 with the scroll offset (same mechanism as the section headers):
    /// the big program header + description + action pills compress into a
    /// one-line "what's playing" row so more of the channel list is visible.

    /// Natural (uncollapsed) height of the full header, measured at runtime
    /// since the description block varies per program. Drives the reserve
    /// interpolation; nil-height (not yet measured) renders naturally.
    @State private var headerFullHeight: CGFloat = 0

    /// Height of the compact one-line header the full block collapses into.
    private let headerCompactHeight: CGFloat = 44

    /// Measured height of the pinned category picker, which only the Channels
    /// tab shows.
    @State private var pickerHeight: CGFloat = 0

    /// How much space a page must leave clear at its top.
    ///
    /// `headerBlockHeight` covers whatever the chrome is showing right now,
    /// and the picker is part of it only while Channels is selected — so that
    /// is taken off to get the shared base, and added back for the one page
    /// that sits under it. Without this the Schedule and Recordings pages
    /// would reserve room for a picker they never show.
    private func reserve(for tab: InfoTab) -> CGFloat {
        let base = headerBlockHeight - (selectedTab == .channels ? pickerHeight : 0)
        return max(0, base) + (tab == .channels ? pickerHeight : 0)
    }

    /// Last known scroll depth of each tab. A reference box rather than
    /// `@State`, because it is written on every scroll frame.
    fileprivate final class TabScrollDepths { var values: [InfoTab: CGFloat] = [:] }
    @State fileprivate var tabDepths = TabScrollDepths()

    /// Live scroll depth of the ACTIVE tab, driving the header slide. A LEAF,
    /// so a scroll frame moves the header and re-renders nothing else — the
    /// same arrangement the Sports and Favorites hubs use.
    @State private var panelScroll = ScrollProgress()

    /// Height of the whole floating header block (full header + tab bar).
    /// Each page reserves exactly this at its top, and it does NOT change as
    /// the header collapses — the header SLIDES, it does not resize.
    ///
    /// That constant is the entire reason the tabs can be a real pager now.
    /// The old design shrank the header and inserted a matching spacer INSIDE
    /// each tab's scroll to stop the rows outrunning the finger; with a paged
    /// TabView the spacer lives inside a UIPageViewController page and
    /// committed a frame after the header's height changed outside it, which
    /// was the one-pixel oscillation during slow scrolls. Nothing resizes any
    /// more, so there is nothing to keep in step and nothing to lag.
    @State private var headerBlockHeight: CGFloat = 0

    /// How far the header travels before the compact line and tab bar reach
    /// the top and stop.
    ///
    /// Enormous until the header has actually been measured, NOT zero. Every
    /// leaf that reads this divides by it, and a zero travel reads as "fully
    /// collapsed" the instant anything scrolls: the full block would fade out
    /// while still occupying its whole height, and the compact line would take
    /// over — a one-line header under a tall band of nothing. A huge value
    /// makes the same division come out at zero progress, so the header simply
    /// stays open until there is a real height to work with.
    private var headerTravel: CGFloat {
        guard headerFullHeight > headerCompactHeight else { return .greatestFiniteMagnitude }
        return headerFullHeight - headerCompactHeight
    }

    /// Converts the scrolled distance into collapse progress. Fed by
    /// `onScrollGeometryChange`, which reports the offset SYNCHRONOUSLY with
    /// every scroll frame (120Hz on ProMotion). The old GeometryReader →
    /// preference pipeline delivered readings a frame late through the
    /// preference system, capping the collapse's effective frame rate below
    /// the rest of the app's. The offset is in the scroll view's own content
    /// coordinates, so it's immune to the frame moving as the header shrinks.
    /// Hands the active tab's scroll depth to the header.
    ///
    /// Replaces the old `panelCollapse` mapping. Nothing resizes any more —
    /// the header slides at constant height — so there is no distance to
    /// interpolate, no latch to carry across a tab switch and no window to
    /// freeze while one is in flight. The neighbours in the pager report too,
    /// hence the guard.
    private func updateCollapse(scrolled: CGFloat, from tab: InfoTab) {
        let depth = max(0, scrolled)
        // Remembered for EVERY tab, not just the active one. Each page keeps
        // its own scroll position, so arriving at one leaves the header
        // holding the depth of the page you left — collapsed over a list
        // sitting at its top, which is the band of black between the picker
        // and the content. A plain box, not `@State`: this is written on every
        // scroll frame and must not re-render the panel.
        tabDepths.values[tab] = depth
        guard tab == selectedTab else { return }
        panelScroll.set(depth)
    }

    /// Hands the header the depth of whichever tab is now in front.
    private func syncHeaderToSelectedTab() {
        panelScroll.set(tabDepths.values[selectedTab] ?? 0)
    }

    /// Which category is currently being browsed in the Channels tab.
    /// `nil` means "default" (Favorites + same category as current channel).
    /// Use special sentinel ids for built-in groups: -4 favorites.
    @State private var browsingCategoryID: Int? = nil

    /// Cached result of the `browsingChannels` filter. The filter scans the
    /// whole channel list, so recomputing it on every header-collapse frame
    /// (the body re-runs each frame as the collapse ticks) was a large part
    /// of the channel-list scroll jitter. Refreshed only when its inputs
    /// actually change via `.task(id: browsingCacheKey)`.
    @State private var cachedBrowsingChannels: [StreamChannel] = []

    /// Bumps only when something that changes `browsingChannels` changes —
    /// the browsed category, the current channel, or the channel/favorite/
    /// hidden set sizes. Header-collapse ticks don't touch it, so the filter
    /// doesn't re-run mid-scroll.
    private var browsingCacheKey: String {
        "\(browsingCategoryID ?? -999)|\(channel.id)|\(channel.categoryID)|\(viewModel.channels.count)|\(viewModel.favoriteIDs.count)|\(viewModel.hiddenIDs.count)"
    }

    /// Which side the incoming tab content enters from — `true` when moving
    /// to a tab further right. Set BEFORE the animated change.

    /// Gates tab changes while a slide is in flight — interrupting a `.move`
    /// transition can strand the incoming view offscreen (blank panel).

    /// Per-tab scroll positions, so a tab swipe can carry the collapsed header
    /// across to the incoming tab by scrolling it to the matching offset.
    @State private var channelsScroll = ScrollPosition()
    @State private var scheduleScroll = ScrollPosition()
    @State private var recordingsScroll = ScrollPosition()

    /// While `Date() < this`, scroll-driven collapse updates are ignored. Set
    /// briefly during a collapse-preserving tab swipe so the incoming tab's
    /// initial `offset 0` layout callback can't flash the header back open
    /// before we've scrolled it to the collapsed offset.


    /// True when a collapsed header was carried across a tab switch. In this
    /// mode the header is latched compact WITHOUT a compensation spacer or
    /// offset gymnastics (the old approach scrolled the incoming list to a
    /// matching offset, and whenever that couldn't land — short schedule
    /// content, view not attached yet — the spacer showed as a dead blank
    /// band). The latch releases when the user pulls decisively past the top
    /// of the list, which re-opens the full header.

    /// Central tab switch, used by the tab bar. The pager animates the page
    /// move itself, so this is only a selection change — no slide direction to
    /// derive, no in-flight guard, and no collapse to latch across the switch:
    /// the header's position is the active page's scroll depth, so it simply
    /// follows whichever page you land on.
    private func selectTab(_ newTab: InfoTab) {
        guard newTab != selectedTab else { return }
        withAnimation(.easeInOut(duration: 0.25)) { selectedTab = newTab }
    }

    private var currentProgram: EPGProgram? { viewModel.getCurrentProgram(for: channel) }

    /// What the header names: the recording, or else what is on air.
    private var headerTitle: String {
        if let recording { return recording.displayName }
        return currentProgram?.title ?? channel.name
    }

    private var headerDescription: String? {
        let desc = recording != nil ? recording?.programDescription : currentProgram?.description
        guard let desc, !desc.isEmpty else { return nil }
        return desc
    }

    private var todaySchedule: [EPGProgram] {
        guard let id = channel.epgID, let schedule = viewModel.epgData[id] else { return [] }
        let cal = Calendar.current
        return schedule
            .filter { cal.isDateInToday($0.start) || cal.isDateInToday($0.stop) }
            .sorted { $0.start < $1.start }
    }

    /// Channels for the currently-selected browsing category.
    private var browsingChannels: [StreamChannel] {
        let visible = viewModel.channels.filter { !viewModel.hiddenIDs.contains($0.id) }
        switch browsingCategoryID {
        case .none:
            // Default: Favorites + same category as current channel
            let favs = visible.filter { viewModel.favoriteIDs.contains($0.id) && $0.id != channel.id }
            let cat  = visible.filter {
                $0.categoryID == channel.categoryID && $0.id != channel.id && !viewModel.favoriteIDs.contains($0.id)
            }
            return Array((favs + cat).prefix(40))
        case .some(-4):
            return visible.filter { viewModel.favoriteIDs.contains($0.id) && $0.id != channel.id }
        case .some(let cid):
            return visible.filter { $0.categoryID == cid && $0.id != channel.id }
        }
    }

    /// Title shown above the channel list, reflecting current browsing selection.
    private var browsingTitle: String {
        switch browsingCategoryID {
        case .none:
            return viewModel.categories.first(where: { $0.id == channel.categoryID })?.name ?? "Related Channels"
        case .some(-4): return "Favorites"
        case .some(let cid):
            return viewModel.categories.first(where: { $0.id == cid })?.name ?? "Channels"
        }
    }

    private var isCurrentlyRecording: Bool { recordingManager.isRecording(channelName: channel.name) }
    private var isFavorited: Bool { viewModel.favoriteIDs.contains(channel.id) }

    /// The header, floating over the pages: the full programme block, the
    /// compact line that replaces it, and the tab bar.
    ///
    /// It SLIDES up with the scroll at a constant height rather than shrinking.
    /// That is the change that lets the tabs below be a real pager — see
    /// `headerBlockHeight` — and it is the same arrangement the Sports and
    /// Favorites hubs use.
    private var headerChrome: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    programHeader
                    if let desc = headerDescription {
                        descriptionView(desc: desc)
                    }
                    actionPills
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
                // Fades over its own travel, so it is gone exactly as the
                // compact line reaches the top.
                .modifier(HeaderFade(offset: panelScroll, over: headerTravel))
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { headerFullHeight = g.size.height }
                            .onChangeCompat(of: g.size.height) { headerFullHeight = $0 }
                    }
                )
            }
            .frame(height: headerFullHeight > 0 ? headerFullHeight : nil, alignment: .top)

            // ── Tab bar ──
            tabBar
                .padding(.horizontal, 18)
                .padding(.bottom, 6)

            Divider()
                .background(Color.white.opacity(0.1))

            // Pinned, like the tab bar above it — it belongs to the chrome,
            // not to the list. Inside the scroll it travelled away with the
            // channels, which is not what a filter for those channels should
            // do.
            if selectedTab == .channels {
                categoryPicker
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .onAppear { pickerHeight = g.size.height }
                                .onChangeCompat(of: g.size.height) { pickerHeight = $0 }
                        }
                    )
            }
        }
        .background(Color.black)
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { headerBlockHeight = g.size.height }
                    .onChangeCompat(of: g.size.height) { headerBlockHeight = $0 }
            }
        )
        .modifier(HeaderSlide(offset: panelScroll, limit: headerTravel))
    }

    /// The one-line "what's playing" row that replaces the full block.
    ///
    /// A SIBLING of the header rather than an overlay on it: the header is
    /// what slides, and anything hung off it inherits that movement in ways
    /// that are hard to reason about. Pinned to the panel's top on its own, it
    /// is simply there, revealed over the last stretch of the header's travel.
    private var compactHeaderLayer: some View {
        compactHeader
            .modifier(CompactHeaderReveal(offset: panelScroll, over: headerTravel))
            .allowsHitTesting(false)
    }

    /// One tab as its own page. Siblings in a real pager, so the tab you are
    /// swiping towards is genuinely on screen and tracking your finger — the
    /// same treatment the hubs and search got.
    @ViewBuilder
    private func tabPage(for tab: InfoTab) -> some View {
        switch tab {
        case .channels:   channelsTab
        case .schedule:   scheduleTab
        case .recordings: recordingsTab
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selectedTab) {
                ForEach(InfoTab.allCases, id: \.self) { tab in
                    tabPage(for: tab)
                        .tag(tab)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            headerChrome
            compactHeaderLayer
        }
        // The header slides UP out of the panel, and what is directly above
        // the panel is the video. Unclipped, its black background rode over
        // the picture as you scrolled. The old shrinking header clipped as a
        // side effect of resizing its own window; a sliding one has to say so.
        .clipped()
        // A swipe changes this without going through `selectTab`, so the
        // re-sync hangs off the value itself rather than the tap path.
        .onChangeCompat(of: selectedTab) { _ in syncHeaderToSelectedTab() }
        .background(Color.black)
        .sheet(isPresented: $showRecordingSheet) {
            RecordingSetupSheet(channel: channel) {
                showRecordingSheet = false
            }
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(InfoTab.allCases, id: \.rawValue) { tab in
                Button(action: {
                    // selectTab derives the slide direction from tab order
                    // so tapping slides the same way a swipe does.
                    selectTab(tab)
                }) {
                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.caption.weight(.semibold))
                            Text(tab.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(selectedTab == tab ? .white : Color.white.opacity(0.45))
                        .padding(.vertical, 8)

                        Capsule()
                            .fill(selectedTab == tab ? accentColor : Color.clear)
                            .frame(height: 2.5)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Channels tab

    private var channelsTab: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: reserve(for: .channels))
                    let chans = cachedBrowsingChannels
                    if chans.isEmpty {
                        emptyState(icon: "tv.slash", message: "No channels in this category")
                    } else if browsingCategoryID == nil {
                        // Default view: split into Favorites + category
                        let favs   = chans.filter { viewModel.favoriteIDs.contains($0.id) }
                        let others = chans.filter { !viewModel.favoriteIDs.contains($0.id) }
                        VStack(spacing: 0) {
                            if !favs.isEmpty {
                                sectionHeader("Favorites")
                                ForEach(favs) { ch in
                                    PanelChannelRow(channel: ch, viewModel: viewModel) { onPlayChannel?(ch) }
                                        .equatable()
                                }
                            }
                            if !others.isEmpty {
                                sectionHeader(browsingTitle)
                                ForEach(others) { ch in
                                    PanelChannelRow(channel: ch, viewModel: viewModel) { onPlayChannel?(ch) }
                                        .equatable()
                                }
                            }
                        }
                        .padding(.top, 4)
                        Spacer(minLength: 32)
                    } else {
                        // Single category view
                        VStack(spacing: 0) {
                            sectionHeader("\(browsingTitle) · \(chans.count)")
                            ForEach(chans) { ch in
                                PanelChannelRow(channel: ch, viewModel: viewModel) { onPlayChannel?(ch) }
                                        .equatable()
                            }
                        }
                        .padding(.top, 4)
                        Spacer(minLength: 32)
                    }
                }
            }
            .scrollPosition($channelsScroll)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, scrolled in
                updateCollapse(scrolled: scrolled, from: .channels)
            }
        }
        .onAppear {
            if cachedBrowsingChannels.isEmpty { cachedBrowsingChannels = browsingChannels }
        }
        .task(id: browsingCacheKey) {
            cachedBrowsingChannels = browsingChannels
        }
    }

    /// Horizontal pill picker for choosing which category's channels to browse.
    /// First pill is "Related" (default smart mix). Then Favorites, All, then real categories.
    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryPill(title: "Related", icon: "sparkles", id: nil)
                categoryPill(title: "Favorites", icon: "star.fill", id: -4)
                ForEach(viewModel.categories.filter { $0.id >= 0 }, id: \.id) { cat in
                    categoryPill(title: cat.name, icon: nil, id: cat.id)
                }
            }
            .padding(.horizontal, 18)
        }
        // Scrubbing this chip row must never flip tabs — mark the shared
        // signal while it scrolls and let the tab-swipe gesture stand down.
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, _ in
            HorizontalScrollActivity.touch()
        }
    }

    @ViewBuilder
    private func categoryPill(title: String, icon: String?, id: Int?) -> some View {
        let isSelected = browsingCategoryID == id
        Button(action: {
            ChannelViewModel.shared.triggerSelectionHaptic()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                browsingCategoryID = id
            }
        }) {
            HStack(spacing: 5) {
                if let icon = icon {
                    Image(systemName: icon).font(.caption2.weight(.bold))
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? contrastingText(on: accentColor) : Color.white.opacity(0.65))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected ? accentColor : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.clear : Color.white.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    /// Pick a text colour that's readable against the supplied background.
    /// Uses standard relative-luminance — black on light backgrounds (e.g. a
    /// white accent), white on dark ones. Keeps the chip readable regardless
    /// of which accent colour the user picked.
    private func contrastingText(on background: Color) -> Color {
        let ui = UIColor(background)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        return lum > 0.6 ? .black : .white
    }

    // MARK: - Schedule tab

    private var scheduleTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
            Color.clear.frame(height: reserve(for: .schedule))
            if todaySchedule.isEmpty {
                emptyState(icon: "calendar.badge.exclamationmark", message: "No schedule available for today")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(todaySchedule.enumerated()), id: \.element.id) { idx, prog in
                        let alreadyScheduled = recordingManager.recordings.contains {
                            $0.channelName == channel.name
                                && abs($0.startTime.timeIntervalSince(prog.start)) < 60
                                && ($0.status == .scheduled || $0.status == .recording)
                        }
                        ScheduleRow(
                            program: prog,
                            isNow: isCurrentlyAiring(prog),
                            isScheduled: alreadyScheduled,
                            // No record bell during recording playback
                            onRecord: isRecordingPlayback ? nil : {
                                guard !alreadyScheduled else { return }
                                ChannelViewModel.shared.triggerNotificationHaptic(.success)
                                let streamCategory = ChannelViewModel.shared.categories.first { $0.id == channel.categoryID }
                                recordingManager.scheduleRecording(
                                    channel: channel,
                                    startTime: max(prog.start, Date()),
                                    endTime: prog.stop,
                                    programTitle: prog.title,
                                    programDescription: prog.description,
                                    category: .guess(channel: channel, category: streamCategory, program: prog)
                                )
                            }
                        )
                        if idx < todaySchedule.count - 1 {
                            Divider().background(Color.white.opacity(0.07)).padding(.leading, 18)
                        }
                    }
                }
                .padding(.top, 4)
                Spacer(minLength: 32)
            }
            }
        }
        .scrollPosition($scheduleScroll)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, scrolled in
            updateCollapse(scrolled: scrolled, from: .schedule)
        }
    }

    // MARK: - Recordings tab

    private var recordingsTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
            Color.clear.frame(height: reserve(for: .recordings))
            let sorted = recordingManager.recordings.sorted { $0.createdAt > $1.createdAt }
            if sorted.isEmpty {
                emptyState(icon: "record.circle", message: "No recordings yet")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, rec in
                        RecordingRow(recording: rec, recordingManager: recordingManager,
                                     onPlay: { onPlayRecording?(rec) },
                                     // A recording in progress: the row opens
                                     // the channel it is recording, live.
                                     onWatchLive: viewModel.liveChannel(for: rec).map { channel in
                                         { onPlayChannel?(channel) }
                                     })
                        if idx < sorted.count - 1 {
                            Divider().background(Color.white.opacity(0.07)).padding(.leading, 18)
                        }
                    }
                }
                .padding(.top, 4)
                Spacer(minLength: 32)
            }
            }
        }
        .scrollPosition($recordingsScroll)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, scrolled in
            updateCollapse(scrolled: scrolled, from: .recordings)
        }
    }

    private func isCurrentlyAiring(_ prog: EPGProgram) -> Bool {
        let now = Date()
        return prog.start <= now && prog.stop > now
    }

    // MARK: - Shared helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.white.opacity(0.4))
            .kerning(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.2))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    // MARK: - Header

    /// One-line header shown while the list is scrolled — just the relevant
    /// info: small logo, program title, channel · time.
    private var compactHeader: some View {
        HStack(spacing: 10) {
            ChannelLogoBox(urlString: channel.icon ?? "",
                           boxSize: 30,
                           cornerRadius: 8,
                           padding: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: headerCompactHeight)
    }

    private var programHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            ChannelLogoBox(urlString: channel.icon ?? "",
                           boxSize: 60,
                           cornerRadius: 12,
                           padding: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isRecordingPlayback { recordButton }
        }
    }

    private var headerSubtitle: String {
        if let recording {
            // The channel it came from and when — the live guide's times
            // would describe a different programme.
            let day = DateFormatter(); day.dateStyle = .medium; day.timeStyle = .none
            let clock = DateFormatter(); clock.timeStyle = .short
            let end = recording.startTime.addingTimeInterval(recording.duration)
            return "\(recording.channelName) · \(day.string(from: recording.startTime)) · \(clock.string(from: recording.startTime))–\(clock.string(from: end))"
        }
        if let prog = currentProgram {
            let f = DateFormatter(); f.timeStyle = .short
            return "\(channel.name) · \(f.string(from: prog.start))–\(f.string(from: prog.stop))"
        }
        return channel.name
    }

    private var recordButton: some View {
        Button(action: tapRecordCurrent) {
            HStack(spacing: 4) {
                Image(systemName: isCurrentlyRecording ? "record.circle.fill" : "plus")
                    .font(.caption.weight(.bold))
                Text(isCurrentlyRecording ? "Stop" : "Record")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(GlassEffect(cornerRadius: 18, isSelected: true, accentColor: isCurrentlyRecording ? .red : nil))
        }
        .buttonStyle(.plain)
    }

    private func tapRecordCurrent() {
        ChannelViewModel.shared.triggerSelectionHaptic()
        if isCurrentlyRecording {
            // Stop the active recording immediately.
            if let rec = recordingManager.recordings.first(where: { $0.channelName == channel.name && $0.status == .recording }) {
                recordingManager.stopRecording(rec.id)
            }
        } else {
            // Open the full RecordingSetupSheet so the user can pick a programme
            // or set a custom time (same sheet as the player controls bottom bar).
            showRecordingSheet = true
        }
    }

    // MARK: - Description

    @ViewBuilder
    private func descriptionView(desc: String) -> some View {
        Text(desc)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(showFullDescription ? nil : 3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                ChannelViewModel.shared.triggerSelectionHaptic()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showFullDescription.toggle() }
            }
    }

    // MARK: - Action pills

    private var actionPills: some View {
        HStack(spacing: 10) {
            pill(icon: "speaker.wave.2.fill", label: audioPillLabel,
                 isEnabled: !playerManager.availableAudioTracks.isEmpty) {
                ChannelViewModel.shared.triggerSelectionHaptic()
                withAnimation { showAudioPanel.toggle() }
            }
            pill(icon: "captions.bubble.fill", label: subtitlePillLabel,
                 isEnabled: playerManager.hasSelectableSubtitles) {
                ChannelViewModel.shared.triggerSelectionHaptic()
                withAnimation { showSubtitlePanel.toggle() }
            }
            pill(icon: isFavorited ? "star.fill" : "star", label: "Favorite",
                 isEnabled: true, tinted: isFavorited) {
                viewModel.toggleFavorite(channel.id)
            }
        }
    }

    private var audioPillLabel: String {
        if playerManager.availableAudioTracks.isEmpty { return "Audio" }
        if let cur = playerManager.currentAudioTrack { return "Audio: \(cur.name)" }
        return "Audio"
    }
    private var subtitlePillLabel: String {
        if !playerManager.hasSelectableSubtitles { return "Subtitles" }
        return playerManager.currentSubtitle?.name ?? "Subtitles"
    }

    @ViewBuilder
    private func pill(icon: String, label: String, isEnabled: Bool, tinted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption.weight(.bold))
                Text(label).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(isEnabled ? .white : Color.white.opacity(0.4))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(GlassEffect(cornerRadius: 20, isSelected: true, accentColor: tinted ? accentColor : nil))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

// MARK: - Channel Logo Box (reusable, properly sized)

/// Renders a channel logo inside a rounded background box with consistent padding.
/// The image uses .fit content mode so logos aren't stretched, but is given enough
/// room (boxSize - 2 * padding) so it fills the box nicely without overflowing.
private struct ChannelLogoBox: View {
    let urlString: String
    let boxSize: CGFloat
    let cornerRadius: CGFloat
    let padding: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.08))
            CachedAsyncImage(urlString: urlString, size: nil)
                .padding(padding)
        }
        .frame(width: boxSize, height: boxSize)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

// MARK: - Panel Channel Row

private struct PanelChannelRow: View, Equatable {
    let channel: StreamChannel
    @ObservedObject var viewModel: ChannelViewModel
    let onPlay: () -> Void

    // Equatable so the enclosing `.equatable()` lets SwiftUI skip re-rendering
    // this row while the header collapses (the panel body re-runs every scroll
    // frame, but the row's channel isn't changing). Data-driven refreshes still
    // flow through the @ObservedObject subscription, so the program label stays
    // current when the EPG or clock ticks.
    static func == (lhs: PanelChannelRow, rhs: PanelChannelRow) -> Bool {
        lhs.channel == rhs.channel
    }

    private var currentProg: EPGProgram? { viewModel.getCurrentProgram(for: channel) }

    var body: some View {
        Button(action: {
            // A tab swipe that starts on this row still fires the action on
            // release — no-op while the swipe suppression window is open.
            guard SwipeTapGuard.tapsAllowed else { return }
            ChannelViewModel.shared.triggerSelectionHaptic()
            onPlay()
        }) {
            HStack(spacing: 14) {
                ChannelLogoBox(urlString: channel.icon ?? "",
                               boxSize: 52,
                               cornerRadius: 10,
                               padding: 7)

                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let prog = currentProg {
                        Text(prog.title)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Schedule Row

private struct ScheduleRow: View {
    let program: EPGProgram
    let isNow: Bool
    var isScheduled: Bool = false
    var onRecord: (() -> Void)? = nil

    /// True when the program has already completely aired.
    private var isPast: Bool { program.stop < Date() }

    private var timeLabel: String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: program.start)
    }
    private var durationLabel: String {
        let mins = Int(program.stop.timeIntervalSince(program.start) / 60)
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(timeLabel)
                    .font(.caption.monospacedDigit().weight(isNow ? .bold : .regular))
                    .foregroundStyle(isNow ? .white : Color.white.opacity(0.5))
                Text(durationLabel)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.3))
            }
            .frame(width: 54, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2)
                .fill(isNow ? Color.red : Color.white.opacity(0.12))
                .frame(width: 3, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(program.title)
                    .font(.subheadline.weight(isNow ? .semibold : .regular))
                    .foregroundStyle(isNow ? .white : Color.white.opacity(0.7))
                    .lineLimit(1)
                if let desc = program.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Record button — hidden for past programs
            if !isPast, let record = onRecord {
                Button(action: {
                    guard SwipeTapGuard.tapsAllowed else { return }
                    record()
                }) {
                    Image(systemName: isScheduled ? "bell.fill" : "bell")
                        .font(.system(size: 15))
                        .foregroundStyle(isScheduled ? .red : Color.white.opacity(0.45))
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(isScheduled ? 0.12 : 0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isScheduled)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(isNow ? Color.white.opacity(0.04) : Color.clear)
    }
}

// MARK: - Recording Row

private struct RecordingRow: View {
    let recording: Recording
    @ObservedObject var recordingManager: RecordingManager
    /// Fired when a completed recording's row is tapped — plays it.
    var onPlay: (() -> Void)? = nil
    /// Fired when a recording IN PROGRESS is tapped — switches the player to
    /// the channel being recorded, live. Nil when that channel can't be
    /// found in the playlist.
    var onWatchLive: (() -> Void)? = nil
    /// The stop confirmation for a recording in progress.
    @State private var confirmStop = false

    private var isPlayable: Bool { recording.status == .completed }
    private var isInProgress: Bool { recording.status == .recording }

    private var dateLabel: String {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: recording.startTime)
    }
    private var statusColor: Color {
        switch recording.status {
        case .completed: return .green
        case .recording: return .red
        case .failed:    return .orange
        case .scheduled: return .blue
        case .cancelled: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // A completed recording shows a play glyph in place of the status
            // dot so it reads as tappable; one in progress pulses; others keep
            // the status dot.
            if isPlayable {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .padding(.leading, 14)
            } else if isInProgress {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                    .padding(.leading, 14)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .padding(.leading, 18)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(isInProgress
                     ? "Recording · \(recording.channelName)"
                     : "\(recording.channelName) · \(dateLabel)")
                    .font(.caption)
                    .foregroundStyle(isInProgress ? .red.opacity(0.85) : .white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isInProgress {
                // Watch the channel live — the whole row does this too; the
                // glyph is what says so.
                if onWatchLive != nil {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 30, height: 36)
                }
                // Stop, keeping what has been recorded so far.
                Button(action: {
                    guard SwipeTapGuard.tapsAllowed else { return }
                    ChannelViewModel.shared.triggerSelectionHaptic()
                    confirmStop = true
                }) {
                    Image(systemName: "stop.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording")
                .confirmationDialog("Stop recording \(recording.displayName)?",
                                    isPresented: $confirmStop, titleVisibility: .visible) {
                    Button("Stop Recording", role: .destructive) {
                        ChannelViewModel.shared.triggerHaptic(.medium)
                        recordingManager.stopRecording(recording.id)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("What has been recorded so far is kept.")
                }
            }

            // Delete — for one in progress, this stops it AND discards the
            // file, which is what the bin means.
            Button(action: {
                guard SwipeTapGuard.tapsAllowed else { return }
                ChannelViewModel.shared.triggerSelectionHaptic()
                recordingManager.deleteRecording(recording)
            }) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .padding(.vertical, 10)
        // Whole-row tap plays a completed recording, or switches to the
        // channel a recording in progress is taken from. onTapGesture rather
        // than a Button so it never swallows the buttons' own taps.
        .contentShape(Rectangle())
        .onTapGesture {
            guard SwipeTapGuard.tapsAllowed else { return }
            if isPlayable {
                ChannelViewModel.shared.triggerSelectionHaptic()
                onPlay?()
            } else if isInProgress, let onWatchLive {
                ChannelViewModel.shared.triggerSelectionHaptic()
                onWatchLive()
            }
        }
    }
}
