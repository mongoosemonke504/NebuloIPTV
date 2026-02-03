import SwiftUI
import UIKit
import UserNotifications

struct SportsHubView: View {
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color; let playAction: (StreamChannel) -> Void; var onBack: (() -> Void)? = nil
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Environment(\.scenePhase) var scenePhase
    @State private var isRefreshingAnimation = false
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                SportSelectorView(selectedSport: $scoreViewModel.selectedSport, pinnedCount: scoreViewModel.allPinnedGames.count, orderedSports: scoreViewModel.sportTabOrder.filter { !scoreViewModel.hiddenSportTabs.contains($0) }, scoreViewModel: scoreViewModel) {
                    Task { await scoreViewModel.fetchScores() }
                }
                
                TabView(selection: $scoreViewModel.selectedSport) {
                    ForEach(scoreViewModel.sportTabOrder.filter { !scoreViewModel.hiddenSportTabs.contains($0) }) { sport in
                        SportGamesListView(
                            sport: sport,
                            scoreViewModel: scoreViewModel,
                            viewModel: viewModel
                        )
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            
            if viewModel.isSearchingGame {
                loadingOverlay
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { 
            ToolbarItem(placement: .principal) {
                Button(action: {
                    ChannelViewModel.shared.triggerSelectionHaptic()
                    Task { await scoreViewModel.fetchScores(forceRefresh: true) }
                }) {
                    Text("Sports")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .opacity(isRefreshingAnimation ? 0.3 : 1.0)
                }
            }
            ToolbarItem(placement: .topBarLeading) { 
                Group {
                    if let onBack = onBack { 
                        Button(action: onBack) { 
                            HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Back") } 
                        }
                        .foregroundStyle(.white) 
                    }
                }
            }
        }
        .task { 
            await scoreViewModel.fetchScores()
            scoreViewModel.applyFilter(text: viewModel.searchText)
            triggerPreResolution()
        }
        .onAppear {
            if scoreViewModel.isLoading {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isRefreshingAnimation = true
                }
            }
        }
        .onChangeCompat(of: scoreViewModel.isLoading) { loading in
            if loading {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isRefreshingAnimation = true
                }
            } else {
                withAnimation(.default) {
                    isRefreshingAnimation = false
                }
                triggerPreResolution()
            }
        }
        .onChangeCompat(of: scenePhase) { phase in
            if phase == .active {
                Task { 
                    await scoreViewModel.fetchScores(forceRefresh: true, silent: true)
                    triggerPreResolution()
                }
            }
        }
        .onChangeCompat(of: scoreViewModel.selectedSport) { _ in 
            Task { 
                await scoreViewModel.fetchScores()
                triggerPreResolution()
            } 
        }
        .onChangeCompat(of: viewModel.searchText) { text in 
            scoreViewModel.applyFilter(text: text)
            triggerPreResolution()
        }
        .sheet(isPresented: $viewModel.showSelectionSheet) { ManualSelectionSheet(viewModel: viewModel, accentColor: accentColor, playAction: playAction) }
    }
    
    private func triggerPreResolution() {
        let sport = scoreViewModel.selectedSport
        let games: [ESPNEvent]
        if isSoccerCategory(sport) {
            games = scoreViewModel.filteredSectionsMap[sport]?.flatMap { $0.games } ?? []
        } else {
            games = scoreViewModel.filteredGames[sport] ?? []
        }
        
        if !games.isEmpty {
            viewModel.preResolveGames(games)
        }
    }
    
    private func isSoccerCategory(_ sport: SportType) -> Bool {
        return sport == .soccerLeagues || sport == .domesticCups || sport == .continental || sport == .international
    }
    
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 15) {
                CustomSpinner(color: .white, lineWidth: 4, size: 40)
                Text("Finding best stream...").font(.caption).bold().foregroundStyle(.white)
            }
            .padding(25)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .shadow(radius: 20)
        }
        .transition(.opacity)
        .zIndex(100)
    }
}

