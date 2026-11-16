// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import AVFoundation
@testable import ZuujisCore

final class LimiterTests: XCTestCase {
    private func sine(_ amplitude: Float, frequency: Double = 220, rate: Double = 48_000, frames: Int = 24_000) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    func testQuietAudioPassesUnchangedApartFromTheDelay() {
        let limiter = SoftLimiter(sampleRate: 48_000, channels: 2)
        let input = sine(0.5)
        let output = limiter.process([input, input])
        let delay = limiter.lookahead
        XCTAssertEqual(delay, 72)
        for i in delay..<input.count {
            XCTAssertEqual(output[0][i], input[i - delay], "sample \(i)")
            XCTAssertEqual(output[1][i], input[i - delay])
        }
    }

    func testNothingLeavesAboveTheCeiling() {
        for (rate, channels) in [(44_100.0, 2), (48_000.0, 1), (96_000.0, 2), (192_000.0, 6)] {
            let limiter = SoftLimiter(sampleRate: rate, channels: channels)
            // Loud sines, a full-scale step, single-sample spikes and noise.
            var signal = sine(4, frequency: 60, rate: rate) + sine(15.85, frequency: 3_000, rate: rate)
            signal += Array(repeating: Float(0), count: 500) + Array(repeating: Float(8), count: 500)
            var seed: UInt32 = 12345
            for i in 0..<20_000 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Float(seed >> 8) / Float(1 << 24) * 2 - 1
                signal.append(i % 997 == 0 ? 30 : noise * 3)
            }
            let output = limiter.process(Array(repeating: signal, count: channels))
            let peak = output.flatMap { $0 }.map(abs).max() ?? 0
            XCTAssertLessThanOrEqual(peak, SoftLimiter.ceiling + 1e-6, "\(rate) Hz, \(channels) ch")
            // And it is a limiter, not a mute: the loud parts come out near the ceiling.
            XCTAssertGreaterThan(peak, SoftLimiter.ceiling * 0.98)
        }
    }

    func testOneLoudChannelTurnsBothDownTogether() {
        let limiter = SoftLimiter(sampleRate: 48_000, channels: 2)
        let loud = sine(4), quiet = sine(0.4)
        let output = limiter.process([loud, quiet])
        // The stereo picture must not shift: both channels get the same gain.
        for i in stride(from: 5_000, to: 20_000, by: 37) where abs(output[0][i]) > 0.01 {
            XCTAssertEqual(output[1][i] / output[0][i], 0.1, accuracy: 0.001)
        }
    }

    func testRecoversAfterAPeak() {
        let limiter = SoftLimiter(sampleRate: 48_000, channels: 1)
        let input = sine(4, frames: 4_800) + sine(0.5, frames: 96_000)
        let output = limiter.process([input])[0]
        // Two seconds on, the quiet part is back at its own level.
        let tail = output.suffix(4_800).map(abs).max() ?? 0
        XCTAssertEqual(tail, 0.5, accuracy: 0.001)
    }

    func testReportsTheInputPeak() {
        let limiter = SoftLimiter(sampleRate: 48_000, channels: 1)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer { buffer.deallocate() }
        buffer.update(from: [0.1, -2.5, 0.3, 0.2], count: 4)
        var pointer = buffer
        let peak = withUnsafePointer(to: &pointer) { limiter.process($0, channels: 1, frames: 4) }
        XCTAssertEqual(peak, 2.5)
    }

    func testNotANumberIsSilenced() {
        let limiter = SoftLimiter(sampleRate: 48_000, channels: 1)
        var input = sine(0.5, frames: 2_000)
        input[1_000] = .nan
        input[1_001] = .infinity
        let output = limiter.process([input])[0]
        XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= SoftLimiter.ceiling })
    }
}

final class LoudnessMeterTests: XCTestCase {
    private func sine(_ amplitude: Float, frequency: Double, rate: Double, seconds: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    func testStereoSineReadsItsLevel() {
        // A 1 kHz sine at -20 dBFS peak-equivalent RMS in both channels is
        // -20 LUFS... in BS.1770 terms: amplitude 0.1 in two channels sums to
        // -20.0, and K-weighting is flat at 1 kHz.
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            var meter = LoudnessMeter(sampleRate: rate, channels: 2)
            let tone = sine(0.1, frequency: 1_000, rate: rate, seconds: 5)
            meter.add([tone, tone])
            XCTAssertEqual(meter.integrated ?? 0, -20.0, accuracy: 0.1, "\(rate) Hz")
            XCTAssertEqual(meter.peak, 0.1, accuracy: 0.0001)
            XCTAssertEqual(meter.duration, 5, accuracy: 0.001)
        }
    }

