// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The Settings window (⌘,): how the main window is arranged, what the
/// desktop widgets show, and the app-wide switches that otherwise live in
/// menus. Every pane has a live preview, and every control writes straight to
/// the same saved values the rest of the app reads, so changes show at once
/// and there is nothing to apply.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case layout, widgets, general
        var id: String { rawValue }
        var title: String {
            switch self {
            case .layout: return "Window Layout"
            case .widgets: return "Desktop Widgets"
            case .general: return "General"
            }
        }
        var symbol: String {
            switch self {
            case .layout: return "rectangle.3.group"
            case .widgets: return "square.grid.2x2"
            case .general: return "gearshape"
            }
        }
        var blurb: String {
            switch self {
            case .layout: return "Where the library, lyrics and equalizer sit, and how big each one is."
            case .widgets: return "What the Equalizer and Now Playing widgets show on the desktop."
            case .general: return "Theme, startup, lyrics and output."
            }
        }
    }

    @AppStorage("settingsPane") private var paneID = Pane.layout.rawValue
    @AppStorage(ThemePalette.storageKey) private var themeID = ThemePalette.midnight.id

    private var pane: Pane { Pane(rawValue: paneID) ?? .layout }

    var body: some View {
        let _ = Theme.apply(themeID)
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pane.title)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.ink)
                        Text(pane.blurb)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink.opacity(0.55))
                    }
                    .padding(.bottom, 2)
                    switch pane {
                    case .layout: LayoutSettingsPane()
                    case .widgets: WidgetSettingsPane()
                    case .general: GeneralSettingsPane()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 880, height: 680)
        .background(AmbientBackground().ignoresSafeArea())
        .preferredColorScheme(Theme.scheme)
        .tint(Theme.cyan)
        .id(themeID)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                BrandMark(size: 24)
                Text("Settings")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.92))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 14)

            ForEach(Pane.allCases) { item in
                let on = item == pane
                Button {
                    paneID = item.rawValue
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(on ? Theme.cyan : Theme.ink.opacity(0.55))
                            .frame(width: 20)
                        Text(item.title)
                            .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                            .foregroundStyle(Theme.ink.opacity(on ? 0.95 : 0.7))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(on ? Theme.cyan.opacity(0.14) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(on ? Theme.cyan.opacity(0.4) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Text("Changes are saved as you make them.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink.opacity(0.4))
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 18)
        .frame(width: 206)
        .background(Theme.ink.opacity(Theme.palette.isLight ? 0.035 : 0.025))
    }
}

// MARK: - Building blocks

/// A titled card of settings rows.
private struct SettingsGroup<Content: View, Accessory: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: title, systemImage: symbol)
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
        .card()
    }
}

extension SettingsGroup where Accessory == EmptyView {
    init(title: String, symbol: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, symbol: symbol, accessory: { EmptyView() }, content: content)
    }
}

/// A name and a line of explanation on the left, the control on the right.
private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var dimmed = false
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.9))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .opacity(dimmed ? 0.4 : 1)
        .disabled(dimmed)
    }
}

/// A switch row.
private struct SwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

/// A size in points: slider, the number, and a way back to the default.
private struct SizeRow: View {
    let title: String
    var detail: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let standard: Double
    var dimmed = false

    var body: some View {
        SettingsRow(title: title, detail: detail, dimmed: dimmed) {
            HStack(spacing: 10) {
                GlowSlider(value: $value, range: range, step: 10)
                    .frame(width: 210)
                Text("\(Int(value)) pt")
                    .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.75))
                    .frame(width: 50, alignment: .trailing)
                Button { withAnimation(.spring(duration: 0.3)) { value = standard } } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.ink.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.ink.opacity(0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(value == standard ? 0 : 1)
                .help("Back to \(Int(standard)) pt")
            }
        }
    }
}

private struct RowDivider: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

/// A small text button in the app's pill style.
private struct PillButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Theme.ink.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Theme.ink.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Up and down arrows for a row in an ordered list.
private struct MoveButtons: View {
    let canUp: Bool
    let canDown: Bool
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            arrow("chevron.up", enabled: canUp) { move(-1) }
            arrow("chevron.down", enabled: canDown) { move(1) }
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(enabled ? 0.75 : 0.2))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Window layout

private struct LayoutSettingsPane: View {
    @AppStorage(Panels.library) private var showLibrary = true
    @AppStorage(Panels.lyrics) private var showLyrics = true
    @AppStorage(Panels.eq) private var eqPanel = Panels.response
    @AppStorage(WindowLayout.orderKey) private var order = WindowLayout.defaultOrder
    @AppStorage(WindowLayout.placementKey) private var placement = WindowLayout.Placement.auto.rawValue
    @AppStorage(WindowLayout.fillKey) private var fill = WindowLayout.autoFill
    @AppStorage(WindowLayout.lyricsWidthKey) private var lyricsWidth = WindowLayout.defaultLyricsWidth
    @AppStorage(WindowLayout.lyricsHeightKey) private var lyricsHeight = WindowLayout.defaultLyricsHeight
    @AppStorage(WindowLayout.libraryHeightKey) private var libraryHeight = WindowLayout.defaultLibraryHeight
    @AppStorage(WindowLayout.eqHeightKey) private var eqHeight = WindowLayout.defaultEQHeight
    @AppStorage(WindowLayout.compactStageKey) private var compactStage = false
    @AppStorage(WindowLayout.stageSpectrumKey) private var stageSpectrum = true
    @State private var previewWidth = 1240.0

