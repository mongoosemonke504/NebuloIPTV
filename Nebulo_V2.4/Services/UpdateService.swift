import Foundation
import Combine

class UpdateService: ObservableObject {
    static let shared = UpdateService()
    
    @Published var isUpdating: Bool = false
    @Published var updateProgress: Double = 0.0
    
    @Published var currentVersion: String = "V2.2(13)"
    @Published var checkingForUpdate: Bool = false
    @Published var isUpdateAvailable: Bool = false
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
            errorMessage = nil
        }
        
        // Simulate network delay
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        
        await MainActor.run {
            // For now, we are always on the latest version after this update
            isUpdateAvailable = false
            latestRelease = nil
            checkingForUpdate = false
            
            if manual {
                // If manual check, we can show a "No updates found" message or similar via a temporary state if needed
                // but the UI handles the absence of isUpdateAvailable nicely.
            }
        }
    }
    
    func checkForUpdates() async {
        await checkForUpdates(manual: false)
    }
}

struct UpdateRelease {
    let tagName: String
    let body: String
    let htmlUrl: String
}
