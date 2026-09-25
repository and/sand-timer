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
`restart` — which the app takes through `application(_:open:)` and only while the menu's
control setting is on. The app writes what it is doing into `timerState` in its settings
whenever that changes, which is how the server can answer "how long is left?" without
asking the app anything. `Sources/TimerState.swift` defines that note, and is built into
both programs so the two always agree about it.

## Rendering images

The app draws its own images. `SandTimer --snapshot out.png` renders the view to a
PNG — it takes `--minutes`, `--progress`, `--theme`, `--base`, `--angle`, `--shake`
and `--dark` — and `--iconset` renders the app icon at every size macOS asks for,
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
| `Sources/TimerState.swift` | what the timer is doing, shared with the MCP server |
| `Tools/SandTimerMCP/` | the MCP server Claude reads and drives the timer through |

