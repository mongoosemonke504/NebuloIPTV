import SwiftUI

struct AddPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var urlInput = ""
    @State private var usernameInput = ""
    @State private var passwordInput = ""
    @State private var macInput = ""
    @State private var playlistNameInput = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var selectedLoginType: LoginType = .xtream
    
    var accountToEdit: Account? = nil
    
    
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                NebulaBackgroundView(color1: .blue, color2: .purple, color3: .pink, point1: .init(x: 0.2, y: 0.2), point2: .init(x: 0.8, y: 0.8), point3: .init(x: 0.5, y: 0.5))
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 30) {
                        Text(accountToEdit != nil ? "Edit Playlist" : "Add New Playlist")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.top, 40)
                        
                        
                        VStack(spacing: 24) {
                            
                            HStack(spacing: 0) {
                                ForEach(LoginType.allCases) { t in
                                    Button(action: {
                                        withAnimation(.spring()) { selectedLoginType = t }
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
                                } else if selectedLoginType == .mac {
                                    PlaylistGlassTextField(icon: "cpu", placeholder: "00:1A:79...", text: $macInput)
                                        .onChangeCompat(of: macInput) { nv in formatMAC(nv) }
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
                        .foregroundColor(.white)
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
                    macInput = acc.macAddress ?? ""
                    selectedLoginType = acc.type
                }
            }
        }
    }
    
    func formatMAC(_ input: String) { let clean = input.uppercased().replacingOccurrences(of: "[^0-9A-F]", with: "", options: .regularExpression); var res = ""; for (i, c) in clean.enumerated() { if i > 0 && i % 2 == 0 && i < 12 { res.append(":") }; if i < 12 { res.append(c) } }; macInput = res }
    func parseM3ULink(_ input: String) { guard input.contains("username=") && input.contains("password="), let c = URLComponents(string: input) else { return }; if let u = c.queryItems?.first(where: { $0.name == "username" })?.value { usernameInput = u }; if let p = c.queryItems?.first(where: { $0.name == "password" })?.value { passwordInput = p }; if let sc = c.scheme, let h = c.host { var b = "\(sc)://\(h)"; if let po = c.port { b += ":\(po)" }; urlInput = b } }
    
    func save() {
        
        if selectedLoginType == .mac {
            errorMessage = "Stalker/MAC Portal support is currently under construction."
            showError = true
            return
        }

        let cl = urlInput.trimmingCharacters(in: .whitespaces)
        var safe = cl
        if safe.hasSuffix("/") { safe = String(safe.dropLast()) }
        
        if selectedLoginType == .xtream {
            guard !usernameInput.isEmpty, !passwordInput.isEmpty, !safe.isEmpty else { errorMessage = "Please enter server URL, username, and password."; showError = true; return }
        } else if selectedLoginType == .mac {
            guard !macInput.isEmpty, macInput.count >= 17, !safe.isEmpty else { errorMessage = "Please enter valid Portal URL and MAC."; showError = true; return }
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
            updated.macAddress = macInput
            
            
            
            AccountManager.shared.saveAccount(updated, makeActive: false)
        } else {
            
            let newAccount = Account(
                name: playlistNameInput.isEmpty ? "Playlist \(Int.random(in: 1...100))" : playlistNameInput,
                type: selectedLoginType,
                url: safe,
                username: usernameInput,
                password: passwordInput,
                macAddress: macInput
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
