import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("viewMode") private var viewMode = ViewMode.automatic.rawValue
    @AppStorage("customAccentHex") private var customAccentHex = "#007AFF"
    
    @Binding var categories: [StreamCategory]
    let accentColor: Color
    var viewModel: ChannelViewModel
    @ObservedObject var scoreViewModel: ScoreViewModel 
    let playAction: ((StreamChannel) -> Void)?
    let onSave: () -> Void
    
    @AppStorage("xstreamURL") private var xstreamURL = ""
    @AppStorage("username") private var username = ""
    @AppStorage("password") private var password = ""
    @AppStorage("loginTypeRaw") private var loginTypeRaw = LoginType.xtream.rawValue 
    @AppStorage("customBackgroundVersion") private var customBackgroundVersion = 0
    @AppStorage("showSupportPopup") private var showSupportPopup = true
    
    @ObservedObject var accountManager = AccountManager.shared
    @ObservedObject var updateService = UpdateService.shared
    
    @State private var showImagePicker = false
    @State private var showFilePicker = false
    @State private var showSourceSelection = false
    @State private var showAddPlaylist = false
    @State private var accountToEdit: Account? = nil
    @State private var inputImage: UIImage?
    
    
    @AppStorage("nebColor1") private var nebColor1 = "#AF52DE"; @AppStorage("nebColor2") private var nebColor2 = "#007AFF"; @AppStorage("nebColor3") private var nebColor3 = "#FF2D55"; @AppStorage("nebX1") private var nebX1 = 0.2; @AppStorage("nebY1") private var nebY1 = 0.2; @AppStorage("nebX2") private var nebX2 = 0.8; @AppStorage("nebY2") private var nebY2 = 0.3; @AppStorage("nebX3") private var nebX3 = 0.5; @AppStorage("nebY3") private var nebY3 = 0.8
    @AppStorage("useCustomBackground") private var useCustomBackground = false
    @AppStorage("customBackgroundBlur") private var customBackgroundBlur = 0.0
    
    var body: some View {
        NavigationStack {
            ZStack {
                
                Color.black.ignoresSafeArea()
                NebulaBackgroundView(color1: Color(hex: nebColor1) ?? .purple, color2: Color(hex: nebColor2) ?? .blue, color3: Color(hex: nebColor3) ?? .pink, point1: UnitPoint(x: nebX1, y: nebY1), point2: UnitPoint(x: nebX2, y: nebY2), point3: UnitPoint(x: nebX3, y: nebY3))
                    .opacity(0.3)
                    .ignoresSafeArea()
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        
                        
                        SettingsSectionHeader(title: "Appearance")
                        AppearanceCard(
                            showSourceSelection: $showSourceSelection,
                            showImagePicker: $showImagePicker,
                            showFilePicker: $showFilePicker,
                            inputImage: $inputImage,
                            accentColor: accentColor
                        )
                        
                        
                        SettingsSectionHeader(title: "Playback")
                        PlaybackCard(viewModel: viewModel)
                        
                        
                        SettingsSectionHeader(title: "Sports")
                        SportsPreferencesCard(viewModel: viewModel)
                        
                        
                        SettingsSectionHeader(title: "Content Management")
                        ContentManagementCard(
                            categories: $categories,
                            accentColor: accentColor,
                            viewModel: viewModel,
                            scoreViewModel: scoreViewModel, 
                            showAddPlaylist: $showAddPlaylist,
                            accountToEdit: $accountToEdit,
                            playAction: playAction,
                            dismissSettings: { dismiss() }
                        )
                        
                        
                        SettingsSectionHeader(title: "Updates")
                        UpdatesCard(updateService: updateService)
                        
                        
                        SettingsSectionHeader(title: "Support")
                        SupportCard()
                        
                        
                        Button(action: {
                            if let current = accountManager.currentAccount {
                                accountManager.removeAccount(current)
                                viewModel.reset()
                            } else {
                                withAnimation { viewModel.reset() }
                            }
                        }) {
                            Text("Sign Out")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.red.opacity(0.8))
                                .cornerRadius(12)
                                .shadow(radius: 5)
                        }
                        .padding(.top, 20)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { onSave(); dismiss() }.fontWeight(.bold) } }
            .sheet(isPresented: $showAddPlaylist) { AddPlaylistSheet(accountToEdit: accountToEdit) }
            .sheet(isPresented: $showImagePicker) { PhotoPicker(image: $inputImage) }
            .sheet(isPresented: $showFilePicker) { FilePicker(image: $inputImage) }
            .onChangeCompat(of: inputImage) { newImage in if let img = newImage { saveImage(img) } }
            .onAppear { loadSavedImage() }
        }
    }
    
    func saveImage(_ image: UIImage) {
        if let data = image.jpegData(compressionQuality: 0.8) {
            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? data.write(to: dir.appendingPathComponent("custom_background.jpg"))
                customBackgroundVersion += 1
            }
        }
    }
    
    func loadSavedImage() {
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = dir.appendingPathComponent("custom_background.jpg")
            if let data = try? Data(contentsOf: fileURL), let uiImage = UIImage(data: data) {
                self.inputImage = uiImage
            }
        }
    }
}

