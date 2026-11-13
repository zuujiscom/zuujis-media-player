import XCTest
@testable import ZuujisCore

final class EQTests: XCTestCase {
    private func bands(count: Int, gain: Double) -> [EQBand] {
        let width = EQPreset.bandwidth(forBandCount: count)
        // Log-spaced 20 Hz...20 kHz.
        return (0..<count).map { i in
            let f = 20 * pow(1000, Double(i) / Double(count - 1))
            return EQBand(frequency: f, gain: gain, bandwidth: width)
        }
    }

    private func responseDB(_ bands: [EQBand], at frequency: Double) -> Double {
        EQResponse.decibels(EQResponse.sections(for: bands), at: frequency)
    }

    func testBandwidthFollowsLayout() {
        XCTAssertEqual(EQPreset.bandwidth(forBandCount: 10), 1.6)
        XCTAssertEqual(EQPreset.bandwidth(forBandCount: 15), 1.0)
        XCTAssertEqual(EQPreset.bandwidth(forBandCount: 31), 0.5)
    }

    func testFlatStaysFlat() {
        let flat = bands(count: 31, gain: 0)
        XCTAssertEqual(EQResponse.compensated(flat).map(\.gain), flat.map(\.gain))
        XCTAssertEqual(responseDB(flat, at: 1_000), 0, accuracy: 0.001)
    }

    func testBandGainIsWhatYouHearAtItsFrequency() {
        // Overlapping neighbours add; without compensation +4.5 dB everywhere
        // on 31 bands came out near +15 dB. The summed response must match
        // each fader instead.
        for count in [10, 15, 31] {
            let set = bands(count: count, gain: 4.5)
            for band in set {
                XCTAssertEqual(responseDB(set, at: band.frequency), 4.5, accuracy: 0.1,
                               "\(count) bands at \(band.frequency) Hz")
            }
        }
    }

    func testSingleFaderIsHonoured() {
        var set = bands(count: 31, gain: 0)
        set[15].gain = 12
        XCTAssertEqual(responseDB(set, at: set[15].frequency), 12, accuracy: 0.1)
    }

    func testDisabledBandsAreSkipped() {
        var set = bands(count: 10, gain: 6)
        for i in set.indices { set[i].isEnabled = false }
        XCTAssertEqual(EQResponse.sections(for: set).count, 0)
    }

    func testLayoutBandwidthIsAppliedOnlyToStandardLayouts() {
        let thirty = bands(count: 31, gain: 0).map { b -> EQBand in var b = b; b.bandwidth = 2; return b }
        XCTAssertTrue(EQPreset.withLayoutBandwidth(thirty).allSatisfy { $0.bandwidth == 0.5 })
        let odd = bands(count: 7, gain: 0).map { b -> EQBand in var b = b; b.bandwidth = 2; return b }
        XCTAssertTrue(EQPreset.withLayoutBandwidth(odd).allSatisfy { $0.bandwidth == 2 })
    }
}
