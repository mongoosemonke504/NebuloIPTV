import SwiftUI
import AVFoundation
import Combine

// MARK: - MAIN VIEW
struct MainView: SwiftUI.View {
    @ObservedObject var viewModel: ChannelViewModel
    @AppStorage("xstreamURL") private var xstreamURL = ""; @AppStorage("username") private var username = ""; @AppStorage("password") private var password = ""; @AppStorage("loginTypeRaw") private var loginTypeRaw = LoginType.xtream.rawValue; @AppStorage("viewMode") private var viewMode = ViewMode.automatic.rawValue; @AppStorage("customAccentHex") private var customAccentHex = "#007AFF"; @AppStorage("nebColor1") private var nebColor1 = "#AF52DE"; @AppStorage("nebColor2") private var nebColor2 = "#007AFF"; @AppStorage("nebColor3") private var nebColor3 = "#FF2D55"; @AppStorage("nebX1") private var nebX1 = 0.2; @AppStorage("nebY1") private var nebY1 = 0.2; @AppStorage("nebX2") private var nebX2 = 0.8; @AppStorage("nebY2") private var nebY2 = 0.3; @AppStorage("nebX3") private var nebX3 = 0.5; @AppStorage("nebY3") private var nebY3 = 0.8
    @AppStorage("showSupportPopup") private var showSupportPopup = true
    @AppStorage("lastSupportPopupTime") private var lastSupportPopupTime: Double = 0
    
    @State private var selectedCategory: StreamCategory?
    @State private var selectedChannel: StreamChannel?
    @State private var showSettings = false
    @State private var showMultiView = false
    @State private var showQuickSwitcher = false
    @State private var showSupportAlert = false
    @State private var selectedRecording: Recording?
    @State private var isPlayerActive: Bool = false
    
    let refreshTimer = Timer.publish(every: 14400, on: .main, in: .common).autoconnect()
    var accentColor: Color { Color(hex: customAccentHex) ?? .blue }
    
    var body: some SwiftUI.View {
        GeometryReader { geo in
            let isL = geo.size.width > geo.size.height
            ZStack {
                backgroundLayer
                
                mainNavigationStack(isL: isL)
                    .zIndex(1)
                    .interactivePopGesture(isEnabled: !isPlayerActive)
                    .onChangeCompat(of: selectedChannel) { newValue in
                        isPlayerActive = (newValue != nil || viewModel.miniPlayerChannel != nil)
                    }
                    .onChangeCompat(of: viewModel.miniPlayerChannel) { newValue in
                        isPlayerActive = (selectedChannel != nil || newValue != nil)
                    }
                
                overlays(isL: isL)
            }
        }
        .ignoresSafeArea()
        .task { 
            if viewModel.channels.isEmpty { 
                await viewModel.loadData(url: xstreamURL, user: username, pass: password, type: LoginType(rawValue: loginTypeRaw) ?? .xtream) 
            }
            if showSupportPopup { 
                let now = Date().timeIntervalSince1970
                if now - lastSupportPopupTime > 43200 { 
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    showSupportAlert = true
                    lastSupportPopupTime = now 
                } 
            } 
        }
        .onReceive(refreshTimer) { _ in 
            Task { 
                await viewModel.loadData(url: xstreamURL, user: username, pass: password, type: LoginType(rawValue: loginTypeRaw) ?? .xtream, silent: true) 
            } 
        }
        .onChangeCompat(of: viewModel.channelToAutoPlay) { nc in 
            if let c = nc { 
                withAnimation(.easeInOut(duration: 0.4)) { selectedChannel = c }
                viewModel.channelToAutoPlay = nil 
            } 
        }
        .onChangeCompat(of: viewModel.triggerMultiView) { nv in 
            if nv { 
                selectedChannel = nil
                withAnimation(.spring()) { showMultiView = true }
                viewModel.triggerMultiView = false 
            } 
        }
    }
    
