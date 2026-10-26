#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Soft theme
//
// The calm, airy look of the redesigned home + sidebar: warm off-white canvas, white cards with a
// hairline edge and a whisper of shadow, soft colour "washes" inside cards, SF Pro with large tight
// numerals. Every token resolves per appearance so dark mode stays legible.

enum Soft {
    static let canvas      = Color.soft(light: 0xF5F5F3, dark: 0x111315)
    static let sidebar     = Color.soft(light: 0xFAFAF8, dark: 0x16191C)
    static let card        = Color.soft(light: 0xFFFFFF, dark: 0x1C2024)
    static let cardEdge    = Color.soft(light: 0xEBEBE7, dark: 0x2A2F35)
    static let fill        = Color.soft(light: 0xEFEFEC, dark: 0x262B30)
    static let ink         = Color.soft(light: 0x111214, dark: 0xF3F4F6)
    // Text tiers meet WCAG AA (≥ 4.5:1) on cards and canvas in both appearances.
    static let ink2        = Color.soft(light: 0x55585E, dark: 0xB9BEC6)
    static let ink3        = Color.soft(light: 0x6A6D73, dark: 0x8C929A)

    static let green       = Color.soft(light: 0x3FAE5A, dark: 0x58C774)
    static let greenWash   = Color.soft(light: 0xCDEFC9, dark: 0x1F4A2A)
    static let peach       = Color.soft(light: 0xF29A4A, dark: 0xF2A35E)
    static let peachWash   = Color.soft(light: 0xFFD9B8, dark: 0x4A3020)
    static let rose        = Color.soft(light: 0xE8708A, dark: 0xEF8AA0)
    static let roseWash    = Color.soft(light: 0xFBD9E2, dark: 0x4A2430)
    static let blue        = Color.soft(light: 0x5B6CF0, dark: 0x8592FF)
    static let blueWash    = Color.soft(light: 0xDCE2FF, dark: 0x252C55)
    static let violet      = Color.soft(light: 0x9A84F0, dark: 0xB2A0FF)
    static let amber       = Color.soft(light: 0xF2B33D, dark: 0xF5C45E)
    static let marker      = Color.soft(light: 0xF6D84A, dark: 0xF6D84A)

    static let radius: CGFloat = 22

    /// Large tight display numerals (the "72" / "8,420" read-outs).
    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold).monospacedDigit() }
}

extension Color {
    /// Appearance-resolving colour from two 0xRRGGBB literals.
    static func soft(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: - Card

/// A soft colour blob drawn inside a card (top-weighted radial gradient).
struct SoftWash: Equatable {
    var color: Color
    var center: UnitPoint = UnitPoint(x: 0.7, y: 0.25)
    var secondary: Color? = nil
}

struct SoftCard<Content: View>: View {
    var wash: SoftWash? = nil
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                GeometryReader { geo in
                    let r = max(geo.size.width, geo.size.height)
                    ZStack {
                        Soft.card
                        if let wash {
                            RadialGradient(colors: [wash.color.opacity(scheme == .dark ? 0.9 : 0.95), wash.color.opacity(0)],
                                           center: wash.center, startRadius: 0, endRadius: r * 0.75)
                            if let second = wash.secondary {
                                RadialGradient(colors: [second.opacity(0.7), second.opacity(0)],
                                               center: UnitPoint(x: 0.15, y: 0.95), startRadius: 0, endRadius: r * 0.6)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Soft.radius, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: Soft.radius, style: .continuous)
                .strokeBorder(Soft.cardEdge, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : (hovering ? 0.07 : 0.035)),
                    radius: hovering ? 22 : 16, y: hovering ? 10 : 6)
            .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hovering = h } }
    }
}

/// Pressed feedback for plain buttons: a quick dim without changing layout bounds.
struct SoftPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Card title row: label left, optional ↗ button right.
struct SoftCardHeader: View {
    let title: LocalizedStringKey
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Soft.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if let action {
                Button(action: action) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Soft.ink2)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPressStyle())
                .padding(-6)
                .help(Text("Open \(Text(title)) in detail"))
                .accessibilityLabel(Text("Open \(Text(title)) in detail"))
            }
        }
    }
}

