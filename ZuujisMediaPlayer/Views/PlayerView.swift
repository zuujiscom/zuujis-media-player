// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// The Now Playing stage under the header: the cover and what is playing on
/// the left, the transport over the scrubber in the middle, the output
/// switches and volume on the right. The live spectrum rises behind it, and
/// the window's backdrop (`ArtworkWash`) is the cover itself, blurred.
struct PlayerBar: View {
    @EnvironmentObject private var player: PlayerEngine

    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var playlists: PlaylistStore
    @Environment(\.openWindow) private var openWindow

    static let height: CGFloat = 140

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 16) {
                artwork
                nowPlaying
            }
            .frame(width: 372, alignment: .leading)

            VStack(spacing: 8) {
                transport
                Scrubber()
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: 14) {
                outputButtons
                volume
            }
            .frame(width: 150, alignment: .trailing)

            // Space toggles play/pause in this window. A text field being
            // edited takes the key first, and the visualizer has its own.
            Button("") { player.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .frame(height: Self.height)
        .background(alignment: .bottom) {
            StageSpectrum()
                .frame(height: 96)
                .allowsHitTesting(false)
        }
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let track = player.track {
                eyebrow(player.state == .playing ? "Now Playing" : (player.state == .paused ? "Paused" : "Stopped"),
                        live: player.state == .playing)
                    .padding(.bottom, 7)

                HStack(spacing: 8) {
                    Text(track.title)
                        .font(.system(size: 21, weight: .bold))
                        .tracking(-0.3)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    let on = playlists.isFavorite(track.url.path)
                    Button {
                        playlists.toggleFavorite(track.url.path)
                    } label: {
                        Image(systemName: on ? "heart.fill" : "heart")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(on ? Theme.pink : Theme.ink.opacity(0.4))
                            .shadow(color: on ? Theme.pink.opacity(0.6) : .clear, radius: 5)
                    }
                    .buttonStyle(.plain)
                    .help(on ? "Remove from Favorites  (⌘D)" : "Add to Favorites  (⌘D)")
                }

                Text([track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.66))
                    .lineLimit(1)
                    .padding(.top, 3)

                HStack(spacing: 7) {
                    if track.isLossless {
                        Text("LOSSLESS")
                            .font(.system(size: 8.5, weight: .heavy))
                            .tracking(0.7)
                            .foregroundStyle(Theme.mint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(Theme.mint.opacity(0.14)))
                            .overlay(Capsule().strokeBorder(Theme.mint.opacity(0.6)))
                    }
                    Text(track.formatSummary)
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink.opacity(0.5))
                        .lineLimit(1)
                }
                .padding(.top, 10)
            } else if let error = player.errorMessage {
                eyebrow("Could not play", live: false, tint: Theme.amber)
                    .padding(.bottom, 7)
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.amber)
                    .lineLimit(3)
            } else {
                eyebrow("Ready", live: false)
                    .padding(.bottom, 7)
                Text("Nothing playing")
                    .font(.system(size: 21, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Theme.ink.opacity(0.9))
                Text("Drop songs here, or pick one below")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .lineLimit(1)
                    .padding(.top, 3)
                Button {
                    PlayerActions.openFiles(in: player)
                } label: {
                    Label("Open Files…", systemImage: "folder")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.onSignal)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(Theme.signal))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
        }
    }

    private func eyebrow(_ text: String, live: Bool, tint: Color = Theme.mint) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(live ? tint : Theme.ink.opacity(0.3))
                .frame(width: 6, height: 6)
                .shadow(color: live ? tint.opacity(0.9) : .clear, radius: 4)
            Text(text.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(live ? tint : Theme.ink.opacity(0.5))
        }
    }

    private var artwork: some View {
        Group {
            if let image = player.track?.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // No cover: a tile in the track's own colour, so songs
                // without art still look different from one another.
                ZStack {
                    let tint = player.track.map { Theme.tint(for: $0.album ?? $0.title) }
                    LinearGradient(colors: tint.map { [$0.opacity(0.85), Theme.violet.opacity(0.35)] }
                                           ?? [Theme.ink.opacity(0.10), Theme.ink.opacity(0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(player.track == nil ? Theme.ink.opacity(0.3) : Color.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                }
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                                         startPoint: .top, endPoint: .bottom)))
        .shadow(color: .black.opacity(Theme.palette.isLight ? 0.22 : 0.5), radius: 16, y: 8)
    }

    // MARK: Transport

    private var transport: some View {
        let idle = player.track == nil && queue.items.isEmpty
        return HStack(spacing: 14) {
            IconButton(symbol: "shuffle", size: 28, glyph: 12, active: queue.shuffle, prominent: false) {
                queue.shuffle.toggle()
            }
            .help(queue.shuffle ? "Shuffle is on" : "Shuffle is off")

            HStack(spacing: 10) {
                IconButton(symbol: "backward.fill", size: 36, glyph: 15, prominent: false) { player.previous() }
                    .help("Previous  (⌘←)")

                PlayButton(isPlaying: player.state == .playing) { player.togglePlayPause() }
                    .help("Play / Pause  (Space)")

                IconButton(symbol: "forward.fill", size: 36, glyph: 15, prominent: false) { player.next() }
                    .help("Next  (⌘→)")
            }
            .disabled(idle)
            .opacity(idle ? 0.4 : 1)

            IconButton(symbol: queue.repeatMode == .one ? "repeat.1" : "repeat", size: 28, glyph: 12,
                       active: queue.repeatMode != .off, prominent: false) {
                queue.repeatMode = queue.repeatMode.next
            }
            .help({
                switch queue.repeatMode {
                case .off: return "Repeat is off"
                case .all: return "Repeating the queue"
                case .one: return "Repeating this track"
                }
            }())
        }
    }

    // MARK: Output and volume

    private var outputButtons: some View {
        HStack(spacing: 6) {
            IconButton(symbol: player.exclusiveMode ? "lock.fill" : "lock.open", active: player.exclusiveMode) {
                player.exclusiveMode.toggle()
            }
            .help(player.exclusiveMode
                  ? "Exclusive output on: other apps are silent while this plays"
                  : "Exclusive output off: other apps can play at the same time")

            IconButton(symbol: "waveform.badge.magnifyingglass", active: player.matchSampleRate) {
                player.matchSampleRate.toggle()
            }
            .help(player.matchSampleRate
                  ? "Output rate follows each track (on, applies from the next track or rebuild)"
                  : "Output rate left as the device has it (off)")

            IconButton(symbol: "music.note.list") {
                openWindow(id: ZuujisMediaPlayerApp.playlistWindowID)
            }
            .help("Show the queue  (⇧⌘L)")

            IconButton(symbol: "folder") {
                PlayerActions.openFiles(in: player)
            }
            .help("Open audio files or a folder  (⌘O)")
        }
    }

    private var volume: some View {
        HStack(spacing: 8) {
            Button {
                player.volume = player.volume < 0.01 ? 0.8 : 0
            } label: {
                Image(systemName: player.volume < 0.01 ? "speaker.slash.fill"
                      : (player.volume < 0.4 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.65))
                    .frame(width: 20, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            GlowSlider(value: Binding(get: { Double(player.volume) },
                                      set: { player.volume = Float($0) }))
        }
        .help("Player volume  (⌘↑ / ⌘↓)")
    }
}

/// The big play/pause button: the signal gradient with a glow that follows it.
private struct PlayButton: View {
    let isPlaying: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 19, weight: .bold))
                // The play triangle's weight sits left of its box.
                .offset(x: isPlaying ? 0 : 1.5)
                .foregroundStyle(Theme.onSignal)
                .frame(width: 52, height: 52)
                .background(Circle().fill(LinearGradient(colors: Theme.signalColors,
                                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .shadow(color: Theme.violet.opacity(isPlaying ? 0.7 : 0.4), radius: hovering ? 16 : 11, y: 2)
                .scaleEffect(hovering ? 1.05 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.25), value: hovering)
        .animation(.easeOut(duration: 0.2), value: isPlaying)
    }
}

/// The window's backdrop while a song with a cover plays: the cover itself,
/// blurred until only its colours are left, washing down from the top of the
/// window and gone by about two thirds of the way. It sits over
/// `AmbientBackground`; without a cover that shows alone.
struct ArtworkWash: View {
    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        ZStack {
            if let image = player.track?.artwork {
                // `Color.clear.overlay` pins the layout to the window: a
                // filled image otherwise reports its own, larger size.
                Color.clear
                    .overlay(Image(nsImage: image).resizable().scaledToFill())
                    .clipped()
                    .blur(radius: 80, opaque: true)
                    .saturation(1.45)
                    .opacity(Theme.palette.isLight ? 0.42 : 0.52)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                 .init(color: .black.opacity(0.75), location: 0.22),
                                                 .init(color: .clear, location: 0.68)],
                                         startPoint: .top, endPoint: .bottom))
                    .transition(.opacity)
                    .id(player.track?.url)
            }
        }
        .animation(.easeInOut(duration: 0.7), value: player.track?.url)
        .animation(.easeInOut(duration: 0.7), value: player.track?.artwork == nil)
        .allowsHitTesting(false)
    }
}

