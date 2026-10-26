import SwiftUI

// MARK: - Sparkline (§9.4 Today / Live HR tile)
//
// A tiny inline line for live HR (or any short numeric series). Gradient-stroked,
// with an optional crisp leading dot at the latest sample and a faint area
// wash (WHOOP-flat: no bloom). Designed to sit in a card/tile or the menu-bar popover.
// The `.smooth` style is the calm dashboard look: a Catmull-Rom curve inset from the edges and a
// ringed head dot (Home + Sleep overview cards).

public enum SparklineStyle: Sendable {
    /// Straight segments, auto-fit with 12 % padding, crisp tip-core head.
    case instrument
    /// Smooth curve through the samples, 6 pt vertical inset, ringed head.
    case smooth
}

public struct Sparkline: View {

    public var values: [Double]
    /// Line gradient (defaults to recovery scale; pass strain/zone gradients as needed).
    public var gradient: Gradient
    /// Optional explicit value range; otherwise auto-fit with padding.
    public var range: ClosedRange<Double>?
    public var lineWidth: CGFloat
    public var showsArea: Bool
    public var showsHead: Bool
    /// Whether hovering highlights the nearest sample + shows a compact tooltip.
    public var showsHover: Bool
    /// Formats a sample value for the tooltip's bold line.
    public var valueFormat: (Double) -> String
    /// Optional secondary label for a sample by index (e.g. a timestamp). When
    /// nil the tooltip falls back to "sample N".
    public var indexLabel: ((Int) -> String)?
    public var style: SparklineStyle

    public init(
        values: [Double],
        gradient: Gradient = StrandPalette.recoveryGradient,
        range: ClosedRange<Double>? = nil,
        lineWidth: CGFloat = 2,
        showsArea: Bool = true,
        showsHead: Bool = true,
        showsHover: Bool = true,
        valueFormat: @escaping (Double) -> String = { Sparkline.defaultValueString($0) },
        indexLabel: ((Int) -> String)? = nil,
        style: SparklineStyle = .instrument
    ) {
        self.values = values
        self.gradient = gradient
        self.range = range
        self.lineWidth = lineWidth
        self.showsArea = showsArea
        self.showsHead = showsHead
        self.showsHover = showsHover
        self.valueFormat = valueFormat
        self.indexLabel = indexLabel
        self.style = style
    }

    /// The dashboard line: one solid colour, smooth, no hover tooltip and (by default) no area.
    public static func smooth(_ values: [Double], color: Color, lineWidth: CGFloat = 2,
                              showsHead: Bool = true, showsArea: Bool = false) -> Sparkline {
        Sparkline(values: values, gradient: Gradient(colors: [color]), lineWidth: lineWidth, showsArea: showsArea,
                  showsHead: showsHead, showsHover: false, style: .smooth)
    }

    /// The hovered x-position in local coordinates.
    @State private var hoverX: CGFloat? = nil

