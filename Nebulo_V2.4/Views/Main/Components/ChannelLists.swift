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
    @State private var channelForDescription: StreamChannel?
    /// Controlled by the "Channel Glow" slider in Settings → Appearance.
    @AppStorage("featuredGlowStrength") private var glowStrength = 0.5

    var body: some View {
        // UIScrollView wrapper from MainView — same fix as the chip row /
        // Live Now shelf. SwiftUI's `ScrollView(.horizontal)` leaves its pan
        // gesture in a tracking state after a swipe, which silently swallows
        // taps on this shelf and on the Quick Access panel beneath it.
        TouchPassingHorizontalScroll {
            HStack(spacing: 16) {
                ForEach(channels) { c in
                    Button(action: {
                        ChannelViewModel.shared.triggerSelectionHaptic()
                        playAction(c)
                    }) {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack {
                                // Blurred backdrop — opacity scales with glow setting
                                CachedAsyncImage(urlString: c.icon ?? "", size: CGSize(width: 200, height: 112))
                                    .blur(radius: 20)
                                    .opacity(0.08 + 0.92 * glowStrength)
                                    .clipped()
                                // Accent colour glow circle driven by glow setting
                                Circle()
                                    .fill(accentColor.opacity(min(1.0, 0.85 * glowStrength)))
                                    .frame(width: 100, height: 100)
                                    .blur(radius: 30)
                                CachedAsyncImage(urlString: c.icon ?? "", size: nil)
                                    .padding(16)
                            }
                            .frame(width: 200, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .modifier(GlassEffect(cornerRadius: 12, isSelected: false, accentColor: nil))
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                if let prog = viewModel.getCurrentProgram(for: c) {
                                    Text(prog.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text(" ")
                                        .font(.caption)
                                }
                            }
                            .frame(width: 192, height: 40, alignment: .topLeading) 
                            .padding(.horizontal, 4)
                        }
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
        .frame(height: 175) 
        .alert(item: $channelForDescription) { channel in
            Alert(
                title: Text("Program Description"),
                message: Text(viewModel.getCurrentProgram(for: channel)?.description ?? "No description available."),
                dismissButton: .default(Text("OK"))
            )
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

    var body: some View {
        Button(action: {
            ChannelViewModel.shared.triggerSelectionHaptic()
            playAction()
        }) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                    CachedAsyncImage(urlString: channel.icon ?? "", size: nil)
                        .padding(8)
                }
                .frame(width: logoSize, height: logoSize)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )

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
                                        .fill(Color.primary.opacity(0.08))
                                    Capsule()
                                        .fill(accentColor)
                                        .frame(width: geo.size.width * progress)
                                }
                            }
                            .frame(height: 2.5)
                            .padding(.top, 3)
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
                            .foregroundStyle(isFavorite ? accentColor : Color.primary.opacity(0.22))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)

                    if let label = timeLeftLabel {
                        Text(label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChannelRowButtonStyle())
        .frame(minHeight: isCompact ? 66 : 76)
        .frame(maxWidth: .infinity)
    }
}

private struct ChannelRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.white.opacity(configuration.isPressed ? 0.06 : 0)
                    .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            )
    }
}