import AppKit

/// Do Not Disturb while the sand runs. macOS gives apps no switch for Focus, but Shortcuts has one, so this runs two
/// shortcuts you make once in the Shortcuts app: one that turns a Focus on, run as the sand starts, and one that turns
/// it off, run at a pause, an end or the sand running out. With Focus shared across devices, an iPhone signed in
/// to the same Apple Account follows the Mac.
final class FocusShortcuts {
    static let shared = FocusShortcuts()
    static let enabledKey = "focusShortcuts"
    static let onName = "Sand Timer Focus On"
    static let offName = "Sand Timer Focus Off"

    /// Only the app's own timer drives it; tests never set this, so they never run anyone's shortcuts.
    var active = false
    private(set) var isEnabled = UserDefaults.standard.bool(forKey: FocusShortcuts.enabledKey)
    /// What was last asked of Focus, so each start and stop runs a shortcut once.
    private var applied: Bool?
    /// Shortcuts run one at a time, in order, so a quick pause and resume can't finish the wrong way round.
    private let queue = DispatchQueue(label: "sand-timer.focus-shortcuts")

    func setEnabled(_ on: Bool) {
        if !on, applied == true { run(Self.offName) }  // turned off mid-run: don't leave Focus on
        isEnabled = on
        applied = nil
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
    }

    /// Called every tick with whether the sand is running.
    func setSessionRunning(_ running: Bool) {
        guard active, isEnabled, running != applied else { return }
        // At launch with the sand still, Focus is left as it is: it may be on for some other reason.
        if applied == nil && !running { applied = false; return }
        applied = running
        run(running ? Self.onName : Self.offName)
    }

    /// The app is quitting: a Focus it turned on goes off with it.
    func quitting() {
        guard applied == true else { return }
        applied = false
        let done = DispatchSemaphore(value: 0)
        queue.async { Self.shortcuts(["run", Self.offName]); done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }

    /// Which of the two shortcuts are missing from the Shortcuts app.
    func missing(_ found: @escaping ([String]) -> Void) {
        queue.async {
            let names = Set(Self.shortcuts(["list"]).split(separator: "\n").map(String.init))
            let missing = [Self.onName, Self.offName].filter { !names.contains($0) }
            DispatchQueue.main.async { found(missing) }
        }
    }

    private func run(_ name: String) {
        queue.async { Self.shortcuts(["run", name]) }
    }

    @discardableResult
    private static func shortcuts(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
