// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Which of the main window's cards are showing. Each is one switch in the
/// header, the View menu and (for lyrics) the player; hiding one gives its
/// space to the others.
enum Panels {
    static let library = "showLibrary"
    /// The lyrics card.
    static let lyrics = "showLyrics"
    /// Which EQ view shows: the response graph, the faders, or neither.
    static let eq = "eqPanel"
    static let response = "response"
    static let equalizer = "faders"
    static let hidden = "none"
    /// Whether the visualizer's window is open (written by the window).
    static let visualizerOpen = "visualizerOpen"

    /// The cards that are switched on, for `WindowLayout.arrange`.
    static func visibleCards(library: Bool, lyrics: Bool, eq: String) -> Set<WindowLayout.Card> {
        var cards = Set<WindowLayout.Card>()
        if library { cards.insert(.library) }
        if lyrics { cards.insert(.lyrics) }
        if eq != hidden { cards.insert(.eq) }
        return cards
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
            .accessibilityLabel(player.volume < 0.01 ? "Unmute" : "Mute")
            GlowSlider(value: Binding(get: { Double(player.volume) },
                                      set: { player.volume = Float($0) }),
                       label: "Volume")
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
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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


// MARK: - Live layer

/// Hosts a meter display (a `TimelineView` + `Canvas` that redraws 30 times a
/// second) in its own `NSHostingView`. Inside the main window's hosting view,
/// every frame of such a view made SwiftUI lay out the whole window, so the
/// window's cost grew with every panel shown (about 20% CPU for the faders'
/// backdrop alone). Here its frames update only this small view.
///
/// A display-only layer passes every click through to the controls drawn
/// underneath; an `interactive` one (the scrubber) takes clicks and reports
/// the height its content needs. Environment objects do not cross into a separate
/// hosting view, so the ones the meter views read are passed in here. The
/// wrapper does not observe `MeterState`, or its own update would run on
/// every meter reading and defeat the point.
struct LiveLayer<Content: View>: NSViewRepresentable {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var player: PlayerEngine
    var interactive = false
    let content: Content

    init(interactive: Bool = false, @ViewBuilder content: () -> Content) {
        self.interactive = interactive
        self.content = content()
    }

    func makeNSView(context: Context) -> LiveHostingView<AnyView> {
        let host = LiveHostingView(rootView: root)
        host.passesClicks = !interactive
        host.sizingOptions = []
        return host
    }

    func updateNSView(_ host: LiveHostingView<AnyView>, context: Context) {
        host.rootView = root
    }

    /// Display layers fill what they are offered; an interactive one takes
    /// the offered width and its content's own height.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView host: LiveHostingView<AnyView>, context: Context) -> CGSize? {
        guard interactive else { return nil }
        // Measured once: `fittingSize` lays the content out, and doing that on
        // every pass tied the main window's layout to this layer again.
        if host.fittedHeight == nil { host.fittedHeight = host.fittingSize.height }
        return CGSize(width: proposal.width ?? 300, height: host.fittedHeight ?? 20)
    }

    private var root: AnyView {
        AnyView(content
            .environmentObject(engine)
            .environmentObject(engine.meters)
            .environmentObject(player)
            // The theme is read from `Theme.palette`, but the colour scheme
            // is environment and does not cross over by itself.
            .preferredColorScheme(Theme.scheme))
    }
}

/// The host of a `LiveLayer`; a display layer never takes a click.
final class LiveHostingView<Content: View>: NSHostingView<Content> {
    var passesClicks = true
    /// An interactive layer's height, measured the first time it is asked.
    var fittedHeight: CGFloat?
    override func hitTest(_ point: NSPoint) -> NSView? {
        passesClicks ? nil : super.hitTest(point)
    }
}
