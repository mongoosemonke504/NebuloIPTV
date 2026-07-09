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
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(
                key: SectionScrollOffsetsKey.self,
                value: [id: g.frame(in: .global).minY]
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

/// Applies an opacity derived from a `ScrollProgress` without coupling the
/// enclosing screen body to the value. The `@ObservedObject` lives on the
/// modifier, so only this modifier re-renders as the value changes — the
/// screen that built it stays put.
struct ScrollProgressOpacity: ViewModifier {
    @ObservedObject var progress: ScrollProgress
    let map: (CGFloat) -> Double
    func body(content: Content) -> some View {
        content.opacity(map(progress.value))
    }
}

extension View {
    func scrollProgressOpacity(_ progress: ScrollProgress, _ map: @escaping (CGFloat) -> Double) -> some View {
        modifier(ScrollProgressOpacity(progress: progress, map: map))
    }
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