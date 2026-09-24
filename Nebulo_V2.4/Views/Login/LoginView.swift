import SwiftUI

struct LoginView: View {
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    @AppStorage("xstreamURL") private var xstreamURL = ""
    @AppStorage("username") private var username = ""
    @AppStorage("password") private var password = ""
    @AppStorage("loginTypeRaw") private var loginTypeRaw = LoginType.xtream.rawValue

    @AppStorage("nebColor1") private var nebColor1 = "#1A2538"
    @AppStorage("nebColor2") private var nebColor2 = "#11101A"
    @AppStorage("nebColor3") private var nebColor3 = "#1F1A24"
    @AppStorage("nebX1") private var nebX1 = 0.5
    @AppStorage("nebY1") private var nebY1 = 0.0
    @AppStorage("nebX2") private var nebX2 = 0.5
    @AppStorage("nebY2") private var nebY2 = 0.5
    @AppStorage("nebX3") private var nebX3 = 0.5
    @AppStorage("nebY3") private var nebY3 = 1.0

    @State private var urlInput = ""
    @State private var usernameInput = ""
    @State private var passwordInput = ""
    @State private var playlistNameInput = ""
    @State private var showError = false
    @State private var errorTitle = "Connection Error"
    @State private var errorMessage = ""
    /// Between the tap and the verdict: the playlist is loading, and the
    /// login screen holds until it knows whether it worked.
    @State private var isConnecting = false
    @State private var selectedLoginType: LoginType = .xtream

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                NebulaBackgroundView(
                    color1: Color(hex: nebColor1) ?? .purple,
                    color2: Color(hex: nebColor2) ?? .blue,
                    color3: Color(hex: nebColor3) ?? .pink,
                    point1: UnitPoint(x: nebX1, y: nebY1),
                    point2: UnitPoint(x: nebX2, y: nebY2),
                    point3: UnitPoint(x: nebX3, y: nebY3)
                )
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 30) {
                        
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(.white.opacity(0.1))
                                    .frame(width: 120, height: 120)
                                    .blur(radius: 20)
                                
                                Image(systemName: "play.tv.fill")
                                    .font(.system(size: 70))
                                    .foregroundStyle(.primary)
                                    .shadow(color: .white.opacity(0.3), radius: 10)
                            }
                            
                            VStack(spacing: 4) {
                                Text("Onside TV")
                                    .font(.system(size: 42, weight: .black, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                
                                Text("STREAMING REIMAGINED")
                                    .font(.system(size: 10, weight: .bold))
                                    .kerning(2.5)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 60)
                        
                        
                        VStack(spacing: 24) {
                            
                            HStack(spacing: 0) {
                                ForEach(LoginType.allCases) { t in
                                    Button(action: {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                            selectedLoginType = t
                                            loginTypeRaw = t.rawValue
                                        }
                                    }) {
                                        Text(t == .xtream ? "Xtream" : "M3U")
                                            .font(.system(size: 13, weight: .bold))
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 38)
                                            .background(
                                                ZStack {
                                                    if selectedLoginType == t {
                                                        RoundedRectangle(cornerRadius: 10)
                                                            .fill(.white)
                                                            .matchedGeometryEffect(id: "picker", in: loginNamespace)
                                                            .shadow(color: .black.opacity(0.2), radius: 5)
                                                    }
                                                }
                                            )
                                            .foregroundColor(selectedLoginType == t ? .black : .white)
                                    }
                                }
                            }
                            .padding(4)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(14)
                            
                            
                            VStack(spacing: 16) {
                                GlassTextField(icon: "tag.fill", placeholder: "Playlist Name (Optional)", text: $playlistNameInput)
                                
                                GlassTextField(
                                    icon: "link",
                                    placeholder: selectedLoginType == .m3u ? "M3U Playlist URL" : "Portal URL",
                                    text: $urlInput,
                                    keyboard: .URL
                                )
                                
                                if selectedLoginType == .xtream {
                                    GlassTextField(icon: "person.fill", placeholder: "Username", text: $usernameInput)
                                    GlassTextField(icon: "lock.fill", placeholder: "Password", text: $passwordInput, isSecure: true)
                                }
                            }
                            
                            
                            Button(action: login) {
                                HStack(spacing: 10) {
                                    if isConnecting {
                                        ProgressView().tint(.black)
                                    }
                                    Text(isConnecting ? "Connecting…" : "Connect to Server")
                                }
                                .font(.headline)
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(Color.white.opacity(isConnecting ? 0.8 : 1))
                                .cornerRadius(16)
                                .shadow(color: .white.opacity(0.2), radius: 15)
                            }
                            .disabled(isConnecting)
                            .padding(.top, 8)
                        }
                        .padding(24)
                        .modifier(GlassEffect(cornerRadius: 30, isSelected: true, accentColor: nil))
                        .padding(.horizontal, 24)
                        
                        Text(" ")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.bottom, 50)
                }
            }
            .alert(errorTitle, isPresented: $showError) {
                Button("Got it", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onChangeCompat(of: urlInput) { nv in if selectedLoginType == .xtream { parseM3ULink(nv) } }
            .onAppear {
                if let s = LoginType(rawValue: loginTypeRaw) { selectedLoginType = s }
                urlInput = xstreamURL
                usernameInput = username
                passwordInput = password
            }
        }
    }
    
    @Namespace private var loginNamespace
    
    func parseM3ULink(_ input: String) { guard input.contains("username=") && input.contains("password="), let c = URLComponents(string: input) else { return }; if let u = c.queryItems?.first(where: { $0.name == "username" })?.value { usernameInput = u }; if let p = c.queryItems?.first(where: { $0.name == "password" })?.value { passwordInput = p }; if let sc = c.scheme, let h = c.host { var b = "\(sc)://\(h)"; if let po = c.port { b += ":\(po)" }; urlInput = b } }
    
    func login() {
        
        let cl = urlInput.trimmingCharacters(in: .whitespaces)
        var safe = cl
        if safe.hasSuffix("/") { safe = String(safe.dropLast()) }
        
        guard !isConnecting else { return }

        if selectedLoginType == .xtream {
            guard !usernameInput.isEmpty, !passwordInput.isEmpty, !safe.isEmpty else { errorTitle = "Missing Details"; errorMessage = "Please enter your server URL, username, and password."; showError = true; return }
        } else {
            guard !safe.isEmpty else { errorTitle = "Missing Details"; errorMessage = "Please enter a valid Playlist URL."; showError = true; return }
        }
        
        
        let newAccount = Account(
            name: playlistNameInput.isEmpty ? "Playlist \(Int.random(in: 1...100))" : playlistNameInput,
            type: selectedLoginType,
            url: safe,
            username: usernameInput,
            password: passwordInput
        )
        let type = selectedLoginType
        let user = usernameInput
        let pass = passwordInput

        isConnecting = true
        Task { @MainActor in
            // Saved, but NOT made current. The app leaves the login screen
            // the moment an account becomes current, and it mustn't until
            // this one has proven it works — a wrong password used to land
            // on an empty home screen with nothing to say why.
            AccountManager.shared.saveAccount(newAccount, makeActive: false)
            let loaded = await ChannelViewModel.shared.loadNewlySignedInAccount(newAccount)

            if loaded {
                isLoggedIn = true
                // The saved copy, not the local one: saving can assign it a
                // different stable ID.
                let saved = AccountManager.shared.accounts.first { $0.id == newAccount.id } ?? newAccount
                withAnimation(.easeInOut(duration: 0.5)) { AccountManager.shared.switchToAccount(saved) }
            } else {
                AccountManager.shared.removeAccount(newAccount)
                // Only now ask the server why — on this path alone, so a good
                // login never pays for the extra request.
                let failure = await PlaylistValidator.validate(type: type, url: safe, username: user, password: pass)
                (errorTitle, errorMessage) = Self.explanation(for: failure, type: type)
                showError = true
            }
            isConnecting = false
        }
    }

    /// What a login that loaded nothing tells the user. "Login incorrect" is
    /// what it nearly always is, so that is the default — but a server that
    /// never answered is not a wrong password, and saying it was would send
    /// someone off re-typing a password that was right.
    private static func explanation(for failure: PlaylistValidator.Failure?, type: LoginType) -> (title: String, message: String) {
        switch failure {
        case .unreachable?:
            return ("Can't Reach Server", PlaylistValidator.Failure.unreachable.errorDescription ?? "")
        case .badURL?:
            return ("Invalid Address", PlaylistValidator.Failure.badURL.errorDescription ?? "")
        default:
            return ("Login Incorrect", type == .xtream
                ? "No channels loaded for that username and password. Check them, and that your subscription is still active."
                : "No channels loaded from that playlist link. Check the link with your provider.")
        }
    }
}

struct GlassTextField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var keyboard: UIKeyboardType = .default
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            
            Group {
                if isSecure {
                    SecureField("", text: $text, prompt: Text(placeholder).foregroundColor(.secondary))
                } else {
                    TextField("", text: $text, prompt: Text(placeholder).foregroundColor(.secondary))
                }
            }
            .font(.system(size: 15))
            .foregroundStyle(.primary)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(keyboard)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Color.white.opacity(0.06))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}
