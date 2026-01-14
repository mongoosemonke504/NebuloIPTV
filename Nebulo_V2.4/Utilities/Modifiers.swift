import SwiftUI

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.5), location: 0.35),
                            .init(color: .white.opacity(1.0), location: 0.5),
                            .init(color: .white.opacity(0.5), location: 0.65),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: -geo.size.width * 2 + (geo.size.width * 3 * phase))
                    .onAppear {
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: true)) {
                            phase = 1
                        }
                    }
                }
            )
            .mask(content)
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

struct SkeletonBox: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = 8
    
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(0.15))
            .frame(width: width, height: height)
            .shimmer()
    }
}

struct BlurFadeModifier: ViewModifier {
    let blurRadius: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content
            .blur(radius: blurRadius)
            .opacity(opacity)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(
            active: BlurFadeModifier(blurRadius: 20, opacity: 0),
            identity: BlurFadeModifier(blurRadius: 0, opacity: 1)
        )
    }
}

struct GlassEffect: ViewModifier {
    @AppStorage("glassOpacity") private var glassOpacity = 0.15
    @AppStorage("glassShade") private var glassShade = 1.0
    let cornerRadius: CGFloat
    let isSelected: Bool
    let accentColor: Color?
    func body(content: Content) -> some View {
        content
            .background(isSelected ? AnyShapeStyle(Color(white: glassShade).opacity(glassOpacity + 0.1)) : AnyShapeStyle(Color(white: glassShade).opacity(glassOpacity)))
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isSelected && accentColor != nil ? accentColor!.opacity(0.8) : Color.white.opacity(0.1), lineWidth: isSelected ? 1.5 : 1)
            )
            .compositingGroup()
    }
}