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

    /// What a logo's artwork actually reads as: the mean of its opaque
    /// pixels, un-brightened, and that colour's luminance.
    struct LogoMean {
        let r: Double, g: Double, b: Double
        let lum: Double
    }
    /// Per logo URL, filled in alongside the glow.
    static var meanCache: [String: LogoMean] = [:]

    /// Resolves the glow colour for a logo. Returns the cached value instantly,
    /// otherwise waits (briefly) for the logo to land in the image cache and
    /// samples it. Returns nil when there's no logo or it never decodes.
    @MainActor
    static func color(for icon: String?) async -> Color? {
        guard let icon, !icon.isEmpty else { return nil }
        if let cached = cache[icon] { return cached }
        // Two cards showing the same logo shouldn't each decode it.
        if let running = inFlight[icon] { return await running.value }

        let work = Task<Color?, Never> { @MainActor in
            defer { inFlight[icon] = nil }
            for _ in 0..<12 {
                // The decode and both pixel passes run OFF the main thread.
                //
                // This function is @MainActor and used to call the cache's
                // synchronous accessor, whose own documentation reserves it for
                // one-shot callers because its disk path decodes on the calling
                // thread. It is called from a `.task` on every channel card, so
                // every card scrolling into view ran a file read, a full
                // downsample, a 64x64 border-trim scan and a 16x16 brand scan
                // on the main thread — and retried all of it up to twelve times
                // for a logo that had not arrived yet. That is the hitch on
                // every scroll; the colours it produces are identical either
                // way, so nothing here changes but where the work happens.
                let boxed = await Task.detached(priority: .utility) { () -> SampleBox in
                    guard let ui = ImageCache.decodeFromDisk(
                        urlString: icon,
                        size: CGSize(width: 160, height: 160)
                    ) else { return SampleBox(sample: nil) }
                    return SampleBox(sample: ui.brandSample())
                }.value

                if let sample = boxed.sample {
                    let c = Color(sample.glow)
                    cache[icon] = c
                    toneCache[icon] = Color(sample.tone)
                    if sample.isLightTone { lightToneIcons.insert(icon) }
                    meanCache[icon] = LogoMean(r: sample.mean.r, g: sample.mean.g, b: sample.mean.b,
                                               lum: sample.meanLuminance)
                    return c
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return nil
        }
        inFlight[icon] = work
        return await work.value
    }

    /// Samples in progress, keyed by logo URL.
    @MainActor private static var inFlight: [String: Task<Color?, Never>] = [:]

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

    // MARK: Crests on a field of their own colour

    /// The logo's mean colour, or nil until it has been sampled.
    static func mean(for icon: String?) -> LogoMean? {
        guard let icon, !icon.isEmpty else { return nil }
        return meanCache[icon]
    }

    /// "#RRGGBB" or "RRGGBB" — the form ESPN's team colours arrive in.
    nonisolated static func rgb(hex: String?) -> (r: Double, g: Double, b: Double)? {
        guard let raw = hex?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")),
              raw.count == 6 else { return nil }
        var v: UInt64 = 0
        guard Scanner(string: raw).scanHexInt64(&v) else { return nil }
        return (Double((v & 0xFF0000) >> 16) / 255,
                Double((v & 0x00FF00) >> 8) / 255,
                Double(v & 0x0000FF) / 255)
    }

    nonisolated static func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    /// True when a logo drawn on a field of this colour would be lost in it.
    ///
    /// Some clubs' marks are one flat colour, and that colour is the club's
    /// brand colour — the one every tile, wash and split behind the crest is
    /// painted with. A black crest on a black tile, a red one on red: the
    /// artwork is there and cannot be seen. A mark of several colours averages
    /// to something the field is not, so this only fires for the marks that
    /// really do disappear: close in brightness AND close in colour. A pure
    /// red crest on a navy field is as dark as the field and still reads by
    /// hue, so brightness alone is not the test.
    ///
    /// False until the logo has been sampled, or when there is no field
    /// colour to lose it against.
    static func blends(logo: String?, on hex: String?) -> Bool {
        guard let mean = mean(for: logo), let field = rgb(hex: hex) else { return false }
        return blends(mean, on: field)
    }

    nonisolated static func blends(_ mean: LogoMean, on field: (r: Double, g: Double, b: Double)) -> Bool {
        let dr = mean.r - field.r, dg = mean.g - field.g, db = mean.b - field.b
        let distance = (dr * dr + dg * dg + db * db).squareRoot()
        return abs(mean.lum - luminance(field)) < 0.16 && distance < 0.38
    }

    /// The tile behind a club crest: nil for the brand colour, or — when the
    /// crest would vanish on it — the tile the channel cards give the same
    /// artwork, which is chosen for contrast against it (light for a dark
    /// mark, charcoal for a white one, a deep slab of its hue otherwise).
    static func crestTile(logo: String?, brand hex: String?) -> Color? {
        guard blends(logo: logo, on: hex) else { return nil }
        return tone(for: logo)
    }

    /// Whether a field colour is dark enough that a light backplate is what
    /// lifts a crest off it (rather than a dark one).
    nonisolated static func isDark(hex: String?) -> Bool {
        guard let field = rgb(hex: hex) else { return true }
        return luminance(field) < 0.5
    }

    /// Samples a crest if it hasn't been yet, so `blends`/`crestTile` can
    /// answer. Waits for the artwork to land in the image cache the way the
    /// glow does; nothing to do once the answer is known.
    static func sampleIfNeeded(_ icon: String?) async {
        guard let icon, !icon.isEmpty, meanCache[icon] == nil else { return }
        _ = await color(for: icon)
    }
}

/// What one pass over a logo yields: the bright colour used for glows and
/// halos, and the solid colour its cards are filled with.
/// Carries a sample back from the detached decode. Safe because the colours
/// are created there and never touched again on that side.
private struct SampleBox: @unchecked Sendable { let sample: BrandSample? }

/// Nonisolated so it can be built on the sampling thread — see
/// `brandSample()`, which runs off the main actor.
nonisolated struct BrandSample {
    let glow: UIColor
    let tone: UIColor
    /// The tone came out pale, because the logo is dark.
    let isLightTone: Bool
    /// The raw mean of the opaque pixels, before the glow is brightened —
    /// what the artwork reads as, for `LogoGlow.blends`.
    let mean: (r: Double, g: Double, b: Double)
    let meanLuminance: Double
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
    nonisolated func brandSample() -> BrandSample? {
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
        let mean = (r: allR / allN, g: allG / allN, b: allB / allN)
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
                           isLightTone: isLightTone,
                           mean: mean,
                           meanLuminance: lum)
    }
}

private extension UIColor {
    /// Nonisolated for the same reason as `brandSample()` — it is read on the
    /// sampling thread, and inheriting main-actor isolation would drag the
    /// whole calculation back onto the main thread.
    nonisolated var hueComponent: CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return h
    }
}
