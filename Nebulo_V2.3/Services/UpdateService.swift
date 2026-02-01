import Foundation
import Combine

class UpdateService: ObservableObject {
    static let shared = UpdateService()
    
    @Published var isUpdating: Bool = false
    @Published var updateProgress: Double = 0.0
    
    @Published var currentVersion: String = "2.3"
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
        
        
        guard let url = URL(string: "https://api.github.com/repos/mongoosemonke504/NebuloIPTV/releases/latest") else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(GitHubRelease.self, from: data)
            
            await MainActor.run {
                self.checkingForUpdate = false
                
                
                
                let remoteVer = release.tagName.replacingOccurrences(of: "v", with: "").replacingOccurrences(of: "V", with: "")
                let localVer = self.currentVersion.replacingOccurrences(of: "v", with: "").replacingOccurrences(of: "V", with: "").components(separatedBy: "(").first ?? ""
                
                if self.isNewer(remote: remoteVer, local: localVer) && !release.tagName.isEmpty {
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
    
    func isNewer(remote: String, local: String) -> Bool {
        let rComponents = remote.split(separator: ".").compactMap { Int($0) }
        let lComponents = local.split(separator: ".").compactMap { Int($0) }
        
        for i in 0..<max(rComponents.count, lComponents.count) {
            let r = i < rComponents.count ? rComponents[i] : 0
            let l = i < lComponents.count ? lComponents[i] : 0
            if r != l { return r > l }
        }
        return false
    }
    
    func checkForUpdates() async {
        await checkForUpdates(manual: false)
    }
}

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
