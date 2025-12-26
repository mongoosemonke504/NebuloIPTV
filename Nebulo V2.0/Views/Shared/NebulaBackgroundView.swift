import SwiftUI

struct NebulaBackgroundView: View {
    let color1, color2, color3: Color; let point1, point2, point3: UnitPoint
    func adjustedPoint(_ p: UnitPoint, isLandscape: Bool) -> UnitPoint { guard isLandscape else { return p }; return UnitPoint(x: p.y, y: 1.0 - p.x) }
    func drawNebula(context: GraphicsContext, size: CGSize, time: Double, isLandscape: Bool) {
        let phase = sin(time * 0.5); context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        let blur = min(size.width, size.height) * 0.45; var ctx = context; ctx.blendMode = .screen
        let p1 = adjustedPoint(point1, isLandscape: isLandscape); let c1 = CGPoint(x: p1.x * size.width, y: p1.y * size.height)
        var ctx1 = ctx; ctx1.addFilter(.blur(radius: blur)); let r1 = size.width + (CGFloat(phase) * 20)
        ctx1.fill(Path(ellipseIn: CGRect(x: c1.x - size.width/2, y: c1.y - size.width/2, width: r1, height: r1)), with: .color(color1))
        let p2 = adjustedPoint(point2, isLandscape: isLandscape); let c2 = CGPoint(x: p2.x * size.width, y: p2.y * size.height)
        var ctx2 = ctx; ctx2.addFilter(.blur(radius: blur)); let r2 = size.width * 1.2
        ctx2.fill(Path(ellipseIn: CGRect(x: c2.x - size.width/2, y: c2.y - size.width/2, width: r2, height: r2)), with: .color(color2))
        let p3 = adjustedPoint(point3, isLandscape: isLandscape); let c3 = CGPoint(x: p3.x * size.width, y: p3.y * size.height)
        var ctx3 = ctx; ctx3.addFilter(.blur(radius: blur)); let r3 = size.width * 0.9
        ctx3.fill(Path(ellipseIn: CGRect(x: c3.x - size.width/2, y: c3.y - size.width/2, width: r3, height: r3)), with: .color(color3))
    }
    var body: some View { GeometryReader { geo in let isL = geo.size.width > geo.size.height; TimelineView(.periodic(from: .now, by: 1.0/30.0)) { tl in Canvas { c, s in drawNebula(context: c, size: s, time: tl.date.timeIntervalSinceReferenceDate, isLandscape: isL) } } }.ignoresSafeArea() }
}
