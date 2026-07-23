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
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var playerManager: NebuloPlayerEngine
    @ObservedObject var recordingManager = RecordingManager.shared

    /// When true (recording playback), hides the record button in the header
    /// and removes the bell record buttons from the schedule rows.
    var isRecordingPlayback: Bool = false

    @Binding var showSubtitlePanel: Bool
    @Binding var showAudioPanel: Bool

    @AppStorage("accentColor") private var accentHex = "#FFFFFF"
    private var accentColor: Color { Color(hex: accentHex) ?? .blue }

    @State private var selectedTab: InfoTab = .channels
    @State private var showFullDescription = false
    @State private var showRecordingSheet = false
    /// A finished recording tapped in the Recordings tab, played over the live
    /// player via a full-screen cover.
    @State private var recordingToPlay: Recording?

    /// 0 at rest, 1 once the active tab's list has been scrolled. Tracked
    /// 1:1 with the scroll offset (same mechanism as the section headers):
    /// the big program header + description + action pills compress into a
    /// one-line "what's playing" row so more of the channel list is visible.
    @State private var panelCollapse: CGFloat = 0

    /// Natural (uncollapsed) height of the full header, measured at runtime
    /// since the description block varies per program. Drives the reserve
    /// interpolation; nil-height (not yet measured) renders naturally.
    @State private var headerFullHeight: CGFloat = 0

    /// Height of the compact one-line header the full block collapses into.
    private let headerCompactHeight: CGFloat = 44

    private var headerReserve: CGFloat? {
        guard headerFullHeight > 0 else { return nil }
        return headerCompactHeight + (headerFullHeight - headerCompactHeight) * (1 - panelCollapse)
    }

    /// Scroll distance over which the header fully compresses — EXACTLY the
    /// height it gives up. That 1:1 ratio is what makes everything move at
    /// finger speed: 1pt of scroll shrinks the header by 1pt, so the header
    /// edge, tab bar and (via the compensation spacer) the list all track
    /// the finger precisely. A shorter distance made the top of the panel
    /// visibly outrun the finger.
    private var collapseDistance: CGFloat {
        max(1, headerFullHeight - headerCompactHeight)
    }

    /// Top spacer inserted into each tab's scroll content, exactly matching
    /// the height the header has given up. This anchors the scroll: without
    /// it, the shrinking header pulled the whole list up IN ADDITION to the
    /// finger's own scroll, so rows visibly outran the finger. With it, the
    /// row you touch stays under your finger for the entire collapse; the
    /// spacer then scrolls away like any other content.
    private var collapseCompensation: CGFloat {
        // In carried mode the collapse never "took" height from this tab's
        // scroll (its list opens at the top), so no spacer is owed — leaving
        // it in was exactly the blank band under the tab bar.
        guard headerFullHeight > 0, !carriedCollapse else { return 0 }
        return max(0, (headerFullHeight - headerCompactHeight) * panelCollapse)
    }

    /// Converts the scrolled distance into collapse progress. Fed by
    /// `onScrollGeometryChange`, which reports the offset SYNCHRONOUSLY with
    /// every scroll frame (120Hz on ProMotion). The old GeometryReader →
    /// preference pipeline delivered readings a frame late through the
    /// preference system, capping the collapse's effective frame rate below
    /// the rest of the app's. The offset is in the scroll view's own content
    /// coordinates, so it's immune to the frame moving as the header shrinks.
    private func updateCollapse(scrolled: CGFloat) {
        // Frozen during a collapse-preserving tab swipe (see selectTab) so the
        // incoming tab's initial offset-0 callback can't reset the collapse.
        guard Date() >= suppressCollapseUntil, headerFullHeight > 0 else { return }
        // Carried mode: the header is latched compact regardless of this
        // tab's offset (its list sits at the top). A decisive pull past the
        // top releases the latch and re-opens the full header; normal
        // offset-driven tracking resumes from there.
        if carriedCollapse {
            if scrolled < -36 {
                carriedCollapse = false
                withAnimation(.easeOut(duration: 0.25)) { panelCollapse = 0 }
            }
            return
        }
        let distance = collapseDistance
        // Pure continuous mapping — no pixel quantization, no end snap
        // zones. Both were workarounds for noise in the old probe pipeline
        // (rounded layout readbacks oscillated sub-pixel; residual fractions
        // at rest clipped the pills). The synchronous offset is exact — 0 at
        // rest, ≥ distance once scrolled past — so any discretization here
        // only ADDS visible steps: the snap zones popped the header ~1.5pt
        // at the start and end of every slow scroll, and quantizing the
        // spacer while the list pans at fractional offsets wobbled the row
        // under the finger by half a device pixel.
        let shrink = min(max(scrolled, 0), distance)
        let p = shrink / distance
        if p != panelCollapse {
            panelCollapse = p
        }
    }

    /// Which category is currently being browsed in the Channels tab.
    /// `nil` means "default" (Favorites + same category as current channel).
    /// Use special sentinel ids for built-in groups: -4 favorites.
    @State private var browsingCategoryID: Int? = nil

    /// Cached result of the `browsingChannels` filter. The filter scans the
    /// whole channel list, so recomputing it on every header-collapse frame
    /// (the body re-runs each frame as `panelCollapse` ticks) was a large part
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
    @State private var slideFromTrailing = true

    /// Gates tab changes while a slide is in flight — interrupting a `.move`
    /// transition can strand the incoming view offscreen (blank panel).
    @State private var isSliding = false

    /// Per-tab scroll positions, so a tab swipe can carry the collapsed header
    /// across to the incoming tab by scrolling it to the matching offset.
    @State private var channelsScroll = ScrollPosition()
    @State private var scheduleScroll = ScrollPosition()
    @State private var recordingsScroll = ScrollPosition()

    /// While `Date() < this`, scroll-driven collapse updates are ignored. Set
    /// briefly during a collapse-preserving tab swipe so the incoming tab's
    /// initial `offset 0` layout callback can't flash the header back open
    /// before we've scrolled it to the collapsed offset.
    @State private var suppressCollapseUntil = Date.distantPast

    /// One tab switch per drag (set mid-drag, cleared on finger-lift), and
    /// the category chip row's global frame so drags starting there scroll
    /// chips instead of switching tabs.
    @State private var swipeConsumed = false
    @State private var categoryPickerFrame: CGRect = .zero

    /// True when a collapsed header was carried across a tab switch. In this
    /// mode the header is latched compact WITHOUT a compensation spacer or
    /// offset gymnastics (the old approach scrolled the incoming list to a
    /// matching offset, and whenever that couldn't land — short schedule
    /// content, view not attached yet — the spacer showed as a dead blank
    /// band). The latch releases when the user pulls decisively past the top
    /// of the list, which re-opens the full header.
    @State private var carriedCollapse = false

    /// Central tab switch: derives the slide direction from tab order and
    /// swaps with a flat easeOut — no spring, no bounce. A collapsed header
    /// STAYS collapsed (latched) across the switch; the incoming tab opens
    /// at the top of its list under the compact header.
    private func selectTab(_ newTab: InfoTab) {
        guard newTab != selectedTab, !isSliding else { return }
        slideFromTrailing = newTab.rawValue > selectedTab.rawValue
        isSliding = true
        ChannelViewModel.shared.triggerSelectionHaptic()

        let keepCollapsed = panelCollapse > 0.5
        carriedCollapse = keepCollapsed

        // Freeze scroll-driven collapse updates during the slide so the
        // outgoing tab's offset callbacks can't fight the state below.
        suppressCollapseUntil = Date().addingTimeInterval(0.35)

        withAnimation(.easeOut(duration: 0.25)) {
            selectedTab = newTab
            panelCollapse = keepCollapsed ? 1 : 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isSliding = false
        }
    }

    /// Steps to the previous/next tab. Driven by the horizontal swipe.
    private func advanceTab(_ delta: Int) {
        let all = InfoTab.allCases
        guard let idx = all.firstIndex(of: selectedTab) else { return }
        let next = idx + delta
        guard all.indices.contains(next) else { return }
        selectTab(all[next])
    }

    private var currentProgram: EPGProgram? { viewModel.getCurrentProgram(for: channel) }

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

    var body: some View {
        VStack(spacing: 0) {
            // ── Collapsing header ──
            // Scrolling any tab's list compresses the full header (program
            // info + description + action pills) into a compact one-line
            // "what's playing" row, freeing the space for more channels.
            // Same continuous, finger-tracked collapse as the section
            // headers: reserve height interpolates full → compact while the
            // two layers crossfade. The tab bar below stays pinned.
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    programHeader
                    if let prog = currentProgram, let desc = prog.description, !desc.isEmpty {
                        descriptionView(desc: desc)
                    }
                    actionPills
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)
                // Keep the ideal height even as the outer frame shrinks —
                // the clip crops it instead of the text reflowing, and the
                // GeometryReader measurement stays stable (no feedback loop).
                .fixedSize(horizontal: false, vertical: true)
                // The full header stays FULLY VISIBLE while the shrinking
                // window crops it bottom-up (pills, then description, then
                // title — swallowed under the video at finger speed, like an
                // iOS large title). Fading it early left a tall empty black
                // band that slowly pumped during slow scrolls and read as
                // jitter. It only fades in the last stretch, right before
                // the compact line takes over.
                .opacity(min(1.0, max(0.0, (0.92 - Double(panelCollapse)) / 0.2)))
                .allowsHitTesting(panelCollapse < 0.7)
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { headerFullHeight = g.size.height }
                            .onChangeCompat(of: g.size.height) { headerFullHeight = $0 }
                    }
                )

                // ...and the compact line takes over only in the final ~8%
                // (the last few points of scroll), so the swap is a crisp
                // handoff with no stretch where the band sits empty.
                compactHeader
                    .opacity(max(0.0, (Double(panelCollapse) - 0.92) / 0.08))
                    .allowsHitTesting(false)
            }
            .frame(height: headerReserve, alignment: .top)
            .clipped()

            // ── Tab bar ──
            tabBar
                .padding(.horizontal, 18)
                .padding(.bottom, 6)

            Divider()
                .background(Color.white.opacity(0.1))

            // ── Tab content ──
            // NOT a paged TabView: the pager is UIPageViewController-backed,
            // so the compensation spacer inside its pages committed a frame
            // later than the header's height change outside it — a one-pixel
            // up/down oscillation every frame during slow scrolls (the
            // "jitter"). A plain switch keeps the header, spacer and list in
            // ONE layout transaction. Swiping between tabs still works via
            // the horizontal drag below, with a directional slide like the
            // Sports/Favorites sections.
            ZStack(alignment: .top) {
                Group {
                    switch selectedTab {
                    case .channels:   channelsTab
                    case .schedule:   scheduleTab
                    case .recordings: recordingsTab
                    }
                }
                .id(selectedTab)
                .transition(.asymmetric(
                    insertion: .move(edge: slideFromTrailing ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: slideFromTrailing ? .leading : .trailing).combined(with: .opacity)
                ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .simultaneousGesture(
                DragGesture(minimumDistance: 25, coordinateSpace: .global)
                    .onChanged { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        // Horizontal drags open the tap-suppression window so
                        // the row under the finger doesn't fire on release.
                        if abs(dx) > abs(dy) * 1.5 {
                            SwipeTapGuard.suppress()
                        }
                        // Fires mid-drag for an instant response. Drags that
                        // start on the category chip row scroll the chips —
                        // they must never flip to the Schedule tab.
                        guard !swipeConsumed,
                              value.startLocation.x > 44,
                              !categoryPickerFrame.contains(value.startLocation),
                              !HorizontalScrollActivity.isActive,
                              abs(dx) > 50, abs(dx) > abs(dy) * 1.5 else { return }
                        swipeConsumed = true
                        advanceTab(dx < 0 ? 1 : -1)
                    }
                    .onEnded { _ in swipeConsumed = false }
            )
        }
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
            categoryPicker
                .padding(.top, 10)
                .padding(.bottom, 4)

            ScrollView(showsIndicators: false) {
                // Single wrapper so the compensation spacer scrolls with the
                // rest of the content.
                VStack(spacing: 0) {
                    Color.clear.frame(height: collapseCompensation)
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
                guard selectedTab == .channels else { return }
                updateCollapse(scrolled: scrolled)
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
        .captureGlobalFrame { categoryPickerFrame = $0 }
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
            Color.clear.frame(height: collapseCompensation)
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
            guard selectedTab == .schedule else { return }
            updateCollapse(scrolled: scrolled)
        }
    }

    // MARK: - Recordings tab

    private var recordingsTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
            Color.clear.frame(height: collapseCompensation)
            let sorted = recordingManager.recordings.sorted { $0.createdAt > $1.createdAt }
            if sorted.isEmpty {
                emptyState(icon: "record.circle", message: "No recordings yet")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, rec in
                        RecordingRow(recording: rec, recordingManager: recordingManager,
                                     onPlay: { recordingToPlay = rec })
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
        // Play a finished recording over the live player. RecordingPlayerView
        // owns the .ts duration/scrubbing fix, so this reuses it wholesale
        // rather than swapping the shared engine to the local file by hand.
        .fullScreenCover(item: $recordingToPlay) { rec in
            RecordingPlayerView(recording: rec, viewModel: viewModel)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, scrolled in
            guard selectedTab == .recordings else { return }
            updateCollapse(scrolled: scrolled)
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
                Text(currentProgram?.title ?? channel.name)
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
                Text(currentProgram?.title ?? channel.name)
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

    private var isPlayable: Bool { recording.status == .completed }

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
            // dot so it reads as tappable; others keep the status dot.
            if isPlayable {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
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
                Text("\(recording.channelName) · \(dateLabel)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Delete button
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
        // Whole-row tap plays a completed recording. onTapGesture rather than a
        // Button so it never swallows the delete button's own tap.
        .contentShape(Rectangle())
        .onTapGesture {
            guard isPlayable, SwipeTapGuard.tapsAllowed else { return }
            ChannelViewModel.shared.triggerSelectionHaptic()
            onPlay?()
        }
    }
}
