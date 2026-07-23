import SwiftUI
import UIKit

/// Shared "brand colour" extraction for channel logos, used by every card that
/// shows a coloured glow behind a channel (featured hero, home shelves, the
/// category rows). Keeping it in one place means the glow is derived from the
/// logo everywhere, rather than some surfaces falling back to the accent colour.
enum LogoGlow {
    /// Process-wide cache keyed by logo URL, so a logo's colour is sampled once.
    static var cache: [String: Color] = [:]

    /// Resolves the glow colour for a logo. Returns the cached value instantly,
    /// otherwise waits (briefly) for the logo to land in the image cache and
    /// samples it. Returns nil when there's no logo or it never decodes.
    @MainActor
    static func color(for icon: String?) async -> Color? {
        guard let icon, !icon.isEmpty else { return nil }
        if let cached = cache[icon] { return cached }
        for _ in 0..<12 {
            if let ui = ImageCache.shared.get(forKey: icon, size: CGSize(width: 160, height: 160)),
               let extracted = ui.brandGlowColor() {
                let c = Color(extracted)
                cache[icon] = c
                return c
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }
}

extension UIImage {
    /// The logo's "brand colour": the average of its saturated opaque pixels
    /// (falling back to all opaque pixels for monochrome logos), brightened so
    /// it reads as a glow on a dark card. Samples a 16×16 downscale, so the
    /// cost is negligible.
    func brandGlowColor() -> UIColor? {
        guard let cg = cgImage else { return nil }
        let w = 16, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        var satR = 0.0, satG = 0.0, satB = 0.0, satN = 0.0
        var allR = 0.0, allG = 0.0, allB = 0.0, allN = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }
            let r = Double(pixels[i]) / 255 / a
            let g = Double(pixels[i + 1]) / 255 / a
            let b = Double(pixels[i + 2]) / 255 / a
            allR += r; allG += g; allB += b; allN += 1
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            if sat > 0.3 && mx > 0.15 {
                satR += r; satG += g; satB += b; satN += 1
            }
        }
        guard allN > 0 else { return nil }
        let useSat = satN >= max(4, allN * 0.05)
        var r = useSat ? satR / satN : allR / allN
        var g = useSat ? satG / satN : allG / allN
        var b = useSat ? satB / satN : allB / allN
        // Brighten dark brand colours so the glow stays visible on the card.
        let mx = max(r, g, b)
        if mx > 0, mx < 0.55 { let k = 0.55 / mx; r *= k; g *= k; b *= k }
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}
