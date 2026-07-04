import SwiftUI
import UIKit
import Combine

/// Describes a selectable home-screen icon for the app.
///
/// `assetName` is `nil` for the primary icon (iOS expects `nil` to mean "use the
/// default icon"). For alternates, `assetName` must match a key under
/// `CFBundleIcons → CFBundleAlternateIcons` in Info.plist *and* a top-level PNG
/// asset (or `.appiconset` entry) bundled with the app — otherwise
/// `setAlternateIconName(_:)` will silently fail.
struct AppIconOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let assetName: String?
    let previewImageName: String  // shown in the picker grid; falls back to SF Symbol if missing

    static let primary = AppIconOption(
        id: "primary",
        displayName: "Default",
        assetName: nil,
        previewImageName: "AppIcon-Preview"
    )

    /// All known options. Adding a new alternate icon = add an entry here, drop
    /// PNGs (`<name>@2x.png`, `<name>@3x.png`) into the bundle, and add the
    /// matching key to Info.plist's `CFBundleAlternateIcons`.
    static let all: [AppIconOption] = [
        .primary,
        AppIconOption(id: "midnight", displayName: "Midnight", assetName: "AppIcon-Midnight", previewImageName: "AppIcon-Midnight-Preview"),
        AppIconOption(id: "sunset", displayName: "Sunset", assetName: "AppIcon-Sunset", previewImageName: "AppIcon-Sunset-Preview"),
        AppIconOption(id: "mono", displayName: "Mono", assetName: "AppIcon-Mono", previewImageName: "AppIcon-Mono-Preview"),
    ]
}

@MainActor
final class AppIconManager: ObservableObject {
    static let shared = AppIconManager()

    @Published private(set) var currentIconID: String

    private init() {
        let active = UIApplication.shared.alternateIconName
        self.currentIconID = AppIconOption.all.first { $0.assetName == active }?.id ?? AppIconOption.primary.id
    }

    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    func setIcon(_ option: AppIconOption) async -> Bool {
        guard supportsAlternateIcons else { return false }
        // No-op if already current.
        if option.assetName == UIApplication.shared.alternateIconName {
            currentIconID = option.id
            return true
        }
        do {
            try await UIApplication.shared.setAlternateIconName(option.assetName)
            currentIconID = option.id
            return true
        } catch {
            // Common cause: the asset isn't bundled. We surface a console hint
            // so it's obvious during development without crashing.
            print("[AppIconManager] setAlternateIconName(\(option.assetName ?? "nil")) failed: \(error)")
            return false
        }
    }
}

struct AppIconPickerView: View {
    @StateObject private var manager = AppIconManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var failureMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(AppIconOption.all) { option in
                            iconTile(option)
                        }
                    }
                    .padding(20)

                    if !manager.supportsAlternateIcons {
                        Text("This device doesn't support alternate app icons.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                    } else if let failureMessage {
                        Text(failureMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
            }
            .navigationTitle("App Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    @ViewBuilder
    private func iconTile(_ option: AppIconOption) -> some View {
        let isSelected = option.id == manager.currentIconID

        Button {
            ChannelViewModel.shared.triggerSelectionHaptic()
            Task {
                let ok = await manager.setIcon(option)
                if !ok && manager.supportsAlternateIcons {
                    failureMessage = "Couldn't switch to \(option.displayName). The icon asset may not be bundled in this build."
                }
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                    iconImage(for: option)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .frame(width: 88, height: 88)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isSelected ? Color.white : Color.white.opacity(0.12),
                                lineWidth: isSelected ? 2.5 : 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)

                Text(option.displayName)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Try the bundled preview asset; if it isn't present (alternates aren't
    /// bundled yet), fall back to a glyph so the UI still reads cleanly.
    private func iconImage(for option: AppIconOption) -> Image {
        if UIImage(named: option.previewImageName) != nil {
            return Image(option.previewImageName)
        }
        if option.id == AppIconOption.primary.id,
           let primary = UIImage(named: "Gemini_Generated_Image_ki04ggki04ggki04-2") {
            return Image(uiImage: primary)
        }
        return Image(systemName: "app.fill")
    }
}
