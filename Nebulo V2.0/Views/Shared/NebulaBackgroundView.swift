import SwiftUI

struct NebulaBackgroundView: View {
    let color1, color2, color3: Color; let point1, point2, point3: UnitPoint
    // Removed adjustedPoint to ensure consistent mapping relative to screen edges
    func drawNebula(context: GraphicsContext, size: CGSize, time: Double) {
        let phase = sin(time * 0.5); context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        let minDim = min(size.width, size.height)
        let blur = minDim * 0.45; var ctx = context; ctx.blendMode = .screen
        
        // Use minDim for radius to keep blob size consistent and prevent washout in landscape
        let p1 = point1; let c1 = CGPoint(x: p1.x * size.width, y: p1.y * size.height)
        var ctx1 = ctx; ctx1.addFilter(.blur(radius: blur)); let r1 = minDim * 1.2 + (CGFloat(phase) * 20)
        ctx1.fill(Path(ellipseIn: CGRect(x: c1.x - r1/2, y: c1.y - r1/2, width: r1, height: r1)), with: .color(color1))
        
        let p2 = point2; let c2 = CGPoint(x: p2.x * size.width, y: p2.y * size.height)
        var ctx2 = ctx; ctx2.addFilter(.blur(radius: blur)); let r2 = minDim * 1.4
        ctx2.fill(Path(ellipseIn: CGRect(x: c2.x - r2/2, y: c2.y - r2/2, width: r2, height: r2)), with: .color(color2))
        
        let p3 = point3; let c3 = CGPoint(x: p3.x * size.width, y: p3.y * size.height)
        var ctx3 = ctx; ctx3.addFilter(.blur(radius: blur)); let r3 = minDim * 1.1
        ctx3.fill(Path(ellipseIn: CGRect(x: c3.x - r3/2, y: c3.y - r3/2, width: r3, height: r3)), with: .color(color3))
    }
    var body: some View { GeometryReader { geo in TimelineView(.periodic(from: .now, by: 1.0/30.0)) { tl in Canvas { c, s in drawNebula(context: c, size: s, time: tl.date.timeIntervalSinceReferenceDate) } } }.ignoresSafeArea() }
}
