// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ZuujisCore

final class WindowLayoutTests: XCTestCase {
    private let all: Set<WindowLayout.Card> = [.library, .lyrics, .eq]

    private func arrange(order: String = WindowLayout.defaultOrder, placement: String = "auto", fill: String = "auto",
                         visible: Set<WindowLayout.Card>? = nil, width: Double) -> WindowLayout.Arrangement {
        WindowLayout.arrange(order: order, placement: placement, fill: fill, lyricsWidth: 340,
                             visible: visible ?? all, width: width)
    }

    func testOrderIsRepaired() {
        XCTAssertEqual(WindowLayout.cards("eq,eq,nonsense"), [.eq, .library, .lyrics])
        XCTAssertEqual(WindowLayout.cards(""), [.library, .lyrics, .eq])
        XCTAssertEqual(WindowLayout.moving(.eq, by: -1, in: "library,lyrics,eq"), "library,eq,lyrics")
        XCTAssertEqual(WindowLayout.moving(.library, by: -1, in: "library,lyrics,eq"), "library,lyrics,eq")
    }

    func testDefaultsMatchTheOriginalWindow() {
        // Wide: lyrics beside the library, the EQ underneath taking the spare room.
        let wide = arrange(width: 1200)
        XCTAssertEqual(wide.side, .besideTop)
        XCTAssertEqual(wide.stack, [.library, .eq])
        XCTAssertEqual(wide.fill, .eq)
        // Narrow: everything stacked.
        let narrow = arrange(width: 800)
        XCTAssertEqual(narrow.side, .none)
        XCTAssertEqual(narrow.stack, [.library, .lyrics, .eq])
        // Without the EQ the stacked lyrics stretch; alone, the library does.
        XCTAssertEqual(arrange(visible: [.library, .lyrics], width: 800).fill, .lyrics)
        XCTAssertEqual(arrange(visible: [.library], width: 800).fill, .library)
    }

    func testColumnsAndStacking() {
        XCTAssertEqual(arrange(placement: "left", width: 900).side, .column(leading: true))
        XCTAssertEqual(arrange(placement: "right", width: 900).stack, [.library, .eq])
        // Too narrow for a column, and never a column with nothing beside it.
        XCTAssertEqual(arrange(placement: "right", width: 600).side, .none)
        XCTAssertEqual(arrange(placement: "right", visible: [.lyrics], width: 1200).side, .none)
        XCTAssertEqual(arrange(placement: "stacked", width: 1400).stack, [.library, .lyrics, .eq])
    }

    func testFillFollowsTheChoiceWhenItIsShown() {
        XCTAssertEqual(arrange(fill: "library", width: 800).fill, .library)
        // Lyrics are at the side here, so the choice falls back to automatic.
        XCTAssertEqual(arrange(fill: "lyrics", width: 1200).fill, .eq)
        XCTAssertNil(arrange(visible: [], width: 800).fill)
    }

    func testLyricsWidthIsCapped() {
        let plan = WindowLayout.arrange(order: WindowLayout.defaultOrder, placement: "right", fill: "auto",
                                        lyricsWidth: 560, visible: all, width: 760)
        XCTAssertEqual(plan.lyricsWidth, 342, accuracy: 0.01)
    }

    func testWidgetSettingsDecodeWithMissingFields() throws {
        let old = try JSONDecoder().decode(WidgetSettings.self, from: Data(#"{"eqColumns": 9, "eqSmall": "presets"}"#.utf8))
        XCTAssertEqual(old.eqColumns, 4)
        XCTAssertEqual(old.eqSmall, "presets")
        XCTAssertEqual(old.eqStep, 1)
        XCTAssertTrue(old.npSkipButtons)
        // A state file written before the settings existed still reads.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var state = WidgetState()
        state.settings = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        XCTAssertEqual(try decoder.decode(WidgetState.self, from: encoder.encode(state)).layout, WidgetSettings())
    }

    func testOfferedPresets() {
        var s = WidgetSettings()
        XCTAssertEqual(s.offeredPresets(from: ["A", "B", "C"]), ["A", "B", "C"])
        s.eqPresets = ["C", "Gone", "A"]
        XCTAssertEqual(s.offeredPresets(from: ["A", "B", "C"]), ["C", "A"])
        s.eqPresets = ["Gone"]
        XCTAssertEqual(s.offeredPresets(from: ["A", "B"]), ["A", "B"])
        XCTAssertEqual(WidgetSettings.rows(in: 90, rowHeight: 28, spacing: 6), 2)
        XCTAssertEqual(WidgetSettings.rows(in: 96, rowHeight: 28, spacing: 6), 3)
    }
}
