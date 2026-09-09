import SwiftUI
import Combine

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.5), location: 0.35),
                            .init(color: .white.opacity(1.0), location: 0.5),
                            .init(color: .white.opacity(0.5), location: 0.65),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: -geo.size.width * 2 + (geo.size.width * 3 * phase))
                    .onAppear {
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: true)) {
                            phase = 1
                        }
                    }
                }
            )
            .mask(content)
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

/// Swipe-down-to-dismiss: a 25-pt transparent hit zone at the top of the view
/// detects a downward drag and calls `onDismiss` when the drag exceeds 80 pts.
/// Mirrors SwipeBackModifier's edge-zone pattern so the gesture feels native.
struct SwipeDownDismissModifier: ViewModifier {
    let onDismiss: () -> Void
    @State private var dragY: CGFloat = 0

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
                .offset(y: max(0, dragY))

            Color.clear
                .frame(height: 25)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            if value.translation.height > 0 {
                                dragY = value.translation.height
                            }
                        }
                        .onEnded { value in
                            if value.translation.height > 80 {
                                dragY = 0
                                onDismiss()
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    dragY = 0
                                }
                            }
                        }
                )
        }
    }
}

struct SkeletonBox: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = 8
    
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(0.15))
            .frame(width: width, height: height)
            .shimmer()
    }
}

struct BlurFadeModifier: ViewModifier {
    let blurRadius: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content
            .blur(radius: blurRadius)
            .opacity(opacity)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(
            active: BlurFadeModifier(blurRadius: 20, opacity: 0),
            identity: BlurFadeModifier(blurRadius: 0, opacity: 1)
        )
    }

    /// iOS navigation-style push/pop: the arriving view slides in from the
    /// trailing (right) edge; the departing view slides back out the same way.
    /// Pair with a spring animation and SwipeBackModifier for a native feel.
    static var pagePush: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing),
            removal: .move(edge: .trailing)
        )
    }
}

/// Horizontal tab-swipes ride simultaneously with the vertical scroll, but a
/// drag that starts and ends inside a full-width button's bounds ALSO fires
/// that button's action on release. The swipe gestures mark a short window
/// here while a horizontal drag is in flight; row/card tap actions check
/// `tapsAllowed` and no-op during it.
enum SwipeTapGuard {
    static var suppressTapsUntil = Date.distantPast
    static var tapsAllowed: Bool { Date() > suppressTapsUntil }
    static func suppress(for interval: TimeInterval = 0.4) {
        suppressTapsUntil = Date().addingTimeInterval(interval)
    }
}

/// Global "a horizontal shelf is scrolling" signal. Horizontal shelves and
/// chip rows touch this while the user drags them; the page-level chip-swipe
/// gestures check it and stand down, so a shelf scroll is never mistaken for
/// a page swipe. Timestamp-based (not a flag) so a missed "ended" callback
/// can't wedge the signal on.
@MainActor
enum HorizontalScrollActivity {
    static var last = Date.distantPast
    static func touch() { last = Date() }
    static var isActive: Bool { Date().timeIntervalSince(last) < 0.2 }
}

/// Reports a view's frame in global (screen) coordinates whenever it moves.
/// Used to carve chip rows out of page-level swipe gestures.
struct GlobalFrameCapture: ViewModifier {
    let onChange: (CGRect) -> Void
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { onChange(geo.frame(in: .global)) }
                    .onChangeCompat(of: geo.frame(in: .global)) { onChange($0) }
            }
        )
    }
}

extension View {
    func captureGlobalFrame(_ onChange: @escaping (CGRect) -> Void) -> some View {
        modifier(GlobalFrameCapture(onChange: onChange))
    }
}

/// Scroll offsets reported by ScrollOffsetProbe, keyed by an arbitrary page id
/// so screens with multiple scroll views (paged tabs) can read just the one
/// that's currently visible.
struct SectionScrollOffsetsKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Invisible zero-height probe placed at the very top of scrollable content.
/// Reports the content's minY in the named coordinate space: ~0 at rest,
/// increasingly negative as the user scrolls down. Drives collapsing headers.
struct ScrollOffsetProbe: View {
    let space: String
    let id: String
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(
                key: SectionScrollOffsetsKey.self,
                value: [id: g.frame(in: .named(space)).minY]
            )
        }
        .frame(height: 0)
    }
}

