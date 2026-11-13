// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct MainView: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var presets: PresetManager
    @EnvironmentObject private var player: PlayerEngine
    @AppStorage(Panels.library) private var showLibrary = true
    @AppStorage(Panels.lyrics) private var showLyrics = true
    @AppStorage(Panels.eq) private var eqPanel = Panels.response
    @AppStorage(ThemePalette.storageKey) private var themeID = ThemePalette.midnight.id
    // The arrangement, edited in Settings.
    @AppStorage(WindowLayout.orderKey) private var order = WindowLayout.defaultOrder
    @AppStorage(WindowLayout.placementKey) private var placement = WindowLayout.Placement.auto.rawValue
    @AppStorage(WindowLayout.fillKey) private var fill = WindowLayout.autoFill
    @AppStorage(WindowLayout.lyricsWidthKey) private var lyricsWidth = WindowLayout.defaultLyricsWidth
    @AppStorage(WindowLayout.lyricsHeightKey) private var lyricsHeight = WindowLayout.defaultLyricsHeight
    @AppStorage(WindowLayout.libraryHeightKey) private var libraryHeight = WindowLayout.defaultLibraryHeight
    @AppStorage(WindowLayout.eqHeightKey) private var eqHeight = WindowLayout.defaultEQHeight
    @AppStorage(WindowLayout.compactStageKey) private var compactStage = false
    @AppStorage(WindowLayout.stageSpectrumKey) private var stageSpectrum = true

    /// The smallest the window goes. Below the cards' own minimums the
    /// content scrolls.
    static let minSize = CGSize(width: 620, height: 460)

    var body: some View {
        let _ = Theme.apply(themeID)
        GeometryReader { root in
            VStack(spacing: 0) {
                HeaderBar()
                PlayerBar(width: root.size.width, isShort: root.size.height < 600 || compactStage,
                          showsSpectrum: stageSpectrum)
                // The cards stretch to fill whatever height the window has; the
                // scroll view only matters once their minimums outgrow it.
                GeometryReader { geo in
                    ScrollView {
                        cards(width: geo.size.width - 32)
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                            .padding(.bottom, 16)
                            .frame(minHeight: geo.size.height)
                    }
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
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        // Up into the hidden title bar, so the header shares its row with
        // the traffic lights instead of sitting under an empty strip.
        .ignoresSafeArea(.container, edges: .top)
        .background(
            ZStack {
                AmbientBackground()
                ArtworkWash()
            }
            .ignoresSafeArea()
        )
        .preferredColorScheme(Theme.scheme)
        // Stock controls (switches, text selection) take the theme's accent.
        .tint(Theme.cyan)
        // Rebuild on a theme change so every view reads the new palette.
        .id(themeID)
    }

    /// Library, lyrics and the EQ in the order, places and sizes chosen in
    /// Settings (`WindowLayout`). By default the lyrics sit beside the top
    /// card when there is room and go into the stack when there is not.
    @ViewBuilder
    private func cards(width: CGFloat) -> some View {
        let plan = WindowLayout.arrange(order: order, placement: placement, fill: fill, lyricsWidth: lyricsWidth,
                                        visible: Panels.visibleCards(library: showLibrary, lyrics: showLyrics, eq: eqPanel),
                                        width: width)
        let side = CGFloat(plan.lyricsWidth)
        if plan.stack.isEmpty {
            AllPanelsHidden()
        } else {
            switch plan.side {
            case .none:
                stack(plan, width: width, besideTop: false)
            case .besideTop:
                stack(plan, width: width, besideTop: true)
            case .column(let leading):
                HStack(alignment: .top, spacing: 14) {
                    if leading { LyricsCard().frame(width: side).frame(maxHeight: .infinity) }
                    stack(plan, width: width - side - 14, besideTop: false)
                        .frame(maxHeight: .infinity, alignment: .top)
                    if !leading { LyricsCard().frame(width: side).frame(maxHeight: .infinity) }
                }
            }
        }
    }

    /// The cards top to bottom. With `besideTop` the lyrics share the first
    /// card's row.
    private func stack(_ plan: WindowLayout.Arrangement, width: CGFloat, besideTop: Bool) -> some View {
        let side = CGFloat(plan.lyricsWidth)
        return VStack(spacing: 14) {
            ForEach(plan.stack) { card in
                if besideTop, card == plan.stack.first {
                    HStack(alignment: .top, spacing: 14) {
                        self.card(card, fills: plan.fill == card, width: width - side - 14)
                            .frame(maxHeight: .infinity, alignment: .top)
                        LyricsCard().frame(width: side).frame(maxHeight: .infinity)
                    }
                    // A card of a set height sets the row's: the lyrics end
                    // level with it instead of running on below.
                    .fixedSize(horizontal: false, vertical: plan.fill != card && hasSetHeight(card))
                    .frame(maxHeight: plan.fill == card ? .infinity : nil)
                } else {
                    self.card(card, fills: plan.fill == card, width: width)
                }
            }
        }
    }

    /// The faders have a range of heights, not one.
    private func hasSetHeight(_ card: WindowLayout.Card) -> Bool {
        card == .library || (card == .eq && eqPanel == Panels.response)
    }

    /// One card at the size Settings gives it; the one that `fills` takes
    /// the window's spare height instead.
    @ViewBuilder
    private func card(_ card: WindowLayout.Card, fills: Bool, width: CGFloat) -> some View {
        switch card {
        case .library:
            LibraryView(fillsHeight: fills, availableWidth: width, columnHeight: CGFloat(libraryHeight))
        case .lyrics:
            let height = CGFloat(lyricsHeight)
            if fills {
                LyricsCard().frame(minHeight: min(260, height), maxHeight: .infinity)
            } else {
                LyricsCard().frame(height: height)
            }
        case .eq:
            if eqPanel == Panels.response {
                SpectrumView(graphHeight: fills ? nil : CGFloat(eqHeight))
            } else {
                BandControlsView(rowMaxHeight: CGFloat(eqHeight)).frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Panel switches

struct PanelToggles: View {
    @AppStorage(Panels.library) private var showLibrary = true
    @AppStorage(Panels.lyrics) private var showLyrics = true
    @AppStorage(Panels.eq) private var eqPanel = Panels.response

    /// The EQ is shown as the response graph or as faders, never both; the
    /// button for the one showing hides it. The four sit in one capsule.
    var body: some View {
        HStack(spacing: 2) {
            toggle("books.vertical.fill", isOn: $showLibrary, name: "Library", key: "⌘L")
            toggle("quote.bubble.fill", isOn: $showLyrics, name: "Lyrics", key: "⌥⌘L")
            toggle("waveform.path.ecg", isOn: choice(Panels.response), name: "Response graph", key: "⌘G")
            toggle("slider.vertical.3", isOn: choice(Panels.equalizer), name: "Equalizer faders", key: "⌘E")
        }
        .padding(3)
        .background(Capsule().fill(Theme.ink.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.10)))
    }

    private func choice(_ value: String) -> Binding<Bool> {
        Binding(get: { eqPanel == value },
                set: { eqPanel = $0 ? value : Panels.hidden })
    }

    private func toggle(_ symbol: String, isOn: Binding<Bool>, name: String, key: String) -> some View {
        Button {
            withAnimation(.spring(duration: 0.3)) { isOn.wrappedValue.toggle() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? Theme.cyan : Theme.ink.opacity(0.42))
                .frame(width: 34, height: 24)
                .background(Capsule().fill(isOn.wrappedValue ? Theme.cyan.opacity(0.18) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help((isOn.wrappedValue ? "Hide the \(name.lowercased())" : "Show the \(name.lowercased())") + "  (\(key))")
    }
}

/// Shown when every panel is switched off, so the window is not just blank.
struct AllPanelsHidden: View {
    @AppStorage(Panels.library) private var showLibrary = true

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 30))
                .foregroundStyle(Theme.ink.opacity(0.28))
            Text("Everything is hidden")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.75))
            Text("Bring a panel back from the View menu or the switches in the header.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink.opacity(0.45))
            Button {
                withAnimation(.spring(duration: 0.3)) { showLibrary = true }
            } label: {
                Text("Show Library")
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

// MARK: - Header Bar

/// The brand, the widget switches, the output device and the theme; there is
/// no sidebar. The window has no title bar of its own — this row is drawn up
/// into it, which is why it starts clear of the traffic lights. It has no
/// fill: the window's backdrop shows through. It sheds its labels as the
/// window narrows.
struct HeaderBar: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var meters: MeterState
    @EnvironmentObject private var presets: PresetManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(brandText: true, compact: false)
            row(brandText: false, compact: false)
            row(brandText: false, compact: true)
        }
        .padding(.leading, 84)
        .padding(.trailing, 16)
        .frame(height: 52)
    }

    private func row(brandText: Bool, compact: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                BrandMark()
                if brandText {
                    HStack(spacing: 6) {
                        Text("Zuujis").font(.system(size: 14, weight: .bold))
                        Text("Media Player").font(.system(size: 14, weight: .regular))
                    }
                    .foregroundStyle(Theme.ink.opacity(0.92))
                    .fixedSize()
                    statusLine
                }
            }

            Spacer(minLength: 8)

            PanelToggles()
            DeviceMenu(compact: compact)

            do {
                Button {
                    openWindow(id: ZuujisMediaPlayerApp.visualizerWindowID)
                } label: {
                    Label("Visualizer", systemImage: "sparkles")
                        .labelStyle(OptionalTitleLabelStyle(showsTitle: !compact))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.onSignal)
                        .padding(.horizontal, 13)
                        .frame(height: 30)
                        .background(Capsule().fill(Theme.signal))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.28)))
                        .shadow(color: Theme.violet.opacity(0.45), radius: 8, y: 1)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Open the visualizer  (⇧⌘V)")
            }

            ThemeMenu()
            StatusMenu()
        }
    }

    /// Only a route error shows; the on/off state is the power button's job.
    @ViewBuilder
    private var statusLine: some View {
        if let error = engine.routeErrorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.amber)
                .lineLimit(1)
                .padding(.leading, 6)
        }
    }
}

/// The app's mark in the header: the icon's play triangle on the signal gradient.
struct BrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: Theme.signalColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .offset(x: size * 0.03)
                    .foregroundStyle(Theme.onSignal)
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
            .frame(width: size, height: size)
            .shadow(color: Theme.violet.opacity(0.5), radius: 6, y: 1)
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
                .foregroundStyle(engine.isBypassed ? Theme.amber : Theme.ink.opacity(0.85))
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
                    .fill(engine.isRunning ? Theme.mint.opacity(0.18) : Theme.ink.opacity(0.06))
                Circle()
                    .strokeBorder(engine.isRunning ? Theme.mint.opacity(0.9) : Theme.ink.opacity(0.18),
                                  lineWidth: 1.5)
                Image(systemName: "power")
                    .font(.system(size: size * 0.41, weight: .bold))
                    .foregroundStyle(engine.isRunning ? Theme.mint : Theme.ink.opacity(0.6))
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