/// The live spectrum as soft bars rising behind the Now Playing stage. Its own view
/// so the meters (20 Hz) redraw this canvas and nothing else; paused, and
/// empty, when no audio is flowing.
struct StageSpectrum: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var meters: MeterState
    @EnvironmentObject private var player: PlayerEngine
    @State private var smoother = SpectrumSmoother()

    private var isLive: Bool { engine.isRunning || player.state == .playing }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isLive)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                smoother.step(toward: meters.snapshot.spectrum, at: timeline.date, live: isLive)
                guard isLive else { return }
                let values = smoother.values
                let count = values.count
                let gap: CGFloat = 3
                let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
                let reach = size.height * 0.9
                for index in 0..<count {
                    let level = CGFloat(min(1, max(0, values[index])))
                    guard level > 0.01 else { continue }
                    let height = max(2, level * reach)
                    let rect = CGRect(x: CGFloat(index) * (width + gap), y: size.height - height,
                                      width: width, height: height)
                    let tint = Theme.signalColor(at: Double(index) / Double(count - 1))
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: min(3, width / 2)),
                        with: .linearGradient(Gradient(colors: [tint.opacity(0.30), tint.opacity(0.0)]),
                                              startPoint: CGPoint(x: 0, y: rect.minY),
                                              endPoint: CGPoint(x: 0, y: rect.maxY)))
                }
            }
        }
    }
}

/// Elapsed time, the position slider and the time remaining. The position is
/// polled, not published, so this is the only view that redraws as it moves.
private struct Scrubber: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let duration = max(player.track?.duration ?? 0, 0.001)
            let position = scrubbing ? scrubValue : min(player.currentTime(), duration)

            HStack(spacing: 10) {
                Text(Self.format(position))
                    .frame(width: 44, alignment: .trailing)

                GlowSlider(
                    value: Binding(get: { position }, set: { scrubValue = $0 }),
                    range: 0...duration,
                    isEnabled: player.track != nil && player.state != .stopped,
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

                Text("-" + Self.format(max(0, duration - position)))
                    .frame(width: 48, alignment: .leading)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.ink.opacity(0.6))
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
        choose(message: "Choose audio files, or a folder of them, to play.") { urls in
            player.open(urls)
        }
    }

    /// Appends to the queue without interrupting playback.
    static func addToQueue(in player: PlayerEngine) {
        choose(message: "Choose audio files, or a folder of them, to add to the queue.") { urls in
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
