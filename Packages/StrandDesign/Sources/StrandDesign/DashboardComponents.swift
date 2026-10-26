import SwiftUI

// MARK: - Dashboard components (macOS Home + Sleep overview)
//
// Small pieces of the calm dashboard look that the instrument components above don't cover:
// a card title row with an "open in detail" button, a prominent delta chip, round icon buttons,
// mini bar / arc / ring ornaments. All colours come from `StrandPalette`.

/// Pressed feedback for plain buttons: a quick dim without changing layout bounds.
public struct DimPressButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Card title row: label left, optional ↗ "open in detail" button right.
public struct CardHeader: View {
    let title: LocalizedStringKey
    var action: (() -> Void)?

    public init(title: LocalizedStringKey, action: (() -> Void)? = nil) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .center) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if let action {
                Button(action: action) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DimPressButtonStyle())
                .padding(-6)
                .help(Text("Open \(Text(title)) in detail"))
                .accessibilityLabel(Text("Open \(Text(title)) in detail"))
            }
        }
    }
}

/// Rounded delta chip beside a big value ("↑ 12 %"). Unlike `TrendChip` it stays a VoiceOver element.
public struct DeltaChip: View {
    let text: String
    var tint: Color

    public init(text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Round icon button on an inset well (date chevrons).
public struct CircleIconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var enabled: Bool
    let action: () -> Void

    public init(symbol: String, label: LocalizedStringKey, enabled: Bool = true, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                .frame(width: 34, height: 34)
                .background(StrandPalette.surfaceInset, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(DimPressButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Thin rounded bars scaled to the series maximum; the newest bar is emphasised.
public struct MiniBars: View {
    let values: [Double]
    var colors: [Color]

    public init(values: [Double], colors: [Color]) {
        self.values = values
        self.colors = colors
    }

    /// Bar height as a fraction of the chart: 0.12 for 0, 1 for the series maximum.
    static func heightFraction(_ value: Double, max hi: Double) -> CGFloat {
        0.12 + 0.88 * CGFloat(value / Swift.max(hi, 1e-9))
    }

    public var body: some View {
        GeometryReader { geo in
            let hi = values.max() ?? 1
            let n = max(values.count, 1)
            let gap: CGFloat = n > 20 ? 3 : 5
            let w = max(2, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    let f = Self.heightFraction(v, max: hi)
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top))
                        .opacity(i == values.count - 1 ? 1 : 0.35 + 0.55 * Double(f))
                        .frame(width: min(w, 7), height: max(4, geo.size.height * f))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// Half-circle gauge with a ringed dot at `fraction` (0…1).
public struct HalfArcGauge: View {
    let fraction: Double
    var color: Color

    public init(fraction: Double, color: Color) {
        self.fraction = fraction
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height * 2)
            let r = d / 2 - 6
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height - 4)
            let angle = Angle.degrees(180 + 180 * min(max(fraction, 0), 1))
            ZStack {
                Path { p in p.addArc(center: center, radius: r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false) }
                    .stroke(StrandPalette.textTertiary.opacity(0.25), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                Path { p in p.addArc(center: center, radius: r, startAngle: .degrees(180), endAngle: angle, clockwise: false) }
                    .stroke(LinearGradient(colors: [color.opacity(0.25), color], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                let dot = CGPoint(x: center.x + r * CGFloat(cos(angle.radians)), y: center.y + r * CGFloat(sin(angle.radians)))
                Circle().fill(StrandPalette.surfaceRaised).frame(width: 16, height: 16).position(dot)
                Circle().fill(color).frame(width: 9, height: 9).position(dot)
            }
        }
    }
}

/// Concentric hairline rings with a progress arc and marker on the outer ring (the Charge ornament).
public struct OrbitRings: View {
    let fraction: Double
    var color: Color

    public init(fraction: Double, color: Color) {
        self.fraction = fraction
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let f = min(max(fraction, 0), 1)
            ZStack {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .stroke(Color.white.opacity(0.75), lineWidth: 1)
                        .frame(width: s * (0.35 + 0.16 * CGFloat(i)), height: s * (0.35 + 0.16 * CGFloat(i)))
                        .position(c)
                }
                Circle()
                    .trim(from: 0, to: f)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: s * 0.99, height: s * 0.99)
                    .position(c)
                let a = Angle.degrees(-90 + 360 * f)
                let r = s * 0.495
                Circle().fill(color).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .position(x: c.x + r * CGFloat(cos(a.radians)), y: c.y + r * CGFloat(sin(a.radians)))
            }
        }
    }
}
