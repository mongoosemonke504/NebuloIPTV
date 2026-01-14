import SwiftUI

struct LoginView: View {
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    @AppStorage("xstreamURL") private var xstreamURL = ""
    @AppStorage("username") private var username = ""
    @AppStorage("password") private var password = ""
    @AppStorage("macAddress") private var macAddress = ""
    @AppStorage("loginTypeRaw") private var loginTypeRaw = LoginType.xtream.rawValue
    
    @State private var urlInput = ""
    @State private var usernameInput = ""
    @State private var passwordInput = ""
    @State private var macInput = ""
    @State private var playlistNameInput = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var selectedLoginType: LoginType = .xtream
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                NebulaBackgroundView(color1: .blue, color2: .purple, color3: .pink, point1: .init(x: 0.2, y: 0.2), point2: .init(x: 0.8, y: 0.8), point3: .init(x: 0.5, y: 0.5))
                
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
                                    .foregroundStyle(.white)
                                    .shadow(color: .white.opacity(0.3), radius: 10)
                            }
                            
                            VStack(spacing: 4) {
                                Text("Nebulo")
                                    .font(.system(size: 42, weight: .black, design: .rounded))
                                    .foregroundStyle(.white)
                                
                                Text("STREAMING REIMAGINED")
                                    .font(.system(size: 10, weight: .bold))
                                    .kerning(2.5)
                                    .foregroundStyle(.white.opacity(0.5))
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
                                        Text(t == .xtream ? "Xtream" : (t == .m3u ? "M3U" : "MAC"))
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
                                
                                if selectedLoginType == .mac {
                                    VStack(spacing: 12) {
                                        Image(systemName: "hammer.fill")
                                            .font(.system(size: 40))
                                            .foregroundColor(.yellow)
                                        Text("Under Construction")
                                            .font(.headline)
                                            .foregroundColor(.white)
                                        Text("Stalker/MAC Portal support is coming soon.")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.7))
                                            .multilineTextAlignment(.center)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 30)
                                    .background(Color.white.opacity(0.05))
                                    .cornerRadius(12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                                } else {
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
                            }
                            
                            
                            Button(action: login) {
                                Text("Connect to Server")
                                    .font(.headline)
                                    .foregroundColor(.black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 54)
                                    .background(Color.white)
                                    .cornerRadius(16)
                                    .shadow(color: .white.opacity(0.2), radius: 15)
                            }
                            .disabled(selectedLoginType == .mac)
                            .opacity(selectedLoginType == .mac ? 0.5 : 1)
                            .padding(.top, 8)
                        }
                        .padding(24)
                        .modifier(GlassEffect(cornerRadius: 30, isSelected: true, accentColor: nil))
                        .padding(.horizontal, 24)
                        
                        Text(" ")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.bottom, 50)
                }
            }
            .alert("Connection Error", isPresented: $showError) {
                Button("Got it", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onChangeCompat(of: urlInput) { nv in if selectedLoginType == .xtream { parseM3ULink(nv) } }
            .onAppear {
                if let s = LoginType(rawValue: loginTypeRaw) { selectedLoginType = s }
                macInput = macAddress
                urlInput = xstreamURL
                usernameInput = username
                passwordInput = password
            }
        }
    }
    
    @Namespace private var loginNamespace
    
    func formatMAC(_ input: String) { let clean = input.uppercased().replacingOccurrences(of: "[^0-9A-F]", with: "", options: .regularExpression); var res = ""; for (i, c) in clean.enumerated() { if i > 0 && i % 2 == 0 && i < 12 { res.append(":") }; if i < 12 { res.append(c) } }; macInput = res }
    func parseM3ULink(_ input: String) { guard input.contains("username=") && input.contains("password="), let c = URLComponents(string: input) else { return }; if let u = c.queryItems?.first(where: { $0.name == "username" })?.value { usernameInput = u }; if let p = c.queryItems?.first(where: { $0.name == "password" })?.value { passwordInput = p }; if let sc = c.scheme, let h = c.host { var b = "\(sc)://\(h)"; if let po = c.port { b += ":\(po)" }; urlInput = b } }
    
    func login() {
        
        if selectedLoginType == .mac {
            errorMessage = "Stalker/MAC Portal support is currently under construction."
            showError = true
            return
        }

        let cl = urlInput.trimmingCharacters(in: .whitespaces)
        var safe = cl
        if safe.hasSuffix("/") { safe = String(safe.dropLast()) }
        
        if selectedLoginType == .xtream {
            guard !usernameInput.isEmpty, !passwordInput.isEmpty, !safe.isEmpty else { errorMessage = "Please enter your server URL, username, and password."; showError = true; return }
        } else if selectedLoginType == .mac {
            guard !macInput.isEmpty, macInput.count >= 17, !safe.isEmpty else { errorMessage = "Please enter a valid Portal URL and MAC Address."; showError = true; return }
        } else {
            guard !safe.isEmpty else { errorMessage = "Please enter a valid Playlist URL."; showError = true; return }
        }
        
        
        let newAccount = Account(
            name: playlistNameInput.isEmpty ? "Playlist \(Int.random(in: 1...100))" : playlistNameInput,
            type: selectedLoginType,
            url: safe,
            username: usernameInput,
            password: passwordInput,
            macAddress: macInput
        )
        
        AccountManager.shared.saveAccount(newAccount, makeActive: true)
        withAnimation(.easeInOut(duration: 0.5)) { isLoggedIn = true }
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
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 20)
            
            Group {
                if isSecure {
                    SecureField("", text: $text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.3)))
                } else {
                    TextField("", text: $text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.3)))
                }
            }
            .font(.system(size: 15))
            .foregroundColor(.white)
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
