import SwiftUI

// MARK: - SKELETON VIEWS
struct ChannelRowSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonBox(height: 55).frame(width: 55).cornerRadius(8)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBox(width: 140, height: 16)
                SkeletonBox(width: 200, height: 12)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

struct HorizontalCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBox(height: 101).frame(width: 180).cornerRadius(12)
            SkeletonBox(width: 120, height: 14)
            SkeletonBox(width: 160, height: 10)
        }
    }
}

struct CategoryCardSkeleton: View {
    var body: some View {
        SkeletonBox(height: 54).cornerRadius(12).padding(.horizontal)
    }
}

struct SquareCardSkeleton: View {
    var body: some View {
        SkeletonBox(height: 140).cornerRadius(16)
    }
}
