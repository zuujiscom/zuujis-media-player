// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct MainView: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var presets: PresetManager
    @EnvironmentObject private var player: PlayerEngine
    @AppStorage(Panels.library) private var showLibrary = true
    @AppStorage(Panels.eq) private var eqPanel = Panels.response

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            PlayerBar()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            // The graph and the faders stretch to fill whatever height the
            // window has; the scroll view only matters once the band details
            // table is open and the content outgrows it.
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 14) {
                        if showLibrary { LibraryView() }
                        if eqPanel == Panels.response { SpectrumView() }
                        if eqPanel == Panels.equalizer {
                            BandControlsView()
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(16)
                    .frame(minHeight: geo.size.height)
                }
            }
        }
        // Dropping audio files or a folder anywhere on the window plays them.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            player.open(files)
            return true
        }
        .frame(minWidth: 900, minHeight: 700)
        // Up into the hidden title bar, so the header shares its row with
        // the traffic lights instead of sitting under an empty strip.
        .ignoresSafeArea(.container, edges: .top)
        .background(AmbientBackground().ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

// MARK: - Panels

/// Which of the main window's cards are showing. Each is one switch in the
/// header; hiding one gives its space to the others.
enum Panels {
    static let library = "showLibrary"
    /// Which EQ view shows: the response graph, the faders, or neither.
    static let eq = "eqPanel"
    static let response = "response"
    static let equalizer = "faders"
    static let hidden = "none"
}

struct PanelToggles: View {
    @AppStorage(Panels.library) private var showLibrary = true
    @AppStorage(Panels.eq) private var eqPanel = Panels.response

    /// The EQ is shown as the response graph or as faders, never both; the
    /// button for the one showing hides it.
    var body: some View {
        HStack(spacing: 6) {
            toggle("books.vertical", isOn: $showLibrary, name: "Library")
            toggle("waveform.path.ecg", isOn: choice(Panels.response), name: "Response graph")
            toggle("slider.vertical.3", isOn: choice(Panels.equalizer), name: "Equalizer faders")
        }
    }

    private func choice(_ value: String) -> Binding<Bool> {
        Binding(get: { eqPanel == value },
                set: { eqPanel = $0 ? value : Panels.hidden })
    }

    private func toggle(_ symbol: String, isOn: Binding<Bool>, name: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(isOn.wrappedValue ? 0.95 : 0.4))
                .pill(active: isOn.wrappedValue)
        }
        .buttonStyle(.plain)
        .help(isOn.wrappedValue ? "Hide the \(name.lowercased())" : "Show the \(name.lowercased())")
    }
}

// MARK: - Header Bar

/// Power, status, devices, presets, bypass and the visualizer all live here;
/// there is no sidebar, so the graph and the faders get the full width. The
/// window has no title bar of its own — this row is drawn up into it, which is
/// why it starts clear of the traffic lights.
struct HeaderBar: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var meters: MeterState
    @EnvironmentObject private var presets: PresetManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("AE2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                statusLine
            }
            .padding(.trailing, 6)

            Spacer(minLength: 8)

            PanelToggles()
            DeviceMenu()

            Button {
                openWindow(id: AudioEqualizerApp.visualizerWindowID)
            } label: {
                Label("Visualizer", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Theme.signal).opacity(0.85))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Open the visualizer  (⇧⌘V)")

            StatusMenu()
        }
        .padding(.leading, 84)
        .padding(.trailing, 14)
        .frame(height: 54)
        .background(Color.white.opacity(0.025))
        .onChange(of: presets.selectedPresetID) { _, newID in
            if let presetID = newID, let preset = presets.preset(withID: presetID) {
                engine.applyPreset(preset)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let error = engine.routeErrorMessage {
            Text(error)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.amber)
                .lineLimit(1)
        } else if engine.isRunning {
            HStack(spacing: 5) {
                Circle().fill(engine.isBypassed ? Theme.amber : Theme.mint).frame(width: 6, height: 6)
                Text(engine.isBypassed ? "Bypassed" : "Live")
                    .foregroundStyle(engine.isBypassed ? Theme.amber : Theme.mint)
                Text("· \(engine.outputFormat)")
                    .foregroundStyle(.white.opacity(0.45))
            }
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
        } else {
            Text("Off — system audio is untouched")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
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
                .foregroundStyle(engine.isBypassed ? Theme.amber : Color.white.opacity(0.85))
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
                    .fill(engine.isRunning ? Theme.mint.opacity(0.18) : Color.white.opacity(0.06))
                Circle()
                    .strokeBorder(engine.isRunning ? Theme.mint.opacity(0.9) : Color.white.opacity(0.18),
                                  lineWidth: 1.5)
                Image(systemName: "power")
                    .font(.system(size: size * 0.41, weight: .bold))
                    .foregroundStyle(engine.isRunning ? Theme.mint : Color.white.opacity(0.6))
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
