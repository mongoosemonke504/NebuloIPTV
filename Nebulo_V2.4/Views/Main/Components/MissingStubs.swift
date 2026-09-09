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

/// The Search SECTION, matching the reference design:
///   • Giant heavy "Search" title; the field itself lives in the app's
///     bottom bar (it morphs out of the dock), bound in via `queryText`.
///   • Empty query  → live games, recents, Browse grid
///   • Typing       → All / Channels / EPG / Recordings scope chips,
///                    "TOP RESULT" hero card, then section lists
struct SearchView: View {
    @ObservedObject var viewModel: ChannelViewModel
    /// Optional so the multi-view search overlay can omit it. When present, the
    /// empty-query screen surfaces live games and recent channels.
    var scoreViewModel: ScoreViewModel? = nil
    let accentColor: Color
    /// The query, owned by whoever renders the field (the main bottom bar,
    /// or the multi-view overlay's own field).
    @Binding var queryText: String
    let playAction: (StreamChannel) -> Void
    let onCategorySelect: (StreamCategory) -> Void
    let onDismiss: () -> Void
    /// Multi-view overlay: shows a circular ✕ in the chrome row.
    var showsCloseButton: Bool = false

    private enum Scope: String, CaseIterable {
        case all = "All", channels = "Channels", epg = "EPG",
             categories = "Categories", teams = "Teams", recordings = "Recordings"
    }

    @State private var scope: Scope = .all

    /// Teams and leagues whose names match the query, offered for one-tap
    /// following. Ranked in a `.task(id:)` rather than in the body, so typing
    /// never runs the catalog scan mid-render.
    @State private var favoritableHits: [ScoreViewModel.FavoritableHit] = []
    /// True when what was typed IS a team or league name rather than merely
    /// touching one — "arse" → Arsenal leads the results; "sports" → the
    /// channels lead and the follow rows sit below them.
    @State private var favoritableLeads = false

    private func rankFavoritables() {
        guard let svm = scoreViewModel else {
            favoritableHits = []
            favoritableLeads = false
            return
        }
        let needle = query.lowercased()
        // Ranked deep once; the All scope shows only the head of the list and
        // the Teams chip shows the rest, so switching scopes never re-ranks.
        let hits = svm.favoritableMatches(for: needle, limit: 30)
        favoritableHits = hits
        favoritableLeads = !needle.isEmpty
            && (hits.first?.displayName.lowercased().hasPrefix(needle) ?? false)
    }

    @State private var pushTask: Task<Void, Never>? = nil
    /// True between a keystroke and the debounced hand-off, so the results
    /// area shows the skeleton instead of flashing the browse content.
    @State private var pushPending = false

    /// One scope switch per drag — set mid-drag, cleared on finger-lift.
    @State private var scopeSwipeConsumed = false

    /// Direction of the current scope change, so the results slide in from the
    /// correct edge — same directional slide as the Sports/Favorites hubs.
    @State private var scopeSlideFromTrailing = true

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

