import SwiftUI
import Combine

enum AppIcon: String, CaseIterable, Identifiable {
    case primary = "AppIcon"
    case nebula = "NebulaIcon"
    case dark = "DarkIcon"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .primary: return "Default"
        case .nebula: return "Nebula"
        case .dark: return "Midnight"
        }
    }
    
    var previewImage: String {
        switch self {
        case .primary: return "appicon_preview_default"
        case .nebula: return "appicon_preview_nebula"
        case .dark: return "appicon_preview_dark"
        }
    }
}

class AppIconManager: ObservableObject {
    static let shared = AppIconManager()
    
    @Published var currentIcon: AppIcon = .primary
    
    init() {
        if let iconName = UIApplication.shared.alternateIconName {
            currentIcon = AppIcon(rawValue: iconName) ?? .primary
        } else {
            currentIcon = .primary
        }
    }
    
    func changeIcon(to icon: AppIcon) {
        let iconName = icon == .primary ? nil : icon.rawValue
        
        guard UIApplication.shared.alternateIconName != iconName else { return }
        
        UIApplication.shared.setAlternateIconName(iconName) { error in
            if let error = error {
                print("Error setting alternate icon: \(error.localizedDescription)")
            } else {
                DispatchQueue.main.async {
                    self.currentIcon = icon
                }
            }
        }
    }
}