    private var visible: Set<WindowLayout.Card> {
        Panels.visibleCards(library: showLibrary, lyrics: showLyrics, eq: eqPanel)
    }

    private var isDefault: Bool {
        order == WindowLayout.defaultOrder && placement == WindowLayout.Placement.auto.rawValue
            && fill == WindowLayout.autoFill && lyricsWidth == WindowLayout.defaultLyricsWidth
            && lyricsHeight == WindowLayout.defaultLyricsHeight && libraryHeight == WindowLayout.defaultLibraryHeight
            && eqHeight == WindowLayout.defaultEQHeight && !compactStage && stageSpectrum
    }

    var body: some View {
        let plan = WindowLayout.arrange(order: order, placement: placement, fill: fill, lyricsWidth: lyricsWidth,
                                        visible: visible, width: previewWidth - 32)

        SettingsGroup(title: "Preview", symbol: "eye", accessory: {
            SegmentedPills(options: [(1240.0, "Wide window"), (900.0, "Medium"), (640.0, "Narrow")],
                           selection: $previewWidth, height: 22, horizontalPadding: 10)
        }) {
            LayoutPreview(plan: plan, windowWidth: previewWidth, eqPanel: eqPanel, compactStage: compactStage,
                          showsSpectrum: stageSpectrum, libraryHeight: libraryHeight,
                          lyricsHeight: lyricsHeight, eqHeight: eqHeight)
                .frame(height: 250)
                .animation(.spring(duration: 0.35), value: plan)
                .animation(.spring(duration: 0.35), value: previewWidth)
            Text(previewNote(plan))
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.5))
        }

        SettingsGroup(title: "Panels", symbol: "square.stack.3d.up") {
            let cards = WindowLayout.cards(order)
            ForEach(Array(cards.enumerated()), id: \.element) { index, card in
                if index > 0 { RowDivider() }
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.ink.opacity(0.4))
                        .frame(width: 14)
                    Image(systemName: card.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LayoutPreview.tint(card))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.ink.opacity(visible.contains(card) ? 0.9 : 0.45))
                        Text(caption(card))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ink.opacity(0.5))
                    }
                    Spacer(minLength: 8)
                    switch card {
                    case .library:
                        Toggle("", isOn: $showLibrary).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    case .lyrics:
                        Toggle("", isOn: $showLyrics).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    case .eq:
                        SegmentedPills(options: [(Panels.response, "Graph"), (Panels.equalizer, "Faders"), (Panels.hidden, "Off")],
                                       selection: $eqPanel, height: 22, horizontalPadding: 10)
                    }
                    MoveButtons(canUp: index > 0, canDown: index < cards.count - 1) { delta in
                        withAnimation(.spring(duration: 0.3)) { order = WindowLayout.moving(card, by: delta, in: order) }
                    }
                }
            }
        }

        SettingsGroup(title: "Lyrics", symbol: "quote.bubble") {
            SettingsRow(title: "Position", detail: placementDetail) {
                SegmentedPills(options: [(WindowLayout.Placement.auto.rawValue, "Automatic"),
                                         (WindowLayout.Placement.left.rawValue, "Left column"),
                                         (WindowLayout.Placement.right.rawValue, "Right column"),
                                         (WindowLayout.Placement.stacked.rawValue, "In the stack")],
                               selection: $placement, height: 22, horizontalPadding: 10)
            }
            RowDivider()
            SizeRow(title: "Width at the side", value: $lyricsWidth, range: WindowLayout.lyricsWidthRange,
                    standard: WindowLayout.defaultLyricsWidth, dimmed: placement == WindowLayout.Placement.stacked.rawValue)
            SizeRow(title: "Height in the stack", detail: "Used when another panel takes the spare room.",
                    value: $lyricsHeight, range: WindowLayout.lyricsHeightRange, standard: WindowLayout.defaultLyricsHeight)
        }

        SettingsGroup(title: "Sizes", symbol: "arrow.up.and.down") {
            SizeRow(title: "Library height", detail: "The artist, album and song columns.",
                    value: $libraryHeight, range: WindowLayout.libraryHeightRange, standard: WindowLayout.defaultLibraryHeight)
            SizeRow(title: "Equalizer height", detail: "The response graph, or how tall the faders may grow.",
                    value: $eqHeight, range: WindowLayout.eqHeightRange, standard: WindowLayout.defaultEQHeight)
            RowDivider()
            SettingsRow(title: "Spare room goes to",
                        detail: "The panel that stretches when the window is taller than its panels need.") {
                SegmentedPills(options: [(WindowLayout.autoFill, "Automatic")]
                               + WindowLayout.Card.allCases.map { ($0.rawValue, $0.name) },
                               selection: $fill, height: 22, horizontalPadding: 10)
            }
        }

        SettingsGroup(title: "Now Playing bar", symbol: "play.rectangle") {
            SwitchRow(title: "Compact", detail: "A smaller cover and a shorter bar, leaving more room for the panels.",
                      isOn: $compactStage)
            SwitchRow(title: "Live spectrum behind it", detail: "Shown when the window is wide enough for one row.",
                      isOn: $stageSpectrum)
        }

        HStack {
            Spacer()
            PillButton(title: "Reset Layout", symbol: "arrow.counterclockwise") {
                withAnimation(.spring(duration: 0.35)) {
                    WindowLayout.allKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
                }
            }
            .opacity(isDefault ? 0.4 : 1)
            .disabled(isDefault)
        }
    }

    private var placementDetail: String {
        switch WindowLayout.Placement(rawValue: placement) ?? .auto {
        case .auto: return "Beside the top panel in a wide window, in the stack in a narrow one."
        case .left, .right: return "A full-height column. Goes into the stack when the window is very narrow."
        case .stacked: return "Always at its place in the order above."
        }
    }

    private func caption(_ card: WindowLayout.Card) -> String {
        switch card {
        case .library: return showLibrary ? "Artists, genres and playlists" : "Hidden"
        case .lyrics: return showLyrics ? "The words, following the song" : "Hidden"
        case .eq: return eqPanel == Panels.hidden ? "Hidden" : (eqPanel == Panels.response ? "The response graph" : "One fader per band")
        }
    }

    private func previewNote(_ plan: WindowLayout.Arrangement) -> String {
        guard !plan.stack.isEmpty else { return "Every panel is hidden." }
        let filler = plan.fill.map { "\($0.name) takes the spare room." } ?? ""
        switch plan.side {
        case .none: return "Top to bottom: " + plan.stack.map(\.name).joined(separator: ", ") + ". " + filler
        case .besideTop: return "Lyrics beside \(plan.stack[0].name) at this width. " + filler
        case .column(let leading): return "Lyrics in a column on the \(leading ? "left" : "right"). " + filler
        }
    }
}

