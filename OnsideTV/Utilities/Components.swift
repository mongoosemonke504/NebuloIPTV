import SwiftUI

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String?
    
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundColor(.gray)
            Text(title)
                .font(.headline)
                .foregroundColor(.gray)
            if let description = description {
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}

struct ChannelRowSkeleton: View {
    var body: some View {
        HStack(spacing: 16) {
            SkeletonBox(width: 50, height: 50).cornerRadius(12)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBox(width: 150, height: 16)
                SkeletonBox(width: 100, height: 12)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

struct HorizontalCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBox(width: 200, height: 112).cornerRadius(16)
            SkeletonBox(width: 120, height: 14)
            SkeletonBox(width: 80, height: 12)
        }
    }
}

struct SquareCardSkeleton: View {
    var body: some View {
        SkeletonBox(height: 120).frame(maxWidth: .infinity).cornerRadius(16)
    }
}

struct DashboardCardSkeleton: View {
    var body: some View {
        SkeletonBox(height: 120).frame(maxWidth: .infinity).cornerRadius(12)
    }
}

struct FullWidthCardSkeleton: View {
    var body: some View {
        SkeletonBox(height: 70).frame(maxWidth: .infinity).cornerRadius(12)
    }
}

struct CategoryCardSkeleton: View {
    var body: some View {
        SkeletonBox(height: 70).frame(maxWidth: .infinity).cornerRadius(12)
    }
}

/// Picker list for the player's settings panels (subtitles, audio, quality,
/// aspect ratio) — glass-pill rows in the app's chip language: translucent
/// at rest, solid white with black text when selected.
struct SettingsList<Item: Identifiable>: View where Item.ID: Equatable {
    let items: [Item]
    let selectedItem: Item?
    let title: String
    let onSelect: (Item) -> Void
    let itemLabel: (Item) -> String

    var body: some View {
        VStack(spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .black))
                .kerning(1.2)
                .foregroundStyle(.white.opacity(0.65))
                .padding(.top, 18)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        let isSelected = item.id == selectedItem?.id
                        Button {
                            ChannelViewModel.shared.triggerSelectionHaptic()
                            onSelect(item)
                        } label: {
                            HStack {
                                Text(itemLabel(item))
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                }
                            }
                            .foregroundStyle(isSelected ? .black : .white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(
                                Capsule().fill(isSelected ? Color.white : Color.white.opacity(0.08))
                            )
                            .overlay(
                                Capsule().stroke(Color.white.opacity(isSelected ? 0 : 0.10), lineWidth: 0.5)
                            )
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: 280)
        }
    }
}
