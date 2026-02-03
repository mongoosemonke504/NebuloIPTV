import SwiftUI

struct NebulaBackgroundView: View {
    let color1, color2, color3: Color; let point1, point2, point3: UnitPoint
    var targetFPS: Double = 1.0
    
    @AppStorage("useCustomBackground") private var useCustomBackground = false
    @AppStorage("customBackgroundBlur") private var customBackgroundBlur = 0.0
    @AppStorage("customBackgroundVersion") private var customBackgroundVersion = 0
    @State private var customImage: UIImage? = nil
    
    
    func drawNebula(context: GraphicsContext, size: CGSize, time: Double) {
        let phase = sin(time * 0.5); context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        let minDim = min(size.width, size.height)
        let blur = minDim * 0.45; var ctx = context; ctx.blendMode = .screen
        
        
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
    
    var body: some View { 
        GeometryReader { geo in 
            if useCustomBackground, let img = customImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: customBackgroundBlur)
                    .overlay(Color.black.opacity(0.2)) 
            } else {
                TimelineView(.periodic(from: .now, by: targetFPS > 0 ? 1.0/targetFPS : 1.0)) { tl in 
                    Canvas { c, s in 
                        drawNebula(context: c, size: s, time: tl.date.timeIntervalSinceReferenceDate) 
                    } 
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { loadCustomImage() }
        .onChange(of: useCustomBackground) { _ in loadCustomImage() }
        .onChange(of: customBackgroundVersion) { _ in loadCustomImage() }
    }
    
    private func loadCustomImage() {
        if useCustomBackground {
            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let fileURL = dir.appendingPathComponent("custom_background.jpg")
                if let data = try? Data(contentsOf: fileURL), let uiImage = UIImage(data: data) {
                    self.customImage = uiImage
                }
            }
        }
    }
}