/// The main window in miniature, drawn from the same `WindowLayout.arrange`
/// result the real window uses.
private struct LayoutPreview: View {
    let plan: WindowLayout.Arrangement
    let windowWidth: Double
    let eqPanel: String
    let compactStage: Bool
    let showsSpectrum: Bool
    let libraryHeight: Double
    let lyricsHeight: Double
    let eqHeight: Double

    private static let windowHeight = 900.0

    static func tint(_ card: WindowLayout.Card) -> Color {
        switch card {
        case .library: return Theme.cyan
        case .lyrics: return Theme.pink
        case .eq: return Theme.violet
        }
    }

    private struct Block: Identifiable {
        let card: WindowLayout.Card
        let rect: CGRect
        let fills: Bool
        var id: String { card.rawValue }
    }

    private var stageHeight: Double {
        windowWidth >= 900 ? (compactStage ? 112 : 140) : (windowWidth >= 690 ? (compactStage ? 160 : 190) : 290)
    }

    /// Roughly what each card needs: its content plus its header and padding.
    private func natural(_ card: WindowLayout.Card) -> Double {
        switch card {
        case .library: return libraryHeight + 84
        case .lyrics: return lyricsHeight
        case .eq: return eqPanel == Panels.response ? eqHeight + 84 : eqHeight + 150
        }
    }

    private var blocks: [Block] {
        let gap = 14.0
        let top = 52 + stageHeight + 6
        let left = 16.0
        let room = Self.windowHeight - top - 16
        let width = windowWidth - 32
        let side = plan.lyricsWidth
        var stackX = left, stackWidth = width
        var result: [Block] = []
        if case .column(let leading) = plan.side {
            stackWidth = width - side - gap
            if leading { stackX = left + side + gap }
            result.append(Block(card: .lyrics, rect: CGRect(x: leading ? left : left + stackWidth + gap, y: top,
                                                            width: side, height: room), fills: false))
        }
        // Fixed cards take what they need, the filling one the rest; if that
        // is more than the window has, everything shrinks (the real window scrolls).
        let fixed = plan.stack.filter { $0 != plan.fill }.map(natural).reduce(0, +)
        let gaps = gap * Double(max(0, plan.stack.count - 1))
        let fillHeight = max(150, room - fixed - gaps)
        let total = fixed + gaps + (plan.fill == nil ? 0 : fillHeight)
        let squeeze = min(1, room / max(1, total))
        var y = top
        for (index, card) in plan.stack.enumerated() {
            let height = (card == plan.fill ? fillHeight : natural(card)) * squeeze
            var rect = CGRect(x: stackX, y: y, width: stackWidth, height: height)
            if index == 0, plan.side == .besideTop {
                rect.size.width = stackWidth - side - gap
                result.append(Block(card: .lyrics, rect: CGRect(x: stackX + rect.width + gap, y: y, width: side, height: height),
                                    fills: false))
            }
            result.append(Block(card: card, rect: rect, fills: card == plan.fill && plan.stack.count > 1))
            y += height + gap * squeeze
        }
        return result
    }

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / windowWidth, geo.size.height / Self.windowHeight)
            let size = CGSize(width: windowWidth * scale, height: Self.windowHeight * scale)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.backgroundTop, Theme.backgroundBottom], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.ink.opacity(0.18))

                // Traffic lights and the header's controls.
                HStack(spacing: 3.5) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.ink.opacity(0.25)).frame(width: 5, height: 5) }
                    Spacer()
                    Capsule().fill(Theme.ink.opacity(0.12)).frame(width: 46, height: 6)
                    Capsule().fill(Theme.signal).frame(width: 24, height: 6)
                }
                .padding(.horizontal, 9)
                .frame(width: size.width, height: 52 * scale)

                stage(scale: scale)
                    .frame(width: (windowWidth - 40) * scale, height: (stageHeight - 16) * scale)
                    .offset(x: 20 * scale, y: (52 + 8) * scale)

                ForEach(blocks) { block in
                    cardBlock(block)
                        .frame(width: block.rect.width * scale, height: block.rect.height * scale)
                        .offset(x: block.rect.minX * scale, y: block.rect.minY * scale)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stage(scale: Double) -> some View {
        let art = min(104.0, stageHeight - 36) * (compactStage ? 0.72 : 1) * scale
        return ZStack(alignment: .bottom) {
            if showsSpectrum, windowWidth >= 900 {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<28, id: \.self) { i in
                        let level = 0.25 + 0.75 * abs(sin(Double(i) * 0.9) * cos(Double(i) * 0.37))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.signalColor(at: Double(i) / 27).opacity(0.28))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(2, level * 60 * scale))
                    }
                }
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(colors: Theme.signalColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: art, height: art)
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(Theme.ink.opacity(0.6)).frame(width: 60, height: 4)
                    Capsule().fill(Theme.ink.opacity(0.3)).frame(width: 40, height: 3)
                }
                Spacer(minLength: 4)
                Circle().fill(Theme.signal).frame(width: 13, height: 13)
                Spacer(minLength: 4)
                Capsule().fill(Theme.ink.opacity(0.2)).frame(width: 34, height: 3)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func cardBlock(_ block: Block) -> some View {
        let tint = Self.tint(block.card)
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.16))
            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(tint.opacity(0.6))
            VStack(spacing: 3) {
                Image(systemName: block.card.symbol).font(.system(size: 11, weight: .semibold))
                Text(block.card.name).font(.system(size: 9.5, weight: .semibold))
                if block.fills {
                    Text("STRETCHES")
                        .font(.system(size: 6.5, weight: .heavy)).tracking(0.6)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(Capsule().fill(tint.opacity(0.25)))
                }
            }
            .foregroundStyle(tint)
            .padding(2)
        }
    }
}

