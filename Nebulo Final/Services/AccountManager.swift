import Foundation
import Combine

class AccountManager: ObservableObject {
    static let shared = AccountManager()
    
    @Published var accounts: [Account] = []
    @Published var currentAccount: Account?
    
    private let accountsKey = "savedAccounts"
    private let currentAccountIDKey = "currentAccountID"
    
    init() {
        loadAccounts()
        loadCurrentAccount()
    }
    
    func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            self.accounts = decoded
        }
    }
    
    func loadCurrentAccount() {
        if accounts.isEmpty {
            migrateLegacyAccount()
        }
        
        if let idStr = UserDefaults.standard.string(forKey: currentAccountIDKey),
           let id = UUID(uuidString: idStr) {
            self.currentAccount = accounts.first(where: { $0.id == id })
        }
        
        // Auto-select first if none selected but accounts exist
        if currentAccount == nil, let first = accounts.first {
            switchToAccount(first)
        }
    }
    
    func saveAccount(_ account: Account, makeActive: Bool = true) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
        } else {
            accounts.append(account)
        }
        persistAccounts()
        if makeActive { switchToAccount(account) }
    }
    
    func removeAccount(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        persistAccounts()
        if currentAccount?.id == account.id {
            if let first = accounts.first {
                switchToAccount(first)
            } else {
                currentAccount = nil
                UserDefaults.standard.removeObject(forKey: currentAccountIDKey)
                UserDefaults.standard.set(false, forKey: "isLoggedIn")
            }
        }
    }
    
    func switchToAccount(_ account: Account) {
        currentAccount = account
        UserDefaults.standard.set(account.id.uuidString, forKey: currentAccountIDKey)
        
        // Sync to legacy keys for compatibility with older parts of the app that read UserDefaults directly
        // (Though we will aim to replace those reads)
        UserDefaults.standard.set(account.url, forKey: "xstreamURL")
        UserDefaults.standard.set(account.username ?? "", forKey: "username")
        UserDefaults.standard.set(account.password ?? "", forKey: "password")
        UserDefaults.standard.set(account.macAddress ?? "", forKey: "macAddress")
        UserDefaults.standard.set(account.type.rawValue, forKey: "loginTypeRaw")
        UserDefaults.standard.set(true, forKey: "isLoggedIn")
    }
    
    private func persistAccounts() {
        if let encoded = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(encoded, forKey: accountsKey)
        }
    }
    
    private func migrateLegacyAccount() {
        let url = UserDefaults.standard.string(forKey: "xstreamURL") ?? ""
        // Check "isLoggedIn" to avoid migrating empty garbage on fresh install
        let isLoggedIn = UserDefaults.standard.bool(forKey: "isLoggedIn")
        
        if isLoggedIn && !url.isEmpty {
            let user = UserDefaults.standard.string(forKey: "username") ?? ""
            let pass = UserDefaults.standard.string(forKey: "password") ?? ""
            let mac = UserDefaults.standard.string(forKey: "macAddress") ?? ""
            let typeRaw = UserDefaults.standard.string(forKey: "loginTypeRaw") ?? LoginType.xtream.rawValue
            let type = LoginType(rawValue: typeRaw) ?? .xtream
            
            let newAccount = Account(name: "Default Account", type: type, url: url, username: user, password: pass, macAddress: mac)
            accounts.append(newAccount)
            persistAccounts()
            // Don't switch yet, loadCurrentAccount will handle logic
        }
    }
}
