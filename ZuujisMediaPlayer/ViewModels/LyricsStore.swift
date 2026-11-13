// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Combine
import Foundation

/// Finds the lyrics of whatever the player has loaded. Everything is read
/// from the user's own files — nothing is fetched from the network:
///
/// 1. a sidecar beside the song with the same name: `.lrc` (synced) or `.txt`;
/// 2. a FLAC's `LYRICS` / `UNSYNCEDLYRICS` Vorbis comment;
/// 3. MP3's USLT and M4A's ©lyr, which AVFoundation exposes.
///
/// Either source may hold LRC text, so each is run through `Lyrics.parse`.
@MainActor
final class LyricsStore: ObservableObject {
    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var isLoading = false
    /// Which file `lyrics` belongs to; the view shows nothing stale.
    @Published private(set) var url: URL?

    private var cancellable: AnyCancellable?
    private var task: Task<Void, Never>?

    func attach(to player: PlayerEngine) {
        guard cancellable == nil else { return }
        cancellable = player.$track
            .map { $0?.url }
            .removeDuplicates()
            .sink { [weak self] url in self?.load(url) }
    }

    private func load(_ url: URL?) {
        task?.cancel()
        self.url = url
        lyrics = nil
        guard let url else { isLoading = false; return }
        isLoading = true
        task = Task { [weak self] in
            let found = await Self.find(for: url)
            guard !Task.isCancelled, let self, self.url == url else { return }
            self.lyrics = found
            self.isLoading = false
        }
    }

    // MARK: Reading

    nonisolated static func find(for url: URL) async -> Lyrics? {
        if let sidecar = await Task.detached(priority: .utility, operation: { sidecar(for: url) }).value {
            return sidecar
        }
        if url.pathExtension.lowercased() == "flac" {
            let tags = await Task.detached(priority: .utility) { FLACTags.read(url) }.value
            for key in ["SYNCEDLYRICS", "LYRICS", "UNSYNCEDLYRICS", "LYRICS-ENG"] {
                if let text = tags?[key], let lyrics = Lyrics.parse(text) { return lyrics }
            }
            return nil
        }
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for id in [AVMetadataIdentifier.id3MetadataUnsynchronizedLyric, .iTunesMetadataLyrics] {
            if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first,
               let text = try? await item.load(.stringValue), let lyrics = Lyrics.parse(text) {
                return lyrics
            }
        }
        return nil
    }

    nonisolated static func sidecar(for url: URL) -> Lyrics? {
        let base = url.deletingPathExtension()
        for ext in ["lrc", "LRC", "txt", "TXT"] {
            let file = base.appendingPathExtension(ext)
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size < 2 * 1024 * 1024,
                  let data = try? Data(contentsOf: file) else { continue }
            // Old LRC files are often not UTF-8.
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
                ?? String(decoding: data, as: UTF8.self)
            if let lyrics = Lyrics.parse(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text) { return lyrics }
        }
        return nil
    }
}
