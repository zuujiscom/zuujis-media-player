// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The menu bar item's icon: it moves while a song plays or the equalizer is on.
struct MenuBarIcon: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var engine: AudioEngine

    var body: some View {
        Image(systemName: player.state == .playing ? "waveform" : (engine.isRunning ? "slider.vertical.3" : "play.circle"))
    }
}

/// The menu bar window: the player and the equalizer in small. Everything here
/// drives the same objects as the main window, so the two always agree, and
/// the window does not need to be open for any of it.
struct MenuBarPlayer: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var lyrics: LyricsStore
    @EnvironmentObject private var login: LaunchAtLogin
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(ThemePalette.storageKey) private var themeID = ThemePalette.midnight.id
    @AppStorage(Panels.visualizerOpen) private var visualizerOpen = false
    @State private var line: String?

    var body: some View {
        let _ = Theme.apply(themeID)
        VStack(spacing: 14) {
            nowPlaying
            Scrubber()
            transport
            HStack(spacing: 10) {
                SpeedMenu()
                Spacer(minLength: 0)
                VolumeControl(sliderWidth: 100)
            }

            if let line {
                Text(line)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.signal)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .transition(.opacity)
            }

            Divider().overlay(Theme.hairline)

            HStack(spacing: 10) {
                PowerButton(size: 26)
                SectionTitle(text: "Equalizer", systemImage: "slider.vertical.3")
                Spacer(minLength: 4)
                BypassButton()
            }
            HStack { PresetMenu(); Spacer(minLength: 0) }
            PreampRow()

            Divider().overlay(Theme.hairline)

            HStack(spacing: 8) {
                ChipToggle(symbol: "macwindow", title: "Open Player", isOn: false) { showMainWindow() }
                ChipToggle(symbol: "sparkles", title: "Visualizer", isOn: visualizerOpen, tint: Theme.violet) {
                    if visualizerOpen { dismissWindow(id: ZuujisMediaPlayerApp.visualizerWindowID) }
                    else { openWindow(id: ZuujisMediaPlayerApp.visualizerWindowID); NSApp.activate() }
                }
                Spacer(minLength: 0)
                Menu {
                    Toggle("Open at Login", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                    if login.needsApproval {
                        Button("Approve in Login Items Settings…") { SMLoginSettings.open() }
                    }
                    Divider()
                    Button("Quit Zuujis Media Player") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.ink.opacity(0.75))
                        .frame(width: 30, height: 28)
                        .background(Circle().fill(Theme.ink.opacity(0.06)))
                        .overlay(Circle().strokeBorder(Theme.ink.opacity(0.10)))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(AmbientBackground())
        .preferredColorScheme(Theme.scheme)
        .tint(Theme.cyan)
        .id(themeID)
        .onAppear { login.refresh(); updateLine() }
        .onReceive(player.timelineChanged) { updateLine() }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            if player.state == .playing { updateLine() }
        }
    }

    /// The lyric being sung, when there are synced lyrics.
    private func updateLine() {
        guard let lyrics = lyrics.lyrics, lyrics.isSynced,
              let index = lyrics.currentIndex(at: player.currentTime()) else {
            if line != nil { line = nil }
            return
        }
        let text = lyrics.lines[index].text
        let next = text.isEmpty ? "♪" : text
        if next != line { withAnimation(.easeOut(duration: 0.2)) { line = next } }
    }

    private func showMainWindow() {
        // Reuses the one main window; makes one if it was closed.
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(ZuujisMediaPlayerApp.mainWindowID) == true && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: ZuujisMediaPlayerApp.mainWindowID)
        }
        NSApp.activate()
    }

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            Group {
                if let image = player.track?.artwork {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [Theme.violet.opacity(0.5), Theme.cyan.opacity(0.25)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note").foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.2)))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.track?.title ?? "Nothing playing")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text([player.track?.artist, player.track?.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .lineLimit(1)
                if let track = player.track {
                    Text(track.formatSummary)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.42))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var transport: some View {
        let idle = player.track == nil && queue.items.isEmpty
        return HStack(spacing: 14) {
            IconButton(symbol: "shuffle", size: 28, glyph: 12, active: queue.shuffle, prominent: false) {
                queue.shuffle.toggle()
            }
            IconButton(symbol: "backward.fill", size: 34, glyph: 14, prominent: false) { player.previous() }
            PlayButton(isPlaying: player.state == .playing) { player.togglePlayPause() }
            IconButton(symbol: "forward.fill", size: 34, glyph: 14, prominent: false) { player.next() }
            IconButton(symbol: queue.repeatMode == .one ? "repeat.1" : "repeat", size: 28, glyph: 12,
                       active: queue.repeatMode != .off, prominent: false) {
                queue.repeatMode = queue.repeatMode.next
            }
        }
        .disabled(idle)
        .opacity(idle ? 0.45 : 1)
    }
}

/// Opens System Settings at Login Items.
enum SMLoginSettings {
    static func open() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}
