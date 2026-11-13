// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The app's one visual language: a dark studio surface, with colour reserved
/// for what the audio is doing. Mint means boost or running, amber means cut
/// or bypassed, and the cyan-violet-pink gradient belongs to the live signal.
enum Theme {
    /// The palette in use. Set by `MainView` from the saved choice before its
    /// children draw; `nonisolated(unsafe)` because it is only touched on the
    /// main thread.
    nonisolated(unsafe) static var palette: ThemePalette = .midnight

    static func apply(_ id: String) { palette = ThemePalette.named(id) }

    static var backgroundTop: Color { palette.backgroundTop }
    static var backgroundBottom: Color { palette.backgroundBottom }
    static var well: Color { palette.well }

    /// Text and line colour: white on the dark themes, near-black on the light one.
    static var ink: Color { palette.isLight ? Color(red: 0.08, green: 0.09, blue: 0.13) : .white }
    static var scheme: ColorScheme { palette.isLight ? .light : .dark }

    static var cardFill: Color { palette.isLight ? Color.white.opacity(0.72) : ink.opacity(0.045) }
    static var cardStroke: Color { ink.opacity(0.09) }
    static var hairline: Color { ink.opacity(0.07) }

    /// The three signal colours (the names are historical: each theme
    /// supplies its own hues). Mint and amber keep their meaning in every theme.
    static var cyan: Color { palette.accentA }
    static var violet: Color { palette.accentB }
    static var pink: Color { palette.accentC }
    static var mint: Color { palette.isLight ? Color(red: 0.05, green: 0.62, blue: 0.40) : Color(red: 0.30, green: 0.94, blue: 0.66) }
    static var amber: Color { palette.isLight ? Color(red: 0.84, green: 0.48, blue: 0.04) : Color(red: 1.00, green: 0.68, blue: 0.26) }
    static var red: Color { palette.isLight ? Color(red: 0.84, green: 0.18, blue: 0.22) : Color(red: 1.00, green: 0.33, blue: 0.36) }

    static var signalColors: [Color] { [cyan, violet, pink] }

    static var signal: LinearGradient {
        LinearGradient(colors: signalColors, startPoint: .leading, endPoint: .trailing)
    }

    static var background: LinearGradient {
        LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .top, endPoint: .bottom)
    }

    /// Mint for a boost, amber for a cut, neutral at rest.
    static func gainColor(_ gain: Double) -> Color {
        if gain > 0.25 { return mint }
        if gain < -0.25 { return amber }
        return Theme.ink.opacity(0.75)
    }
}

extension View {
    /// The raised panel every section of the main window sits on.
    func card(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardFill))
            // Lit from above: the rim is brighter at the top edge.
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                LinearGradient(colors: Theme.palette.isLight ? [Color.white, Theme.ink.opacity(0.08)] : [Color.white.opacity(0.17), Color.white.opacity(0.04)],
                               startPoint: .top, endPoint: .bottom)
            ))
            .shadow(color: .black.opacity(Theme.palette.isLight ? 0.10 : 0.28), radius: 14, y: 6)
    }

    /// A small rounded control surface for the header's menus and toggles.
    func pill(active: Bool = false, tint: Color = Theme.cyan) -> some View {
        self
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                Capsule().fill(active ? tint.opacity(0.16) : Theme.ink.opacity(0.06))
            )
            .overlay(
                Capsule().strokeBorder(active ? tint.opacity(0.55) : Theme.ink.opacity(0.10))
            )
            .contentShape(Capsule())
    }
}

/// The window's backdrop: the dark gradient, with a wash of the signal
/// colours bleeding in from the top corners so the cards have something to
/// sit in front of.
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.cyan.opacity(0.16), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 620)
            RadialGradient(colors: [Theme.pink.opacity(0.13), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 560)
            RadialGradient(colors: [Theme.violet.opacity(0.12), .clear],
                           center: .bottom, startRadius: 0, endRadius: 700)
        }
    }
}

/// Section heading used across the cards.
struct SectionTitle: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.signal)
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(Theme.ink.opacity(0.72))
        }
    }
}

/// A selectable look: the backdrop and the three signal colours. All are dark,
/// since the interface text is white.
struct ThemePalette: Identifiable, Equatable {
    var id: String
    var name: String
    var backgroundTop: Color
    var backgroundBottom: Color
    var well: Color
    var accentA: Color
    var accentB: Color
    var accentC: Color
    var isLight = false

