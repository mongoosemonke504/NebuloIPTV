import SwiftUI

@main
struct IPTVPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("appTheme") private var appTheme = AppTheme.system.rawValue
    var selectedScheme: ColorScheme? { switch AppTheme(rawValue: appTheme) ?? .system { case .light: return .light; case .dark: return .dark; case .system: return nil } }
    var body: some Scene { WindowGroup { ContentView().preferredColorScheme(selectedScheme) } }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Background fetch is deprecated in favor of BGTaskScheduler.
        return true
    }
}
