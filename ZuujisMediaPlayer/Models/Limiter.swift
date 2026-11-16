// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A look-ahead peak limiter: the last stage of both audio paths, so a hot
/// preamp, a boosted band or a loudness gain is turned down for the moment it
/// would exceed full scale instead of clipping at the output.
///
/// Audio below the ceiling passes through untouched (delayed by the look-ahead,
/// 1.5 ms). When a sample would go over, the gain it needs is known 1.5 ms
/// before that sample leaves, so the gain glides down to it in a straight line
/// and recovers slowly afterwards; nothing is ever chopped off. The output
/// never exceeds `ceiling`, whatever comes in:
///
/// 1. `need[n]` is the gain sample *n* needs (`ceiling / peak`, or 1).
/// 2. `windowMin[n]` is the smallest `need` over the last `lookahead + 1` samples.
/// 3. `released[n]` follows `windowMin` down at once and back up slowly.
/// 4. The gain applied to sample *n − lookahead* is the average of `released`
///    over the last `lookahead + 1` samples. Every one of those values is at
///    most `need[n − lookahead]`, so their average is too.
///
/// It runs on the realtime thread: everything is allocated in `init`, and
/// `process` neither allocates nor locks. One instance belongs to one stream.
final class SoftLimiter {
    /// −0.3 dBFS: a little under full scale, for the converter's sake.
    static let ceiling: Float = 0.966
    /// The delay it adds, at the default look-ahead.
    static let lookaheadSeconds = 0.0015

    let channels: Int
    /// Delay in samples, which is also how far ahead the gain can see.
    let lookahead: Int
    let sampleRate: Double

    private let size: Int
    private let delay: UnsafeMutablePointer<Float>
    private let need: UnsafeMutablePointer<Float>
    private let smooth: UnsafeMutablePointer<Float>
    private var index = 0
    /// How many entries of `need` are below 1; zero means nothing to do.
    private var reducing = 0
    private var windowMin: Float = 1
    private var released: Float = 1
    private var sum: Double
    private let releaseStep: Float

    init(sampleRate: Double, channels: Int, lookaheadMs: Double = SoftLimiter.lookaheadSeconds * 1000, releaseMs: Double = 120) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        self.sampleRate = rate
        self.channels = max(1, channels)
        lookahead = max(1, Int(rate * lookaheadMs / 1000))
        size = lookahead + 1
        delay = .allocate(capacity: size * self.channels)
        need = .allocate(capacity: size)
        smooth = .allocate(capacity: size)
        sum = Double(size)
        releaseStep = Float(1 - exp(-1 / (rate * releaseMs / 1000)))
        reset()
    }

    deinit {
        delay.deallocate()
        need.deallocate()
        smooth.deallocate()
    }

    var latency: Double { Double(lookahead) / sampleRate }

    /// Forgets what is in the delay line. Safe on the realtime thread.
    func reset() {
        delay.update(repeating: 0, count: size * channels)
        need.update(repeating: 1, count: size)
        smooth.update(repeating: 1, count: size)
        index = 0
        reducing = 0
        windowMin = 1
        released = 1
        sum = Double(size)
    }

    /// Limits `frames` frames in place, one buffer per channel, and returns the
    /// largest sample that came *in*: over 1.0 means it would have clipped.
    @discardableResult
    func process(_ buffers: UnsafePointer<UnsafeMutablePointer<Float>>, channels count: Int, frames: Int) -> Float {
        let active = min(count, channels)
        guard active > 0, frames > 0 else { return 0 }
        let ceiling = Self.ceiling
        var inputPeak: Float = 0

        for n in 0..<frames {
            var peak: Float = 0
            // A frame holding anything that is not a number (a NaN compares
            // false with everything) is silenced rather than passed on.
            var finite = true
            for c in 0..<active {
                let magnitude = abs(buffers[c][n])
                if !(magnitude < .infinity) { finite = false } else if magnitude > peak { peak = magnitude }
            }
            if !finite { peak = 0 }
            if peak > inputPeak { inputPeak = peak }
            let wanted: Float = peak > ceiling ? ceiling / peak : 1

            let leaving = need[index]
            need[index] = wanted
            if leaving < 1 { reducing -= 1 }
            if wanted < 1 { reducing += 1 }
            if reducing == 0 {
                windowMin = 1
            } else if wanted <= windowMin {
                windowMin = wanted
            } else if leaving <= windowMin {
                // The smallest one just left the window: find the next.
                var smallest: Float = 1
                for i in 0..<size where need[i] < smallest { smallest = need[i] }
                windowMin = smallest
            }

            var next = released + (1 - released) * releaseStep
            if next > 0.99999 { next = 1 }
            if next > windowMin { next = windowMin }
            released = next

            sum += Double(next) - Double(smooth[index])
            smooth[index] = next
            let gain = min(1, Float(sum / Double(size)))

            // The slot after the one just written holds the oldest sample.
            let oldest = index + 1 == size ? 0 : index + 1
            for c in 0..<active {
                let line = delay + c * size
                let x = buffers[c][n]
                line[index] = finite ? x : 0
                buffers[c][n] = line[oldest] * gain
            }
            index = oldest
        }
        return inputPeak
    }

    /// Array form, for tests: returns the limited channels.
    func process(_ input: [[Float]]) -> [[Float]] {
        let frames = input.map(\.count).min() ?? 0
        let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: max(1, input.count))
        defer { pointers.deallocate() }
        for (c, samples) in input.enumerated() {
            let copy = UnsafeMutablePointer<Float>.allocate(capacity: max(1, frames))
            copy.update(from: samples, count: frames)
            pointers[c] = copy
        }
        process(pointers, channels: input.count, frames: frames)
        return (0..<input.count).map { c in
            defer { pointers[c].deallocate() }
            return Array(UnsafeBufferPointer(start: pointers[c], count: frames))
        }
    }
}
