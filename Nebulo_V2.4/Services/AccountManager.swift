import Foundation
import Combine

class AccountManager: ObservableObject {
    static let shared = AccountManager()
    
    @Published var isLoggedIn: Bool = false
    @Published var currentAccount: Account? = nil {
        didSet {
            if let account = currentAccount {
                UserDefaults.standard.set(account.id.uuidString, forKey: "activeAccountID")
                isLoggedIn = true
            } else {
                UserDefaults.standard.removeObject(forKey: "activeAccountID")
                isLoggedIn = false
            }
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
        if let data = UserDefaults.standard.data(forKey: "savedAccounts"),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            self.accounts = decoded
        }
        
        if let activeIDStr = UserDefaults.standard.string(forKey: "activeAccountID"),
           let activeID = UUID(uuidString: activeIDStr) {
            self.currentAccount = accounts.first(where: { $0.id == activeID })
            self.isLoggedIn = (self.currentAccount != nil)
        }
    }
    
    private func saveAccounts() {
        if let encoded = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(encoded, forKey: "savedAccounts")
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
