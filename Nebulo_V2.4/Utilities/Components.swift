import SwiftUI

// MARK: - COMMON COMPONENTS
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

// MARK: - SKELETONS
// Note: SkeletonBox is defined in Modifiers.swift

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
