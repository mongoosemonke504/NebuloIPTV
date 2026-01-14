import Foundation
import Combine

class UpdateService: ObservableObject {
    static let shared = UpdateService()
    
    @Published var isUpdating: Bool = false
    @Published var updateProgress: Double = 0.0
    
    @Published var currentVersion: String = "V2.2(13)"
    @Published var checkingForUpdate: Bool = false
    @Published var isUpdateAvailable: Bool = false
    @Published var showUpToDate: Bool = false
    @Published var latestRelease: UpdateRelease? = nil
    @Published var errorMessage: String? = nil
    
    init() {
        Task {
            await checkForUpdates(manual: false)
        }
    }
    
    func checkForUpdates(manual: Bool = false) async {
        guard !checkingForUpdate else { return }
        
        await MainActor.run {
            checkingForUpdate = true
            showUpToDate = false
            errorMessage = nil
        }
        
        // GitHub API URL
        guard let url = URL(string: "https://api.github.com/repos/mongoosemonke504/NebuloIPTV/releases/latest") else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // Decode GitHub Release
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(GitHubRelease.self, from: data)
            
            await MainActor.run {
                self.checkingForUpdate = false
                
                // Version Comparison (Simple String Check)
                // Normalize versions (remove 'v' prefix, etc)
                let remoteVer = release.tagName.replacingOccurrences(of: "v", with: "")
                let localVer = self.currentVersion.replacingOccurrences(of: "V", with: "").components(separatedBy: "(").first ?? ""
                
                // If remote string is different/newer (naïve check, should use proper semver if available)
                // For now, if they don't match, we assume update.
                // Ideally we'd compare Major.Minor.Patch integers.
                
                if remoteVer != localVer && !release.tagName.isEmpty {
                    self.latestRelease = UpdateRelease(
                        tagName: release.tagName,
                        body: release.body ?? "No release notes.",
                        htmlUrl: release.htmlUrl
                    )
                    self.isUpdateAvailable = true
                } else {
                    self.isUpdateAvailable = false
                    if manual {
                        self.showUpToDate = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            self.showUpToDate = false
                        }
                    }
                }
            }
        } catch {
            print("Update check failed: \(error)")
            await MainActor.run {
                self.checkingForUpdate = false
                if manual {
                    self.errorMessage = "Check Failed"
                }
            }
        }
    }
    
    func checkForUpdates() async {
        await checkForUpdates(manual: false)
    }
}

// GitHub API Models
struct GitHubRelease: Codable {
    let tagName: String
    let body: String?
    let htmlUrl: String
}

struct UpdateRelease {
    let tagName: String
    let body: String
    let htmlUrl: String
}
