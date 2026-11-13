// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How the main window's cards are arranged: their order, where the lyrics
/// sit, how big each is and which one takes the spare height. The user edits
/// these in Settings; `MainView` and the Settings preview both draw whatever
/// `arrange` returns, so the two cannot disagree. Pure, and tested in
/// `WindowLayoutTests`.
enum WindowLayout {
    enum Card: String, CaseIterable, Identifiable {
        case library, lyrics, eq
        var id: String { rawValue }
        var name: String {
            switch self {
            case .library: return "Library"
            case .lyrics: return "Lyrics"
            case .eq: return "Equalizer"
            }
        }
        var symbol: String {
            switch self {
            case .library: return "books.vertical.fill"
            case .lyrics: return "quote.bubble.fill"
            case .eq: return "slider.vertical.3"
            }
        }
    }

    /// Where the lyrics card goes.
    enum Placement: String, CaseIterable {
        /// Beside the top card when the window is wide, in the stack otherwise.
        case auto
        /// A full-height column on that side of the other cards.
        case right, left
        /// Always in the stack, at its place in the order.
        case stacked
    }

    // Saved under these keys (`@AppStorage`).
    static let orderKey = "layoutCardOrder"
    static let placementKey = "layoutLyricsPlacement"
    static let fillKey = "layoutFill"
    static let lyricsWidthKey = "layoutLyricsWidth"
    static let lyricsHeightKey = "layoutLyricsHeight"
    static let libraryHeightKey = "layoutLibraryHeight"
    static let eqHeightKey = "layoutEQHeight"
    static let compactStageKey = "layoutCompactStage"
    static let stageSpectrumKey = "layoutStageSpectrum"
    static let allKeys = [orderKey, placementKey, fillKey, lyricsWidthKey, lyricsHeightKey,
                          libraryHeightKey, eqHeightKey, compactStageKey, stageSpectrumKey]

    static let defaultOrder = "library,lyrics,eq"
    /// "Whichever suits": the EQ, else stacked lyrics, else the library.
    static let autoFill = "auto"
    static let defaultLyricsWidth = 340.0
    static let defaultLyricsHeight = 260.0
    static let defaultLibraryHeight = 300.0
    static let defaultEQHeight = 360.0
    static let lyricsWidthRange = 240.0...560.0
    static let lyricsHeightRange = 160.0...640.0
    static let libraryHeightRange = 200.0...720.0
    static let eqHeightRange = 190.0...560.0

    /// Width from which automatic lyrics sit beside the top card.
    static let besideWidth = 1080.0
    /// Below this even a chosen side column goes back into the stack.
    static let columnMinWidth = 720.0

    /// The saved order as cards; anything missing or unknown is repaired, so
    /// a damaged value can never hide a card.
    static func cards(_ raw: String) -> [Card] {
        var result: [Card] = []
        for part in raw.split(separator: ",") {
            if let card = Card(rawValue: String(part)), !result.contains(card) { result.append(card) }
        }
        for card in Card.allCases where !result.contains(card) { result.append(card) }
        return result
    }

    static func raw(_ cards: [Card]) -> String { cards.map(\.rawValue).joined(separator: ",") }

    /// `order` with `card` moved one place up (-1) or down (+1).
    static func moving(_ card: Card, by delta: Int, in order: String) -> String {
        var list = cards(order)
        guard let from = list.firstIndex(of: card) else { return order }
        let to = from + delta
        guard list.indices.contains(to) else { return raw(list) }
        list.swapAt(from, to)
        return raw(list)
    }

    struct Arrangement: Equatable {
        enum Side: Equatable {
            /// The lyrics are in the stack (or hidden).
            case none
            /// The lyrics share a row with the first card of the stack.
            case besideTop
            /// The lyrics are a full-height column.
            case column(leading: Bool)
        }
        /// The cards top to bottom; without the lyrics when they are at the side.
        var stack: [Card]
        var side: Side
        /// The card that takes the window's spare height.
        var fill: Card?
        var lyricsWidth: Double
    }

    static func arrange(order: String, placement: String, fill: String, lyricsWidth: Double,
                        visible: Set<Card>, width: Double) -> Arrangement {
        let shown = cards(order).filter(visible.contains)
        let others = shown.filter { $0 != .lyrics }
        var side = Arrangement.Side.none
        if shown.contains(.lyrics), !others.isEmpty {
            switch Placement(rawValue: placement) ?? .auto {
            case .auto: if width >= besideWidth { side = .besideTop }
            case .right: if width >= columnMinWidth { side = .column(leading: false) }
            case .left: if width >= columnMinWidth { side = .column(leading: true) }
            case .stacked: break
            }
        }
        let stack = side == .none ? shown : others
        var target = Card(rawValue: fill).flatMap { stack.contains($0) ? $0 : nil }
        if target == nil {
            target = stack.contains(.eq) ? .eq : (stack.contains(.lyrics) ? .lyrics : stack.last)
        }
        // The lyrics never take more than half of a narrow window.
        let clamped = min(max(lyricsWidth, lyricsWidthRange.lowerBound), lyricsWidthRange.upperBound)
        return Arrangement(stack: stack, side: side, fill: target, lyricsWidth: min(clamped, max(220, width * 0.45)))
    }
}
