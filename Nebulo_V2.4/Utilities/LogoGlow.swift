import SwiftUI
import UIKit

/// Shared "brand colour" extraction for channel logos, used by every card that
/// shows a coloured glow behind a channel (featured hero, home shelves, the
/// category rows). Keeping it in one place means the glow is derived from the
/// logo everywhere, rather than some surfaces falling back to the accent colour.
enum LogoGlow {
    /// Process-wide cache keyed by logo URL, so a logo's colour is sampled once.
    static var cache: [String: Color] = [:]

    /// The SOLID card background for the same logo, filled in alongside the
    /// glow. Channel tiles are flat slabs of this rather than a gradient over a
    /// blurred copy of the logo — see `BrandSample.tone`.
    static var toneCache: [String: Color] = [:]

    /// Logos whose tone came out LIGHT (because the logo itself is dark). The
    /// hero uses this to darken the bottom of its backdrop so the white title
    /// still reads over a pale field.
    static var lightToneIcons: Set<String> = []

    /// Resolves the glow colour for a logo. Returns the cached value instantly,
    /// otherwise waits (briefly) for the logo to land in the image cache and
    /// samples it. Returns nil when there's no logo or it never decodes.
    @MainActor
    static func color(for icon: String?) async -> Color? {
        guard let icon, !icon.isEmpty else { return nil }
        if let cached = cache[icon] { return cached }
        for _ in 0..<12 {
            if let ui = ImageCache.shared.get(forKey: icon, size: CGSize(width: 160, height: 160)),
               let sample = ui.brandSample() {
                let c = Color(sample.glow)
                cache[icon] = c
                toneCache[icon] = Color(sample.tone)
                if sample.isLightTone { lightToneIcons.insert(icon) }
                return c
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    /// The channel's solid card colour, or nil until the logo has been sampled.
    /// Read on every render (never held in view state) so a recycled card can't
    /// paint the previous channel's colour.
    static func tone(for icon: String?) -> Color? {
        guard let icon, !icon.isEmpty else { return nil }
        return toneCache[icon]
    }

    /// True when this channel's tile is a pale one (its logo is dark).
    static func isLightTone(for icon: String?) -> Bool {
        guard let icon, !icon.isEmpty else { return false }
        return lightToneIcons.contains(icon)
    }
}

/// What one pass over a logo yields: the bright colour used for glows and
/// halos, and the solid colour its cards are filled with.
struct BrandSample {
    let glow: UIColor
    let tone: UIColor
    /// The tone came out pale, because the logo is dark.
    let isLightTone: Bool
}

extension UIImage {
    /// Samples a 16×16 downscale of the logo once and derives both colours from
    /// it, so the cost is negligible and the two can't disagree.
    ///
    /// The tone is chosen for CONTRAST against the logo that will sit on it,
    /// because a logo drawn on a slab of its own colour can vanish:
    ///
    ///   • A dark logo — a black wordmark, or a near-black navy — gets a LIGHT
    ///     tile carrying a wash of its hue. Nothing dark can be seen on a dark
    ///     slab, so this is the only way those channels read at all.
    ///   • A white or grey logo gets the dark charcoal tile.
    ///   • Everything else gets the deep tinted slab: the logo's hue held at a
    ///     fixed low brightness, which white and mid-tone artwork reads well
    ///     against.
    ///
    /// The dark/light decision uses "effective lightness" — luminance plus an
    /// allowance for saturation — because a saturated colour separates from its
    /// background by HUE as well as by brightness. A pure red logo (luminance
    /// 0.21) is perfectly legible on a deep red slab; a dark grey logo of the
    /// same luminance is not.
    func brandSample() -> BrandSample? {
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
        // Mean luminance of every opaque pixel — how light the logo ACTUALLY
        // reads, before any brightening.
        var lumSum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }
            let r = Double(pixels[i]) / 255 / a
            let g = Double(pixels[i + 1]) / 255 / a
            let b = Double(pixels[i + 2]) / 255 / a
            allR += r; allG += g; allB += b; allN += 1
            lumSum += 0.2126 * r + 0.7152 * g + 0.0722 * b
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

        // ── Tone, decided BEFORE the glow is brightened.
        let lum = lumSum / allN
        let mxBase = max(r, g, b), mnBase = min(r, g, b)
        let baseSat = mxBase == 0 ? 0 : (mxBase - mnBase) / mxBase
        let hue = UIColor(red: r, green: g, blue: b, alpha: 1).hueComponent
        // Saturation earns an allowance: hue contrast substitutes for
        // brightness contrast.
        let effectiveLightness = lum + 0.18 * baseSat
        let isLightTone = effectiveLightness < 0.32
        let tone: UIColor
        if isLightTone {
            // Dark logo — the tile has to be LIGHT or the artwork disappears.
            // A hueless black wordmark gets plain light grey; a dark coloured
            // one keeps a readable wash of its hue.
            tone = baseSat > 0.12
                ? UIColor(hue: hue, saturation: min(baseSat, 0.30), brightness: 0.86, alpha: 1)
                : UIColor(white: 0.86, alpha: 1)
        } else if baseSat <= 0.12 {
            // White or grey logo — charcoal, so it reads without inventing a hue.
            tone = UIColor(white: 0.13, alpha: 1)
        } else {
            tone = UIColor(hue: hue,
                           saturation: min(max(baseSat, 0.50), 0.85),
                           brightness: 0.32,
                           alpha: 1)
        }

        // Brighten dark brand colours so the GLOW stays visible on a dark card.
        let mx = max(r, g, b)
        if mx > 0, mx < 0.55 { let k = 0.55 / mx; r *= k; g *= k; b *= k }
        return BrandSample(glow: UIColor(red: r, green: g, blue: b, alpha: 1),
                           tone: tone,
                           isLightTone: isLightTone)
    }
}

private extension UIColor {
    var hueComponent: CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return h
    }
}