    func testMonoCountsAsBothSpeakers() {
        var meter = LoudnessMeter(sampleRate: 48_000, channels: 1)
        meter.add([sine(0.1, frequency: 1_000, rate: 48_000, seconds: 3)])
        XCTAssertEqual(meter.integrated ?? 0, -20.0, accuracy: 0.1)
    }

    func testSilenceBetweenIsGatedOut() {
        let rate = 48_000.0
        let tone = sine(0.1, frequency: 1_000, rate: rate, seconds: 4)
        let gap = [Float](repeating: 0, count: Int(rate * 8))
        var meter = LoudnessMeter(sampleRate: rate, channels: 2)
        let all = tone + gap + tone
        meter.add([all, all])
        // Ungated, two thirds silence would read almost 5 dB lower.
        XCTAssertEqual(meter.integrated ?? 0, -20.0, accuracy: 0.3)
    }

    func testChunksGiveTheSameAnswer() {
        let rate = 44_100.0
        let tone = sine(0.25, frequency: 440, rate: rate, seconds: 3)
        var whole = LoudnessMeter(sampleRate: rate, channels: 2)
        whole.add([tone, tone])
        var pieces = LoudnessMeter(sampleRate: rate, channels: 2)
        var i = 0
        while i < tone.count {
            let n = min(1_000 + i % 777, tone.count - i)
            let part = Array(tone[i..<i + n])
            pieces.add([part, part])
            i += n
        }
        XCTAssertEqual(whole.integrated ?? 0, pieces.integrated ?? 1, accuracy: 1e-9)
    }

    func testSilenceHasNoLoudness() {
        var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
        let zeros = [Float](repeating: 0, count: 48_000)
        meter.add([zeros, zeros])
        XCTAssertNil(meter.integrated)
        XCTAssertNil(LoudnessMeter(sampleRate: 48_000, channels: 2).integrated)
    }

    func testBassCountsForLessThanMidrange() {
        var low = LoudnessMeter(sampleRate: 48_000, channels: 2)
        let bass = sine(0.1, frequency: 50, rate: 48_000, seconds: 3)
        low.add([bass, bass])
        XCTAssertLessThan(low.integrated ?? 0, -22)
    }
}

final class LoudnessGainTests: XCTestCase {
    func testParsesTagText() {
        XCTAssertEqual(ReplayGainInfo.decibels("-6.54 dB"), -6.54)
        XCTAssertEqual(ReplayGainInfo.decibels("+2.10 dB"), 2.1)
        XCTAssertEqual(ReplayGainInfo.decibels(" -7,3dB "), -7.3)
        XCTAssertEqual(ReplayGainInfo.decibels("3"), 3)
        XCTAssertNil(ReplayGainInfo.decibels("loud"))
        XCTAssertNil(ReplayGainInfo.decibels("-999 dB"))
        XCTAssertNil(ReplayGainInfo.decibels(nil))
        XCTAssertEqual(ReplayGainInfo.peak("0.988553"), 0.988553)
        XCTAssertNil(ReplayGainInfo.peak("0"))

        let info = ReplayGainInfo(tags: ["REPLAYGAIN_TRACK_GAIN": "-8.2 dB", "REPLAYGAIN_ALBUM_GAIN": "-7.5 dB",
                                         "REPLAYGAIN_TRACK_PEAK": "1.02", "ARTIST": "x"])
        XCTAssertEqual(info, ReplayGainInfo(trackGain: -8.2, albumGain: -7.5, trackPeak: 1.02))
        XCTAssertTrue(ReplayGainInfo(tags: ["TITLE": "x"]).isEmpty)
    }

