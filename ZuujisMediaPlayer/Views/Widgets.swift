// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Panels

/// Which of the main window's widgets and boxes are showing. Each is one
/// saved switch; the header, the View menu and the widgets themselves all
/// drive the same ones.
enum Panels {
    /// The player widget: now playing, transport, speed, lyrics, library.
    static let player = "showPlayer"
    /// The player's expandable library box.
    static let library = "showLibrary"
    /// The synced-lyrics box inside the player widget.
    static let lyrics = "showLyrics"
    /// The EQ widget: `response` or `faders` is on (and picks the view), `none` is off.
    static let eq = "eqPanel"
    /// The last EQ view, so switching the widget back on restores it.
    static let eqLast = "eqPanelLast"
    static let response = "response"
    static let equalizer = "faders"
    static let hidden = "none"
    /// Whether the visualizer's window is open (written by the window).
    static let visualizerOpen = "visualizerOpen"

    /// The EQ widget as one on/off switch over `eqPanel`.
    static func eqWidget(_ eq: Binding<String>, last: Binding<String>) -> Binding<Bool> {
        Binding(get: { eq.wrappedValue != hidden },
                set: { on in
                    if on { eq.wrappedValue = last.wrappedValue == equalizer ? equalizer : response }
                    else { eq.wrappedValue = hidden }
                })
    }
}

// MARK: - Deck

/// Lays the two widgets out in the room the window has. Both can be on at
/// once: side by side when the window is wide enough for each to keep its
/// minimum width, stacked (and scrolling, if need be) when it is not. A lone
/// widget takes the whole window. Every size decision is made here from the
/// window's size and handed to the widgets, so they never measure themselves.
struct WidgetDeck: View {
    @AppStorage(Panels.player) private var showPlayer = true
    @AppStorage(Panels.library) private var showLibrary = false
    @AppStorage(Panels.lyrics) private var showLyrics = true
    @AppStorage(Panels.eq) private var eqPanel = Panels.response

    private static let gutter: CGFloat = 16
    private static let eqMinWidth: CGFloat = 430

    var body: some View {
        GeometryReader { geo in
            let area = CGSize(width: max(0, geo.size.width - 32), height: max(0, geo.size.height - 22))
            let showEQ = eqPanel != Panels.hidden
            let playerMin = PlayerWidget.minWidth(library: showLibrary, lyrics: showLyrics)
            let side = showPlayer && showEQ && area.width >= playerMin + Self.gutter + Self.eqMinWidth

            ScrollView {
                Group {
                    if showPlayer && showEQ {
                        if side {
                            let share = showLibrary ? 0.56 : 0.46
                            let playerWidth = min(max(playerMin, area.width * share),
                                                  area.width - Self.gutter - Self.eqMinWidth)
                            HStack(alignment: .top, spacing: Self.gutter) {
                                PlayerWidget(width: playerWidth, height: area.height)
                                    .frame(width: playerWidth)
                                    .frame(maxHeight: .infinity)
                                EQWidget(width: area.width - playerWidth - Self.gutter)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        } else {
                            // Stacked: the player keeps its natural height unless
                            // it has a box that can stretch (lyrics, library).
                            VStack(spacing: Self.gutter) {
                                PlayerWidget(width: area.width, height: .infinity)
                                    .frame(maxHeight: showLibrary || showLyrics ? .infinity : nil)
                                EQWidget(width: area.width)
                                    .frame(maxHeight: .infinity)
                            }
                        }
                    } else if showPlayer {
                        let width = min(area.width, showLibrary || showLyrics ? 1400 : 880)
                        PlayerWidget(width: width, height: area.height)
                            .frame(width: width)
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: .infinity)
                    } else if showEQ {
                        EQWidget(width: area.width)
                            .frame(maxHeight: .infinity)
                    } else {
                        AllPanelsHidden()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 16)
                .frame(minHeight: geo.size.height)
            }
        }
    }
}

/// Shown when both widgets are off, so the window is not just blank.
struct AllPanelsHidden: View {
    @AppStorage(Panels.player) private var showPlayer = true

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 30))
                .foregroundStyle(Theme.ink.opacity(0.28))
            Text("Both widgets are hidden")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.75))
            Text("Bring one back from the View menu or the switches in the header.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink.opacity(0.45))
            Button {
                withAnimation(.spring(duration: 0.3)) { showPlayer = true }
            } label: {
                Text("Show Player")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.9))
                    .pill(active: true)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Player widget

