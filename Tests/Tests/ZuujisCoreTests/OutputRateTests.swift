import XCTest
@testable import ZuujisCore

final class OutputRateTests: XCTestCase {
    private func discrete(_ rates: [Double]) -> [ClosedRange<Double>] { rates.map { $0...$0 } }

    func testExactRateIsPreferred() {
        let ranges = discrete([44_100, 48_000, 88_200, 96_000])
        XCTAssertEqual(OutputRate.bestRate(for: 44_100, in: ranges), 44_100)
        XCTAssertEqual(OutputRate.bestRate(for: 96_000, in: ranges), 96_000)
    }

    func testFallsBackToLowestIntegerMultiple() {
        // 44.1 kHz is not offered, 88.2 kHz is: an exact 2x, nothing fractional.
        XCTAssertEqual(OutputRate.bestRate(for: 44_100, in: discrete([48_000, 88_200, 96_000])), 88_200)
    }

    func testNoUsableRateLeavesTheDeviceAlone() {
        // A 48 kHz-only device (the headset) cannot take 44.1 kHz or any multiple.
        XCTAssertNil(OutputRate.bestRate(for: 44_100, in: discrete([48_000])))
        XCTAssertNil(OutputRate.bestRate(for: 44_100, in: []))
        XCTAssertNil(OutputRate.bestRate(for: 0, in: discrete([48_000])))
    }

    func testContinuousRange() {
        XCTAssertEqual(OutputRate.bestRate(for: 44_100, in: [8_000...192_000]), 44_100)
    }
}