// MARK: - Desktop widgets

private struct WidgetSettingsPane: View {
    @EnvironmentObject private var store: WidgetSettingsStore
    @EnvironmentObject private var presets: PresetManager
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var player: PlayerEngine
    @State private var eqSize = WidgetMock.Size.large
    @State private var playerSize = WidgetMock.Size.medium

    private var all: [String] { presets.allPresets.map(\.name) }
    private var offered: [String] { store.settings.offeredPresets(from: all) }

    private static let sizeOptions: [(value: String, label: String)] =
        [("compact", "Compact"), ("regular", "Regular"), ("large", "Large")]

    var body: some View {
        let s = store.settings

        SettingsGroup(title: "Equalizer widget", symbol: "slider.vertical.3", accessory: {
            SegmentedPills(options: WidgetMock.Size.allCases.map { ($0, $0.label) }, selection: $eqSize,
                           height: 22, horizontalPadding: 10)
        }) {
            WidgetMock.Frame(size: eqSize) {
                EQWidgetMock(settings: s, presets: offered, selected: presets.selectedPreset?.name ?? "",
                             isOn: engine.isRunning, bypassed: engine.isBypassed, preamp: engine.amplificationDB,
                             tone: tone, size: eqSize)
            }
            .animation(.spring(duration: 0.3), value: s)
            .animation(.spring(duration: 0.3), value: eqSize)

            RowDivider()
            SettingsRow(title: "Small widget shows") {
                SegmentedPills(options: [("preamp", "Preamp and bypass"), ("presets", "Presets")],
                               selection: $store.settings.eqSmall, height: 22, horizontalPadding: 10)
            }
            SettingsRow(title: "Medium widget shows") {
                SegmentedPills(options: [("tone", "Bass, mid, treble, preamp"), ("presets", "Presets")],
                               selection: $store.settings.eqMedium, height: 22, horizontalPadding: 10)
            }
            SwitchRow(title: "Tone controls on the large widget",
                      detail: "Off leaves the whole widget to presets.", isOn: $store.settings.eqLargeTone)
            SettingsRow(title: "Large widget order", dimmed: !s.eqLargeTone) {
                SegmentedPills(options: [(false, "Tone, then presets"), (true, "Presets, then tone")],
                               selection: $store.settings.eqPresetsFirst, height: 22, horizontalPadding: 10)
            }
            RowDivider()
            SettingsRow(title: "Presets per row", detail: "On the medium and large widgets.") {
                SegmentedPills(options: [(2, "2"), (3, "3"), (4, "4")], selection: $store.settings.eqColumns,
                               height: 22, horizontalPadding: 12)
            }
            SettingsRow(title: "Button size") {
                SegmentedPills(options: Self.sizeOptions, selection: $store.settings.eqSize, height: 22, horizontalPadding: 10)
            }
            SettingsRow(title: "One tap of − or + changes", detail: "Bass, mid, treble and the preamp.") {
                SegmentedPills(options: [(0.5, "0.5 dB"), (1.0, "1 dB"), (2.0, "2 dB"), (3.0, "3 dB")],
                               selection: $store.settings.eqStep, height: 22, horizontalPadding: 10)
            }
        }

        SettingsGroup(title: "Presets on the widget", symbol: "square.stack.3d.up", accessory: {
            PillButton(title: "Show All", symbol: "arrow.counterclockwise") {
                withAnimation(.spring(duration: 0.3)) { store.settings.eqPresets = [] }
            }
            .opacity(s.eqPresets.isEmpty ? 0.4 : 1)
            .disabled(s.eqPresets.isEmpty)
        }) {
            Text(capacityNote)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            let fits = EQWidgetMock.capacity(settings: s, size: .large)
            VStack(spacing: 0) {
                ForEach(Array(offered.enumerated()), id: \.element) { index, name in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Theme.ink.opacity(0.4))
                            .frame(width: 18, alignment: .trailing)
                        Text(name)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.ink.opacity(index < fits ? 0.9 : 0.45))
                            .lineLimit(1)
                        if name == presets.selectedPreset?.name {
                            Text("IN USE")
                                .font(.system(size: 8, weight: .heavy)).tracking(0.8)
                                .foregroundStyle(Theme.mint)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.mint.opacity(0.14)))
                        }
                        if index >= fits {
                            Text("does not fit")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.ink.opacity(0.4))
                        }
                        Spacer(minLength: 8)
                        MoveButtons(canUp: index > 0, canDown: index < offered.count - 1) { delta in
                            withAnimation(.spring(duration: 0.3)) { store.movePreset(name, by: delta, all: all) }
                        }
                        Button {
                            withAnimation(.spring(duration: 0.3)) { store.togglePreset(name, all: all) }
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.ink.opacity(0.7))
                                .frame(width: 24, height: 22)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(0.07)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(offered.count <= 1)
                        .opacity(offered.count <= 1 ? 0.3 : 1)
                        .help("Take \(name) off the widget")
                    }
                    .frame(height: 30)
                    if index < offered.count - 1 { RowDivider() }
                }
            }
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well.opacity(Theme.palette.isLight ? 0.9 : 0.5)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))

            let unused = all.filter { !offered.contains($0) }
            if !unused.isEmpty {
                Text("NOT ON THE WIDGET")
                    .font(.system(size: 9.5, weight: .semibold)).tracking(1.1)
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .padding(.top, 2)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(unused, id: \.self) { name in
                        Button {
                            withAnimation(.spring(duration: 0.3)) { store.togglePreset(name, all: all) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                                Text(name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(Theme.ink.opacity(0.8))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Capsule().fill(Theme.ink.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.10)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Put \(name) on the widget")
                    }
                }
            }
        }

        SettingsGroup(title: "Now Playing widget", symbol: "play.square", accessory: {
            SegmentedPills(options: WidgetMock.Size.allCases.map { ($0, $0.label) }, selection: $playerSize,
                           height: 22, horizontalPadding: 10)
        }) {
            WidgetMock.Frame(size: playerSize) {
                NowPlayingWidgetMock(settings: s, title: player.track?.title ?? "Saltwater Radio",
                                     artist: player.track?.artist ?? "Velvet Harbor",
                                     art: player.track?.artwork, size: playerSize)
            }
            .animation(.spring(duration: 0.3), value: s)
            .animation(.spring(duration: 0.3), value: playerSize)

            RowDivider()
            SettingsRow(title: "Large widget shows",
                        detail: "A song without synced lyrics shows its cover either way.") {
                SegmentedPills(options: [("lyrics", "Lyrics"), ("cover", "Cover")],
                               selection: $store.settings.npLarge, height: 22, horizontalPadding: 10)
            }
            SwitchRow(title: "Lyric line on the medium widget", isOn: $store.settings.npMediumLyrics)
            SettingsRow(title: "Lyric text size") {
                SegmentedPills(options: Self.sizeOptions, selection: $store.settings.npLyricSize, height: 22, horizontalPadding: 10)
            }
            RowDivider()
            SwitchRow(title: "Previous and next buttons", detail: "On the medium and large widgets.",
                      isOn: $store.settings.npSkipButtons)
            SwitchRow(title: "Favorite button", isOn: $store.settings.npFavorite)
            SwitchRow(title: "Elapsed and total time", isOn: $store.settings.npTime)
            SwitchRow(title: "Cover as the backdrop", detail: "The song's cover, blurred, behind the widget.",
                      isOn: $store.settings.npCoverBackdrop)
        }

        SettingsGroup(title: "Putting widgets on the desktop", symbol: "questionmark.circle") {
            Text("Right-click the desktop and choose Edit Widgets, then search for Zuujis. Each widget comes in three sizes; the previews above show how each will look. Widgets are drawn in one colour unless System Settings › Desktop & Dock › Widget style is set to Full-color.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Spacer()
            PillButton(title: "Reset Widgets", symbol: "arrow.counterclockwise") {
                withAnimation(.spring(duration: 0.35)) { store.reset() }
            }
            .opacity(s == WidgetSettings() ? 0.4 : 1)
            .disabled(s == WidgetSettings())
        }
    }

    /// Bass, mid and treble as the widget reports them.
    private var tone: (Double, Double, Double) {
        func average(_ bands: [EQBand]) -> Double { bands.isEmpty ? 0 : bands.map(\.gain).reduce(0, +) / Double(bands.count) }
        return (average(engine.bands.filter { $0.frequency < 250 }),
                average(engine.bands.filter { $0.frequency >= 250 && $0.frequency <= 4000 }),
                average(engine.bands.filter { $0.frequency > 4000 }))
    }

    private var capacityNote: String {
        let s = store.settings
        func count(_ size: WidgetMock.Size) -> Int { EQWidgetMock.capacity(settings: s, size: size) }
        var parts = ["the large widget shows the first \(count(.large))"]
        if s.eqMedium == "presets" { parts.append("the medium the first \(count(.medium))") }
        if s.eqSmall == "presets" { parts.append("the small the first \(count(.small))") }
        return "The order here is the order on the widget. With these settings " + parts.joined(separator: ", ")
            + ". The stack button on the smaller widgets steps through all of them."
    }
}

