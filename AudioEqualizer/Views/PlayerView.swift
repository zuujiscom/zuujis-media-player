// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// The transport strip along the bottom of the main window: cover, title and
/// format on the left, play and the scrubber in the middle, volume and Open on
/// the right. With nothing loaded it is a single "Open a song" prompt.
struct PlayerBar: View {
    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        HStack(spacing: 16) {
            nowPlaying
                .frame(width: 270, alignment: .leading)

            transport

            Scrubber()
                .frame(maxWidth: .infinity)

            volume

            Button {
                PlayerActions.openFile(in: player)
            } label: {
                Label("Open", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .pill()
            }
            .buttonStyle(.plain)
            .help("Open an audio file  (⇧⌘O)")
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
        HStack(spacing: 6) {
            Button { player.skip(by: -10) } label: {
                Image(systemName: "gobackward.10")
            }
            .help("Back 10 seconds  (⇧⌘←)")

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.signal).opacity(0.9))
                    .foregroundStyle(.white)
            }
            .help("Play / Pause  (⇧⌘P)")

            Button { player.skip(by: 10) } label: {
                Image(systemName: "goforward.10")
            }
            .help("Forward 10 seconds  (⇧⌘→)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(.white.opacity(0.8))
        .disabled(player.track == nil)
        .opacity(player.track == nil ? 0.4 : 1)
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
    /// Everything the player can decode.
    static let audioTypes: [UTType] = [.audio]

    static func openFile(in player: PlayerEngine) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = audioTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an audio file to play through the equalizer."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in player.open(url) }
        }
    }
}
