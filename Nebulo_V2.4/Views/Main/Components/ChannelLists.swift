import SwiftUI

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
                .padding(.horizontal)
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
                CachedAsyncImage(urlString: channel.icon ?? "", size: nil).frame(height: 44).padding(4)
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
                        .foregroundStyle(.white.opacity(0.8))
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
                                CachedAsyncImage(urlString: c.icon ?? "", size: nil).frame(height: 52).padding(4)
                            }.frame(width: 200, height: 112).modifier(GlassEffect(cornerRadius: 12, isSelected: false, accentColor: nil))
                            
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
                                } else {
                                    Text(" ")
                                        .font(.system(size: 12))
                                }
                            }
                            .frame(width: 192, height: 40, alignment: .topLeading) 
                            .padding(.horizontal, 4)
                        }
                    }.buttonStyle(.plain)
                    .contextMenu { 
                        Button { promptRenameChannel(c) } label: { Label("Rename", systemImage: "pencil") }
                        Button { hideChannel(c.id) } label: { Label("Hide", systemImage: "eye.slash") }
                        if isRecent { Button(role: .destructive) { removeFromRecent(c.id) } label: { Label("Remove", systemImage: "clock.badge.xmark") } }
                        if let prog = viewModel.getCurrentProgram(for: c), let desc = prog.description, !desc.isEmpty {
                            Button { channelForDescription = c } label: { Label("Description", systemImage: "text.alignleft") }
                        }
                    }
                }
            }.padding(.horizontal)
        }
        .frame(height: 175) 
        .alert(item: $channelForDescription) { channel in
            Alert(
                title: Text("Program Description"),
                message: Text(viewModel.getCurrentProgram(for: channel)?.description ?? "No description available."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

struct SquareCategoryCard: View { let title: String; let icon: String; let color: Color; let accentColor: Color; var body: some View { VStack(alignment: .center, spacing: 12) { Image(systemName: icon).font(.system(size: 40)).foregroundColor(color); Text(title).font(.headline).fontWeight(.bold).foregroundStyle(.white).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).frame(height: 140).modifier(GlassEffect(cornerRadius: 16, isSelected: false, accentColor: accentColor)).overlay(RoundedRectangle(cornerRadius: 16).stroke(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)) } }
struct CategoryCard: View, Equatable { let title: String; var icon: String? = nil; var color: Color; var lineLimit: Int = 1; static func == (lhs: CategoryCard, rhs: CategoryCard) -> Bool { lhs.title == rhs.title && lhs.icon == rhs.icon && lhs.color == rhs.color }; var body: some View { HStack { if let icon = icon { Image(systemName: icon).foregroundColor(color).frame(width: 30) }; Text(title).font(.headline).lineLimit(lineLimit).foregroundStyle(.white); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.6)) }.padding().frame(maxWidth: .infinity).modifier(GlassEffect(cornerRadius: 12, isSelected: true, accentColor: nil)) } }

struct ChannelRow: View, Equatable {
    let channel: StreamChannel; let epgProgram: EPGProgram?; let isFavorite: Bool; let accentColor: Color; var isCompact: Bool = false; let playAction: () -> Void; let toggleFav: () -> Void
    
    static func == (lhs: ChannelRow, rhs: ChannelRow) -> Bool { lhs.channel == rhs.channel && lhs.isFavorite == rhs.isFavorite && lhs.accentColor == rhs.accentColor && lhs.isCompact == rhs.isCompact && lhs.epgProgram?.id == rhs.epgProgram?.id }
    
    var body: some View {
        Button(action: playAction) {
            HStack(spacing: 12) {
                CachedAsyncImage(urlString: channel.icon ?? "", size: CGSize(width: isCompact ? 40 : 50, height: isCompact ? 40 : 50))
                    .frame(width: isCompact ? 40 : 50, height: isCompact ? 40 : 50)
                    .padding(2)
                    .cornerRadius(8)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.name)
                        .font(isCompact ? .system(size: 14, weight: .semibold) : .system(size: 16, weight: .bold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                    
                    if let prog = epgProgram {
                        Text(prog.title)
                            .font(isCompact ? .system(size: 11) : .caption2)
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: isCompact ? 40 : 50, alignment: .leading)
                
                Spacer()
                
                Button(action: toggleFav) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? accentColor : .gray.opacity(0.5))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Divider().padding(.leading, isCompact ? 60 : 70).opacity(0.1), alignment: .bottom)
        .frame(minHeight: isCompact ? 60 : 70)
        .frame(maxWidth: .infinity)
        .drawingGroup()
    }
}