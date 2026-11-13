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
            LyricsBox(showsBadge: false)
        }
        .card()
    }
}

/// The lyrics box. Synced lyrics follow the song: the line being sung is large
/// and lit in the signal colours, the lines around it fade with distance, and
/// the list scrolls to keep it in view through seeks, speed changes and the
/// next track. Click a line to jump to it. Plain lyrics just scroll. With
/// none found it says where they come from.
struct LyricsBox: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var store: LyricsStore
    /// The corner badge; the main window's card shows it in its header instead.
    var showsBadge = true
    @State private var current: Int?
    @State private var userScrolledAt = Date.distantPast

    var body: some View {
        ZStack {
            if let lyrics = store.lyrics, player.track != nil {
                if lyrics.isSynced { synced(lyrics) } else { plain(lyrics) }
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.well.opacity(Theme.palette.isLight ? 0.9 : 0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
        .overlay(alignment: .topTrailing) { if showsBadge { badge } }
        .onAppear(perform: update)
        .onChange(of: store.lyrics) { _, _ in current = nil; update() }
        .onReceive(player.timelineChanged) { update() }
        // The line only needs checking while the song moves; seeks and
        // speed changes arrive through `timelineChanged`.
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            if player.state == .playing { update() }
        }
    }

    private func update() {
        guard let lyrics = store.lyrics, lyrics.isSynced else { if current != nil { current = nil }; return }
        let index = lyrics.currentIndex(at: player.currentTime())
        if index != current { current = index }
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

    private func synced(_ lyrics: Lyrics) -> some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        // Room above and below, so the first and last lines
                        // can reach the reading position too.
                        Color.clear.frame(height: max(34, geo.size.height * 0.36))
                        ForEach(lyrics.lines) { line in
                            LyricRow(line: line, distance: current.map { line.id - $0 } ?? (line.id + 1),
                                     width: geo.size.width)
                                .id(line.id)
                                .onTapGesture {
                                    if let time = line.time { player.seek(to: time) }
                                }
                        }
                        Color.clear.frame(height: geo.size.height * 0.55)
                    }
                    .padding(.horizontal, 22)
                }
                .mask(edgeFade)
                .onChange(of: current) { _, index in
                    guard let index else { return }
                    withAnimation(.smooth(duration: 0.55)) {
                        proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.36))
                    }
                }
                .onChange(of: store.lyrics) { _, _ in
                    proxy.scrollTo(0, anchor: .top)
                }
            }
        }
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

/// One line. Distance from the line being sung sets its size, brightness and
/// blur; the current one is lit.
private struct LyricRow: View {
    let line: LyricLine
    /// 0 is the line being sung; negative is behind it, positive ahead.
    let distance: Int
    let width: CGFloat
    @State private var hovering = false

    var body: some View {
        let active = distance == 0
        let size = min(26, max(15, width / 17))
        let near = abs(distance)
        let text = line.text.isEmpty ? "♪" : line.text

        Text(text)
            .font(.system(size: active ? size : size * 0.82, weight: active ? .bold : .semibold))
            .tracking(active ? -0.2 : 0)
            .foregroundStyle(active
                             ? AnyShapeStyle(LinearGradient(colors: Theme.signalColors, startPoint: .leading, endPoint: .trailing))
                             : AnyShapeStyle(Theme.ink.opacity(hovering ? 0.8 : max(0.16, 0.55 - 0.1 * Double(near)))))
            .shadow(color: active ? Theme.violet.opacity(0.55) : .clear, radius: 10)
            .blur(radius: active || hovering ? 0 : min(1.6, 0.35 * Double(max(0, near - 1))))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.smooth(duration: 0.4), value: active)
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
