// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The music library browser: by artist, by genre, or by saved playlist, and
/// the songs under the current choice. Double-click a song to play it with the
/// songs around it as the queue; right-click for play, queue, playlists and
/// tag editing.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var playlists: PlaylistStore

    enum Browse: String { case artists, genres, playlists }

    /// With no EQ panel showing, the columns take the window's spare height
    /// instead of stopping at their usual 300 points.
    var fillsHeight = false

    @AppStorage("libraryBrowse") private var browseRaw = Browse.artists.rawValue
    @AppStorage("libraryWriteTagsToFiles") private var writeToFiles = true
    private var browse: Browse { Browse(rawValue: browseRaw) ?? .artists }

    @State private var genre: String?
    @State private var artist: String?
    @State private var album: LibraryModel.Album?
    @State private var playlistID: UUID?
    @State private var search = ""
    @State private var editing: EditTarget?
    @State private var namePrompt: NamePrompt?
    @State private var deleting: Playlist?
    @State private var notice: String?
    /// Songs the user has clicked: ids (paths) in the current song list.
    @State private var selection = Set<String>()
    @State private var anchor: String?

    // Grouping a few thousand tracks is cheap but not free; redo it when the
    // library, the choice or the search changes, not on every redraw.
    @State private var genres: [LibraryModel.Genre] = []
    @State private var artists: [LibraryModel.Artist] = []
    @State private var albums: [LibraryModel.Album] = []
    @State private var songs: [LibraryTrack] = []
    @State private var byPath: [String: LibraryTrack] = [:]

    /// Dragging a song onto a playlist carries its path with this prefix.
    static let dragPrefix = "zuujistrack:"

    var body: some View {
        VStack(spacing: 10) {
            header

            if library.folders.isEmpty, browse != .playlists {
                emptyState
            } else {
                HStack(spacing: 10) {
                    switch browse {
                    case .artists:
                        column(title: "Artists", count: artists.count) { artistList }.frame(width: 226)
                        column(title: "Albums", count: albums.count) { albumList }.frame(width: 250)
                        column(title: "Songs", count: songs.count, selected: selection.count) { songList }
                    case .genres:
                        column(title: "Genres", count: genres.count) { genreList }.frame(width: 172)
                        column(title: "Artists", count: artists.count) { artistList }.frame(width: 198)
                        column(title: "Albums", count: albums.count) { albumList }.frame(width: 216)
                        column(title: "Songs", count: songs.count, selected: selection.count) { songList }
                    case .playlists:
                        column(title: "Playlists", count: playlists.playlists.count, accessory: {
                            Button { newPlaylist(with: []) } label: {
                                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.ink.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .help("New playlist")
                        }) { playlistList }.frame(width: 230)
                        column(title: "Songs", count: currentPlaylist?.paths.count ?? 0, selected: selection.count) { playlistSongList }
                    }
                }
                // Fixed height: each column scrolls inside it instead of the
                // card growing to fit a long list.
                .frame(minHeight: 300, idealHeight: 300, maxHeight: fillsHeight ? .infinity : 300)
            }
        }
        .card()
        .onAppear(perform: refresh)
        .onChange(of: library.tracks) { _, _ in refresh() }
        #if DEBUG
        .task {
            // DebugGallery screenshots choose what the library shows.
            let env = ProcessInfo.processInfo.environment
            try? await Task.sleep(for: .seconds(1))
            if let name = env["ZMP_GALLERY_ARTIST"] { artist = name }
            if let name = env["ZMP_GALLERY_PLAYLIST"] { playlistID = playlists.playlists.first { $0.name == name }?.id }
        }
        #endif
        .onChange(of: browseRaw) { _, _ in album = nil; clearSelection(); refresh() }
        .onChange(of: genre) { _, _ in artist = nil; album = nil; clearSelection(); refresh() }
        .onChange(of: artist) { _, _ in album = nil; clearSelection(); refresh() }
        .onChange(of: album) { _, _ in clearSelection(); refreshSongs() }
        .onChange(of: search) { _, _ in refresh() }
        .onChange(of: playlistID) { _, _ in clearSelection() }
        .sheet(item: $editing) { target in
            EditTagsSheet(target: target) { edit, write in
                library.apply(edit, to: target.tracks, writeToFiles: write)
                // Keep the selection on an artist that was just renamed.
                if let old = target.artistName, artist == old, let new = edit.artist {
                    artist = new.isEmpty ? nil : new
                }
            }
        }
        .sheet(item: $namePrompt) { prompt in NameSheet(prompt: prompt) }
        .confirmationDialog("Delete \"\(deleting?.name ?? "")\"?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                if let list = deleting {
                    if playlistID == list.id { playlistID = nil }
                    playlists.delete(list.id)
                }
                deleting = nil
            }
        } message: { Text("The songs themselves are not deleted.") }
        .alert("Some changes were not written to files", isPresented: Binding(
            get: { library.writeReport != nil }, set: { if !$0 { library.writeReport = nil } })) {
            Button("OK") { library.writeReport = nil }
        } message: { Text(library.writeReport ?? "") }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            SectionTitle(text: "Library", systemImage: "books.vertical.fill")

            SegmentedPills(options: [(Browse.artists.rawValue, "Artists"),
                                     (Browse.genres.rawValue, "Genres"),
                                     (Browse.playlists.rawValue, "Playlists")],
                           selection: $browseRaw)

            Text(notice ?? status)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(notice == nil ? Theme.ink.opacity(0.45) : Theme.mint)
                .lineLimit(1)

            Spacer(minLength: 8)

            if browse != .playlists {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink.opacity(0.45))
                    TextField("Search", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 140)
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ink.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .pill()
            }

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
                    .foregroundStyle(Theme.ink.opacity(0.85))
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
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.signal)
                .shadow(color: Theme.violet.opacity(0.5), radius: 12)
            Text("Add a folder of music to build your library")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.7))
            Text("Folders on external drives work too. They stay listed when the drive is unplugged.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.4))
            Button {
                addFolder()
            } label: {
                Label("Add Music Folder…", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.onSignal)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Capsule().fill(Theme.signal))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: Columns

    private func column<Content: View, Accessory: View>(
        title: String, count: Int, selected: Int = 0,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(Theme.ink.opacity(0.55))
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.ink.opacity(0.08)))
                if selected > 0 {
                    Text("\(selected) selected")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.cyan)
                }
                Spacer(minLength: 0)
                accessory()
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 1) { content() }
                    .padding(5)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.well.opacity(Theme.palette.isLight ? 1 : 0.72)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func column<Content: View>(title: String, count: Int, selected: Int = 0, @ViewBuilder content: () -> Content) -> some View {
        column(title: title, count: count, selected: selected, accessory: { EmptyView() }, content: content)
    }

    // MARK: Genres

    private var genreList: some View {
        Group {
            row("All Genres", detail: "\(library.tracks.count)", icon: .symbol("guitars.fill"), selected: genre == nil) { genre = nil }
            ForEach(genres) { entry in
                row(entry.name, detail: "\(entry.trackCount)", icon: .genre, selected: genre == entry.name) { genre = entry.name }
                    .contextMenu {
                        let tracks = LibraryModel.songs(library.tracks, inGenre: entry.name)
                        Button("Play All \(entry.name)") { play(tracks) }
                        Button("Add to Queue") { enqueue(tracks) }
                        addToPlaylistMenu { tracks }
                        if entry.name != LibraryModel.unknownGenre {
                            Divider()
                            Button("Rename Genre…") {
                                namePrompt = NamePrompt(title: "Rename Genre", message: "Applies to \(tracks.count) songs.",
                                                        initial: entry.name, confirm: "Rename") { name in
                                    setGenre(name, on: tracks)
                                    if genre == entry.name { genre = name.isEmpty ? nil : name }
                                }
                            }
                        }
                    }
            }
        }
    }

    // MARK: Artists and albums

    private var artistList: some View {
        Group {
            row("All Artists", detail: "\(scoped.count)", icon: .symbol("person.2.fill"), selected: artist == nil) { artist = nil }
            ForEach(artists) { entry in
                row(entry.name, detail: "\(entry.trackCount)", icon: .artist, selected: artist == entry.name) { artist = entry.name }
                    .contextMenu {
                        let tracks = LibraryModel.songs(scoped, artist: entry.name, album: nil)
                        Button("Play All by \(entry.name)") { play(tracks) }
                        Button("Add to Queue") { enqueue(tracks) }
                        addToPlaylistMenu(suggestion: entry.name) { tracks }
                        Divider()
                        Button("Edit Info…") { edit(tracks, "Artist: \(entry.name)", artist: entry.name) }
                        genreMenu { tracks }
                    }
            }
        }
    }

    private var albumList: some View {
        Group {
            row("All Albums", detail: "", icon: .symbol("square.stack"), selected: album == nil) { album = nil }
            ForEach(albums) { entry in
                row(entry.name,
                    detail: entry.year.map(String.init) ?? "",
                    subtitle: artist == nil ? entry.artist : nil,
                    icon: .album,
                    selected: album == entry) { album = entry }
                    .contextMenu {
                        let tracks = LibraryModel.songs(scoped, artist: entry.artist, album: entry)
                        Button("Play Album") { play(tracks) }
                        Button("Add to Queue") { enqueue(tracks) }
                        addToPlaylistMenu(suggestion: entry.name) { tracks }
                        Divider()
                        Button("Edit Info…") { edit(tracks, "Album: \(entry.name)") }
                        genreMenu { tracks }
                    }
            }
        }
    }

    // MARK: Songs

    private var songList: some View {
        let playing = queue.current?.url
        return ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
            let isCurrent = song.url == playing
            let isSelected = selection.contains(song.id)
            HStack(spacing: 8) {
                Group {
                    if isCurrent {
                        Image(systemName: player.state == .playing ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(Theme.cyan)
                    } else {
                        Text(song.trackNumber.map(String.init) ?? "")
                            .foregroundStyle(Theme.ink.opacity(0.35))
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 22, alignment: .trailing)

                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Theme.cyan : Theme.ink.opacity(0.88))
                        .lineLimit(1)
                    Text(artist == nil || album == nil ? "\(song.artistName) · \(song.albumName)" : "")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ink.opacity(0.4))
                        .lineLimit(1)
                        .opacity(artist == nil || album == nil ? 1 : 0)
                        .frame(height: artist == nil || album == nil ? nil : 0)
                }
                Spacer(minLength: 6)
                heart(song.id)
                Text(Self.time(song.duration))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.ink.opacity(0.4))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .modifier(RowHighlight(isSelected: isSelected, isCurrent: isCurrent))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { player.play(urls: songs.map(\.url), startingAt: index) }
            .onTapGesture { click(song.id, in: songs.map(\.id)) }
            .draggable(Self.dragPrefix + song.id)
            .contextMenu {
                let targets = songTargets(for: song)
                let many = targets.count > 1
                Button(many ? "Play \(targets.count) Songs" : "Play") {
                    if many { player.play(urls: targets.map(\.url), startingAt: 0) }
                    else { player.play(urls: songs.map(\.url), startingAt: index) }
                }
                favoriteButton(targets.map(\.id))
                Button(many ? "Add \(targets.count) Songs to Queue" : "Add to Queue") { enqueue(targets) }
                addToPlaylistMenu(suggestion: many ? "" : song.title) { targets }
                Divider()
                Button(many ? "Edit Info for \(targets.count) Songs…" : "Edit Info…") {
                    edit(targets, many ? "\(targets.count) songs" : song.title)
                }
                genreMenu { targets }
                if targets.contains(where: library.isEdited) {
                    Button("Revert Library Edits") { library.resetEdits(for: targets) }
                }
                Divider()
                Button("Select All Songs") { selection = Set(songs.map(\.id)) }
            }
        }
    }

    // MARK: Playlists

    private var currentPlaylist: Playlist? { playlists.playlist(playlistID) }

    private var playlistList: some View {
        Group {
            if playlists.playlists.isEmpty {
                Text("No playlists yet. Use + above, or right-click a song, album, artist or genre and choose Add to Playlist.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.4))
                    .padding(8)
            }
            ForEach(playlists.playlists) { list in
                row(list.name, detail: "\(list.paths.count)",
                    icon: list.id == PlaylistStore.favoritesID ? .favorites : .playlist,
                    selected: playlistID == list.id) { playlistID = list.id }
                    .dropDestination(for: String.self) { items, _ in
                        let paths = items.compactMap(Self.path(fromDrag:))
                        guard !paths.isEmpty else { return false }
                        addToPlaylist(paths, list.id)
                        return true
                    }
                    .contextMenu {
                        let urls = list.paths.map { URL(fileURLWithPath: $0) }
                        Button("Play") { if !urls.isEmpty { player.play(urls: urls, startingAt: 0) } }
                            .disabled(urls.isEmpty)
                        Button("Add to Queue") { player.enqueue(urls) }
                            .disabled(urls.isEmpty)
                        Divider()
                        if list.id != PlaylistStore.favoritesID {
                            Button("Rename…") {
                                namePrompt = NamePrompt(title: "Rename Playlist", message: nil, initial: list.name,
                                                        confirm: "Rename") { playlists.rename(list.id, to: $0) }
                            }
                        }
                        Button("Duplicate") {
                            playlistID = playlists.create(name: list.name + " copy", paths: list.paths).id
                        }
                        if list.id != PlaylistStore.favoritesID {
                            Divider()
                            Button("Delete Playlist…", role: .destructive) { deleting = list }
                        }
                    }
            }
        }
    }

    private var playlistSongList: some View {
        Group {
            if let list = currentPlaylist {
                if list.paths.isEmpty {
                    Text("Empty. Add songs from the Artists or Genres view, or drag them onto this playlist.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink.opacity(0.4))
                        .padding(8)
                }
                let playable = PlayableList(list.paths)
                ForEach(Array(list.paths.enumerated()), id: \.element) { index, path in
                    playlistSongRow(path: path, index: index, list: list, playable: playable)
                }
            } else {
                Text(playlists.playlists.isEmpty ? "" : "Choose a playlist.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.4))
                    .padding(8)
            }
        }
    }

    private func playlistSongRow(path: String, index: Int, list: Playlist, playable: PlayableList) -> some View {
        let track = byPath[path]
        let isCurrent = queue.current?.url.path == path
        let exists = playable.position[path] != nil
        let isSelected = selection.contains(path)
        let title = track?.title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return HStack(spacing: 8) {
            Group {
                if isCurrent {
                    Image(systemName: player.state == .playing ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundStyle(Theme.cyan)
                } else {
                    Text("\(index + 1)").foregroundStyle(Theme.ink.opacity(0.35))
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.cyan : Theme.ink.opacity(exists ? 0.88 : 0.4))
                    .lineLimit(1)
                Text(exists ? (track.map { "\($0.artistName) · \($0.albumName)" } ?? "") : "File not found (drive offline?)")
                    .font(.system(size: 10))
                    .foregroundStyle(exists ? Theme.ink.opacity(0.4) : Theme.amber.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            heart(path)
            Text(Self.time(track?.duration))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.ink.opacity(0.4))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .modifier(RowHighlight(isSelected: isSelected, isCurrent: isCurrent))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard let start = playable.position[path] else { return }
            player.play(urls: playable.urls, startingAt: start)
        }
        .onTapGesture { click(path, in: list.paths) }
        .draggable(Self.dragPrefix + path)
        // Dropping a song here puts it just before this one.
        .dropDestination(for: String.self) { items, _ in
            let paths = items.compactMap(Self.path(fromDrag:))
            guard !paths.isEmpty else { return false }
            for dropped in paths {
                playlists.add([dropped], to: list.id)
                playlists.move(dropped, before: path, in: list.id)
            }
            return true
        }
        .contextMenu {
            let targets = list.paths.filter { selection.contains(path) ? selection.contains($0) : $0 == path }
            let many = targets.count > 1
            let playableTargets = targets.filter { playable.position[$0] != nil }
            Button(many ? "Play \(playableTargets.count) Songs" : "Play") {
                if many {
                    player.play(urls: playableTargets.map { URL(fileURLWithPath: $0) }, startingAt: 0)
                } else if let start = playable.position[path] {
                    player.play(urls: playable.urls, startingAt: start)
                }
            }
            .disabled(playableTargets.isEmpty)
            Button(many ? "Add \(playableTargets.count) Songs to Queue" : "Add to Queue") {
                player.enqueue(playableTargets.map { URL(fileURLWithPath: $0) })
            }
            .disabled(playableTargets.isEmpty)
            favoriteButton(targets)
            let tracks = targets.compactMap { byPath[$0] }
            if !tracks.isEmpty { addToPlaylistMenu { tracks } }
            if !many {
                Divider()
                Button("Move Up") { playlists.nudge(path, by: -1, in: list.id) }.disabled(index == 0)
                Button("Move Down") { playlists.nudge(path, by: 1, in: list.id) }.disabled(index == list.paths.count - 1)
            }
            if !tracks.isEmpty {
                Divider()
                Button(many ? "Edit Info for \(tracks.count) Songs…" : "Edit Info…") {
                    edit(tracks, many ? "\(tracks.count) songs" : (tracks[0].title))
                }
                genreMenu { tracks }
            }
            Divider()
            Button("Select All Songs") { selection = Set(list.paths) }
            Button(many ? "Remove \(targets.count) Songs from Playlist" : "Remove from Playlist", role: .destructive) {
                playlists.remove(Set(targets), from: list.id)
                selection.subtract(targets)
            }
        }
    }

    // MARK: Selection

    private func clearSelection() { selection = []; anchor = nil }

    /// A click on a song: select it; with ⌘ toggle it; with ⇧ select the
    /// range from the last click.
    private func click(_ id: String, in order: [String]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) {
            selection = Set(order[min(i, j)...max(i, j)])
        } else if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else {
            selection = [id]
            anchor = id
        }
    }

    /// What a right-click on `song` acts on: the whole selection when the
    /// song is part of it, else just the song. In list order.
    private func songTargets(for song: LibraryTrack) -> [LibraryTrack] {
        guard selection.contains(song.id) else { return [song] }
        return songs.filter { selection.contains($0.id) }
    }

    /// Hearts or un-hearts `paths` together: removes when all are favorites.
    private func favoriteButton(_ paths: [String]) -> some View {
        let all = paths.allSatisfy(playlists.isFavorite)
        let many = paths.count > 1
        return Button(all ? (many ? "Remove from Favorites" : "Remove from Favorites") : "Add to Favorites") {
            if all { playlists.remove(Set(paths), from: PlaylistStore.favoritesID) }
            else { playlists.add(paths, to: PlaylistStore.favoritesID) }
        }
    }

    /// The heart on a song row: filled when the song is a favorite.
    private func heart(_ path: String) -> some View {
        let on = playlists.isFavorite(path)
        return Button {
            playlists.toggleFavorite(path)
        } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .font(.system(size: 10.5))
                .foregroundStyle(on ? Theme.pink : Theme.ink.opacity(0.25))
        }
        .buttonStyle(.plain)
        .help(on ? "Remove from Favorites" : "Add to Favorites")
    }

    private static func path(fromDrag item: String) -> String? {
        item.hasPrefix(dragPrefix) ? String(item.dropFirst(dragPrefix.count)) : nil
    }

    // MARK: Menus

    /// "Add to Playlist ▸": new playlist, then each existing one.
    private func addToPlaylistMenu(suggestion: String = "", tracks: @escaping () -> [LibraryTrack]) -> some View {
        Menu("Add to Playlist") {
            Button("New Playlist…") { newPlaylist(with: tracks(), suggestion: suggestion) }
            if !playlists.playlists.isEmpty { Divider() }
            ForEach(playlists.playlists) { list in
                Button(list.name) { addToPlaylist(tracks().map(\.id), list.id) }
            }
        }
    }

    /// "Set Genre ▸": the genres already in the library, a new one, or none.
    private func genreMenu(tracks: @escaping () -> [LibraryTrack]) -> some View {
        Menu("Set Genre") {
            ForEach(genres.filter { $0.name != LibraryModel.unknownGenre }) { entry in
                Button(entry.name) { setGenre(entry.name, on: tracks()) }
            }
            Divider()
            Button("New Genre…") {
                namePrompt = NamePrompt(title: "New Genre", message: nil, initial: "", confirm: "Set") { name in
                    setGenre(name, on: tracks())
                }
            }
            Button("Clear Genre") { setGenre("", on: tracks()) }
        }
    }

    private func setGenre(_ name: String, on tracks: [LibraryTrack]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tracks.isEmpty else { return }
        library.apply(TagEdit(genre: trimmed), to: tracks, writeToFiles: writeToFiles)
    }

    private func newPlaylist(with tracks: [LibraryTrack], suggestion: String = "") {
        namePrompt = NamePrompt(title: "New Playlist",
                                message: tracks.isEmpty ? nil : "\(tracks.count) song\(tracks.count == 1 ? "" : "s") will be added.",
                                initial: suggestion, confirm: "Create") { name in
            let list = playlists.create(name: name, paths: tracks.map(\.id))
            playlistID = list.id
            flash("Created \(list.name)")
        }
    }

    private func addToPlaylist(_ paths: [String], _ id: UUID) {
        guard !paths.isEmpty, let list = playlists.playlist(id) else { return }
        let added = playlists.add(paths, to: id)
        flash(added == 0 ? "Already in \(list.name)" : "Added \(added) song\(added == 1 ? "" : "s") to \(list.name)")
    }

    private func flash(_ text: String) {
        notice = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if notice == text { notice = nil }
        }
    }

    /// The little picture at the start of a browse row.
    private enum RowIcon {
        case none, artist, album, genre, playlist, favorites
        case symbol(String)
    }

    private func row(_ title: String, detail: String, subtitle: String? = nil, icon: RowIcon = .none,
                     selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                switch icon {
                case .none: EmptyView()
                case .artist: Monogram(name: title, shape: .circle)
                case .album: Monogram(name: title, symbol: "music.note", shape: .square, size: 26)
                case .genre: Monogram(name: title, symbol: "tag.fill", shape: .square)
                case .playlist: Monogram(name: title, symbol: "music.note.list", shape: .square)
                case .favorites:
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.pink))
                case .symbol(let name): Monogram(name: title, symbol: name, shape: .circle, neutral: true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(Theme.ink.opacity(selected ? 1 : 0.86))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ink.opacity(selected ? 0.6 : 0.42))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.ink.opacity(selected ? 0.7 : 0.38))
            }
            .padding(.leading, 7)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 30)
            .modifier(RowHighlight(isSelected: selected))
            // The selected row carries the signal colours as a bar on its edge.
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(LinearGradient(colors: Theme.signalColors, startPoint: .top, endPoint: .bottom))
                        .frame(width: 3)
                        .padding(.vertical, 5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    /// The library narrowed to the chosen genre (in the Genres view).
    private var scoped: [LibraryTrack] {
        LibraryModel.songs(library.tracks, inGenre: browse == .genres ? genre : nil)
    }

    private func refresh() {
        byPath = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        genres = LibraryModel.genres(library.tracks)
        if let genre, !genres.contains(where: { $0.name == genre }) { self.genre = nil }
        let pool = scoped
        artists = LibraryModel.artists(pool)
        if let artist, !artists.contains(where: { $0.name == artist }) { self.artist = nil }
        albums = LibraryModel.albums(pool, artist: artist)
        if let album, !albums.contains(album) { self.album = nil }
        refreshSongs()
    }

    private func refreshSongs() {
        songs = LibraryModel.songs(scoped, artist: artist, album: album, search: search)
        if browse != .playlists { selection.formIntersection(songs.map(\.id)) }
    }

    private func edit(_ tracks: [LibraryTrack], _ title: String, artist: String? = nil) {
        guard !tracks.isEmpty else { return }
        editing = EditTarget(tracks: tracks, title: title, artistName: artist)
    }

    private func play(_ tracks: [LibraryTrack]) {
        guard !tracks.isEmpty else { return }
        player.play(urls: tracks.map(\.url), startingAt: 0)
    }

    private func enqueue(_ tracks: [LibraryTrack]) {
        player.enqueue(tracks.map(\.url))
    }

    private func addFolder() { LibraryActions.addFolder(to: library) }

    private static func time(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Shared by the library card and the File menu.
@MainActor
enum LibraryActions {
    static func addFolder(to library: LibraryStore) {
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
}

/// A one-line text prompt: new playlist, rename, new genre.
struct NamePrompt: Identifiable {
    let id = UUID()
    var title: String
    var message: String?
    var initial: String
    var confirm: String
    var action: (String) -> Void
}

struct NameSheet: View {
    let prompt: NamePrompt
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.title).font(.headline)
            if let message = prompt.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(done)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(prompt.confirm, action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .preferredColorScheme(Theme.scheme)
        .onAppear { text = prompt.initial }
    }

    private func done() {
        prompt.action(text)
        dismiss()
    }
}

struct EditTarget: Identifiable {
    let id = UUID()
    var tracks: [LibraryTrack]
    var title: String
    /// Set when the whole artist is being edited, so a rename can keep it selected.
    var artistName: String?
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
        .preferredColorScheme(Theme.scheme)
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

/// A playlist's songs that are on disk, checked once per redraw rather than
/// once per row, with each one's place for starting playback.
private struct PlayableList {
    let paths: [String]
    let position: [String: Int]
    var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

    init(_ all: [String]) {
        paths = all.filter { FileManager.default.fileExists(atPath: $0) }
        position = Dictionary(paths.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }
}
