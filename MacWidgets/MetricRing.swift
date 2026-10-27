import SwiftUI
import StrandDesign

/// Static circular progress ring for WidgetKit: faint track + trimmed round-cap stroke starting at
/// 12 o'clock, value centred. No animation, no TimelineView — widgets render a single snapshot.
/// The ring scales with the space it is given (stroke and value font derive from the diameter).
struct MetricRing: View {
    /// 0…1 (already clamped by `WidgetRingFormat.fill`).
    let fill: Double
    let color: Color
    let valueText: String
    /// Whether the value is missing (draws the value in the tertiary colour).
    var isEmpty: Bool = false
    /// Value font size as a fraction of the ring diameter.
    var valueScale: CGFloat = 0.27

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let d = min(geo.size.width, geo.size.height)
                    let line = max(d * 0.115, 4)
                    ZStack {
                        Circle()
                            .stroke(StrandPalette.textTertiary.opacity(0.22), lineWidth: line)
                        if fill > 0 {
                            Circle()
                                .trim(from: 0, to: fill)
                                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        Text(valueText)
                            .font(.system(size: d * valueScale, weight: .bold, design: .rounded))
                            .foregroundStyle(isEmpty ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .padding(.horizontal, line + 2)
                    }
                    .frame(width: d - line, height: d - line)
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
    }
}

/// A ring with its caption underneath — one of the three WHOOP home-screen rings.
struct MetricRingColumn: View {
    let label: LocalizedStringKey
    /// Table the label is looked up in (the widget's language, see `WidgetLocalization`).
    let bundle: Bundle
    let fill: Double
    let color: Color
    let valueText: String
    var isEmpty: Bool = false
    var valueScale: CGFloat = 0.27

    var body: some View {
        VStack(spacing: 5) {
            MetricRing(fill: fill, color: color, valueText: valueText, isEmpty: isEmpty, valueScale: valueScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(label, bundle: bundle)
                .font(.caption2.weight(.medium))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label, bundle: bundle))
        .accessibilityValue(valueText)
    }
}
