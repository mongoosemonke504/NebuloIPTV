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


/// Checks that a playlist actually gives you something before it is saved.
///
/// A wrong host, a typo'd password or an expired line all "save" perfectly well
/// and then leave the app sitting on an empty home screen with nothing to say
/// for itself. This asks the source for its channels the same way the loader
/// will, and reports what went wrong in the user's terms.
enum PlaylistValidator {
    enum Failure: LocalizedError {
        case badURL
        case unreachable
        case rejected           // reached the server, it refused the credentials
        case empty              // reached it, got a valid answer, no channels in it

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "That doesn't look like a valid address. Check the server URL and try again."
            case .unreachable:
                return "Couldn't reach that server. Check the address and your connection."
            case .rejected:
                return "The server rejected those details. Check the username and password."
            case .empty:
                return "Connected, but the playlist has no channels in it. Check the details with your provider."
            }
        }
    }

    /// 15s: long enough for a slow provider, short enough that a dead host does
    /// not leave the sheet spinning.
    private static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }

    static func validate(type: LoginType, url: String, username: String, password: String) async -> Failure? {
        switch type {
        case .xtream: return await validateXtream(url: url, username: username, password: password)
        case .m3u:    return await validateM3U(url: url)
        }
    }

    private static func validateXtream(url: String, username: String, password: String) async -> Failure? {
        guard let base = URL(string: url), base.host != nil else { return .badURL }
        var components = URLComponents(url: base.appendingPathComponent("player_api.php"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "action", value: "get_live_streams")
        ]
        guard let endpoint = components?.url else { return .badURL }

        guard let (data, response) = try? await session.data(from: endpoint) else { return .unreachable }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return http.statusCode == 401 || http.statusCode == 403 ? .rejected : .unreachable
        }
        // A refused line answers 200 with `{"user_info":{"auth":0}}` rather than
        // an array, so the SHAPE of the answer is what separates the two.
        if let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return array.isEmpty ? .empty : nil
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let info = object["user_info"] as? [String: Any] {
                let auth = (info["auth"] as? Int) ?? Int((info["auth"] as? String) ?? "") ?? 0
                return auth == 1 ? .empty : .rejected
            }
            return .rejected
        }
        return .unreachable
    }

    private static func validateM3U(url: String) async -> Failure? {
        guard let endpoint = URL(string: url), endpoint.host != nil else { return .badURL }
        guard let (data, response) = try? await session.data(from: endpoint) else { return .unreachable }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return http.statusCode == 401 || http.statusCode == 403 ? .rejected : .unreachable
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return .unreachable
        }
        // One entry is enough to prove it is a playlist with something in it.
        guard text.contains("#EXTM3U") || text.contains("#EXTINF") else { return .unreachable }
        return text.contains("#EXTINF") ? nil : .empty
    }
}