struct SportGamesListView: View {
    let sport: SportType
    @ObservedObject var scoreViewModel: ScoreViewModel
    @ObservedObject var viewModel: ChannelViewModel
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                if sport == .pinned {
                    if scoreViewModel.allPinnedGames.isEmpty {
                        EmptyStateView(title: "No Pinned Games", systemImage: "pin.slash", description: "Pin games to see them here.").frame(height: 300)
                    } else {
                        ForEach(scoreViewModel.allPinnedGames) { game in
                            scoreButton(game: game, sport: .nfl) 
                        }
                    }
                } else if isSoccerCategory(sport) {
                    if let sections = scoreViewModel.filteredSectionsMap[sport], !sections.isEmpty {
                        
                        let allSoccerGames = sections.flatMap { $0.games }
                        let pinnedSoccer = allSoccerGames.filter { scoreViewModel.pinnedGameIDs.contains($0.id) }
                        
                        if !pinnedSoccer.isEmpty {
                            Section(header: subCategoryHeader("Pinned")) {
                                ForEach(pinnedSoccer) { game in
                                    scoreButton(game: game, sport: .soccerLeagues)
                                }
                            }
                        }
                        
                        ForEach(sections, id: \.league) { s in
                            let remainingGames = s.games.filter { !scoreViewModel.pinnedGameIDs.contains($0.id) }
                            if !remainingGames.isEmpty {
                                Section(header: leagueHeader(s.league)) {
                                    ForEach(remainingGames) { game in
                                        scoreButton(game: game, sport: .soccerLeagues) 
                                    }
                                }
                            }
                        }
                    } else {
                        emptyState
                    }
                } else {
                    let filtered = scoreViewModel.filteredGames[sport] ?? []
                    if filtered.isEmpty {
                        emptyState
                    } else {
                        let pinned = filtered.filter { scoreViewModel.pinnedGameIDs.contains($0.id) }
                        let unpinned = filtered.filter { !scoreViewModel.pinnedGameIDs.contains($0.id) }
                        
                        if !pinned.isEmpty {
                            Section(header: subCategoryHeader("Pinned")) {
                                ForEach(pinned) { game in
                                    scoreButton(game: game, sport: sport)
                                }
                            }
                        }
                        
                        if !unpinned.isEmpty {
                            Section(header: pinned.isEmpty ? AnyView(EmptyView()) : AnyView(subCategoryHeader("Games"))) {
                                ForEach(unpinned) { game in
                                    scoreButton(game: game, sport: sport)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 120)
        }
        .tag(sport)
    }
    
    private func subCategoryHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
    
    private func isSoccerCategory(_ sport: SportType) -> Bool {
        return sport == .soccerLeagues || sport == .domesticCups || sport == .continental || sport == .international
    }
    
    @ViewBuilder
    private var emptyState: some View {
        if scoreViewModel.isLoading {
            CustomSpinner(color: .white, lineWidth: 4, size: 40).padding(.top, 100)
        }
        else {
            EmptyStateView(title: "No Match Data", systemImage: "calendar.badge.exclamationmark", description: "No matches found for \(sport.rawValue).").frame(height: 300)
        }
    }
    
    private func soccerSectionsView(sections: [SoccerGameSection]) -> some View {
        ForEach(sections, id: \.league) { s in
            Section(header: leagueHeader(s.league)) {
                ForEach(s.games) { game in
                    scoreButton(game: game, sport: .soccerLeagues) 
                }
            }
        }
    }
    
    private func leagueHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.bold())
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top)
    }
    
    private func scoreButton(game: ESPNEvent, sport: SportType) -> some View {
        Button(action: { 
            ChannelViewModel.shared.triggerSelectionHaptic()
            let h = game.homeCompetitor?.team?.shortDisplayName ?? game.homeCompetitor?.athlete?.shortName ?? ""
            let a = game.awayCompetitor?.team?.shortDisplayName ?? game.awayCompetitor?.athlete?.shortName ?? ""
            viewModel.runSmartSearch(gameID: game.id, home: h, away: a, sport: sport, network: game.broadcastName)
        }) {
            ScoreRow(game: game, sport: sport, isScoreHidden: scoreViewModel.hiddenScoreGameIDs.contains(game.id), isReminderSet: scoreViewModel.reminderGameIDs.contains(game.id))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                let h = game.homeCompetitor?.team?.shortDisplayName ?? game.homeCompetitor?.athlete?.shortName ?? ""
                let a = game.awayCompetitor?.team?.shortDisplayName ?? game.awayCompetitor?.athlete?.shortName ?? ""
                viewModel.showStreamOptions(home: h, away: a, sport: sport, network: game.broadcastName)
            } label: {
                Label("Stream List", systemImage: "list.bullet")
            }
            
            Button {
                let h = game.homeCompetitor?.team?.shortDisplayName ?? game.homeCompetitor?.athlete?.shortName ?? ""
                let a = game.awayCompetitor?.team?.shortDisplayName ?? game.awayCompetitor?.athlete?.shortName ?? ""
                viewModel.autoAddGameToMultiView(home: h, away: a, network: game.broadcastName)
            } label: {
                Label("Add to Multi-View", systemImage: "square.grid.2x2")
            }
            
            Button {
                let query = "\(game.shortName) highlights"
                if let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let url = URL(string: "https://www.youtube.com/results?search_query=\(encoded)") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Find Highlights", systemImage: "play.rectangle.fill")
            }
            
            Button {
                scoreViewModel.toggleReminder(game)
            } label: {
                Label(scoreViewModel.reminderGameIDs.contains(game.id) ? "Cancel Reminder" : "Set Reminder", systemImage: scoreViewModel.reminderGameIDs.contains(game.id) ? "bell.slash" : "bell")
            }
            
            Button {
                scoreViewModel.togglePin(game.id)
            } label: {
                Label(scoreViewModel.pinnedGameIDs.contains(game.id) ? "Unpin" : "Pin", systemImage: scoreViewModel.pinnedGameIDs.contains(game.id) ? "pin.slash" : "pin")
            }
            
            Button {
                scoreViewModel.toggleHideScore(game.id)
            } label: {
                Label(scoreViewModel.hiddenScoreGameIDs.contains(game.id) ? "Show Score" : "Hide Score", systemImage: scoreViewModel.hiddenScoreGameIDs.contains(game.id) ? "eye" : "eye.slash")
            }
        }
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
                            HStack(spacing: 6) {
                                Text(channel.name).font(.headline).foregroundStyle(.primary)
                                
                                let fullInfo = "\(channel.name) \(viewModel.getCurrentProgram(for: channel)?.title ?? "") \(viewModel.getCurrentProgram(for: channel)?.description ?? "")"
                                
                                let q = SmartSearchLogic.detectQuality(fullInfo, width: channel.width, height: channel.height)
                                if q != .unknown {
                                    Text(q.rawValue.components(separatedBy: " ").first ?? "SD")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.8))
                                        .cornerRadius(4)
                                }
                                
                                let lang = SmartSearchLogic.detectLanguage(fullInfo)
                                Text(lang?.rawValue.prefix(2).uppercased() ?? "??")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.8))
                                    .cornerRadius(4)
                            }
                            if let live = viewModel.getCurrentProgram(for: channel) {
                                Text(live.title).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer(); Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(accentColor)
                    }
                }
                .onAppear { viewModel.prewarmChannel(channel) }
            }.navigationTitle("Select Stream").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.medium])
    }
}

