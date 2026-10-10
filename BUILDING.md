# Building Sand Timer

```sh
./build.sh              # build SandTimer.app
./build.sh release      # universal binary, signed, notarized, packaged as a .dmg
./build.sh test         # unit and integration tests
./build.sh test-unit    # unit tests only (opens no windows)
./build.sh test tilt    # only the tests matching a word, in one process, as they happen
```

## The test run

The sand has to fall in real time, so the integration tests are spread over four
processes at once (`SHARDS=8 ./build.sh test` to change that), with the unit tests
running beside them — about a minute instead of two and a half. The two test programs
compile side by side as well.

A handful of tests can't share: the one measuring the timer's share of a core, and the
two that listen for the sand. They are marked `serial: true`, sit the shards out, and run
afterwards with the machine to themselves. Asking for a word runs everything in a single
process, where watching it happen is the point.

## Notarizing

`release` notarizes automatically using credentials saved in your Keychain:

```sh
xcrun notarytool store-credentials sandtimer-notary --apple-id <you> --team-id <TEAMID>
```

Point `NOTARY_PROFILE` at a different profile to use another one, or set it empty to
skip notarizing. It verifies what it produced rather than assuming: `stapler validate`
on both artifacts, then `spctl --assess`, which is the check another Mac performs.

## Releasing

Each release adds an entry at the top of `CHANGELOG.md`, which keeps the whole history in one
place. The notes on the GitHub release itself hold only that release's changes, a line pointing
anyone coming from an older version to the changelog, and the download line with the disk
image's SHA-256, which `./build.sh release` prints at the end.

## The MCP server

`sand-timer-mcp` is a second program in the same bundle, built from the app's own
`Stats.swift` so the two can't disagree about where a week begins. It speaks JSON-RPC over
stdin and stdout, reads the record from the app's preferences by name (inside the bundle it
shares the app's identifier, so a `UserDefaults` suite of that name would be meaningless),
and only reads. Drive it by hand with:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | build/SandTimer.app/Contents/MacOS/sand-timer-mcp
```

Being a nested program, it is signed before the bundle is sealed around it.

The note says when the run began and when it will end, not only how much is left: a run that was paused and
resumed started earlier than the last thing written down, so leaving the start to be worked out from the remaining
sand would quietly give the wrong answer. A command that arrives while the glass is mid-turn waits for it to
settle rather than being dropped — a hand would have waited too.

Commands go the other way as `sandtimer://` links — `start?minutes=25`, `pause`, `resume`,
`restart`, `end` — which the app takes through `application(_:open:)` and only while the menu's
control setting is on. The app writes what it is doing into `timerState` in its settings
whenever that changes, which is how the server can answer "how long is left?" without
asking the app anything. `Sources/TimerState.swift` defines that note, and is built into
both programs so the two always agree about it.

## Rendering images

