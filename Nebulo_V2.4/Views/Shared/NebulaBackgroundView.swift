import SwiftUI

/// Full-screen background that is either:
///   • A static custom image the user picked (loaded off the main thread)
///   • A static one-shot nebula gradient painted with Canvas (no TimelineView,
///     no periodic redraws — just a single GPU-rasterised frame)
///
/// Removing the TimelineView was the key change: the old `.periodic(by: 1/fps)`
/// schedule fired every second and forced the entire Canvas to repaint, which
/// added CPU/GPU pressure during home-screen scrolling.
struct NebulaBackgroundView: View {
    let color1, color2, color3: Color
    let point1, point2, point3: UnitPoint

    @AppStorage("useCustomBackground")     private var useCustomBackground     = false
    @AppStorage("customBackgroundBlur")    private var customBackgroundBlur    = 0.0
    @AppStorage("customBackgroundVersion") private var customBackgroundVersion = 0

    @State private var customImage: UIImage? = nil

    var body: some View {
        Group {
            if useCustomBackground, let img = customImage {
                // GeometryReader pins the image to exactly the available frame so
                // scaledToFill never expands the layout size beyond the screen,
                // which was causing the ZStack beneath it to zoom/stretch.
                GeometryReader { geo in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: customBackgroundBlur)
                        .overlay(Color.black.opacity(0.2))
                }
            } else if useCustomBackground {
                // Image chosen but not loaded yet — solid black avoids a flash.
                Color.black
            } else {
                // Nebula gradient — painted once, never redrawn unless props change.
                Canvas { ctx, size in
                    drawNebula(context: ctx, size: size)
                }
            }
        }
        .ignoresSafeArea()
        // Load / reload the image off the main thread whenever the user
        // toggles the setting or saves a new image.
        .task(id: useCustomBackground) {
            guard useCustomBackground else { customImage = nil; return }
            customImage = await loadImageAsync()
        }
        .task(id: customBackgroundVersion) {
            guard useCustomBackground else { return }
            customImage = await loadImageAsync()
        }
    }

    // MARK: - Nebula draw (static — called once by Canvas)

    private func drawNebula(context: GraphicsContext, size: CGSize) {
        let minDim  = min(size.width, size.height)
        let blur    = minDim * 0.45
        var ctx     = context
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        ctx.blendMode = .screen

        func blob(_ point: UnitPoint, _ color: Color, _ scale: CGFloat) {
            var c = ctx
            c.addFilter(.blur(radius: blur))
            let cx = point.x * size.width
            let cy = point.y * size.height
            let r  = minDim * scale
            c.fill(Path(ellipseIn: CGRect(x: cx - r/2, y: cy - r/2, width: r, height: r)),
                   with: .color(color))
        }

        blob(point1, color1, 1.2)
        blob(point2, color2, 1.4)
        blob(point3, color3, 1.1)
    }

    // MARK: - Async image loader (disk read off the main thread)

    private func loadImageAsync() async -> UIImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard
                    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                else { continuation.resume(returning: nil); return }
                let url = dir.appendingPathComponent("custom_background.jpg")
                guard let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: UIImage(data: data))
            }
        }
    }
}
