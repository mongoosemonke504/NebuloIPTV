import Foundation

/// First-launch defaults.
///
/// `UserDefaults.register(defaults:)` only supplies values for keys that
/// have never been written, so baking values into `shippedJSON` changes what
/// a FRESH install starts with while leaving every existing install
/// untouched.
///
/// To capture the current device's configuration as the shipped defaults:
/// Settings → Support → "Copy Settings Snapshot", then paste the copied JSON
/// between the triple quotes of `shippedJSON` below.
enum AppDefaults {

    // The nebula-palette, custom-photo and glass-tuning keys were dropped
    // with the redesign — the canvas is pure black and the chrome's glass is
    // the system's, so none of them had a setting or a reader left.
    static let snapshotDefaults: [String: Any] = [
        "customAccentHex": "#FFFFFF",
        "featuredGlowStrength": 0.5,
        "autoBuffer": true, "bufferTime": 10.0,
        "showSupportPopup": true,
    ]

    static var snapshotKeys: [String] { Array(snapshotDefaults.keys).sorted() }

    private static let shippedJSON = """
    {"autoBuffer":true,"bufferTime":10,"customAccentHex":"#FFFFFF","featuredGlowStrength":0.5,"showSupportPopup":true}
    """

    static func register() {
        guard let data = shippedJSON.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              !dict.isEmpty else { return }
        UserDefaults.standard.register(defaults: dict)
    }

    static func snapshotJSON() -> String {
        var dict: [String: Any] = snapshotDefaults
        for key in snapshotDefaults.keys {
            if let value = UserDefaults.standard.object(forKey: key) {
                dict[key] = value
            }
        }
        guard let data = try? JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
