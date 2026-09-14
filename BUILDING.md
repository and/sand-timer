# Building Sand Timer

```sh
./build.sh              # build SandTimer.app
./build.sh release      # universal binary, signed, notarized, packaged as a .dmg
./build.sh test         # unit and integration tests
./build.sh test-unit    # unit tests only (opens no windows)
```

## Notarizing

`release` notarizes automatically using credentials saved in your Keychain:

```sh
xcrun notarytool store-credentials sandtimer-notary --apple-id <you> --team-id <TEAMID>
```

Point `NOTARY_PROFILE` at a different profile to use another one, or set it empty to
skip notarizing. It verifies what it produced rather than assuming: `stapler validate`
on both artifacts, then `spctl --assess`, which is the check another Mac performs.

## Rendering images

The app draws its own images. `SandTimer --snapshot out.png` renders the view to a
PNG — it takes `--minutes`, `--progress`, `--theme`, `--base`, `--angle`, `--shake`
and `--dark` — and `--iconset` renders the app icon at every size macOS asks for,
which is where `AppIcon.icns` comes from. The images in the README were made that way.

## Layout

| | |
|---|---|
| `Sources/SandPhysics.swift` | how the sand piles, craters, falls and slides |
| `Sources/HourglassRenderer.swift` | drawing the glass, sand and base |
| `Sources/HourglassView.swift` | the view, its gestures and animation |
| `Sources/Sounds.swift` | synthesised pouring, shaking and chime |
| `Sources/Model.swift` | duration, progress and settings |
| `Sources/main.swift` | app lifecycle, menu, `--snapshot` and `--iconset` |

