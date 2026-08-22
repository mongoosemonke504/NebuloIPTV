import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    @AppStorage("customAccentHex") private var customAccentHex = "#FFFFFF"
    
    @Binding var categories: [StreamCategory]
    let accentColor: Color
    var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    let playAction: ((StreamChannel) -> Void)?
    let onSave: () -> Void
    /// True when Settings renders as the Profile TAB (in-hierarchy, bar
    /// visible) instead of a presented sheet: hides the Done button and
    /// pads the bottom clear of the floating bar.
    var isSection: Bool = false
    /// Opens Multi-View. It lives here rather than on the home screen — a
    /// utility alongside Recordings, not a browsing surface.
    var openMultiView: (() -> Void)? = nil
    
    @AppStorage("xstreamURL") private var xstreamURL = ""
    @AppStorage("username") private var username = ""
    @AppStorage("password") private var password = ""
    @AppStorage("loginTypeRaw") private var loginTypeRaw = LoginType.xtream.rawValue 
    @AppStorage("showSupportPopup") private var showSupportPopup = true

    @ObservedObject var accountManager = AccountManager.shared
    @ObservedObject var updateService = UpdateService.shared
    
    /// 0 at rest, 1 once the big title has scrolled away — drives the compact
    /// header's blur and dark wash, the same recipe the hubs use. A leaf, so a
    /// scroll frame re-renders the scrim alone.
    @State private var headerProgress = ScrollProgress()

    @State private var showAddPlaylist = false
    @State private var accountToEdit: Account? = nil
    
    
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Same NebulaBackgroundView treatment as the rest of the app —
                // no .opacity(0.3) dimmer, no Color.black underlay, so settings
                // visually belongs to the same surface as the home screen.
                AppBackground()
                    .ignoresSafeArea()
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {

                        // Nuvio giant heavy title, replacing the system
                        // large-title chrome.
                        Text("Settings")
                            .font(NuvioTheme.pageTitleFont)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                            .padding(.bottom, -6)
                            // Reports this screen's scroll the same way the
                            // hubs do, so the shared chrome row can fade its
                            // compact "Settings" in as this one leaves.
                            .background(
                                isSection ? ScrollOffsetProbe(space: "settingsScroll", id: "settings") : nil
                            )

                        SettingsSectionHeader(title: "Content Management")
                        ContentManagementCard(
                            categories: $categories,
                            accentColor: accentColor,
                            viewModel: viewModel,
                            scoreViewModel: scoreViewModel,
                            showAddPlaylist: $showAddPlaylist,
                            accountToEdit: $accountToEdit,
                            playAction: playAction,
                            dismissSettings: { dismiss() },
                            openMultiView: openMultiView
                        )


                        SettingsSectionHeader(title: "Playback")
                        PlaybackCard(viewModel: viewModel)


                        SettingsSectionHeader(title: "Sports")
                        SportsPreferencesCard(viewModel: viewModel)

                        
                        SettingsSectionHeader(title: "Updates")
                        UpdatesCard(updateService: updateService)
                        
                        
                        SettingsSectionHeader(title: "Support")
                        SupportCard()
                        
                        
                        SettingsCard {
                            Button(action: {
                                if let current = accountManager.currentAccount {
                                    accountManager.removeAccount(current)
                                } else {
                                    withAnimation { viewModel.reset(); isLoggedIn = false }
                                }
                            }) {
                                SettingsRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out", iconColor: .red, showChevron: false)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                        }
                        .padding(.top, 20)
                    }
                    .padding(20)
                    .padding(.bottom, isSection ? 100 : 0)
                }
                .coordinateSpace(name: "settingsScroll")
                // Read directly rather than through the preference the probe
                // publishes: this drives a per-frame value, and the preference
                // pipeline recomputes across the whole page to deliver it.
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y + geo.contentInsets.top
                } action: { _, scrolled in
                    headerProgress.set(min(max(scrolled / 40, 0), 1))
                }
            }
            // The compact header every other section has: the frosted blur and
            // dark wash that content passes under once the big title is gone.
            // Settings was the one section drawn without it, so its rows ran
            // straight up under the status bar.
            .overlay(alignment: .top) {
                if isSection {
                    CompactHeaderScrim(height: 150, fadeStart: 0.42)
                        .scrollProgressReveal(headerProgress, cullWhenHidden: true)
                        .ignoresSafeArea(.container, edges: .top)
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isSection {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { onSave(); dismiss() }.fontWeight(.bold) }
                }
            }
            // Section mode has no Done button — persist category edits
            // whenever the tab goes away instead.
            .onDisappear { if isSection { onSave() } }
            .sheet(isPresented: $showAddPlaylist) { AddPlaylistSheet(accountToEdit: accountToEdit) }
        }
    }

}

