import SwiftUI

struct HorizontalSearchList: View {
    let channels: [StreamChannel]
    let viewModel: ChannelViewModel
    let accentColor: Color
    let playAction: (StreamChannel) -> Void
    @State private var channelForDescription: StreamChannel?
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(channels) { c in
                        Button(action: { 
                            ChannelViewModel.shared.triggerSelectionHaptic()
                            playAction(c) 
                        }) {
                            SearchChannelContent(channel: c, viewModel: viewModel)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { playAction(c) } label: { Label("Play", systemImage: "play.fill") }
                            Button { viewModel.toggleFavorite(c.id) } label: { Label(viewModel.favoriteIDs.contains(c.id) ? "Unfavorite" : "Favorite", systemImage: viewModel.favoriteIDs.contains(c.id) ? "star.fill" : "star") }
                            Button { viewModel.triggerRenameChannel(c) } label: { Label("Rename", systemImage: "pencil") }
                            Button { viewModel.hideChannel(c.id) } label: { Label("Hide", systemImage: "eye.slash") }
                            if let prog = viewModel.getCurrentProgram(for: c), let desc = prog.description, !desc.isEmpty {
                                Button { channelForDescription = c } label: { Label("Description", systemImage: "text.alignleft") }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .frame(height: 170)
        .alert(item: $channelForDescription) { channel in
            Alert(
                title: Text("Program Description"),
                message: Text(viewModel.getCurrentProgram(for: channel)?.description ?? "No description available."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

struct SearchChannelContent: View {
    let channel: StreamChannel
    let viewModel: ChannelViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                CachedAsyncImage(urlString: channel.icon ?? "", size: CGSize(width: 180, height: 101))
                    .blur(radius: 20)
                    .opacity(0.3)
                    .clipped()
                CachedAsyncImage(urlString: channel.icon ?? "", size: nil)
                    .padding(14)
            }
            .frame(width: 180, height: 101)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .modifier(GlassEffect(cornerRadius: 12, isSelected: false, accentColor: nil))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let prog = viewModel.getCurrentProgram(for: channel) {
                    Text(prog.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 172, height: 50, alignment: .topLeading)
            .padding(.horizontal, 4)
        }
    }
}

struct HorizontalPreviewList: View {
    let channels: [StreamChannel]; let isRecent: Bool; let accentColor: Color; let viewModel: ChannelViewModel
    let playAction: (StreamChannel) -> Void; let promptRenameChannel: (StreamChannel) -> Void; let hideChannel: (Int) -> Void; let removeFromRecent: (Int) -> Void
    /// Tapping a card opens the channel preview popup (what's on, the guide
    /// and a Play button) rather than starting playback outright. The context
    /// menu's Play still goes straight to the stream.
    var onSelect: ((StreamChannel) -> Void)? = nil
    @State private var channelForDescription: StreamChannel?
    /// Controlled by the "Channel Glow" slider in Settings → Appearance.
    @AppStorage("featuredGlowStrength") private var glowStrength = 0.5

    var body: some View {
        // UIScrollView wrapper from MainView — same fix as the chip row /
        // Live Now shelf. SwiftUI's `ScrollView(.horizontal)` leaves its pan
        // gesture in a tracking state after a swipe, which silently swallows
        // taps on this shelf and on the Quick Access panel beneath it.
        TouchPassingHorizontalScroll {
            LazyHStack(spacing: 14) {
                ForEach(channels) { c in
                    Button(action: {
                        guard SwipeTapGuard.tapsAllowed else { return }
                        ChannelViewModel.shared.triggerSelectionHaptic()
                        (onSelect ?? playAction)(c)
                    }) {
                        // Nuvio continue-watching card: big 16:9 tile, the
                        // channel name overlaid bottom-left over a dark
                        // gradient, and the guide's time-remaining as the
                        // black "1h 48m left" badge top-right — nothing
                        // below the card, exactly like the reference.
                        ContinueWatchingCard(
                            channel: c,
                            program: viewModel.getCurrentProgram(for: c),
                            glowStrength: glowStrength
                        )
                    }.buttonStyle(.plain)
                    .contextMenu {
                        Button { playAction(c) } label: { Label("Play", systemImage: "play.fill") }
                        Button { viewModel.toggleFavorite(c.id) } label: { Label(viewModel.favoriteIDs.contains(c.id) ? "Unfavorite" : "Favorite", systemImage: viewModel.favoriteIDs.contains(c.id) ? "star.slash" : "star") }
                        Button { promptRenameChannel(c) } label: { Label("Rename", systemImage: "pencil") }
                        Button { hideChannel(c.id) } label: { Label("Hide", systemImage: "eye.slash") }
                        if isRecent { Button(role: .destructive) { removeFromRecent(c.id) } label: { Label("Remove", systemImage: "clock.badge.xmark") } }
                        if let prog = viewModel.getCurrentProgram(for: c), let desc = prog.description, !desc.isEmpty {
                            Button { channelForDescription = c } label: { Label("Description", systemImage: "text.alignleft") }
                        }
                    }
                }
            }.padding(.horizontal)
        }
        .frame(height: ContinueWatchingCard.cardHeight + 9)
        .alert(item: $channelForDescription) { channel in
            Alert(
                title: Text("Program Description"),
                message: Text(viewModel.getCurrentProgram(for: channel)?.description ?? "No description available."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

/// Nuvio continue-watching card — 16:9 tile filled SOLID with the logo's brand
/// tone, the sharp logo centred, the channel name overlaid bottom-left over a
/// dark gradient and the guide's remaining time as a black badge in the
/// top-right corner.
struct ContinueWatchingCard: View {
    /// Measured off the reference screenshot on the user's iPhone (1206px
    /// wide, 3x): the tile runs 50→610px with its neighbour starting at 640,
    /// i.e. 245pt wide, 170pt tall, 14pt apart.
    static let cardWidth: CGFloat = 245
    static let cardHeight: CGFloat = 170

    let channel: StreamChannel
    let program: EPGProgram?
    let glowStrength: Double
    /// Bumped when the colour lands in the shared cache; the colour itself is
    /// derived per render so a recycled view can't show a stale one.
    @State private var glowTick = 0

    private var fill: Color {
        _ = glowTick
        return LogoGlow.tone(for: channel.icon).map { NuvioTheme.card.mix(with: $0, by: 0.55 + 0.45 * glowStrength) }
            ?? NuvioTheme.card
    }

    private var timeLeftLabel: String? {
        guard let prog = program else { return nil }
        let remaining = prog.stop.timeIntervalSince(Date())
        guard remaining > 0 && remaining < 12 * 3600 else { return nil }
        let minutes = Int((remaining / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)m left" }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours)h left" : "\(hours)h \(mins)m left"
    }

    var body: some View {
        CachedAsyncImage(urlString: channel.icon ?? "", size: nil)
            .padding(26)
            // Room for the caption strip, so the logo stays centred in what's
            // left of the artwork rather than behind the frost.
            .padding(.bottom, 30)
            .frame(width: ContinueWatchingCard.cardWidth, height: ContinueWatchingCard.cardHeight)
            // Home screen card — carries Nuvio's glass rim.
            .nuvioCard(fill: fill, depth: true)
            // The reference's frosted caption: name over what's on, with the
            // time remaining on the trailing edge.
            .overlay(alignment: .bottom) {
                NuvioCardCaption(title: channel.name, subtitle: program?.title) {
                    if let label = timeLeftLabel {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .monospacedDigit()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: channel.icon) {
            guard let icon = channel.icon, LogoGlow.cache[icon] == nil else { return }
            _ = await LogoGlow.color(for: icon)
            glowTick += 1
        }
    }
}

/// One home shelf for a single category — the reference's "Popular - Movies"
/// row: underlined header whose tap/chevron opens the full catalog page,
/// over a horizontally scrolling shelf of the category's channels that play
/// directly in place. Long-press the header for category actions (rename,
/// colour), long-press a card for channel actions.
struct HomeCategoryShelf: View {
    let category: StreamCategory
    let channels: [StreamChannel]
    let viewModel: ChannelViewModel
    let playAction: (StreamChannel) -> Void
    /// Tapping a card opens the channel preview popup; the context menu's
    /// Play still starts the stream directly.
    var onSelect: ((StreamChannel) -> Void)? = nil
    let openCategory: () -> Void
    let promptRename: () -> Void

    @State private var channelForDescription: StreamChannel?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NuvioSectionHeader(title: category.name, showsChevron: true, action: openCategory)
                .contextMenu {
                    Button { promptRename() } label: { Label("Rename", systemImage: "pencil") }
                }

            // UIScrollView wrapper — same tap-lockout fix as the other
            // home shelves (see TouchPassingHorizontalScroll).
            TouchPassingHorizontalScroll {
                // Lazy: a shelf that scrolls into view builds only the cards
                // actually on screen, so entering a new category shelf never
                // costs a full row of logo art at once.
                LazyHStack(spacing: 10) {
                    ForEach(channels) { c in
                        Button {
                            guard SwipeTapGuard.tapsAllowed else { return }
                            ChannelViewModel.shared.triggerSelectionHaptic()
                            (onSelect ?? playAction)(c)
                        } label: {
                            HomeChannelShelfCard(
                                channel: c,
                                program: viewModel.getCurrentProgram(for: c)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { playAction(c) } label: { Label("Play", systemImage: "play.fill") }
                            Button { viewModel.toggleFavorite(c.id) } label: { Label(viewModel.favoriteIDs.contains(c.id) ? "Unfavorite" : "Favorite", systemImage: viewModel.favoriteIDs.contains(c.id) ? "star.slash" : "star") }
                            Button { viewModel.triggerRenameChannel(c) } label: { Label("Rename", systemImage: "pencil") }
                            Button { viewModel.hideChannel(c.id) } label: { Label("Hide", systemImage: "eye.slash") }
                            if let prog = viewModel.getCurrentProgram(for: c), let desc = prog.description, !desc.isEmpty {
                                Button { channelForDescription = c } label: { Label("Description", systemImage: "text.alignleft") }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: HorizontalChannelCardArt.cardHeight + 6)
        }
        .alert(item: $channelForDescription) { channel in
            Alert(
                title: Text("Program Description"),
                message: Text(viewModel.getCurrentProgram(for: channel)?.description ?? "No description available."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

/// Shelf card for one channel on a home category shelf — brand-tone artwork
/// with the name and what's on it now carried on the frosted strip across its
/// bottom, exactly the reference's card layout.
struct HomeChannelShelfCard: View {
    let channel: StreamChannel
    let program: EPGProgram?
    @AppStorage("featuredGlowStrength") private var glowStrength = 0.5

    var body: some View {
        // The name and what's on now live INSIDE the card, on the frosted
        // strip, instead of as loose text underneath it.
        HorizontalChannelCardArt(icon: channel.icon, glowStrength: glowStrength)
            .overlay(alignment: .bottom) {
                NuvioCardCaption(title: channel.name, subtitle: program?.title)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The artwork tile for a horizontal channel card: a SOLID slab of the logo's
/// own brand tone with the sharp logo centred on it. A channel has no poster
/// art, and the gradient-over-blurred-logo this replaced only tinted a strip
/// across the middle, leaving the rest near-black — a flat brand colour fills
/// the whole tile and gives each channel an unmistakable identity.
struct HorizontalChannelCardArt: View {
    let icon: String?
    let glowStrength: Double
    /// Bumped when the tone lands in the shared cache; the colour itself is
    /// derived per render so a recycled view can't show a stale one.
    @State private var glowTick = 0

    private var fill: Color {
        _ = glowTick
        return LogoGlow.tone(for: icon).map { NuvioTheme.card.mix(with: $0, by: 0.55 + 0.45 * glowStrength) }
            ?? NuvioTheme.card
    }

    /// Measured off the reference on the user's iPhone (1206px, 3x): the tiles
    /// run 218pt wide by 123pt tall — a true 16:9 — set 10pt apart.
    static let cardWidth: CGFloat = 218
    static let cardHeight: CGFloat = 123

    var body: some View {
        CachedAsyncImage(urlString: icon ?? "", size: nil)
            .padding(14)
            // Room for the caption strip, so the logo stays centred in what's
            // left of the artwork rather than behind the frost.
            .padding(.bottom, 26)
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            // Home screen card — carries Nuvio's glass rim.
            .nuvioCard(fill: fill, depth: true)
            .task(id: icon) {
                guard let icon, LogoGlow.cache[icon] == nil else { return }
                _ = await LogoGlow.color(for: icon)
                glowTick += 1
            }
    }
}

struct SquareCategoryCard: View { let title: String; let icon: String; let color: Color; let accentColor: Color; var body: some View { VStack(alignment: .center, spacing: 12) { Image(systemName: icon).font(.system(size: 40)).symbolRenderingMode(.hierarchical).foregroundColor(color); Text(title).font(.headline).fontWeight(.bold).foregroundStyle(.primary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).frame(height: 140).modifier(GlassEffect(cornerRadius: 16, isSelected: false, accentColor: accentColor)).overlay(RoundedRectangle(cornerRadius: 16).stroke(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)) } }
struct CategoryCard: View, Equatable { let title: String; var icon: String? = nil; var color: Color; var lineLimit: Int = 1; static func == (lhs: CategoryCard, rhs: CategoryCard) -> Bool { lhs.title == rhs.title && lhs.icon == rhs.icon && lhs.color == rhs.color }; var body: some View { HStack { if let icon = icon { Image(systemName: icon).symbolRenderingMode(.hierarchical).foregroundColor(color).frame(width: 30) }; Text(title).font(.headline).lineLimit(lineLimit).foregroundStyle(.primary); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }.padding().frame(maxWidth: .infinity).modifier(GlassEffect(cornerRadius: 12, isSelected: true, accentColor: nil)) } }

struct ChannelRow: View, Equatable {
    let channel: StreamChannel; let epgProgram: EPGProgram?; let isFavorite: Bool; let accentColor: Color; var isCompact: Bool = false; let playAction: () -> Void; let toggleFav: () -> Void

    static func == (lhs: ChannelRow, rhs: ChannelRow) -> Bool { lhs.channel == rhs.channel && lhs.isFavorite == rhs.isFavorite && lhs.accentColor == rhs.accentColor && lhs.isCompact == rhs.isCompact && lhs.epgProgram?.id == rhs.epgProgram?.id }

    private var logoSize: CGFloat { isCompact ? 46 : 56 }

    private var programProgress: Double? {
        guard let prog = epgProgram else { return nil }
        let total = prog.stop.timeIntervalSince(prog.start)
        guard total > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(prog.start)
        guard elapsed >= 0 && elapsed <= total else { return nil }
        return elapsed / total
    }

    @ViewBuilder
    private var starIcon: some View {
        if #available(iOS 17.0, *) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .contentTransition(.symbolEffect(.replace))
        } else {
            Image(systemName: isFavorite ? "star.fill" : "star")
        }
    }

    private var timeLeftLabel: String? {
        guard let prog = epgProgram else { return nil }
        let remaining = prog.stop.timeIntervalSince(Date())
        guard remaining > 0 && remaining < 12 * 3600 else { return nil }
        let minutes = Int((remaining / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }

    // Logo-derived colour — carries the channel's brand hue instead of a flat
    // accent, matching the featured/shelf cards: the solid tone fills the logo
    // tile, the brighter glow spills out behind it. Read from the shared cache
    // per render: List recycles these rows across channels, and view state
    // would keep a previous channel's colour for a frame.
    @State private var glowTick = 0
    private var glow: Color? {
        guard let icon = channel.icon, !icon.isEmpty else { return nil }
        _ = glowTick
        return LogoGlow.cache[icon]
    }
    private var tile: Color {
        _ = glowTick
        return LogoGlow.tone(for: channel.icon) ?? Color(white: 0.13)
    }

    var body: some View {
        Button(action: {
            // A horizontal filter/page swipe that passes over this row must not
            // also fire it — the page-swipe gestures open a short suppression
            // window that this tap honours.
            guard SwipeTapGuard.tapsAllowed else { return }
            ChannelViewModel.shared.triggerSelectionHaptic()
            playAction()
        }) {
            HStack(spacing: 14) {
                ZStack {
                    // Solid brand tone behind the logo; the plain hairline rim
                    // the rest of the app uses (the glass rim is home-only).
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tile)
                    CachedAsyncImage(urlString: channel.icon ?? "", size: nil)
                        .padding(8)
                }
                .frame(width: logoSize, height: logoSize)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                )
                // Soft brand-colour halo spilling out behind the logo tile.
                // A gradient, not a blur — see `SoftGlow`: this row is what
                // every category page scrolls, and a blur here was a filter
                // pass per visible row per frame.
                .background {
                    if let glow {
                        SoftGlow(color: glow, opacity: 0.5, radius: logoSize / 2 + 3, softness: 14)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name)
                        .font(isCompact ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if let prog = epgProgram {
                        Text(prog.title)
                            .font(isCompact ? .caption : .footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let progress = programProgress {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.12))
                                    // Live progress is always red — matching the
                                    // channel-tap preview's now-playing bar.
                                    Capsule()
                                        .fill(Color.red)
                                        .frame(width: geo.size.width * progress)
                                }
                            }
                            .frame(height: 3)
                            .padding(.top, 4)
                            .padding(.trailing, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 6) {
                    Button(action: toggleFav) {
                        starIcon
                            .font(.subheadline.weight(.semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(isFavorite ? .yellow : Color.primary.opacity(0.22))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)

                    if let label = timeLeftLabel {
                        Text(label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            // Each channel is now a distinct card rather than a bare list row.
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(NuvioTheme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChannelRowButtonStyle())
        .task(id: channel.icon) {
            guard let icon = channel.icon, LogoGlow.cache[icon] == nil else { return }
            _ = await LogoGlow.color(for: icon)
            glowTick += 1
        }
    }
}

private struct ChannelRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Visible pressed feedback: the card brightens and dips slightly so
            // a tap plainly registers.
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
/// Tap-through preview for a channel in the category lists: what's on now
/// (with live progress), the description, the channel's upcoming guide with
/// one-tap record bells, and the play button.
struct ChannelPreviewSheet: View {
    let channel: StreamChannel
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject private var recordingManager = RecordingManager.shared
    let accentColor: Color
    let playAction: (StreamChannel) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Bumped once the logo's tone lands in the shared cache — the sheet can be
    /// opened before any card has sampled this channel.
    @State private var glowTick = 0
    private var tile: Color {
        _ = glowTick
        return LogoGlow.tone(for: channel.icon) ?? Color(white: 0.13)
    }

    private var currentProgram: EPGProgram? {
        viewModel.getCurrentProgram(for: channel)
    }

    /// The channel's guide for the next two days, current program excluded.
    private var upcomingPrograms: [EPGProgram] {
        guard let epgID = channel.epgID,
              let schedule = viewModel.epgData[epgID] else { return [] }
        let now = Date()
        let limit = now.addingTimeInterval(48 * 3600)
        return schedule
            .filter { $0.stop > now && $0.start < limit && $0.id != currentProgram?.id }
            .sorted { $0.start < $1.start }
    }

    private var progress: Double? {
        guard let prog = currentProgram else { return nil }
        let total = prog.stop.timeIntervalSince(prog.start)
        guard total > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(prog.start)
        guard elapsed >= 0, elapsed <= total else { return nil }
        return elapsed / total
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return f
    }()

    private func rowTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? Self.timeFormatter.string(from: date)
            : Self.dayTimeFormatter.string(from: date)
    }

    private func isScheduled(_ prog: EPGProgram) -> Bool {
        recordingManager.recordings.contains {
            $0.channelName == channel.name
                && abs($0.startTime.timeIntervalSince(prog.start)) < 60
                && ($0.status == .scheduled || $0.status == .recording)
        }
    }

    /// The scheduled (not yet finished) recording matching a guide row.
    private func scheduledRecording(for prog: EPGProgram) -> Recording? {
        recordingManager.recordings.first {
            $0.channelName == channel.name
                && abs($0.startTime.timeIntervalSince(prog.start)) < 60
                && ($0.status == .scheduled || $0.status == .recording)
        }
    }

    /// Tap = arm, tap again = undo — no trip to the Recordings screen to
    /// cancel a bell you just set.
    private func toggleRecord(_ prog: EPGProgram) {
        if let existing = scheduledRecording(for: prog) {
            ChannelViewModel.shared.triggerHaptic(.light)
            recordingManager.deleteRecording(existing)
            return
        }
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

    var body: some View {
        ZStack {
            AppBackground().ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    // Channel identity
                    HStack(spacing: 14) {
                        ZStack {
                            // Same solid brand tone as the channel's cards.
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(tile)
                            CachedAsyncImage(urlString: channel.icon ?? "", size: nil)
                                .padding(10)
                        }
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(channel.name)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            if let prog = currentProgram {
                                HStack(spacing: 6) {
                                    Circle().fill(Color.red).frame(width: 6, height: 6)
                                    Text("\(Self.timeFormatter.string(from: prog.start)) \u{2013} \(Self.timeFormatter.string(from: prog.stop))")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                            }
                        }
                        Spacer()

                        Button {
                            viewModel.toggleFavorite(channel.id)
                        } label: {
                            Image(systemName: viewModel.favoriteIDs.contains(channel.id) ? "star.fill" : "star")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(viewModel.favoriteIDs.contains(channel.id) ? .yellow : .white.opacity(0.7))
                                .frame(width: 42, height: 42)
                                .background(Circle().fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }

                    // Now playing card
                    if let prog = currentProgram {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(prog.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            if let progress {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.12))
                                        Capsule().fill(Color.red)
                                            .frame(width: max(4, geo.size.width * progress))
                                    }
                                }
                                .frame(height: 4)
                            }

                            if let desc = prog.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                    } else {
                        Text("No guide information for this channel.")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }

                    // Upcoming guide with one-tap record bells.
                    if !upcomingPrograms.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("UPCOMING")
                                .font(.system(size: 11, weight: .black))
                                .kerning(1)
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.bottom, 8)

                            ForEach(Array(upcomingPrograms.enumerated()), id: \.element.id) { index, prog in
                                let scheduled = isScheduled(prog)
                                HStack(spacing: 12) {
                                    Text(rowTime(prog.start))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .lineLimit(1)
                                        .fixedSize()
                                        .frame(minWidth: 70, alignment: .leading)
                                    Text(prog.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Button {
                                        toggleRecord(prog)
                                    } label: {
                                        Image(systemName: scheduled ? "checkmark.circle.fill" : "record.circle")
                                            .font(.system(size: 17, weight: .semibold))
                                            .foregroundStyle(scheduled ? .green : .white.opacity(0.65))
                                            .frame(width: 34, height: 34)
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 6)
                                if index < upcomingPrograms.count - 1 {
                                    Divider().background(Color.white.opacity(0.06))
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                    }
                }
                .padding(20)
                .padding(.bottom, 80)
            }
        }
        // Play floats over the scrolling guide, always reachable.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                ChannelViewModel.shared.triggerHaptic(.medium)
                dismiss()
                playAction(channel)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: channel.icon) {
            guard let icon = channel.icon, LogoGlow.cache[icon] == nil else { return }
            _ = await LogoGlow.color(for: icon)
            glowTick += 1
        }
    }
}

// MARK: - Favorite teams shelf

/// One favourited team or league on the home screen, shaped like the
/// reference's Top 10 poster tiles: a portrait card filled with the club's own
/// colour, the crest centred on it, and the name captioned across the bottom.
///
/// Measured off the reference screenshot on the user's iPhone (1206px, 3x):
/// the tiles run 99pt wide by 153pt tall, 16pt apart.
struct FavoriteBadge: View {
    let logo: String?
    let name: String
    /// Brand colour hex (team), or nil for leagues, which get charcoal.
    let colorHex: String?
    let action: () -> Void

    static let cardWidth: CGFloat = 99
    static let cardHeight: CGFloat = 153

    /// Stand-in for a missing crest: the first letters of the name, on the
    /// team's own colour.
    private var initialsTile: some View {
        Text(Self.initials(from: name))
            .font(.system(size: 22, weight: .black))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .frame(width: 58, height: 58)
            .background(Circle().fill(fill.opacity(0.9)))
            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
    }

    private static func initials(from name: String) -> String {
        let letters = name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    /// Flipped once the crest has been sampled — see `fill`.
    @State private var crestSampled = false

    /// The club's colour, pushed lighter or darker when its own crest would
    /// vanish on it — the Longhorns' burnt orange on burnt orange was an
    /// empty card. See `LogoGlow.field`.
    private var fill: Color {
        _ = crestSampled
        if let adjusted = LogoGlow.field(hex: colorHex, forLogo: logo) { return adjusted }
        guard let hex = colorHex, !hex.isEmpty,
              let c = Color(hex: hex.hasPrefix("#") ? hex : "#\(hex)") else {
            return Color(white: 0.15)
        }
        return c
    }

    var body: some View {
        Button(action: {
            guard SwipeTapGuard.tapsAllowed else { return }
            ChannelViewModel.shared.triggerSelectionHaptic()
            action()
        }) {
            ZStack(alignment: .bottom) {
                Group {
                    if let logo, !logo.isEmpty {
                        CachedAsyncImage(urlString: logo,
                                         size: CGSize(width: 58, height: 58),
                                         failurePlaceholder: AnyView(initialsTile))
                    } else {
                        // No crest to draw. Without this the tile was empty
                        // apart from its caption — a favourite that looked as
                        // though it had never been added. A team always has
                        // initials, and they go on its own colour.
                        initialsTile
                    }
                }
                .padding(20)
                .frame(width: Self.cardWidth, height: Self.cardHeight)
                // Lifted clear of the caption, the way the reference's
                // poster art sits above its genre line.
                .offset(y: -10)

                // Legibility wash under the caption, so a pale kit colour
                // can't swallow the name.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.45),
                        .init(color: .black.opacity(0.70), location: 1.0)
                    ],
                    startPoint: .top, endPoint: .bottom
                )

                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
            }
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(PressableCardStyle())
        .samplesCrests(colorHex == nil ? [] : [logo], flag: $crestSampled)
    }
}

/// The home screen's "My Teams" shelf — every favourited team and league as a
/// round crest, in the user's own order.
struct FavoriteTeamsShelf: View {
    let teams: [(team: ESPNTeam, sport: SportType?, leagueLabel: String?)]
    let leagues: [(sport: SportType, leagueLabel: String?, displayName: String)]
    let onTeam: (ESPNTeam, SportType?, String?) -> Void
    let onLeague: (SportType, String?, String) -> Void

    /// One tile, with an id that is unique across the WHOLE row.
    ///
    /// This is why a favourite kept going missing here. The row was two
    /// `ForEach`s over `enumerated()`, each keyed by `\.offset` — so the first
    /// league and the first team both had identity `0` inside one lazy stack,
    /// and SwiftUI drew one of them. Whichever list came second lost: teams
    /// first meant the leagues disappeared, leagues first meant the teams did.
    /// Prefixing the kind makes every tile distinct.
    private struct Badge: Identifiable {
        let id: String
        let logo: String?
        let name: String
        let colorHex: String?
        let open: () -> Void
    }

    private var badges: [Badge] {
        // Leagues lead: there are only ever a handful, and with the teams ahead
        // of them they sat off the right-hand edge of a row nobody scrolls.
        let leagueBadges = leagues.enumerated().map { index, item in
            Badge(id: "league-\(index)-\(item.sport.rawValue)-\(item.leagueLabel ?? "")",
                  logo: LeagueLogoURL.url(sport: item.sport, leagueLabel: item.leagueLabel),
                  name: item.displayName,
                  colorHex: nil,
                  open: { onLeague(item.sport, item.leagueLabel, item.displayName) })
        }
        let teamBadges = teams.enumerated().map { index, item in
            Badge(id: "team-\(index)-\(item.team.id)",
                  logo: item.team.logo,
                  // A favourite whose catalog entry has not arrived yet has no
                  // name of its own; its sport stands in until it does.
                  name: item.team.shortDisplayName
                      ?? item.team.displayName
                      ?? item.sport?.rawValue
                      ?? "Team",
                  colorHex: item.team.color,
                  open: { onTeam(item.team, item.sport, item.leagueLabel) })
        }
        return leagueBadges + teamBadges
    }

    var body: some View {
        TouchPassingHorizontalScroll {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(badges) { badge in
                    FavoriteBadge(logo: badge.logo,
                                  name: badge.name,
                                  colorHex: badge.colorHex,
                                  action: badge.open)
                }
            }
            .padding(.horizontal)
        }
        .frame(height: FavoriteBadge.cardHeight + 6)
    }
}

// MARK: - Spotlight shelf

/// One of the playlist's best-known channels as the reference's big editorial
/// tile: a near-full-width portrait card carrying a PHOTO of whatever is on
/// right now — the still the guide ships with the programme — then the status
/// badge, the programme title and a dot-separated line along the bottom.
///
/// Without a guide still there's nothing photographic to show, so the card
/// falls back to the channel's brand tone with its logo floating over it.
///
/// Measured off the reference screenshot on the user's iPhone (1206px, 3x):
/// 357pt wide by 454pt tall with a 22pt peek either side.
struct SpotlightCard: View {
    let channel: StreamChannel
    let program: EPGProgram?
    let categoryName: String?
    let action: () -> Void

    static var cardWidth: CGFloat { UIScreen.main.bounds.width - 44 }
    static let cardHeight: CGFloat = 454

    /// Bumped when the tone lands in the shared cache; derived per render so a
    /// recycled card can't paint the previous channel's colour.
    @State private var glowTick = 0
    private var fill: Color {
        _ = glowTick
        return LogoGlow.tone(for: channel.icon) ?? NuvioTheme.card
    }

    /// Artwork found for the programme title when the guide shipped no still.
    @State private var fetchedArt: String?

    private var still: String? {
        if let image = program?.image, !image.isEmpty { return image }
        return fetchedArt
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    /// "ON NOW" while a programme is running, otherwise when it starts.
    private var badgeText: String {
        guard let program else { return "LIVE" }
        return program.start <= Date() ? "ON NOW" : "AT \(Self.timeFmt.string(from: program.start))"
    }

    private var metadataParts: [String] {
        var parts = [channel.name]
        if let categoryName, !categoryName.isEmpty { parts.append(categoryName) }
        return parts
    }

    var body: some View {
        Button(action: {
            guard SwipeTapGuard.tapsAllowed else { return }
            ChannelViewModel.shared.triggerSelectionHaptic()
            action()
        }) {
            ZStack(alignment: .bottomLeading) {
                if let still {
                    // The guide's own still, cropped to fill the WHOLE card —
                    // and decoded at card size, because the shared 300x300
                    // default would be upscaled 3x here and look soft.
                    CachedAsyncImage(urlString: still,
                                     size: CGSize(width: Self.cardWidth, height: Self.cardHeight),
                                     contentMode: .fill,
                                     decodeSize: CGSize(width: Self.cardWidth, height: Self.cardHeight))
                        .frame(width: Self.cardWidth, height: Self.cardHeight)
                        .clipped()
                } else {
                    CachedAsyncImage(urlString: channel.icon ?? "", size: nil)
                        .frame(maxWidth: 190, maxHeight: 190)
                        .frame(width: Self.cardWidth, height: Self.cardHeight)
                        .offset(y: -Self.cardHeight * 0.14)
                }

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.40),
                        .init(color: .black.opacity(0.55), location: 0.70),
                        .init(color: .black.opacity(0.90), location: 1.0)
                    ],
                    startPoint: .top, endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text(badgeText)
                        .font(.system(size: 11, weight: .black))
                        .kerning(0.5)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.55)))

                    Text(program?.title ?? channel.name)
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 2)

                    NuvioMetadataLine(parts: metadataParts)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
            }
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(PressableCardStyle())
        .task(id: channel.icon) {
            guard let icon = channel.icon, LogoGlow.cache[icon] == nil else { return }
            _ = await LogoGlow.color(for: icon)
            glowTick += 1
        }
        // Only when the guide gave us nothing: look the programme up. Results
        // (including misses) are cached on disk, so this is one request per
        // title ever, and the card shows its brand treatment until it lands.
        .task(id: program?.title) {
            fetchedArt = nil
            guard let title = program?.title, !title.isEmpty,
                  (program?.image ?? "").isEmpty else { return }
            fetchedArt = await ProgramArtworkService.shared.artwork(for: title)
        }
    }
}

/// The big-card row. SwiftUI's own ScrollView here rather than the app's
/// UIScrollView wrapper, because only it can SNAP card-to-card the way the
/// reference does — `.scrollTargetBehavior(.viewAligned)`. Taps are still
/// protected by SwipeTapGuard, which is what the wrapper was there for.
struct SpotlightShelf: View {
    let items: [SpotlightItem]
    let viewModel: ChannelViewModel
    let onSelect: (StreamChannel) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(items) { item in
                    SpotlightCard(
                        channel: item.channel,
                        program: item.program,
                        categoryName: viewModel.categories.first(where: { $0.id == item.channel.categoryID })?.name
                    ) {
                        onSelect(item.channel)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 22)
        }
        .scrollTargetBehavior(.viewAligned)
        .frame(height: SpotlightCard.cardHeight + 6)
    }
}

/// A well-known channel and whatever it is showing.
struct SpotlightItem: Identifiable {
    let channel: StreamChannel
    let program: EPGProgram?
    var id: Int { channel.id }
}

// MARK: - Follow a team or league straight from search

/// One "follow this team / league" row in the search results.
///
/// Searching is how people look for a team — typing "Arsenal" to find the
/// match that's on is the same gesture as wanting to follow Arsenal — so the
/// results offer that directly, rather than sending the user off to Favorites
/// to search the catalog a second time.
///
/// Shaped like the Channels and Categories rows beside it: a 44pt square
/// mark, two lines of text, and a trailing control.
struct SearchFavoritableRow: View {
    let hit: ScoreViewModel.FavoritableHit
    /// Observed HERE, by the row, not by the search screen. The screen holds
    /// the model without watching it — a score refresh must not rebuild the
    /// search page — so it never re-rendered its rows when a favourite
    /// changed: a tap saved the team and showed nothing, which read as the
    /// tap not registering. Each row watches for itself, the way the game
    /// card's reminder bell does.
    @ObservedObject var scoreViewModel: ScoreViewModel
    /// Bumped on a FOLLOW, so the heart bounces in; letting go gets the
    /// plain swap back to the plus.
    @State private var followPulse = 0

    var body: some View {
        let isFavorite = scoreViewModel.isFavorite(hit)
        Button {
            guard SwipeTapGuard.tapsAllowed else { return }
            if !isFavorite { followPulse += 1 }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                scoreViewModel.toggleFavorite(hit)
            }
        } label: {
            HStack(spacing: 12) {
                FavoriteSquareLogo(
                    logo: hit.logo,
                    abbreviation: hit.displayName,
                    color: hit.color
                )
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(isFavorite ? "Following · \(hit.subtitle)" : hit.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }

                Spacer()

                Image(systemName: isFavorite ? "heart.fill" : "plus.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isFavorite ? Color.pink : Color.white.opacity(0.7))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: followPulse)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
