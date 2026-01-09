import SwiftUI

// MARK: - HORIZONTAL SEARCH LIST
struct HorizontalSearchList: View {
    let channels: [StreamChannel]
    let viewModel: ChannelViewModel
    let accentColor: Color
    let playAction: (StreamChannel) -> Void
    @State private var channelForDescription: StreamChannel?
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(channels) { c in
                        Button(action: { playAction(c) }) {
                            SearchChannelContent(channel: c, viewModel: viewModel)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { viewModel.triggerRenameChannel(c) } label: { Label("Rename", systemImage: "pencil") }
                            Button { viewModel.hideChannel(c.id) } label: { Label("Hide", systemImage: "eye.slash") }
                            Button { viewModel.toggleFavorite(c.id) } label: { Label(viewModel.favoriteIDs.contains(c.id) ? "Unfavorite" : "Favorite", systemImage: viewModel.favoriteIDs.contains(c.id) ? "star.fill" : "star") }
                            if let prog = viewModel.getCurrentProgram(for: c), let desc = prog.description, !desc.isEmpty {
                                Button { channelForDescription = c } label: { Label("Description", systemImage: "text.alignleft") }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .frame(height: 170)
        .alert(item: $channelForDescription) { channel in
            Alert(
                title: Text("Program Description"),
                message: Text(viewModel.getCurrentProgram(for: channel)?.description ?? "No description available."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

struct SearchChannelContent: View {
    let channel: StreamChannel
    let viewModel: ChannelViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                CachedAsyncImage(urlString: channel.icon ?? "", size: CGSize(width: 180, height: 101)).blur(radius: 20).opacity(0.3)
                CachedAsyncImage(urlString: channel.icon ?? "", size: CGSize(width: 44, height: 44)).frame(height: 44).padding(4)
            }
            .frame(width: 180, height: 101)
            .modifier(GlassEffect(cornerRadius: 12, isSelected: false, accentColor: nil))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                
                if let prog = viewModel.getCurrentProgram(for: channel) {
                    Text(prog.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 172, height: 50, alignment: .topLeading)
            .padding(.horizontal, 4)
        }
    }
}

struct HorizontalPreviewList: View {
    let channels: [StreamChannel]; let isRecent: Bool; let accentColor: Color; let viewModel: ChannelViewModel
    let playAction: (StreamChannel) -> Void; let promptRenameChannel: (StreamChannel) -> Void; let hideChannel: (Int) -> Void; let removeFromRecent: (Int) -> Void
    @State private var channelForDescription: StreamChannel?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(channels) { c in
                    Button(action: { playAction(c) }) {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack {
                                CachedAsyncImage(urlString: c.icon ?? "", size: CGSize(width: 200, height: 112)).blur(radius: 20).opacity(0.3)
                                CachedAsyncImage(urlString: c.icon ?? "", size: CGSize(width: 52, height: 52)).frame(height: 52).padding(4)
                            }
                            .frame(width: 200, height: 112)
                            .modifier(GlassEffect(cornerRadius: 16, isSelected: false, accentColor: nil))
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                
                                if let prog = viewModel.getCurrentProgram(for: c) {
                                    Text(prog.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.6))
                                        .lineLimit(1)
                                        .frame(maxWidth: 192, alignment: .leading) // Explicitly constrain width to card content area
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    }.buttonStyle(.plain)
                    .contextMenu { 
                        Button { promptRenameChannel(c) } label: { Label("Rename", systemImage: "pencil") }
                        Button { hideChannel(c.id) } label: { Label("Hide", systemImage: "eye.slash") }
                        if isRecent { Button(role: .destructive) { removeFromRecent(c.id) } label: { Label("Remove", systemImage: "clock.badge.xmark") } }
                    }
                }
            }.padding(.horizontal, 20)
        }
        .frame(height: 175)
    }
}

// MARK: - HORIZONTAL RECORDING LIST
struct HorizontalRecordingList: View {
    let recordings: [Recording]
    let onSelect: (Recording) -> Void
    let onDelete: (Recording) -> Void
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(recordings) { recording in
                    Button(action: { onSelect(recording) }) {
                        RecordingCard(recording: recording)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete(recording)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 175)
    }
}

struct RecordingCard: View {
    let recording: Recording
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let icon = recording.channelIcon {
                    CachedAsyncImage(urlString: icon, size: CGSize(width: 200, height: 112)).blur(radius: 20).opacity(0.3)
                    CachedAsyncImage(urlString: icon, size: CGSize(width: 52, height: 52)).frame(height: 52).padding(4)
                } else {
                    Rectangle().fill(Color.white.opacity(0.05))
                    Image(systemName: "film").font(.system(size: 30)).foregroundColor(.white.opacity(0.3))
                }
                
                if recording.status == .recording {
                    VStack {
                        HStack {
                            Circle().fill(.red).frame(width: 6, height: 6)
                            Text("REC").font(.system(size: 9, weight: .black)).foregroundColor(.white)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                        .padding(8)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: 200, height: 112)
            .modifier(GlassEffect(cornerRadius: 16, isSelected: false, accentColor: nil))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.channelName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                
                Text(formatDate(recording.startTime))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
    }
    
    func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}

struct SquareCategoryCard: View {
    let title: String; let icon: String; let color: Color; let accentColor: Color
    var body: some View {
        VStack(spacing: 8) { // Change to VStack for vertical layout
            Image(systemName: icon)
                .font(.system(size: 36, weight: .bold)) // Much larger icon font size
                .foregroundColor(color)
                .frame(width: 60, height: 60) // Larger icon frame
                .background(color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 16)) // Adjust corner radius for larger frame
            
            Text(title)
                .font(.system(size: 15, weight: .bold)) // Keep same text font size
                .foregroundStyle(.white)
                .lineLimit(1) // Ensure single line for title
        }
        .padding(16) // Adjust overall padding
        .frame(maxWidth: .infinity, minHeight: 120) // Taller minHeight for the button
        .modifier(GlassEffect(cornerRadius: 16, isSelected: false, accentColor: nil))
    }
}

struct CategoryCard: View, Equatable {
    let title: String; var icon: String? = nil; var color: Color; var lineLimit: Int = 1
    static func == (lhs: CategoryCard, rhs: CategoryCard) -> Bool { lhs.title == rhs.title && lhs.icon == rhs.icon && lhs.color == rhs.color }
    
    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold)) // Smaller and less bold
            .foregroundStyle(.white)
            .lineLimit(2) // Allow two lines
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 15) // Adjust vertical padding for better fit
            .frame(maxWidth: .infinity, minHeight: 80) // Ensure enough height for two lines
            .modifier(GlassEffect(cornerRadius: 16, isSelected: false, accentColor: nil))
    }
}

