import SwiftUI

struct ManageEPGsView: View {
    @ObservedObject var accountManager = AccountManager.shared
    @State private var showingAddSheet = false
    @State private var newEPGUrl = ""
    @State private var editingEPGUrl: String? = nil
    
    var currentAccount: Account? {
        if let activeID = accountManager.currentAccount?.id {
            return accountManager.accounts.first(where: { $0.id == activeID })
        }
        return accountManager.currentAccount
    }
    
    var body: some View {
        List {
            Section(footer: Text("Add external XMLTV or GZipped XML links to merge with your provider's EPG.")) {
                if let account = currentAccount {
                    if account.externalEPGUrls.isEmpty {
                        Text("No external EPGs added.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(account.externalEPGUrls, id: \.self) { url in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(url)
                                        .font(.body)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    removeEPG(url)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    
                    Button(action: { newEPGUrl = ""; showingAddSheet = true }) {
                        Label("Add EPG URL", systemImage: "plus.circle")
                    }
                } else {
                    Text("Please select an account first.")
                }
            }
        }
        .navigationTitle("Manage EPGs")
        .sheet(isPresented: $showingAddSheet) {
            NavigationStack {
                Form {
                    Section(header: Text("EPG URL")) {
                        TextField("https://example.com/epg.xml.gz", text: $newEPGUrl)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .navigationTitle("Add EPG")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingAddSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            addEPG()
                            showingAddSheet = false
                        }
                        .disabled(newEPGUrl.isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
    
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
