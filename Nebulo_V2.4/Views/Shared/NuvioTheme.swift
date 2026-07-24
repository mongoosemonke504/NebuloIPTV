import SwiftUI

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

/// Hero pager dots — the current page is an elongated white capsule, the
/// rest are small translucent circles.
struct NuvioPageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i == index ? 1.0 : 0.55))
                    .frame(width: i == index ? 26 : 7, height: 7)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: index)
            }
        }
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

/// The floating rounded dock from the reference recording: a translucent
/// charcoal slab with icon-over-label tabs, the active tab wrapped in a
/// lighter rounded pill. Pure presentation — the owner decides what each
/// tab tap does, so all existing navigation machinery stays intact.
struct NuvioTabDock: View {
    let active: NuvioTab
    let onSelect: (NuvioTab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(NuvioTab.allCases, id: \.self) { tab in
                Button {
                    ChannelViewModel.shared.triggerSelectionHaptic()
                    onSelect(tab)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 19, weight: .semibold))
                            .frame(height: 22)
                        Text(tab.rawValue)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(tab == active ? .white : Color.white.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 21, style: .continuous)
                            .fill(tab == active ? NuvioTheme.chipSelected : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(NuvioTheme.dockFill.opacity(0.92))
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 30, style: .continuous)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 24)
        .padding(.bottom, 2)
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
    }
}

// MARK: - Shelf card chrome

/// Flat charcoal 16:9 artwork tile used by the shelf cards — replaces the
/// glass/glow tiles on the main screens so cards sit flat on the black
/// canvas like the reference.
struct NuvioCardSurface: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(NuvioTheme.card)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
    }
}

extension View {
    func nuvioCard(cornerRadius: CGFloat = 12) -> some View {
        modifier(NuvioCardSurface(cornerRadius: cornerRadius))
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
