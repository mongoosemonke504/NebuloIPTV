import SwiftUI

struct CustomSpinner: View {
    var color: Color = .white
    var lineWidth: CGFloat = 4
    var size: CGFloat = 40
    
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            
            Circle()
                .stroke(color.opacity(0.3), lineWidth: lineWidth)
            
            
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(Angle(degrees: isAnimating ? 360 : 0))
                .onAppear {
                    withAnimation(Animation.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                        isAnimating = true
                    }
                }
        }
        .frame(width: size, height: size)
    }
}
