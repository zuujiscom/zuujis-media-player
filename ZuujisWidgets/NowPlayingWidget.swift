// SPDX-License-Identifier: GPL-3.0-or-later

import AppIntents
import SwiftUI
import WidgetKit

struct PlayerEntry: TimelineEntry {
    let date: Date
    let state: WidgetState?
    let art: NSImage?
}

/// One entry now and, while a synced song plays, one at the start of each
/// upcoming lyric line, so the line changes on time with no refresh from the
/// app. The app reloads the timeline whenever the song, pause state, speed or
/// position jumps.
struct PlayerProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlayerEntry {
        PlayerEntry(date: .now, state: Self.sample, art: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlayerEntry) -> Void) {
        completion(PlayerEntry(date: .now, state: context.isPreview ? Self.sample : WidgetFiles.loadState(),
                               art: context.isPreview ? nil : loadArtwork()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlayerEntry>) -> Void) {
        let state = WidgetFiles.loadState()
        let art = loadArtwork()
        let now = Date()
        var entries = [PlayerEntry(date: now, state: state, art: art)]
        if let state, state.isPlaying, state.speed > 0 {
            let here = state.position(at: now)
            var dates: [Date] = []
            // Lyric lines on time, plus a tick every 15 s for the progress bar
            // (in the flattened desktop look it cannot count by itself).
            for line in state.lyrics where line.t > here {
                dates.append(now.addingTimeInterval((line.t - here) / state.speed))
            }
            for n in 1...40 { dates.append(now.addingTimeInterval(Double(n) * 15)) }
            let remaining = (state.duration - here) / state.speed
            for when in dates.sorted() where when.timeIntervalSince(now) < min(3600, remaining) && entries.count < 160 {
                entries.append(PlayerEntry(date: when, state: state, art: art))
            }
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    static let sample = WidgetState(
        hasTrack: true, title: "Saltwater Radio", artist: "Velvet Harbor", album: "Low Tide Letters",
        format: "FLAC · 44.1 kHz", isPlaying: true, duration: 214, position: 42, anchor: .now, speed: 1,
        lyrics: [.init(t: 30, s: "Paper lanterns drifting past the pier"), .init(t: 50, s: "Every little wave is spelling out your name")])
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: PlayerProvider()) { entry in
            NowPlayingView(entry: entry)
                .containerBackground(for: .widget) { WTheme.background(art: entry.art) }
        }
        .configurationDisplayName("Now Playing")
        .description("The song that is playing, its lyrics and the player controls.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct NowPlayingView: View {
    let entry: PlayerEntry
    @Environment(\.widgetFamily) private var family
    /// Desktop widgets are drawn flattened ("accented") much of the time:
    /// gradients and tints collapse to one colour, so every control has to
    /// read by shape and opacity as well as colour.
    @Environment(\.widgetRenderingMode) private var mode
    private var full: Bool { mode == .fullColor }

    var body: some View {
        Group {
            if let state = entry.state, state.hasTrack {
                switch family {
                case .systemSmall: small(state)
                case .systemMedium: medium(state)
                default: large(state)
                }
            } else {
                empty
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: Pieces

    private func artwork(_ size: CGFloat) -> some View {
        Group {
            if let art = entry.art {
                Image(nsImage: art).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(full ? AnyShapeStyle(WTheme.signalDiagonal.opacity(0.55)) : AnyShapeStyle(Color.white.opacity(0.14)))
                    Image(systemName: "music.note").font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous).strokeBorder(.white.opacity(0.25)))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
    }

    private func playButton(_ state: WidgetState, size: CGFloat) -> some View {
        Button(intent: PlayPauseIntent()) {
            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(full ? Color.black.opacity(0.8) : Color.white)
                .offset(x: state.isPlaying ? 0 : size * 0.03)
                .frame(width: size, height: size)
                .background(Circle().fill(full ? AnyShapeStyle(WTheme.signalDiagonal) : AnyShapeStyle(Color.white.opacity(0.2))))
                .overlay(Circle().strokeBorder(full ? Color.white.opacity(0.35) : Color.white.opacity(0.7), lineWidth: full ? 1 : 1.5))
                .shadow(color: full ? WTheme.violet.opacity(0.6) : .clear, radius: 7)
                .widgetAccentable()
        }
        .buttonStyle(.plain)
    }

    private func skip(_ symbol: String, _ intent: some AppIntent, size: CGFloat = 30) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func progress(_ state: WidgetState) -> some View {
        Group {
            if full, state.isPlaying, state.duration > 0, state.speed > 0 {
                // Counts by itself between timeline entries.
                let start = entry.date.addingTimeInterval(-state.position(at: entry.date) / state.speed)
                ProgressView(timerInterval: start...start.addingTimeInterval(state.duration / state.speed), countsDown: false) {
                    EmptyView()
                } currentValueLabel: { EmptyView() }
                .progressViewStyle(.linear)
                .tint(WTheme.cyan)
            } else {
                // A bar of our own: the system one loses its track when flattened.
                let fraction = state.duration > 0 ? min(1, max(0, state.position(at: entry.date) / state.duration)) : 0
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule().fill(full ? AnyShapeStyle(WTheme.cyan) : AnyShapeStyle(Color.white))
                            .frame(width: max(4, geo.size.width * fraction))
                            .widgetAccentable()
                    }
                }
            }
        }
        .frame(height: 4)
    }

    private func titleBlock(_ state: WidgetState, titleSize: CGFloat, lines: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title).font(.system(size: titleSize, weight: .bold)).lineLimit(lines)
            Text([state.artist, state.album].filter { !$0.isEmpty }.joined(separator: " — "))
                .font(.system(size: titleSize * 0.76, weight: .medium))
                .foregroundStyle(.white.opacity(0.66))
                .lineLimit(1)
        }
    }

    /// The lyric line being sung at this entry's time.
    private func currentLine(_ state: WidgetState) -> Int? {
        guard !state.lyrics.isEmpty else { return nil }
        return state.lyricIndex(at: state.position(at: entry.date) + 0.05)
    }

    private func lyricText(_ state: WidgetState, _ index: Int?) -> String? {
        guard let index, state.lyrics.indices.contains(index) else { return nil }
        let text = state.lyrics[index].s
        return text.isEmpty ? "♪" : text
    }

    // MARK: Sizes

    private func small(_ state: WidgetState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                artwork(58)
                Spacer()
                playButton(state, size: 38)
            }
            Spacer(minLength: 6)
            titleBlock(state, titleSize: 14)
            progress(state).padding(.top, 9)
        }
        .padding(14)
    }

    private func medium(_ state: WidgetState) -> some View {
        HStack(spacing: 14) {
            artwork(118)
            VStack(alignment: .leading, spacing: 0) {
                titleBlock(state, titleSize: 15)
                if let line = lyricText(state, currentLine(state)) {
                    Text(line)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(WTheme.signal)
                        .widgetAccentable()
                        .lineLimit(2)
                        .padding(.top, 8)
                }
                Spacer(minLength: 4)
                progress(state)
                HStack(spacing: 18) {
                    Spacer()
                    skip("backward.fill", PreviousTrackIntent())
                    playButton(state, size: 38)
                    skip("forward.fill", NextTrackIntent())
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .padding(14)
    }

    private func large(_ state: WidgetState) -> some View {
        let index = currentLine(state)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                artwork(64)
                titleBlock(state, titleSize: 16)
                Spacer(minLength: 0)
                playButton(state, size: 40)
            }
            if state.lyrics.isEmpty {
                Spacer()
                Text("No synced lyrics for this song")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(-1...4, id: \.self) { offset in
                        let i = (index ?? -1) + offset
                        if let text = lyricText(state, state.lyrics.indices.contains(i) ? i : nil) {
                            let active = offset == 0
                            Text(text)
                                .font(.system(size: active ? 19 : 14.5, weight: active ? .bold : .semibold))
                                .foregroundStyle(active ? AnyShapeStyle(WTheme.signal) : AnyShapeStyle(Color.white.opacity(offset < 0 ? 0.28 : max(0.2, 0.62 - 0.11 * Double(offset)))))
                                .lineLimit(2)
                                .widgetAccentable(active)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Spacer().frame(height: 4)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            progress(state)
            HStack(spacing: 26) {
                Spacer()
                skip("backward.fill", PreviousTrackIntent(), size: 34)
                skip("forward.fill", NextTrackIntent(), size: 34)
                Spacer()
            }
        }
        .padding(16)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: family == .systemSmall ? 30 : 38))
                .foregroundStyle(WTheme.signalDiagonal)
            Text("Nothing playing").font(.system(size: 14, weight: .bold))
            Text("Open Zuujis Media Player").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