/// Small rounded delta chip ("↑ 12 %").
struct SoftChip: View {
    let text: String
    var tint: Color = Soft.green
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Round icon button (date chevrons, bell).
struct SoftCircleButton: View {
    let symbol: String
    var label: LocalizedStringKey
    var enabled = true
    var size: CGFloat = 34
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? Soft.ink : Soft.ink3)
                .frame(width: size, height: size)
                .background(Soft.fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(SoftPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Mini charts

/// Smooth Catmull-Rom line through evenly spaced values, with an optional trailing dot.
struct SoftLine: View {
    let values: [Double]
    var color: Color
    var lineWidth: CGFloat = 2
    var showsHead = true
    var fill = false

    var body: some View {
        GeometryReader { geo in
            let pts = Self.points(values, in: geo.size)
            ZStack {
                if fill, pts.count > 1 {
                    Self.path(pts, close: geo.size)
                        .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                }
                Self.path(pts, close: nil)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                if showsHead, let last = pts.last {
                    Circle().fill(Soft.card).frame(width: 11, height: 11).position(last)
                    Circle().fill(color).frame(width: 7, height: 7).position(last)
                }
            }
        }
    }

    static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count > 1, let lo = values.min(), let hi = values.max() else {
            return values.isEmpty ? [] : [CGPoint(x: size.width, y: size.height / 2)]
        }
        let span = max(hi - lo, 1e-9)
        let inset: CGFloat = 6
        return values.enumerated().map { i, v in
            CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                    y: inset + (size.height - 2 * inset) * CGFloat(1 - (v - lo) / span))
        }
    }

    static func path(_ p: [CGPoint], close size: CGSize?) -> Path {
        var path = Path()
        guard let first = p.first else { return path }
        path.move(to: first)
        if p.count > 1 {
            for i in 0..<(p.count - 1) {
                let p0 = i > 0 ? p[i - 1] : p[i], p1 = p[i], p2 = p[i + 1]
                let p3 = i + 2 < p.count ? p[i + 2] : p2
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                path.addCurve(to: p2, control1: c1, control2: c2)
            }
        }
        if let size, let last = p.last {
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.addLine(to: CGPoint(x: first.x, y: size.height))
            path.closeSubpath()
        }
        return path
    }
}

/// Thin rounded bars; the newest bar is emphasised.
struct SoftBars: View {
    let values: [Double]
    var colors: [Color]
    var baselineFraction: CGFloat = 0.12
    var highlightLast = true

    var body: some View {
        GeometryReader { geo in
            let hi = max(values.max() ?? 1, 1e-9)
            let n = max(values.count, 1)
            let gap: CGFloat = n > 20 ? 3 : 5
            let w = max(2, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    let f = baselineFraction + (1 - baselineFraction) * CGFloat(v / hi)
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top))
                        .opacity(highlightLast && i == values.count - 1 ? 1 : 0.35 + 0.55 * Double(f))
                        .frame(width: min(w, 7), height: max(4, geo.size.height * f))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// Half-circle gauge with a dot at `fraction` (0…1).
struct SoftArcGauge: View {
    let fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height * 2)
            let r = d / 2 - 6
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height - 4)
            let angle = Angle.degrees(180 + 180 * min(max(fraction, 0), 1))
            ZStack {
                Path { p in p.addArc(center: center, radius: r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false) }
                    .stroke(Soft.ink3.opacity(0.25), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                Path { p in p.addArc(center: center, radius: r, startAngle: .degrees(180), endAngle: angle, clockwise: false) }
                    .stroke(LinearGradient(colors: [color.opacity(0.25), color], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                let dot = CGPoint(x: center.x + r * CGFloat(cos(angle.radians)), y: center.y + r * CGFloat(sin(angle.radians)))
                Circle().fill(Soft.card).frame(width: 16, height: 16).position(dot)
                Circle().fill(color).frame(width: 9, height: 9).position(dot)
            }
        }
    }
}

/// Concentric hairline rings with a marker on the outer ring — the Charge card ornament.
struct SoftRings: View {
    let fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .stroke(Color.white.opacity(0.75), lineWidth: 1)
                        .frame(width: s * (0.35 + 0.16 * CGFloat(i)), height: s * (0.35 + 0.16 * CGFloat(i)))
                        .position(c)
                }
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: s * 0.99, height: s * 0.99)
                    .position(c)
                let a = Angle.degrees(-90 + 360 * min(max(fraction, 0), 1))
                let r = s * 0.495
                Circle().fill(color).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .position(x: c.x + r * CGFloat(cos(a.radians)), y: c.y + r * CGFloat(sin(a.radians)))
            }
        }
    }
}
#endif
