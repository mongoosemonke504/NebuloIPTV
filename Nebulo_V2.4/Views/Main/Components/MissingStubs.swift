import SwiftUI
import UIKit

private struct SearchBarGlass: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = Capsule()
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                .contentShape(shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                .contentShape(shape)
        }
    }
}

/// Full-screen search experience, matching the reference design:
///   • Empty query  → big "Search" title, circular ✕, "Browse" category grid
///   • Typing       → All / Channels / EPG / Recordings scope chips,
///                    "TOP RESULT" hero card, then section lists
///   • Search field pinned to the bottom, auto-focused so the keyboard and
///     the overlay rise together.
struct SearchView: View {
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color
    let playAction: (StreamChannel) -> Void
    let onCategorySelect: (StreamCategory) -> Void
    let onDismiss: () -> Void

    private enum Scope: String, CaseIterable {
        case all = "All", channels = "Channels", epg = "EPG", recordings = "Recordings"
    }

    @State private var scope: Scope = .all
    @FocusState private var fieldFocused: Bool

    /// Manual keyboard tracking. This overlay is presented inside MainView's
    /// `.ignoresSafeArea()` ZStack, which strips both the safe-area insets AND
    /// SwiftUI's automatic keyboard avoidance — so the view measures the
    /// device insets itself and pads the bottom search field by the keyboard
    /// frame reported by UIKit.
    @State private var keyboardHeight: CGFloat = 0

    // Same nebula palette as every other screen so search feels like part of
    // the app instead of a black sheet.
    @AppStorage("nebColor1") private var nebColor1 = "#1A2538"
    @AppStorage("nebColor2") private var nebColor2 = "#11101A"
    @AppStorage("nebColor3") private var nebColor3 = "#1F1A24"
    @AppStorage("nebX1") private var nebX1 = 0.5
    @AppStorage("nebY1") private var nebY1 = 0.0
    @AppStorage("nebX2") private var nebX2 = 0.5
    @AppStorage("nebY2") private var nebY2 = 0.5
    @AppStorage("nebX3") private var nebX3 = 0.5
    @AppStorage("nebY3") private var nebY3 = 1.0

