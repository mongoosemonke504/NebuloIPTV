import SwiftUI
import AVKit
import MobileVLCKit
import Combine

// MARK: - Category colour (view-layer only)

extension Recording.RecordingCategory {
    var color: Color {
        switch self {
        case .sports:  return Color(red: 0.00, green: 0.78, blue: 0.95)
        case .movies:  return Color(red: 0.69, green: 0.32, blue: 0.87)
        case .tvShows: return Color(red: 1.00, green: 0.58, blue: 0.00)
        case .other:   return Color(white: 0.55)
        }
    }
}

extension Recording {
    var categoryColor: Color { category.color }
}

// MARK: - Recording group (completed recordings grouped by display name)

struct RecordingGroup: Identifiable {
    var id: String { displayName }
    let displayName: String
    let recordings: [Recording]
    let channelIcon: String?

    var episodeCount: Int { recordings.count }

    var totalSizeBytes: Int64 {
        recordings.reduce(0) { $0 + $1.fileSizeBytes }
    }

    var totalSizeString: String { formatBytes(totalSizeBytes) }

    /// Sum of all recording durations (endTime – startTime).
    var totalDuration: TimeInterval {
        recordings.reduce(0) { $0 + $1.duration }
    }

    /// Human-readable total duration, e.g. "1h 24m" or "47m".
    var totalDurationString: String {
        let secs = Int(totalDuration)
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(max(1, m))m"
    }

    var latestRecording: Recording? {
        recordings.sorted { $0.createdAt > $1.createdAt }.first
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 0.1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1  { return String(format: "%.0f MB", mb) }
        return "\(bytes / 1024) KB"
    }
}

// MARK: - Storage item (Identifiable wrapper for ForEach)

private struct StorageItem: Identifiable {
    let id: Recording.RecordingCategory
    let category: Recording.RecordingCategory
    let bytes: Int64
}

// MARK: - Main view

struct RecordingsView: View {
    @ObservedObject var manager = RecordingManager.shared
    @State private var selectedRecording: Recording?
    @State private var showRenameAlert = false
    @State private var recordingToRename: Recording?
    @State private var newNameInput = ""
    @State private var showManageScheduled = false
    @State private var navigateToCategoryView = false
    /// The recording whose red dot was tapped, awaiting the stop confirmation.
    @State private var stopRequest: Recording?
    /// 0 at rest, 1 once the big "Recordings" title has fully scrolled past.
    /// Tracks live scroll offset directly (no withAnimation) so the compact
    /// overlay crossfades in lockstep with the scroll instead of snapping in.
    @State private var headerProgress: CGFloat = 0

    var viewModel: ChannelViewModel? = nil
    var playAction: ((StreamChannel) -> Void)? = nil
    var onBack: (() -> Void)? = nil
    var onOpenSearch: (() -> Void)? = nil
    @Environment(\.dismiss) var dismiss

    @AppStorage("nebColor1") private var nebColor1 = "#1A2538"
    @AppStorage("nebColor2") private var nebColor2 = "#11101A"
    @AppStorage("nebColor3") private var nebColor3 = "#1F1A24"
    @AppStorage("nebX1") private var nebX1 = 0.5
    @AppStorage("nebY1") private var nebY1 = 0.0
    @AppStorage("nebX2") private var nebX2 = 0.5
    @AppStorage("nebY2") private var nebY2 = 0.5
    @AppStorage("nebX3") private var nebX3 = 0.5
    @AppStorage("nebY3") private var nebY3 = 1.0

    // MARK: Derived data

    private var nowRecording: [Recording] {
        manager.recordings
            .filter { $0.status == .recording }
            .sorted { $0.startTime < $1.startTime }
    }

    /// All completed recordings grouped by display name, newest first.
    private var allCompletedGroups: [RecordingGroup] {
        let completed = manager.recordings.filter { $0.status == .completed }
        var nameDict: [String: [Recording]] = [:]
        for rec in completed {
            nameDict[rec.displayName, default: []].append(rec)
        }
        return nameDict.map { name, recs in
            RecordingGroup(
                displayName: name,
                recordings: recs,
                channelIcon: recs.first?.channelIcon
            )
        }.sorted {
            guard let a = $0.latestRecording, let b = $1.latestRecording else { return false }
            return a.createdAt > b.createdAt
        }
    }

