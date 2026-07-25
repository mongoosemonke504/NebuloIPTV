import SwiftUI
import Combine

// MARK: - Nuvio design system
// Design language copied from the user's reference recording (Stremio/Nuvio
// style): pure black canvas, flat charcoal surfaces, huge heavy titles,
// underlined section headers with a circular chevron, dark pill chips, a
// floating rounded tab dock, and white capsule call-to-action pills.
// Monochrome throughout — no accent tinting on the main screens.

enum NuvioTheme {
    /// The app canvas — pure black everywhere.
    static let background = Color.black
    /// Flat card / panel surface.
    static let card = Color(white: 0.08)
    /// Slightly raised surface (icon circles, chevron buttons).
    static let surface = Color(white: 0.14)
    /// Chip fill (dark pill).
    static let chipFill = Color(white: 0.11)
    /// Selected/active pill highlight (dock active tab, selected chip).
    static let chipSelected = Color(white: 0.22)
    /// Dock backing.
    static let dockFill = Color(white: 0.12)
    /// Secondary text.
    static let secondaryText = Color.white.opacity(0.55)
    /// Tertiary text (years, captions).
    static let tertiaryText = Color.white.opacity(0.4)

    /// Giant page title ("Search", "Library", "Settings").
    static let pageTitleFont = Font.system(size: 38, weight: .heavy)
    /// Section header title ("Continue Watching", "Series").
    static let sectionTitleFont = Font.system(size: 21, weight: .bold)
    /// Title under a shelf card.
    static let cardTitleFont = Font.system(size: 16, weight: .semibold)
}

// MARK: - Page title

/// Huge heavy left-aligned page title, exactly like "Library" / "Search" in
/// the reference.
struct NuvioPageTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(NuvioTheme.pageTitleFont)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Section header

/// Bold section title with the short white underline bar beneath it and an
/// optional circular chevron ("see all") button on the trailing edge.
struct NuvioSectionHeader: View {
    let title: String
    var showsChevron: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(NuvioTheme.sectionTitleFont)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 56, height: 3.5)
            }
            Spacer()
            if showsChevron, let action {
                Button {
                    ChannelViewModel.shared.triggerSelectionHaptic()
                    action()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(NuvioTheme.surface))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .contentShape(Rectangle())
        .onTapGesture {
            // The whole header row is tappable like the reference app's
            // headers — same destination as the chevron.
            if showsChevron, let action {
                ChannelViewModel.shared.triggerSelectionHaptic()
                action()
            }
        }
    }
}

/// Bare underlined section title (no trailing chevron) for use inside
/// custom header rows that carry their own accessories.
struct NuvioUnderlinedTitle: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(text)
                .font(NuvioTheme.sectionTitleFont)
                .foregroundStyle(.white)
                .lineLimit(1)
            RoundedRectangle(cornerRadius: 2)
                .fill(.white)
                .frame(width: 56, height: 3.5)
        }
    }
}

// MARK: - Circular icon button

/// Small dark circular icon button — the catalog page's back chevron and the
/// Library page's grid/calendar buttons.
struct NuvioCircleButton: View {
    let systemName: String
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(NuvioTheme.surface.opacity(0.85)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chips

/// Dark rounded chip — the reference's "Movies ⌄" / "Saved" pills.
/// Selected state brightens the text and adds the thin outline; an optional
/// chevron turns it into the dropdown look.
struct NuvioChipLabel: View {
    let title: String
    var isSelected: Bool = false
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(isSelected ? .white : NuvioTheme.secondaryText)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(NuvioTheme.chipFill))
        .overlay(
            Capsule().stroke(Color.white.opacity(isSelected ? 0.45 : 0), lineWidth: 1)
        )
        .contentShape(Capsule())
    }
}

// MARK: - Metadata dot line

/// "Movie • Action • 2026" — white semibold parts separated by gray dots.
struct NuvioMetadataLine: View {
    let parts: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 {
                    Circle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 4, height: 4)
                }
                Text(part)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - White capsule pill button

/// The hero's "View Details" — white capsule, black bold label.
struct NuvioPillButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(Capsule().fill(.white))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableCardStyle())
    }
}

// MARK: - Page dots

/// Hero pager dots. The current page is an elongated capsule TRACK that
/// fills with white left-to-right as its dwell time elapses — the reference's
/// countdown to the next auto-advance — while the others stay small
/// translucent circles.
struct NuvioPageDots: View {
    let count: Int
    let index: Int
    /// 0 → 1 across the current page's dwell time.
    var progress: CGFloat = 0

    private static let activeWidth: CGFloat = 30
    private static let dotSize: CGFloat = 7

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                if i == index {
                    // Track + fill, so the white edge sweeps across as the
                    // countdown runs.
                    Capsule()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: Self.activeWidth, height: Self.dotSize)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: max(Self.dotSize,
                                                  Self.activeWidth * min(max(progress, 0), 1)))
                        }
                        .clipShape(Capsule())
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: Self.dotSize, height: Self.dotSize)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: index)
    }
}

