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

    static let snapshotDefaults: [String: Any] = [
        "customAccentHex": "#FFFFFF",
        "nebColor1": "#1A2538", "nebColor2": "#11101A", "nebColor3": "#1F1A24",
        "nebX1": 0.5, "nebY1": 0.0, "nebX2": 0.5, "nebY2": 0.5, "nebX3": 0.5, "nebY3": 1.0,
        "useCustomBackground": false, "customBackgroundBlur": 0.0,
        "glassOpacity": 0.15, "glassShade": 1.0, "featuredGlowStrength": 0.5,
        "autoBuffer": true, "bufferTime": 10.0, "defaultPlayerEngine": "VLC",
        "viewMode": "automatic", "showSupportPopup": true,
    ]

    static var snapshotKeys: [String] { Array(snapshotDefaults.keys).sorted() }

    private static let shippedJSON = """
    {"autoBuffer":true,"bufferTime":10,"customAccentHex":"#FFFFFF","customBackgroundBlur":0,"defaultPlayerEngine":"VLC","featuredGlowStrength":0.5,"glassOpacity":0.15,"glassShade":1,"nebColor1":"#1A2538","nebColor2":"#11101A","nebColor3":"#1F1A24","nebX1":0.5,"nebX2":0.5,"nebX3":0.5,"nebY1":0,"nebY2":0.5,"nebY3":1,"showSupportPopup":true,"useCustomBackground":false,"viewMode":"automatic"}
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
