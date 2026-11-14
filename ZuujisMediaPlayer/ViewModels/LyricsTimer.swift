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

    /// Recognises the song's words with their start times (seconds).
    static func listen(to url: URL, locale: Locale = Locale(identifier: "en-US"),
                       progress: @escaping @MainActor (String) -> Void) async throws -> [LyricsAligner.Word] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupportedLanguage
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await progress("Downloading the speech model…")
            try await install.downloadAndInstall()
        }
        await progress("Listening to the song…")
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let collect = Task {
            var words: [LyricsAligner.Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    for piece in text.split(whereSeparator: \.isWhitespace) {
                        words.append(.init(time: range.start.seconds, text: String(piece)))
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
        let words = try await collect.value
        if words.isEmpty { throw Failure.noWordsHeard }
        return words
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
            ? LyricsAligner.alignWords(timedLines: lyrics.lines.map { ($0.time ?? 0, $0.text) }, heard: heard)
            : LyricsAligner.align(lines: lines, heard: heard)
        var text = "[zmp-song:\(song.path)]\n"
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