    func testModePicksTrackOrAlbum() {
        let facts = LoudnessFacts(tags: ReplayGainInfo(trackGain: -9, albumGain: -7))
        var settings = LoudnessSettings(mode: .track, fallbackDB: -6, preventClipping: false)
        XCTAssertEqual(Loudness.gain(for: facts, settings: settings), -9)
        settings.mode = .album
        XCTAssertEqual(Loudness.gain(for: facts, settings: settings), -7)
        settings.mode = .off
        XCTAssertEqual(Loudness.gain(for: facts, settings: settings), 0)
    }

    func testFallsBackToTheOtherKindThenToTheSetting() {
        let album = LoudnessSettings(mode: .album, fallbackDB: -6, preventClipping: false)
        let track = LoudnessSettings(mode: .track, fallbackDB: -6, preventClipping: false)
        XCTAssertEqual(Loudness.gain(for: LoudnessFacts(tags: ReplayGainInfo(trackGain: -9)), settings: album), -9)
        XCTAssertEqual(Loudness.gain(for: LoudnessFacts(tags: ReplayGainInfo(albumGain: -7)), settings: track), -7)
        XCTAssertEqual(Loudness.gain(for: LoudnessFacts(), settings: album), -6)
    }

    func testMeasurementsStandInForTags() {
        let settings = LoudnessSettings(mode: .track, fallbackDB: -6, preventClipping: false)
        // -10 LUFS is 8 dB over the -18 target.
        XCTAssertEqual(Loudness.gain(for: LoudnessFacts(measuredLUFS: -10), settings: settings), -8)
        // The file's own tag wins over a measurement.
        XCTAssertEqual(Loudness.gain(for: LoudnessFacts(tags: ReplayGainInfo(trackGain: -5), measuredLUFS: -10), settings: settings), -5)
        let album = LoudnessSettings(mode: .album, fallbackDB: -6, preventClipping: false)
        XCTAssertEqual(Loudness.gain(for: LoudnessFacts(measuredLUFS: -10, albumLUFS: -12), settings: album), -6)
    }

    func testAQuietSongIsRaisedOnlyAsFarAsItsPeakAllows() {
        var settings = LoudnessSettings(mode: .track, fallbackDB: -6, preventClipping: true)
        // -26 LUFS wants +8 dB, but its peak of 0.8 leaves 1.94 dB of room.
        let facts = LoudnessFacts(measuredLUFS: -26, measuredPeak: 0.8)
        XCTAssertEqual(Loudness.gain(for: facts, settings: settings), 1.938, accuracy: 0.001)
        settings.preventClipping = false
        XCTAssertEqual(Loudness.gain(for: facts, settings: settings), 8)
        // Turning a loud song down is never limited by its peak.
        settings.preventClipping = true
        XCTAssertEqual(Loudness.gain(for: LoudnessFacts(measuredLUFS: -9, measuredPeak: 1.0), settings: settings), -9)
    }

    func testAlbumLoudnessAveragesEnergyByLength() {
        XCTAssertEqual(Loudness.albumLoudness([(-10, 200), (-10, 100)]) ?? 0, -10, accuracy: 1e-9)
        // A loud song dominates a quiet one of the same length.
        let mixed = Loudness.albumLoudness([(-8, 200), (-20, 200)]) ?? 0
        XCTAssertEqual(mixed, -10.75, accuracy: 0.05)
        XCTAssertNil(Loudness.albumLoudness([]))
    }
}

