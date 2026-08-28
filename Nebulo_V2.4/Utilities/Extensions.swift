import SwiftUI
import Combine

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6 else { return nil }
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        self.init(red: Double((rgb & 0xFF0000) >> 16)/255.0, green: Double((rgb & 0x00FF00) >> 8)/255.0, blue: Double(rgb & 0x0000FF)/255.0)
    }
    func toHex() -> String? {
        guard let c = UIColor(self).cgColor.components, c.count >= 3 else { return nil }
        return String(format: "#%02lX%02lX%02lX", lroundf(Float(c[0])*255), lroundf(Float(c[1])*255), lroundf(Float(c[2])*255))
    }
}
extension KeyedDecodingContainer {
    func decodeFlexibleID(forKey key: K) throws -> Int {
        if let intValue = try? decode(Int.self, forKey: key) { return intValue }
        if let stringValue = try? decode(String.self, forKey: key) {
            return Int(stringValue) ?? 0
        }
        return 0
    }
}

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            self.onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
    
    func swipeBack(onTrigger: @escaping () -> Void) -> some View {
        self.gesture(
            DragGesture()
                .onEnded { value in
                    let minDragTranslation: CGFloat = 100
                    let minStartingX: CGFloat = 50 
                    
                    if value.startLocation.x < minStartingX && value.translation.width > minDragTranslation {
                        onTrigger()
                    }
                }
        )
    }
    
    @ViewBuilder
    func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

import UIKit

struct NavigationPopGestureHandler: UIViewControllerRepresentable {
    var isEnabled: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        
        return UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        
        uiViewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = isEnabled
    }
}

extension View {
    
    
    
    func interactivePopGesture(isEnabled: Bool) -> some View {
        self.background(NavigationPopGestureHandler(isEnabled: isEnabled))
    }
}

/// Interactive close state for a screen that covers the whole app.
///
/// The detail pages already work this way; multi-view is the other one, and it
/// needs its own pair of leaves rather than borrowing the router's — a detail
/// page can be open underneath multi-view, and the two must not fight over one
/// offset. Two parallax modifiers stack additively, and a value of 0 contributes
/// nothing, so having both applied costs nothing while only one is in use.
final class MultiViewDismiss {
    static let shared = MultiViewDismiss()
    private init() {}

    /// 0 = covering the screen, 1 = fully swiped off to the right.
    let slide = ScrollProgress()
    /// 1 = covering the screen, 0 = gone. Drives the parallax underneath.
    let cover = ScrollProgress()
    /// Set while a close swipe is in flight.
    let dragLock = FlagBox()
}

// MARK: - Detail page router

/// Which full-screen detail page is open, if any.
///
/// The pages are opened from two unrelated screens (the home shelf and the
/// Favorites hub) but have to be RENDERED from one place — above the bottom
/// dock, which is an overlay on the navigation stack's root. So the choice of
/// page lives here rather than in either screen's own state.
enum DetailRoute: Identifiable, Equatable {
    case team(team: ESPNTeam, sport: SportType?, leagueLabel: String?)
    case league(sport: SportType, leagueLabel: String?, displayName: String)

    var id: String {
        switch self {
        case let .team(team, sport, _):
            return "team|\(sport?.rawValue ?? "-")|\(team.id)"
        case let .league(sport, leagueLabel, _):
            return "league|\(sport.rawValue)|\(leagueLabel ?? "-")"
        }
    }

    static func == (a: DetailRoute, b: DetailRoute) -> Bool { a.id == b.id }
}

/// Owns the open detail page and how far it has been swiped aside.
///
/// Neither a cover nor a navigation push could give the swipe-to-close what
/// it needs: a cover takes the screen underneath out of the hierarchy (so the
/// gesture could only reveal black), and a push leaves the interactive pop in
/// UIKit's hands, which refuses to run it while the navigation bar is hidden —
/// which it is on every one of these pages. Rendering the page as an overlay
/// over the live screen keeps the whole transition in SwiftUI, where the
/// screen behind is genuinely there to be revealed.
final class DetailRouter: ObservableObject {
    static let shared = DetailRouter()
    private init() {}

    @Published var route: DetailRoute?

    /// 0 = page covering the screen, 1 = fully swiped off to the right. Kept
    /// in a leaf object so a drag re-renders the sliding page's offset alone
    /// and not the screen that owns the router.
    let slide = ScrollProgress()

