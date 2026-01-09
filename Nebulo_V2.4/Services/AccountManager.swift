import Foundation
import Combine

class AccountManager: ObservableObject {
    static let shared = AccountManager()
    
    @Published var isLoggedIn: Bool = false
    @Published var username: String = ""
    @Published var currentAccount: Account? = nil // Correctly uses Account from Models/Account.swift
    @Published var accounts: [Account] = []
    
    init() {
        // Placeholder init
    }
    
    func login(user: String, pass: String) async -> Bool {
        // Placeholder login logic
        return true
    }
    
    func logout() {
        // Placeholder logout logic
        isLoggedIn = false
        currentAccount = nil // Clear current account on logout
    }

    func saveAccount(_ account: Account, makeActive: Bool) {
        // Placeholder for saving account logic
        if !accounts.contains(where: { $0.id == account.id }) {
            accounts.append(account)
        }
        if makeActive {
            currentAccount = account
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