// MARK: - Tab dock

enum NuvioTab: String, CaseIterable {
    case home = "Home"
    case search = "Search"
    case sports = "Sports"
    case favorites = "Favorites"
    case profile = "Profile"

    var icon: String {
        switch self {
        case .home:      return "house.fill"
        case .search:    return "magnifyingglass"
        case .sports:    return "sportscourt.fill"
        case .favorites: return "star.fill"
        case .profile:   return "person.crop.circle.fill"
        }
    }
}

/// The Apple TV-style bottom bar with a CONTINUOUS Liquid Glass morph
/// between its states. The two glass shapes are permanent views whose
/// frames animate — the tab capsule squeezes into the circular Home button
/// while the search circle stretches into the field — so nothing pops in
/// from the middle; the glass simply reshapes, exactly like the native bar.
/// While the keyboard is up, the Home circle tucks away and a circular ✕
/// melts out beside the field; tapping it (or dismissing the keyboard)
/// melts it back in.
/// Pure presentation — the owner decides what each tab tap does, so all
/// existing navigation machinery stays intact.
struct NuvioBottomBar: View {
    let active: NuvioTab
    var tint: Color = .white
    let searchMode: Bool
    @Binding var queryText: String
    var fieldFocused: FocusState<Bool>.Binding
    let onSelect: (NuvioTab) -> Void
    let onClearQuery: () -> Void
    /// The ✕ beside the field: collapses the keyboard and clears the query.
    let onCancelSearch: () -> Void

    @Namespace private var ns

    /// True for a beat after a tab switch — swells the glass selection blob
    /// and the landing glyph, the system bar's magnifying-lens hop.
    @State private var pillBoost = false

    private static let mainTabs: [NuvioTab] = [.home, .sports, .favorites, .profile]

    /// Keyboard up in search — the Home circle hides and the ✕ appears.
    private var typing: Bool { searchMode && fieldFocused.wrappedValue }

    var body: some View {
        // The bar positions ITSELF against the physical bottom of the screen
        // rather than trusting whatever bottom inset its host container
        // reports — that dependency is why it previously landed at a
        // different height than the reference bar. A full-height stack that
        // ignores the container's bottom inset reaches the true screen edge;
        // the bar then sits a measured 20pt above it. `.container` only, so
        // SwiftUI's keyboard avoidance still lifts the whole thing while the
        // user types.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if #available(iOS 26.0, *) {
                    // The container lets glass shapes melt into each other as
                    // they appear, disappear and reshape.
                    GlassEffectContainer(spacing: 0) { barContent }
                } else {
                    barContent
                }
            }
            // Margins measured off the reference bar.
            .padding(.horizontal, 21)
            .padding(.bottom, typing ? 10 : 20)
        }
        // A hair of transparency on top of the system glass so a little more
        // of the content behind reads through.
        .opacity(0.96)
        .ignoresSafeArea(.container, edges: .bottom)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: searchMode)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: typing)
    }

    private var barContent: some View {
        HStack(spacing: 8) {
            // ── LEFT: tab capsule ⇄ Home circle (one persistent glass shape,
            //    its frame animates) — tucked away while typing.
            if !typing {
                ZStack {
                    tabsRow
                        .opacity(searchMode ? 0 : 1)
                    Image(systemName: "house.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .opacity(searchMode ? 1 : 0)
                }
                .frame(maxWidth: searchMode ? 50 : .infinity)
                // Slab height. The bar stays pinned at the same bottom
                // position, so changing this moves its TOP edge only.
                // (Apple's measures 58pt; this runs 3pt taller by request.)
                .frame(height: searchMode ? 50 : 61)
                .modifier(DockGlass(circular: false, morphID: "left", morphNS: ns))
                .contentShape(Capsule())
                .onTapGesture {
                    guard searchMode else { return }
                    ChannelViewModel.shared.triggerSelectionHaptic()
                    onSelect(.home)
                }
                .transition(.opacity)
            }

            // ── RIGHT: search circle ⇄ field (one persistent glass shape).
            ZStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(searchMode ? 0 : 1)

                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    TextField("Search", text: $queryText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .submitLabel(.search)
                        .focused(fieldFocused)
                    if !queryText.isEmpty {
                        Button(action: onClearQuery) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .opacity(searchMode ? 1 : 0)
                .allowsHitTesting(searchMode)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: queryText.isEmpty)
            }
            .frame(maxWidth: searchMode ? .infinity : 62)
            .frame(height: searchMode ? 50 : 62)
            .modifier(DockGlass(circular: false, morphID: "right", morphNS: ns))
            .contentShape(Capsule())
            .onTapGesture {
                ChannelViewModel.shared.triggerSelectionHaptic()
                if searchMode {
                    fieldFocused.wrappedValue = true
                } else {
                    onSelect(.search)
                }
            }

            // ── ✕ while typing: closes the keyboard, then melts back into
            //    the bar — reference behaviour.
            if typing {
                Button {
                    ChannelViewModel.shared.triggerSelectionHaptic()
                    onCancelSearch()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .modifier(DockGlass(circular: true, morphID: "cancel", morphNS: ns))
                .transition(.opacity)
            }
        }
    }

    /// The four main tabs with the gliding Liquid Glass selection blob.
    /// Switching tabs swells the blob (and the landing tab's glyph) for a
    /// beat — the system bar's magnifying-lens hop.
    private var tabsRow: some View {
        HStack(spacing: 0) {
            ForEach(Self.mainTabs, id: \.self) { tab in
                Button {
                    ChannelViewModel.shared.triggerSelectionHaptic()
                    if tab != active {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.68)) {
                            pillBoost = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                                pillBoost = false
                            }
                        }
                    }
                    onSelect(tab)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 23, weight: .bold))
                            .frame(height: 25)
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    // Active tab reads in the accent tint (blue), idle tabs
                    // stay white — exactly like the reference bar.
                    .foregroundStyle(tab == active ? tint : Color.white.opacity(0.82))
                    // Under the lens the glyph and label are genuinely
                    // MAGNIFIED — measured ~1.45x at the peak of the hop in
                    // the reference recording.
                    .scaleEffect(tab == active && pillBoost ? 1.45 : 1.0)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background {
                        // The selection lens glides between tabs. It always
                        // keeps the reference's rounded-RECT shape — during
                        // the hop it simply swells past the bar's edges,
                        // magnifying the landing tab, then settles back.
                        if tab == active {
                            // Reference capsule: 74x52pt in a 58pt slab, so
                            // it is slightly WIDER than the tab slot and
                            // inset ~3pt top and bottom.
                            DockPillBlob(boosted: pillBoost)
                                .padding(.horizontal, -2)
                                .padding(.vertical, -2)
                                .matchedGeometryEffect(id: "dockPill", in: ns)
                                // At the peak of the hop the lens swells past
                                // the bar's edges — the bulging glass droplet
                                // in the reference.
                                .scaleEffect(x: pillBoost ? 1.30 : 1.0,
                                             y: pillBoost ? 1.35 : 1.0)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        // Slight overshoot — the system pill's springy glide.
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: active)
    }
}

