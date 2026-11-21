# Shh

Shh is a menu bar app for macOS 14.2 or later. It watches Core Audio microphone activity. When a microphone is in use, Shh pauses supported players and silences other app output. Playback returns when the last microphone client releases the input. Shh detects an open microphone even during silence.

## Build and open Shh

With Xcode or the Command Line Tools installed, run these commands from the project folder.

```sh
./scripts/build-app.sh
open /Applications/Shh.app
```

The script builds and signs `build/Shh.app`, verifies the bundle, then installs it in `/Applications`. On launch, Shh’s microphone icon appears in the menu bar.

Set `SHH_APPLICATIONS_DIR` to choose another install folder. Set `SHH_REFRESH_DESKTOP=0` to skip Launch Services registration and the Dock restart. For a build-only copy, run `./build.sh` and open `build/Shh.app`.

## Set up playback

- **Chrome** — In Chrome, enable **View → Developer → Allow JavaScript from Apple Events**. This is a browser-wide setting for software authorized to automate Chrome. Shh uses it to pause audio and video elements across windows and tabs.
- **Automation** — Allow Shh to control each supported player when prompted. You can review permissions under **System Settings → Privacy & Security → Automation**.
- **Other audio** — Allow system audio recording when macOS prompts. Shh uses a private Core Audio tap to silence eligible output and immediately discards the buffers. It never saves or transmits audio. Microphone detection itself reads device and process activity.
- **Exclusions** — Click the Shh menu bar icon and choose **Excluded Apps → Exclude an App…**. Selected apps keep playing and stay audible. Click a checked app to remove the exclusion. Excluding a conferencing app preserves the call audio while its microphone still triggers Shh for other players. Excluding Chrome covers the entire browser.

## Playback behavior

| Source | During microphone use | When microphone use ends |
| --- | --- | --- |
| Music, Spotify, TV, VLC | Shh pauses a playing item when the player exposes its state and identity. | It resumes the same item if it is still paused in the same app instance. |
| Chrome audio and video elements | Shh pauses playing media in tabs it can script, including accessible same-origin frames. | It requests playback of the elements it paused if the page and media source still match. Browser autoplay rules may affect resumption. |
| Other eligible Core Audio output | Shh mutes the app output. This also covers sources such as Web Audio or inaccessible frames in Chrome. | Sound returns at the stream’s current position. |

Shh periodically checks for new playback during microphone use. Brief sounds may finish before the next check. App exclusions apply to output that Core Audio or a nested helper bundle can attribute to that app. Some protected content or device-specific output routes may bypass audio taps. Use **Playback Issues** in the menu to inspect reported errors. Turning off monitoring or quitting normally releases audio controls.

## Try it with Dictation

1. Start a YouTube video in Chrome and leave a second video paused.
2. Start macOS Dictation in a text field. The menu should show **Microphone in use** and the playing video should pause.
3. Stop Dictation. The first video should resume, and the second should stay paused.
4. Add Chrome to **Excluded Apps** and repeat. Both videos should retain their states.
