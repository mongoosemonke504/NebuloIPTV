import SwiftUI

@main
struct IPTVPlayerApp: App {
    @AppStorage("appTheme") private var appTheme = AppTheme.system.rawValue
    var selectedScheme: ColorScheme? { switch AppTheme(rawValue: appTheme) ?? .system { case .light: return .light; case .dark: return .dark; case .system: return nil } }
    var body: some Scene { WindowGroup { ContentView().preferredColorScheme(selectedScheme) } }
}