    private var scheduledRecordings: [Recording] {
        manager.recordings
            .filter { $0.status == .scheduled }
            .sorted { $0.startTime < $1.startTime }
    }

    private var storageItems: [StorageItem] {
        var dict: [Recording.RecordingCategory: Int64] = [:]
        for rec in manager.recordings where rec.status == .completed {
            dict[rec.category, default: 0] += rec.fileSizeBytes
        }
        return Recording.RecordingCategory.allCases.compactMap { cat in
            guard let b = dict[cat], b > 0 else { return nil }
            return StorageItem(id: cat, category: cat, bytes: b)
        }
    }

    private var totalRecordingBytes: Int64 {
        storageItems.reduce(0) { $0 + $1.bytes }
    }

    /// Free space iOS will actually let us use (from volume resource values).
    private var deviceAvailableBytes: Int64 {
        let vals = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return vals?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            NebulaBackgroundView(
                color1: Color(hex: nebColor1) ?? .purple,
                color2: Color(hex: nebColor2) ?? .blue,
                color3: Color(hex: nebColor3) ?? .pink,
                point1: UnitPoint(x: nebX1, y: nebY1),
                point2: UnitPoint(x: nebX2, y: nebY2),
                point3: UnitPoint(x: nebX3, y: nebY3)
            )

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    headerView
                        .opacity(1 - headerProgress)
                        .background(ScrollOffsetProbe(space: "recScroll", id: "rec"))
                    storageCard
                    nowRecordingSection
                    // Single "Recently Recorded" section — tapping header opens
                    // the per-category breakdown page.
                    if !allCompletedGroups.isEmpty {
                        recentlyRecordedSection
                    }
                    // Scheduled is always shown (empty-state message if nothing queued)
                    scheduledSection
                    // Only show the big "No Recordings" placeholder when literally
                    // nothing exists across all states — having a pending scheduled
                    // entry counts as activity, so don't drown it out with a
                    // contradictory empty-state.
                    if nowRecording.isEmpty && allCompletedGroups.isEmpty && scheduledRecordings.isEmpty {
                        emptyState
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
            .coordinateSpace(name: "recScroll")
            // The compact "Recordings" title is drawn by StandardLayout's
            // chrome row (level with Back/gear), fed by the same offset
            // preference this probe publishes.
            .onPreferenceChange(SectionScrollOffsetsKey.self) { offsets in
                guard let y = offsets["rec"] else { return }
                headerProgress = min(max(-y / 40, 0), 1)
            }

            // Shared app-wide compact-header vignette (dark + blur), reaching
            // from the true screen top and fading out down a long tail — same
            // as home/sports/favorites. Revealed as the big title scrolls away.
            GeometryReader { proxy in
                CompactHeaderScrim(height: proxy.safeAreaInsets.top + 215, fadeStart: 0.2)
                    .frame(width: proxy.size.width)
            }
            .ignoresSafeArea(.container, edges: .top)
            .opacity(headerProgress * headerProgress)
            .allowsHitTesting(false)

            // The Recently Recorded breakdown is a DRILL-DOWN, so it pushes in
            // from the trailing edge and leaves the same way — like a category
            // page or a favourite team's, rather than the blur-crossfade it
            // used to do. Same curve and duration as every other push in the
            // app, from `DetailRouter.travel`.
            if navigateToCategoryView {
                RecordingsCategoryView(
                    viewModel: viewModel,
                    playAction: playAction,
                    onBack: {
                        withAnimation(.easeOut(duration: DetailRouter.travel)) {
                            navigateToCategoryView = false
                        }
                    },
                    onOpenSearch: onOpenSearch
                )
                .transition(.move(edge: .trailing))
                .zIndex(10)
            }
        }
        // Single swipe-back gesture that handles both nav levels:
        //   • In the category overlay  → dismiss the overlay back to Recordings
        //   • At the top level         → return to the home screen
        // Placed on the whole ZStack so there's only one .highPriorityGesture
        // listening at the leading edge — fixes the bug where the outer modifier
        // (in MainView) was eating swipes that should dismiss the overlay.
        .modifier(SwipeBackModifier(onBack: {
            if navigateToCategoryView {
                withAnimation(.easeOut(duration: DetailRouter.travel)) {
                    navigateToCategoryView = false
                }
            } else {
                onBack?()
            }
        },
        // Opened from Settings there is no `onBack` and no overlay, so the
        // strip would swallow the swipe and go nowhere. Stand down and let
        // the navigation stack's own pop take it.
        isEnabled: navigateToCategoryView || onBack != nil))
        .overlay(alignment: .bottom) {
            if let onSearch = onOpenSearch, !navigateToCategoryView {
                FavoritesSearchPill(onTap: onSearch)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 0)
            }
        }
        // Transparent nav bar so the toolbar back button floats over the content
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Hide this back button while the category-view overlay is up —
                // that overlay supplies its own back button and we don't want
                // both showing simultaneously.
                if let back = onBack, !navigateToCategoryView {
                    Button(action: back) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
        }
        .fullScreenCover(item: $selectedRecording) { recording in
            RecordingPlayerView(recording: recording, viewModel: viewModel, onPlayChannel: { channel in
                // Leave the recording, then open the channel live once the
                // cover has gone.
                selectedRecording = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { playAction?(channel) }
            })
        }
        .alert("Rename Recording", isPresented: $showRenameAlert) {
            TextField("Name", text: $newNameInput)
            Button("Save") {
                if let rec = recordingToRename {
                    manager.renameRecording(rec, newName: newNameInput)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showManageScheduled) {
            ManageScheduledView()
        }
        // One tap on the dot asks; a stop can't be undone, and the dot sits
        // where a thumb lands.
        .confirmationDialog("Stop recording \(stopRequest?.displayName ?? "")?",
                            isPresented: Binding(get: { stopRequest != nil },
                                                 set: { if !$0 { stopRequest = nil } }),
                            titleVisibility: .visible,
                            presenting: stopRequest) { recording in
            Button("Stop Recording", role: .destructive) {
                ChannelViewModel.shared.triggerHaptic(.medium)
                manager.stopRecording(recording.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("What has been recorded so far is kept.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Recordings")
                .font(NuvioTheme.pageTitleFont)
                .foregroundStyle(.white)
            Spacer()
        }
    }

    // MARK: - Storage Card (always visible)

    private var storageCard: some View {
        let available = deviceAvailableBytes
        // Bar: recordings fraction of (recordings + available)
        let totalBar  = totalRecordingBytes + available
        let recFrac   = totalBar > 0 ? CGFloat(totalRecordingBytes) / CGFloat(totalBar) : 0

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Storage")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if totalRecordingBytes > 0 {
                    Text(formatBytes(totalRecordingBytes) + " used")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }

            // Progress bar: coloured (recordings) + grey (available)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Available (background)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.12))

                    // Recordings (foreground) — segmented by category
                    if totalRecordingBytes > 0 {
                        HStack(spacing: 2) {
                            ForEach(storageItems) { item in
                                let catFrac = CGFloat(item.bytes) / CGFloat(totalRecordingBytes)
                                let barW    = max(4, geo.size.width * recFrac * catFrac)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(item.category.color)
                                    .frame(width: barW)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .frame(height: 8)

            // Legend — two-column grid prevents overflow when multiple categories exist
            if storageItems.isEmpty {
                Text("No recordings saved yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), alignment: .leading),
                                  GridItem(.flexible(), alignment: .leading)],
                        alignment: .leading,
                        spacing: 5
                    ) {
                        ForEach(storageItems) { item in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(item.category.color)
                                    .frame(width: 7, height: 7)
                                Text(item.category.displayName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .lineLimit(1)
                                Text(formatBytes(item.bytes))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .lineLimit(1)
                            }
                        }
                    }
                    if available > 0 {
                        Text(formatBytes(available) + " free")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
        }
        .padding(16)
        .modifier(GlassEffect(cornerRadius: 16, isSelected: false, accentColor: nil))
    }

    // MARK: - Now Recording

    @ViewBuilder
    private var nowRecordingSection: some View {
        if !nowRecording.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                        .padding(.top, 3)
                    NuvioUnderlinedTitle(text: "Now Recording")
                }

                VStack(spacing: 10) {
                    ForEach(nowRecording) { recording in
                        let live = viewModel?.liveChannel(for: recording)
                        NowRecordingRow(
                            recording: recording,
                            // The row is the channel: tap it to watch what
                            // is being recorded, live.
                            onWatch: live.map { channel in { playAction?(channel) } },
                            // The dot is the recording: tap it to stop.
                            onStop: { stopRequest = recording }
                        )
                        .contextMenu {
                            if let live {
                                Button {
                                    playAction?(live)
                                } label: {
                                    Label("Watch Live", systemImage: "play.fill")
                                }
                            }
                            Button(role: .destructive) {
                                stopRequest = recording
                            } label: {
                                Label("Stop Recording", systemImage: "stop.circle")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recently Recorded (single section, navigates to category breakdown)

    private var recentlyRecordedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Tappable header navigates to per-category page
            Button {
                // Same push tempo as the way back out, and as every other
                // drill-down in the app.
                withAnimation(.easeOut(duration: DetailRouter.travel)) {
                    navigateToCategoryView = true
                }
            } label: {
                HStack(alignment: .top) {
                    NuvioUnderlinedTitle(text: "Recently Recorded")
                    Spacer()
                    HStack(spacing: 4) {
                        Text(
                            allCompletedGroups.count == 1
                                ? "1 item"
                                : "\(allCompletedGroups.count) items"
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            .buttonStyle(.plain)

            // Horizontal carousel — all groups newest first
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(allCompletedGroups) { group in
                        RecordingGroupCard(group: group) {
                            if let rec = group.latestRecording {
                                selectedRecording = rec
                            }
                        }
                        .contextMenu {
                            if group.recordings.count > 1 {
                                Menu("All Recordings (\(group.episodeCount))") {
                                    ForEach(group.recordings.sorted { $0.createdAt > $1.createdAt }) { rec in
                                        Button(rec.displayName + " · " + shortDate(rec.startTime)) {
                                            selectedRecording = rec
                                        }
                                    }
                                }
                            }
                            Button {
                                if let rec = group.latestRecording {
                                    recordingToRename = rec
                                    newNameInput = rec.displayName
                                    showRenameAlert = true
                                }
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                for rec in group.recordings { manager.deleteRecording(rec) }
                            } label: {
                                Label(
                                    group.episodeCount > 1
                                        ? "Delete All (\(group.episodeCount))"
                                        : "Delete",
                                    systemImage: "trash"
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Scheduled (always visible)

    private var scheduledSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                NuvioUnderlinedTitle(text: "Scheduled")
                Spacer()
                if !scheduledRecordings.isEmpty {
                    Button { showManageScheduled = true } label: {
                        Text("Manage")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }

            if scheduledRecordings.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("Nothing is scheduled yet")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            } else {
                // A real List so the swipe-to-cancel is the exact native
                // gesture the channel-hide swipe uses — same reveal, same
                // spring, same row-collapse on delete. Scroll-disabled and
                // sized to its rows so it sits inside the outer ScrollView.
                List {
                    ForEach(scheduledRecordings) { recording in
                        ScheduledRecordingRow(recording: recording)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    manager.deleteRecording(recording)
                                } label: {
                                    Label("Cancel", systemImage: "trash.fill")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    manager.deleteRecording(recording)
                                } label: {
                                    Label("Cancel Recording", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .environment(\.defaultMinListRowHeight, 0)
                .frame(height: CGFloat(scheduledRecordings.count) * 92)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.25))
            Text("No Recordings")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text("Schedule recordings from the guide or while watching a channel.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.38))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 0.1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1  { return String(format: "%.0f MB", mb) }
        return "\(bytes / 1024) KB"
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Now Recording Row

struct NowRecordingRow: View {
    let recording: Recording
    /// Watch the channel being recorded, live. Nil when the channel can't
    /// be found in the playlist any more — the row then only shows.
    var onWatch: (() -> Void)? = nil
    /// Stop the recording — the red dot.
    var onStop: () -> Void = {}
    // Tick every second so the elapsed timer is live.
    @State private var now: Date = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 14) {
            // The red dot IS the stop button. Its own Button so a tap here
            // never reaches the row's own tap beneath it.
            Button {
                guard SwipeTapGuard.tapsAllowed else { return }
                ChannelViewModel.shared.triggerSelectionHaptic()
                onStop()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red.opacity(0.2))
                        .frame(width: 52, height: 52)
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(recording.channelName + " · ends " + endsAt)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer()

            // Live elapsed indicator, with a play glyph when the row can
            // open the channel — so the row reads as somewhere to go.
            HStack(spacing: 8) {
                Text(elapsedString)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.9))
                if onWatch != nil {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(14)
        .modifier(GlassEffect(cornerRadius: 14, isSelected: true, accentColor: .red))
        // The row — everything but the dot — opens the channel live.
        // onTapGesture rather than a Button around the row, so the dot's
        // own Button keeps its tap.
        .contentShape(Rectangle())
        .onTapGesture {
            guard let onWatch, SwipeTapGuard.tapsAllowed else { return }
            ChannelViewModel.shared.triggerSelectionHaptic()
            onWatch()
        }
        .onReceive(ticker) { now = $0 }
    }

    private var endsAt: String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: recording.endTime)
    }

    private var elapsedString: String {
        let secs = max(0, now.timeIntervalSince(recording.startTime))
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        if m >= 60 { return String(format: "%dh %02dm", m / 60, m % 60) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Recording Group Card

struct RecordingGroupCard: View {
    let group: RecordingGroup
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        if let icon = group.channelIcon {
                            CachedAsyncImage(urlString: icon, size: CGSize(width: 160, height: 100))
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 160, height: 100)
                                .clipped()
                        } else {
                            LinearGradient(
                                colors: [Color.purple.opacity(0.55), Color.blue.opacity(0.55)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        }
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.6)],
                            startPoint: .top, endPoint: .bottom
                        )
                        Image(systemName: "play.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                            .padding(11)
                            .background(.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                    .frame(width: 160, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if group.episodeCount > 1 {
                        Text("\(group.episodeCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.red)
                            .clipShape(Capsule())
                            .padding(8)
                    }
                }

                Text(group.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(group.totalDurationString)
                    if group.totalSizeBytes > 0 {
                        Text("·")
                        Text(group.totalSizeString)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: 160)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Scheduled Row

struct ScheduledRecordingRow: View {
    let recording: Recording

    // Live countdown to the scheduled start, refreshed every 30s.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()

    // Same card shape as the favorites reminder row: an icon block, a title
    // with a status pill, and a rich schedule line, on a dark rounded card.
    var body: some View {
        HStack(spacing: 12) {
            // Channel logo chip — identical to the favorites reminder card.
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                if let icon = recording.channelIcon, !icon.isEmpty {
                    CachedAsyncImage(urlString: icon, size: CGSize(width: 40, height: 40))
                        .padding(6)
                } else {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(recording.categoryColor)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(recording.displayName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(countdownPill)
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.black.opacity(0.75))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(recording.categoryColor))
                }
                Text(scheduleSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Text("\(recording.channelName) · \(durationString)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .onReceive(ticker) { now = $0 }
    }

    /// Countdown pill next to the title: "IN 2H", "IN 45M", "IN 3D", "SOON".
    private var countdownPill: String {
        let delta = recording.startTime.timeIntervalSince(now)
        guard delta > 0 else { return "SOON" }
        let mins = Int(delta / 60)
        if mins < 60 { return "IN \(max(1, mins))M" }
        if mins < 24 * 60 { return "IN \(mins / 60)H" }
        return "IN \(mins / (24 * 60))D"
    }

    private var durationString: String {
        let secs = Int(recording.endTime.timeIntervalSince(recording.startTime))
        let h = secs / 3600, m = (secs % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(max(1, m))m"
    }

    private var scheduleSubtitle: String {
        let cal = Calendar.current
        let start = recording.startTime
        let dayPrefix: String
        if cal.isDateInToday(start) { dayPrefix = "Today" }
        else if cal.isDateInTomorrow(start) { dayPrefix = "Tomorrow" }
        else { dayPrefix = Self.dayFmt.string(from: start) }
        return "\(dayPrefix) · \(Self.timeFmt.string(from: start)) – \(Self.timeFmt.string(from: recording.endTime))"
    }
}

// MARK: - Manage Scheduled Sheet

struct ManageScheduledView: View {
    @ObservedObject private var manager = RecordingManager.shared
    @Environment(\.dismiss) var dismiss

    private var liveScheduled: [Recording] {
        manager.recordings
            .filter { $0.status == .scheduled }
            .sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(liveScheduled) { recording in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recording.displayName).font(.headline)
                            Text(scheduleString(recording))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .onDelete { indexSet in
                    for idx in indexSet { manager.deleteRecording(liveScheduled[idx]) }
                }
            }
            .navigationTitle("Scheduled")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
            }
        }
    }

    private func scheduleString(_ r: Recording) -> String {
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
        let tf = DateFormatter(); tf.timeStyle = .short
        return "\(df.string(from: r.startTime)) – \(tf.string(from: r.endTime))"
    }
}

// MARK: - Recordings Category View
// Pushed from RecordingsView when the user taps "Recently Recorded".
// Shows completed recordings split by category, each in its own carousel.

struct RecordingsCategoryView: View {
    var viewModel: ChannelViewModel? = nil
    var playAction: ((StreamChannel) -> Void)? = nil
    var onBack: (() -> Void)? = nil
    var onOpenSearch: (() -> Void)? = nil

    @ObservedObject private var manager = RecordingManager.shared
    @State private var selectedRecording: Recording?
    @State private var showRenameAlert = false
    @State private var recordingToRename: Recording?
    @State private var newNameInput = ""

    @AppStorage("nebColor1") private var nebColor1 = "#1A2538"
    @AppStorage("nebColor2") private var nebColor2 = "#11101A"
    @AppStorage("nebColor3") private var nebColor3 = "#1F1A24"
    @AppStorage("nebX1") private var nebX1 = 0.5
    @AppStorage("nebY1") private var nebY1 = 0.0
    @AppStorage("nebX2") private var nebX2 = 0.5
    @AppStorage("nebY2") private var nebY2 = 0.5
    @AppStorage("nebX3") private var nebX3 = 0.5
    @AppStorage("nebY3") private var nebY3 = 1.0

    // Groups completed recordings by category → display name, newest first within each category.
    private var completedGroupsByCategory: [(Recording.RecordingCategory, [RecordingGroup])] {
        let completed = manager.recordings.filter { $0.status == .completed }
        var tree: [Recording.RecordingCategory: [String: [Recording]]] = [:]
        for rec in completed {
            tree[rec.category, default: [:]][rec.displayName, default: []].append(rec)
        }
        return Recording.RecordingCategory.allCases.compactMap { cat in
            guard let nameDict = tree[cat], !nameDict.isEmpty else { return nil }
            let groups = nameDict.map { name, recs in
                RecordingGroup(
                    displayName: name,
                    recordings: recs,
                    channelIcon: recs.first?.channelIcon
                )
            }.sorted {
                guard let a = $0.latestRecording, let b = $1.latestRecording else { return false }
                return a.createdAt > b.createdAt
            }
            return (cat, groups)
        }
    }

    var body: some View {
        ZStack {
            NebulaBackgroundView(
                color1: Color(hex: nebColor1) ?? .purple,
                color2: Color(hex: nebColor2) ?? .blue,
                color3: Color(hex: nebColor3) ?? .pink,
                point1: UnitPoint(x: nebX1, y: nebY1),
                point2: UnitPoint(x: nebX2, y: nebY2),
                point3: UnitPoint(x: nebX3, y: nebY3)
            )
            .ignoresSafeArea()

            if completedGroupsByCategory.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 52))
                        .foregroundStyle(.white.opacity(0.25))
                    Text("No Recordings")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(completedGroupsByCategory, id: \.0) { cat, groups in
                            categorySection(category: cat, groups: groups)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 100)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let onSearch = onOpenSearch {
                FavoritesSearchPill(onTap: onSearch)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 0)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let back = onBack {
                    Button(action: back) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
        }
        .tint(.white)
        .fullScreenCover(item: $selectedRecording) { recording in
            RecordingPlayerView(recording: recording, viewModel: viewModel, onPlayChannel: { channel in
                // Leave the recording, then open the channel live once the
                // cover has gone.
                selectedRecording = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { playAction?(channel) }
            })
        }
        .alert("Rename Recording", isPresented: $showRenameAlert) {
            TextField("Name", text: $newNameInput)
            Button("Save") {
                if let rec = recordingToRename {
                    manager.renameRecording(rec, newName: newNameInput)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Category section

    @ViewBuilder
    private func categorySection(category: Recording.RecordingCategory, groups: [RecordingGroup]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(category.color).frame(width: 8, height: 8)
                    .padding(.top, 8)
                NuvioUnderlinedTitle(text: category.displayName)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(groups) { group in
                        RecordingGroupCard(group: group) {
                            if let rec = group.latestRecording {
                                selectedRecording = rec
                            }
                        }
                        .contextMenu {
                            if group.recordings.count > 1 {
                                Menu("All Recordings (\(group.episodeCount))") {
                                    ForEach(group.recordings.sorted { $0.createdAt > $1.createdAt }) { rec in
                                        Button(rec.displayName + " · " + shortDate(rec.startTime)) {
                                            selectedRecording = rec
                                        }
                                    }
                                }
                            }
                            Button {
                                if let rec = group.latestRecording {
                                    recordingToRename = rec
                                    newNameInput = rec.displayName
                                    showRenameAlert = true
                                }
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                for rec in group.recordings { manager.deleteRecording(rec) }
                            } label: {
                                Label(
                                    group.episodeCount > 1
                                        ? "Delete All (\(group.episodeCount))"
                                        : "Delete",
                                    systemImage: "trash"
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 4)
            }
        }
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Recording Player View
// Uses CustomVideoPlayerView (same player as all other channels).
// Portrait split layout is kept (forceFullscreen defaults to false) so
// PlayerInfoPanel appears below the video — same experience as a live channel.
// infoChannel resolves to the real live channel so EPG / schedule data is live.

struct RecordingPlayerView: View {
    /// The recording being played. Held in @State so tapping a different
    /// recording in the info panel's Recordings tab swaps it in place — the
    /// player re-sets-up on the new file rather than opening a second cover.
    @State private var recording: Recording
    /// Pass the app's ChannelViewModel so the info panel below the player
    /// can show EPG schedule, related channels, and recordings.
    var viewModel: ChannelViewModel? = nil
    /// A live channel tapped in the info panel (the related channels, or a
    /// channel from the picker). The presenter closes this player and opens
    /// that channel live — without it a tap on a related channel did
    /// nothing at all from a recording.
    var onPlayChannel: ((StreamChannel) -> Void)? = nil

    init(recording: Recording, viewModel: ChannelViewModel? = nil,
         onPlayChannel: ((StreamChannel) -> Void)? = nil) {
        _recording = State(initialValue: recording)
        self.viewModel = viewModel
        self.onPlayChannel = onPlayChannel
    }

    @Environment(\.dismiss) var dismiss
    @ObservedObject private var manager = RecordingManager.shared
    @State private var showQuickSwitcher = false

    /// Live snapshot from the manager — picks up `localFileName` changes
    /// when the background .ts → .mp4 remux finishes mid-playback, which
    /// then lets `recordingChannel` rebuild with the .mp4 URL so KSPlayer
    /// (with its moov-atom seek table) takes over scrubbing.
    private var currentRecording: Recording {
        manager.recordings.first(where: { $0.id == recording.id }) ?? recording
    }

    /// Fake StreamChannel whose streamURL points at the local recording file.
    /// Used only for playback — the info panel uses `infoChannel` instead.
    private var recordingChannel: StreamChannel? {
        guard let url = manager.getPlaybackURL(for: currentRecording) else { return nil }
        return StreamChannel(
            id: currentRecording.id.hashValue,
            name: currentRecording.displayName,
            streamURL: url.absoluteString,
            icon: currentRecording.channelIcon,
            categoryID: 0,
            originalName: currentRecording.programTitle,
            epgID: currentRecording.programDescription  // shown as description in the controls overlay
        )
    }

    /// The real live channel that matches this recording's channel name.
    /// Passed as `infoChannel` so PlayerInfoPanel shows live EPG/schedule data.
    private var infoChannel: StreamChannel? {
        viewModel?.liveChannel(for: currentRecording)
    }

    var body: some View {
        Group {
            if let ch = recordingChannel {
                CustomVideoPlayerView(
                    channel: ch,
                    viewModel: viewModel,          // enables the portrait split info panel
                    onDismiss: { dismiss() },
                    onPlayChannel: onPlayChannel,
                    // Tapping another recording in the info panel swaps it in
                    // place: changing `recording` rebuilds `recordingChannel`,
                    // and the player re-sets-up on the new file (its channel
                    // prop changed) — closing the current one and opening the
                    // new one without a second cover.
                    onPlayRecording: { newRec in
                        guard newRec.id != recording.id else { return }
                        recording = newRec
                    },
                    isRecordingPlayback: true,
                    recording: currentRecording,
                    // forceFullscreen: false (default) — portrait split layout shows
                    // the info panel below, same as a live channel.
                    infoChannel: infoChannel,      // real channel for EPG / schedule lookup
                    showQuickSwitcher: $showQuickSwitcher
                )
                .ignoresSafeArea()
                // Transparent cover, same as a live channel: while the player
                // card is dragged down to close, the recordings list behind it
                // shows through instead of a flat black backdrop.
                .presentationBackground(.clear)
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("Recording file not found")
                            .foregroundStyle(.white.opacity(0.7))
                        Button("Dismiss") { dismiss() }
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        // Scrubbing fix: AVURLAsset.load(.duration) on a raw .ts stream returns an
        // incorrect duration because live HLS PCR/PTS timestamps start at a large
        // offset (e.g. "seconds since broadcast epoch"), making the file appear to
        // be 24+ hours long.  The correct duration is always known from the recording
        // metadata (endTime – startTime).  Same applies to currentTime — VLC reports
        // it in the same broken PTS units, so the progress text/bar would stay frozen.
        //
        // The fix: switch the engine into externalTimeManagement mode and override
        // the duration with metadata. The engine then advances currentTime on the
        // wall clock itself (it used to be a ticker in this view, which meant the
        // position stopped counting the moment the view left the screen — so a
        // recording sent down to the mini player came back showing the time you
        // minimised it at). Seeks just set currentTime to the target — the engine's
        // clock continues from there.
        //
        // Keyed on the FILE being played rather than the recording id: `play()`
        // resets the engine's clock mode, and the file changes under a playing
        // recording when the background .ts → .mp4 remux lands, so that swap has
        // to re-arm it too.
        .task(id: recordingChannel?.streamURL ?? "") {
            try? await Task.sleep(nanoseconds: 800_000_000) // 0.8s — after play() fires
            // currentRecording (not the captured struct) so we pick up the
            // actual recorded duration even if it was finalized just before
            // playback started.
            let knownDuration = currentRecording.duration
            guard knownDuration > 0 else { return }
            await MainActor.run {
                let engine = PlayerEngine.shared
                engine.externalTimeManagement = true
                engine.duration = knownDuration
                if engine.currentTime > knownDuration || engine.currentTime < 0 {
                    engine.currentTime = 0
                }
            }
        }
        // When background remux finishes, `currentRecording.localFileName`
        // flips from "<uuid>.ts" to "<uuid>.mp4". CustomVideoPlayerView's own
        // .onChange(of: channel) handler will already detect the new URL and
        // re-setupPlayer on the mp4 (which has a real seek table from the
        // moov atom — fixing the scrub-hangs-forever bug). The task above
        // re-arms the clock mode for the new file; this just re-seeks to the
        // position from before the swap so the user doesn't lose their place.
        .onChangeCompat(of: currentRecording.localFileName ?? "") { newFile in
            guard newFile.hasSuffix(".mp4") else { return }
            let savedTime = PlayerEngine.shared.currentTime
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if savedTime > 0 {
                    PlayerEngine.shared.seek(to: savedTime)
                }
            }
        }
    }
}
