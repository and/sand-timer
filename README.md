# Sand Timer

A realistic sand timer that sits on your Mac's desktop, above your other windows.

<p align="center">
  <img src="docs/hourglass.png" width="300" alt="The Sand Timer hourglass, mid-pour, with 14:30 remaining on the display in its base">
</p>

Every image here is drawn by the app itself — `SandTimer --snapshot out.png` renders
the real view, so nothing in this README is a mockup.

## Download

Grab the latest `.dmg` from [Releases](https://github.com/and/sand-timer/releases),
open it, and drag **Sand Timer** into **Applications**. macOS 13 Ventura or later,
Apple Silicon and Intel.

The app is signed and notarized, so it opens without a security warning — the
notarization ticket is stapled into both the app and the disk image, which means it
works on a machine that is offline too.

## Using it

- **Click** to start. Click again to pause — it tips onto its side — and again to resume.
- **Drag** it anywhere; let go and it drops to the bottom of the screen.
- **Right-click** for durations (1–60 minutes, including a 25-minute 🍅 Pomodoro),
  sand colours, base style, size, sounds, Start at Login and Hide to Menu Bar.

## What's inside

Sand that behaves like sand: a crater that deepens on top, a pile that builds at the
bottom, a stream that loosens as it falls, and a neck sized to the duration. Flip,
drop, shake or knock it over and the sand responds. The remaining time shows on a
display in the base, which switches over when you flip it.

The sounds were made to match — pouring onto glass, then onto sand, shaking, landing,
and a chime when time is up.

<p align="center">
  <img src="docs/theme-amber.png" width="200" alt="The timer in a green sand theme with a matching base">
  <img src="docs/theme-rose-dark.png" width="200" alt="The timer in a rose sand theme on a dark desktop">
</p>

## Building

```sh
./build.sh              # build SandTimer.app
./build.sh release      # universal binary, signed, notarized, packaged as a .dmg
./build.sh test         # unit and integration tests
./build.sh test-unit    # unit tests only (opens no windows)
```

`release` notarizes automatically using credentials saved in your Keychain:

```sh
xcrun notarytool store-credentials sandtimer-notary --apple-id <you> --team-id <TEAMID>
```

Point `NOTARY_PROFILE` at a different profile to use another one, or set it empty to
skip notarizing. It verifies what it produced rather than assuming: `stapler validate`
on both artifacts, then `spctl --assess`, which is the check another Mac performs.

## Layout

| | |
|---|---|
| `Sources/SandPhysics.swift` | how the sand piles, craters, falls and slides |
| `Sources/HourglassRenderer.swift` | drawing the glass, sand and base |
| `Sources/HourglassView.swift` | the view, its gestures and animation |
| `Sources/Sounds.swift` | synthesised pouring, shaking and chime |
| `Sources/Model.swift` | duration, progress and settings |
| `Sources/main.swift` | app lifecycle, menu, `--snapshot` and `--iconset` |