    /// The probe's reading at rest. The chrome rides as a top safe-area
    /// inset, so the content's resting minY equals the inset height rather
    /// than 0 — progress is measured relative to this baseline.
    @State private var probeRestY: CGFloat? = nil

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
        setScope(all[next])
    }

    /// Switches the active scope with a directional slide, shared by the chip
    /// taps and the horizontal swipe so both animate identically. Silent — no
    /// tab or chip row in the app buzzes.
    private func setScope(_ target: Scope) {
        guard target != scope,
              let cur = Scope.allCases.firstIndex(of: scope),
              let dst = Scope.allCases.firstIndex(of: target) else { return }
        scopeSlideFromTrailing = dst > cur
        withAnimation(.easeOut(duration: 0.25)) { scope = target }
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
                            // ZStack so the outgoing and incoming scope lists
                            // overlap during the directional slide instead of
                            // stacking vertically — the same move+fade the
                            // Sports and Favorites hubs use for tab switches.
                            ZStack(alignment: .top) {
                                resultsList
                                    .id(scope)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: scopeSlideFromTrailing ? .trailing : .leading).combined(with: .opacity),
                                        removal: .move(edge: scopeSlideFromTrailing ? .leading : .trailing).combined(with: .opacity)
                                    ))
                            }
                        }
                    }
                    // Explicit full width: content inserted while another
                    // layout transaction is animating (keyboard rise) was
                    // getting laid out narrow and visibly growing to full
                    // width — the "cover sliding away" on open.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Clearance for the floating dock — results scroll
                    // behind its translucent slab instead of stopping above.
                    .padding(.bottom, 118)
                    }
                }
                .coordinateSpace(name: "searchScroll")
                .frame(maxWidth: .infinity)
                // Horizontal swipe on the results area steps through the
                // scope chips (All → Channels → EPG → Recordings), matching
                // the Sports and Favorites sections. Fires mid-drag for an
                // instant response; simultaneousGesture so vertical
                // scrolling keeps working.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 25)
                        .onChanged { value in
                            let h = value.translation.width
                            let v = value.translation.height
                            // As soon as the drag reads as horizontal, open the
                            // tap-suppression window so whatever is under the
                            // finger doesn't ALSO fire on release. Deliberately
                            // BEFORE the empty-query check below: the browse
                            // screen has no scopes to switch between, but its
                            // shelves and grid are just as tappable, and a
                            // sideways drag across them was landing as a tap.
                            if abs(h) > abs(v) * 1.4 {
                                SwipeTapGuard.suppress()
                            }
                            guard !query.isEmpty else { return }
                            guard !scopeSwipeConsumed,
                                  abs(h) > 50, abs(h) > abs(v) * 1.5,
                                  !HorizontalScrollActivity.isActive else { return }
                            scopeSwipeConsumed = true
                            advanceScope(h < 0 ? 1 : -1)
                        }
                        .onEnded { _ in scopeSwipeConsumed = false }
                )
                // Shared app-wide compact-header vignette, revealed as the big
                // "Search" title scrolls away. Sits above the scrolling results
                // but below the chrome (added by the safeAreaInset that follows).
                .overlay(alignment: .top) {
                    CompactHeaderScrim(height: screenInsets.top + 215, fadeStart: 0.2)
                        .frame(maxWidth: .infinity)
                        .ignoresSafeArea(.container, edges: .top)
                        .scrollProgressOpacity(titleProgress, cullWhenHidden: true) { Double($0 * $0) }
                        .allowsHitTesting(false)
                }
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

            }
        }
        .onAppear {
            // The heavy browse shelves join one frame after the section so
            // their build can never stall the presentation itself.
            DispatchQueue.main.async {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { browseReady = true }
            }
            // No auto-focus: the keyboard only rises when the user taps the
            // search field, exactly like the reference's search tab.
        }
        .onChangeCompat(of: queryText) { newValue in
            scheduleSearchPush(newValue)
        }
        // Teams and leagues come from the already-loaded catalog, so they are
        // ranked straight off the keystroke — no need to wait out the 250 ms
        // debounce that the channel search needs.
        .task(id: queryText) { rankFavoritables() }
        // The catalog arrives after launch — re-rank once it does, so a search
        // run before it loaded doesn't sit there showing nothing to follow.
        .task(id: scoreViewModel?.teamCatalog.count ?? 0) { rankFavoritables() }
        // The probe on the big title reports its offset in the scroll's
        // coordinate space; 40pt of scroll completes the title crossfade —
        // the same ramp the Sports and Favorites hubs use. Measured against
        // the resting baseline because the chrome inset shifts the origin.
        .onPreferenceChange(SectionScrollOffsetsKey.self) { offsets in
            guard let y = offsets["search"] else { return }
            if probeRestY == nil { probeRestY = y }
            let scrolled = (probeRestY ?? y) - y
            titleProgress.set(min(max(scrolled / 40, 0), 1))
        }
    }

    // MARK: - Header

    /// Minimal chrome row — the dock owns navigation now, so the row only
    /// hosts the compact "Search" title crossfading in as the big in-scroll
    /// title departs.
    ///
    /// The ✕ below is off by default and currently unused: multi-view once
    /// needed it, but that overlay now carries the real bottom bar, whose left
    /// circle leaves search the same way it does everywhere else. Kept because
    /// restoring it is a single argument if a dock-less caller wants one.
    private var chromeRow: some View {
        HStack {
            Spacer()
            if showsCloseButton {
                NuvioCircleButton(systemName: "xmark") {
                    viewModel.triggerSelectionHaptic()
                    hideKeyboard()
                    onDismiss()
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
            .font(NuvioTheme.pageTitleFont)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 16)
    }

    private var scopeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Scope.allCases, id: \.self) { s in
                    Button {
                        setScope(s)
                    } label: {
                        NuvioChipLabel(title: s.rawValue, isSelected: scope == s)
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
                VStack(alignment: .leading, spacing: 14) {
                    // Nuvio underlined header + the red live-count badge.
                    HStack(alignment: .top, spacing: 8) {
                        searchHeader("Live Now", inset: 0)
                        Text("\(svm.allLiveGames.count)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red))
                            .padding(.top, 3)
                    }
                    .padding(.horizontal, 20)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(games) { game in
                                LiveEventCard(game: game, accentColor: accentColor)
                                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .onTapGesture {
                                        guard SwipeTapGuard.tapsAllowed else { return }
                                        viewModel.triggerSelectionHaptic()
                                        let h = game.homeCompetitor?.team?.shortDisplayName ?? game.homeCompetitor?.athlete?.shortName ?? ""
                                        let a = game.awayCompetitor?.team?.shortDisplayName ?? game.awayCompetitor?.athlete?.shortName ?? ""
                                        hideKeyboard()
                                        onDismiss()
                                        viewModel.runSmartSearch(gameID: game.id, home: h, away: a, sport: svm.sportType(for: game), network: game.streamNetworkHint)
                                    }
                                    .liveGameContextMenu(game: game, viewModel: viewModel, scoreViewModel: svm, beforeNavigate: {
                                        hideKeyboard()
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
            VStack(alignment: .leading, spacing: 14) {
                searchHeader("Recently Watched")

                ScrollView(.horizontal, showsIndicators: false) {
                    // The same card the home shelves use, at the same size —
                    // a search result and a home shelf card are the same thing
                    // and shouldn't look like two different components.
                    LazyHStack(spacing: 10) {
                        ForEach(recents) { channel in
                            Button {
                                guard SwipeTapGuard.tapsAllowed else { return }
                                viewModel.triggerSelectionHaptic()
                                hideKeyboard()
                                playAction(channel)
                            } label: {
                                HomeChannelShelfCard(
                                    channel: channel,
                                    program: viewModel.getCurrentProgram(for: channel)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    // MARK: - Browse (empty query)

    /// Section header for the search page (20pt inset to match the page's own
    /// padding).
    private func searchHeader(_ title: String, inset: CGFloat = 20) -> some View {
        Text(title)
            .font(NuvioTheme.sectionTitleFont)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, inset)
    }

    private var browseGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchHeader("Browse")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(viewModel.categories.filter { !$0.isHidden }) { cat in
                    Button {
                        guard SwipeTapGuard.tapsAllowed else { return }
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
                                .fill(NuvioTheme.card)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
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

    private var noResults: some View {
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

    /// The follow rows. One definition, placed either above the channel
    /// results or below them depending on `favoritableLeads`.
    @ViewBuilder
    private var favoritableSection: some View {
        if let svm = scoreViewModel, !favoritableHits.isEmpty {
            // Alongside everything else, only the best few — enough to catch
            // the team you meant without burying the channels. The Teams chip
            // is where the full list lives.
            let shown = scope == .teams ? favoritableHits : Array(favoritableHits.prefix(5))
            VStack(alignment: .leading, spacing: 4) {
                Text("Teams & Leagues")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                ForEach(shown) { hit in
                    SearchFavoritableRow(
                        hit: hit,
                        isFavorite: svm.isFavorite(hit),
                        onToggle: {
                            guard SwipeTapGuard.tapsAllowed else { return }
                            svm.toggleFavorite(hit)
                        }
                    )
                }
            }
        }
    }

    /// True when the Teams scope has nothing to show — used so that scope
    /// answers for itself the way Categories does.
    private var hasFavoritableResults: Bool { !favoritableHits.isEmpty }

    @ViewBuilder
    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 22) {
            // A channel isn't a result in any of these scopes.
            if scope != .recordings, scope != .categories, scope != .teams, let top = topResult {
                VStack(alignment: .leading, spacing: 10) {
                    Text("TOP RESULT")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.8)
                    topResultCard(top.channel, isLive: top.isLive)
                }
            }

            if scope == .all && favoritableLeads { favoritableSection }

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

            if scope == .teams || (scope == .all && !favoritableLeads) { favoritableSection }

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

            // The Categories and Teams scopes answer for themselves: either
            // can be empty while channels matched, or full while nothing
            // else did.
            if scope == .categories {
                if viewModel.filteredCategories.isEmpty { noResults }
            } else if scope == .teams {
                if !hasFavoritableResults { noResults }
            } else if topResult == nil && recordingMatches.isEmpty
                        && viewModel.filteredCategories.isEmpty
                        && !hasFavoritableResults {
                noResults
            }

            if (scope == .all || scope == .categories) && !viewModel.filteredCategories.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Categories")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    ForEach(viewModel.filteredCategories) { cat in
                        Button {
                            guard SwipeTapGuard.tapsAllowed else { return }
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
            guard SwipeTapGuard.tapsAllowed else { return }
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

                favoriteButton(channel)

                Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(NuvioTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
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
                    guard SwipeTapGuard.tapsAllowed else { return }
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
                        favoriteButton(channel)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One-tap favourite toggle for a search-result row. A nested plain button
    /// so it captures its own hit area without triggering the row's play action.
    private func favoriteButton(_ channel: StreamChannel) -> some View {
        let isFav = viewModel.favoriteIDs.contains(channel.id)
        return Button {
            guard SwipeTapGuard.tapsAllowed else { return }
            viewModel.triggerSelectionHaptic()
            viewModel.toggleFavorite(channel.id)
        } label: {
            Image(systemName: isFav ? "star.fill" : "star")
                .font(.footnote.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isFav ? .yellow : Color.white.opacity(0.4))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

}

/// Search overlay used by MultiViewScreen to add streams — same UI as the
/// main SearchView plus its own bottom glass field (the multi-view sheet
/// has no morphing bottom bar).
/// The app's search, for the one place that cannot host the dock: multi-view
/// runs inside a full-screen cover, so the bottom bar that normally carries the
/// search field is not on screen.
///
/// Everything else is the SAME search — same `SearchView`, same scopes, same
/// results including live games, and the real `NuvioBottomBar` in its search
/// state rather than a hand-rolled field. It used to differ in two ways that
/// showed: no `scoreViewModel` was passed, and SearchView gates its whole live
/// games section on that, so those results never appeared here at all; and the
/// field was a taller capsule at different insets with no companion circle.
struct SearchOverlayView: View {
    @ObservedObject var viewModel: ChannelViewModel
    /// Required for parity: without it the live games section is skipped.
    var scoreViewModel: ScoreViewModel? = nil
    @Binding var searchText: String
    let accentColor: Color
    let playAction: (StreamChannel) -> Void
    let onCategorySelect: (StreamCategory) -> Void
    let onDismiss: () -> Void
    /// Glyph for the circle that leaves search — see NuvioBottomBar.
    var exitIcon: String = "house.fill"

    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        SearchView(
            viewModel: viewModel,
            scoreViewModel: scoreViewModel,
            accentColor: accentColor,
            queryText: $query,
            playAction: playAction,
            onCategorySelect: onCategorySelect,
            onDismiss: onDismiss
        )
        .overlay(alignment: .bottom) {
            NuvioBottomBar(
                active: .search,
                // The reference bar's selected-tab blue, exactly as
                // MainViewModifiers passes it — same bar, same tint.
                tint: Color(red: 0.333, green: 0.686, blue: 0.976),
                searchMode: true,
                searchExitIcon: exitIcon,
                queryText: $query,
                fieldFocused: $focused,
                onSelect: { tab in
                    // The bar's left circle leaves search. There is no tab to
                    // switch to from inside multi-view, so anything but search
                    // itself closes the overlay — the same gesture that leaves
                    // search everywhere else.
                    guard tab != .search else { return }
                    hideKeyboard()
                    onDismiss()
                },
                onClearQuery: {
                    viewModel.triggerSelectionHaptic()
                    query = ""
                    viewModel.searchText = ""
                },
                onCancelSearch: { focused = false }
            )
        }
    }
}
