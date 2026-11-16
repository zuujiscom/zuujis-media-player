// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Accelerate

/// The equalizer's filter: one biquad per band in series, followed by the
/// preamp gain. It replaced `AVAudioUnitEQ`. The sections are the ones
/// `EQResponse` draws, so the curve on screen is the filter, not a model of it.
///
/// **Why it is hand-written.** A biquad's output feeds its own next sample,
/// so one section cannot go faster than that chain allows, and running the
/// sections one after another (which is what `vDSP_biquadm` amounts to) makes
/// the whole cascade one long chain. Here every section works on a different
/// sample at the same moment: in step *t*, section *k* filters sample *t − k*,
/// which section *k − 1* finished in the step before. The 31 sections in a
/// step do not depend on each other, so the processor overlaps them. The
/// result is bit-identical to `vDSP_biquadmD` and takes about 40% of its time
/// (which in turn was about 60% of `AVAudioUnitEQ`'s).
///
/// **Double precision.** In single precision the low bands (20 Hz at a 48 kHz
/// rate, worse at 192 kHz) leave an error only 46 to 66 dB under the signal.
/// Channels are filtered two at a time, one in each half of a `SIMD2<Double>`.
///
/// There is always one section per band, identity for a band that is off or
/// at 0 dB, so moving a fader never changes the section count. New
/// coefficients are approached over a few milliseconds, so a change does not
/// click. While every section is identity the filter is skipped altogether.
///
/// `process` runs on the realtime thread: it allocates nothing and holds
/// `lock` only against the main thread's short coefficient updates.
final class BiquadEQ: @unchecked Sendable {
    /// More bands than any layout has; `set(bands:)` ignores the rest.
    static let maxSections = 64

    let sampleRate: Double
    let channels: Int
    private let capacity: Int
    private let pairs: Int

    private typealias Pair = SIMD2<Double>

    /// One section: `y = b0·x + z1`, `z1 = b1·x − a1·y + z2`, `z2 = b2·x − a2·y`.
    /// `a1` and `a2` are stored negated.
    private struct Section {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, na1 = 0.0, na2 = 0.0
    }

    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private let current: UnsafeMutablePointer<Section>
    private let target: UnsafeMutablePointer<Section>
    /// `z1` then `z2` for each section, for each pair of channels.
    private let state: UnsafeMutablePointer<Pair>
    private let scratch: UnsafeMutablePointer<Pair>
    private var sectionCount = 0

    /// `current` is still on its way to `target`.
    private var ramping = false
    /// Frames between coefficient steps while ramping, and how much of the
    /// remaining distance each step covers (a time constant of about 5 ms).
    private static let rampChunk = 64
    private let rampStep: Double

    /// Every section is identity. Once that has lasted `restAfter` frames
    /// (long after the filters have rung out) the filter is not run.
    private var flat = true
    private var flatFrames = 0
    private let restAfter: Int

    private var gain: Float = 1
    private var targetGain: Float = 1

