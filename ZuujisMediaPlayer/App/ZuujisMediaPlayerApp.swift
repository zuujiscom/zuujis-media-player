// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// Receives files opened from Finder and flushes debounced saves on quit.
/// View and Help used to be stripped from the menu bar here; both now carry
/// real items (panel switches and themes; the guide), so they stay.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Where files opened from Finder (double-click, Open With, drop on the
    /// Dock icon) go. Set once the player exists; files that arrive earlier
    /// (launching by double-clicking a song) wait in `pendingOpens`.
    static var openHandler: (([URL]) -> Void)? {
        didSet {
            guard let handler = openHandler, !pendingOpens.isEmpty else { return }
            let urls = pendingOpens
            pendingOpens = []
            handler(urls)
        }
    }
    private static var pendingOpens: [URL] = []
    /// Finder can deliver one multi-file open as several calls: they are
    /// gathered for a moment and handled together.
    private var batch: [URL] = []
    private var batchFlush: DispatchWorkItem?

    /// Writes stores whose saves are debounced, so a change made just before
    /// quitting is not lost.
    static var saveOnQuit: (() -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        batch += files
        batchFlush?.cancel()
        let flush = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let urls = self.batch
            self.batch = []
            if let handler = Self.openHandler { handler(urls) } else { Self.pendingOpens += urls }
        }
        batchFlush = flush
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: flush)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.saveOnQuit?()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One main window, no tabs: this also keeps "Show Tab Bar" and
        // "Show All Tabs" out of the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false
    }
}