    private var backgroundLayer: some View {
        NebulaBackgroundView(color1: Color(hex: nebColor1) ?? .purple, color2: Color(hex: nebColor2) ?? .blue, color3: Color(hex: nebColor3) ?? .pink, point1: UnitPoint(x: nebX1, y: nebY1), point2: UnitPoint(x: nebX2, y: nebY2), point3: UnitPoint(x: nebX3, y: nebY3))
            .ignoresSafeArea()
            .zIndex(0)
    }
    
    @ViewBuilder
    private func mainNavigationStack(isL: Bool) -> some View {
        NavigationStack {
            ZStack {
                backgroundLayer
                contentLayout(isL: isL)
                
                if viewModel.activeMultiViewCount > 0 && !showMultiView && selectedChannel == nil { 
                    MultiViewIndicator(count: viewModel.activeMultiViewCount, accentColor: nil, action: { withAnimation(.spring()) { showMultiView = true } }).zIndex(5) 
                }
            }
            .modifier(MainViewModifiers(
                viewModel: viewModel,
                showMultiView: $showMultiView,
                showSettings: $showSettings,
                showSupportAlert: $showSupportAlert,
                showSupportPopup: $showSupportPopup,
                selectedRecording: $selectedRecording,
                accentColor: accentColor
            ))
        }
    }

    @ViewBuilder
    private func contentLayout(isL: Bool) -> some View {
        Group {
            if shouldUseSidebar(isLandscape: isL) { 
                SidebarLayout(viewModel: viewModel, selectedCategory: $selectedCategory, selectedChannel: $selectedChannel, searchText: $viewModel.searchText, isLandscape: isL, accentColor: accentColor, playAction: playChannel, showMultiView: $showMultiView, showSettings: $showSettings) 
            } else { 
                StandardLayout(viewModel: viewModel, selectedCategory: $selectedCategory, selectedChannel: $selectedChannel, searchText: $viewModel.searchText, accentColor: accentColor, playAction: playChannel, showMultiView: $showMultiView, showSettings: $showSettings, selectedRecording: $selectedRecording) 
            }
        }
        .zIndex(1)
    }
}

struct MainViewModifiers: ViewModifier {
    @ObservedObject var viewModel: ChannelViewModel
    @Binding var showMultiView: Bool
    @Binding var showSettings: Bool
    @Binding var showSupportAlert: Bool
    @Binding var showSupportPopup: Bool
    @Binding var selectedRecording: Recording?
    let accentColor: Color

