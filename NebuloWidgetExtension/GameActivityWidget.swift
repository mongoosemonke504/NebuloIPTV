import WidgetKit
import SwiftUI
import ActivityKit

// Lock Screen + Dynamic Island UI for the live-game activity: near-black
// card with each team's color washing in from its edge, real logos at the
// sides, and the scoreline grouped in the middle so the whole card reads
// as one matchup.

@main
struct NebuloWidgetBundle: WidgetBundle {
    var body: some Widget {
        GameActivityWidget()
    }
}

struct GameActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GameActivityAttributes.self) { context in
            LockScreenGameView(context: context)
                .activityBackgroundTint(Color(red: 0.05, green: 0.05, blue: 0.08))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(deepLink(for: context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    islandTeam(
                        logoFile: context.attributes.awayLogoFile,
                        abbrev: context.attributes.awayAbbrev,
                        score: context.state.awayScore,
                        colorHex: context.attributes.awayColorHex
                    )
                }
                DynamicIslandExpandedRegion(.trailing) {
                    islandTeam(
                        logoFile: context.attributes.homeLogoFile,
                        abbrev: context.attributes.homeAbbrev,
                        score: context.state.homeScore,
                        colorHex: context.attributes.homeColorHex
                    )
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        liveClock(context: context, size: 13)
                        situationLine(context.state)
                        Text(context.attributes.leagueName.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(1)
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    .widgetURL(deepLink(for: context))
                }
            } compactLeading: {
                HStack(spacing: 5) {
                    teamLogo(context.attributes.awayLogoFile,
                             abbrev: context.attributes.awayAbbrev,
                             colorHex: context.attributes.awayColorHex,
                             size: 20)
                    Text(context.state.awayScore)
                        .font(.system(size: 14, weight: .semibold))
                        .contentTransition(.numericText())
                }
            } compactTrailing: {
                HStack(spacing: 5) {
                    Text(context.state.homeScore)
                        .font(.system(size: 14, weight: .semibold))
                        .contentTransition(.numericText())
                    teamLogo(context.attributes.homeLogoFile,
                             abbrev: context.attributes.homeAbbrev,
                             colorHex: context.attributes.homeColorHex,
                             size: 20)
                }
            } minimal: {
                teamLogo(context.attributes.homeLogoFile,
                         abbrev: context.attributes.homeAbbrev,
                         colorHex: context.attributes.homeColorHex,
                         size: 20)
            }
            .keylineTint(.red)
        }
    }

    @ViewBuilder
    private func islandTeam(logoFile: String?, abbrev: String, score: String, colorHex: String?) -> some View {
        VStack(spacing: 5) {
            teamLogo(logoFile, abbrev: abbrev, colorHex: colorHex, size: 34)
            Text(score)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(abbrev)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}

/// Tapping the activity opens the app straight to this game's detail page.
private func deepLink(for context: ActivityViewContext<GameActivityAttributes>) -> URL? {
    URL(string: "nebulo://game/\(context.attributes.gameID)")
}

// MARK: - Lock Screen card

struct LockScreenGameView: View {
    let context: ActivityViewContext<GameActivityAttributes>

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [color(from: context.attributes.awayColorHex).opacity(0.4), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                LinearGradient(
                    colors: [.clear, color(from: context.attributes.homeColorHex).opacity(0.4)],
                    startPoint: .leading, endPoint: .trailing
                )
            }

            // Faint sketch of the playing surface behind the scoreline.
            if let kind = context.attributes.sportKind {
                SportSurfaceView(kind: kind)
            }

            HStack(spacing: 0) {
                lockTeam(
                    logoFile: context.attributes.awayLogoFile,
                    abbrev: context.attributes.awayAbbrev,
                    colorHex: context.attributes.awayColorHex
                )

                VStack(spacing: 6) {
                    liveClock(context: context, size: 13)
                    HStack(spacing: 10) {
                        scoreText(context.state.awayScore)
                        Text("–")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.25))
                        scoreText(context.state.homeScore)
                    }
                    situationLine(context.state)
                    Text(context.attributes.leagueName.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(1.2)
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                lockTeam(
                    logoFile: context.attributes.homeLogoFile,
                    abbrev: context.attributes.homeAbbrev,
                    colorHex: context.attributes.homeColorHex
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
        }
        .frame(minHeight: 142)
    }

    @ViewBuilder
    private func lockTeam(logoFile: String?, abbrev: String, colorHex: String?) -> some View {
        VStack(spacing: 6) {
            teamLogo(logoFile, abbrev: abbrev, colorHex: colorHex, size: 48)
            Text(abbrev)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .frame(width: 64)
    }

    private func scoreText(_ score: String) -> some View {
        Text(score)
            .font(.system(size: 40, weight: .bold))
            .foregroundStyle(.white)
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

// MARK: - Playing-surface sketch

/// The sport's playing surface drawn in faint white line-work behind the
/// Lock Screen card — a top-down court/pitch/rink diagram, just visible
/// enough to set the scene without fighting the scoreline.
struct SportSurfaceView: View {
    let kind: String

    /// Outline-defined surfaces render whole; the rest crop as watermarks.
    private var fitsInside: Bool { ["tennis", "baseball", "octagon"].contains(kind) }

    /// Real length-to-width ratio of each surface, so the diagram reads as
    /// the actual court rather than a stretched banner.
    private var aspect: CGFloat {
        switch kind {
        case "basketball": return 94.0 / 50.0
        case "soccer": return 105.0 / 68.0
        case "football": return 120.0 / 53.3
        case "hockey": return 200.0 / 85.0
        case "tennis": return 78.0 / 36.0
        case "baseball": return 1.15
        case "octagon": return 1.0
        default: return 2.0
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let line = Color.white.opacity(0.11)
            let stroke = StrokeStyle(lineWidth: 1.6)
            func draw(_ path: Path) { ctx.stroke(path, with: .color(line), style: stroke) }

            // Two treatments, per sport. Surfaces identified by their CENTER
            // marks (midcourt circle, yard lines, faceoff dots) run oversized
            // and crop at the edges — a watermark filling the card. Surfaces
            // identified by their OUTLINE (tennis's service boxes, the
            // baseball diamond, the octagon) must be seen whole, so they fit
            // fully inside — cropping a tennis court leaves four anonymous
            // squares.
            let dh = size.height * (fitsInside ? 0.9 : 1.3)
            let dw = dh * aspect
            let r = CGRect(x: (size.width - dw) / 2, y: (size.height - dh) / 2, width: dw, height: dh)

            switch kind {
            case "basketball":
                draw(Path(roundedRect: r, cornerRadius: 2))
                draw(Path { p in
                    p.move(to: CGPoint(x: r.midX, y: r.minY))
                    p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                })
                let circle = r.height * 0.36
                draw(Path(ellipseIn: CGRect(x: r.midX - circle / 2, y: r.midY - circle / 2, width: circle, height: circle)))
                draw(Path { p in
                    p.addArc(center: CGPoint(x: r.minX, y: r.midY), radius: r.height * 0.44,
                             startAngle: .degrees(-64), endAngle: .degrees(64), clockwise: false)
                })
                draw(Path { p in
                    p.addArc(center: CGPoint(x: r.maxX, y: r.midY), radius: r.height * 0.44,
                             startAngle: .degrees(116), endAngle: .degrees(244), clockwise: true)
                })

            case "soccer":
                draw(Path(roundedRect: r, cornerRadius: 2))
                draw(Path { p in
                    p.move(to: CGPoint(x: r.midX, y: r.minY))
                    p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                })
                let circle = r.height * 0.4
                draw(Path(ellipseIn: CGRect(x: r.midX - circle / 2, y: r.midY - circle / 2, width: circle, height: circle)))
                let boxH = r.height * 0.55
                let boxW = r.width * 0.16
                draw(Path(CGRect(x: r.minX, y: r.midY - boxH / 2, width: boxW, height: boxH)))
                draw(Path(CGRect(x: r.maxX - boxW, y: r.midY - boxH / 2, width: boxW, height: boxH)))

            case "football":
                draw(Path(roundedRect: r, cornerRadius: 2))
                for i in 1..<10 {
                    let x = r.minX + r.width * CGFloat(i) / 10
                    draw(Path { p in
                        p.move(to: CGPoint(x: x, y: r.minY))
                        p.addLine(to: CGPoint(x: x, y: r.maxY))
                    })
                }

            case "hockey":
                draw(Path(roundedRect: r, cornerRadius: r.height * 0.32))
                for frac in [0.5, 0.34, 0.66] {
                    draw(Path { p in
                        p.move(to: CGPoint(x: r.minX + r.width * frac, y: r.minY))
                        p.addLine(to: CGPoint(x: r.minX + r.width * frac, y: r.maxY))
                    })
                }
                let circle = r.height * 0.34
                draw(Path(ellipseIn: CGRect(x: r.midX - circle / 2, y: r.midY - circle / 2, width: circle, height: circle)))
                draw(Path(ellipseIn: CGRect(x: r.minX + r.width * 0.14 - circle / 2, y: r.midY - circle / 2, width: circle, height: circle)))
                draw(Path(ellipseIn: CGRect(x: r.maxX - r.width * 0.14 - circle / 2, y: r.midY - circle / 2, width: circle, height: circle)))

            case "baseball":
                // Diamond with home plate at the bottom, outfield arc above.
                let base = CGPoint(x: r.midX, y: r.maxY)
                let side = r.height * 0.5
                draw(Path { p in
                    p.move(to: base)
                    p.addLine(to: CGPoint(x: r.midX - side * 0.9, y: r.maxY - side * 0.62))
                    p.addLine(to: CGPoint(x: r.midX, y: r.maxY - side * 1.24))
                    p.addLine(to: CGPoint(x: r.midX + side * 0.9, y: r.maxY - side * 0.62))
                    p.closeSubpath()
                })
                draw(Path { p in
                    p.addArc(center: base, radius: r.height,
                             startAngle: .degrees(230), endAngle: .degrees(310), clockwise: false)
                })

            case "tennis":
                draw(Path(roundedRect: r, cornerRadius: 1.5))
                // Singles sidelines (doubles alleys top/bottom).
                let alley = r.height * 0.12
                draw(Path { p in
                    p.move(to: CGPoint(x: r.minX, y: r.minY + alley))
                    p.addLine(to: CGPoint(x: r.maxX, y: r.minY + alley))
                })
                draw(Path { p in
                    p.move(to: CGPoint(x: r.minX, y: r.maxY - alley))
                    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - alley))
                })
                // Net + service lines + center service line.
                draw(Path { p in
                    p.move(to: CGPoint(x: r.midX, y: r.minY))
                    p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                })
                for frac in [0.31, 0.69] {
                    draw(Path { p in
                        p.move(to: CGPoint(x: r.minX + r.width * frac, y: r.minY + alley))
                        p.addLine(to: CGPoint(x: r.minX + r.width * frac, y: r.maxY - alley))
                    })
                }
                draw(Path { p in
                    p.move(to: CGPoint(x: r.minX + r.width * 0.31, y: r.midY))
                    p.addLine(to: CGPoint(x: r.minX + r.width * 0.69, y: r.midY))
                })

            case "octagon":
                let radius = min(r.width, r.height) / 2
                draw(Path { p in
                    for i in 0...8 {
                        let angle = CGFloat(i) * .pi / 4 + .pi / 8
                        let pt = CGPoint(x: r.midX + radius * cos(angle), y: r.midY + radius * sin(angle))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                })

            default:
                break
            }
        }
        // Soften the crop: the sketch fades out under the logo columns and
        // toward the top/bottom edges instead of ending on a hard line.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.16),
                    .init(color: .white, location: 0.84),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        )
        .mask(
            LinearGradient(
                stops: fitsInside
                    // Whole-surface diagrams keep their outline crisp.
                    ? [.init(color: .white, location: 0), .init(color: .white, location: 1)]
                    : [
                        .init(color: .white.opacity(0.35), location: 0),
                        .init(color: .white, location: 0.3),
                        .init(color: .white, location: 0.7),
                        .init(color: .white.opacity(0.35), location: 1),
                    ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }
}

// MARK: - Shared pieces

/// Live-situation line under the clock. Baseball gets the bases diamond
/// with the count and outs; football gets down & distance; sports with no
/// live situation in the feed render nothing.
@ViewBuilder
private func situationLine(_ state: GameActivityAttributes.ContentState) -> some View {
    if state.isFinal {
        EmptyView()
    } else if state.onFirst != nil || state.onSecond != nil || state.onThird != nil || state.outs != nil {
        HStack(spacing: 7) {
            MiniBases(
                first: state.onFirst ?? false,
                second: state.onSecond ?? false,
                third: state.onThird ?? false
            )
            if let balls = state.balls, let strikes = state.strikes {
                Text("\(balls)-\(strikes)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .contentTransition(.numericText())
            }
            if let outs = state.outs {
                Text("\(outs) OUT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.numericText())
            }
        }
    } else if let text = state.situationText, !text.isEmpty {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Scoreboard-style base indicator: second base on top, third left,
/// first right; occupied bases light up.
private struct MiniBases: View {
    let first: Bool
    let second: Bool
    let third: Bool

    var body: some View {
        ZStack {
            base(second).offset(y: -4.5)
            base(third).offset(x: -5.5, y: 1)
            base(first).offset(x: 5.5, y: 1)
        }
        .frame(width: 22, height: 16)
    }

    private func base(_ occupied: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(occupied ? Color.yellow : Color.white.opacity(0.22))
            .frame(width: 6, height: 6)
            .rotationEffect(.degrees(45))
    }
}

/// Red-dot live clock, or a quiet FINAL once the game ends.
@ViewBuilder
private func liveClock(context: ActivityViewContext<GameActivityAttributes>, size: CGFloat) -> some View {
    if context.state.isFinal {
        Text("FINAL")
            .font(.system(size: size - 1, weight: .bold))
            .kerning(1)
            .foregroundStyle(.white.opacity(0.6))
    } else {
        HStack(spacing: 5) {
            Circle().fill(Color.red).frame(width: 5, height: 5)
            Text(context.state.statusDetail)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.red)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// Team logo from the shared container; when it isn't available, a
/// team-color circle carrying the abbreviation's first letters.
@ViewBuilder
private func teamLogo(_ filename: String?, abbrev: String, colorHex: String?, size: CGFloat) -> some View {
    if let filename,
       let url = GameActivityAttributes.logoURL(filename: filename),
       let image = UIImage(contentsOfFile: url.path) {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    } else {
        ZStack {
            Circle().fill(color(from: colorHex).opacity(0.85))
            Text(String(abbrev.prefix(2)))
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// "1D428A" → Color. Falls back to a neutral gray when the feed carries no
/// team color.
private func color(from hex: String?) -> Color {
    guard let hex, let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) else {
        return Color(white: 0.45)
    }
    return Color(
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255
    )
}