    static let storageKey = "appTheme"

    private static func make(_ id: String, _ name: String, top: (Double, Double, Double),
                             bottom: (Double, Double, Double), well: (Double, Double, Double),
                             _ a: (Double, Double, Double), _ b: (Double, Double, Double),
                             _ c: (Double, Double, Double)) -> ThemePalette {
        func color(_ t: (Double, Double, Double)) -> Color { Color(red: t.0, green: t.1, blue: t.2) }
        return ThemePalette(id: id, name: name, backgroundTop: color(top), backgroundBottom: color(bottom),
                            well: color(well), accentA: color(a), accentB: color(b), accentC: color(c))
    }

    static let midnight = make("midnight", "Midnight",
        top: (0.070, 0.075, 0.115), bottom: (0.028, 0.030, 0.052), well: (0.020, 0.022, 0.040),
        (0.24, 0.86, 1.00), (0.56, 0.44, 1.00), (1.00, 0.33, 0.64))
    static let graphite = make("graphite", "Graphite",
        top: (0.105, 0.108, 0.115), bottom: (0.045, 0.046, 0.052), well: (0.030, 0.031, 0.036),
        (0.78, 0.84, 0.92), (0.62, 0.68, 0.78), (0.95, 0.96, 0.98))
    static let ocean = make("ocean", "Ocean",
        top: (0.040, 0.100, 0.150), bottom: (0.015, 0.040, 0.075), well: (0.010, 0.030, 0.055),
        (0.25, 0.80, 0.95), (0.20, 0.55, 1.00), (0.45, 0.95, 0.85))
    static let forest = make("forest", "Forest",
        top: (0.050, 0.100, 0.080), bottom: (0.018, 0.042, 0.034), well: (0.012, 0.030, 0.024),
        (0.55, 0.92, 0.50), (0.25, 0.80, 0.60), (0.85, 0.92, 0.45))
    static let ember = make("ember", "Ember",
        top: (0.130, 0.070, 0.055), bottom: (0.055, 0.026, 0.024), well: (0.040, 0.018, 0.018),
        (1.00, 0.62, 0.22), (1.00, 0.38, 0.30), (1.00, 0.82, 0.38))
    static let orchid = make("orchid", "Orchid",
        top: (0.115, 0.060, 0.130), bottom: (0.046, 0.024, 0.060), well: (0.034, 0.016, 0.044),
        (0.90, 0.45, 1.00), (0.62, 0.40, 1.00), (1.00, 0.40, 0.70))
    static let mono = make("mono", "Black",
        top: (0.020, 0.020, 0.022), bottom: (0.000, 0.000, 0.000), well: (0.000, 0.000, 0.000),
        (0.85, 0.85, 0.88), (0.55, 0.55, 0.60), (1.00, 1.00, 1.00))

    static let light: ThemePalette = {
        var p = make("light", "Light",
            top: (0.955, 0.958, 0.972), bottom: (0.880, 0.888, 0.915), well: (0.985, 0.988, 0.995),
            (0.05, 0.52, 0.80), (0.38, 0.28, 0.85), (0.86, 0.16, 0.50))
        p.isLight = true
        return p
    }()

    static let all: [ThemePalette] = [midnight, light, graphite, mono, ocean, forest, ember, orchid]

    static func named(_ id: String) -> ThemePalette { all.first { $0.id == id } ?? midnight }
}

/// A row of colour dots previewing a theme.
struct ThemeSwatch: View {
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: -4) {
            ForEach(Array([palette.isLight ? Color.white : palette.backgroundTop, palette.accentA, palette.accentB, palette.accentC].enumerated()), id: \.offset) { _, c in
                Circle().fill(c).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Theme.ink.opacity(0.25), lineWidth: 0.5))
            }
        }
    }
}

/// The header's theme chooser.
struct ThemeMenu: View {
    @AppStorage(ThemePalette.storageKey) private var themeID = ThemePalette.midnight.id

    var body: some View {
        Menu {
            ForEach(ThemePalette.all) { palette in
                Button {
                    themeID = palette.id
                } label: {
                    if palette.id == themeID { Label(palette.name, systemImage: "checkmark") } else { Text(palette.name) }
                }
            }
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.ink.opacity(0.06)))
                .overlay(Circle().strokeBorder(Theme.ink.opacity(0.10)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a colour theme")
    }
}