    private var screenInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets ?? .zero
    }

    private var query: String {
        viewModel.searchText.trimmingCharacters(in: .whitespaces)
    }

    private var nameMatches: [StreamChannel] { viewModel.filteredNameChannels }
    private var epgMatches: [StreamChannel] { viewModel.filteredEPGChannels }

    /// Best hit shown in the TOP RESULT card — a live EPG match wins over a
    /// plain name match.
    private var topResult: (channel: StreamChannel, isLive: Bool)? {
        if let c = epgMatches.first { return (c, true) }
        if let c = nameMatches.first { return (c, false) }
        return nil
    }

    private var recordingMatches: [Recording] {
        guard !query.isEmpty else { return [] }
        return RecordingManager.shared.recordings.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ZStack {
            // Opaque nebula gradient (the Canvas paints solid black underneath
            // its blobs) — matches the rest of the app and guarantees the home
            // screen never shows through the overlay.
            NebulaBackgroundView(
                color1: Color(hex: nebColor1) ?? .purple,
                color2: Color(hex: nebColor2) ?? .blue,
                color3: Color(hex: nebColor3) ?? .pink,
                point1: UnitPoint(x: nebX1, y: nebY1),
                point2: UnitPoint(x: nebX2, y: nebY2),
                point3: UnitPoint(x: nebX3, y: nebY3)
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Status-bar spacer (safe area is zeroed by the ancestor).
                Color.clear.frame(height: screenInsets.top)

                if !query.isEmpty { scopeChips }
                titleRow

                ScrollView(showsIndicators: false) {
                    Group {
                        if query.isEmpty {
                            browseGrid
                        } else if viewModel.isSearching {
                            searchingSkeleton
                        } else {
                            resultsList
                        }
                    }
                    // Clearance for the floating search field below — results
                    // scroll behind its glass instead of stopping above it.
                    .padding(.bottom, 90)
                }
            }

            // The field floats OVER the scroll view (bottom-aligned ZStack)
            // so results pass behind its liquid glass while scrolling.
            VStack {
                Spacer()
                searchField
                    .padding(.bottom, keyboardHeight > 0 ? keyboardHeight + 8 : screenInsets.bottom + 8)
            }
        }
        .onAppear {
            fieldFocused = true
            // Focus set during the blurFade insertion can be dropped by
            // UIKit — re-assert shortly after so the keyboard always rises.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                fieldFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenH = UIScreen.main.bounds.height
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = max(0, screenH - frame.origin.y)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = 0 }
        }
    }

    // MARK: - Header

    private var titleRow: some View {
        HStack(alignment: .center) {
            Text("Search")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            if query.isEmpty {
                Button {
                    fieldFocused = false
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .modifier(GlassEffect(cornerRadius: 17, isSelected: false, accentColor: nil))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    fieldFocused = false
                    onDismiss()
                } label: {
                    Text("Cancel")
                        .font(.body)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var scopeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Scope.allCases, id: \.self) { s in
                    Button {
                        viewModel.triggerSelectionHaptic()
                        withAnimation(.easeOut(duration: 0.15)) { scope = s }
                    } label: {
                        Text(s.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(scope == s ? .black : .white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(
                                Capsule().fill(scope == s ? Color.white : Color.white.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 8)
    }

    // MARK: - Browse (empty query)

    private var browseGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Browse")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(viewModel.categories.filter { !$0.isHidden }) { cat in
                    Button {
                        viewModel.triggerSelectionHaptic()
                        onCategorySelect(cat)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                            Text(cat.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 19)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 20)
    }

    // MARK: - Results (typing)

    private var searchingSkeleton: some View {
        VStack(alignment: .leading, spacing: 16) {
            SkeletonBox(width: 100, height: 14)
            SkeletonBox(height: 88, cornerRadius: 20).frame(maxWidth: .infinity)
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 12) {
                    SkeletonBox(width: 44, height: 44, cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBox(width: 180, height: 14)
                        SkeletonBox(width: 120, height: 10)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 22) {
            if scope != .recordings, let top = topResult {
                VStack(alignment: .leading, spacing: 10) {
                    Text("TOP RESULT")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.8)
                    topResultCard(top.channel, isLive: top.isLive)
                }
            }

            if scope == .all || scope == .channels {
                let rows = nameMatches.filter { $0.id != topResult?.channel.id }
                if !rows.isEmpty {
                    section(title: "Channels", channels: rows)
                }
            }

            if scope == .all || scope == .epg {
                let rows = epgMatches.filter { $0.id != topResult?.channel.id }
                if !rows.isEmpty {
                    section(title: "On Now", channels: rows)
                }
            }

            if scope == .all || scope == .recordings {
                let recs = recordingMatches
                if !recs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recordings")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                        ForEach(recs) { rec in
                            HStack(spacing: 12) {
                                Image(systemName: "record.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.red)
                                    .frame(width: 44, height: 44)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rec.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(rec.channelName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
            }

            if topResult == nil && recordingMatches.isEmpty && viewModel.filteredCategories.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Results")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Try a different search term.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            }

            if scope == .all && !viewModel.filteredCategories.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Categories")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    ForEach(viewModel.filteredCategories) { cat in
                        Button {
                            viewModel.triggerSelectionHaptic()
                            onCategorySelect(cat)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "globe")
                                    .font(.title3)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .frame(width: 44, height: 44)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                                Text(cat.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    private func topResultCard(_ channel: StreamChannel, isLive: Bool) -> some View {
        Button {
            viewModel.triggerSelectionHaptic()
            playAction(channel)
        } label: {
            HStack(spacing: 14) {
                channelIcon(channel, size: 56, cornerRadius: 12)

                VStack(alignment: .leading, spacing: 4) {
                    if isLive, let program = viewModel.getCurrentProgram(for: channel) {
                        HStack(spacing: 6) {
                            Text("LIVE")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.red))
                            Text(program.title)
                                .font(.body.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                        }
                        Text("\(channel.name) · Live now")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text(channel.name)
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        if let program = viewModel.getCurrentProgram(for: channel) {
                            Text("Now: \(program.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    private func section(title: String, channels: [StreamChannel]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            ForEach(channels) { channel in
                Button {
                    viewModel.triggerSelectionHaptic()
                    playAction(channel)
                } label: {
                    HStack(spacing: 12) {
                        channelIcon(channel, size: 44, cornerRadius: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if let program = viewModel.getCurrentProgram(for: channel) {
                                Text("Now: \(program.title)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func channelIcon(_ channel: StreamChannel, size: CGFloat, cornerRadius: CGFloat) -> some View {
        if let icon = channel.icon, !icon.isEmpty {
            CachedAsyncImage(urlString: icon, size: CGSize(width: size, height: size))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.white.opacity(0.08)))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            Image(systemName: "tv")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.white.opacity(0.08)))
        }
    }

    // MARK: - Bottom search field

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Search", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .submitLabel(.search)
                    .focused($fieldFocused)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.triggerSelectionHaptic()
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .modifier(SearchBarGlass(cornerRadius: 100))
            // Tapping anywhere on the pill (icon, padding — not just the
            // text field itself) focuses the field and raises the keyboard.
            .onTapGesture { fieldFocused = true }

            if !viewModel.searchText.isEmpty {
                Button {
                    fieldFocused = false
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .modifier(GlassEffect(cornerRadius: 22, isSelected: false, accentColor: nil))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.searchText.isEmpty)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }
}

/// Search overlay used by MultiViewScreen to add streams — same UI as the
/// main SearchView, just with the multi-view call sites' signature.
struct SearchOverlayView: View {
    @ObservedObject var viewModel: ChannelViewModel
    @Binding var searchText: String
    let accentColor: Color
    let playAction: (StreamChannel) -> Void
    let onCategorySelect: (StreamCategory) -> Void
    let onDismiss: () -> Void

    var body: some View {
        SearchView(
            viewModel: viewModel,
            accentColor: accentColor,
            playAction: playAction,
            onCategorySelect: onCategorySelect,
            onDismiss: onDismiss
        )
    }
}
