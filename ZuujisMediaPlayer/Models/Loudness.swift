// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How songs are brought to the same loudness.
enum LoudnessMode: String, CaseIterable, Codable, Sendable {
    /// Every file plays as it was mastered.
    case off
    /// Each song is brought to the target on its own.
    case track
    /// A whole album gets one gain, so its quiet songs stay quiet and a
    /// gapless album has no step between tracks.
    case album
}

/// The ReplayGain values a file carries in its tags. Gains are in dB, peaks
/// are linear (1.0 is full scale).
struct ReplayGainInfo: Codable, Equatable, Sendable {
    var trackGain: Double?
    var albumGain: Double?
    var trackPeak: Double?
    var albumPeak: Double?

    init(trackGain: Double? = nil, albumGain: Double? = nil, trackPeak: Double? = nil, albumPeak: Double? = nil) {
        self.trackGain = trackGain
        self.albumGain = albumGain
        self.trackPeak = trackPeak
        self.albumPeak = albumPeak
    }

    /// From a tag dictionary with upper-cased names, as `FLACTags.read` returns.
    init(tags: [String: String]) {
        trackGain = Self.decibels(tags["REPLAYGAIN_TRACK_GAIN"])
        albumGain = Self.decibels(tags["REPLAYGAIN_ALBUM_GAIN"])
        trackPeak = Self.peak(tags["REPLAYGAIN_TRACK_PEAK"])
        albumPeak = Self.peak(tags["REPLAYGAIN_ALBUM_PEAK"])
    }

    var isEmpty: Bool { trackGain == nil && albumGain == nil }

    /// "-6.54 dB", "+2.1", "-6,54 dB" → dB. Values no real file has are dropped.
    static func decibels(_ text: String?) -> Double? {
        guard let value = number(text), abs(value) <= 51 else { return nil }
        return value
    }

    /// "0.988553" → 0.988553.
    static func peak(_ text: String?) -> Double? {
        guard let value = number(text), value > 0, value < 16 else { return nil }
        return value
    }

    private static func number(_ text: String?) -> Double? {
        guard let text else { return nil }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let digits = cleaned.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        guard let value = Double(digits), value.isFinite else { return nil }
        return value
    }
}

/// What is known about one song when its gain is chosen.
struct LoudnessFacts: Equatable, Sendable {
    var tags = ReplayGainInfo()
    /// Measured by this app (LUFS and linear sample peak).
    var measuredLUFS: Double?
    var measuredPeak: Double?
    /// The song's album as a whole, from this app's measurements.
    var albumLUFS: Double?
    var albumPeak: Double?
}

struct LoudnessSettings: Equatable, Sendable {
    var mode: LoudnessMode = .album
    /// The gain for a song with no tags that has not been measured yet.
    var fallbackDB: Double = -6
    /// Lowers the gain so the song's own peak stays under full scale.
    var preventClipping = true
}

enum Loudness {
    /// The level ReplayGain 2 brings everything to.
    static let targetLUFS = -18.0
    static let gainRange = -24.0...20.0

    /// The gain, in dB, a song plays at. The file's own tags win over this
    /// app's measurement; the mode picks album or track values and falls back
    /// to the other kind when only that is known.
    static func gain(for facts: LoudnessFacts, settings: LoudnessSettings) -> Double {
        guard settings.mode != .off else { return 0 }
        typealias Choice = (gain: Double, peak: Double?)

        let track: Choice? = facts.tags.trackGain.map { ($0, facts.tags.trackPeak ?? facts.measuredPeak) }
            ?? facts.measuredLUFS.map { (targetLUFS - $0, facts.measuredPeak) }
        let album: Choice? = facts.tags.albumGain.map { ($0, facts.tags.albumPeak ?? facts.albumPeak) }
            ?? facts.albumLUFS.map { (targetLUFS - $0, facts.albumPeak) }

        guard let chosen = settings.mode == .album ? (album ?? track) : (track ?? album) else {
            return clamp(settings.fallbackDB)
        }
        var gain = chosen.gain
        if settings.preventClipping, let peak = chosen.peak, peak > 0 {
            gain = min(gain, -20 * log10(peak))
        }
        return clamp(gain)
    }

    private static func clamp(_ gain: Double) -> Double {
        min(gainRange.upperBound, max(gainRange.lowerBound, gain))
    }

    /// The loudness of several songs played as one: their energies averaged
    /// by length. (The standard gates the album's blocks together; this is
    /// within a fraction of a dB of that and needs only each song's figure.)
    static func albumLoudness(_ songs: [(lufs: Double, duration: Double)]) -> Double? {
        var energy = 0.0, total = 0.0
        for song in songs where song.lufs.isFinite {
            let weight = song.duration > 0 ? song.duration : 240
            energy += pow(10, song.lufs / 10) * weight
            total += weight
        }
        guard total > 0, energy > 0 else { return nil }
        return 10 * log10(energy / total)
    }
}

