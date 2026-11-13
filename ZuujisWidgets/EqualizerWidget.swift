// SPDX-License-Identifier: GPL-3.0-or-later

import AppIntents
import SwiftUI
import WidgetKit

struct EQEntry: TimelineEntry {
    let date: Date
    let state: WidgetState?
}

struct EQProvider: TimelineProvider {
    func placeholder(in context: Context) -> EQEntry { EQEntry(date: .now, state: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (EQEntry) -> Void) {
        completion(EQEntry(date: .now, state: context.isPreview ? Self.sample : WidgetFiles.loadState()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<EQEntry>) -> Void) {
        completion(Timeline(entries: [EQEntry(date: .now, state: WidgetFiles.loadState())], policy: .never))
    }

    static let sample: WidgetState = {
        var s = WidgetState()
        s.eqOn = true
        s.preset = "Bass Boost"
        s.preampDB = 2
        s.bass = 4; s.mid = -1; s.treble = 3
        s.presets = ["Flat", "Bass Boost", "Treble Boost", "Vocal", "Rock", "Pop", "Jazz", "Night Mode", "Podcast"]
        return s
    }()
}

struct EqualizerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Equalizer", provider: EQProvider()) { entry in
            EqualizerView(entry: entry)
                .containerBackground(for: .widget) { WTheme.background(art: nil) }
        }
        .configurationDisplayName("Equalizer")
        .description("Power, bypass, your presets, bass / mid / treble and preamp, one tap at a time. Arrange it in the app's Settings.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

/// A widget has no sliders or drags, only taps, so this one is a remote: the
/// controls that make sense as taps (power, bypass, preset buttons, 1 dB steps
/// for bass, mid, treble and the preamp, flat) and nothing that pretends to be
/// draggable. Fine shaping stays in the app.
struct EqualizerView: View {
    let entry: EQEntry
    @Environment(\.widgetFamily) private var family

    private var layout: WidgetSettings { entry.state?.layout ?? WidgetSettings() }
    /// The size chosen in Settings, as a factor on buttons and text.
    private var k: CGFloat { CGFloat(WidgetSettings.factor(layout.eqSize)) }

    var body: some View {
        let state = entry.state ?? WidgetState()
        Group {
            switch family {
            case .systemSmall: small(state)
            case .systemMedium: medium(state)
            default: large(state)
            }
        }
        .foregroundStyle(.white)
    }

    private func status(_ s: WidgetState) -> (String, Color) {
        if !s.eqOn { return ("OFF", .white.opacity(0.45)) }
        return s.bypassed ? ("BYPASSED", WTheme.amber) : ("ON", WTheme.mint)
    }

    // MARK: Pieces

    private func power(_ s: WidgetState, size: CGFloat) -> some View {
        Button(intent: EQPowerIntent()) {
            ZStack {
                Circle().fill(s.eqOn ? WTheme.mint.opacity(0.2) : .white.opacity(0.07))
                Circle().strokeBorder(s.eqOn ? WTheme.mint : .white.opacity(0.22), lineWidth: 1.5)
                Image(systemName: "power").font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(s.eqOn ? WTheme.mint : .white.opacity(0.6))
            }
            .frame(width: size, height: size)
            .shadow(color: s.eqOn ? WTheme.mint.opacity(0.5) : .clear, radius: 6)
            .widgetAccentable(s.eqOn)
        }
        .buttonStyle(.plain)
    }

    private func header(_ s: WidgetState, size: CGFloat) -> some View {
        HStack(spacing: 8) {
            power(s, size: size)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.preset.isEmpty ? "Custom" : s.preset).font(.system(size: 13, weight: .bold)).lineLimit(1)
                let (text, color) = status(s)
                Text(text).font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundStyle(color)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ title: String?, symbol: String, on: Bool = false, tint: Color = WTheme.cyan, intent: some AppIntent) -> some View {
        Button(intent: intent) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                if let title { Text(title).font(.system(size: 11 * k, weight: .semibold)).lineLimit(1) }
            }
            .foregroundStyle(on ? tint : .white.opacity(0.85))
            .padding(.horizontal, title == nil ? 0 : 10)
            .frame(width: title == nil ? 28 * k : nil, height: 26 * k)
            .background(Capsule().fill(on ? tint.opacity(0.2) : .white.opacity(0.09)))
            .overlay(Capsule().strokeBorder(on ? tint.opacity(0.6) : .white.opacity(0.14)))
            .widgetAccentable(on)
        }
        .buttonStyle(.plain)
    }

