// Integration tests: the real timer view in a window, driven with clicks and menu commands.
// Needs a logged-in desktop session; windows appear briefly while it runs. Run with `./build.sh test`.
import AppKit

// This test program keeps its own settings, separate from the app's; keep it quiet.
UserDefaults.standard.set(false, forKey: "soundOn")
UserDefaults.standard.set(false, forKey: "grainSoundOn")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

timerViewTests()
TestKit.finish()