struct PlaybackCard: View {
    @AppStorage("autoBuffer") private var autoBuffer = true
    @AppStorage("bufferTime") private var bufferTime = 10.0
    @AppStorage("customAccentHex") private var customAccentHex = "#FFFFFF"
    @ObservedObject var viewModel: ChannelViewModel

    var body: some View {
        SettingsCard {
            VStack(spacing: 16) {
                SettingsToggle(title: "Haptic Feedback", isOn: $viewModel.hapticsEnabled)
                
                Divider().background(Color.white.opacity(0.1))
                
                SettingsToggle(title: "Auto Buffer", isOn: $autoBuffer)
                
                if !autoBuffer {
                    Divider().background(Color.white.opacity(0.1))
                    VStack(alignment: .leading) {
                        Text("Buffer Duration: \(String(format: "%.1f", bufferTime))s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $bufferTime, in: 0.5...10.0, step: 0.5)
                            .tint(Color(hex: customAccentHex) ?? .white)
                    }
                }
            }
            .padding()
        }
    }
}

struct SportsPreferencesCard: View {
    @ObservedObject var viewModel: ChannelViewModel
    
    var body: some View {
        SettingsCard {
            VStack(spacing: 16) {
                HStack {
                    Text("Preferred Language").font(.body).foregroundStyle(.primary)
                    Spacer()
                    Picker("Preferred Language", selection: $viewModel.preferredLanguage) {
                        ForEach(LanguagePreference.allCases) { lang in
                            Text(lang.rawValue).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white.opacity(0.7))
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                HStack {
                    Text("Preferred Quality").font(.body).foregroundStyle(.primary)
                    Spacer()
                    Picker("Preferred Quality", selection: $viewModel.preferredQuality) {
                        ForEach(StreamQuality.allCases) { qual in
                            Text(qual.rawValue).tag(qual)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white.opacity(0.7))
                }
            }
            .padding()
        }
    }
}

struct ContentManagementCard: View {
    @Binding var categories: [StreamCategory]
    let accentColor: Color
    @ObservedObject var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel
    @Binding var showAddPlaylist: Bool
    @Binding var accountToEdit: Account?
    let playAction: ((StreamChannel) -> Void)?
    let dismissSettings: () -> Void
    /// Opens Multi-View. It lives here rather than on the home screen — a
    /// utility alongside Recordings, not a browsing surface.
    var openMultiView: (() -> Void)? = nil
    
    @ObservedObject var accountManager = AccountManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        SettingsCard {
            VStack(spacing: 0) {
                
                ForEach(accountManager.accounts) { account in
                    HStack {
                        
                        Toggle("", isOn: Binding(
                            get: { account.isActive },
                            set: { val in
                                var updated = account
                                updated.isActive = val
                                accountManager.saveAccount(updated, makeActive: false)
                            }
                        ))
                        .labelsHidden()
                        .tint(.green)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            
                            HStack(spacing: 4) {
                                Image(systemName: "list.bullet")
                                    .font(.caption2)
                                Text(account.type == .m3u ? "M3U Playlist" : "Xtream Codes")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        
                        if accountManager.currentAccount?.id == account.id {
                            Text("Primary")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(accentColor.opacity(0.2))
                                .foregroundColor(accentColor)
                                .cornerRadius(4)
                        }
                        
                        
                        Menu {
                            Button("Set as Primary") {
                                withAnimation { accountManager.switchToAccount(account) }
                            }
                            
                            Button {
                                accountToEdit = account
                                showAddPlaylist = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            
                            Button(role: .destructive) {
                                accountManager.removeAccount(account)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(Color.white.opacity(0.03))
                    
                    Divider().background(Color.white.opacity(0.1))
                }
                
                
                Button(action: {
                    accountToEdit = nil
                    showAddPlaylist = true
                }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.primary)
                        Text("Add Playlist")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding()
                }
                .buttonStyle(.plain)
                
                Divider().background(Color.white.opacity(0.1))
                
                
                Button(action: {
                    dismiss()
                    Task {
                        await viewModel.loadActiveAccounts(silent: false, force: true, performEpgCheck: true)
                        await scoreViewModel.fetchScores(forceRefresh: true)
                    }
                }) {
                    SettingsRow(icon: "arrow.clockwise.icloud", title: "Update All Content", subtitle: viewModel.isUpdatingEPG ? "Updating..." : nil, iconColor: .teal, showChevron: false)
                }
                .disabled(viewModel.isUpdatingEPG)
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                NavigationLink(destination: SportTabsManagerView(scoreViewModel: scoreViewModel, accentColor: accentColor)) {
                    SettingsRow(icon: "sportscourt", title: "Manage Sports Categories", iconColor: .green)
                }
                .foregroundStyle(.primary)

                NavigationLink(destination: ManageEPGsView()) {
                    SettingsRow(icon: "list.bullet.clipboard", title: "Manage EPGs", subtitle: "\(accountManager.accounts.first(where: { $0.id == accountManager.currentAccount?.id })?.externalEPGUrls.count ?? 0) Sources", iconColor: .purple)
                }
                .foregroundStyle(.primary)

                NavigationLink(destination: RecordingsView(viewModel: viewModel, playAction: { channel in
                    dismissSettings()
                    playAction?(channel)
                })) {
                    SettingsRow(icon: "recordingtape", title: "Recordings", subtitle: "\(RecordingManager.shared.recordings.filter { $0.status == .completed }.count) Saved", iconColor: .red)
                }
                .foregroundStyle(.primary)

                if let openMultiView {
                    Button(action: {
                        dismissSettings()
                        openMultiView()
                    }) {
                        SettingsRow(icon: "square.grid.2x2.fill",
                                    title: "Multi-View",
                                    subtitle: viewModel.activeMultiViewCount > 0 ? "\(viewModel.activeMultiViewCount)/4 Active" : nil,
                                    iconColor: .blue)
                    }
                    .foregroundStyle(.primary)
                }

                NavigationLink(destination: HomeLayoutSettingsView(viewModel: viewModel, accentColor: accentColor)) {
                    SettingsRow(icon: "square.stack.3d.up.fill",
                                title: "Home Layout",
                                subtitle: viewModel.homeRowOrder.isEmpty ? "Default" : "Custom",
                                iconColor: .pink)
                }
                .foregroundStyle(.primary)

                NavigationLink(destination: HeroChannelsSettingsView(viewModel: viewModel, accentColor: accentColor)) {
                    SettingsRow(icon: "rectangle.on.rectangle.angled",
                                title: "Hero Channels",
                                subtitle: viewModel.customHeroIDs.isEmpty ? "Automatic" : "\(viewModel.customHeroIDs.count) Chosen",
                                iconColor: .indigo)
                }
                .foregroundStyle(.primary)

                NavigationLink(destination: HiddenChannelsSettingsView(viewModel: viewModel)) {
                    SettingsRow(icon: "eye.slash.fill", title: "Hidden Channels", subtitle: !viewModel.hiddenIDs.isEmpty ? "\(viewModel.hiddenIDs.count)" : nil, iconColor: .gray)
                }
                .foregroundStyle(.primary)
            }
        }
    }
}

struct SupportCard: View {
    @AppStorage("showSupportPopup") private var showSupportPopup = true

    var body: some View {
        SettingsCard {
            VStack(spacing: 0) {
                SettingsToggle(title: "Show Support Popup", isOn: $showSupportPopup)
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                
                Divider().background(Color.white.opacity(0.1)).padding(.leading, 16)
                
                Button(action: { UIApplication.shared.open(URL(string: "https://discord.gg/msq2tcd5Rg")!) }) {
                    SettingsRow(icon: "bubble.left.and.bubble.right.fill", title: "Join Discord", iconColor: Color(hex: "#5865F2") ?? .blue)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                Button(action: { UIApplication.shared.open(URL(string: "https://buymeacoffee.com/mongoosemonke")!) }) {
                    SettingsRow(icon: "cup.and.saucer.fill", title: "Buy Me a Coffee", iconColor: .yellow)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
    }
}

struct UpdatesCard: View {
    @ObservedObject var updateService: UpdateService
    @State private var showReleaseNotes = false
    
    var body: some View {
        SettingsCard {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "app.badge.fill")
                        .foregroundStyle(.primary)
                    Text("Current Version: \(updateService.currentVersion)")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding()
                
                Divider().background(Color.white.opacity(0.1))
                
                if updateService.checkingForUpdate {
                    HStack {
                        CustomSpinner(color: .white, lineWidth: 3, size: 20)
                        Text("Checking...")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else if updateService.isUpdateAvailable, let release = updateService.latestRelease {
                    Button(action: { showReleaseNotes = true }) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.green)
                                .font(.title3)
                            
                            VStack(alignment: .leading) {
                                Text("Update Available: \(release.tagName)")
                                    .font(.headline)
                                    .foregroundColor(.green)
                                Text("Tap to view release notes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding()
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showReleaseNotes) {
                        NavigationStack {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text("What's New")
                                        .font(.title2.bold())
                                    
                                    Text(release.body)
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                    
                                    Button(action: { UIApplication.shared.open(URL(string: release.htmlUrl)!) }) {
                                        Text("Download Update")
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 50)
                                            .background(Material.ultraThin)
                                            .cornerRadius(12)
                                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 20)
                                }
                                .padding()
                            }
                            .navigationTitle(release.tagName)
                            .toolbar {
                                Button("Close") { showReleaseNotes = false }
                            }
                        }
                        .presentationDetents([.medium, .large])
                    }
                } else {
                    Button(action: {
                        Task { await updateService.checkForUpdates(manual: true) }
                    }) {
                        SettingsRow(
                            icon: updateService.showUpToDate ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath",
                            title: updateService.showUpToDate ? "System Up to Date" : "Check for Updates",
                            subtitle: updateService.errorMessage,
                            iconColor: updateService.showUpToDate ? .green : .blue,
                            showChevron: false
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct SettingsSectionHeader: View {
    let title: String
    var body: some View {
        // Reference style: small gray ALL-CAPS group label ("ACCOUNT",
        // "GENERAL") with a touch of letter-spacing.
        Text(title.uppercased())
            .font(.system(size: 12, weight: .bold))
            .kerning(1.1)
            .foregroundStyle(NuvioTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            content
        }
        // Nuvio flat charcoal surface instead of glass.
        .background(NuvioTheme.card)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var iconColor: Color = .accentColor
    var showChevron: Bool = true

    /// Reference rows are monochrome — white glyph in a dark circle. Red
    /// (destructive rows like Sign Out) and blue (Multi-View) are the two
    /// deliberate exceptions.
    private var glyphColor: Color {
        iconColor == .red || iconColor == .blue ? iconColor : .white
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(white: 0.17))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(glyphColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                if let sub = subtitle {
                    Text(sub)
                        .font(.footnote)
                        .foregroundStyle(NuvioTheme.secondaryText)
                }
            }

            Spacer(minLength: 8)

            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }
}

struct SportTabsManagerView: View {
    @ObservedObject var scoreViewModel: ScoreViewModel
    let accentColor: Color
    @State private var sportToRename: SportType?
    @State private var renameText = ""
    @State private var showRenameAlert = false

    @AppStorage("nebColor1") private var nebColor1 = "#1A2538"
    @AppStorage("nebColor2") private var nebColor2 = "#11101A"
    @AppStorage("nebColor3") private var nebColor3 = "#1F1A24"
    @AppStorage("nebX1") private var nebX1 = 0.5
    @AppStorage("nebY1") private var nebY1 = 0.0
    @AppStorage("nebX2") private var nebX2 = 0.5
    @AppStorage("nebY2") private var nebY2 = 0.5
    @AppStorage("nebX3") private var nebX3 = 0.5
    @AppStorage("nebY3") private var nebY3 = 1.0

    var body: some View {
        ZStack {
            NebulaBackgroundView(
                color1: Color(hex: nebColor1) ?? .purple,
                color2: Color(hex: nebColor2) ?? .blue,
                color3: Color(hex: nebColor3) ?? .pink,
                point1: UnitPoint(x: nebX1, y: nebY1),
                point2: UnitPoint(x: nebX2, y: nebY2),
                point3: UnitPoint(x: nebX3, y: nebY3)
            )

            List {
                Section {
                    ForEach(scoreViewModel.sportTabOrder, id: \.self) { sport in
                        HStack {
                            Button(action: {
                                withAnimation { scoreViewModel.toggleSportTabVisibility(sport) }
                            }) {
                                Image(systemName: scoreViewModel.hiddenSportTabs.contains(sport) ? "eye.slash" : "eye")
                                    .foregroundColor(scoreViewModel.hiddenSportTabs.contains(sport) ? .gray : accentColor)
                                    .frame(width: 30)
                            }
                            .buttonStyle(.plain)

                            Text(scoreViewModel.getSportName(sport))
                                .foregroundStyle(scoreViewModel.hiddenSportTabs.contains(sport) ? .white.opacity(0.45) : .white)
                                .strikethrough(scoreViewModel.hiddenSportTabs.contains(sport))

                            Spacer()
                        }
                        .listRowBackground(Color.black.opacity(0.35))
                        .contextMenu {
                            Button {
                                sportToRename = sport
                                renameText = scoreViewModel.getSportName(sport)
                                showRenameAlert = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                        }
                    }
                    .onMove { src, dst in
                        scoreViewModel.moveSportTab(from: src, to: dst)
                    }
                } header: {
                    Text("Drag to Reorder")
                        .foregroundStyle(.white.opacity(0.65))
                } footer: {
                    Text("Tap the eye icon to toggle visibility. Long press to rename.")
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
        .navigationTitle("Sports Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(.white)
        .alert("Rename Category", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let s = sportToRename {
                    scoreViewModel.renameSportTab(s, to: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Drag-to-reorder for the home page's sections — the rows of big cards and the
/// category shelves, in one list.
///
/// The list is exactly what the home page renders, in the order it renders it,
/// because both read `ChannelViewModel.orderedHomeSections()`. Ships in the
/// natural order (three category shelves, then a row of big cards, repeating);
/// dragging stores an explicit order, and Reset clears it back to nothing so a
/// fresh install and a reset user are the same state.
struct HomeLayoutSettingsView: View {
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color

    @AppStorage("nebColor1") private var nebColor1 = "#1A2538"
    @AppStorage("nebColor2") private var nebColor2 = "#11101A"
    @AppStorage("nebColor3") private var nebColor3 = "#1F1A24"
    @AppStorage("nebX1") private var nebX1 = 0.5
    @AppStorage("nebY1") private var nebY1 = 0.0
    @AppStorage("nebX2") private var nebX2 = 0.5
    @AppStorage("nebY2") private var nebY2 = 0.5
    @AppStorage("nebX3") private var nebX3 = 0.5
    @AppStorage("nebY3") private var nebY3 = 1.0

    private var sections: [ChannelViewModel.HomeSection] { viewModel.orderedHomeSections() }

    /// The category a long press is renaming, and the name being typed.
    @State private var renamingCategory: (id: Int, name: String)?
    @State private var renameText = ""

    /// A section's category id, or nil for a row of big cards — those are
    /// generated groups with no name of their own to change.
    private func categoryID(for section: ChannelViewModel.HomeSection) -> Int? {
        guard !section.isSpotlight else { return nil }
        return Int(section.id.dropFirst())
    }

    var body: some View {
        ZStack {
            NebulaBackgroundView(
                color1: Color(hex: nebColor1) ?? .purple,
                color2: Color(hex: nebColor2) ?? .blue,
                color3: Color(hex: nebColor3) ?? .pink,
                point1: UnitPoint(x: nebX1, y: nebY1),
                point2: UnitPoint(x: nebX2, y: nebY2),
                point3: UnitPoint(x: nebX3, y: nebY3)
            )

            List {
                Section {
                    ForEach(sections) { section in
                        HStack(spacing: 12) {
                            Image(systemName: section.isSpotlight
                                  ? "rectangle.portrait.on.rectangle.portrait.fill"
                                  : "rectangle.grid.1x2.fill")
                                .foregroundStyle(section.isSpotlight ? accentColor : .white.opacity(0.55))
                                .frame(width: 26)

                            Text(section.title)
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            Text(section.isSpotlight ? "Big Cards" : "Category")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .listRowBackground(Color.black.opacity(0.35))
                        // What the Manage Categories page used to be for, in
                        // the place the categories are already listed.
                        .contextMenu {
                            if let id = categoryID(for: section) {
                                Button {
                                    renameText = section.title
                                    renamingCategory = (id: id, name: section.title)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button {
                                    if let index = viewModel.categories.firstIndex(where: { $0.id == id }) {
                                        withAnimation { viewModel.categories[index].isHidden.toggle() }
                                        viewModel.saveCategorySettings()
                                    }
                                } label: {
                                    let hidden = viewModel.categories.first(where: { $0.id == id })?.isHidden ?? false
                                    Label(hidden ? "Show on Home" : "Hide from Home",
                                          systemImage: hidden ? "eye" : "eye.slash")
                                }
                            }
                        }
                    }
                    .onMove { src, dst in
                        viewModel.moveHomeSection(from: src, to: dst)
                    }
                } header: {
                    Text("Drag to Reorder")
                        .foregroundStyle(.white.opacity(0.65))
                } footer: {
                    Text("The order of the home screen below the featured card. Drag every row of big cards to the top to group them together, or spread them out however you like. Press and hold a category to rename or hide it.")
                        .foregroundStyle(.white.opacity(0.55))
                }

                if !viewModel.homeRowOrder.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            withAnimation { viewModel.resetHomeSectionOrder() }
                        } label: {
                            Text("Reset to Default Order")
                        }
                        .listRowBackground(Color.black.opacity(0.35))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
        .navigationTitle("Home Layout")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename Category", isPresented: Binding(
            get: { renamingCategory != nil },
            set: { if !$0 { renamingCategory = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let target = renamingCategory, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    viewModel.renameCategory(id: target.id, newName: renameText)
                }
                renamingCategory = nil
            }
            Button("Cancel", role: .cancel) { renamingCategory = nil }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(.white)
    }
}

struct HiddenChannelsSettingsView: View {
    @ObservedObject var viewModel: ChannelViewModel
    @State private var searchText = ""
    @AppStorage("customAccentHex") private var customAccentHex = "#FFFFFF"

    @AppStorage("nebColor1") private var nebColor1 = "#1A2538"
    @AppStorage("nebColor2") private var nebColor2 = "#11101A"
    @AppStorage("nebColor3") private var nebColor3 = "#1F1A24"
    @AppStorage("nebX1") private var nebX1 = 0.5
    @AppStorage("nebY1") private var nebY1 = 0.0
    @AppStorage("nebX2") private var nebX2 = 0.5
    @AppStorage("nebY2") private var nebY2 = 0.5
    @AppStorage("nebX3") private var nebX3 = 0.5
    @AppStorage("nebY3") private var nebY3 = 1.0

    var hidden: [StreamChannel] {
        let h = viewModel.channels.filter { viewModel.hiddenIDs.contains($0.id) }
        if searchText.isEmpty { return h }
        return h.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ZStack {
            NebulaBackgroundView(
                color1: Color(hex: nebColor1) ?? .purple,
                color2: Color(hex: nebColor2) ?? .blue,
                color3: Color(hex: nebColor3) ?? .pink,
                point1: UnitPoint(x: nebX1, y: nebY1),
                point2: UnitPoint(x: nebX2, y: nebY2),
                point3: UnitPoint(x: nebX3, y: nebY3)
            )

            List {
                if viewModel.hiddenIDs.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "eye")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(.white.opacity(0.35))
                            Text("No hidden channels")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .listRowBackground(Color.black.opacity(0.35))
                    }
                } else {
                    Section {
                        ForEach(hidden) { c in
                            HStack(spacing: 12) {
                                CachedAsyncImage(urlString: c.icon ?? "", size: CGSize(width: 30, height: 30))
                                    .frame(width: 30, height: 30)
                                    .padding(2)
                                    .cornerRadius(4)
                                    .clipped()
                                Text(c.name)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer()
                                Button("Unhide") {
                                    withAnimation { viewModel.unhideChannel(c.id) }
                                }
                                .buttonStyle(.bordered)
                                .tint(Color(hex: customAccentHex) ?? .white)
                                .controlSize(.small)
                            }
                            .listRowBackground(Color.black.opacity(0.35))
                        }
                    } header: {
                        Text("Hidden Channels (\(hidden.count))")
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .searchable(text: $searchText, prompt: "Search hidden channels")
        .navigationTitle("Hidden Channels")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(.white)
        .toolbar {
            if !viewModel.hiddenIDs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Unhide All") {
                        withAnimation { viewModel.hiddenIDs.forEach { viewModel.unhideChannel($0) } }
                    }
                    .foregroundStyle(.white)
                }
            }
        }
    }
}

// MARK: - Hero channels

/// Chooses exactly which channels the home carousel leads with. Leave it empty
/// and the app picks automatically (most-watched networks, then the genres you
/// actually watch); tick anything and that becomes the carousel, in tick order.
struct HeroChannelsSettingsView: View {
    @ObservedObject var viewModel: ChannelViewModel
    let accentColor: Color
    @State private var query = ""

    /// Chosen channels first, in the user's own order, then everything else —
    /// so what you've picked is never buried under ten thousand rows.
    private var rows: [StreamChannel] {
        let byID = Dictionary(uniqueKeysWithValues: viewModel.channels.map { ($0.id, $0) })
        let chosen = viewModel.customHeroIDs.compactMap { byID[$0] }
        let chosenIDs = Set(viewModel.customHeroIDs)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return chosen }
        let matches = viewModel.channels.lazy
            .filter { !chosenIDs.contains($0.id) && !viewModel.hiddenIDs.contains($0.id) }
            .filter { $0.name.lowercased().contains(trimmed) }
        return chosen + Array(matches.prefix(60))
    }

    var body: some View {
        ZStack {
            AppBackground().ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(viewModel.customHeroIDs.isEmpty
                         ? "The carousel is picking channels for you. Search below and tap any channel to take over."
                         : "The carousel shows these, in this order. Remove them all to go back to automatic.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 4)

                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        TextField("Search channels", text: $query)
                            .textFieldStyle(.plain)
                            .foregroundStyle(.white)
                            .autocorrectionDisabled()
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NuvioTheme.card))

                    if !viewModel.customHeroIDs.isEmpty {
                        Button {
                            withAnimation { viewModel.customHeroIDs = [] }
                        } label: {
                            Label("Use Automatic Picks", systemImage: "wand.and.stars")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NuvioTheme.card))
                        }
                        .buttonStyle(.plain)
                    }

                    LazyVStack(spacing: 8) {
                        ForEach(rows) { channel in
                            let isOn = viewModel.customHeroIDs.contains(channel.id)
                            Button {
                                withAnimation { viewModel.toggleHeroChannel(channel.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    CachedAsyncImage(urlString: channel.icon ?? "", size: nil)
                                        .padding(6)
                                        .frame(width: 44, height: 44)
                                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(LogoGlow.tone(for: channel.icon) ?? Color(white: 0.15)))
                                    Text(channel.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 19))
                                        .foregroundStyle(isOn ? accentColor : Color.white.opacity(0.25))
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NuvioTheme.card))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if rows.isEmpty {
                        Text(query.isEmpty ? "Search for a channel to add it." : "No channels match “\(query)”.")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }

                    Color.clear.frame(height: 40)
                }
                .padding(20)
            }
        }
        .navigationTitle("Hero Channels")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        // The carousel is rebuilt from these picks.
        .onDisappear { Task { await viewModel.refreshFeaturedChannels() } }
    }
}
