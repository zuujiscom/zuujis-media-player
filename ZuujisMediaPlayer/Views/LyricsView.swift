// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The lyrics section of the main window: a card around the box.
struct LyricsCard: View {
    @EnvironmentObject private var store: LyricsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Lyrics", systemImage: "quote.bubble")
                Spacer()
                if store.lyrics?.isSynced == true { syncControl }
                if let lyrics = store.lyrics {
                    Text(lyrics.isSynced ? "SYNCED" : "TEXT")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(lyrics.isSynced ? Theme.mint : Theme.ink.opacity(0.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill((lyrics.isSynced ? Theme.mint : Theme.ink).opacity(0.12)))
                }
            }
            if (store.lyrics.map { !$0.hasWordTimes } ?? false) || store.isTiming
                || store.timingStatus != nil || store.batchStatus != nil { timingBar }
            LyricsBox(showsBadge: false)
        }
        .card()
    }

    /// For untimed lyrics: listen to the song and time them, line and word.
    private var timingBar: some View {
        HStack(spacing: 8) {
            if store.isTiming { ProgressView().controlSize(.small) }
            if let status = store.timingStatus ?? store.batchStatus {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if store.isTimingBatch {
                Button { store.stopTimingWords() } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.85))
                        .pill()
                }
                .buttonStyle(.plain)
            } else if !store.isTiming, let lyrics = store.lyrics, !lyrics.hasWordTimes {
                Button { store.timeCurrentLyrics() } label: {
                    Label(lyrics.isSynced ? "Time Words" : "Time These Lyrics", systemImage: "waveform.badge.mic")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.85))
                        .pill()
                }
                .buttonStyle(.plain)
                .help("Listen to this song on this Mac (speech recognition, nothing is uploaded) and time each word, so the lyrics light up word by word. Kept in the app's own folder; your music folder is not changed.")
            }
        }
    }

    /// − 0.0s + : shifts this song's lyrics, for a file whose timing is off.
    private var syncControl: some View {
        HStack(spacing: 4) {
            nudge("minus", -0.5, help: "Show the lyrics later (they come too early)")
            Button { store.resetOffset() } label: {
                Text(String(format: "%+.1fs", store.offset))
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(store.offset == 0 ? Theme.ink.opacity(0.5) : Theme.amber)
                    .frame(minWidth: 38)
            }
            .buttonStyle(.plain)
            .help("This song's lyric timing. Click to reset.")
            nudge("plus", 0.5, help: "Show the lyrics sooner (they come too late)")
        }
        .padding(.horizontal, 4)
        .background(Capsule().fill(Theme.ink.opacity(0.06)))
    }

    private func nudge(_ symbol: String, _ seconds: Double, help: String) -> some View {
        Button { store.nudge(by: seconds) } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.7))
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The lyrics box. Synced lyrics follow the song: the line being sung is large
/// and lit in the signal colours, the lines around it fade with distance, and
/// the list scrolls to keep it in view through seeks, speed changes and the
/// next track. Click a line to jump to it (that list is `SyncedLyricsView`, a
/// layer view). Plain lyrics just scroll. With none found it says where they
/// come from.
struct LyricsBox: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var store: LyricsStore
    /// The corner badge; the main window's card shows it in its header instead.
    var showsBadge = true
    var body: some View {
        ZStack {
            if let lyrics = store.lyrics, player.track != nil {
                if lyrics.isSynced { SyncedLyrics(lyrics: lyrics) } else { plain(lyrics) }
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.well.opacity(Theme.palette.isLight ? 0.9 : 0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
        .overlay(alignment: .topTrailing) { if showsBadge { badge } }
    }

    // MARK: States

    /// "LYRICS · SYNCED" in the corner.
    @ViewBuilder
    private var badge: some View {
        if let lyrics = store.lyrics {
            HStack(spacing: 6) {
                Image(systemName: "quote.bubble.fill").font(.system(size: 9.5, weight: .bold))
                Text(lyrics.isSynced ? "SYNCED" : "LYRICS")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.2)
            }
            .foregroundStyle(lyrics.isSynced ? Theme.mint : Theme.ink.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.well.opacity(0.85)))
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .padding(10)
            .allowsHitTesting(false)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: store.isLoading ? "ellipsis" : "quote.bubble")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.signal)
                .opacity(0.8)
            Text(player.track == nil ? "Lyrics show up here" : (store.isLoading ? "Looking for lyrics…" : "No lyrics for this song"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.7))
            if player.track != nil, !store.isLoading {
                Text(store.onlineMessage ?? "Put a .lrc file next to the song with the same name,\nor embed lyrics in its tags.")
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.ink.opacity(0.42))
                Button { store.lookUpNow() } label: {
                    Label("Look up online", systemImage: "network")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.85))
                        .pill()
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .help("Ask lrclib.net for this song's lyrics. Sends its title, artist, album and length.")
            }
        }
        .padding(16)
    }

    private func plain(_ lyrics: Lyrics) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear.frame(height: 18)
                ForEach(lyrics.lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Color.clear.frame(height: 18)
            }
            .padding(.horizontal, 22)
            .textSelection(.enabled)
        }
        .mask(edgeFade)
    }

    private var edgeFade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0),
                               .init(color: .black, location: 0.12),
                               .init(color: .black, location: 0.82),
                               .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}
