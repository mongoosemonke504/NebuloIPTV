import SwiftUI

struct GlassEffect: ViewModifier {
    var cornerRadius: CGFloat
    var isSelected: Bool
    var accentColor: Color?
    
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    if isSelected {
                        (accentColor ?? .blue).opacity(0.8)
                    } else {
                        Color.white.opacity(0.1)
                    }
                }
            )
            .cornerRadius(cornerRadius)
            .shadow(color: .black.opacity(isSelected ? 0.4 : 0.2), radius: isSelected ? 8 : 4, x: 0, y: isSelected ? 4 : 2)
    }
}
