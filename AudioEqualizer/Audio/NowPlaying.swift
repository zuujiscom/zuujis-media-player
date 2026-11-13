// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit
import Combine
import MediaPlayer

/// Publishes what the player is playing to the system — Control Centre's Now
/// Playing tile, the lock screen, AirPods and the keyboard's media keys — and
/// routes their commands back to the player.
///
/// macOS sends the media keys to whichever app last claimed Now Playing, so
/// this also keeps them from launching Music.
@MainActor
final class NowPlayingController {
    private weak var player: PlayerEngine?
    private var cancellables = Set<AnyCancellable>()
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private let keyTap = MediaKeyTap()
    private var activationObserver: NSObjectProtocol?

    init(player: PlayerEngine) {
        self.player = player
        registerCommands()

        // macOS hands the media keys to an app that has recently *played*, and
        // to Music otherwise, so a freshly launched or idle player never gets
        // them from Now Playing alone. Claim them directly while the player
        // is in use. Needs Accessibility permission; without it the Now
        // Playing route above still works whenever the system picks us.
        keyTap.handler = { [weak self] key, isDown in self?.handle(mediaKey: key, isDown: isDown) ?? false }
        keyTap.start(prompt: true)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Permission may have just been granted in System Settings.
            MainActor.assumeIsolated { self?.keyTap.start(prompt: false) }
        }

        // `@Published` fires before the value is stored: hop a turn, then read.
        Publishers.Merge3(
            player.$state.map { _ in () },
            player.$track.map { _ in () },
            player.timelineChanged
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        .store(in: &cancellables)
    }

    // The center is process-wide: leave no handlers behind.
    isolated deinit {
        for (command, target) in commandTargets { command.removeTarget(target) }
    }

    /// Whether a media key is ours: while playing or paused always, and while
    /// idle only if this app is frontmost — an idle player with a track loaded
    /// should not take the keys from a video playing in a browser.
    private func handle(mediaKey key: MediaKeyTap.Key, isDown: Bool) -> Bool {
        guard let player else { return false }
        let inUse = player.state != .stopped || (NSApp.isActive && player.track != nil)
        guard inUse else { return false }
        guard isDown else { return true } // swallow the release, act on the press
        switch key {
        case .playPause: player.togglePlayPause()
        case .next: player.next()
        case .previous: player.previous()
        }
        return true
    }

    // MARK: - System → player

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerEngine) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                // Handlers may arrive on any thread.
                Task { @MainActor in
                    if let player = self?.player { action(player) }
                }
                return .success
            }
            commandTargets.append((command, target))
        }

        add(center.playCommand) { if $0.state != .playing { $0.togglePlayPause() } }
        add(center.pauseCommand) { $0.pause() }
        add(center.togglePlayPauseCommand) { $0.togglePlayPause() }
        add(center.stopCommand) { $0.stop() }
        add(center.nextTrackCommand) { $0.next() }
        add(center.previousTrackCommand) { $0.previous() }

        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { $0.skip(by: 10) }
        add(center.skipBackwardCommand) { $0.skip(by: -10) }

        center.changePlaybackPositionCommand.isEnabled = true
        let seek = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in self?.player?.seek(to: seconds) }
            return .success
        }
        commandTargets.append((center.changePlaybackPositionCommand, seek))
    }

    // MARK: - Player → system

    /// The system extrapolates elapsed time from the rate, so this only needs
    /// to run when something changes, not every second.
    private func refresh() {
        let center = MPNowPlayingInfoCenter.default()
        guard let player, let track = player.track else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime(),
            MPNowPlayingInfoPropertyPlaybackRate: player.state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let artist = track.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let image = track.artwork {
            let size = image.size
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: size) { _ in image }
        }
        center.nowPlayingInfo = info

        switch player.state {
        case .playing: center.playbackState = .playing
        case .paused: center.playbackState = .paused
        // A track that is loaded but not started (after launch, after Stop) is
        // reported as paused, not stopped: macOS gives the media keys only to
        // an app it sees as playing or paused, and hands them to Music
        // otherwise. Play from this state starts the loaded track.
        case .stopped: center.playbackState = .paused
        }
    }
}

/// Listens for the keyboard's play/pause, next and previous keys (system-defined
/// events, subtype 8) and swallows the ones the handler claims, so macOS does
/// not also send them to Music. Creating the tap requires Accessibility access.
@MainActor
final class MediaKeyTap {
    enum Key { case playPause, next, previous }

    /// Returns whether the key is claimed. Called for the press and the release.
    var handler: ((Key, Bool) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private static let promptedKey = "mediaKeysAccessibilityPrompted"

    func start(prompt: Bool) {
        guard tap == nil else { return }
        var trusted = AXIsProcessTrusted()
        if !trusted, prompt, !UserDefaults.standard.bool(forKey: Self.promptedKey) {
            UserDefaults.standard.set(true, forKey: Self.promptedKey)
            let key = "AXTrustedCheckOptionPrompt" // kAXTrustedCheckOptionPrompt
            trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        guard trusted else { return }

        let mask: CGEventMask = 1 << 14 // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let this = Unmanaged<MediaKeyTap>.fromOpaque(info).takeUnretainedValue()
            return MainActor.assumeIsolated { this.receive(type: type, event: event) }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return pass }

        let code = (ns.data1 & 0xFFFF0000) >> 16
        let isDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
        let key: Key
        switch code {
        case 16: key = .playPause   // NX_KEYTYPE_PLAY
        case 17, 19: key = .next    // NEXT, FAST
        case 18, 20: key = .previous // PREVIOUS, REWIND
        default: return pass
        }
        let isRepeat = (ns.data1 & 0x1) != 0
        guard handler?(key, isDown && !isRepeat) ?? false else { return pass }
        return nil
    }
}
