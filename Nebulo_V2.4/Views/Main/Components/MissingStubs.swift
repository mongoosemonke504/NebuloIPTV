import SwiftUI
import UIKit

/// Pre-warms the keyboard for the search overlay. UIKit defers a keyboard
/// requested from INSIDE a view-controller transition until that transition
/// finishes — which made the keyboard trail the cover's slide-up. A hidden
/// text field in the MAIN hierarchy becomes first responder the instant the
/// search pill is tapped, so the keyboard rises WITH the cover; SearchView
/// steals focus once it lands and the keyboard simply stays up.
@MainActor
final class KeyboardSummoner {
    static let shared = KeyboardSummoner()
    weak var field: UITextField?
    /// True only during the one-time launch warm below. Outside it the
    /// pre-warm field can never become first responder, so UIKit's habit of
    /// restoring the presenting hierarchy's first responder after a cover
    /// dismisses can't resurface the keyboard behind the user's back.
    private(set) var armed = false
    private var didWarmProcess = false

    /// One-time silent become+resign in the same runloop pass. The system
    /// keyboard process loads lazily, so the FIRST becomeFirstResponder of a
    /// session stalls for a beat before the rise animation even starts —
    /// this spins it up at launch so the search field's first real focus is
    /// as instant as every later one. Back-to-back become/resign never
    /// shows the keyboard.
    func warmProcessIfNeeded() {
        guard !didWarmProcess, let field, field.window != nil else { return }
        didWarmProcess = true
        armed = true
        field.becomeFirstResponder()
        field.resignFirstResponder()
        armed = false
    }
}

