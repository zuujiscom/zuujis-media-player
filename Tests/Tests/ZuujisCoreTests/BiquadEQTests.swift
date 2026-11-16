import XCTest
@testable import ZuujisCore

final class BiquadEQTests: XCTestCase {
    private let rate = 48_000.0

    private func bands(count: Int, gain: Double) -> [EQBand] {
        let width = EQPreset.bandwidth(forBandCount: count)
        return (0..<count).map { i in
            EQBand(frequency: 20 * pow(1000, Double(i) / Double(count - 1)), gain: gain, bandwidth: width)
        }
    }

    /// Runs a sine through the filter in blocks and returns the gain in dB
    /// over the last half second (whole cycles for the frequencies used), for both channels.
    private func measure(_ eq: BiquadEQ, frequency: Double, seconds: Double = 4, block: Int = 512) -> [Double] {
        let total = Int(rate * seconds)
        var left = (0..<total).map { Float(0.25 * sin(2 * Double.pi * frequency * Double($0) / rate)) }
        var right = left
        let input = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var position = 0
                while position < total {
                    let n = min(block, total - position)
                    var pointers = [l.baseAddress! + position, r.baseAddress! + position]
                    eq.process(&pointers, channels: 2, frames: n)
                    position += n
                }
            }
        }
        func rms(_ x: [Float]) -> Double {
            let tail = x[(total - Int(rate / 2))...]
            return sqrt(tail.reduce(0) { $0 + Double($1) * Double($1) } / Double(tail.count))
        }
        return [left, right].map { 20 * log10(rms($0) / rms(input)) }
    }

    func testResponseMatchesTheDrawnCurve() {
        var set = bands(count: 31, gain: 0)
        for i in set.indices { set[i].gain = i % 2 == 0 ? 9 : -6 }
        set[0].filterType = .lowShelf
        set[30].filterType = .highShelf
        let effective = EQResponse.compensated(set, sampleRate: rate)
        let sections = EQResponse.sections(for: set, sampleRate: rate)
        for frequency in [32.0, 100, 440, 1_000, 3_150, 10_000, 16_000] {
            let eq = BiquadEQ(sampleRate: rate, channels: 2)
            eq.set(bands: effective)
            let expected = EQResponse.decibels(sections, at: frequency, sampleRate: rate)
            for gain in measure(eq, frequency: frequency) {
                XCTAssertEqual(gain, expected, accuracy: 0.02, "\(frequency) Hz")
            }
        }
    }

    func testFlatAndBypassedPassAudioUntouched() {
        let flat = BiquadEQ(sampleRate: rate, channels: 2)
        flat.set(bands: bands(count: 31, gain: 0))
        XCTAssertEqual(measure(flat, frequency: 1_000)[0], 0, accuracy: 1e-6)

        let bypassed = BiquadEQ(sampleRate: rate, channels: 2)
        bypassed.set(bands: bands(count: 31, gain: 12), bypassed: true)
        XCTAssertEqual(measure(bypassed, frequency: 1_000)[0], 0, accuracy: 1e-6)
    }

    func testGainIsApplied() {
        let eq = BiquadEQ(sampleRate: rate, channels: 2)
        eq.set(bands: bands(count: 10, gain: 0))
        eq.setGain(decibels: -6)
        XCTAssertEqual(measure(eq, frequency: 1_000)[1], -6, accuracy: 0.001)
    }

    func testChangesWhilePlayingArrive() {
        // Flat long enough to rest, then a boost, a new band count, and flat again.
        let eq = BiquadEQ(sampleRate: rate, channels: 2)
        eq.set(bands: bands(count: 31, gain: 0))
        _ = measure(eq, frequency: 1_000)

        var boosted = bands(count: 31, gain: 0)
        boosted[17].gain = 12
        eq.set(bands: boosted)
        let expected = EQResponse.decibels(
            boosted.compactMap { EQResponse.section(for: $0, sampleRate: rate) }, at: 1_000, sampleRate: rate)
        XCTAssertEqual(measure(eq, frequency: 1_000)[0], expected, accuracy: 0.02)

        var ten = bands(count: 10, gain: 0)
        ten[5].gain = -9
        eq.set(bands: ten)
        let expectedTen = EQResponse.decibels(
            ten.compactMap { EQResponse.section(for: $0, sampleRate: rate) }, at: 1_000, sampleRate: rate)
        XCTAssertEqual(measure(eq, frequency: 1_000)[0], expectedTen, accuracy: 0.02)

        eq.set(bands: bands(count: 10, gain: 0))
        XCTAssertEqual(measure(eq, frequency: 1_000)[0], 0, accuracy: 0.001)
    }

    func testAChangeDoesNotClick() {
        // A 12 dB step on a band, mid-stream: no sample-to-sample jump beyond
        // what the sine itself and a smooth gain change account for.
        let eq = BiquadEQ(sampleRate: rate, channels: 1)
        var set = bands(count: 31, gain: 0)
        set[17].gain = 3
        eq.set(bands: set)
        let total = 48_000
        var x = (0..<total).map { Float(0.25 * sin(2 * Double.pi * 1_000 * Double($0) / rate)) }
        x.withUnsafeMutableBufferPointer { buffer in
            var position = 0
            while position < total {
                if position == 24_064 { set[17].gain = 15; eq.set(bands: set) }
                var pointers = [buffer.baseAddress! + position]
                eq.process(&pointers, channels: 1, frames: 512)
                position += 512
            }
        }
        var worst: Float = 0
        for i in 24_000..<26_000 { worst = max(worst, abs(x[i + 1] - x[i])) }
        // A full-size +15 dB 1 kHz sine moves at most 0.25 * 5.6 * 2π·1000/48000 = 0.18 a sample.
        XCTAssertLessThan(worst, 0.2)
    }

    func testOddBlockSizesAndChannelCounts() {
        // Blocks shorter than the section count, and a channel without a pair,
        // must give the same answer as everything else.
        var set = bands(count: 31, gain: 0)
        for i in set.indices { set[i].gain = i % 3 == 0 ? 6 : -3 }
        let effective = EQResponse.compensated(set, sampleRate: rate)
        let expected = EQResponse.decibels(EQResponse.sections(for: set, sampleRate: rate), at: 1_000, sampleRate: rate)
        for block in [1, 7, 31, 64, 4096] {
            let eq = BiquadEQ(sampleRate: rate, channels: 2)
            eq.set(bands: effective)
            XCTAssertEqual(measure(eq, frequency: 1_000, seconds: 1.5, block: block)[1], expected, accuracy: 0.02, "block \(block)")
        }

        let three = BiquadEQ(sampleRate: rate, channels: 3)
        three.set(bands: effective)
        let total = 72_000
        let input = (0..<total).map { Float(0.25 * sin(2 * Double.pi * 1_000 * Double($0) / rate)) }
        var x0 = input, x1 = input, x2 = input
        x0.withUnsafeMutableBufferPointer { a in x1.withUnsafeMutableBufferPointer { b in x2.withUnsafeMutableBufferPointer { c in
            var position = 0
            while position < total {
                var pointers = [a.baseAddress! + position, b.baseAddress! + position, c.baseAddress! + position]
                three.process(&pointers, channels: 3, frames: 480)
                position += 480
            }
        }}}
        XCTAssertEqual(x0, x2)
        XCTAssertEqual(x0, x1)
        XCTAssertNotEqual(x0, input)
    }

    func testSpeed() {
        // Not a pass/fail figure: prints what 31 stereo bands cost.
        var set = bands(count: 31, gain: 0)
        for i in set.indices { set[i].gain = i % 2 == 0 ? 9 : -6 }
        let eq = BiquadEQ(sampleRate: rate, channels: 2)
        eq.set(bands: EQResponse.compensated(set, sampleRate: rate))
        let start = Date()
        _ = measure(eq, frequency: 1_000, seconds: 20)
        print("BiquadEQ: 20 s of 31-band stereo, including building the test signal, took", Date().timeIntervalSince(start), "s")
    }
}
