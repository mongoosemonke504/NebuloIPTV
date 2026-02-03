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

struct SettingsList<Item: Identifiable>: View where Item.ID: Equatable {
    let items: [Item]
    let selectedItem: Item?
    let title: String
    let onSelect: (Item) -> Void
    let itemLabel: (Item) -> String
    
    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).foregroundColor(.white).padding()
            Divider().background(Color.white.opacity(0.3))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        Button(action: {
                            onSelect(item)
                        }) {
                            HStack {
                                Text(itemLabel(item))
                                Spacer()
                                if item.id == selectedItem?.id { Image(systemName: "checkmark") }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(item.id == selectedItem?.id ? .yellow : .white)
                        .padding(.vertical, 4).padding(.horizontal)
                    }
                }.padding(.top)
            }.frame(maxHeight: 200)
        }
    }
}
