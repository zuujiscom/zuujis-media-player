# Audio route checklist

A manual test for the system audio route (process tap + aggregate device), which the unit tests in `Tests/` cannot reach. Run it after any change to `AudioEngine`, the renderer, device switching, profiles or band-count handling, on a Mac that supports process taps (macOS 14.2+).

Before each run: play steady audio from another app (a browser tab or Music), and keep **Equalizer ▸ Copy Diagnostics** handy. Paste the report into the PR or issue when anything fails.

"Clean" below means three things:

- Ordinary system audio plays at normal volume after the step.
- `Audio MIDI Setup` shows no leftover private aggregate device.
- No route error is showing in the header, unless the step expects one.

## 1. Start and stop

| # | Do | Expect |
|---|----|--------|
| 1.1 | Start (⌘↩). | Audio continues through the EQ; meters move. |
| 1.2 | Move one band to +12 dB, then raise and lower the preamp. | The change is audible; no dropouts. |
| 1.3 | Bypass (⌘B) on and off. | A/B difference is audible; the route stays up. |
| 1.4 | Stop (⌘↩). | Clean. Audio is unprocessed. |
| 1.5 | Start and stop five times quickly. | Clean every time; nothing is muted at the end. |
| 1.6 | Quit the app while it is running. | Clean. |

## 2. While running

| # | Do | Expect |
|---|----|--------|
| 2.1 | Switch 10 → 15 → 31 bands. | Audio never goes silent; settings carry over. |
| 2.2 | Apply presets with ⌘1–9, including a custom preset saved at a different band count. | Audio keeps playing. |
| 2.3 | Turn the app's own player on and off with a song playing. | The app's player is not captured twice (no echo). |

## 3. Output changes

| # | Do | Expect |
|---|----|--------|
| 3.1 | Change the default output in Control Center (speakers → headphones). | The app follows; audio comes from the new device processed. |
| 3.2 | Unplug wired headphones while running. | Follows the fallback device; no silence. |
| 3.3 | Connect and disconnect a Bluetooth headset. | Follows each way. Its profile applies (if one was saved). |
| 3.4 | Choose an output with a microphone too (the Xbox headset bridge, or a USB headset). | Processed system audio, **not** the mic. This is the tap-offset case. |
| 3.5 | Switch to an AirPlay or HDMI output with a different sample rate. | Follows; no pitch or speed change. |
| 3.6 | Remove the only output device (or choose a device that disappears). | A route error appears in the header; Stop leaves things clean. |

## 4. Permission

| # | Do | Expect |
|---|----|--------|
| 4.1 | Reset with `tccutil reset AudioCapture com.zuujis.MediaPlayer`, then Start. | macOS asks for permission once. |
| 4.2 | Deny it, then Start. | A route error appears; Stop leaves things clean; the system audio is **not** muted. |
| 4.3 | Allow it in System Settings ▸ Privacy & Security, then Start. | Works without relaunching, or after one relaunch (note which). |

## 5. Sleep and long runs

| # | Do | Expect |
|---|----|--------|
| 5.1 | Sleep the Mac while running, then wake it. | Audio returns; or a route error is shown and Start recovers it. |
| 5.2 | Leave it running for 30 minutes with audio. | No drift, crackle or rising CPU. |

Write down the macOS version, the output devices used and any step that failed.
