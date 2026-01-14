import SwiftUI

struct CustomSpinner: View {
    @State private var isAnimating = false
    var color: Color = .white
    var lineWidth: CGFloat = 4
    var size: CGFloat = 40
    
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(
                AngularGradient(gradient: Gradient(colors: [color.opacity(0), color]), center: .center),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(Angle(degrees: isAnimating ? 360 : 0))
            .onAppear {
                withAnimation(Animation.linear(duration: 1).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
    }
}