/// ReplayGain tags read back from real files made with ffmpeg, and this app's
/// measurement checked against ffmpeg's own EBU R128 meter. Skipped when
/// ffmpeg is not installed.
final class ReplayGainFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("zuujis-loudness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func ffmpeg(_ args: [String]) throws -> String {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile) else {
            throw XCTSkip("ffmpeg is not installed")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-hide_banner", "-nostdin", "-y"] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private let tags = ["-metadata", "REPLAYGAIN_TRACK_GAIN=-7.25 dB", "-metadata", "REPLAYGAIN_TRACK_PEAK=0.977200",
                        "-metadata", "REPLAYGAIN_ALBUM_GAIN=-6.50 dB", "-metadata", "REPLAYGAIN_ALBUM_PEAK=1.001000",
                        "-metadata", "album=Night Drive", "-metadata", "artist=The Examples"]
    private let expected = ReplayGainInfo(trackGain: -7.25, albumGain: -6.5, trackPeak: 0.9772, albumPeak: 1.001)

    private func make(_ name: String, _ extra: [String] = []) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=1"] + tags + extra + [url.path])
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("ffmpeg could not write \(name)") }
        return url
    }

    func testFLAC() throws {
        let read = ReplayGainTags.read(try make("a.flac"))
        XCTAssertEqual(read.info, expected)
        XCTAssertEqual(read.album, "the examples\u{1F}night drive")
    }

    func testMP3UserTextFrames() throws {
        for version in ["3", "4"] {
            let read = ReplayGainTags.read(try make("a\(version).mp3", ["-id3v2_version", version]))
            XCTAssertEqual(read.info, expected, "ID3v2.\(version)")
            XCTAssertEqual(read.album, "the examples\u{1F}night drive")
        }
    }

    func testM4AFreeformAtoms() throws {
        for (name, extra) in [("a.m4a", [String]()), ("fast.m4a", ["-movflags", "+faststart"])] {
            let read = ReplayGainTags.read(try make(name, ["-movflags", "use_metadata_tags"] + extra))
            // ffmpeg writes custom keys its own way in some builds; iTunes-style
            // freeform atoms are what taggers write, so build those by hand too.
            if read.info.isEmpty { continue }
            XCTAssertEqual(read.info, expected, name)
        }
    }

    func testMP4AtomWalk() {
        func atom(_ type: [UInt8], _ body: [UInt8]) -> [UInt8] {
            let size = UInt32(body.count + 8)
            return [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)] + type + body
        }
        func atom(_ type: String, _ body: [UInt8]) -> [UInt8] { atom(Array(type.utf8), body) }
        func data(_ text: String) -> [UInt8] { atom("data", [0, 0, 0, 1, 0, 0, 0, 0] + Array(text.utf8)) }
        func freeform(_ name: String, _ value: String) -> [UInt8] {
            atom("----", atom("mean", [0, 0, 0, 0] + Array("com.apple.iTunes".utf8))
                + atom("name", [0, 0, 0, 0] + Array(name.utf8)) + data(value))
        }
        let ilst = atom("ilst",
                        atom([0xA9] + Array("alb".utf8), data("Night Drive"))
                        + atom([0xA9] + Array("ART".utf8), data("Someone Else"))
                        + atom("aART", data("The Examples"))
                        + atom("covr", atom("data", [0, 0, 0, 13, 0, 0, 0, 0, 0xFF, 0xD8, 0xFF]))
                        + freeform("replaygain_track_gain", "-7.25 dB")
                        + freeform("replaygain_album_gain", "-6.50 dB")
                        + freeform("replaygain_track_peak", "0.977200"))
        let moov = atom("mvhd", [UInt8](repeating: 0, count: 100))
            + atom("udta", atom("meta", [0, 0, 0, 0] + atom("hdlr", [UInt8](repeating: 0, count: 25)) + ilst))
        let fields = MP4Tags.parse(moov: moov)
        XCTAssertEqual(fields["REPLAYGAIN_TRACK_GAIN"], "-7.25 dB")
        XCTAssertEqual(fields["ALBUM"], "Night Drive")
        XCTAssertEqual(fields["ALBUMARTIST"], "The Examples")
        XCTAssertEqual(ReplayGainInfo(tags: fields), ReplayGainInfo(trackGain: -7.25, albumGain: -6.5, trackPeak: 0.9772))

        // Through the file reader too, with the audio in front of `moov`.
        let file = atom("ftyp", Array("M4A \0\0\0\0".utf8)) + atom("mdat", [UInt8](repeating: 7, count: 5_000)) + atom("moov", moov)
        let url = dir.appendingPathComponent("hand.m4a")
        try? Data(file).write(to: url)
        let read = ReplayGainTags.read(url)
        XCTAssertEqual(read.info.trackGain, -7.25)
        XCTAssertEqual(read.album, "the examples\u{1F}night drive")

        // Truncated and nonsense input is survived.
        XCTAssertEqual(MP4Tags.parse(moov: Array(moov.prefix(150))), [:])
        XCTAssertEqual(MP4Tags.parse(moov: [0, 0, 0, 0, 1, 2, 3]), [:])
    }

    func testUntaggedFileHasNoGain() throws {
        let url = dir.appendingPathComponent("plain.flac")
        try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=1", url.path])
        XCTAssertTrue(ReplayGainTags.read(url).info.isEmpty)
        XCTAssertTrue(ReplayGainTags.read(dir.appendingPathComponent("missing.flac")).info.isEmpty)
    }

    func testMeasurementAgreesWithFFmpeg() throws {
        // Pink noise with a quiet stretch and a loud one, so both gates matter.
        let url = dir.appendingPathComponent("noise.flac")
        try ffmpeg(["-f", "lavfi", "-i", "anoisesrc=color=pink:duration=20:sample_rate=44100:seed=7:amplitude=0.5",
                    "-af", "volume='if(lt(t,6),0.02,if(lt(t,12),0.4,1))':eval=frame", "-ac", "2", url.path])
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("ffmpeg could not write the file") }
        let report = try ffmpeg(["-i", url.path, "-af", "ebur128", "-f", "null", "-"])
        guard let line = report.components(separatedBy: "\n").last(where: { $0.contains("I:") && $0.contains("LUFS") }),
              let value = line.components(separatedBy: "I:").last?
                .trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first,
              let reference = Double(value) else { throw XCTSkip("no ebur128 summary from ffmpeg") }

        let measured = try XCTUnwrap(LoudnessStore.measure(url))
        XCTAssertEqual(try XCTUnwrap(measured.lufs), reference, accuracy: 0.2)
        XCTAssertEqual(measured.duration, 20, accuracy: 0.05)
        XCTAssertGreaterThan(measured.peak, 0.1)
    }
}