struct ScoreRow: View {
    let game: ESPNEvent; let sport: SportType; var isScoreHidden: Bool = false; var isReminderSet: Bool = false
    var body: some View { 
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) { 
                if sport == .f1 {  
                    raceLayout 
                } else { 
                    teamLayout 
                } 
            }
            .padding(.vertical, 18).padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1)) 
            
            if isReminderSet {
                Image(systemName: "bell.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 10, weight: .bold))
                    .padding(8)
            }
        }
    }
    
    private var teamLayout: some View { HStack(alignment: .center, spacing: 4) { if let away = game.awayCompetitor { TeamColumn(competitor: away, gameState: game.status.type.state, align: .trailing, isScoreHidden: isScoreHidden).frame(maxWidth: .infinity) }; VStack(spacing: 6) { Text(game.status.type.detail.uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(game.status.type.state == "in" ? .red : .secondary).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8).frame(minWidth: 70, maxWidth: 100); if let cn = game.broadcastName { Text(cn).font(.system(size: 10, weight: .black)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2).background(Color.white.opacity(0.15)).cornerRadius(4) }; Capsule().fill(Color.white.opacity(0.1)).frame(width: 1.5, height: 20) }; if let home = game.homeCompetitor { TeamColumn(competitor: home, gameState: game.status.type.state, align: .leading, isScoreHidden: isScoreHidden).frame(maxWidth: .infinity) } } }
    
    
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
    let competitor: ESPNCompetitor; let gameState: String; let align: HorizontalAlignment; var isScoreHidden: Bool = false
    var body: some View { 
        let name = competitor.team?.shortDisplayName ?? competitor.team?.abbreviation ?? competitor.athlete?.shortName ?? competitor.athlete?.displayName ?? "Unknown"
        let logo = competitor.team?.logo ?? competitor.athlete?.flag?.href ?? competitor.athlete?.headshot ?? ""
        let score = isScoreHidden ? "?" : (gameState == "pre" ? "" : (competitor.score ?? "0"))
        
        return HStack(spacing: 8) { if align == .trailing { teamInfoStack(n: name, l: logo); scoreText(s: score) } else { scoreText(s: score); teamInfoStack(n: name, l: logo) } } 
    }
    private func teamInfoStack(n: String, l: String) -> some View { VStack(spacing: 4) { CachedAsyncImage(urlString: l, size: CGSize(width: 32, height: 32)).frame(width: 32, height: 32).padding(2); Text(n).font(.system(size: 13, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(1).minimumScaleFactor(0.75) }.frame(maxWidth: .infinity) }
    private func scoreText(s: String) -> some View { Text(s).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1).fixedSize(horizontal: true, vertical: false).frame(minWidth: 40) }
}

struct SportSelectorView: View {
    @Binding var selectedSport: SportType; let pinnedCount: Int; let orderedSports: [SportType]; @ObservedObject var scoreViewModel: ScoreViewModel; let action: () -> Void
    var body: some View { ScrollViewReader { proxy in ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 12) { 
        ForEach(orderedSports) { s in Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { selectedSport = s }; action() }) { Text(scoreViewModel.getSportName(s) + (s == .pinned ? " (\(pinnedCount))" : "")).font(.caption.bold()).padding(.vertical, 8).padding(.horizontal, 16).background(selectedSport == s ? Color.white : Color.white.opacity(0.1)).foregroundColor(selectedSport == s ? .black : .white).clipShape(Capsule()) }.id(s) } }.padding(.horizontal).padding(.vertical, 10) }.onAppear { proxy.scrollTo(selectedSport, anchor: .center) }.onChangeCompat(of: selectedSport) { ns in withAnimation(.spring()) { proxy.scrollTo(ns, anchor: .center) } } } }
}
