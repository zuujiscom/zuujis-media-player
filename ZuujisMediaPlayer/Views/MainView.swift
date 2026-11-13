// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct MainView: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var presets: PresetManager
    @EnvironmentObject private var player: PlayerEngine
    @AppStorage(ThemePalette.storageKey) private var themeID = ThemePalette.midnight.id

    /// The smallest the window goes; below the widgets' own minimums the
    /// deck stacks them and scrolls.
    static let minSize = CGSize(width: 560, height: 440)

    var body: some View {
        let _ = Theme.apply(themeID)
        VStack(spacing: 0) {
            HeaderBar()
            // The widgets (player, equalizer) arrange themselves in what is
            // left of the window: side by side, stacked, or one alone.
            WidgetDeck()
        }
        // Dropping audio files or a folder anywhere on the window plays them.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            player.open(files)
            return true
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        // Up into the hidden title bar, so the header shares its row with
        // the traffic lights instead of sitting under an empty strip.
        .ignoresSafeArea(.container, edges: .top)
        .background(
            ZStack {
                AmbientBackground()
                ArtworkWash()
            }
            .ignoresSafeArea()
        )
        .preferredColorScheme(Theme.scheme)
        // Stock controls (switches, text selection) take the theme's accent.
        .tint(Theme.cyan)
        // Rebuild on a theme change so every view reads the new palette.
        .id(themeID)
    }
}

// MARK: - Widget switches

/// The two widget switches in the header. Both can be on; each box inside a
/// widget (lyrics, library, graph or faders) has its own control there.
struct PanelToggles: View {
    @AppStorage(Panels.player) private var showPlayer = true
    @AppStorage(Panels.eq) private var eqPanel = Panels.response
    @AppStorage(Panels.eqLast) private var eqLast = Panels.response

    var body: some View {
        HStack(spacing: 2) {
            toggle("play.rectangle.fill", isOn: $showPlayer, name: "Player widget", key: "⌥⌘P")
            toggle("slider.vertical.3", isOn: Panels.eqWidget($eqPanel, last: $eqLast), name: "Equalizer widget", key: "⌥⌘E")
        }
        .padding(3)
        .background(Capsule().fill(Theme.ink.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.10)))
    }

    private func toggle(_ symbol: String, isOn: Binding<Bool>, name: String, key: String) -> some View {
        Button {
            withAnimation(.spring(duration: 0.3)) { isOn.wrappedValue.toggle() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? Theme.cyan : Theme.ink.opacity(0.42))
                .frame(width: 34, height: 24)
                .background(Capsule().fill(isOn.wrappedValue ? Theme.cyan.opacity(0.18) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help((isOn.wrappedValue ? "Hide the \(name.lowercased())" : "Show the \(name.lowercased())") + "  (\(key))")
    }
}

// MARK: - Header Bar

/// The brand, the widget switches, the output device and the theme; there is
/// no sidebar. The window has no title bar of its own — this row is drawn up
/// into it, which is why it starts clear of the traffic lights. It has no
/// fill: the window's backdrop shows through. It sheds its labels as the
/// window narrows.
struct HeaderBar: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var meters: MeterState
    @EnvironmentObject private var presets: PresetManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Panels.player) private var showPlayer = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(brandText: true, compact: false)
            row(brandText: false, compact: false)
            row(brandText: false, compact: true)
        }
        .padding(.leading, 84)
        .padding(.trailing, 16)
        .frame(height: 52)
        .onChange(of: presets.selectedPresetID) { _, newID in
            if let presetID = newID, let preset = presets.preset(withID: presetID) {
                engine.applyPreset(preset)
            }
        }
    }

    private func row(brandText: Bool, compact: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                BrandMark()
                if brandText {
                    HStack(spacing: 6) {
                        Text("Zuujis").font(.system(size: 14, weight: .bold))
                        Text("Media Player").font(.system(size: 14, weight: .regular))
                    }
                    .foregroundStyle(Theme.ink.opacity(0.92))
                    .fixedSize()
                    statusLine
                }
            }

            Spacer(minLength: 8)

            PanelToggles()
            DeviceMenu(compact: compact)

            // The player widget carries the visualizer switch; without it the
            // header does.
            if !showPlayer {
                Button {
                    openWindow(id: ZuujisMediaPlayerApp.visualizerWindowID)
                } label: {
                    Label("Visualizer", systemImage: "sparkles")
                        .labelStyle(OptionalTitleLabelStyle(showsTitle: !compact))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.onSignal)
                        .padding(.horizontal, 13)
                        .frame(height: 30)
                        .background(Capsule().fill(Theme.signal))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.28)))
                        .shadow(color: Theme.violet.opacity(0.45), radius: 8, y: 1)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Open the visualizer  (⇧⌘V)")
            }

            ThemeMenu()
            StatusMenu()
        }
    }

    /// Only a route error shows; the on/off state is the power button's job.
    @ViewBuilder
    private var statusLine: some View {
        if let error = engine.routeErrorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.amber)
                .lineLimit(1)
                .padding(.leading, 6)
        }
    }
}

/// The app's mark in the header: the icon's play triangle on the signal gradient.
struct BrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: Theme.signalColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .offset(x: size * 0.03)
                    .foregroundStyle(Theme.onSignal)
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
            .frame(width: size, height: size)
            .shadow(color: Theme.violet.opacity(0.5), radius: 6, y: 1)
    }
}

// MARK: - Bypass

/// Hear the audio without the EQ, to compare. Sits with the power button and
/// presets in the Response and Equalizer boxes.
struct BypassButton: View {
    @EnvironmentObject private var engine: AudioEngine

    var body: some View {
        Button {
            engine.toggleBypass()
        } label: {
            Label("Bypass", systemImage: engine.isBypassed ? "circle.slash.fill" : "circle.slash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(engine.isBypassed ? Theme.amber : Theme.ink.opacity(0.85))
                .pill(active: engine.isBypassed, tint: Theme.amber)
        }
        .buttonStyle(.plain)
        .help("Hear the audio without the EQ, to compare  (⌘B)")
    }
}

// MARK: - Power

/// The EQ's master switch. It lives in the Response and Equalizer boxes
/// because that is all it controls: the system-wide route and the player's EQ.
struct PowerButton: View {
    @EnvironmentObject private var engine: AudioEngine
    var size: CGFloat = 26

    var body: some View {
        Button {
            engine.isRunning ? engine.stop() : engine.start()
        } label: {
            ZStack {
                Circle()
                    .fill(engine.isRunning ? Theme.mint.opacity(0.18) : Theme.ink.opacity(0.06))
                Circle()
                    .strokeBorder(engine.isRunning ? Theme.mint.opacity(0.9) : Theme.ink.opacity(0.18),
                                  lineWidth: 1.5)
                Image(systemName: "power")
                    .font(.system(size: size * 0.41, weight: .bold))
                    .foregroundStyle(engine.isRunning ? Theme.mint : Theme.ink.opacity(0.6))
            }
            .frame(width: size, height: size)
            .shadow(color: engine.isRunning ? Theme.mint.opacity(0.55) : .clear, radius: 6)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: engine.isRunning)
        .help(engine.isRunning ? "Stop  (⌘↩)" : "Start  (⌘↩)")
    }
}

#Preview {
    MainView()
        .environmentObject(AudioEngine())
        .environmentObject(AudioEngine().meters)
        .environmentObject(PresetManager())
        .environmentObject(DeviceProfileStore())
        .environmentObject(PlayerEngine())
}