The app draws its own images. `SandTimer --snapshot out.png` renders the view to a
PNG — it takes `--minutes`, `--progress`, `--theme`, `--base`, `--angle`, `--shake`,
`--hover` (the day's figure on the base, as when the pointer rests there) and `--dark` —
and `--iconset` renders the app icon at every size macOS asks for,
which is where `AppIcon.icns` comes from. The images in the README were made that way.

The animation is the same renderer run across a range of `--progress` values and
stitched together, so it shows the real drain rather than a recording:

```sh
for i in $(seq 0 35); do
  p=$(python3 -c "print(f'{0.02 + 0.96 * $i / 35:.4f}')")
  SandTimer --snapshot frames/f$(printf %03d $i).png --minutes 25 --progress "$p"
done
ffmpeg -framerate 12 -i frames/f%03d.png -vf "scale=260:-1:flags=lanczos,palettegen" palette.png
ffmpeg -framerate 12 -i frames/f%03d.png -i palette.png \
  -lavfi "scale=260:-1:flags=lanczos[x];[x][1:v]paletteuse" docs/sand-running.gif
```

The shared palette matters: generated per frame, the sand's speckle bands badly.

## The phone apps and linking

```sh
cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@17 ./gradlew assembleDebug testDebugUnitTest
cd ios && xcodegen && open SandTimer.xcodeproj
```

The iPhone app (`ios/`, SwiftUI, iOS 17 and later) is compiled from the Mac's own `Model.swift`,
`SandPhysics.swift`, `Stats.swift`, `Projects.swift`, `TimerState.swift`, `LinkFormat.swift` and
`LinkEngine.swift`.
Its `GlassRenderer.swift` is the Mac's `HourglassRenderer` drawn with UIKit. When the sand
starts, the moment it runs out is handed to the system as a notification. The Android app's
`ui/Hourglass.kt` is the same renderer ported to Compose.

The app is in `android/` (package `io.github.and.sandtimer`, Android 13 and later). The timer
is kept as moments in time (`data/TimerState.kt`), and the moment the sand runs out sets an
exact alarm. A notification stands in for the timer while you're in another app. The record
is kept in the Mac's own format (`data/SandLog.kt` matches `SandLog.stored`), so the two read
each other's time without any conversion.

Linking is Bluetooth Low Energy, straight between the devices, and off until it's turned on in
Settings. The Mac makes a 256-bit key; the QR code carries `sandtimer-link:2:<key, base64url>`.
The Mac is the peripheral: it offers a GATT service whose UUID is drawn from the key
(`LinkFormat.serviceUUID`), so a phone only ever finds its own Mac. The phone writes to one
characteristic and hears the Mac on the other. Each message is JSON sealed with AES-GCM and cut
into pieces of at most 512 bytes, each led by a byte saying whether more follow.

The Mac is the hub and passes each phone's news on to the others. `Sources/LinkEngine.swift`
(the Mac and the iPhone) and `android/…/link/LinkEngine.kt` speak the same messages:

- `hello`: the device, the months of the record it holds with a digest of each, its projects
  and the timer. Each side sends one as they connect.
- `timer`: the shared timer, stamped when it changes; the later stamp wins. The device that
  started a session owns it, and only the owner counts its time.
- `projects`: one list, merged by each project's `updated` stamp (the later change wins).
- `logs`: one month of one device's record, sent only where the other side's digest differs.
- `bye` and `unlinked`: a phone unlinking itself, and the Mac unlinking every phone.

## Layout

| | |
|---|---|
| `Sources/SandPhysics.swift` | how the sand piles, craters, falls and slides |
| `Sources/HourglassRenderer.swift` | drawing the glass, sand and base |
| `Sources/HourglassView.swift` | the view, its gestures and animation |
| `Sources/Sounds.swift` | synthesised pouring, shaking and chime |
| `Sources/Model.swift` | duration, progress and settings |
| `Sources/Stats.swift` | the day-by-day record behind the statistics |
| `Sources/Updates.swift` | the once-a-day look for a newer release |
| `Sources/StatsWindow.swift` | the statistics window and its bar chart |
| `Sources/main.swift` | app lifecycle, menu, `--snapshot` and `--iconset` |
| `Sources/FocusShortcuts.swift` | Do Not Disturb while the sand runs, through two shortcuts |
| `Sources/TimerState.swift` | what the timer is doing, shared with the MCP server |
| `Sources/Link.swift` | linking a phone: the Mac's Bluetooth side and the QR code window |
| `Sources/LinkEngine.swift` | what linked devices say to each other, shared with the iPhone app |
| `Sources/LinkFormat.swift` | the QR code, the Bluetooth service, sealing and the shared timer |
| `ios/` | the iPhone app (SwiftUI), sharing the Mac's model sources |
| `android/` | the Android app (Kotlin, Compose) |
| `Tools/SandTimerMCP/` | the MCP server Claude reads and drives the timer through |