/// Liquid Glass backing shared by the bar's shapes — the plain system glass
/// (no tint), exactly as the reference's native tab bar renders it; ultra-
/// thin material fallback below iOS 26. `morphID`/`morphNS` join the shape
/// into the bar's GlassEffectContainer so state changes melt one glass
/// shape into the other.
struct DockGlass: ViewModifier {
    var circular = false
    var morphID: String? = nil
    var morphNS: Namespace.ID? = nil

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // `.regular.interactive()` — the system tab bar's own material.
            // It refracts AND dims the backdrop, which is what makes the
            // reference bar read as a surface over bright content; `.clear`
            // passed the backdrop through at full brightness so the bar
            // vanished into whatever was behind it.
            if circular {
                glassed(content.glassEffect(.regular.interactive(), in: Circle()))
            } else {
                glassed(content.glassEffect(.regular.interactive(), in: Capsule()))
            }
        } else {
            // No material either — a plain dark translucent fill, so there
            // is no blur behind the glass on older systems.
            if circular {
                content
                    .background(Color(white: 0.13).opacity(0.82), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            } else {
                content
                    .background(Color(white: 0.13).opacity(0.82), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            }
        }
    }

    @available(iOS 26.0, *)
    @ViewBuilder
    private func glassed(_ view: some View) -> some View {
        if let morphID, let morphNS {
            view
                .glassEffectID(morphID, in: morphNS)
                // The real liquid melt between the bar's states.
                .glassEffectTransition(.matchedGeometry)
        } else {
            view
        }
    }
}

/// The dock's active-tab highlight — a Liquid Glass lens riding on the
/// bar's glass, shaped as the reference's rounded rectangle (never a
/// circle) with a light wash so the selected tab still reads.
private struct DockPillBlob: View {
    /// True at the peak of a tab hop — the lens brightens its rim, the
    /// refractive edge visible on the swelling droplet in the reference.
    var boosted: Bool = false

    var body: some View {
        // Deliberately NOT a nested glassEffect: glass layered on the bar's
        // own glass came out muddy (a brown blob over warm content). The
        // reference selection is simply a lighter capsule with a hairline
        // edge, letting the bar's glass show through it.
        Capsule()
            .fill(Color.white.opacity(boosted ? 0.20 : 0.16))
            .overlay(
                Capsule().stroke(Color.white.opacity(boosted ? 0.42 : 0.14),
                                 lineWidth: boosted ? 1.2 : 0.5)
            )
    }
}