/// Probe that reports a view's global (screen) minY. Pair one on a scroll
/// view's content and one on the scroll view itself, then subtract, to get
/// the true scrolled distance — works where named coordinate spaces don't
/// resolve (e.g. through UIPageViewController-backed pagers) and is immune
/// to the scroll view's own frame moving during a header collapse.
struct GlobalOffsetProbe: View {
    let id: String
    /// Which space the offset is measured in. Defaults to `.global`, but a
    /// caller that gets translated as a whole — the game detail card, slid up
    /// and down by the open/dismiss — should pass a space anchored inside
    /// itself. Measured globally, a uniform translation rewrites the preference
    /// on every frame of that slide and re-runs the preference plumbing across
    /// the tree, even though the value the reader actually wants (a difference
    /// between two probes moving in lockstep) never changed.
    var space: CoordinateSpace = .global
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(
                key: SectionScrollOffsetsKey.self,
                value: [id: g.frame(in: space).minY]
            )
        }
    }
}

/// Holds a single scroll-driven progress value (0…1) in its own observable
/// object. A screen holds it via `@State` — which does NOT subscribe the
/// screen to its changes — and only the small leaf views that render the
/// progress (a fading title, a gradient) observe it via `@ObservedObject`.
/// Updating it every scroll frame then re-renders just those leaves instead
/// of the whole screen body, which — carrying the scrolling lists — was the
/// source of the jitter during the header-fade at the start of a scroll.
final class ScrollProgress: ObservableObject {
    @Published var value: CGFloat = 0

    /// Assigns only on a real change so identical per-frame readings don't
    /// emit redundant publishes.
    func set(_ newValue: CGFloat) {
        if newValue != value { value = newValue }
    }
}

/// Boolean twin of `ScrollProgress`, and there for the same reason: a screen
/// holds it via `@State` (which does NOT subscribe the screen to it), so
/// flipping it re-renders only the leaf that reads it rather than the whole
/// view that owns it.
final class FlagBox: ObservableObject {
    /// A box that is never set, for callers that only have one lock to give.
    /// Shared and immutable in practice, so observing it costs nothing.
    static let never = FlagBox()

    @Published var value: Bool = false

    init(_ value: Bool = false) { self.value = value }

    /// Assigns only on a real change, so repeat writes don't publish.
    func set(_ newValue: Bool) {
        if newValue != value { value = newValue }
    }
}

/// Freezes a scroll view while the flag is set. Used to stop a card's content
/// scrolling under the finger during a drag that is dismissing the whole card.
struct ScrollLocked: ViewModifier {
    @ObservedObject var flag: FlagBox
    /// A second, independent lock, ORed with the first.
    ///
    /// Two `scrollDisabled` modifiers cannot be stacked to mean "either": the
    /// one nearest the scroll view wins, so an outer `false` would release an
    /// inner `true`. A page that has its own lock AND is subject to a lock
    /// owned by whatever is presenting it needs both resolved in one place.
    @ObservedObject var other: FlagBox

    func body(content: Content) -> some View {
        content.scrollDisabled(flag.value || other.value)
    }
}

extension View {
    /// Optional so callers can pass an environment value straight through —
    /// substituting a fresh `FlagBox` for nil would mint a new object on every
    /// render and observe nothing.
    @ViewBuilder
    func scrollLocked(_ flag: FlagBox?, _ other: FlagBox? = nil) -> some View {
        if let flag {
            modifier(ScrollLocked(flag: flag, other: other ?? FlagBox.never))
        } else {
            self
        }
    }
}

/// Applies an opacity derived from a `ScrollProgress` without coupling the
/// enclosing screen body to the value. The `@ObservedObject` lives on the
/// modifier, so only this modifier re-renders as the value changes — the
/// screen that built it stays put.
struct ScrollProgressOpacity: ViewModifier {
    @ObservedObject var progress: ScrollProgress
    let map: (CGFloat) -> Double
    /// Drop the content out of the render pass entirely while it maps to fully
    /// transparent, rather than drawing it at opacity 0 — see
    /// `ScrollProgressReveal.cullWhenHidden` for why that is not the same
    /// thing. Every compact-header scrim in the app is a `.regularMaterial`,
    /// and a material re-samples and blurs its backdrop on every frame the
    /// content behind it moves, visible or not: a full-width backdrop blur
    /// computed for the entire length of every scroll, for nothing.
    ///
    /// Opt-in, and only safe for pure decoration: a culled view stops laying
    /// out, so anything measuring itself (or measured through a `.background`
    /// chained after this) must keep rendering.
    var cullWhenHidden = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let value = map(progress.value)
        if cullWhenHidden && value <= 0.001 {
            EmptyView()
        } else {
            content.opacity(value)
        }
    }
}

