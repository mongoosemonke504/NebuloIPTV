import SwiftUI

struct ManageEPGsView: View {
    @ObservedObject var accountManager = AccountManager.shared
    @State private var showingAddSheet = false
    @State private var newEPGUrl = ""
    @State private var pendingRemoval: String? = nil

    @AppStorage("nebColor1") private var nebColor1 = "#1A2538"
    @AppStorage("nebColor2") private var nebColor2 = "#11101A"
    @AppStorage("nebColor3") private var nebColor3 = "#1F1A24"
    @AppStorage("nebX1") private var nebX1 = 0.5
    @AppStorage("nebY1") private var nebY1 = 0.0
    @AppStorage("nebX2") private var nebX2 = 0.5
    @AppStorage("nebY2") private var nebY2 = 0.5
    @AppStorage("nebX3") private var nebX3 = 0.5
    @AppStorage("nebY3") private var nebY3 = 1.0

    var currentAccount: Account? {
        if let activeID = accountManager.currentAccount?.id {
            return accountManager.accounts.first(where: { $0.id == activeID })
        }
        return accountManager.currentAccount
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

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    headerCard
                    if let account = currentAccount {
                        if account.externalEPGUrls.isEmpty {
                            emptyStateCard
                        } else {
                            epgListCard(account: account)
                        }
                        addButton
                    } else {
                        noAccountCard
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 60)
            }
        }
        .navigationTitle("Manage EPGs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingAddSheet) {
            addSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert("Remove EPG?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { url in
            Button("Remove", role: .destructive) {
                removeEPG(url)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("This source will no longer be merged into your EPG.")
        }
    }

    // MARK: Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.purple.gradient)
                        .frame(width: 36, height: 36)
                    Image(systemName: "list.bullet.clipboard")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("External EPG Sources")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
            }
            Text("Add XMLTV or gzipped XML guide links. They'll be merged on top of your provider's built-in EPG every refresh.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: Empty state

    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("No external EPGs added")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
            Text("Tap + to paste an XMLTV link from another provider.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 0.8, dash: [5, 4]))
        )
    }

    private var noAccountCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.yellow.opacity(0.85))
            Text("Please select an account first.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
    }

    // MARK: EPG list

    private func epgListCard(account: Account) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(account.externalEPGUrls.enumerated()), id: \.element) { idx, url in
                epgRow(url: url, isFirst: idx == 0, isLast: idx == account.externalEPGUrls.count - 1)
                if idx < account.externalEPGUrls.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 0.5)
                        .padding(.leading, 56)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func epgRow(url: String, isFirst: Bool, isLast: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.teal.gradient)
                    .frame(width: 32, height: 32)
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }

            Text(url)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                pendingRemoval = url
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.red.opacity(0.7), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Add button

    private var addButton: some View {
        Button(action: { newEPGUrl = ""; showingAddSheet = true }) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("Add EPG URL")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.blue.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Add sheet

    private var addSheet: some View {
        NavigationStack {
            ZStack {
                NebulaBackgroundView(
                    color1: Color(hex: nebColor1) ?? .purple,
                    color2: Color(hex: nebColor2) ?? .blue,
                    color3: Color(hex: nebColor3) ?? .pink,
                    point1: UnitPoint(x: nebX1, y: nebY1),
                    point2: UnitPoint(x: nebX2, y: nebY2),
                    point3: UnitPoint(x: nebX3, y: nebY3)
                )

                VStack(alignment: .leading, spacing: 16) {
                    Text("EPG URL")
                        .font(.system(size: 13, weight: .black))
                        .kerning(0.8)
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 4)

                    TextField("", text: $newEPGUrl, prompt: Text("https://example.com/epg.xml.gz").foregroundColor(.white.opacity(0.35)))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.black.opacity(0.4))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                        )

                    Text("Supports XMLTV (.xml) and gzipped (.xml.gz) formats. The link will be fetched every EPG refresh.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 4)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
            }
            .navigationTitle("Add EPG")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddSheet = false }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addEPG()
                        showingAddSheet = false
                    }
                    .foregroundStyle(.white)
                    .fontWeight(.semibold)
                    .disabled(newEPGUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: Actions

    func addEPG() {
        guard let currentID = accountManager.currentAccount?.id,
              var account = accountManager.accounts.first(where: { $0.id == currentID }) else { return }

        let clean = newEPGUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty && !account.externalEPGUrls.contains(clean) {
            account.externalEPGUrls.append(clean)
            withAnimation {
                accountManager.saveAccount(account, makeActive: true)
            }
        }
    }

    func removeEPG(_ url: String) {
        guard let currentID = accountManager.currentAccount?.id,
              var account = accountManager.accounts.first(where: { $0.id == currentID }) else { return }

        if let idx = account.externalEPGUrls.firstIndex(of: url) {
            account.externalEPGUrls.remove(at: idx)
            withAnimation {
                accountManager.saveAccount(account, makeActive: true)
            }
        }
    }
}