    /// Default value formatting: integer when whole, else one decimal.
    public static func defaultValueString(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private var bounds: (min: Double, max: Double) {
        if let range { return (range.lowerBound, range.upperBound) }
        guard let lo = values.min(), let hi = values.max() else { return (0, 1) }
        if lo == hi { return (lo - 1, hi + 1) }
        let pad = (hi - lo) * 0.12
        return (lo - pad, hi + pad)
    }

    public var body: some View {
        GeometryReader { geo in
            let pts = style == .smooth ? Self.smoothPoints(values, in: geo.size) : points(in: geo.size)
            let areaColor = StrandPalette.sample(stops: gradient.stops, at: 0.7)
            ZStack {
                if showsArea, pts.count > 1 {
                    areaPath(pts, in: geo.size)
                        .fill(
                            LinearGradient(
                                colors: [areaColor.opacity(0.22), style == .smooth ? areaColor.opacity(0) : Color.clear],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                }
                if pts.count > 1 {
                    linePath(pts)
                        .stroke(
                            LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                        )
                }
                if showsHead, style == .smooth, let head = pts.last {
                    Circle().fill(StrandPalette.surfaceRaised).frame(width: 11, height: 11).position(head)
                    Circle().fill(StrandPalette.sample(stops: gradient.stops, at: 1.0)).frame(width: 7, height: 7)
                        .position(head)
                } else if showsHead, let head = pts.last {
                    // Design Reset (WHOOP): a crisp solid leading dot, no blurred bloom halo.
                    // The line colour reads as the head ring; a small core sits inside it.
                    let c = StrandPalette.sample(stops: gradient.stops, at: 1.0)
                    Circle().fill(c).frame(width: lineWidth * 2.2, height: lineWidth * 2.2)
                        .position(head)
                    Circle().fill(StrandPalette.tipCore).frame(width: lineWidth * 1.0, height: lineWidth * 1.0)
                        .position(head)
                }

                // Hover affordance: crosshair + highlighted sample + tooltip.
                if showsHover, !values.isEmpty, let hx = hoverX,
                   let idx = ChartHoverMath.nearestIndex(toX: hx, count: values.count, width: geo.size.width),
                   idx < pts.count {
                    let p = pts[idx]
                    let color = sampleColor(forIndex: idx)
                    CrosshairRule(x: p.x, height: geo.size.height)
                    HighlightDot(color: color, diameter: max(7, lineWidth * 3))
                        .position(p)
                    PositionedTooltip(
                        anchor: p,
                        container: geo.size,
                        tooltip: ChartTooltip(
                            value: valueFormat(values[idx]),
                            label: indexLabel?(idx) ?? "sample \(idx + 1)",
                            accent: color
                        )
                    )
                }
            }
            .animation(StrandMotion.fade, value: hoverX)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard showsHover else { return }
                switch phase {
                case .active(let location): hoverX = location.x
                case .ended: hoverX = nil
                }
            }
            // The line is pointer-hover only (dead on touch); give VoiceOver a
            // spoken summary of the series so the trend isn't silent on iPhone.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(axSummary))
        }
    }

    /// A spoken summary of the series for VoiceOver: count + latest/low/high,
    /// formatted via the same `valueFormat` closure so units match the call site.
    private var axSummary: String {
        guard let last = values.last, let lo = values.min(), let hi = values.max() else {
            return "No data"
        }
        return "Trend, \(values.count) points, latest \(valueFormat(last)), low \(valueFormat(lo)), high \(valueFormat(hi))"
    }

    /// The gradient colour at a sample's normalized position along the line.
    private func sampleColor(forIndex idx: Int) -> Color {
        let pos = values.count > 1 ? Double(idx) / Double(values.count - 1) : 1.0
        return StrandPalette.sample(stops: gradient.stops, at: pos)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let (lo, hi) = bounds
        let span = max(hi - lo, 0.0001)
        let n = values.count
        return values.enumerated().map { i, v in
            let x = n > 1 ? CGFloat(i) / CGFloat(n - 1) * size.width : size.width / 2
            let norm = (v - lo) / span
            let y = size.height - CGFloat(norm) * size.height
            return CGPoint(x: x, y: y)
        }
    }

    /// `.smooth` layout: evenly spaced, min…max mapped into the height minus a 6 pt inset.
    /// A single sample sits mid-height at the trailing edge.
    static func smoothPoints(_ values: [Double], in size: CGSize) -> [CGPoint] {
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

    private func linePath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard style == .smooth else {
            for p in pts.dropFirst() { path.addLine(to: p) }
            return path
        }
        // Catmull-Rom through every sample (endpoints duplicated as their own neighbours).
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i], p1 = pts[i], p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }

    private func areaPath(_ pts: [CGPoint], in size: CGSize) -> Path {
        var path = linePath(pts)
        if let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.addLine(to: CGPoint(x: first.x, y: size.height))
            path.closeSubpath()
        }
        return path
    }
}

#if DEBUG
private func sampleHR() -> [Double] {
    (0..<48).map { i -> Double in
        let wave: Double = 10 * sin(Double(i) / 4.0)
        let jitter: Double = Double((i * 13) % 7)
        return 58 + wave + jitter
    }
}

#Preview("Sparkline") {
    VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("64").font(StrandFont.number(34)).foregroundStyle(StrandPalette.textPrimary)
            Text("bpm").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Sparkline(
                values: sampleHR(),
                valueFormat: { "\(Int($0.rounded())) bpm" },
                indexLabel: { "\($0)s ago" }
            )
            .frame(width: 160, height: 44)
        }
        Sparkline(values: sampleHR(), gradient: StrandPalette.strainGradient)
            .frame(height: 60)
        Text("Hover any sparkline to read the exact sample under the cursor.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
    }
    .padding(24)
    .frame(width: 380, height: 240)
    .background(StrandPalette.surfaceRaised)
    .preferredColorScheme(.dark)
}
#endif