extension View {
    func scrollProgressOpacity(_ progress: ScrollProgress,
                               cullWhenHidden: Bool = false,
                               _ map: @escaping (CGFloat) -> Double) -> some View {
        modifier(ScrollProgressOpacity(progress: progress,
                                       map: map,
                                       cullWhenHidden: cullWhenHidden))
    }
}

/// Same idea for pinned chrome that fades in as the user scrolls (the
/// compact score bar on the game detail pages): opacity tracks the
/// scroll-driven progress directly, and hit testing only switches on once
/// the bar is mostly visible so the invisible bar never eats touches meant
/// for the content beneath it.
struct ScrollProgressReveal: ViewModifier {
    @ObservedObject var progress: ScrollProgress

    /// While fully transparent, drop the content out of the render pass
    /// entirely instead of drawing it at opacity 0. Worth it for the header
    /// scrim, which is a `.regularMaterial` — a material samples and blurs the
    /// backdrop every frame even when invisible, and a dismiss only engages at
    /// the top of the page, precisely where the scrim is hidden. All three
    /// pager cards were paying for a full-width backdrop blur throughout the
    /// open and close for something nobody could see.
    ///
    /// Opt-in, and only safe for pure decoration: a culled view stops laying
    /// out, so anything measuring itself (or measured through a `.background`
    /// chained after this modifier) must keep rendering.
    var cullWhenHidden = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if cullWhenHidden && progress.value <= 0.001 {
            EmptyView()
        } else {
            content
                .opacity(Double(progress.value))
                .allowsHitTesting(progress.value > 0.5)
        }
    }
}

extension View {
    func scrollProgressReveal(_ progress: ScrollProgress, cullWhenHidden: Bool = false) -> some View {
        modifier(ScrollProgressReveal(progress: progress, cullWhenHidden: cullWhenHidden))
    }
}

/// The app-wide compact-header vignette: a strong frosted blur + dark wash at
/// the top that fades — blur and all — to fully clear down a long tail, the
/// same recipe used behind the collapsed home title. Every pinned/compact
/// header (home, sports hub, favorites, game detail, player stats) uses this
/// so they read identically. `height` sets the total reach and `fadeStart` is
/// the fraction that stays fully solid before the long fade begins — a taller
/// solid cap for headers that sit further below the top of the screen.
struct CompactHeaderScrim: View {
    var height: CGFloat
    var fadeStart: CGFloat = 0.2
    /// Overrides the background-derived tint with a fixed colour. The game and
    /// score cards pass `.black`: they float above the app background on their
    /// own dark surface, so a background-tinted vignette read as a colour cast
    /// rather than a shadow.
    var tintOverride: Color? = nil
    /// The canvas is pure black since the redesign, so the vignette is a
    /// plain black wash unless a caller overrides it.
    private var tint: Color { tintOverride ?? .black }
    /// Length in points of a soft ramp at the scrim's TOP edge.
    ///
    /// Zero — the default, and right for every scrim that sits flush with the
    /// top of the screen — keeps the hard edge, which is invisible there because
    /// it's at the screen boundary.
    ///
    /// A scrim that can sit MID-screen needs one. The team and driver pages pin
    /// a header whose frame reaches `pinnedInset` ABOVE its chips, so that frame
    /// top only arrives at the top of the screen at the very end of the
    /// collapse: for the whole scroll before it, a hard-edged 82% wash plus
    /// blur was drawing a line straight across the hero with a flat dark bar
    /// beneath it. The ramp is added ON TOP of `height` and offset back out, so
    /// the scrim still covers exactly what it used to and the ramp is simply
    /// off-screen once the header is pinned — the pinned look is unchanged.
    var topFade: CGFloat = 0

    var body: some View {
        let total = height + topFade
        // Where the ramp finishes, as a fraction of the taller scrim; the
        // bottom fade then starts `fadeStart` of the way through what remains.
        let rampEnd = total > 0 ? topFade / total : 0
        ZStack {
            Rectangle().fill(.regularMaterial)
            LinearGradient(
                colors: [tint.opacity(0.82), tint.opacity(0.5), .clear],
                startPoint: .top, endPoint: .bottom
            )
        }
        .frame(height: total)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: rampEnd),
                    .init(color: .black, location: rampEnd + (1 - rampEnd) * fadeStart),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .offset(y: -topFade)
        .allowsHitTesting(false)
    }
}