/// Stand-ins for the desktop widgets, so Settings can show what a choice does
/// without waiting for the desktop. They are drawn like the real ones in
/// `ZuujisWidgets` (always in the Midnight look, as widgets are) and share
/// `WidgetSettings` with them, but they are pictures: nothing here is tappable.
private enum WidgetMock {
    enum Size: String, CaseIterable, Hashable {
        case small, medium, large
        var label: String { rawValue.capitalized }
        /// The usual size of each family on a Mac desktop.
        var points: CGSize {
            switch self {
            case .small: return CGSize(width: 158, height: 158)
            case .medium: return CGSize(width: 338, height: 158)
            case .large: return CGSize(width: 338, height: 354)
            }
        }
        var scale: CGFloat { self == .large ? 0.8 : 1 }
    }

    static let cyan = Color(red: 0.24, green: 0.86, blue: 1.00)
    static let violet = Color(red: 0.56, green: 0.44, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.33, blue: 0.64)
    static let mint = Color(red: 0.30, green: 0.94, blue: 0.66)
    static let amber = Color(red: 1.00, green: 0.68, blue: 0.26)
    static var signal: LinearGradient { LinearGradient(colors: [cyan, violet, pink], startPoint: .leading, endPoint: .trailing) }

    /// The widget's rounded tile, centred in the settings card.
    struct Frame<Content: View>: View {
        let size: Size
        @ViewBuilder var content: () -> Content

