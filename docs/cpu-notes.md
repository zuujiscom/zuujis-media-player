# CPU notes

A running log of what uses CPU in Zuujis Media Player, what was done about it, and how to measure.
It lives in the repository so any session, on any account, starts from the same facts.
The rules that came out of this work are in [AGENTS.md](../AGENTS.md); this file is the history and the numbers.

## How to measure

- Reading: `top -l 6 -s 2 -pid <pid> -stats pid,cpu,mem` (ignore the first line, it is always 0).
- Where it goes: `sample <pid> 5 -file out.txt`, then per thread subtract the idle leaves
  (`mach_msg2_trap`, `semaphore_wait*`, `__workq_kernreturn`) from the thread total. 2,594 samples = 5 s of one core.
- State changes the reading a lot. Always note: playing or paused, EQ on or off, which cards are shown
  (library, faders, lyrics), whether other apps are playing sound, whether the pointer is moving.
- The pointer over the window costs CPU by itself. Test hover with a fast scripted sweep (about 250 events a second), not a slow one.
- When a reading "still has issues", sample during the real action (song change, click, drag), not only steady playback.
- GUI tests go on the left screen; move the window back there after every relaunch.

## Causes found and fixes

| When | Cause | Fix | Before → after |
|---|---|---|---|
| Idle window | SwiftUI views redrawing with nothing playing | Stop timers and observers when not live (08c8f76) | ~45% → 0.3% |
| Playing, cards hidden | Any SwiftUI view that redraws inside the main window re-lays out the whole window, about 17 ms a frame. A nested `NSHostingView` does not isolate it. | Everything that moves is a plain `NSView` with CALayers: `Views/LiveViews.swift` (563ac38) | 34% → ~4.5% (EQ off), ~6.5% (EQ on) |
| Lyrics card shown | Per-word state changes plus blur, shadow and scale animations in SwiftUI rows | `SyncedLyricsView` in `Views/LyricsLayerView.swift`, layers only (0a4ab9d) | 25–42% → ~9–10% |
| Pointer moving | Every mouse-moved event hit-tests the whole SwiftUI tree, 7–14 ms each; the faders card (31 `NSViewRepresentable`s) was the slowest part | `App/PointerThrottle.swift` passes 10 events a second; decorative views get `.allowsHitTesting(false)`; fader gestures sit on one clear overlay (bb87a0c) | fast sweep 21–26% → 13–15% |
| Pointer still, loud preamp | `ClipLevel.overDB` was published and changed several times a second, re-rendering the window | Publish only `isOver` (bb87a0c) | 12–18% → 7–10% |
| Starting a library song | The queue was replaced with the whole list (1,000 songs) and every file's tags were re-read, one publish each | `PlaybackQueue.knownMetadata` takes tags from the library; the rest apply in batches of 40 (bb87a0c) | 25–50% for 8+ s → ~2 s bump to ~25% |
| Playing, EQ on, nothing else making sound | The system route's IOProc ran the 31-band EQ and limiter over silence, about 4.5% of a core | `SystemAudioRenderer` stops rendering after 2 s of zero input from the tap and resumes on the first non-zero cycle; the route's meter timer stops analysing too | ~10% → ~6% |
| Playing a loud song | The LIMIT light blinked off and back on every 2 s (the silent route reports a zero peak 20 times a second, which cleared the light the moment its hold ran out); each blink ran a 0.15 s animation that rendered the whole window on every frame | The light goes out only after a full hold with no peak (`MeterState.lastOver`); no fade on the light | 11–15% → 6–9% |
| Paused, EQ on | The player's `AVAudioEngine` kept pulling silence through the EQ and limiter (~3%), and the spectrum views ticked 30 times a second over nothing | `PlayerEngine.restEngineSoon()` pauses the engine 3 s after a pause (resume restarts from the paused frame on the seek path); `LiveMeterView` touches no layer after 5 s of silence | 4.2% → ~1.3% |
| Playing | `outputNode.presentationLatency` is a ~4 ms round trip to the audio server, read once a second | Read every 5 s (still reset when the graph is rebuilt) | ~0.8% → ~0.15% |

## Current state (2026-11-16, after the fixes above, not yet committed when written)

EQ on, library + faders + lyrics shown, pointer still, nothing else making sound:

- Playing: about 6%, up to 9% on a song with word-timed lyrics. Main thread ~4–6% of a core (30 Hz layer timers, scrubber, lyrics), player audio thread ~3% (Apple's 31-band EQ is most of it), route thread ~0.3%.
- Paused: about 1.3%. Stopped or EQ off and idle: about 0.3%.
- Another app playing through the EQ adds about 4.5% (the route's EQ doing real work).

For comparison, Apple Music plays at 3–5% and about 125 MB; this app uses about 125 MB after a fresh launch and has been seen at 210 MB (not looked at yet).

## Ideas not done

- Apple's `AVAudioUnitEQ` costs about 3.6% of a core for 31 stereo bands. A `vDSP_biquadm` cascade would likely be several times cheaper, but it replaces the filter in both audio paths and needs the full audio-route checklist.
- Bypassing bands that sit at exactly 0 dB saves little in practice: the gains sent to the node are compensated for neighbouring bands, so few are exactly zero.
- `ScrubberView.refresh` converts colours and builds a path 10 times a second (about 0.8% of a core).
- A few window re-renders still show in samples during playback (8–32 samples in 5 s); the trigger is not identified. No SwiftUI `body` runs in them, so it is an animation or an AppKit layout pass.
- The ~2 s bump when a track changes is not broken down yet (a widget update shows in the sample).
- Memory: 210 MB against Music's 125 MB.

## Not yet checked by hand

Resume after a long pause across an output-device change; the route picking up another app's sound after hours of silence; scrubber drag-seek, hover knob and VoiceOver; lyrics click-to-seek, scroll and hover; Light theme for the layer views; fader scroll wheel, context menu and tooltips.
