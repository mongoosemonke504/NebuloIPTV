import SwiftUI

struct SportsHubView: View {
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color; let playAction: (StreamChannel) -> Void; var onBack: (() -> Void)? = nil
    @ObservedObject var scoreViewModel: ScoreViewModel
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                SportSelectorView(selectedSport: $scoreViewModel.selectedSport) { Task { await scoreViewModel.fetchScores() } }
                TabView(selection: $scoreViewModel.selectedSport) {
                    ForEach(SportType.allCases) { sport in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 12) {
                                let filtered = scoreViewModel.filteredGames[sport] ?? []
                                if filtered.isEmpty {
                                    if scoreViewModel.isLoading { ProgressView().tint(.white).padding(.top, 100) }
                                    else { EmptyStateView(title: "No Match Data", systemImage: "calendar.badge.exclamationmark", description: "No matches found for \(sport.rawValue).").frame(height: 300) }
                                } else {
                                    if sport == .soccer {
                                        let sections = scoreViewModel.soccerSections
                                        ForEach(sections, id: \.league) { s in
                                            Section(header: Text(s.league.uppercased()).font(.caption.bold()).foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity, alignment: .leading).padding(.top)) {
                                                ForEach(s.games) { game in scoreButton(game: game, sport: sport) }
                                            }
                                        }
                                    } else { ForEach(filtered) { game in scoreButton(game: game, sport: sport) } }
                                }
                            }.padding(.horizontal).padding(.bottom, 120)
                        }.tag(sport)
                    }
                }.tabViewStyle(.page(indexDisplayMode: .never))
            }
            if viewModel.isSearchingGame {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 15) { ProgressView().tint(.white); Text("Finding best stream...").font(.caption).bold().foregroundStyle(.white) }.padding(25).background(.ultraThinMaterial).cornerRadius(20).shadow(radius: 20)
                }.transition(.opacity).zIndex(100)
            }
        }
        .navigationTitle("Sports Center").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { if let onBack = onBack { Button(action: onBack) { HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Back") } }.foregroundStyle(.white) } } }
        .task { 
            await scoreViewModel.fetchScores()
            scoreViewModel.applyFilter(text: viewModel.searchText)
        }
        .onChangeCompat(of: scoreViewModel.selectedSport) { _ in Task { await scoreViewModel.fetchScores() } }
        .onChangeCompat(of: viewModel.searchText) { text in scoreViewModel.applyFilter(text: text) }
        .sheet(isPresented: $viewModel.showSelectionSheet) { ManualSelectionSheet(viewModel: viewModel, accentColor: accentColor, playAction: playAction) }
    }
    private func scoreButton(game: ESPNEvent, sport: SportType) -> some View {
        Button(action: { 
            let h = game.homeCompetitor?.team?.shortDisplayName ?? game.homeCompetitor?.athlete?.shortName ?? ""
            let a = game.awayCompetitor?.team?.shortDisplayName ?? game.awayCompetitor?.athlete?.shortName ?? ""
            viewModel.runSmartSearch(home: h, away: a, sport: sport, network: game.broadcastName)
        }) { ScoreRow(game: game, sport: sport).equatable() }.buttonStyle(.plain)
    }
}

struct ManualSelectionSheet: View {
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color; let playAction: (StreamChannel) -> Void; @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List(viewModel.suggestedChannels) { channel in
                Button(action: { dismiss(); playAction(channel) }) {
                    HStack {
                        CachedAsyncImage(urlString: channel.icon ?? "", size: CGSize(width: 35, height: 35)).cornerRadius(8)
                        VStack(alignment: .leading) {
                            Text(channel.name).font(.headline).foregroundStyle(.primary)
                            if let live = viewModel.getCurrentProgram(for: channel) {
                                Text(live.title).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer(); Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(accentColor)
                    }
                }
            }.navigationTitle("Select Stream").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.medium])
    }
}

struct ScoreRow: View, Equatable {
    let game: ESPNEvent; let sport: SportType
    static func == (lhs: ScoreRow, rhs: ScoreRow) -> Bool { lhs.game.id == rhs.game.id }
    var body: some View { 
        VStack(spacing: 0) { 
            if sport == .f1 { 
                raceLayout 
            } else { 
                teamLayout 
            } 
        }
        .padding(.vertical, 18).padding(.horizontal, 12)
        .background(Color.black.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1)) 
    }
    
    private var teamLayout: some View { HStack(alignment: .center, spacing: 4) { if let away = game.awayCompetitor { TeamColumn(competitor: away, align: .trailing).frame(maxWidth: .infinity) }; VStack(spacing: 6) { Text(game.status.type.detail.uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(game.status.type.state == "in" ? .red : .secondary).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8).frame(minWidth: 70, maxWidth: 100); if let cn = game.broadcastName { Text(cn).font(.system(size: 10, weight: .black)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2).background(Color.white.opacity(0.15)).cornerRadius(4) }; Capsule().fill(Color.white.opacity(0.1)).frame(width: 1.5, height: 20) }; if let home = game.homeCompetitor { TeamColumn(competitor: home, align: .leading).frame(maxWidth: .infinity) } } }
    
    private var raceLayout: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(game.shortName).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 8) {
                    Text(game.status.type.detail).font(.system(size: 13)).foregroundStyle(game.status.type.state == "in" ? .red : .secondary)
                    if let cn = game.broadcastName {
                        Text(cn).font(.system(size: 10, weight: .black)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1).background(Color.white.opacity(0.15)).cornerRadius(3)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

struct TeamColumn: View {
    let competitor: ESPNCompetitor; let align: HorizontalAlignment
    var body: some View { 
        let name = competitor.team?.shortDisplayName ?? competitor.team?.abbreviation ?? competitor.athlete?.shortName ?? competitor.athlete?.displayName ?? "Unknown"
        let logo = competitor.team?.logo ?? competitor.athlete?.flag?.href ?? competitor.athlete?.headshot ?? ""
        let score = competitor.score ?? "0"
        return HStack(spacing: 8) { if align == .trailing { teamInfoStack(n: name, l: logo); scoreText(s: score) } else { scoreText(s: score); teamInfoStack(n: name, l: logo) } } 
    }
    private func teamInfoStack(n: String, l: String) -> some View { VStack(spacing: 4) { CachedAsyncImage(urlString: l, size: CGSize(width: 32, height: 32)).frame(width: 32, height: 32).padding(2); Text(n).font(.system(size: 13, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(1).minimumScaleFactor(0.75) }.frame(maxWidth: .infinity) }
    private func scoreText(s: String) -> some View { Text(s).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1).fixedSize(horizontal: true, vertical: false).frame(minWidth: 40) }
}

struct SportSelectorView: View {
    @Binding var selectedSport: SportType; let action: () -> Void
    var body: some View { ScrollViewReader { proxy in ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 12) { ForEach(SportType.allCases) { s in Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { selectedSport = s }; action() }) { Text(s.rawValue).font(.caption.bold()).padding(.vertical, 8).padding(.horizontal, 16).background(selectedSport == s ? Color.white : Color.white.opacity(0.1)).foregroundColor(selectedSport == s ? .black : .white).clipShape(Capsule()) }.id(s) } }.padding(.horizontal).padding(.vertical, 10) }.onAppear { proxy.scrollTo(selectedSport, anchor: .center) }.onChangeCompat(of: selectedSport) { ns in withAnimation(.spring()) { proxy.scrollTo(ns, anchor: .center) } } } }
}
