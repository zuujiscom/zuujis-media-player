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

    init(player: PlayerEngine) {
        self.player = player
        registerCommands()

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
        case .stopped: center.playbackState = .stopped
        }
    }
}
