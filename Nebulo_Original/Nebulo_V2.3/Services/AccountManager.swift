import Foundation
import Combine

class AccountManager: ObservableObject {
    static let shared = AccountManager()
    
    @Published var isLoggedIn: Bool = false
    
    @Published var currentAccount: Account? = nil {
        didSet {
            if let account = currentAccount {
                UserDefaults.standard.set(account.id.uuidString, forKey: "activeAccountID")
                self.isLoggedIn = true
            } else {
                UserDefaults.standard.removeObject(forKey: "activeAccountID")
                self.isLoggedIn = false
            }
            UserDefaults.standard.synchronize()
        }
    }
    @Published var accounts: [Account] = [] {
        didSet {
            saveAccounts()
        }
    }
    
    init() {
        loadAccounts()
    }
    
    private func loadAccounts() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "savedAccounts") {
            if let decoded = try? JSONDecoder().decode([Account].self, from: data) {
                self.accounts = decoded
            }
        }
        
        let activeIDStr = defaults.string(forKey: "activeAccountID")
        if let idStr = activeIDStr, let activeID = UUID(uuidString: idStr) {
            let found = accounts.first(where: { $0.id == activeID })
            self.currentAccount = found
            self.isLoggedIn = (found != nil)
        } else if !accounts.isEmpty {
            // Auto-recover session if we have accounts but lost the active ID
            let first = accounts.first
            self.currentAccount = first
            self.isLoggedIn = (first != nil)
        } else {
            self.isLoggedIn = false
        }
    }
    
    private func saveAccounts() {
        if let encoded = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(encoded, forKey: "savedAccounts")
            UserDefaults.standard.synchronize()
        }
    }
    
    func saveAccount(_ account: Account, makeActive: Bool) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            var newAccount = account
            
            let maxID = accounts.map { $0.stableID }.max() ?? 0
            
            
            
            
            
            if !accounts.isEmpty {
                newAccount.stableID = maxID + 1
            }
            accounts.append(newAccount)
            if makeActive {
                switchToAccount(newAccount)
            }
        }
    }
    
    func removeAccount(_ account: Account) {
        accounts.removeAll(where: { $0.id == account.id })
        if currentAccount?.id == account.id {
            currentAccount = accounts.first
        }
    }
    
    func switchToAccount(_ account: Account) {
        currentAccount = account
    }
}
