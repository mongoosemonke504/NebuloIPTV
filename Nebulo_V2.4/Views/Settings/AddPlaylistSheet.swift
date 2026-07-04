import SwiftUI

struct AddPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var urlInput = ""
    @State private var usernameInput = ""
    @State private var passwordInput = ""
    @State private var playlistNameInput = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var selectedLoginType: LoginType = .xtream

    @AppStorage("nebColor1") private var nebColor1 = "#1A2538"
    @AppStorage("nebColor2") private var nebColor2 = "#11101A"
    @AppStorage("nebColor3") private var nebColor3 = "#1F1A24"
    @AppStorage("nebX1") private var nebX1 = 0.5
    @AppStorage("nebY1") private var nebY1 = 0.0
    @AppStorage("nebX2") private var nebX2 = 0.5
    @AppStorage("nebY2") private var nebY2 = 0.5
    @AppStorage("nebX3") private var nebX3 = 0.5
    @AppStorage("nebY3") private var nebY3 = 1.0

    var accountToEdit: Account? = nil



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
                        Text(accountToEdit != nil ? "Edit Playlist" : "Add New Playlist")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .padding(.top, 40)
                        
                        
                        VStack(spacing: 24) {
                            
                            HStack(spacing: 0) {
                                ForEach(LoginType.allCases) { t in
                                    Button(action: {
                                        withAnimation(.spring()) { selectedLoginType = t }
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
                                PlaylistGlassTextField(icon: "tag.fill", placeholder: "Playlist Name (Optional)", text: $playlistNameInput)
                                
                                PlaylistGlassTextField(
                                    icon: "link",
                                    placeholder: selectedLoginType == .m3u ? "M3U Playlist URL" : "Portal URL",
                                    text: $urlInput,
                                    keyboard: .URL
                                )
                                
                                if selectedLoginType == .xtream {
                                    PlaylistGlassTextField(icon: "person.fill", placeholder: "Username", text: $usernameInput)
                                    PlaylistGlassTextField(icon: "lock.fill", placeholder: "Password", text: $passwordInput, isSecure: true)
                                }
                            }
                            
                            
                            Button(action: save) {
                                Text(accountToEdit != nil ? "Save Changes" : "Add Playlist")
                                    .font(.headline)
                                    .foregroundColor(.black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 54)
                                    .background(Color.white)
                                    .cornerRadius(16)
                                    .shadow(color: .white.opacity(0.2), radius: 15)
                            }
                            .padding(.top, 8)
                        }
                        .padding(24)
                        .modifier(GlassEffect(cornerRadius: 30, isSelected: true, accentColor: nil))
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 50)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.primary)
                }
            }
            .alert("Input Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onChangeCompat(of: urlInput) { nv in if selectedLoginType == .xtream { parseM3ULink(nv) } }
            .onAppear {
                if let acc = accountToEdit {
                    playlistNameInput = acc.name
                    urlInput = acc.url
                    usernameInput = acc.username ?? ""
                    passwordInput = acc.password ?? ""
                    selectedLoginType = acc.type
                }
            }
        }
    }
    
    func parseM3ULink(_ input: String) { guard input.contains("username=") && input.contains("password="), let c = URLComponents(string: input) else { return }; if let u = c.queryItems?.first(where: { $0.name == "username" })?.value { usernameInput = u }; if let p = c.queryItems?.first(where: { $0.name == "password" })?.value { passwordInput = p }; if let sc = c.scheme, let h = c.host { var b = "\(sc)://\(h)"; if let po = c.port { b += ":\(po)" }; urlInput = b } }
    
    func save() {
        
        let cl = urlInput.trimmingCharacters(in: .whitespaces)
        var safe = cl
        if safe.hasSuffix("/") { safe = String(safe.dropLast()) }
        
        if selectedLoginType == .xtream {
            guard !usernameInput.isEmpty, !passwordInput.isEmpty, !safe.isEmpty else { errorMessage = "Please enter server URL, username, and password."; showError = true; return }
        } else {
            guard !safe.isEmpty else { errorMessage = "Please enter a valid Playlist URL."; showError = true; return }
        }
        
        if let existing = accountToEdit {
            var updated = existing
            updated.name = playlistNameInput.isEmpty ? "Playlist" : playlistNameInput
            updated.type = selectedLoginType
            updated.url = safe
            updated.username = usernameInput
            updated.password = passwordInput
            
            
            
            AccountManager.shared.saveAccount(updated, makeActive: false)
        } else {
            
            let newAccount = Account(
                name: playlistNameInput.isEmpty ? "Playlist \(Int.random(in: 1...100))" : playlistNameInput,
                type: selectedLoginType,
                url: safe,
                username: usernameInput,
                password: passwordInput
            )
            AccountManager.shared.saveAccount(newAccount, makeActive: true)
        }
        dismiss()
    }
}

struct PlaylistGlassTextField: View {
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
