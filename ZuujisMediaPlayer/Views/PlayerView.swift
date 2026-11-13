// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// The big play/pause button: the signal gradient with a glow that follows it.
struct PlayButton: View {
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
struct Scrubber: View {
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
