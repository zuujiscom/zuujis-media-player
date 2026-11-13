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

    /// Text and glyphs drawn on top of the signal gradient. The dark themes'
    /// accents are bright, so they take near-black; Light's are deep, so white.
    static var onSignal: Color { palette.isLight ? .white : Color.black.opacity(0.82) }

    /// The signal gradient sampled at `t` (0 = first colour, 1 = last).
    static func signalColor(at t: Double) -> Color {
        let clamped = min(1, max(0, t))
        return clamped < 0.5 ? cyan.mix(with: violet, by: clamped * 2)
                             : violet.mix(with: pink, by: (clamped - 0.5) * 2)
    }

    /// A stable colour for a name (an artist, an album): the same name always
    /// lands on the same point of the signal gradient. `hashValue` is seeded
    /// per launch, so this folds the scalars itself.
    static func tint(for name: String) -> Color {
        var hash: UInt32 = 5381
        for scalar in name.unicodeScalars { hash = hash &* 33 &+ scalar.value }
        // Six evenly spaced stops: neighbours in a list should look different.
        return signalColor(at: Double(hash % 6) / 5)
    }

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
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.palette.isLight
                          ? AnyShapeStyle(Color.white.opacity(0.74))
                          : AnyShapeStyle(LinearGradient(colors: [Theme.ink.opacity(0.065), Theme.ink.opacity(0.030)],
                                                         startPoint: .top, endPoint: .bottom)))
            )
            // Lit from above: the rim is brighter at the top edge.
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(
                LinearGradient(colors: Theme.palette.isLight ? [Color.white, Theme.ink.opacity(0.08)] : [Color.white.opacity(0.18), Color.white.opacity(0.035)],
                               startPoint: .top, endPoint: .bottom)
            ))
            .shadow(color: .black.opacity(Theme.palette.isLight ? 0.10 : 0.32), radius: 18, y: 8)
    }

    /// A small rounded control surface for the header's menus and toggles.
    func pill(active: Bool = false, tint: Color = Theme.cyan) -> some View {
        self
            .padding(.horizontal, 12)
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

// MARK: - Controls

/// A round icon button that lights up under the pointer. `active` tints it
/// (a mode that is on); `prominent` gives it a resting surface.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 30
    var glyph: CGFloat = 13
    var active = false
    var tint: Color = Theme.cyan
    var prominent = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(active ? tint : Theme.ink.opacity(hovering ? 0.95 : 0.62))
                .frame(width: size, height: size)
                .background(Circle().fill(active ? tint.opacity(hovering ? 0.24 : 0.16)
                                                 : Theme.ink.opacity(hovering ? 0.13 : (prominent ? 0.06 : 0))))
                .overlay(Circle().strokeBorder(active ? tint.opacity(0.5)
                                                      : Theme.ink.opacity(prominent ? 0.10 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A slim horizontal slider drawn in the signal colours: the fill glows, and
/// the thumb appears under the pointer. Replaces the stock `Slider` wherever
/// the system accent colour would break the theme.
struct GlowSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double?
    var colors: [Color] = Theme.signalColors
    var isEnabled = true
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var hovering = false
    @State private var dragging = false

    private static let knob: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span) : 0
            let x = Self.knob / 2 + max(0, width - Self.knob) * fraction
            let thick: CGFloat = hovering || dragging ? 5 : 4
            let lit = isEnabled && fraction > 0.001

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ink.opacity(0.12))
                    .frame(height: thick)
                // The gradient is laid out across the whole track and the fill
                // reveals it, so a colour always sits at the same position.
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading,
                                         endPoint: UnitPoint(x: width / max(x, 1), y: 0.5)))
                    .frame(width: lit ? x : 0, height: thick)
                    .shadow(color: Theme.signalColor(at: Double(fraction)).opacity(lit ? 0.5 : 0), radius: 5)
                Circle()
                    .fill(Color.white)
                    .frame(width: Self.knob, height: Self.knob)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .scaleEffect(hovering || dragging ? 1 : 0.4)
                    .opacity(hovering || dragging ? 1 : 0)
                    .position(x: x, y: geo.size.height / 2)
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        set(at: drag.location.x, width: width)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .frame(height: 18)
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
        .accessibilityElement()
        .accessibilityValue(String(format: "%.0f percent",
                                   (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001) * 100))
        .accessibilityAdjustableAction { direction in
            let nudge = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(range.upperBound, value + nudge)
            case .decrement: value = max(range.lowerBound, value - nudge)
            @unknown default: break
            }
        }
    }

    private func set(at x: CGFloat, width: CGFloat) {
        let usable = max(1, width - Self.knob)
        let fraction = Double(min(max((x - Self.knob / 2) / usable, 0), 1))
        var next = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        if let step, step > 0 { next = (next / step).rounded() * step }
        next = min(max(next, range.lowerBound), range.upperBound)
        if next != value { value = next }
    }
}

/// A segmented choice in the app's own colours: the selection is a capsule of
/// the signal gradient that slides between the options.
struct SegmentedPills<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var height: CGFloat = 24
    var horizontalPadding: CGFloat = 12
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button {
                    withAnimation(.spring(duration: 0.28, bounce: 0.18)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(on ? Theme.onSignal : Theme.ink.opacity(0.62))
                        .padding(.horizontal, horizontalPadding)
                        .frame(height: height)
                        .background {
                            if on {
                                Capsule().fill(Theme.signal)
                                    .shadow(color: Theme.violet.opacity(0.45), radius: 6, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.ink.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.09)))
        .fixedSize()
    }
}

/// A small coloured tile standing in for a picture: an artist's initial in a
/// circle, an album's in a rounded square, or a symbol. The colour comes from
/// the name, so each keeps its own.
struct Monogram: View {
    enum Shape { case circle, square }
    let name: String
    var symbol: String?
    var shape: Shape = .circle
    var size: CGFloat = 22
    /// Neutral tiles (the "All …" rows) take no colour of their own.
    var neutral = false

    var body: some View {
        let tint = neutral ? Theme.ink.opacity(0.5) : Theme.tint(for: name)
        let fill = LinearGradient(colors: [tint.opacity(neutral ? 0.22 : 0.95), tint.opacity(neutral ? 0.10 : 0.45)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        ZStack {
            switch shape {
            case .circle: Circle().fill(fill)
            case .square: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(fill)
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(neutral ? Theme.ink.opacity(0.75) : Theme.onSignal)
            } else {
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.onSignal)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The background of a list row: selected, current, or under the pointer.
struct RowHighlight: ViewModifier {
    var isSelected = false
    var isCurrent = false
    var cornerRadius: CGFloat = 7
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isSelected ? Theme.cyan.opacity(0.20)
                          : (isCurrent ? Theme.ink.opacity(hovering ? 0.10 : 0.07)
                             : Theme.ink.opacity(hovering ? 0.055 : 0)))
            )
            .onHover { hovering = $0 }
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
                Toggle(palette.name, isOn: Binding(get: { palette.id == themeID },
                                                   set: { _ in themeID = palette.id }))
            }
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.ink.opacity(0.06)))
                .overlay(Circle().strokeBorder(Theme.ink.opacity(0.10)))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a colour theme")
    }
}