struct AppearanceCard: View {
    @AppStorage("viewMode") private var viewMode = ViewMode.automatic.rawValue
    @AppStorage("customAccentHex") private var customAccentHex = "#007AFF"
    @AppStorage("useCustomBackground") private var useCustomBackground = false
    @AppStorage("customBackgroundBlur") private var customBackgroundBlur = 0.0
    @AppStorage("glassOpacity") private var glassOpacity = 0.15
    @AppStorage("glassShade") private var glassShade = 1.0 
    
    @Binding var showSourceSelection: Bool
    @Binding var showImagePicker: Bool
    @Binding var showFilePicker: Bool
    @Binding var inputImage: UIImage?
    let accentColor: Color
    
    var body: some View {
        SettingsCard {
            VStack(spacing: 16) {
                
                HStack {
                    Text("Layout Mode").font(.body).foregroundColor(.white)
                    Spacer()
                    Picker("Layout Mode", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                    }.pickerStyle(.menu).tint(.white.opacity(0.7))
                }
                Divider().background(Color.white.opacity(0.1))
                
                HStack {
                    Text("Accent Color").font(.body).foregroundColor(.white)
                    Spacer()
                    ColorPicker("", selection: Binding(get: { Color(hex: customAccentHex) ?? .blue }, set: { if let h = $0.toHex() { customAccentHex = h } }))
                }
                Divider().background(Color.white.opacity(0.1))
                
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Button Transparency").font(.body).foregroundColor(.white)
                        Spacer()
                        Text("\(Int(glassOpacity * 100))%").font(.caption).foregroundColor(.white.opacity(0.7))
                    }
                    
                    
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            
                            ZStack {
                                TransparencyCheckerboardView()
                                    .clipShape(Capsule())
                                
                                LinearGradient(
                                    stops: [
                                        .init(color: .white.opacity(0), location: 0),
                                        .init(color: .white, location: 1)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .clipShape(Capsule())
                            }
                            .frame(height: 8)
                            .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                            
                            Circle()
                                .fill(Color(white: glassShade).opacity(glassOpacity))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
                                .offset(x: CGFloat(glassOpacity) * (geo.size.width - 22))
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { v in
                                            let newValue = v.location.x / geo.size.width
                                            glassOpacity = max(0, min(1, Double(newValue)))
                                        }
                                )
                        }
                    }
                    .frame(height: 22)
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Button Color (Grayscale)").font(.body).foregroundColor(.white)
                        Spacer()
                        Text(glassShade == 1.0 ? "White" : (glassShade == 0.0 ? "Black" : String(format: "%.0f%% Gray", (1.0 - glassShade) * 100))).font(.caption).foregroundColor(.white.opacity(0.7))
                    }
                    
                    
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            
                            LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                                .frame(height: 8)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                            
                            Circle()
                                .fill(Color(white: glassShade))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
                                .offset(x: CGFloat(glassShade) * (geo.size.width - 22))
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { v in
                                            let newValue = v.location.x / geo.size.width
                                            glassShade = max(0, min(1, Double(newValue)))
                                        }
                                )
                        }
                    }
                    .frame(height: 22)
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Preview")
                        .font(.caption.bold())
                        .foregroundColor(.white.opacity(0.5))
                    
                    HStack {
                        Image(systemName: "tv.fill")
                            .foregroundColor(Color(hex: customAccentHex) ?? .blue)
                            .frame(width: 30)
                        Text("Example Category")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .modifier(GlassEffect(cornerRadius: 12, isSelected: false, accentColor: nil))
                }
            }
            .padding()
            
            Divider().background(Color.white.opacity(0.1))
            
            
            VStack(alignment: .leading, spacing: 16) {
                Text("Background Style")
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.top, 4)
                
                SettingsToggle(title: "Use Custom Photo", isOn: $useCustomBackground)
                
                if useCustomBackground {
                    CustomBackgroundEditor(
                        showSourceSelection: $showSourceSelection,
                        showImagePicker: $showImagePicker,
                        showFilePicker: $showFilePicker,
                        inputImage: $inputImage,
                        customBackgroundBlur: $customBackgroundBlur,
                        accentColor: accentColor
                    )
                } else {
                    NebulaEditorView()
                }
            }
            .padding()
        }
    }
}

