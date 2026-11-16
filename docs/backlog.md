# Improvement backlog

Ideas from a code review on 2026-11-15. None of this is started unless it says so.
Read `AGENTS.md` first; the audio-route safety rules there apply to items 2, 9 and 10.

## Sound

### 1. Loudness matching (ReplayGain) — done 2026-11-16
Tags are read (FLAC, MP3 `TXXX`, M4A freeform atoms), untagged files are measured
(BS.1770, -18 LUFS) and the gain rides on the player's EQ global gain. See
"Loudness matching" in `AGENTS.md`. Left out:
- APEv2 tags and the LAME header on MP3 are not read; such files are measured.
- Album loudness for untagged albums is an energy average of the songs' figures,
  not the standard's joint gating of all their blocks (a fraction of a dB apart).
- Surround channels are weighted alike (the standard gives the rear pair +1.5 dB
  and skips the LFE).
- Not listened to on real music yet: tests and a muted run only.

### 2. Clipping protection — done 2026-11-16
`SoftLimiter` on both paths, on by default, and the LIMIT / CLIP light beside the
preamp. See "Limiter" and "Clip light" in `AGENTS.md`. Left to do:
- **The system route's limiter has not been run live.** It is tested as pure code
  and through an offline manual-rendering graph. Run `docs/audio-route-checklist.md`
  (start/stop, band-count change while running, output switch) with it on.
- It is a sample-peak limiter: inter-sample peaks can still exceed full scale by a
  little after the converter. The ceiling of -0.3 dBFS is the allowance for that.

### 3. Crossfade
Gapless exists; there is no crossfade for shuffled or mixed playlists. It needs a
second player node, since one node cannot overlap two segments.

## Library and playback

### 4. M3U / PLS import and export
The scan already treats these as expected companion files. Playlists hold file
paths (`Models/Playlist.swift`), so import and export are small.

### 5. Play history
No play counts or last-played dates. They would allow Recently Played, Most
Played and smart playlists. Keep them in their own file keyed by path, like playlists.

### 6. M4A tag writing
`TagWriter` writes FLAC and MP3; M4A edits stay library-only (needs `moov`
offset fixups).

### 7. Queue lags a tag edit
The queue re-reads tags from the file when an item loads, so it can show old
values after an edit in the library.

### 8. Ogg / Opus
Not supported: AVFoundation cannot decode them. Only worth it if such files
turn up, because it means adding a decoder to an app with no dependencies.

## Robustness

### 9. Logging
No `Logger` / `os_log` anywhere. A log of the tap and aggregate-device lifecycle
would help with "the sound went silent" reports. Never log from the IOProc.

### 10. Bit-perfect output is untested on real hardware
Sample-rate matching and exclusive mode (`OutputRate`, `exclusiveMode`).

### 11. Accessibility
About 14 accessibility labels in the whole app, and most controls are custom
(`GlowSlider`, `IconButton`, the faders). VoiceOver likely cannot operate much of it.

### 12. Large files
`VisualizerView.swift`, `AudioEngine.swift` and `PlayerEngine.swift` each do
several jobs. Low-risk first moves: `CoverArt` / `OnlineCoverArt` out of
`PlayerEngine.swift`, device monitoring out of `AudioEngine.swift`.

### 13. CI
No workflow runs `swift test`.

## Visualizer

### 14. MilkDrop custom waves and shapes
Imported presets reproduce motion only. See the visualizer work that started on
2026-11-15 before investing here: MilkDrop may stop being the main direction.
