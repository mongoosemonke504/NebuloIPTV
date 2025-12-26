import SwiftUI

// MARK: - SHIMMER EFFECT (SKELETON LOADING)
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.8), location: 0.5),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: -geo.size.width + (geo.size.width * 2 * phase))
                    .onAppear {
                        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
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
            .fill(Color.white.opacity(0.04))
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
    let cornerRadius: CGFloat
    let isSelected: Bool
    let accentColor: Color?
    func body(content: Content) -> some View {
        content
            .background(isSelected ? AnyShapeStyle(Material.ultraThinMaterial) : AnyShapeStyle(Material.thinMaterial.opacity(0.2)))
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isSelected && accentColor != nil ? accentColor!.opacity(0.8) : Color.white.opacity(0.1), lineWidth: isSelected ? 1.5 : 0.5)
            )
            .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
            .compositingGroup()
    }
}