struct AllChannelsCard: View {
    let title: String
    let icon: String
    let channelCount: Int
    let accentColor: Color
    
    var body: some View {
        HStack(spacing: 12) { // Main horizontal stack
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold)) // Slightly larger icon than SquareCategoryCard
                .foregroundColor(.white) // Keep icon white
                .frame(width: 40, height: 40) // Adjust frame for icon
                .background(Color.blue.opacity(0.1)) // Subtle background for the icon
                .clipShape(RoundedRectangle(cornerRadius: 10)) // Rounded corners for icon background
            
            VStack(alignment: .leading, spacing: 2) { // Vertical stack for title and count
                Text(title)
                    .font(.system(size: 16, weight: .bold)) // Font for "All Channels"
                    .foregroundStyle(.white)
                    .lineLimit(1)
                
                Text("\(channelCount) Channels")
                    .font(.caption) // Smaller font for count
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            
            Spacer() // Push content to the left
        }
        .padding(.vertical, 12) // Adjust vertical padding for compactness
        .padding(.horizontal, 16) // Adjust horizontal padding
        .frame(maxWidth: .infinity, minHeight: 60) // Make it single line tall
        .modifier(GlassEffect(cornerRadius: 16, isSelected: false, accentColor: nil)) // Keep glass effect
    }
}


struct ChannelRow: View, Equatable {
    let channel: StreamChannel; let epgProgram: EPGProgram?; let isFavorite: Bool; let accentColor: Color; var isCompact: Bool = false; let playAction: () -> Void; let toggleFav: () -> Void
    
    static func == (lhs: ChannelRow, rhs: ChannelRow) -> Bool { lhs.channel == rhs.channel && lhs.isFavorite == rhs.isFavorite && lhs.accentColor == rhs.accentColor && lhs.isCompact == rhs.isCompact && lhs.epgProgram?.id == rhs.epgProgram?.id }
    
    var body: some View {
        Button(action: playAction) {
            HStack(spacing: 16) {
                ZStack {
                    CachedAsyncImage(urlString: channel.icon ?? "", size: CGSize(width: 50, height: 50))
                        .frame(width: 50, height: 50)
                }
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    
                    if let prog = epgProgram {
                        Text(prog.title)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                Button(action: toggleFav) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 18))
                        .foregroundStyle(isFavorite ? accentColor : .white.opacity(0.2))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}