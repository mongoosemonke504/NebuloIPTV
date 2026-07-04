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

    /// Which category is currently being browsed in the Channels tab.
    /// `nil` means "default" (Favorites + same category as current channel).
    /// Use special sentinel ids for built-in groups: -4 favorites.
    @State private var browsingCategoryID: Int? = nil

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
            // ── Fixed header ──
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

            // ── Tab bar ──
            tabBar
                .padding(.horizontal, 18)
                .padding(.bottom, 6)

            Divider()
                .background(Color.white.opacity(0.1))

            // ── Tab content — native PageTabView handles swipe without conflicting
            // with the inner scroll views ──
            TabView(selection: $selectedTab) {
                channelsTab.tag(InfoTab.channels)
                scheduleTab.tag(InfoTab.schedule)
                recordingsTab.tag(InfoTab.recordings)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: selectedTab) { _ in
                ChannelViewModel.shared.triggerSelectionHaptic()
            }
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
                    ChannelViewModel.shared.triggerSelectionHaptic()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedTab = tab
                    }
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
                let chans = browsingChannels
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
                            }
                        }
                        if !others.isEmpty {
                            sectionHeader(browsingTitle)
                            ForEach(others) { ch in
                                PanelChannelRow(channel: ch, viewModel: viewModel) { onPlayChannel?(ch) }
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
                        }
                    }
                    .padding(.top, 4)
                    Spacer(minLength: 32)
                }
            }
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
                                ChannelViewModel.shared.triggerSelectionHaptic()
                                recordingManager.scheduleRecording(
                                    channel: channel,
                                    startTime: max(prog.start, Date()),
                                    endTime: prog.stop,
                                    programTitle: prog.title,
                                    programDescription: prog.description
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

    // MARK: - Recordings tab

    private var recordingsTab: some View {
        ScrollView(showsIndicators: false) {
            let sorted = recordingManager.recordings.sorted { $0.createdAt > $1.createdAt }
            if sorted.isEmpty {
                emptyState(icon: "record.circle", message: "No recordings yet")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, rec in
                        RecordingRow(recording: rec, recordingManager: recordingManager)
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
                 isEnabled: !playerManager.availableSubtitles.isEmpty) {
                ChannelViewModel.shared.triggerSelectionHaptic()
                withAnimation { showSubtitlePanel.toggle() }
            }
            pill(icon: isFavorited ? "star.fill" : "star", label: "Favorite",
                 isEnabled: true, tinted: isFavorited) {
                ChannelViewModel.shared.triggerSelectionHaptic()
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
        if playerManager.availableSubtitles.isEmpty { return "Subtitles" }
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

private struct PanelChannelRow: View {
    let channel: StreamChannel
    @ObservedObject var viewModel: ChannelViewModel
    let onPlay: () -> Void

    private var currentProg: EPGProgram? { viewModel.getCurrentProgram(for: channel) }

    var body: some View {
        Button(action: { ChannelViewModel.shared.triggerSelectionHaptic(); onPlay() }) {
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
                Button(action: record) {
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
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.leading, 18)

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
    }
}
