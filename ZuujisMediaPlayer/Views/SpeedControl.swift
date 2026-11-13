// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// "1×", "1.25×", "0.9×".
func speedLabel(_ speed: Double) -> String {
    String(format: "%g×", (speed * 100).rounded() / 100)
}

/// The speed button: shows the current speed and opens the panel below.
struct SpeedPill: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var shown = false

    var body: some View {
        let changed = player.speed != 1
        Button { shown.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(speedLabel(player.speed))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(changed ? Theme.amber : Theme.ink.opacity(0.8))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(changed ? Theme.amber.opacity(0.15) : Theme.ink.opacity(0.06)))
            .overlay(Capsule().strokeBorder(changed ? Theme.amber.opacity(0.5) : Theme.ink.opacity(0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Playback speed  (⌘[ slower, ⌘] faster)")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            SpeedPanel()
                .environmentObject(player)
        }
    }
}

/// Quick speeds, a slider for the rest, and the pitch choice.
struct SpeedPanel: View {
    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle(text: "Speed", systemImage: "speedometer")
                Spacer()
                Text(speedLabel(player.speed))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.signal)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(PlayerEngine.speedPresets, id: \.self) { value in
                    let on = abs(player.speed - value) < 0.001
                    Button { withAnimation(.spring(duration: 0.25)) { player.speed = value } } label: {
                        Text(speedLabel(value))
                            .font(.system(size: 12, weight: on ? .bold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(on ? Theme.onSignal : Theme.ink.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(Capsule().fill(on ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(Theme.ink.opacity(0.07))))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Text("0.5×").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.ink.opacity(0.45))
                GlowSlider(value: Binding(get: { player.speed }, set: { player.speed = $0 }),
                           range: PlayerEngine.speedRange, step: 0.05)
                Text("2×").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.ink.opacity(0.45))
            }

            Toggle(isOn: $player.keepsPitch) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep the pitch").font(.system(size: 12, weight: .medium))
                    Text(player.keepsPitch ? "Time-stretched: voices keep their sound" : "Like a turntable: faster is higher")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 280)
        .preferredColorScheme(Theme.scheme)
        .tint(Theme.cyan)
    }
}

/// Speed as a menu, for places a popover does not fit (the menu bar window).
struct SpeedMenu: View {
    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        Menu {
            ForEach(PlayerEngine.speedPresets, id: \.self) { value in
                Toggle(speedLabel(value), isOn: Binding(get: { abs(player.speed - value) < 0.001 },
                                                        set: { _ in player.speed = value }))
            }
            Divider()
            Toggle("Keep the Pitch", isOn: $player.keepsPitch)
        } label: {
            Label(speedLabel(player.speed), systemImage: "speedometer")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(player.speed != 1 ? Theme.amber : Theme.ink.opacity(0.8))
                .pill(active: player.speed != 1, tint: Theme.amber)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed")
    }
}
