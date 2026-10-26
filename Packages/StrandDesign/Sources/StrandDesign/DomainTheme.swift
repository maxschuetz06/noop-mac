import SwiftUI

// MARK: - Domain Theme (NEW — Bevel per-domain colour worlds)
//
// Maps a daily-score domain (Charge / Effort / Rest / Stress) to its accent
// "colour world": a primary colour, a deep→bright gradient for gauge strokes and
// card washes, and a glow colour for blooms / end-cap halos. Every Bevel surface
// (layered gauge, frosted card tint, scenic hero) reads its colours from here so a
// screen only has to name its domain.

public enum DomainTheme: String, CaseIterable, Sendable {
    case charge
    case effort
    case rest
    case stress

    /// The dominant accent colour for the world.
    public var color: Color {
        switch self {
        case .charge: return StrandPalette.chargeColor
        case .effort: return StrandPalette.effortColor
        case .rest:   return StrandPalette.restColor
        case .stress: return StrandPalette.stressColor
        }
    }

    /// The deep (low) end of the world's accent ramp.
    public var deep: Color {
        switch self {
        case .charge: return StrandPalette.chargeDeep
        case .effort: return StrandPalette.effortDeep
        case .rest:   return StrandPalette.restDeep
        case .stress: return StrandPalette.stressDeep
        }
    }

    /// The bright (high) end of the world's accent ramp.
    public var bright: Color {
        switch self {
        case .charge: return StrandPalette.chargeBright
        case .effort: return StrandPalette.effortBright
        case .rest:   return StrandPalette.restBright
        case .stress: return StrandPalette.stressBright
        }
    }

    /// The world's glow colour for blooms and gauge end-caps.
    public var glow: Color {
        switch self {
        case .charge: return StrandPalette.chargeGlow
        case .effort: return StrandPalette.effortGlow
        case .rest:   return StrandPalette.restGlow
        case .stress: return StrandPalette.stressGlow
        }
    }

    /// Deep → bright gradient for gauge strokes and the diagonal card wash.
    public var gradient: Gradient {
        switch self {
        case .charge: return StrandPalette.chargeGradient
        case .effort: return StrandPalette.effortGradient
        case .rest:   return StrandPalette.restGradient
        case .stress: return StrandPalette.stressGradient
        }
    }

    /// The data gradient the world samples values along (Charge/Rest = recovery
    /// scale, Effort = strain ramp), used by sparklines and value-tinted strokes.
    public var dataGradient: Gradient {
        switch self {
        case .charge, .rest, .stress: return StrandPalette.recoveryGradient
        case .effort:                 return StrandPalette.strainGradient
        }
    }
}

// MARK: - Scenic Hero Background (NEW)
//
// A Canvas-drawn premium backdrop for detail-screen heroes: a radial deep blue-black
// gradient (warm-lit center → near-black edge) sprinkled with a faint deterministic
// starfield, optionally tinted toward a domain's glow. Sits behind a ScoreGauge /
// hero number. Deterministic (no per-frame randomness) so it never flickers, and the
// starfield is purely decorative (hidden from VoiceOver via the caller's container).

public struct ScenicHeroBackground: View {

    /// Optional domain whose glow tints the upper bloom. nil = neutral blue-black.
    public var domain: DomainTheme?
    /// Star count — kept modest so the field reads as texture, not noise.
    public var starCount: Int
    /// Whether to draw the bottom fade that lets content sit cleanly over the field.
    public var fadesToBase: Bool

    @Environment(\.colorScheme) private var scheme

    public init(domain: DomainTheme? = nil, starCount: Int = 40, fadesToBase: Bool = true) {
        self.domain = domain
        self.starCount = starCount
        self.fadesToBase = fadesToBase
    }

    public var body: some View {
        // Soft redesign (2026-10-19): a white card surface with a soft radial wash in the domain's
        // hue (the home dashboard's card language) instead of the blue-black scenic field.
        GeometryReader { geo in
            let r = max(geo.size.width, geo.size.height)
            ZStack {
                StrandPalette.surfaceRaised
                RadialGradient(colors: [washColor.opacity(scheme == .dark ? 0.22 : 0.20), washColor.opacity(0)],
                               center: UnitPoint(x: 0.82, y: 0.2), startRadius: 0, endRadius: r * 0.7)
                RadialGradient(colors: [washColor.opacity(scheme == .dark ? 0.10 : 0.08), washColor.opacity(0)],
                               center: UnitPoint(x: 0.1, y: 0.95), startRadius: 0, endRadius: r * 0.5)
            }
        }
        .accessibilityHidden(true)
    }

    private var washColor: Color { domain?.color ?? StrandPalette.accent }
}

#if DEBUG
#Preview("ScenicHeroBackground") {
    VStack(spacing: 0) {
        ScenicHeroBackground(domain: .charge)
            .frame(height: 220)
            .overlay(
                Text("87").font(.system(size: 60, weight: .bold, design: .rounded))
                    .foregroundStyle(StrandPalette.textPrimary)
            )
        ScenicHeroBackground(domain: .rest)
            .frame(height: 220)
    }
    .frame(width: 420, height: 440)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