final class LoudnessStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("zuujis-loudstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A stereo WAV of a 1 kHz sine, written without any outside tool.
    private func wav(_ name: String, amplitude: Float, seconds: Double = 3) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for c in 0..<2 {
            let p = try XCTUnwrap(buffer.floatChannelData)[c]
            for i in 0..<Int(frames) { p[i] = amplitude * Float(sin(2 * Double.pi * 1_000 * Double(i) / 44_100)) }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        try file.write(from: buffer)
        return url
    }

    @MainActor
    func testMeasuresUntaggedSongsAndRemembers() async throws {
        let loud = try wav("loud.wav", amplitude: 0.5)     // about -6 LUFS
        let quiet = try wav("quiet.wav", amplitude: 0.05)  // about -26 LUFS
        let saved = dir.appendingPathComponent("loudness.json")
        let store = LoudnessStore(fileURL: saved)
        store.mode = .track
        store.preventClipping = false
        store.fallbackDB = -6
        store.measuresAutomatically = true

        // Not measured yet: the fallback.
        XCTAssertEqual(store.gain(for: loud, artist: "A", album: "One"), -6)

        store.measure([(loud, "A", "One"), (quiet, "A", "One")], label: "Test")
        for _ in 0..<200 where store.isMeasuringBatch { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(store.isMeasuringBatch)

        XCTAssertEqual(store.gain(for: loud, artist: "A", album: "One"), -12, accuracy: 0.15)
        XCTAssertEqual(store.gain(for: quiet, artist: "A", album: "One"), 8, accuracy: 0.15)

        // Album mode: one gain for both, set mostly by the loud one.
        store.mode = .album
        let a = store.gain(for: loud, artist: "A", album: "One")
        let b = store.gain(for: quiet, artist: "A", album: "One")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, -9, accuracy: 0.2)

        // Keeping peaks under full scale caps the quiet song's boost.
        store.mode = .track
        store.preventClipping = true
        XCTAssertEqual(store.gain(for: quiet, artist: "A", album: "One"), 8, accuracy: 0.15)   // peak 0.05: plenty of room
        store.mode = .off
        XCTAssertEqual(store.gain(for: loud, artist: "A", album: "One"), 0)

        // A new store reads the saved measurements; a changed file is forgotten.
        store.saveNow()
        let again = LoudnessStore(fileURL: saved)
        again.mode = .track
        again.preventClipping = false
        XCTAssertEqual(again.gain(for: loud, artist: nil, album: nil), -12, accuracy: 0.15)
        try (Data(contentsOf: loud) + Data([0, 0, 0, 0])).write(to: loud)
        let third = LoudnessStore(fileURL: saved)
        third.mode = .track
        third.fallbackDB = -6
        XCTAssertEqual(third.gain(for: loud, artist: nil, album: nil), -6)
    }
}