        var body: some View {
            let points = size.points
            content()
                .foregroundStyle(.white)
                .frame(width: points.width, height: points.height)
                .background(
                    ZStack {
                        LinearGradient(colors: [Color(red: 0.07, green: 0.075, blue: 0.115), Color(red: 0.028, green: 0.03, blue: 0.052)],
                                       startPoint: .top, endPoint: .bottom)
                        RadialGradient(colors: [cyan.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
                        RadialGradient(colors: [pink.opacity(0.18), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 280)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .scaleEffect(size.scale)
                .frame(width: points.width * size.scale, height: points.height * size.scale)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .allowsHitTesting(false)
        }
    }
}

private struct EQWidgetMock: View {
    let settings: WidgetSettings
    let presets: [String]
    let selected: String
    let isOn: Bool
    let bypassed: Bool
    let preamp: Double
    let tone: (Double, Double, Double)
    let size: WidgetMock.Size

    private var k: CGFloat { CGFloat(WidgetSettings.factor(settings.eqSize)) }

    /// How many presets a widget of `size` has room for, by the same sums the
    /// real widget does.
    static func capacity(settings: WidgetSettings, size: WidgetMock.Size) -> Int {
        let k = WidgetSettings.factor(settings.eqSize)
        let rowHeight = 28 * k
        switch size {
        case .small:
            return WidgetSettings.rows(in: 158 - 28 - 32 - 8, rowHeight: rowHeight, spacing: 6) * 2
        case .medium:
            return WidgetSettings.rows(in: 158 - 28 - 32 - 9, rowHeight: rowHeight, spacing: 6) * settings.eqColumns
        case .large:
            var room = 354.0 - 32 - 40 - 11 - 11 - 11
            if settings.eqLargeTone { room -= 32 * k * 2 + 8 + 11 }
            return WidgetSettings.rows(in: room, rowHeight: rowHeight, spacing: 6) * settings.eqColumns
        }
    }

    var body: some View {
        switch size {
        case .small:
            VStack(alignment: .leading, spacing: 8) {
                header(32)
                if settings.eqSmall == "presets" {
                    grid(columns: 2)
                } else {
                    stepper("PREAMP", preamp, decimals: 1)
                    HStack(spacing: 8) {
                        chip("Bypass", "circle.slash", on: bypassed)
                        chip(nil, "square.stack.3d.up")
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
        case .medium:
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    header(32)
                    chip("Bypass", "circle.slash", on: bypassed)
                    chip(nil, settings.eqMedium == "presets" ? "arrow.counterclockwise" : "square.stack.3d.up")
                }
                if settings.eqMedium == "presets" {
                    grid(columns: settings.eqColumns)
                } else {
                    toneGrid(28)
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
        case .large:
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    header(40)
                    chip("Bypass", "circle.slash", on: bypassed)
                    chip("Flat", "arrow.counterclockwise")
                }
                if settings.eqLargeTone, !settings.eqPresetsFirst { toneGrid(32) }
                Text("PRESETS").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.white.opacity(0.45))
                grid(columns: settings.eqColumns)
                if settings.eqLargeTone, settings.eqPresetsFirst { toneGrid(32) }
            }
            .padding(16)
        }
    }

    private func header(_ size: CGFloat) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(isOn ? WidgetMock.mint.opacity(0.2) : .white.opacity(0.07))
                Circle().strokeBorder(isOn ? WidgetMock.mint : .white.opacity(0.22), lineWidth: 1.5)
                Image(systemName: "power").font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(isOn ? WidgetMock.mint : .white.opacity(0.6))
            }
            .frame(width: size, height: size)
            VStack(alignment: .leading, spacing: 1) {
                Text(selected.isEmpty ? "Custom" : selected).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Text(!isOn ? "OFF" : (bypassed ? "BYPASSED" : "ON"))
                    .font(.system(size: 9.5, weight: .heavy)).tracking(1)
                    .foregroundStyle(!isOn ? .white.opacity(0.45) : (bypassed ? WidgetMock.amber : WidgetMock.mint))
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ title: String?, _ symbol: String, on: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
            if let title { Text(title).font(.system(size: 11 * k, weight: .semibold)).lineLimit(1) }
        }
        .foregroundStyle(on ? WidgetMock.amber : .white.opacity(0.85))
        .padding(.horizontal, title == nil ? 0 : 10)
        .frame(width: title == nil ? 28 * k : nil, height: 26 * k)
        .background(Capsule().fill(on ? WidgetMock.amber.opacity(0.2) : .white.opacity(0.09)))
        .overlay(Capsule().strokeBorder(on ? WidgetMock.amber.opacity(0.6) : .white.opacity(0.14)))
    }

    private func stepper(_ label: String, _ value: Double, decimals: Int = 0, height: CGFloat = 28) -> some View {
        let places = max(decimals, settings.eqStep.rounded() == settings.eqStep ? 0 : 1)
        let text = WidgetSettings.signed(value, places: places)
        return HStack(spacing: 6) {
            Text(label).font(.system(size: 9 * k, weight: .semibold)).tracking(0.8).foregroundStyle(.white.opacity(0.5))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 38 * k, alignment: .leading)
            stepButton("minus")
            Text(text).font(.system(size: 12 * k, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(value > 0.05 ? WidgetMock.mint : (value < -0.05 ? WidgetMock.amber : .white.opacity(0.75)))
                .frame(maxWidth: .infinity)
            stepButton("plus")
        }
        .frame(height: height * k)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.07)))
    }