struct PlaybackCard: View {
    @AppStorage("autoBuffer") private var autoBuffer = true
    @AppStorage("bufferTime") private var bufferTime = 10.0
    @AppStorage("defaultPlayerEngine") private var defaultPlayerEngine = "VLC"
    @ObservedObject var viewModel: ChannelViewModel
    
    var body: some View {
        SettingsCard {
            VStack(spacing: 16) {
                HStack {
                    Text("Default Player").font(.body).foregroundColor(.white)
                    Spacer()
                    Picker("Default Player", selection: $defaultPlayerEngine) {
                        Text("KSPlayer").tag("KSPlayer")
                        Text("VLC").tag("VLC")
                    }
                    .pickerStyle(.menu)
                    .tint(.white.opacity(0.7))
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                SettingsToggle(title: "Haptic Feedback", isOn: $viewModel.hapticsEnabled)
                
                Divider().background(Color.white.opacity(0.1))
                
                SettingsToggle(title: "Auto Buffer", isOn: $autoBuffer)
                
                if !autoBuffer {
                    Divider().background(Color.white.opacity(0.1))
                    VStack(alignment: .leading) {
                        Text("Buffer Duration: \(String(format: "%.1f", bufferTime))s")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        Slider(value: $bufferTime, in: 0.5...10.0, step: 0.5)
                            .tint(.blue)
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
                    Text("Preferred Language").font(.body).foregroundColor(.white)
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
                    Text("Preferred Quality").font(.body).foregroundColor(.white)
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

struct CustomBackgroundEditor: View {
    @Binding var showSourceSelection: Bool
    @Binding var showImagePicker: Bool
    @Binding var showFilePicker: Bool
    @Binding var inputImage: UIImage?
    @Binding var customBackgroundBlur: Double
    let accentColor: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: { showSourceSelection = true }) {
                SettingsRow(icon: "photo.on.rectangle", title: "Select Photo", subtitle: "Choose from Photos or Files")
            }
            .buttonStyle(.plain)
            .confirmationDialog("Choose Background Source", isPresented: $showSourceSelection) {
                Button("Photos") { showImagePicker = true }
                Button("Files") { showFilePicker = true }
                Button("Cancel", role: .cancel) { }
            }
            
            if let img = inputImage {
                let ratio = img.size.width / img.size.height
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(ratio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .cornerRadius(8)
                    .clipped()
                    .padding(.vertical, 4)
            }
            
            VStack(alignment: .leading) {
                Text("Blur: \(Int(customBackgroundBlur))%")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                Slider(value: $customBackgroundBlur, in: 0...50, step: 1)
                    .tint(accentColor)
            }
        }
    }
}

struct NebulaEditorView: View {
    @AppStorage("nebColor1") private var nebColor1 = "#AF52DE"; @AppStorage("nebColor2") private var nebColor2 = "#007AFF"; @AppStorage("nebColor3") private var nebColor3 = "#FF2D55"; @AppStorage("nebX1") private var nebX1 = 0.2; @AppStorage("nebY1") private var nebY1 = 0.2; @AppStorage("nebX2") private var nebX2 = 0.8; @AppStorage("nebY2") private var nebY2 = 0.3; @AppStorage("nebX3") private var nebX3 = 0.5; @AppStorage("nebY3") private var nebY3 = 0.8
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                ZStack {
                    let screenBounds = UIScreen.main.bounds
                    let screenRatio = screenBounds.width / screenBounds.height
                    
                    NebulaBackgroundView(color1: Color(hex: nebColor1) ?? .purple, color2: Color(hex: nebColor2) ?? .blue, color3: Color(hex: nebColor3) ?? .pink, point1: UnitPoint(x: nebX1, y: nebY1), point2: UnitPoint(x: nebX2, y: nebY2), point3: UnitPoint(x: nebX3, y: nebY3), targetFPS: 60.0)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
                    
                    GeometryReader { geo in
                        DragHandle(x: $nebX1, y: $nebY1, color: Color(hex: nebColor1) ?? .purple, size: geo.size)
                        DragHandle(x: $nebX2, y: $nebY2, color: Color(hex: nebColor2) ?? .blue, size: geo.size)
                        DragHandle(x: $nebX3, y: $nebY3, color: Color(hex: nebColor3) ?? .pink, size: geo.size)
                    }
                    .aspectRatio(screenRatio, contentMode: .fit)
                }
                .aspectRatio(UIScreen.main.bounds.width / UIScreen.main.bounds.height, contentMode: .fit)
                .frame(maxHeight: 250)
                Spacer()
            }
            .padding(.bottom, 8)
            
            HStack(spacing: 20) {
                ColorPicker("Aura 1", selection: Binding(get: { Color(hex: nebColor1) ?? .purple }, set: { if let h = $0.toHex() { nebColor1 = h } })).labelsHidden()
                ColorPicker("Aura 2", selection: Binding(get: { Color(hex: nebColor2) ?? .blue }, set: { if let h = $0.toHex() { nebColor2 = h } })).labelsHidden()
                ColorPicker("Aura 3", selection: Binding(get: { Color(hex: nebColor3) ?? .pink }, set: { if let h = $0.toHex() { nebColor3 = h } })).labelsHidden()
                Spacer()
                Button("Reset") {
                    nebColor1 = "#AF52DE"; nebColor2 = "#007AFF"; nebColor3 = "#FF2D55"
                    nebX1 = 0.2; nebY1 = 0.2; nebX2 = 0.8; nebY2 = 0.3; nebX3 = 0.5; nebY3 = 0.8
                }
                .font(.caption.bold())
                .foregroundColor(.white.opacity(0.6))
            }
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
                        .tint(accentColor)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName)
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                                .lineLimit(1)
                            
                            HStack(spacing: 4) {
                                Image(systemName: "list.bullet")
                                    .font(.caption2)
                                Text(account.type == .m3u ? "M3U Playlist" : "Xtream Codes")
                                    .font(.caption)
                            }
                            .foregroundColor(.white.opacity(0.5))
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
                                .foregroundColor(.white.opacity(0.6))
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
                            .foregroundColor(accentColor)
                        Text("Add Playlist")
                            .font(.subheadline.bold())
                            .foregroundColor(accentColor)
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
                    SettingsRow(icon: "arrow.clockwise.icloud", title: "Update All Content", subtitle: viewModel.isUpdatingEPG ? "Updating..." : nil, showChevron: false)
                }
                .disabled(viewModel.isUpdatingEPG)
                .buttonStyle(.plain)
                
                NavigationLink(destination: CategoriesManagerView(categories: $categories, accentColor: accentColor, viewModel: viewModel)) {
                    SettingsRow(icon: "list.bullet.rectangle.portrait.fill", title: "Manage Categories")
                }
                
                NavigationLink(destination: SportTabsManagerView(scoreViewModel: scoreViewModel, accentColor: accentColor)) {
                    SettingsRow(icon: "sportscourt", title: "Manage Sports Categories")
                }
                
                NavigationLink(destination: ManageEPGsView()) {
                    SettingsRow(icon: "list.bullet.clipboard", title: "Manage EPGs", subtitle: "\(accountManager.accounts.first(where: { $0.id == accountManager.currentAccount?.id })?.externalEPGUrls.count ?? 0) Sources")
                }
                
                NavigationLink(destination: RecordingsView(viewModel: viewModel, playAction: { channel in
                    dismissSettings()
                    playAction?(channel)
                })) {
                    SettingsRow(icon: "recordingtape", title: "Recordings", subtitle: "\(RecordingManager.shared.recordings.count) Saved")
                }
                
                NavigationLink(destination: HiddenChannelsSettingsView(viewModel: viewModel)) {
                    SettingsRow(icon: "eye.slash.fill", title: "Hidden Channels", subtitle: !viewModel.hiddenIDs.isEmpty ? "\(viewModel.hiddenIDs.count)" : nil, iconColor: .white)
                }
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
                
                Link(destination: URL(string: "https://discord.gg/QkBUjsGCJ2")!) {
                    SettingsRow(icon: "bubble.left.and.bubble.right.fill", title: "Join Discord", iconColor: Color(hex: "#5865F2") ?? .blue)
                }
                
                Link(destination: URL(string: "https://buymeacoffee.com/mongoosemonke")!) {
                    SettingsRow(icon: "cup.and.saucer.fill", title: "Buy Me a Coffee", iconColor: .yellow)
                }
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
                        .foregroundColor(.white)
                    Text("Current Version: \(updateService.currentVersion)")
                        .font(.body)
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding()
                
                Divider().background(Color.white.opacity(0.1))
                
                if updateService.checkingForUpdate {
                    HStack {
                        CustomSpinner(color: .white, lineWidth: 3, size: 20)
                        Text("Checking...")
                            .foregroundColor(.white.opacity(0.7))
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
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.white.opacity(0.3))
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
                                    
                                    Link(destination: URL(string: release.htmlUrl)!) {
                                        Text("Download Update")
                                            .font(.headline)
                                            .foregroundColor(.white)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 50)
                                            .background(Color.blue)
                                            .cornerRadius(12)
                                    }
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
                            iconColor: updateService.showUpToDate ? .green : .white,
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
        Text(title.uppercased())
            .font(.caption)
            .fontWeight(.bold)
            .foregroundColor(.white.opacity(0.6))
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
        .background(Material.ultraThin)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var iconColor: Color = .white
    var showChevron: Bool = true
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(iconColor)
                .frame(width: 28)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.white)
                if let sub = subtitle {
                    Text(sub)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            
            Spacer()
            
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .padding()
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
                .foregroundColor(.white)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }
}

struct DragHandle: View { @Binding var x: Double; @Binding var y: Double; let color: Color; let size: CGSize; var body: some View { Circle().fill(color).frame(width: 30, height: 30).overlay(Circle().stroke(Color.white, lineWidth: 2)).shadow(radius: 4).position(x: x * size.width, y: y * size.height).gesture(DragGesture().onChanged { v in x = min(max(v.location.x / size.width, 0), 1); y = min(max(v.location.y / size.height, 0), 1) }) } }

struct CategoriesManagerView: View {
    @Binding var categories: [StreamCategory]; let accentColor: Color; @ObservedObject var viewModel: ChannelViewModel; @State private var categoryToRename: StreamCategory?; @State private var localRenameName = ""; @State private var showLocalRenameAlert = false
    var body: some View { List { Section { Button(action: { categories.indices.forEach { categories[$0].isHidden = false } }) { Label("Show All Categories", systemImage: "eye") }; Button(action: { categories.indices.forEach { categories[$0].isHidden = true } }) { Label("Hide All Categories", systemImage: "eye.slash") } }; Section(header: Text("Drag to Reorder"), footer: Text("Tap eye icon to toggle visibility. Long press to rename.")) { ForEach($categories) { $cat in HStack { Button(action: { withAnimation { cat.isHidden.toggle() } }) { Image(systemName: cat.isHidden ? "eye.slash" : "eye").foregroundColor(cat.isHidden ? .gray : accentColor).frame(width: 30) }.buttonStyle(.plain); Text(cat.name).foregroundStyle(cat.isHidden ? .secondary : .primary).strikethrough(cat.isHidden); Spacer() }.contextMenu { Button { categoryToRename = cat; localRenameName = cat.name; showLocalRenameAlert = true } label: { Label("Rename", systemImage: "pencil") } } }.onMove { src, dst in categories.move(fromOffsets: src, toOffset: dst); for i in 0..<categories.count { categories[i].order = i } } } }.environment(\.editMode, .constant(.active)).navigationTitle("Categories").alert("Rename Category", isPresented: $showLocalRenameAlert) { TextField("Name", text: $localRenameName); Button("Save") { if let c = categoryToRename { viewModel.renameCategory(id: c.id, newName: localRenameName) } }; Button("Cancel", role: .cancel) {} } }
}
struct SportTabsManagerView: View {
    @ObservedObject var scoreViewModel: ScoreViewModel
    let accentColor: Color
    @State private var sportToRename: SportType?
    @State private var renameText = ""
    @State private var showRenameAlert = false
    