    /// LABEL  − value +   (the value resets when it has a reset intent).
    private func stepper(_ label: String, _ value: Double, decimals: Int = 0, height: CGFloat = 28,
                         down: some AppIntent, up: some AppIntent, reset: (any AppIntent)? = nil) -> some View {
        // Half-dB steps need the decimal to show.
        let places = max(decimals, layout.eqStep.rounded() == layout.eqStep ? 0 : 1)
        let text = WidgetSettings.signed(value, places: places)
        return HStack(spacing: 6) {
            Text(label).font(.system(size: 9 * k, weight: .semibold)).tracking(0.8).foregroundStyle(.white.opacity(0.5))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 38 * k, alignment: .leading)
            stepButton("minus", down)
            Group {
                if let reset { Button(intent: reset) { valueText(text, value) }.buttonStyle(.plain) } else { valueText(text, value) }
            }
            .frame(maxWidth: .infinity)
            stepButton("plus", up)
        }
        .frame(height: height * k)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.07)))
    }

    private func valueText(_ text: String, _ value: Double) -> some View {
        Text(text).font(.system(size: 12 * k, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(value > 0.05 ? WTheme.mint : (value < -0.05 ? WTheme.amber : .white.opacity(0.75)))
    }

    private func stepButton(_ symbol: String, _ intent: some AppIntent) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol).font(.system(size: 10 * k, weight: .bold))
                .frame(width: 22 * k, height: 22 * k)
                .background(Circle().fill(.white.opacity(0.12)))
                .overlay(Circle().strokeBorder(.white.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }

    private func tone(_ label: String, _ region: String, _ value: Double, height: CGFloat = 28) -> some View {
        stepper(label, value, height: height,
                down: ToneIntent(region: region, step: -layout.eqStep), up: ToneIntent(region: region, step: layout.eqStep))
    }

    private func preampStepper(_ s: WidgetState, height: CGFloat = 28) -> some View {
        stepper("PREAMP", s.preampDB, decimals: 1, height: height,
                down: PreampIntent(step: -layout.eqStep), up: PreampIntent(step: layout.eqStep), reset: PreampIntent(step: 0))
    }

    private func toneGrid(_ s: WidgetState, height: CGFloat = 28) -> some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow { tone("BASS", "bass", s.bass, height: height); tone("MID", "mid", s.mid, height: height) }
            GridRow { tone("TREBLE", "treble", s.treble, height: height); preampStepper(s, height: height) }
        }
    }

    /// The preset buttons, as many rows as the space left holds. Which
    /// presets, and in what order, is chosen in the app's Settings.
    private func presetGrid(_ s: WidgetState, columns: Int) -> some View {
        GeometryReader { geo in
            let rowHeight = 28 * k, gap: CGFloat = 6
            let fits = WidgetSettings.rows(in: geo.size.height, rowHeight: rowHeight, spacing: gap)
            let names = Array(s.presets.prefix(fits * columns))
            let rows = (names.count + columns - 1) / max(1, columns)
            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            if index < names.count {
                                presetButton(names[index], on: names[index] == s.preset, height: rowHeight)
                            } else {
                                Color.clear.frame(maxWidth: .infinity).frame(height: rowHeight)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func presetButton(_ name: String, on: Bool, height: CGFloat) -> some View {
        Button(intent: SetPresetIntent(preset: name)) {
            Text(name).font(.system(size: 11 * k, weight: on ? .bold : .medium)).lineLimit(1).minimumScaleFactor(0.75)
                .foregroundStyle(on ? WTheme.cyan : .white.opacity(0.85))
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity).frame(height: height)
                .background(Capsule().fill(on ? WTheme.cyan.opacity(0.2) : .white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(on ? WTheme.cyan.opacity(0.6) : .white.opacity(0.12)))
                .widgetAccentable(on)
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.white.opacity(0.45))
    }

    // MARK: Sizes

    private func small(_ s: WidgetState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(s, size: 32)
            if layout.eqSmall == "presets" {
                presetGrid(s, columns: 2)
            } else {
                preampStepper(s)
                HStack(spacing: 8) {
                    chip("Bypass", symbol: "circle.slash", on: s.bypassed, tint: WTheme.amber, intent: EQBypassIntent())
                    chip(nil, symbol: "square.stack.3d.up", intent: NextPresetIntent())
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
    }

    private func medium(_ s: WidgetState) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                header(s, size: 32)
                chip("Bypass", symbol: "circle.slash", on: s.bypassed, tint: WTheme.amber, intent: EQBypassIntent())
                if layout.eqMedium == "presets" {
                    chip(nil, symbol: "arrow.counterclockwise", intent: FlatIntent())
                } else {
                    chip(nil, symbol: "square.stack.3d.up", intent: NextPresetIntent())
                }
            }
            if layout.eqMedium == "presets" {
                presetGrid(s, columns: layout.eqColumns)
            } else {
                toneGrid(s)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
    }

    private func large(_ s: WidgetState) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                header(s, size: 40)
                chip("Bypass", symbol: "circle.slash", on: s.bypassed, tint: WTheme.amber, intent: EQBypassIntent())
                chip("Flat", symbol: "arrow.counterclockwise", intent: FlatIntent())
            }
            if layout.eqLargeTone, !layout.eqPresetsFirst { toneGrid(s, height: 32) }
            sectionLabel("PRESETS")
            presetGrid(s, columns: layout.eqColumns)
            if layout.eqLargeTone, layout.eqPresetsFirst { toneGrid(s, height: 32) }
        }
        .padding(16)
    }
}