@main
struct ZuujisMediaPlayerApp: App {
    init() { AppPaths.migrateFromOldName() }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var audioEngine = AudioEngine()
    @StateObject private var presetManager = PresetManager()
    @StateObject private var deviceProfiles = DeviceProfileStore()
    @StateObject private var milkdropLibrary = MilkdropLibrary()
    @StateObject private var player = PlayerEngine()
    @StateObject private var library = LibraryStore()
    @StateObject private var playlists = PlaylistStore()
    // The View menu drives the same saved switches as the header buttons.
    @AppStorage(Panels.library) private var showLibrary = true
    @AppStorage(Panels.eq) private var eqPanel = Panels.response
    @AppStorage(ThemePalette.storageKey) private var themeID = ThemePalette.midnight.id

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(player)
                .environmentObject(player.queue)
                .environmentObject(library)
                .environmentObject(playlists)
                .environmentObject(audioEngine)
                .environmentObject(audioEngine.meters)
                .environmentObject(presetManager)
                .environmentObject(deviceProfiles)
                .environmentObject(milkdropLibrary)
                .frame(minWidth: 900, minHeight: 700)
                // After a scan, playlist songs whose files moved follow them.
                .onChange(of: library.isScanning) { _, scanning in
                    if !scanning { playlists.relink(library: library.tracks.map(\.id)) }
                }
                .task {
                    #if DEBUG
                    if let gallery = DebugGallery.directory {
                        DebugGallery.run(engine: audioEngine, player: player, directory: gallery,
                                         openVisualizer: { openWindow(id: Self.visualizerWindowID) })
                        return
                    }
                    #endif
                    player.attach(to: audioEngine)
                    AppDelegate.openHandler = { player.openFromFinder($0) }
                    AppDelegate.saveOnQuit = {
                        library.saveNow()
                        playlists.saveNow()
                        player.queue.saveNow()
                    }
                    // The engine's device didSet runs during init, before this
                    // store exists, so the launch device is applied here.
                    guard audioEngine.deviceProfiles == nil else { return }
                    audioEngine.deviceProfiles = deviceProfiles
                    audioEngine.applyProfileForCurrentDevice()
                }
        }
        // No title bar: `HeaderBar` is drawn up into that space instead.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 790)
        // Files opened from Finder reuse this window instead of making new ones.
        .handlesExternalEvents(matching: ["*"])
        .commands {
            // App menu.
            CommandGroup(replacing: .appInfo) {
                Button("About Zuujis Media Player") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Zuujis Media Player",
                        .credits: NSAttributedString(
                            string: "A lossless music player with a system-wide equalizer and a visualizer.",
                            attributes: [.font: NSFont.systemFont(ofSize: 11),
                                         .foregroundColor: NSColor.secondaryLabelColor])
                    ])
                }

                Divider()

                Button("Make Default Audio Player…") {
                    DefaultPlayer.makeDefault()
                }
            }

            // File: what a player opens. Presets live in the Equalizer menu.
            CommandGroup(replacing: .newItem) {
                Button("Open Files or Folder…") {
                    PlayerActions.openFiles(in: player)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Add to Queue…") {
                    PlayerActions.addToQueue(in: player)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Add Music Folder to Library…") {
                    LibraryActions.addFolder(to: library)
                }

                Button("Rescan Library") { library.rescan() }
                    .disabled(library.folders.isEmpty || library.isScanning)
            }

            // Nothing here registers an undo manager, so Undo/Redo were inert.
            // The pasteboard items stay — they are what makes ⌘V work in the
            // preset name and rename dialogs.
            CommandGroup(replacing: .undoRedo) { }

            // View: the system menu keeps Enter Full Screen; these go above it.
            CommandGroup(before: .toolbar) {
                Toggle("Library", isOn: $showLibrary)
                    .keyboardShortcut("l", modifiers: [.command])
                Toggle("Response Graph", isOn: eqPanelBinding(Panels.response))
                    .keyboardShortcut("g", modifiers: [.command])
                Toggle("Equalizer Faders", isOn: eqPanelBinding(Panels.equalizer))
                    .keyboardShortcut("e", modifiers: [.command])

                Divider()

                Button("Show Queue") {
                    openWindow(id: Self.playlistWindowID)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Open Visualizer") {
                    openVisualizerWindow()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Divider()

                Picker("Theme", selection: $themeID) {
                    ForEach(ThemePalette.all) { palette in
                        Text(palette.name).tag(palette.id)
                    }
                }

                Divider()
            }

            CommandMenu("Playback") {
                Button(player.state == .playing ? "Pause" : "Play") {
                    player.togglePlayPause()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(player.track == nil && player.queue.items.isEmpty)

                Button("Stop") {
                    player.stop()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(player.state == .stopped)

                Divider()

                Button("Next Track") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                    .disabled(player.state == .stopped)

                Button("Previous Track") { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                    .disabled(player.state == .stopped)

                Button("Forward 10 Seconds") { player.skip(by: 10) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(player.state == .stopped)

                Button("Back 10 Seconds") { player.skip(by: -10) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(player.state == .stopped)

                Divider()

                Button("Volume Up") { player.volume = min(1, player.volume + 0.1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                Button("Volume Down") { player.volume = max(0, player.volume - 0.1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command])

                Divider()

                Toggle("Shuffle", isOn: Binding(get: { player.queue.shuffle },
                                                set: { player.queue.shuffle = $0 }))

                Picker("Repeat", selection: Binding(get: { player.queue.repeatMode },
                                                    set: { player.queue.repeatMode = $0 })) {
                    Text("Off").tag(PlaybackQueue.Repeat.off)
                    Text("Queue").tag(PlaybackQueue.Repeat.all)
                    Text("Track").tag(PlaybackQueue.Repeat.one)
                }

                Divider()

                Button(player.track.map { playlists.isFavorite($0.url.path) } == true
                       ? "Remove Current Song from Favorites" : "Add Current Song to Favorites") {
                    if let track = player.track { playlists.toggleFavorite(track.url.path) }
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(player.track == nil)

                Divider()

                Toggle("Match Output Rate to Each Track", isOn: Binding(
                    get: { player.matchSampleRate }, set: { player.matchSampleRate = $0 }))
                Toggle("Exclusive Output", isOn: Binding(
                    get: { player.exclusiveMode }, set: { player.exclusiveMode = $0 }))

                Divider()

                if player.mediaKeysActive {
                    Text("Media Keys: Captured")
                } else {
                    Button("Allow Media Keys in Accessibility Settings…") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }

            CommandMenu("Equalizer") {
                Button(audioEngine.isRunning ? "Turn Equalizer Off" : "Turn Equalizer On") {
                    audioEngine.isRunning ? audioEngine.stop() : audioEngine.start()
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Button(audioEngine.isBypassed ? "Turn Bypass Off" : "Bypass") {
                    audioEngine.toggleBypass()
                }
                .keyboardShortcut("b", modifiers: [.command])

                Button("Reset to Flat") {
                    audioEngine.resetToFlat()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Picker("Bands", selection: Binding(
                    get: { audioEngine.bands.count },
                    set: { count in DispatchQueue.main.async { audioEngine.setBandCount(count) } })) {
                    Text("10 Bands").tag(10)
                    Text("15 Bands").tag(15)
                    Text("31 Bands").tag(31)
                }

                Menu("Presets") {
                    Section("Built-in") {
                        ForEach(Array(EQPreset.allBuiltin.enumerated()), id: \.element.id) { index, preset in
                            presetItem(preset, shortcutIndex: index)
                        }
                    }
                    if !presetManager.customPresets.isEmpty {
                        Section("Custom") {
                            ForEach(presetManager.customPresets) { preset in
                                presetItem(preset, shortcutIndex: nil)
                            }
                        }
                    }
                }

                Divider()

                Button("Save Current as Preset…") {
                    PresetActions.saveCurrent(bands: audioEngine.bands, in: presetManager)
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Import Preset…") {
                    PresetActions.importPreset(into: presetManager)
                }

                Button("Export Selected Preset…") {
                    if let preset = presetManager.selectedPreset {
                        PresetActions.export(preset, from: presetManager)
                    }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(presetManager.selectedPreset == nil)

                Button("Reveal Presets File in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([presetManager.presetsFileURL])
                }

                Divider()

                Button("Refresh Devices") {
                    audioEngine.enumerateDevices()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Copy Diagnostics") {
                    let text = audioEngine.diagnosticsReport()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }

                Section("Output") {
                    Text(audioEngine.outputFormat)
                }
            }

            CommandMenu("Visualizer") {
                Button("Open Visualizer") {
                    openVisualizerWindow()
                }

                // Selecting a mode also opens the window, so the menu works as
                // a launcher rather than only as a switch for a window already
                // on screen. Shuffle is a single top-level choice, not a
                // section: a one-item section headed "Auto" containing "Auto"
                // is only confusing, and the header is not clickable.
                Button("Shuffle Everything") {
                    UserDefaults.standard.set(VisualizerMode.auto.rawValue, forKey: VisualizerMode.storageKey)
                    openVisualizerWindow()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])

                Divider()

                // One submenu per family: fifty modes in one flat list ran off
                // the bottom of the screen.
                ForEach(VisualizerMode.groups) { group in
                    Menu(group.id) {
                        ForEach(group.modes) { mode in
                            visualizerItem(mode)
                        }
                    }
                }

                Divider()

                if !milkdropLibrary.isEmpty {
                    Menu("MilkDrop (\(milkdropLibrary.presets.count))") {
                        ForEach(milkdropLibrary.presets.prefix(60), id: \.name) { preset in
                            Button(preset.name) {
                                UserDefaults.standard.set(preset.name, forKey: MilkdropLibrary.selectionKey)
                                UserDefaults.standard.set(VisualizerMode.milkdrop.rawValue, forKey: VisualizerMode.storageKey)
                                openVisualizerWindow()
                            }
                        }
                    }
                }

                Button("Import MilkDrop Presets…") {
                    importMilkdropPresets()
                }

                Button("Reveal MilkDrop Folder") {
                    NSWorkspace.shared.open(milkdropLibrary.folderURL)
                }
            }

            CommandGroup(replacing: .help) {
                Link("Zuujis Media Player Guide",
                     destination: URL(string: "https://github.com/zuujiscom/zuujis-media-player#readme")!)
                Link("Report a Problem",
                     destination: URL(string: "https://github.com/zuujiscom/zuujis-media-player/issues")!)
            }
        }

        Window("Visualizer", id: Self.visualizerWindowID) {
            VisualizerWindow()
                .environmentObject(player)
                .environmentObject(audioEngine)
                .environmentObject(milkdropLibrary)
        }
        .defaultSize(width: 1100, height: 680)

        Window("Queue", id: Self.playlistWindowID) {
            PlaylistView()
                .environmentObject(playlists)
                .environmentObject(player)
                .environmentObject(player.queue)
        }
        .defaultSize(width: 520, height: 620)
    }

    static let visualizerWindowID = "visualizer"
    static let playlistWindowID = "playlist"

    private func openVisualizerWindow() {
        openWindow(id: Self.visualizerWindowID)
    }

    /// The response graph and the faders are one or the other; switching the
    /// one that shows off hides the EQ panel.
    private func eqPanelBinding(_ value: String) -> Binding<Bool> {
        Binding(get: { eqPanel == value },
                set: { eqPanel = $0 ? value : Panels.hidden })
    }

    /// A preset as a checkable menu item; the first nine built-ins get ⌘1…⌘9.
    @ViewBuilder
    private func presetItem(_ preset: EQPreset, shortcutIndex: Int?) -> some View {
        let item = Toggle(preset.name, isOn: Binding(
            get: { presetManager.selectedPresetID == preset.id },
            set: { _ in
                presetManager.selectedPresetID = preset.id
                audioEngine.applyPreset(preset)
            }))
        if let index = shortcutIndex, index < 9 {
            item.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
        } else {
            item
        }
    }

    /// A visualizer mode; the first ten get ⌥⌘1…⌥⌘0, the rest are click-only.
    @ViewBuilder
    private func visualizerItem(_ mode: VisualizerMode) -> some View {
        let item = Button(mode.rawValue) {
            UserDefaults.standard.set(mode.rawValue, forKey: VisualizerMode.storageKey)
            openVisualizerWindow()
        }
        if let key = mode.shortcut {
            item.keyboardShortcut(key, modifiers: [.command, .option])
        } else {
            item
        }
    }

    /// Accepts folders as well as files — preset packs arrive as directories of
    /// hundreds of `.milk` files, and picking them one at a time is no use.
    private func importMilkdropPresets() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose .milk presets, or a folder of them."
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in milkdropLibrary.importPresets(from: urls) }
        }
    }
}

/// Makes Zuujis Media Player the app Finder opens sound files with. Runs only when the user
/// chooses the menu item; macOS may ask them to confirm.
enum DefaultPlayer {
    static let identifiers = [
        "org.xiph.flac", "public.mp3", "com.apple.m4a-audio", "com.microsoft.waveform-audio",
        "public.aiff-audio", "public.aifc-audio", "com.apple.coreaudio-format", "public.aac-audio",
    ]

    @MainActor
    static func makeDefault() {
        let appURL = Bundle.main.bundleURL
        // Only the types another app still opens: no needless prompts.
        let types = identifiers.compactMap { UTType($0) }.filter {
            NSWorkspace.shared.urlForApplication(toOpen: $0)?.standardizedFileURL != appURL.standardizedFileURL
        }
        guard !types.isEmpty else {
            let done = NSAlert()
            done.messageText = "Zuujis Media Player is already the default player"
            done.runModal()
            return
        }
        let ask = NSAlert()
        ask.messageText = "Open \(types.count) sound file type\(types.count == 1 ? "" : "s") with Zuujis Media Player?"
        ask.informativeText = "macOS may ask you to confirm each one."
        ask.addButton(withTitle: "Continue")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            var failed: [String] = []
            for type in types {
                do { try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) }
                catch { failed.append(type.localizedDescription ?? type.identifier) }
            }
            let alert = NSAlert()
            if failed.isEmpty {
                alert.messageText = "Zuujis Media Player is now the default player"
                alert.informativeText = "Double-clicking a FLAC, MP3, M4A, WAV, AIFF or AAC file opens it in Zuujis Media Player."
            } else {
                alert.messageText = "Could not change some file types"
                alert.informativeText = "Not changed: " + failed.joined(separator: ", ")
                    + ". You can set them in Finder: Get Info, Open with, Change All."
            }
            alert.runModal()
        }
    }
}
