import SwiftUI

// MARK: - RECENT SEARCHES COMPONENT
struct RecentSearchesView: View {
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color
    
    var body: some View {
        if !viewModel.recentQueries.isEmpty {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("RECENT SEARCHES")
                        .font(.system(size: 11, weight: .black))
                        .kerning(1.2)
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Button(action: {
                        withAnimation {
                            viewModel.clearRecentQueries()
                        }
                    }) {
                        Text("Clear All")
                            .font(.caption2.bold())
                            .foregroundColor(accentColor)
                    }
                }
                .padding(.horizontal)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.recentQueries, id: \.self) { (query: String) in
                            HStack(spacing: 8) {
                                Button(action: { viewModel.searchText = query }) {
                                    Text(query)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white)
                                }
                                
                                Button(action: { viewModel.removeRecentQuery(query) }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Material.ultraThinMaterial)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}
