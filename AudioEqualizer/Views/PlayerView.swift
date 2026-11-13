// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// The transport strip along the bottom of the main window: cover, title and
/// format on the left, play and the scrubber in the middle, volume and Open on
/// the right. With nothing loaded it is a single "Open a song" prompt.
struct PlayerBar: View {
    @EnvironmentObject private var player: PlayerEngine

    @EnvironmentObject private var queue: PlaybackQueue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 14) {
            nowPlaying
                .frame(width: 236, alignment: .leading)

            transport

            Scrubber()
                .frame(maxWidth: .infinity)

            modeButtons

            volume

            // Space toggles play/pause in this window. A text field being
            // edited takes the key first, and the visualizer has its own.
            Button("") { player.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)

            Button {
                player.exclusiveMode.toggle()
            } label: {
                Image(systemName: player.exclusiveMode ? "lock.fill" : "lock.open")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(player.exclusiveMode ? 0.95 : 0.4))
                    .pill()
            }
            .buttonStyle(.plain)
            .help(player.exclusiveMode
                  ? "Exclusive output on: other apps are silent while this plays"
                  : "Exclusive output off: other apps can play at the same time")

            Button {
                player.matchSampleRate.toggle()
            } label: {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(player.matchSampleRate ? 0.95 : 0.4))
                    .pill()
            }
            .buttonStyle(.plain)
            .help(player.matchSampleRate
                  ? "Output rate follows each track (on, applies from the next track or rebuild)"
                  : "Output rate left as the device has it (off)")

            Button {
                openWindow(id: AudioEqualizerApp.playlistWindowID)
            } label: {
                Image(systemName: "music.note.list")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .pill()
            }
            .buttonStyle(.plain)
            .help("Show the playlist  (⇧⌘L)")

            Button {
                PlayerActions.openFiles(in: player)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .pill()
            }
            .buttonStyle(.plain)
            .help("Open audio files or a folder  (⇧⌘O)")
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(Color.white.opacity(0.03))
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        HStack(spacing: 11) {
            artwork

            VStack(alignment: .leading, spacing: 2) {
                if let track = player.track {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.artist ?? track.album ?? " ")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if track.isLossless {
                            Text("LOSSLESS")
                                .font(.system(size: 8.5, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(Theme.mint)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.mint.opacity(0.7)))
                        }
                        Text(track.formatSummary)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                } else if let error = player.errorMessage {
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.amber)
                        .lineLimit(2)
                } else {
                    Text("Nothing playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("Open a FLAC, ALAC, WAV, AIFF, MP3 or AAC file")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
        }
    }

    private var artwork: some View {
        Group {
            if let image = player.track?.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: "music.note")
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 8) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
            }
            .help("Previous  (⇧⌘[)")

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.signal).opacity(0.9))
                    .foregroundStyle(.white)
            }
            .help("Play / Pause  (⇧⌘P)")

            Button { player.next() } label: {
                Image(systemName: "forward.fill")
            }
            .help("Next  (⇧⌘])")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(.white.opacity(0.8))
        .disabled(player.track == nil && queue.items.isEmpty)
        .opacity(player.track == nil && queue.items.isEmpty ? 0.4 : 1)
    }

    private var modeButtons: some View {
        HStack(spacing: 4) {
            Button { queue.shuffle.toggle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(queue.shuffle ? Theme.cyan : .white.opacity(0.5))
            }
            .help(queue.shuffle ? "Shuffle is on" : "Shuffle is off")

            Button { queue.repeatMode = queue.repeatMode.next } label: {
                Image(systemName: queue.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(queue.repeatMode == .off ? .white.opacity(0.5) : Theme.cyan)
            }
            .help({
                switch queue.repeatMode {
                case .off: return "Repeat is off"
                case .all: return "Repeating the playlist"
                case .one: return "Repeating this track"
                }
            }())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
    }

    private var volume: some View {
        HStack(spacing: 6) {
            Image(systemName: player.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 16)
            Slider(value: Binding(get: { Double(player.volume) },
                                  set: { player.volume = Float($0) }), in: 0...1)
                .frame(width: 84)
                .controlSize(.small)
        }
        .help("Player volume")
    }
}

/// Elapsed time, the position slider and the time remaining. The position is
/// polled, not published, so this is the only view that redraws as it moves.
private struct Scrubber: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let duration = max(player.track?.duration ?? 0, 0.001)
            let position = scrubbing ? scrubValue : min(player.currentTime(), duration)

            HStack(spacing: 8) {
                Text(Self.format(position))
                    .frame(width: 42, alignment: .trailing)

                Slider(
                    value: Binding(get: { position }, set: { scrubValue = $0 }),
                    in: 0...duration,
                    onEditingChanged: { editing in
                        if editing {
                            scrubValue = player.currentTime()
                            scrubbing = true
                        } else {
                            player.seek(to: scrubValue)
                            scrubbing = false
                        }
                    }
                )
                .controlSize(.small)
                .disabled(player.track == nil || player.state == .stopped)

                Text("-" + Self.format(max(0, duration - position)))
                    .frame(width: 46, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum PlayerActions {
    /// Everything the player can decode, plus folders of it.
    static let audioTypes: [UTType] = [.audio]

    /// Replaces the playlist with the chosen files or folders and plays.
    static func openFiles(in player: PlayerEngine) {
        choose(message: "Choose audio files, or a folder of them, to play through the equalizer.") { urls in
            player.open(urls)
        }
    }

    /// Appends to the playlist without interrupting playback.
    static func addToPlaylist(in player: PlayerEngine) {
        choose(message: "Choose audio files, or a folder of them, to add to the playlist.") { urls in
            player.enqueue(urls)
        }
    }

    private static func choose(message: String, then handle: @escaping @MainActor ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = audioTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = message
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in handle(urls) }
        }
    }
}