    private func stepButton(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 10 * k, weight: .bold))
            .frame(width: 22 * k, height: 22 * k)
            .background(Circle().fill(.white.opacity(0.12)))
            .overlay(Circle().strokeBorder(.white.opacity(0.25)))
    }

    private func toneGrid(_ height: CGFloat) -> some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow { stepper("BASS", tone.0, height: height); stepper("MID", tone.1, height: height) }
            GridRow { stepper("TREBLE", tone.2, height: height); stepper("PREAMP", preamp, decimals: 1, height: height) }
        }
    }

    private func grid(columns: Int) -> some View {
        GeometryReader { geo in
            let rowHeight = 28 * k, gap: CGFloat = 6
            let fits = WidgetSettings.rows(in: geo.size.height, rowHeight: rowHeight, spacing: gap)
            let names = Array(presets.prefix(fits * columns))
            let rows = (names.count + columns - 1) / max(1, columns)
            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            if index < names.count {
                                let on = names[index] == selected
                                Text(names[index]).font(.system(size: 11 * k, weight: on ? .bold : .medium))
                                    .lineLimit(1).minimumScaleFactor(0.75)
                                    .foregroundStyle(on ? WidgetMock.cyan : .white.opacity(0.85))
                                    .padding(.horizontal, 6)
                                    .frame(maxWidth: .infinity).frame(height: rowHeight)
                                    .background(Capsule().fill(on ? WidgetMock.cyan.opacity(0.2) : .white.opacity(0.08)))
                                    .overlay(Capsule().strokeBorder(on ? WidgetMock.cyan.opacity(0.6) : .white.opacity(0.12)))
                            } else {
                                Color.clear.frame(maxWidth: .infinity).frame(height: rowHeight)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct NowPlayingWidgetMock: View {
    let settings: WidgetSettings
    let title: String
    let artist: String
    let art: NSImage?
    let size: WidgetMock.Size

    private var lyricScale: CGFloat { CGFloat(WidgetSettings.factor(settings.npLyricSize)) }
    private static let lines = ["Paper lanterns drifting past the pier", "Every little wave is spelling out your name",
                                "Hold the line until the morning", "Saltwater on the radio",
                                "Turn it up and let it carry", "All the way back home"]

    var body: some View {
        switch size {
        case .small:
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) { artwork(58); Spacer(); play(38) }
                Spacer(minLength: 6)
                titles(14)
                bar.padding(.top, 9)
            }
            .padding(14)
        case .medium:
            HStack(spacing: 14) {
                artwork(118)
                VStack(alignment: .leading, spacing: 0) {
                    titles(15)
                    if settings.npMediumLyrics {
                        Text(Self.lines[1]).font(.system(size: 14 * lyricScale, weight: .bold))
                            .foregroundStyle(WidgetMock.signal).lineLimit(settings.npTime ? 1 : 2).padding(.top, 8)
                    }
                    Spacer(minLength: 4)
                    bar
                    times.padding(.top, 3)
                    HStack(spacing: 14) {
                        if settings.npFavorite { Color.clear.frame(width: 30, height: 30) }
                        Spacer(minLength: 0)
                        if settings.npSkipButtons { glyph("backward.fill", 30) }
                        play(34)
                        if settings.npSkipButtons { glyph("forward.fill", 30) }
                        Spacer(minLength: 0)
                        if settings.npFavorite { glyph("heart.fill", 30, tint: WidgetMock.pink) }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(14)
        case .large:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if settings.npLarge != "cover" { artwork(64) }
                    titles(16)
                    Spacer(minLength: 0)
                    play(40)
                }
                if settings.npLarge == "cover" {
                    GeometryReader { geo in
                        VStack(spacing: 8) {
                            artwork(max(40, min(geo.size.width, geo.size.height - 44)))
                            Text(Self.lines[1]).font(.system(size: 14 * lyricScale, weight: .bold))
                                .foregroundStyle(WidgetMock.signal).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(Self.lines.enumerated()), id: \.offset) { index, line in
                            let active = index == 1
                            Text(line)
                                .font(.system(size: (active ? 19 : 14.5) * lyricScale, weight: active ? .bold : .semibold))
                                .foregroundStyle(active ? AnyShapeStyle(WidgetMock.signal)
                                                 : AnyShapeStyle(Color.white.opacity(index == 0 ? 0.28 : max(0.2, 0.62 - 0.11 * Double(index - 1)))))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                }
                VStack(spacing: 3) { bar; times }
                if settings.npSkipButtons || settings.npFavorite {
                    HStack(spacing: 26) {
                        if settings.npFavorite { Color.clear.frame(width: 34, height: 34) }
                        Spacer(minLength: 0)
                        if settings.npSkipButtons { glyph("backward.fill", 34); glyph("forward.fill", 34) }
                        Spacer(minLength: 0)
                        if settings.npFavorite { glyph("heart.fill", 34, tint: WidgetMock.pink) }
                    }
                }
            }
            .padding(16)
        }
    }

    private func artwork(_ side: CGFloat) -> some View {
        Group {
            if let art {
                Image(nsImage: art).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [WidgetMock.cyan, WidgetMock.violet, WidgetMock.pink],
                                   startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.55)
                    Image(systemName: "music.note").font(.system(size: side * 0.4, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: side * 0.16, style: .continuous).strokeBorder(.white.opacity(0.25)))
    }

    private func play(_ side: CGFloat) -> some View {
        Image(systemName: "pause.fill").font(.system(size: side * 0.4, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.8))
            .frame(width: side, height: side)
            .background(Circle().fill(LinearGradient(colors: [WidgetMock.cyan, WidgetMock.violet, WidgetMock.pink],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private func glyph(_ symbol: String, _ side: CGFloat, tint: Color = .white) -> some View {
        Image(systemName: symbol).font(.system(size: side * 0.42, weight: .semibold))
            .foregroundStyle(tint).frame(width: side, height: side)
    }

    private func titles(_ size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: size, weight: .bold)).lineLimit(1)
            Text(artist).font(.system(size: size * 0.76, weight: .medium)).foregroundStyle(.white.opacity(0.66)).lineLimit(1)
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(WidgetMock.cyan).frame(width: geo.size.width * 0.34)
            }
        }
        .frame(height: 4)
    }

    @ViewBuilder
    private var times: some View {
        if settings.npTime {
            HStack {
                Text("1:12"); Spacer(); Text("3:34")
            }
            .font(.system(size: 9.5, weight: .medium)).monospacedDigit()
            .foregroundStyle(.white.opacity(0.55))
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var lyrics: LyricsStore
    @EnvironmentObject private var login: LaunchAtLogin
    @AppStorage(ThemePalette.storageKey) private var themeID = ThemePalette.midnight.id

    var body: some View {
        SettingsGroup(title: "Theme", symbol: "paintpalette") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(ThemePalette.all) { palette in
                    let on = palette.id == themeID
                    Button { themeID = palette.id } label: {
                        VStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(LinearGradient(colors: [palette.backgroundTop, palette.backgroundBottom],
                                                     startPoint: .top, endPoint: .bottom))
                                .overlay(
                                    Capsule().fill(LinearGradient(colors: [palette.accentA, palette.accentB, palette.accentC],
                                                                  startPoint: .leading, endPoint: .trailing))
                                        .frame(height: 6).padding(.horizontal, 14)
                                )
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ink.opacity(0.15)))
                                .frame(height: 44)
                            Text(palette.name)
                                .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                                .foregroundStyle(Theme.ink.opacity(on ? 0.95 : 0.7))
                        }
                        .padding(7)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(on ? Theme.cyan.opacity(0.12) : Theme.ink.opacity(0.03)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(on ? Theme.cyan.opacity(0.6) : Theme.ink.opacity(0.08), lineWidth: on ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        SettingsGroup(title: "Startup", symbol: "power") {
            SwitchRow(title: "Open at login",
                      detail: "Starts in the menu bar without opening a window.",
                      isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
            if login.needsApproval {
                SettingsRow(title: "Waiting for approval", detail: "macOS needs this allowed in Login Items.") {
                    PillButton(title: "Open Login Items…") { SMLoginSettings.open() }
                }
            }
        }

        SettingsGroup(title: "Lyrics", symbol: "quote.bubble") {
            SwitchRow(title: "Look up missing lyrics online",
                      detail: "Asks lrclib.net, sending the song's title, artist, album and length. Off, nothing leaves this Mac.",
                      isOn: $lyrics.onlineLookup)
            SettingsRow(title: "Saved online lyrics",
                        detail: lyrics.recheckStatus ?? "Ask again for every saved song and keep the best-matching version.") {
                PillButton(title: "Re-check") { lyrics.recheckSaved() }
                    .opacity(lyrics.recheckStatus == nil ? 1 : 0.4)
                    .disabled(lyrics.recheckStatus != nil)
            }
        }

        SettingsGroup(title: "Output", symbol: "hifispeaker") {
            SwitchRow(title: "Match the output rate to each track",
                      detail: "Sets the device to the file's own sample rate. Applies from the next track.",
                      isOn: $player.matchSampleRate)
            SwitchRow(title: "Exclusive output",
                      detail: "Other apps are silent while a song plays.",
                      isOn: $player.exclusiveMode)
            SwitchRow(title: "Keep the pitch when changing speed",
                      detail: "Off, speed changes pitch like a turntable.",
                      isOn: $player.keepsPitch)
        }
        .onAppear { login.refresh() }
    }
}
