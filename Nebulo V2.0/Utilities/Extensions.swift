import SwiftUI

// MARK: - EXTENSIONS & LOGIC
extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6 else { return nil }
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        self.init(red: Double((rgb & 0xFF0000) >> 16)/255.0, green: Double((rgb & 0x00FF00) >> 8)/255.0, blue: Double(rgb & 0x0000FF)/255.0)
    }
    func toHex() -> String? {
        guard let c = UIColor(self).cgColor.components, c.count >= 3 else { return nil }
        return String(format: "#%02lX%02lX%02lX", lroundf(Float(c[0])*255), lroundf(Float(c[1])*255), lroundf(Float(c[2])*255))
    }
}
extension KeyedDecodingContainer {
    func decodeFlexibleID(forKey key: K) throws -> Int {
        if let intValue = try? decode(Int.self, forKey: key) { return intValue }
        if let stringValue = try? decode(String.self, forKey: key) {
            return Int(stringValue) ?? 0
        }
        return 0
    }
}