    var body: some View {
        List {
            Section(header: Text("Drag to Reorder"), footer: Text("Tap eye icon to toggle visibility. Long press to rename.")) {
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
                            .foregroundStyle(scoreViewModel.hiddenSportTabs.contains(sport) ? .secondary : .primary)
                            .strikethrough(scoreViewModel.hiddenSportTabs.contains(sport))
                        
                        Spacer()
                    }
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
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Sports Categories")
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

struct HiddenChannelsSettingsView: View {
    @ObservedObject var viewModel: ChannelViewModel; @State private var searchText = ""
    var hidden: [StreamChannel] { let h = viewModel.channels.filter { viewModel.hiddenIDs.contains($0.id) }; if searchText.isEmpty { return h }; return h.filter { $0.name.localizedCaseInsensitiveContains(searchText) } }
    var body: some View { List { if viewModel.hiddenIDs.isEmpty { Section { Text("No hidden channels").foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .center).padding() } } else { Section(header: Text("Hidden Channels (\(hidden.count))")) { ForEach(hidden) { c in HStack { CachedAsyncImage(urlString: c.icon ?? "", size: CGSize(width: 30, height: 30)).frame(width: 30, height: 30).padding(2).cornerRadius(4); Text(c.name).lineLimit(1); Spacer(); Button("Unhide") { withAnimation { viewModel.unhideChannel(c.id) } }.buttonStyle(.bordered).tint(.blue).controlSize(.small) } } } } }.searchable(text: $searchText, prompt: "Search hidden channels").navigationTitle("Hidden Channels").toolbar { if !viewModel.hiddenIDs.isEmpty { ToolbarItem(placement: .topBarTrailing) { Button("Unhide All") { withAnimation { viewModel.hiddenIDs.forEach { viewModel.unhideChannel($0) } } } } } } }
}

struct PhotoPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.presentationMode) var presentationMode

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker

        init(_ parent: PhotoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.presentationMode.wrappedValue.dismiss()
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
            
            provider.loadObject(ofClass: UIImage.self) { image, error in
                if let uiImage = image as? UIImage {
                    DispatchQueue.main.async {
                        self.parent.image = uiImage
                    }
                }
            }
        }
    }
}

struct FilePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.presentationMode) var presentationMode
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FilePicker
        init(_ parent: FilePicker) { self.parent = parent }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first, url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            
            if let data = try? Data(contentsOf: url), let uiImage = UIImage(data: data) {
                DispatchQueue.main.async {
                    self.parent.image = uiImage
                }
            }
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

struct TransparencyCheckerboardView: View {
    var body: some View {
        GeometryReader { geo in
            let size: CGFloat = 4
            let cols = Int(geo.size.width / size) + 1
            let rows = Int(geo.size.height / size) + 1
            
            Canvas { context, _ in
                for row in 0..<rows {
                    for col in 0..<cols {
                        if (row + col) % 2 == 0 {
                            context.fill(
                                Path(CGRect(x: CGFloat(col) * size, y: CGFloat(row) * size, width: size, height: size)),
                                with: .color(.white)
                            )
                        } else {
                            context.fill(
                                Path(CGRect(x: CGFloat(col) * size, y: CGFloat(row) * size, width: size, height: size)),
                                with: .color(.gray.opacity(0.5))
                            )
                        }
                    }
                }
            }
        }
    }
}