struct KeyboardPrewarmField: UIViewRepresentable {
    final class PrewarmTextField: UITextField {
        override var canBecomeFirstResponder: Bool { KeyboardSummoner.shared.armed }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // Deferred a tick: becomeFirstResponder mid-layout is ignored.
            DispatchQueue.main.async { KeyboardSummoner.shared.warmProcessIfNeeded() }
        }
    }
    func makeUIView(context: Context) -> UITextField {
        let tf = PrewarmTextField(frame: .zero)
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        KeyboardSummoner.shared.field = tf
        return tf
    }
    func updateUIView(_ uiView: UITextField, context: Context) {}
}

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
    /// Optional so the multi-view search overlay can omit it. When present, the
    /// empty-query screen surfaces live games and recent channels.
    var scoreViewModel: ScoreViewModel? = nil
    let accentColor: Color
    let playAction: (StreamChannel) -> Void
    let onCategorySelect: (StreamCategory) -> Void
    let onDismiss: () -> Void

    private enum Scope: String, CaseIterable {
        case all = "All", channels = "Channels", epg = "EPG", recordings = "Recordings"
    }

    @State private var scope: Scope = .all
    @FocusState private var fieldFocused: Bool

    /// Local mirror of the query. The TextField binds HERE so keystrokes only
    /// re-render this overlay — binding straight to viewModel.searchText
    /// published the whole ChannelViewModel on every keystroke, re-rendering
    /// the entire home screen behind the overlay and making typing crawl.
    /// The debounced push below hands the query to the view model.
    @State private var queryText = ""
    @State private var pushTask: Task<Void, Never>? = nil
    /// True between a keystroke and the debounced hand-off, so the results
    /// area shows the skeleton instead of flashing the browse content.
    @State private var pushPending = false

    /// One scope switch per drag — set mid-drag, cleared on finger-lift.
    @State private var scopeSwipeConsumed = false

    /// Browse content (live games, recents, categories) lands one runloop
    /// tick after the overlay: the first frame (nebula + title + field)
    /// presents instantly, and the heavy shelves join on the next frame —
    /// early enough that the user never registers them as missing, late
    /// enough that their build can't hold the whole presentation hostage.
    @State private var browseReady = false

    /// 0 at rest, 1 once the big "Search" title has scrolled away — same
    /// compact mode as the Sports/Favorites hubs. Drives the big title's
    /// fade-out and the compact chrome-row title's fade-in. Held in its own
    /// object so scrolling doesn't re-render the whole overlay every frame.
    @State private var titleProgress = ScrollProgress()

    /// Settings sheet presented from the chrome row's gear — over the search
    /// cover, so closing settings lands back in search, exactly like the
    /// gear in the Sports/Favorites sections keeps you in the section.
    @State private var showSettings = false

    /// The probe's reading at rest. The chrome rides as a top safe-area
    /// inset, so the content's resting minY equals the inset height rather
    /// than 0 — progress is measured relative to this baseline.
    @State private var probeRestY: CGFloat? = nil

    /// One dismissal per rubber-band pull — reset once the scroll returns
    /// near rest so a long bounce can't fire twice.
    @State private var pullDismissFired = ValueBox(false)

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
        queryText.trimmingCharacters(in: .whitespaces)
    }

    /// Debounced hand-off: typing mutates only local state; the view model
    /// (and its whole observer tree) hears about it once, 250 ms after the
    /// last keystroke. Clearing pushes through immediately so the browse
    /// content snaps back without a dead beat.
    private func scheduleSearchPush(_ text: String) {
        pushTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            pushPending = false
            if !viewModel.searchText.isEmpty { viewModel.searchText = "" }
            return
        }
        pushPending = true
        pushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            viewModel.searchText = text
            pushPending = false
        }
    }

    private func advanceScope(_ delta: Int) {
        let all = Scope.allCases
        guard let idx = all.firstIndex(of: scope) else { return }
        let next = idx + delta
        guard all.indices.contains(next) else { return }
        viewModel.triggerSelectionHaptic()
        withAnimation(.easeOut(duration: 0.15)) { scope = all[next] }
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
            // screen never shows through the overlay. Deliberately OUTSIDE
            // the rising/fading group below: it's visible from the very
            // first frame, so the cover never flashes black even if the
            // first-ever open hits a slow frame.
            NebulaBackgroundView(
                color1: Color(hex: nebColor1) ?? .purple,
                color2: Color(hex: nebColor2) ?? .blue,
                color3: Color(hex: nebColor3) ?? .pink,
                point1: UnitPoint(x: nebX1, y: nebY1),
                point2: UnitPoint(x: nebX2, y: nebY2),
                point3: UnitPoint(x: nebX3, y: nebY3)
            )
            .ignoresSafeArea()

            ZStack {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                    // The big title is scroll CONTENT — same compact mode as
                    // the Sports/Favorites hubs: it physically scrolls away
                    // with the page while the small title in the chrome row
                    // above crossfades in over the same distance.
                    bigTitle
                        .scrollProgressOpacity(titleProgress) { 1 - Double($0) }
                        .background(ScrollOffsetProbe(space: "searchScroll", id: "search"))

                    Group {
                        if query.isEmpty {
                            if browseReady {
                                VStack(alignment: .leading, spacing: 26) {
                                    liveGamesSection
                                    recentChannelsSection
                                    browseGrid
                                }
                            }
                        } else if pushPending || viewModel.isSearching {
                            searchingSkeleton
                        } else {
                            resultsList
                        }
                    }
                    // Explicit full width: content inserted while another
                    // layout transaction is animating (keyboard rise) was
                    // getting laid out narrow and visibly growing to full
                    // width — the "cover sliding away" on open.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Clearance for the floating search field below — results
                    // scroll behind its glass instead of stopping above it.
                    .padding(.bottom, 90)
                    }
                }
                .coordinateSpace(name: "searchScroll")
                .frame(maxWidth: .infinity)
                // Pull-past-top to close, like dragging a sheet down: once
                // the rubber-band overscroll passes 70pts the overlay
                // dismisses. Latched so one long bounce fires exactly once.
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, scrolled in
                    if scrolled >= -5 {
                        pullDismissFired.value = false
                    } else if scrolled < -70, !pullDismissFired.value {
                        pullDismissFired.value = true
                        viewModel.triggerSelectionHaptic()
                        fieldFocused = false
                        onDismiss()
                    }
                }
                // Horizontal swipe on the results area steps through the
                // scope chips (All → Channels → EPG → Recordings), matching
                // the Sports and Favorites sections. Fires mid-drag for an
                // instant response; simultaneousGesture so vertical
                // scrolling keeps working.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 25)
                        .onChanged { value in
                            guard !scopeSwipeConsumed, !query.isEmpty else { return }
                            let h = value.translation.width
                            let v = value.translation.height
                            guard abs(h) > 50, abs(h) > abs(v) * 1.5,
                                  !HorizontalScrollActivity.isActive else { return }
                            scopeSwipeConsumed = true
                            advanceScope(h < 0 ? 1 : -1)
                        }
                        .onEnded { _ in scopeSwipeConsumed = false }
                )
                // Chrome rides as a top inset OVER the scroll: content
                // scrolls UNDER the Back pill, gear and chips with nothing
                // drawn behind them — totally translucent, like the other
                // sections — instead of clipping against a solid strip.
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Status-bar spacer (safe area is zeroed by the ancestor).
                        Color.clear.frame(height: screenInsets.top)
                        chromeRow
                        if !query.isEmpty { scopeChips }
                    }
                }

            // The field floats OVER the scroll view (bottom-aligned ZStack)
            // so results pass behind its liquid glass while scrolling.
            // Scoped animation: only this container animates with keyboard
            // frame changes.
            VStack {
                Spacer()
                searchField
                    .padding(.bottom, keyboardHeight > 0 ? keyboardHeight + 8 : screenInsets.bottom + 8)
            }
            .animation(.easeOut(duration: 0.2), value: keyboardHeight)
            }
        }
        .onAppear {
            queryText = viewModel.searchText
            // The heavy browse shelves join one frame after the cover so
            // their build can never stall the presentation itself.
            DispatchQueue.main.async {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { browseReady = true }
            }
            // The cover snaps in with no transition, so there is nothing for
            // UIKit to defer the keyboard behind — focusing on the next tick
            // starts the keyboard rise the instant the section is on screen.
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChangeCompat(of: queryText) { newValue in
            scheduleSearchPush(newValue)
        }
        // The probe on the big title reports its offset in the scroll's
        // coordinate space; 40pt of scroll completes the title crossfade —
        // the same ramp the Sports and Favorites hubs use. Measured against
        // the resting baseline because the chrome inset shifts the origin.
        .onPreferenceChange(SectionScrollOffsetsKey.self) { offsets in
            guard let y = offsets["search"] else { return }
            if probeRestY == nil { probeRestY = y }
            titleProgress.set(min(max(((probeRestY ?? y) - y) / 40, 0), 1))
        }
        // Keyboard height set WITHOUT withAnimation — the transaction leaked
        // into unrelated layout (see browseReady note). The scoped .animation
        // on the field container below animates just the field's rise.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenH = UIScreen.main.bounds.height
            keyboardHeight = max(0, screenH - frame.origin.y)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .sheet(isPresented: $showSettings) {
            if let svm = scoreViewModel {
                SettingsView(
                    categories: Binding(
                        get: { viewModel.categories },
                        set: { viewModel.categories = $0 }
                    ),
                    accentColor: accentColor,
                    viewModel: viewModel,
                    scoreViewModel: svm,
                    playAction: playAction,
                    onSave: { viewModel.saveCategorySettings() }
                )
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Header

    /// Fixed chrome row, IDENTICAL to the Sports/Favorites sections: Back
    /// pill on the leading edge, settings gear trailing, and the compact
    /// "Search" title crossfading in between them as the big in-scroll
    /// title departs — pure opacity, no layout shift.
    private var chromeRow: some View {
        HStack {
            Button {
                fieldFocused = false
                onDismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                    Text("Back")
                        .font(.body)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .modifier(GlassEffect(cornerRadius: 22, isSelected: false, accentColor: nil))
            }
            .buttonStyle(.plain)
            Spacer()
            if scoreViewModel != nil {
                SettingsGearButton {
                    viewModel.triggerSelectionHaptic()
                    fieldFocused = false
                    showSettings = true
                }
            }
        }
        .overlay {
            Text("Search")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 80)
                .scrollProgressOpacity(titleProgress) { Double($0) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var bigTitle: some View {
        Text("Search")
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 2)
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

    // MARK: - Live games (empty query)

    /// Live sports happening right now — the most time-sensitive thing to
    /// surface when the user opens search. Tapping resolves the best stream
    /// (same smart-search the Sports hub uses) and closes the overlay.
    @ViewBuilder
    private var liveGamesSection: some View {
        if let svm = scoreViewModel {
            let games = Array(svm.allLiveGames.prefix(12))
            if !games.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    // No leading dot — the title must line up flush with the
                    // "Recently Watched" header below it; the red count badge
                    // already reads as live.
                    HStack(spacing: 8) {
                        Text("Live Now")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("\(svm.allLiveGames.count)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red))
                    }
                    .padding(.horizontal, 20)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(games) { game in
                                LiveGameCard(game: game, accentColor: accentColor)
                                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .onTapGesture {
                                        viewModel.triggerSelectionHaptic()
                                        let h = game.homeCompetitor?.team?.shortDisplayName ?? game.homeCompetitor?.athlete?.shortName ?? ""
                                        let a = game.awayCompetitor?.team?.shortDisplayName ?? game.awayCompetitor?.athlete?.shortName ?? ""
                                        fieldFocused = false
                                        onDismiss()
                                        viewModel.runSmartSearch(gameID: game.id, home: h, away: a, sport: svm.sportType(for: game), network: game.broadcastName)
                                    }
                                    .liveGameContextMenu(game: game, viewModel: viewModel, scoreViewModel: svm, beforeNavigate: {
                                        fieldFocused = false
                                        onDismiss()
                                    })
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
        }
    }

    /// Recently-watched channels — a one-tap way back into what you were
    /// watching, without typing.
    @ViewBuilder
    private var recentChannelsSection: some View {
        let recents = viewModel.recentIDs.prefix(12).compactMap { id in
            viewModel.channels.first(where: { $0.id == id })
        }
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recently Watched")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(recents) { channel in
                            Button {
                                viewModel.triggerSelectionHaptic()
                                fieldFocused = false
                                playAction(channel)
                            } label: {
                                VStack(spacing: 8) {
                                    recentTile(channel)
                                    Text(channel.name)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .lineLimit(1)
                                        .frame(width: 84)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    /// A single recently-watched channel tile: the logo centred on a soft
    /// rounded card with a hairline border and a gentle top-lit gradient, so
    /// the crest reads cleanly instead of floating on a flat grey square.
    private func recentTile(_ channel: StreamChannel) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.55))
            if let icon = channel.icon, !icon.isEmpty {
                CachedAsyncImage(urlString: icon, size: CGSize(width: 84, height: 84))
                    .padding(12)
            } else {
                Image(systemName: "tv")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
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
                TextField("Search", text: $queryText)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .submitLabel(.search)
                    .focused($fieldFocused)
                if !queryText.isEmpty {
                    Button {
                        viewModel.triggerSelectionHaptic()
                        queryText = ""
                        pushTask?.cancel()
                        pushPending = false
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

            if !queryText.isEmpty {
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
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: queryText.isEmpty)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .contentShape(Rectangle())
        .onTapGesture { fieldFocused = true }
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