struct PinnedHeaderGradient: View {
    var body: some View {
        CompactHeaderScrim(height: 275, fadeStart: 0.2, tintOverride: .black)
            .offset(y: -55)
    }
}

/// Game-detail compact-header vignette — one continuous scrim (tint + blur)
/// with no cutout. It's rendered BEHIND the tab chips (lower z-order) so the
/// vignette, blur and all, passes continuously behind them while the chips
/// themselves stay bright on top.
///
/// The tint reproduces the detail card's OWN background — the dark base plus
/// the away/home team-colour washes flooding in from the top corners — instead
/// of a flat black band, so the pinned header reads as a continuation of the
/// card rather than a separate panel laid over it.
struct GameHeaderScrim: View {
    var awayColor: Color = .black
    var homeColor: Color = .black
    var height: CGFloat = 340
    var fadeStart: CGFloat = 0.16

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.regularMaterial)
            // Rendered at the card's full height and then clipped to the scrim,
            // so the wash lines up with the identical gradient painted by
            // GameDetailView.backgroundLayer directly beneath it. Building it at
            // the scrim's own height instead would compress the falloff and
            // leave a visible seam where the two meet.
            ZStack {
                Color(white: 0.10)
                LinearGradient(
                    colors: [awayColor.opacity(0.65), .clear],
                    startPoint: .topLeading,
                    endPoint: UnitPoint(x: 0.65, y: 0.75)
                )
                LinearGradient(
                    colors: [homeColor.opacity(0.55), .clear],
                    startPoint: .topTrailing,
                    endPoint: UnitPoint(x: 0.35, y: 0.75)
                )
            }
            .frame(height: UIScreen.main.bounds.height)
            .opacity(0.8)
        }
        .frame(height: height)
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: fadeStart),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }
}

/// Pinned-chip styling derived from the user's chosen app background, so the
/// chip rows on Home, Sports and Favorites always sit in the same colour family
/// as the nebula (or custom photo) behind them. Reads the same @AppStorage keys
/// as `CompactHeaderScrim`, so chips restyle live the moment the background
/// changes.
///
/// The unselected fill stays fully opaque — these rows pin over scrolling
/// content, which must never show through them.
struct BackgroundTintedChip: ViewModifier {
    let isSelected: Bool

    // Nuvio redesign: chips are the reference app's dark charcoal pills —
    // opaque (they pin over scrolling content), white text when selected
    // with a thin light outline, muted gray text when idle. No background
    // tinting — the canvas is pure black everywhere.
    private var fill: Color {
        isSelected ? Color(white: 0.20) : Color(white: 0.11)
    }
    private var text: Color {
        isSelected ? .white : Color.white.opacity(0.6)
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(text)
            .background(Capsule().fill(fill))
            .overlay(
                Capsule().stroke(Color.white.opacity(isSelected ? 0.4 : 0), lineWidth: 1)
            )
            .contentShape(Capsule())
    }
}

extension View {
    /// Styles a chip's fill + label colour from the user's background palette.
    func backgroundTintedChip(isSelected: Bool) -> some View {
        modifier(BackgroundTintedChip(isSelected: isSelected))
    }
}

struct ScrollProgressOffset: ViewModifier {
    @ObservedObject var progress: ScrollProgress
    func body(content: Content) -> some View {
        content.offset(y: progress.value)
    }
}

extension View {
    func scrollProgressOffset(_ progress: ScrollProgress) -> some View {
        modifier(ScrollProgressOffset(progress: progress))
    }
}

final class ValueBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

struct GlassEffect: ViewModifier {
    let cornerRadius: CGFloat
    let isSelected: Bool
    let accentColor: Color?

    func body(content: Content) -> some View {
        applyGlass(to: content)
    }

    // @ViewBuilder lets both branches return different concrete types
    // without AnyView — SwiftUI keeps stable view identity across renders.
    @ViewBuilder
    private func applyGlass(to content: Content) -> some View {
        let shape       = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let strokeColor = isSelected && accentColor != nil
            ? accentColor!.opacity(0.6)
            : Color.white.opacity(0.08)
        let strokeWidth: CGFloat = isSelected ? 1.2 : 0.5
        if #available(iOS 26.0, *) {
            let glass: Glass = {
                if isSelected, let accent = accentColor {
                    return .regular.tint(accent.opacity(0.35))
                }
                return .regular
            }()
            content
                .glassEffect(glass, in: shape)
                .overlay(shape.stroke(strokeColor, lineWidth: strokeWidth))
                .contentShape(shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(strokeColor, lineWidth: strokeWidth))
                .contentShape(shape)
        }
    }
}