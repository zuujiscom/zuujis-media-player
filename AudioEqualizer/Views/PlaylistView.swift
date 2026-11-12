// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The play list in its own window: what is queued, what is playing, and the
/// shuffle and repeat that decide what comes next.
struct PlaylistView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var queue: PlaybackQueue

    @State private var selection = Set<QueueItem.ID>()
    @State private var search = ""

    private var visibleItems: [QueueItem] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return queue.items }
        return queue.items.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || ($0.artist?.localizedCaseInsensitiveContains(needle) ?? false)
                || ($0.album?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.hairline).frame(height: 1)

            if queue.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        .background(AmbientBackground().ignoresSafeArea())
        .preferredColorScheme(.dark)
        // Dropping files or folders here adds them to the end.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            player.enqueue(files)
            return true
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Playlist")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(summary)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                TextField("Filter", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 110)
            }
            .pill()

            Button {
                PlayerActions.addToPlaylist(in: player)
            } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .pill()
            }
            .buttonStyle(.plain)
            .help("Add files or folders to the end of the playlist")

            Button {
                queue.clear()
                player.stop()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .pill()
            }
            .buttonStyle(.plain)
            .disabled(queue.items.isEmpty)
            .help("Clear the playlist")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Color.white.opacity(0.025))
    }

    private var summary: String {
        let count = queue.items.count
        guard count > 0 else { return "Empty" }
        let known = queue.items.compactMap(\.duration)
        let total = known.reduce(0, +)
        let tracks = "\(count) track\(count == 1 ? "" : "s")"
        guard !known.isEmpty else { return tracks }
        let hours = Int(total) / 3600, minutes = (Int(total) % 3600) / 60
        let length = hours > 0 ? "\(hours) hr \(minutes) min" : "\(max(minutes, 1)) min"
        // Tags load a few files at a time, so the total can still be filling in.
        return known.count < count ? tracks : "\(tracks) · \(length)"
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            ForEach(visibleItems) { item in
                PlaylistRow(item: item,
                            isCurrent: item.id == queue.currentID,
                            isPlaying: item.id == queue.currentID && player.state == .playing)
                    .tag(item.id)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            // Reordering only makes sense on the whole, unfiltered list.
            .onMove(perform: search.isEmpty ? { queue.move(fromOffsets: $0, toOffset: $1) } : nil)
            .onDelete { offsets in
                queue.remove(Set(offsets.map { visibleItems[$0].id }))
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .contextMenu(forSelectionType: QueueItem.ID.self) { ids in
            if let id = ids.first, ids.count == 1 {
                Button("Play") { player.play(id) }
            }
            if !ids.isEmpty {
                Button("Remove from Playlist", role: .destructive) { queue.remove(ids) }
            }
        } primaryAction: { ids in
            // Double-click.
            if let id = ids.first { player.play(id) }
        }
        .onDeleteCommand {
            queue.remove(selection)
            selection = []
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.3))
            Text("The playlist is empty")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text("Drop audio files or a folder here, or use Add.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PlaylistRow: View {
    let item: QueueItem
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : (isCurrent ? "speaker.fill" : "music.note"))
                .font(.system(size: 10))
                .foregroundStyle(isCurrent ? Theme.cyan : .white.opacity(0.25))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.cyan : .white)
                    .lineLimit(1)
                if let line = subtitle {
                    Text(line)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let duration = item.duration {
                Text(Self.format(duration))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var subtitle: String? {
        let parts = [item.artist, item.album].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