/// Stretchy-hero transform: while the user rubber-bands past the top, the
/// hero scales up from its bottom edge so its artwork keeps covering the
/// screen — no black gap above it. Observes its own leaf object so the
/// per-frame overscroll updates re-render only this transform, never the
/// carousel content.
struct HeroStretch: ViewModifier {
    @ObservedObject var pull: ScrollProgress
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 + max(0, pull.value) / height, anchor: .bottom)
    }
}

// MARK: - Shelf card chrome

/// The card tile used across the shelves, optionally carrying Nuvio's
/// card-DEPTH treatment (`CardDepthEffect.kt` → `cardDepthVisual`): a 1pt rim
/// whose white falls away from top to bottom, and a soft sheen across the top
/// of the tile. Together they read as a slab of liquid glass catching light
/// from above rather than a flat rectangle — the "lines around the cards" in
/// the reference app.
///
/// `depth` is OPT-IN and lives only on the HOME screen's cards; everywhere else
/// keeps the plain hairline, which is what the rest of the app is drawn with.
///
/// Nuvio's shipped defaults, scaled from its 0-100 sliders:
///   edgeStrength 28 → 0.28   sheenStrength 10 → 0.10   edgeCoverage 0 → 0
/// so the rim runs 0.28 at the top, 0.09 across the middle (0.28 × 0.33) and
/// vanishes at the bottom edge.
struct NuvioCardSurface: ViewModifier {
    var cornerRadius: CGFloat = 12
    /// The tile's fill. Channel surfaces pass their logo-derived tone; anything
    /// else gets the theme's charcoal.
    var fill: Color? = nil
    /// Nuvio's glass rim + sheen. Home screen only.
    var depth: Bool = false

    static let edgeStrength: Double = 0.28
    static let sheenStrength: Double = 0.10
    static let edgeCoverage: Double = 0

    /// The rim: brightest along the top, gone by the bottom.
    static let edgeGradient = LinearGradient(
        stops: [
            .init(color: .white.opacity(edgeStrength), location: 0),
            .init(color: .white.opacity(edgeStrength * (0.33 + 0.67 * edgeCoverage)), location: 0.5),
            .init(color: .white.opacity(edgeStrength * edgeCoverage), location: 1)
        ],
        startPoint: .top, endPoint: .bottom
    )

    /// Nuvio draws the sheen over the top 22% of the card's height; expressing
    /// it as a full-height gradient that reaches clear at 0.22 is the same
    /// thing without needing to measure the card.
    static let sheenGradient = LinearGradient(
        stops: [
            .init(color: .white.opacity(sheenStrength), location: 0),
            .init(color: .clear, location: 0.22)
        ],
        startPoint: .top, endPoint: .bottom
    )

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(fill ?? NuvioTheme.card))
            // The sheen sits above the content, as Nuvio's drawWithContent
            // does, and inside the clip so it follows the corners.
            .overlay {
                if depth { Self.sheenGradient.allowsHitTesting(false) }
            }
            .clipShape(shape)
            .overlay {
                if depth {
                    shape.strokeBorder(Self.edgeGradient, lineWidth: 1)
                } else {
                    shape.stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                }
            }
    }
}

extension View {
    func nuvioCard(cornerRadius: CGFloat = 12, fill: Color? = nil, depth: Bool = false) -> some View {
        modifier(NuvioCardSurface(cornerRadius: cornerRadius, fill: fill, depth: depth))
    }
}

/// Nuvio's hero SCROLL parallax (`HomeHeroSection.kt`): as the page scrolls the
/// artwork slides down at a fraction of the scroll and swells a hair, so it
/// lags behind the title and metadata travelling away at full speed. Applied to
/// the backdrop only — that difference in speed IS the effect. Observes its own
/// leaf object so per-frame scroll updates re-render this transform alone.
struct HeroScrollParallax: ViewModifier {
    @ObservedObject var scroll: ScrollProgress
    /// The carousel's own backdrop scale, which this multiplies.
    let baseScale: CGFloat

    // Nuvio's constants.
    private static let parallax: CGFloat = 0.3
    private static let downScaleMultiplier: CGFloat = 0.0001
    private static let maxScale: CGFloat = 1.3

    func body(content: Content) -> some View {
        let s = max(0, scroll.value)
        content
            .scaleEffect(baseScale * min(1 + s * Self.downScaleMultiplier, Self.maxScale))
            .offset(y: s * Self.parallax)
    }
}

/// Small black badge pill overlaid on a card's corner — "1h 48m left".
struct NuvioCardBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.75)))
    }
}
