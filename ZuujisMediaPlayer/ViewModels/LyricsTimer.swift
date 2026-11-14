// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import Speech

/// "Time These Lyrics": turns untimed lyrics into synced ones by listening to
/// the song. Apple's on-device speech recognizer (`SpeechTranscriber`) writes
/// down the sung words with a time for each; `LyricsAligner` lines those up
/// with the known lyrics, so recognition mistakes only cost the odd word, not
/// the text. Nothing leaves the Mac (the recognizer's language model may be
/// downloaded from Apple once). The result is saved as enhanced LRC in the
/// app's own folder (`wordsFile`), which `LyricsStore` reads before any other
/// source; the music folder is never written.
enum LyricsTimer {
    enum Failure: LocalizedError {
        case unsupportedLanguage, noWordsHeard, couldNotSave(String)
        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage: return "Speech recognition isn't available for this language."
            case .noWordsHeard: return "No sung words were recognised in this song."
            case .couldNotSave(let why): return "Couldn't save the timed lyrics: \(why)"
            }
        }
    }

    /// Recognises the song's words with their start times (seconds), several
    /// times over: the file as it is, then copies made for the voice (see
    /// `voiceCopies`). Each pass hears words the others miss, and
    /// `LyricsAligner` combines them.
    static func listen(to url: URL, locale: Locale = Locale(identifier: "en-US"),
                       progress: @escaping @MainActor (String) -> Void) async throws -> [[LyricsAligner.Word]] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupportedLanguage
        }
        let probe = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                      reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            await progress("Downloading the speech model…")
            try await install.downloadAndInstall()
        }
        await progress("Listening to the song…")
        var passes = [try await recognise(url, locale: supported)]
        let copies = (try? voiceCopies(of: url)) ?? []
        defer { for copy in copies { try? FileManager.default.removeItem(at: copy) } }
        for copy in copies {
            try Task.checkCancellation()
            // A copy that fails only costs its extra words.
            if let words = try? await recognise(copy, locale: supported) { passes.append(words) }
        }
        passes.removeAll(where: \.isEmpty)
        if passes.isEmpty { throw Failure.noWordsHeard }
        return passes
    }

    /// One recognition pass over a file.
    private static func recognise(_ url: URL, locale: Locale) async throws -> [LyricsAligner.Word] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let collect = Task {
            var words: [LyricsAligner.Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    for piece in text.split(whereSeparator: \.isWhitespace) {
                        words.append(.init(time: range.start.seconds, text: String(piece),
                                           duration: range.duration.seconds))
                    }
                }
            }
            return words
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value
    }

    /// Temporary copies of the song that favour the singer: the channels
    /// mixed to one (a lead vocal sits in the middle, so it gains on
    /// instruments panned to the sides), and that mix band-limited to
    /// 180 Hz – 5 kHz (bass, kick and cymbals out). The recognizer is built
    /// for speech and often hears nothing under a full stereo mix. Written
    /// to the temporary folder, same sample rate and length, so word times
    /// need no correction; the caller deletes them.
    private static func voiceCopies(of url: URL) throws -> [URL] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        guard rate > 0, channels > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536),
              let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 65_536),
              let band = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 65_536) else { return [] }
        let folder = FileManager.default.temporaryDirectory
        let stem = "zmp-listen-" + UUID().uuidString
        let bandURL = folder.appendingPathComponent(stem + "-band.caf")
        // A one-channel file is its own mix.
        let mixURL = channels > 1 ? folder.appendingPathComponent(stem + "-mix.caf") : nil
        do {
            let bandFile = try AVAudioFile(forWriting: bandURL, settings: mono.settings)
            let mixFile = try mixURL.map { try AVAudioFile(forWriting: $0, settings: mono.settings) }
            var high = Biquad(highPass: 180, rate: rate), low = Biquad(lowPass: min(5000, rate * 0.45), rate: rate)
            // Reading at the end throws (eofErr) rather than returning nothing,
            // and an MP3's length is an estimate, so stop on either.
            while file.framePosition < file.length {
                do { try file.read(into: input) } catch { break }
                let frames = Int(input.frameLength)
                guard frames > 0, let source = input.floatChannelData,
                      let mix = mixed.floatChannelData?[0], let out = band.floatChannelData?[0] else { break }
                let gain = 1 / Float(channels)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += source[channel][frame] }
                    let sample = sum * gain
                    mix[frame] = sample
                    out[frame] = low.step(high.step(sample))
                }
                mixed.frameLength = input.frameLength
                band.frameLength = input.frameLength
                try mixFile?.write(from: mixed)
                try bandFile.write(from: band)
            }
        } catch {
            for made in [mixURL, bandURL].compactMap({ $0 }) { try? FileManager.default.removeItem(at: made) }
            throw error
        }
        return [mixURL, bandURL].compactMap { $0 }
    }

    /// A second-order Butterworth section (Audio EQ Cookbook).
    private struct Biquad {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        private init(frequency: Double, rate: Double, highPass: Bool) {
            let w = 2 * Double.pi * frequency / rate
            let alpha = sin(w) / (2 * 0.7071), c = cos(w), a0 = 1 + alpha
            let edge = highPass ? (1 + c) / 2 : (1 - c) / 2
            b0 = Float(edge / a0)
            b1 = Float((highPass ? -(1 + c) : 1 - c) / a0)
            b2 = Float(edge / a0)
            a1 = Float(-2 * c / a0)
            a2 = Float((1 - alpha) / a0)
        }
        init(highPass frequency: Double, rate: Double) { self.init(frequency: frequency, rate: rate, highPass: true) }
        init(lowPass frequency: Double, rate: Double) { self.init(frequency: frequency, rate: rate, highPass: false) }

        mutating func step(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// Bumped when the timing method improves: older files are ignored, so
    /// those songs show their usual lyrics again and are re-timed by the next
    /// album or library run. 2: line times follow what is actually sung.
    /// 3: lines may move up to 6 s; partly heard openings back up.
    /// 4: several listening passes (voice copies) are combined.
    nonisolated static let wordsRevision = 4

    /// The saved word timing for `song`, if it was made by the current method.
    nonisolated static func currentWordsText(for song: URL) -> String? {
        guard let text = try? String(contentsOf: wordsFile(for: song), encoding: .utf8),
              text.contains("[zmp-words-rev:\(wordsRevision)]") else { return nil }
        return text
    }

    /// Where word-timed lyrics are kept: the app's own folder, never beside
    /// the music. `LyricsStore` reads it before any other source.
    nonisolated static func wordsFile(for song: URL) -> URL {
        let dir = AppPaths.support.appendingPathComponent("Lyrics/Words", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var hash: UInt64 = 5381
        for byte in song.path.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return dir.appendingPathComponent(String(hash, radix: 16) + ".lrc")
    }

    /// Listens, aligns and saves. Untimed lyrics get line and word times;
    /// line-timed lyrics keep their line times and gain word times.
    static func time(_ lyrics: Lyrics, song: URL, title: String?, artist: String?,
                     progress: @escaping @MainActor (String) -> Void) async throws -> Lyrics {
        let heard = try await listen(to: song, progress: progress)
        await progress("Lining up the words…")
        let lines = lyrics.lines.map(\.text)
        let timing = lyrics.isSynced
            ? LyricsAligner.alignWords(timedLines: lyrics.lines.map { ($0.time ?? 0, $0.text) }, passes: heard)
            : LyricsAligner.align(lines: lines, passes: heard)
        var text = "[zmp-song:\(song.path)]\n[zmp-words-rev:\(wordsRevision)]\n"
        if let artist, !artist.isEmpty { text += "[ar:\(artist)]\n" }
        if let title, !title.isEmpty { text += "[ti:\(title)]\n" }
        text += "[by:Zuujis Media Player, timed by on-device speech recognition]\n"
        text += LyricsAligner.lrc(lines: lines, timing: timing)
        do {
            try text.write(to: wordsFile(for: song), atomically: true, encoding: .utf8)
        } catch {
            throw Failure.couldNotSave(error.localizedDescription)
        }
        guard let parsed = Lyrics.parse(text), parsed.isSynced else { throw Failure.noWordsHeard }
        return parsed
    }
}
