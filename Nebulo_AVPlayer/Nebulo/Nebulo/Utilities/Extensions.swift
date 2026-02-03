import SwiftUI

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

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            self.onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
    
    func swipeBack(onTrigger: @escaping () -> Void) -> some View {
        self.gesture(
            DragGesture()
                .onEnded { value in
                    let minDragTranslation: CGFloat = 100
                    let minStartingX: CGFloat = 50 
                    
                    if value.startLocation.x < minStartingX && value.translation.width > minDragTranslation {
                        onTrigger()
                    }
                }
        )
    }
    
    @ViewBuilder
    func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

import UIKit

struct NavigationPopGestureHandler: UIViewControllerRepresentable {
    var isEnabled: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        
        return UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        
        uiViewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = isEnabled
    }
}

extension View {
    
    
    
    func interactivePopGesture(isEnabled: Bool) -> some View {
        self.background(NavigationPopGestureHandler(isEnabled: isEnabled))
    }
}
