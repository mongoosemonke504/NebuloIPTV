import Foundation
import Combine

struct GitHubRelease: Codable {
    let tagName: String
    let htmlUrl: String
    let body: String
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case body
    }
}

@MainActor
class UpdateService: ObservableObject {
    static let shared = UpdateService()
    
    @Published var isUpdateAvailable = false
    @Published var latestRelease: GitHubRelease?
    @Published var checkingForUpdate = false
    @Published var errorMessage: String?
    
    // CONFIGURATION: Change these to match your GitHub repository
    private let repoOwner = "mongoosemonke504"
    private let repoName = "NebuloIPTV"
    
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    
    func checkForUpdates(manual: Bool = false) async {
        checkingForUpdate = true
        errorMessage = nil
        
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            checkingForUpdate = false
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            
            let cleanCurrent = currentVersion.lowercased().replacingOccurrences(of: "v", with: "")
            let cleanLatest = release.tagName.lowercased().replacingOccurrences(of: "v", with: "")
            
            if cleanLatest.compare(cleanCurrent, options: .numeric) == .orderedDescending {
                self.latestRelease = release
                self.isUpdateAvailable = true
            } else {
                self.isUpdateAvailable = false
                if manual {
                    self.errorMessage = "You are up to date! Version \(currentVersion)"
                }
            }
        } catch {
            print("Update Check Failed: \(error)")
            if manual {
                self.errorMessage = "Failed to check for updates."
            }
        }
        
        checkingForUpdate = false
    }
}