/// The player: what is playing, the transport and its scrubber, speed and
/// volume, and boxes for lyrics and the library that open and close. It lays
/// itself out from the width and height the deck gives it:
///
/// - **two columns** when it is wide with lyrics on (the song on the left,
///   the lyrics beside it, full height);
/// - **hero** when nothing else is open and there is room (a large cover);
/// - **row** otherwise (a small cover beside the title);
/// - **short** when the window is tiny: just the song and the controls.
struct PlayerWidget: View {
    let width: CGFloat
    let height: CGFloat

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Panels.library) private var showLibrary = false
    @AppStorage(Panels.lyrics) private var showLyrics = true

    /// The narrowest the widget is laid out at, given what it holds.
    static func minWidth(library: Bool, lyrics: Bool) -> CGFloat {
        library ? 700 : (lyrics ? 470 : 420)
    }

    private var inner: CGFloat { max(0, width - 40) }
    private var isShort: Bool { height.isFinite && height < 340 }
    private var twoColumn: Bool { showLyrics && !showLibrary && width >= 800 && !isShort }
    private var hero: Bool { !showLyrics && !showLibrary && width >= 420 && height.isFinite && height >= 560 }
    private var compact: Bool { inner < 520 }
    /// Two columns with room for a big cover on the left.
    private var tallColumns: Bool { twoColumn && height.isFinite && height >= 600 }

    var body: some View {
        Group {
            if twoColumn {
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 16) {
                        if tallColumns {
                            Spacer(minLength: 0)
                            heroNowPlaying
                        } else {
                            nowPlaying(art: 128)
                        }
                        stage
                        if tallColumns { Spacer(minLength: 0) }
                    }
                    .frame(width: min(380, inner * 0.46))
                    LyricsBox()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 16) {
                    if hero { heroNowPlaying } else { nowPlaying(art: isShort ? 64 : (compact ? 84 : 104)) }
                    stage
                    if !isShort {
                        if showLyrics {
                            LyricsBox()
                                .frame(minHeight: 150, maxHeight: showLibrary ? 230 : .infinity)
                        }
                        libraryDisclosure
                        if showLibrary {
                            LibraryView(fillsHeight: true, embedded: true, availableWidth: inner, minColumnHeight: 230)
                                .frame(minHeight: 260, maxHeight: .infinity)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    if hero { Spacer(minLength: 0) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(alignment: .bottom) {
            StageSpectrum()
                .frame(height: 70)
                .allowsHitTesting(false)
                .mask(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .card(padding: 0)
        .frame(minHeight: Self.minHeight(library: showLibrary, lyrics: showLyrics, twoColumn: twoColumn))
        // Space toggles play/pause in this window. A text field being
        // edited takes the key first, and the visualizer has its own.
        .background {
            Button("") { player.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .animation(.spring(duration: 0.35), value: showLibrary)
        .animation(.spring(duration: 0.35), value: showLyrics)
    }

    /// What the widget needs before the deck should scroll.
    static func minHeight(library: Bool, lyrics: Bool, twoColumn: Bool) -> CGFloat {
        if twoColumn { return 440 }
        return 300 + (lyrics ? 170 : 0) + (library ? 300 : 0)
    }

    // MARK: Stage: scrubber, transport, speed, volume, switches

    private var stage: some View {
        VStack(spacing: 14) {
            Scrubber()
            controls
            if !isShort { switches }
        }
    }

    private var controls: some View {
        let idle = player.track == nil && queue.items.isEmpty
        let transport = HStack(spacing: 12) {
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

        return ViewThatFits(in: .horizontal) {
            // Wide: speed, transport and volume on one line.
            HStack(spacing: 0) {
                SpeedPill().frame(maxWidth: .infinity, alignment: .leading)
                transport
                VolumeControl().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(minWidth: 520)
            // Narrow: the transport alone, speed and volume under it.
            VStack(spacing: 12) {
                transport
                HStack(spacing: 14) {
                    SpeedPill()
                    VolumeControl()
                }
            }
        }
    }

    /// Lyrics, visualizer, queue and open: the toggles for what sits around
    /// the player.
    private var switches: some View {
        ViewThatFits(in: .horizontal) {
            switchRow(labels: true)
            switchRow(labels: false)
        }
    }

    private func switchRow(labels: Bool) -> some View {
        HStack(spacing: 8) {
            ChipToggle(symbol: "quote.bubble", title: "Lyrics", isOn: showLyrics, showsTitle: labels) {
                withAnimation(.spring(duration: 0.35)) { showLyrics.toggle() }
            }
            .help(showLyrics ? "Hide the lyrics  (⌥⌘L)" : "Show the lyrics  (⌥⌘L)")
            VisualizerToggle(showsTitle: labels)
            Spacer(minLength: 4)
            ChipToggle(symbol: "music.note.list", title: "Queue", isOn: false, showsTitle: labels) {
                openWindow(id: ZuujisMediaPlayerApp.playlistWindowID)
            }
            .help("Show the queue  (⇧⌘L)")
            ChipToggle(symbol: "folder", title: "Open", isOn: false, showsTitle: labels) {
                PlayerActions.openFiles(in: player)
            }
            .help("Open audio files or a folder  (⌘O)")
        }
    }

    /// The bar that opens and closes the library box.
    private var libraryDisclosure: some View {
        Button {
            withAnimation(.spring(duration: 0.35)) { showLibrary.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(showLibrary ? Theme.cyan : Theme.ink.opacity(0.6))
                Text("LIBRARY")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.3)
                    .foregroundStyle(Theme.ink.opacity(0.72))
                if !library.tracks.isEmpty {
                    Text("\(library.tracks.count) songs")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.42))
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .rotationEffect(.degrees(showLibrary ? 180 : 0))
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(showLibrary ? Theme.cyan.opacity(0.10) : Theme.ink.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(showLibrary ? Theme.cyan.opacity(0.35) : Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showLibrary ? "Collapse the library  (⌘L)" : "Expand the library  (⌘L)")
    }

    // MARK: Now playing

    private func nowPlaying(art: CGFloat) -> some View {
        HStack(spacing: art > 90 ? 16 : 14) {
            artwork(art)
            info(titleSize: art > 90 ? 21 : (art > 70 ? 18 : 16))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroNowPlaying: some View {
        VStack(spacing: 16) {
            artwork(min(220, max(120, min(inner * 0.5, height * 0.3))))
            info(titleSize: 24, centered: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func artwork(_ size: CGFloat) -> some View {
        let radius = max(10, size * 0.13)
        return Group {
            if let image = player.track?.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                // No cover: a tile in the track's own colour, so songs
                // without art still look different from one another.
                ZStack {
                    let tint = player.track.map { Theme.tint(for: $0.album ?? $0.title) }
                    LinearGradient(colors: tint.map { [$0.opacity(0.85), Theme.violet.opacity(0.35)] }
                                           ?? [Theme.ink.opacity(0.10), Theme.ink.opacity(0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.36, weight: .medium))
                        .foregroundStyle(player.track == nil ? Theme.ink.opacity(0.3) : Color.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                                         startPoint: .top, endPoint: .bottom)))
        .shadow(color: .black.opacity(Theme.palette.isLight ? 0.22 : 0.5), radius: size * 0.15, y: size * 0.07)
    }

    private func info(titleSize: CGFloat, centered: Bool = false) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 0) {
            if let track = player.track {
                eyebrow(player.state == .playing ? "Now Playing" : (player.state == .paused ? "Paused" : "Stopped"),
                        live: player.state == .playing)
                    .padding(.bottom, 6)

                HStack(spacing: 8) {
                    Text(track.title)
                        .font(.system(size: titleSize, weight: .bold))
                        .tracking(-0.3)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(centered ? 2 : 1)
                        .multilineTextAlignment(centered ? .center : .leading)
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
                    .font(.system(size: titleSize > 20 ? 13 : 12, weight: .medium))
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
                .padding(.top, 9)
            } else if let error = player.errorMessage {
                eyebrow("Could not play", live: false, tint: Theme.amber)
                    .padding(.bottom, 6)
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.amber)
                    .lineLimit(3)
            } else {
                eyebrow("Ready", live: false)
                    .padding(.bottom, 6)
                Text("Nothing playing")
                    .font(.system(size: titleSize, weight: .bold))
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
                .padding(.top, 9)
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
}

/// Player volume: the speaker button (mute / restore) and its slider.
struct VolumeControl: View {
    @EnvironmentObject private var player: PlayerEngine
    var sliderWidth: CGFloat = 110

    var body: some View {
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
                .frame(width: sliderWidth)
        }
        .help("Player volume  (⌘↑ / ⌘↓)")
    }
}

/// A small toggle chip: a symbol and, when there is room, its name.
struct ChipToggle: View {
    let symbol: String
    let title: String
    let isOn: Bool
    var showsTitle = true
    var tint: Color = Theme.cyan
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                if showsTitle {
                    Text(title).font(.system(size: 11.5, weight: .medium))
                }
            }
            .foregroundStyle(isOn ? tint : Theme.ink.opacity(hovering ? 0.95 : 0.7))
            .padding(.horizontal, showsTitle ? 11 : 0)
            .frame(width: showsTitle ? nil : 30, height: 28)
            .background(Capsule().fill(isOn ? tint.opacity(0.16) : Theme.ink.opacity(hovering ? 0.10 : 0.06)))
            .overlay(Capsule().strokeBorder(isOn ? tint.opacity(0.55) : Theme.ink.opacity(0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Opens and closes the visualizer's window. The window writes whether it is
/// open, so the chip lights while it is.
struct VisualizerToggle: View {
    var showsTitle = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(Panels.visualizerOpen) private var isOpen = false

    var body: some View {
        ChipToggle(symbol: "sparkles", title: "Visualizer", isOn: isOpen, showsTitle: showsTitle, tint: Theme.violet) {
            if isOpen { dismissWindow(id: ZuujisMediaPlayerApp.visualizerWindowID) }
            else { openWindow(id: ZuujisMediaPlayerApp.visualizerWindowID) }
        }
        .help(isOpen ? "Close the visualizer  (⇧⌘V)" : "Pop out the visualizer  (⇧⌘V)")
    }
}

// MARK: - EQ widget

/// The equalizer: power, presets, bypass, the preamp, and either the response
/// graph or the faders. The header folds to two lines when the widget is
/// narrow, and the bands, graph and faders share whatever height is left.
struct EQWidget: View {
    let width: CGFloat

    @EnvironmentObject private var engine: AudioEngine
    @AppStorage(Panels.eq) private var eqPanel = Panels.response
    @AppStorage(Panels.eqLast) private var eqLast = Panels.response

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            PreampRow()
            if eqPanel == Panels.equalizer {
                BandControlsView(embedded: true)
            } else {
                SpectrumView(embedded: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .card(padding: 0)
        .frame(minHeight: eqPanel == Panels.equalizer ? 400 : 380)
        .onChange(of: eqPanel) { _, now in if now != Panels.hidden { eqLast = now } }
        .onAppear { if eqPanel != Panels.hidden { eqLast = eqPanel } }
    }

    private var viewSwitch: some View {
        SegmentedPills(options: [(Panels.response, "Graph"), (Panels.equalizer, "Faders")],
                       selection: $eqPanel, height: 22, horizontalPadding: 10)
            .help("Show the response graph (⌘G) or the faders (⌘E)")
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            // One line.
            HStack(spacing: 10) {
                PowerButton()
                SectionTitle(text: "Equalizer", systemImage: "slider.vertical.3")
                PresetMenu()
                BypassButton()
                Spacer(minLength: 8)
                viewSwitch
                BandCountPicker()
            }
            // Two lines.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    PowerButton()
                    SectionTitle(text: "Equalizer", systemImage: "slider.vertical.3")
                    Spacer(minLength: 8)
                    viewSwitch
                    BandCountPicker()
                }
                HStack(spacing: 10) {
                    PresetMenu()
                    BypassButton()
                    Spacer(minLength: 0)
                }
            }
            // Three, for a very narrow widget.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    PowerButton()
                    SectionTitle(text: "Equalizer", systemImage: "slider.vertical.3")
                    Spacer(minLength: 8)
                    BypassButton()
                }
                HStack(spacing: 10) {
                    PresetMenu()
                    Spacer(minLength: 0)
                    BandCountPicker()
                }
                HStack { viewSwitch; Spacer(minLength: 0) }
            }
        }
    }
}