    func body(content: Content) -> some View {
        let showRenameAlert = Binding(get: { viewModel.showRenameAlert }, set: { viewModel.showRenameAlert = $0 })
        let renameInput = Binding(get: { viewModel.renameInput }, set: { viewModel.renameInput = $0 })
        let showNoStreamsAlert = Binding(get: { viewModel.showNoStreamsAlert }, set: { viewModel.showNoStreamsAlert = $0 })
        let categories = Binding(get: { viewModel.categories }, set: { viewModel.categories = $0 })
        let searchText = Binding(get: { viewModel.searchText }, set: { viewModel.searchText = $0 })

        content
            .if(!showMultiView) { view in
                view.searchable(text: searchText, prompt: "Search").toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack {
                            Button(action: { withAnimation(.spring()) { showMultiView = true } }) { 
                                Image(systemName: "square.grid.2x2.fill").foregroundStyle(.white.opacity(0.8)) 
                            }
                            Button(action: { showSettings = true }) { 
                                Image(systemName: "gearshape.fill").foregroundStyle(.white.opacity(0.8)) 
                            }
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showMultiView) { MultiViewScreen(viewModel: viewModel, showMultiView: $showMultiView) }
            .fullScreenCover(item: $selectedRecording) { recording in RecordingPlayerView(recording: recording) }
            .sheet(isPresented: $showSettings) { SettingsView(categories: categories, accentColor: accentColor, viewModel: viewModel, onSave: { viewModel.saveCategorySettings() }) }
            .alert("No Streams Found", isPresented: showNoStreamsAlert) { Button("OK", role: .cancel) { } } message: { Text("No streams were found. Please search for the channel manually.") }
            .alert("Rename", isPresented: showRenameAlert) {
                TextField("New Name", text: renameInput)
                Button("Save") {
                    viewModel.confirmRename()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Support Project", isPresented: $showSupportAlert) {
                Button("Donate") { if let url = URL(string: "https://buymeacoffee.com/mongoosemonke") { UIApplication.shared.open(url) } }
                Button("Join Discord") { if let url = URL(string: "https://discord.gg/QkBUjsGCJ2") { UIApplication.shared.open(url) } }
                Button("Don't Show Again") { showSupportPopup = false }
                Button("Close", role: .cancel) {}
            } message: { Text("This is a free, open-source project that is constantly being worked on. If you enjoy using it, please consider donating to support development!") }
    }
}

extension MainView {
    @ViewBuilder
    private func overlays(isL: Bool) -> some View {
        if viewModel.isUpdatingEPG { 
            VStack { 
                EPGLoadingNotification(progress: viewModel.displayEPGProgress, accentColor: accentColor, onDismiss: { withAnimation(.spring()) { viewModel.isUpdatingEPG = false } })
                    .padding(.top, 65)
                Spacer() 
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(30) 
        }
        
        if let miniChannel = viewModel.miniPlayerChannel, selectedChannel == nil { 
            VStack { 
                Spacer()
                HStack { 
                    Spacer()
                    MiniPlayerView(channel: miniChannel, viewModel: viewModel, onExpand: { 
                        withAnimation(.easeInOut(duration: 0.4)) { 
                            selectedChannel = miniChannel
                            viewModel.miniPlayerChannel = nil 
                        } 
                    }, onClose: { 
                        withAnimation(.easeInOut(duration: 0.3)) { 
                            viewModel.miniPlayerChannel = nil 
                        } 
                    })
                    .padding(.trailing, 20)
                    .padding(.bottom, shouldUseSidebar(isLandscape: isL) ? 20 : 100) 
                } 
            }
            .zIndex(15)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity)) 
        }
        
        if let channel = selectedChannel { 
            CustomVideoPlayerView(channel: channel, viewModel: viewModel, onDismiss: { 
                if selectedChannel?.id == channel.id { 
                    withAnimation(.easeInOut(duration: 0.4)) { 
                        selectedChannel = nil
                        showQuickSwitcher = false 
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { 
                        viewModel.scrollRestoreTrigger = UUID() 
                    } 
                } 
            }, onPlayChannel: { newChannel in 
                playChannel(newChannel) 
            }, showQuickSwitcher: $showQuickSwitcher)
            .transition(.move(edge: .bottom))
            .zIndex(20)
            .ignoresSafeArea() 
        }
    }
    
    func playChannel(_ channel: StreamChannel) { 
        hideKeyboard()
        if viewModel.multiViewModeActive { 
            viewModel.addToMultiView(channel)
            viewModel.multiViewModeActive = false
            withAnimation(.spring()) { showMultiView = true } 
        } else { 
            viewModel.addToRecent(channel.id)
            viewModel.lastPlayedChannelID = channel.id
            viewModel.lastSourceCategory = selectedCategory
            withAnimation(.easeInOut(duration: 0.4)) { selectedChannel = channel } 
        } 
    }
    func shouldUseSidebar(isLandscape: Bool) -> Bool { if selectedCategory?.id == -3 { return false }; switch ViewMode(rawValue: viewMode) ?? .automatic { case .automatic: return isLandscape; case .sidebar: return true; case .standard: return false } }
}

extension SwiftUI.View { @ViewBuilder func `if`<Content: SwiftUI.View>(_ condition: Bool, transform: (Self) -> Content) -> some SwiftUI.View { if condition { transform(self) } else { self } } }