    init(sampleRate: Double, channels: Int, capacity: Int = 4096) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        self.sampleRate = rate
        self.channels = max(1, channels)
        self.capacity = max(1, capacity)
        pairs = (self.channels + 1) / 2
        restAfter = Int(rate)
        rampStep = 1 - exp(-Double(Self.rampChunk) / (0.005 * rate))
        lock.initialize(to: os_unfair_lock())
        current = .allocate(capacity: Self.maxSections)
        current.initialize(repeating: Section(), count: Self.maxSections)
        target = .allocate(capacity: Self.maxSections)
        target.initialize(repeating: Section(), count: Self.maxSections)
        state = .allocate(capacity: pairs * Self.maxSections * 2)
        state.initialize(repeating: .zero, count: pairs * Self.maxSections * 2)
        scratch = .allocate(capacity: self.capacity)
        scratch.initialize(repeating: .zero, count: self.capacity)
    }

    deinit {
        current.deallocate()
        target.deallocate()
        state.deallocate()
        scratch.deallocate()
        lock.deallocate()
    }

    // MARK: Settings (not the realtime thread)

    /// `bands` as the filter should be set: pass the compensated gains
    /// (`EQResponse.compensated`), not the faders' own. `bypassed` makes every
    /// section identity and leaves the preamp gain in place.
    func set(bands: [EQBand], bypassed: Bool = false) {
        var sections: [Section] = []
        sections.reserveCapacity(bands.count)
        var isFlat = true
        for band in bands.prefix(Self.maxSections) {
            if !bypassed, band.isEnabled, let s = EQResponse.section(for: band, sampleRate: sampleRate) {
                sections.append(Section(b0: s.b0, b1: s.b1, b2: s.b2, na1: -s.a1, na2: -s.a2))
                isFlat = false
            } else {
                sections.append(Section())
            }
        }

        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let resting = flat && flatFrames >= restAfter && !ramping
        for (k, section) in sections.enumerated() { target[k] = section }

        if sections.count != sectionCount {
            // A different layout: start on the new coefficients with empty
            // delays. There is no meaningful path from one layout to another.
            for k in sections.indices { current[k] = sections[k] }
            sectionCount = sections.count
            ramping = false
            clearState()
            flat = isFlat
            flatFrames = isFlat ? restAfter : 0
            return
        }

        // Coming back from rest: the filter has been skipped, so its delays
        // are stale. It starts empty and glides in from identity.
        if resting, !isFlat { clearState() }
        ramping = true
        flat = isFlat
        if !isFlat { flatFrames = 0 }
    }

    /// The preamp (and, for the file player, the loudness gain), in decibels.
    /// Reached in a straight line over the next block.
    func setGain(decibels: Double) {
        let linear = Float(pow(10, min(24, max(-96, decibels)) / 20))
        os_unfair_lock_lock(lock)
        targetGain = linear
        os_unfair_lock_unlock(lock)
    }

    private func clearState() {
        for i in 0..<(pairs * Self.maxSections * 2) { state[i] = .zero }
    }

    // MARK: Realtime

    /// Filters `frames` samples of each channel in place.
    func process(_ buffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels count: Int, frames: Int) {
        guard frames > 0 else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        let resting = flat && flatFrames >= restAfter && !ramping
        if sectionCount > 0, count == channels, !resting {
            if flat { flatFrames += frames }
            let doubles = UnsafeMutableRawPointer(scratch).assumingMemoryBound(to: Double.self)
            var done = 0
            while done < frames {
                if ramping { stepCoefficients() }
                let n = min(ramping ? Self.rampChunk : capacity, frames - done)
                let length = vDSP_Length(n)
                for pair in 0..<pairs {
                    let a = buffers[pair * 2] + done
                    // An odd channel out shares its pair with itself.
                    let b = buffers[min(pair * 2 + 1, channels - 1)] + done
                    vDSP_vspdp(a, 1, doubles, 2, length)
                    vDSP_vspdp(b, 1, doubles + 1, 2, length)
                    cascade(scratch, n, state + pair * Self.maxSections * 2)
                    vDSP_vdpsp(doubles, 2, a, 1, length)
                    if b != a { vDSP_vdpsp(doubles + 1, 2, b, 1, length) }
                }
                done += n
            }
        }

        let goal = targetGain
        if gain != goal {
            let step = (goal - gain) / Float(frames)
            for c in 0..<count {
                var start = gain
                var by = step
                vDSP_vrampmul(buffers[c], 1, &start, &by, buffers[c], 1, vDSP_Length(frames))
            }
            gain = goal
        } else if gain != 1 {
            var g = gain
            for c in 0..<count { vDSP_vsmul(buffers[c], 1, &g, buffers[c], 1, vDSP_Length(frames)) }
        }
    }

    /// Moves `current` a step towards `target`, and stops the ramp once it is
    /// there. A straight line between two stable biquads is stable all the way.
    private func stepCoefficients() {
        var furthest = 0.0
        for k in 0..<sectionCount {
            let to = target[k]
            var c = current[k]
            func move(_ value: inout Double, _ goal: Double) {
                furthest = max(furthest, abs(goal - value))
                value += (goal - value) * rampStep
            }
            move(&c.b0, to.b0); move(&c.b1, to.b1); move(&c.b2, to.b2)
            move(&c.na1, to.na1); move(&c.na2, to.na2)
            current[k] = c
        }
        if furthest < 1e-10 {
            for k in 0..<sectionCount { current[k] = target[k] }
            ramping = false
        }
    }

    /// The whole cascade over `n` samples of one channel pair, in place. See
    /// the type's comment for the order the work is done in.
    private func cascade(_ buffer: UnsafeMutablePointer<Pair>, _ n: Int, _ z: UnsafeMutablePointer<Pair>) {
        let m = sectionCount
        let sections = current

        @inline(__always) func step(_ k: Int, _ i: Int) {
            let s = sections[k]
            let x = buffer[i]
            let y = z[2 * k].addingProduct(Pair(repeating: s.b0), x)
            z[2 * k] = z[2 * k + 1].addingProduct(Pair(repeating: s.b1), x).addingProduct(Pair(repeating: s.na1), y)
            z[2 * k + 1] = (x * s.b2).addingProduct(Pair(repeating: s.na2), y)
            buffer[i] = y
        }
        // The first and last steps, where not every section has a sample.
        @inline(__always) func edge(_ t: Int) {
            var k = max(0, t - n + 1)
            let last = min(m - 1, t)
            while k <= last { step(k, t - k); k += 1 }
        }

        let total = n + m - 1
        for t in 0..<min(m - 1, total) { edge(t) }
        if n >= m {
            for t in (m - 1)..<n {
                for k in 0..<m { step(k, t - k) }
            }
        }
        for t in max(n, m - 1)..<total { edge(t) }
    }
}
