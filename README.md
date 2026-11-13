# Timelapse Cam

A small macOS app that records your camera as a timelapse or a regular video, with a clean Liquid Glass interface.

![Timelapse Cam main window](docs/screenshots/main-window.png)

## Features

- **Timelapse or video.** Switch with the slider. Timelapse captures one frame every 1 second to 5 minutes and plays them back at 24, 30 or 60 fps.
- **Live preview** with mirror and exposure controls, plus a last-frame thumbnail that fades after each capture.
- **Recording controls** with keyboard shortcuts: ⌘R record, ⌘P pause/resume, ⌘, settings.
- **Automatic stop** after a set number of minutes, with a progress bar.
- **Stats at a glance:** elapsed time, file size, frame count, and resulting video length.
- **Video settings:** resolution, HEVC or H.264 codec, quality, and output folder.
- **Keep awake** while recording, so the Mac doesn't sleep mid-timelapse.
- **Camera lock options** for exposure and white balance, so long recordings stay consistent.

## Requirements

- macOS 14 (Sonoma) or later. The Liquid Glass look uses macOS 26; older systems fall back to material blur.
- Swift 5.9+ toolchain (Xcode 15 or later) to build from source.

## Build and run

```bash
./build.sh
open TimelapseCam.app
```

`build.sh` makes a release build, assembles `TimelapseCam.app` with the icon, and ad-hoc signs it. The signature is tied to the bundle ID, so macOS keeps the camera permission across rebuilds.

Videos are saved to `~/Movies/Timelapses` by default and can be changed in Settings.

## Screenshots

Settings panel:

![Settings](docs/screenshots/settings.png)

To regenerate the screenshots, run `scripts/take-screenshots.sh`. It needs Screen Recording permission for your terminal.

## Project layout

```
Sources/TimelapseCam/
  TimelapseCamApp.swift   app entry point and main UI
  TimelapseEngine.swift   capture, encoding and recording pipeline
  SettingsView.swift      settings sheet
  ModeSwitch.swift        Timelapse / Video slider
  Glass.swift             Liquid Glass and tactile button styles
  Features.swift          feature switches
Resources/                app icon (AppIcon.icns, 1024px master)
docs/                     GitHub Pages site
```

## Feature switches

Experimental clock overlay code (wall fitting, plane picking, occlusion) is still in the source but turned off. Set `Features.clock = true` in `Features.swift` to bring it back.

## License

No license has been chosen yet. All rights reserved until one is added.