    /// Set while a close swipe is in flight, so the page being swiped away
    /// holds still vertically instead of scrolling under the finger.
    let dragLock = FlagBox()

    /// How much of the screen underneath is covered: 1 while a page is fully
    /// over it, 0 with nothing open. Drives the parallax on the screen behind,
    /// the way a navigation pop eases the previous screen in from part-way
    /// across rather than having it sit still. A leaf, so a drag frame moves
    /// that one offset and re-renders nothing else.
    let cover = ScrollProgress()

    /// How far the screen underneath is pushed aside while fully covered.
    /// UIKit's own interactive pop uses about a third; a quarter reads the
    /// same here without the far edge of the page ever showing through.
    static let underlayParallax: CGFloat = 0.25

    /// How long the page takes to travel on and off under its own power.
    static let travel: TimeInterval = 0.3

    func open(_ newRoute: DetailRoute) {
        // Reset here rather than on close: the page is already gone by then,
        // and resetting in the same frame it is removed can flash it back on.
        slide.set(0)
        withAnimation(.easeOut(duration: Self.travel)) {
            route = newRoute
            cover.set(1)
        }
    }

    /// Chevron / programmatic close — the page slides off the same way it
    /// arrived.
    func close() {
        guard route != nil else { return }
        slide.set(0)
        withAnimation(.easeOut(duration: Self.travel)) {
            route = nil
            cover.set(0)
        }
    }

    /// Finish a swipe that has passed the threshold: carry the page the rest
    /// of the way out under the gesture's own momentum, then drop it once it
    /// is off-screen, with no second animation to play over the top.
    func finishSwipe() {
        let duration: TimeInterval = 0.2
        withAnimation(.easeOut(duration: duration)) {
            slide.set(1)
            cover.set(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { self.route = nil }
        }
    }

    /// Abandoned swipe — springs back under the screen edge.
    func cancelSwipe() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            slide.set(0)
            cover.set(1)
        }
    }

    /// Tracks a drag in progress: the screen underneath eases in by exactly as
    /// much as the page has travelled off.
    func trackSwipe(_ travelled: CGFloat) {
        slide.set(travelled)
        cover.set(1 - travelled)
    }
}

/// Restores the native interactive pop (the edge swipe that follows your
/// finger) inside a `NavigationStack` whose navigation bar is hidden.
///
/// The main stack hides its bar unconditionally — `.toolbar(.hidden, for:
/// .navigationBar)` in `MainViewModifiers` — and Settings nests its own
/// `NavigationStack` inside that content, so the sub-pages inherit the hidden
/// bar. UIKit's default delegate for `interactivePopGestureRecognizer` refuses
/// to begin while the bar is hidden, so the edge swipe never starts tracking:
/// the page sits still under your finger and only reacts once SwiftUI's own
/// fallback dismiss decides the drag counted. Handing the recognizer a
/// permissive delegate is the standard fix.
///
/// The delegate only lets the gesture begin when there is actually something
/// to pop. Clearing the delegate outright (the usual shortcut) lets a swipe
/// start on the root page, which pops nothing and wedges the stack.
fileprivate final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var navigationController: UINavigationController?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (navigationController?.viewControllers.count ?? 0) > 1
    }

    /// The pages are lists and scroll views. Without this the scroll pan and
    /// the edge pan both track and the page shears sideways while scrolling.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}

struct NavigationPopGestureUnlock: UIViewControllerRepresentable {
    final class Coordinator {
        /// Held strongly: `UIGestureRecognizer.delegate` is weak, and a
        /// deallocated delegate reads as "no delegate", which is the
        /// always-allow behaviour this type exists to avoid.
        fileprivate let delegate = PopGestureDelegate()
    }

    final class Host: UIViewController {
        var coordinator: Coordinator?

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            adopt()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            adopt()
        }

        /// `navigationController` resolves to the NEAREST enclosing stack, so
        /// this must be planted inside the stack it means to fix.
        private func adopt() {
            guard let nav = navigationController,
                  let recognizer = nav.interactivePopGestureRecognizer,
                  let coordinator else { return }
            coordinator.delegate.navigationController = nav
            recognizer.delegate = coordinator.delegate
            recognizer.isEnabled = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        host.coordinator = context.coordinator
        host.view.isUserInteractionEnabled = false
        return host
    }

    func updateUIViewController(_ uiViewController: Host, context: Context) {}
}
