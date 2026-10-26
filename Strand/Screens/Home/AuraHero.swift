#if os(macOS)
import SwiftUI

// MARK: - Aura hero
//
// The abstract stand-in for the reference's portrait: a slowly turning sphere of light points
// (the "body" as a cloud of signals) over a soft warm glow, with vital read-outs anchored to
// markers on its surface. It breathes gently at the current heart rate. The animation pauses when
// the window is inactive or Reduce Motion is on, so it costs nothing in the background.

struct AuraCallout: Identifiable, Equatable {
    enum Side { case leading, trailing }
    let id: String
    let title: LocalizedStringResource
    let value: String
    let unit: String
    let status: LocalizedStringResource
    let side: Side
    /// Vertical label position as a fraction of the hero height.
    let labelY: CGFloat
    /// Marker position on the sphere, degrees clockwise from 12 o'clock.
    let markerAngle: Double
}

struct AuraHero: View {
    var callouts: [AuraCallout]
    var heartRate: Int?
    var caption: LocalizedStringResource

    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private static let points: [SIMD3<Double>] = {
        let n = 760
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return (0..<n).map { i in
            let y = 1 - 2 * (Double(i) + 0.5) / Double(n)
            let r = (1 - y * y).squareRoot()
            let t = golden * Double(i)
            return SIMD3(cos(t) * r, y, sin(t) * r)
        }
    }()

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let radius = min(size.width * 0.31, size.height * 0.28)
            let center = CGPoint(x: size.width * 0.56, y: size.height * 0.43)
            ZStack(alignment: .topLeading) {
                glow(center: center, radius: radius, size: size)
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: activeState == .inactive || reduceMotion)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    Canvas { gc, _ in
                        drawSphere(gc, center: center, radius: radius * pulse(t), t: t)
                    }
                }
                ForEach(callouts) { c in
                    callout(c, center: center, radius: radius, size: size)
                }
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(Soft.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: min(220, size.width), alignment: .leading)
                    .position(x: min(110, size.width / 2), y: size.height - 30)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func pulse(_ t: TimeInterval) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let bpm = Double(heartRate ?? 60)
        let beat = sin(2 * .pi * t * bpm / 60)
        return 1 + 0.008 * CGFloat(max(beat, 0))
    }

    private func glow(center: CGPoint, radius: CGFloat, size: CGSize) -> some View {
        let dark = scheme == .dark
        return ZStack {
            RadialGradient(colors: [Soft.peachWash.opacity(dark ? 0.55 : 0.9), Soft.peachWash.opacity(0)],
                           center: .center, startRadius: 0, endRadius: radius * 1.5)
                .frame(width: radius * 3, height: radius * 3)
                .position(x: center.x - radius * 0.25, y: center.y + radius * 0.35)
            RadialGradient(colors: [Soft.roseWash.opacity(dark ? 0.5 : 0.85), Soft.roseWash.opacity(0)],
                           center: .center, startRadius: 0, endRadius: radius * 1.2)
                .frame(width: radius * 2.4, height: radius * 2.4)
                .position(x: center.x + radius * 0.35, y: center.y - radius * 0.2)
            RadialGradient(colors: [Soft.blueWash.opacity(dark ? 0.45 : 0.75), Soft.blueWash.opacity(0)],
                           center: .center, startRadius: 0, endRadius: radius * 1.1)
                .frame(width: radius * 2.2, height: radius * 2.2)
                .position(x: center.x + radius * 0.1, y: center.y - radius * 0.75)
        }
        .blur(radius: 18)
        .allowsHitTesting(false)
    }

    private func drawSphere(_ gc: GraphicsContext, center: CGPoint, radius: CGFloat, t: TimeInterval) {
        let theta = reduceMotion ? 0.6 : t * (2 * .pi / 70)
        let tilt = -0.32
        let (ct, st) = (cos(theta), sin(theta))
        let (cx, sx) = (cos(tilt), sin(tilt))
        let top = Soft.violet, mid = Soft.rose, bottom = Soft.peach
        for p in Self.points {
            // Rotate around Y, then tilt around X.
            let x1 = p.x * ct + p.z * st
            let z1 = -p.x * st + p.z * ct
            let y2 = p.y * cx - z1 * sx
            let z2 = p.y * sx + z1 * cx
            let depth = (z2 + 1) / 2
            let sizeDot = 1.0 + 1.9 * depth
            let alpha = 0.10 + 0.82 * pow(depth, 1.6)
            let pt = CGPoint(x: center.x + CGFloat(x1) * radius, y: center.y - CGFloat(y2) * radius)
            let color = y2 > 0.15 ? top : (y2 > -0.35 ? mid : bottom)
            let rect = CGRect(x: pt.x - sizeDot / 2, y: pt.y - sizeDot / 2, width: sizeDot, height: sizeDot)
            gc.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
        }
        // A bright inner core.
        let core = radius * 0.22
        gc.fill(Path(ellipseIn: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2)),
                with: .radialGradient(Gradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0)]),
                                      center: center, startRadius: 0, endRadius: core))
    }

    @ViewBuilder
    private func callout(_ c: AuraCallout, center: CGPoint, radius: CGFloat, size: CGSize) -> some View {
        let a = (c.markerAngle - 90) * .pi / 180
        let marker = CGPoint(x: center.x + radius * 0.92 * CGFloat(cos(a)), y: center.y + radius * 0.92 * CGFloat(sin(a)))
        let labelW: CGFloat = 104
        let labelX: CGFloat = c.side == .leading ? labelW / 2 : size.width - labelW / 2
        let labelY = size.height * c.labelY
        let anchor = CGPoint(x: c.side == .leading ? labelW - 4 : size.width - labelW + 4, y: labelY - 10)

        Path { p in
            p.move(to: anchor)
            p.addLine(to: marker)
        }
        .stroke(Soft.ink3.opacity(0.55), lineWidth: 0.8)

        AuraMarker().position(marker)

        VStack(alignment: c.side == .leading ? .leading : .trailing, spacing: 2) {
            Text(c.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Soft.ink)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(c.value).font(Soft.number(24))
                Text(c.unit).font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(Soft.ink)
            Text(c.status).font(.system(size: 12)).foregroundStyle(Soft.ink3)
        }
        .frame(width: labelW, alignment: c.side == .leading ? .leading : .trailing)
        .position(x: labelX, y: labelY)
        .accessibilityElement(children: .combine)
    }
}

/// Yellow dot in a white ring with a translucent halo.
private struct AuraMarker: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.35)).frame(width: 34, height: 34)
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
            Circle().fill(Color.white).frame(width: 14, height: 14)
            Circle().fill(Soft.marker).frame(width: 8, height: 8)
        }
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
    }
}
#endif