/// Integrated loudness by ITU-R BS.1770: each channel goes through the
/// K-weighting filter, the mean square is taken over 400 ms blocks that
/// overlap by three quarters, blocks under −70 LUFS are dropped, then blocks
/// more than 10 LU under the average of the rest. Feed it a whole file in
/// pieces and read `integrated`.
///
/// Mono counts as the same signal in both speakers, which is how it is played.
/// Surround channels are all weighted alike.
struct LoudnessMeter {
    let sampleRate: Double
    let channels: Int

    private struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    }

    private let shelf: Biquad
    private let highpass: Biquad
    /// Four filter states a channel: two for each filter.
    private var state: [Double]
    private let hop: Int
    private var filled = 0
    private var hopEnergy = 0.0
    /// Mean square, summed over channels, of each finished 100 ms.
    private var hops: [Double] = []
    /// The largest sample seen (linear).
    private(set) var peak: Float = 0

    init(sampleRate: Double, channels: Int) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        self.sampleRate = rate
        self.channels = max(1, channels)
        state = Array(repeating: 0, count: self.channels * 4)
        hop = max(1, Int((rate / 10).rounded()))

        // The standard gives coefficients for 48 kHz only; these are the same
        // two filters derived for any rate.
        var k = tan(Double.pi * 1681.974450955533 / rate)
        var q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                       b2: (vh - vb * k / q + k * k) / a0,
                       a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        k = tan(Double.pi * 38.13547087602444 / rate)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        highpass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }

    /// Adds `frames` frames, one buffer per channel.
    mutating func add(_ buffers: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        let weight = channels == 1 ? 2.0 : 1.0
        var done = 0
        while done < frames {
            let count = min(frames - done, hop - filled)
            for c in 0..<channels {
                let samples = buffers[c] + done
                var s1 = state[c * 4], s2 = state[c * 4 + 1], h1 = state[c * 4 + 2], h2 = state[c * 4 + 3]
                var energy = 0.0
                var top = peak
                for i in 0..<count {
                    let raw = samples[i]
                    let magnitude = abs(raw)
                    if magnitude > top { top = magnitude }
                    let x = Double(raw)
                    // Transposed direct form II, shelf then high-pass.
                    let y = shelf.b0 * x + s1
                    s1 = shelf.b1 * x - shelf.a1 * y + s2
                    s2 = shelf.b2 * x - shelf.a2 * y
                    let z = highpass.b0 * y + h1
                    h1 = highpass.b1 * y - highpass.a1 * z + h2
                    h2 = highpass.b2 * y - highpass.a2 * z
                    energy += z * z
                }
                peak = top
                state[c * 4] = s1; state[c * 4 + 1] = s2; state[c * 4 + 2] = h1; state[c * 4 + 3] = h2
                hopEnergy += energy * weight
            }
            filled += count
            done += count
            if filled == hop {
                hops.append(hopEnergy / Double(hop))
                hopEnergy = 0
                filled = 0
            }
        }
    }

    /// Array form, for tests.
    mutating func add(_ input: [[Float]]) {
        let frames = input.map(\.count).min() ?? 0
        guard frames > 0, input.count >= channels else { return }
        let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
        defer { pointers.deallocate() }
        for c in 0..<channels {
            pointers[c] = .allocate(capacity: frames)
            pointers[c].update(from: input[c], count: frames)
        }
        add(pointers, frames: frames)
        for c in 0..<channels { pointers[c].deallocate() }
    }

    /// Seconds measured so far.
    var duration: Double { (Double(hops.count * hop) + Double(filled)) / sampleRate }

    /// LUFS over everything added, or nil for silence (or nothing at all).
    var integrated: Double? {
        // 400 ms blocks every 100 ms; a clip shorter than one block is one block.
        var blocks: [Double] = []
        if hops.count >= 4 {
            blocks.reserveCapacity(hops.count - 3)
            for i in 0...(hops.count - 4) {
                blocks.append((hops[i] + hops[i + 1] + hops[i + 2] + hops[i + 3]) / 4)
            }
        } else if !hops.isEmpty {
            blocks = [hops.reduce(0, +) / Double(hops.count)]
        } else if filled > 0 {
            blocks = [hopEnergy / Double(filled)]
        }

        func lufs(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }
        let audible = blocks.filter { $0 > 0 && lufs($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let threshold = lufs(audible.reduce(0, +) / Double(audible.count)) - 10
        let counted = audible.filter { lufs($0) > threshold }
        guard !counted.isEmpty else { return nil }
        return lufs(counted.reduce(0, +) / Double(counted.count))
    }
}
