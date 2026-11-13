// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The music library browser: artists, their albums, and the songs under the
/// current choice. Double-click a song to play it with the songs around it as
/// the playlist; right-click for play and add.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var queue: PlaybackQueue

    @State private var artist: String?
    @State private var album: LibraryModel.Album?
    @State private var search = ""
    @State private var editing: EditTarget?

    // Grouping a few thousand tracks is cheap but not free; redo it when the
    // library, the choice or the search changes, not on every redraw.
    @State private var artists: [LibraryModel.Artist] = []
    @State private var albums: [LibraryModel.Album] = []
    @State private var songs: [LibraryTrack] = []

    var body: some View {
        VStack(spacing: 10) {
            header

            if library.folders.isEmpty {
                emptyState
            } else {
                HStack(spacing: 10) {
                    column(title: "Artists", count: artists.count) { artistList }
                        .frame(width: 210)
                    column(title: "Albums", count: albums.count) { albumList }
                        .frame(width: 250)
                    column(title: "Songs", count: songs.count) { songList }
                }
                // Fixed height: each column scrolls inside it instead of the
                // card growing to fit a long list.
                .frame(height: 300)
            }
        }
        .card()
        .onAppear(perform: refresh)
        .onChange(of: library.tracks) { _, _ in refresh() }
        .onChange(of: artist) { _, _ in album = nil; refresh() }
        .onChange(of: album) { _, _ in refreshSongs() }
        .onChange(of: search) { _, _ in refresh() }
        .sheet(item: $editing) { target in
            EditTagsSheet(target: target) { edit, write in library.apply(edit, to: target.tracks, writeToFiles: write) }
        }
        .alert("Some changes were not written to files", isPresented: Binding(
            get: { library.writeReport != nil }, set: { if !$0 { library.writeReport = nil } })) {
            Button("OK") { library.writeReport = nil }
        } message: { Text(library.writeReport ?? "") }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.violet)
            Text("LIBRARY")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.85))
            Text(status)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                TextField("Search songs, artists, albums", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 190)
            }
            .pill()

            Menu {
                Button("Add Music Folder…") { addFolder() }
                if !library.folders.isEmpty {
                    Divider()
                    Section("Folders") {
                        ForEach(library.folders, id: \.self) { folder in
                            let offline = library.offlineFolders.contains(folder)
                            Button(role: .destructive) {
                                library.removeFolder(folder)
                            } label: {
                                Text("Remove \(folder.lastPathComponent)" + (offline ? " (offline)" : ""))
                            }
                        }
                    }
                    Divider()
                    Button("Rescan Library") { library.rescan() }
                }
            } label: {
                Label("Folders", systemImage: "folder.badge.plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .pill()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add or remove music folders, or rescan")
        }
    }

    private var status: String {
        if library.isScanning, library.scanTotal > 0 {
            return "Reading tags… \(library.scanDone) of \(library.scanTotal)"
        }
        if library.isScanning { return "Scanning…" }
        guard !library.folders.isEmpty else { return "" }
        var text = "\(library.tracks.count) songs"
        if !library.offlineFolders.isEmpty {
            let n = library.offlineFolders.count
            text += " · \(n) folder\(n == 1 ? "" : "s") offline"
        }
        return text
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.house")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.3))
            Text("Add a folder of music to build your library")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text("Folders on external drives work too. They stay listed when the drive is unplugged.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            Button {
                addFolder()
            } label: {
                Label("Add Music Folder…", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .pill(active: true)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: Columns

    private func column<Content: View>(title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title.uppercased())  \(count)")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 1) { content() }
                    .padding(4)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
        }
    }

    private var artistList: some View {
        Group {
            row("All Artists", detail: "\(library.tracks.count)", selected: artist == nil) { artist = nil }
            ForEach(artists) { entry in
                row(entry.name, detail: "\(entry.trackCount)", selected: artist == entry.name) { artist = entry.name }
                    .contextMenu {
                        Button("Play All by \(entry.name)") { play(LibraryModel.songs(library.tracks, artist: entry.name, album: nil)) }
                        Button("Add to Playlist") { enqueue(LibraryModel.songs(library.tracks, artist: entry.name, album: nil)) }
                        Divider()
                        Button("Edit Info…") {
                            edit(LibraryModel.songs(library.tracks, artist: entry.name, album: nil), "Artist: \(entry.name)")
                        }
                    }
            }
        }
    }

    private var albumList: some View {
        Group {
            row("All Albums", detail: "", selected: album == nil) { album = nil }
            ForEach(albums) { entry in
                row(entry.name,
                    detail: entry.year.map(String.init) ?? "",
                    subtitle: artist == nil ? entry.artist : nil,
                    selected: album == entry) { album = entry }
                    .contextMenu {
                        Button("Play Album") { play(LibraryModel.songs(library.tracks, artist: entry.artist, album: entry)) }
                        Button("Add to Playlist") { enqueue(LibraryModel.songs(library.tracks, artist: entry.artist, album: entry)) }
                        Divider()
                        Button("Edit Info…") {
                            edit(LibraryModel.songs(library.tracks, artist: entry.artist, album: entry), "Album: \(entry.name)")
                        }
                    }
            }
        }
    }

    private var songList: some View {
        let playing = queue.current?.url
        return ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
            let isCurrent = song.url == playing
            HStack(spacing: 8) {
                Group {
                    if isCurrent {
                        Image(systemName: player.state == .playing ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(Theme.cyan)
                    } else {
                        Text(song.trackNumber.map(String.init) ?? "")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 22, alignment: .trailing)

                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Theme.cyan : .white.opacity(0.88))
                        .lineLimit(1)
                    Text(artist == nil || album == nil ? "\(song.artistName) · \(song.albumName)" : "")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .opacity(artist == nil || album == nil ? 1 : 0)
                        .frame(height: artist == nil || album == nil ? nil : 0)
                }
                Spacer(minLength: 6)
                Text(Self.time(song.duration))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(isCurrent ? Color.white.opacity(0.06) : .clear))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { player.play(urls: songs.map(\.url), startingAt: index) }
            .contextMenu {
                Button("Play") { player.play(urls: songs.map(\.url), startingAt: index) }
                Button("Add to Playlist") { player.enqueue([song.url]) }
                Divider()
                Button("Edit Info…") { edit([song], song.title) }
                if library.isEdited(song) {
                    Button("Revert Library Edits") { library.resetEdits(for: [song]) }
                }
            }
        }
    }

    private func row(_ title: String, detail: String, subtitle: String? = nil, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.black.opacity(0.85) : .white.opacity(0.85))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(selected ? Color.black.opacity(0.6) : .white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(selected ? Color.black.opacity(0.6) : .white.opacity(0.35))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(selected ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func refresh() {
        artists = LibraryModel.artists(library.tracks)
        if let artist, !artists.contains(where: { $0.name == artist }) { self.artist = nil }
        albums = LibraryModel.albums(library.tracks, artist: artist)
        if let album, !albums.contains(album) { self.album = nil }
        refreshSongs()
    }

    private func refreshSongs() {
        songs = LibraryModel.songs(library.tracks, artist: artist, album: album, search: search)
    }

    private func edit(_ tracks: [LibraryTrack], _ title: String) {
        guard !tracks.isEmpty else { return }
        editing = EditTarget(tracks: tracks, title: title)
    }

    private func play(_ tracks: [LibraryTrack]) {
        guard !tracks.isEmpty else { return }
        player.play(urls: tracks.map(\.url), startingAt: 0)
    }

    private func enqueue(_ tracks: [LibraryTrack]) {
        player.enqueue(tracks.map(\.url))
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders of music to add to the library."
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in library.addFolders(urls) }
        }
    }

    private static func time(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct EditTarget: Identifiable {
    let id = UUID()
    var tracks: [LibraryTrack]
    var title: String
}

/// Edits tags for one song, or for a whole album or artist at once. With
/// several songs a field that differs between them starts empty ("Multiple
/// values"); only the fields the user changes are applied. The audio files
/// themselves are modified only if the toggle is on.
struct EditTagsSheet: View {
    let target: EditTarget
    let onSave: (TagEdit, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var genre = ""
    @State private var year = ""
    @State private var track = ""
    @State private var disc = ""
    @State private var initial: [String: String] = [:]
    @AppStorage("libraryWriteTagsToFiles") private var writeToFiles = true

    private var single: Bool { target.tracks.count == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Info").font(.headline)
                Text(single ? target.title : "\(target.tracks.count) songs · \(target.title)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                if single { field("Title", $title, "title") }
                field("Artist", $artist, "artist")
                field("Album", $album, "album")
                field("Genre", $genre, "genre")
                field("Year", $year, "year")
                if single {
                    field("Track", $track, "track")
                    field("Disc", $disc, "disc")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Write changes into the audio files", isOn: $writeToFiles)
                Text(writeToFiles
                     ? "FLAC and MP3 files are updated, so other apps see the changes. Other formats keep them in the library only."
                     : "Changes are kept in the library only. The audio files are not modified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    private func field(_ label: String, _ text: Binding<String>, _ key: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            TextField(initial[key] == "" && !single ? "Multiple values" : "", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// The value every song shares, or "" when they differ.
    private func common(_ value: (LibraryTrack) -> String?) -> String {
        let values = Set(target.tracks.map { value($0) ?? "" })
        return values.count == 1 ? values.first! : ""
    }

    private func load() {
        title = common { $0.title }
        artist = common { $0.artist }
        album = common { $0.album }
        genre = common { $0.genre }
        year = common { $0.year.map(String.init) }
        track = common { $0.trackNumber.map(String.init) }
        disc = common { $0.discNumber.map(String.init) }
        initial = ["title": title, "artist": artist, "album": album, "genre": genre,
                   "year": year, "track": track, "disc": disc]
    }

    private func save() {
        func text(_ value: String, _ key: String) -> String? {
            value == initial[key] ? nil : value
        }
        func number(_ value: String, _ key: String) -> Int? {
            guard value != initial[key] else { return nil }
            return LibraryModel.leadingNumber(value) ?? 0
        }
        var edit = TagEdit(
            title: single ? text(title, "title") : nil,
            artist: text(artist, "artist"), album: text(album, "album"), genre: text(genre, "genre"),
            year: number(year, "year"))
        if single {
            edit.trackNumber = number(track, "track")
            edit.discNumber = number(disc, "disc")
        }
        if !edit.isEmpty { onSave(edit, writeToFiles) }
        dismiss()
    }
}
