import Foundation

/// Sand Timer's MCP server: one JSON-RPC message per line on stdin, one per line on stdout, which is how Claude
/// talks to a program on your own Mac. It reads the record the timer keeps and nothing else — it cannot start,
/// stop or change the timer, and it makes no network calls.
///
///     claude mcp add sand-timer -- /Applications/Sand\ Timer.app/Contents/MacOS/sand-timer-mcp

/// The app's preferences, where the record lives. Asked for by name rather than through this program's own
/// settings: inside the bundle the server shares the app's identifier, which makes a suite of that name meaningless.
let timerPreferences = "local.sandtimer" as CFString

/// The record as it stands. Read again for every request, and synchronised first, so a timer that has been running
/// since the last question is counted.
func currentRecord() -> SandLog {
    CFPreferencesAppSynchronize(timerPreferences)
    let stored = CFPreferencesCopyAppValue(SandLog.defaultsKey as CFString, timerPreferences) as? [String: [String: Any]]
    return SandLog.load(stored: stored ?? [:])
}

/// What the timer is doing, as the app last wrote it down.
func currentState() -> TimerState {
    CFPreferencesAppSynchronize(timerPreferences)
    return TimerState.load(stored: CFPreferencesCopyAppValue(TimerState.key as CFString, timerPreferences) as? [String: Any])
}

func controlAllowed() -> Bool {
    CFPreferencesAppSynchronize(timerPreferences)
    return CFPreferencesCopyAppValue(TimerState.controlKey as CFString, timerPreferences) as? Bool ?? false
}

/// Asks the app to do something, as a sandtimer:// link — the same link Shortcuts or a terminal would open — and
/// waits for the app to write down what it did. The app may have to start up first, hence the patience.
func send(_ command: String, minutes: Int?) -> Result<TimerState, Unreachable> {
    var link = URLComponents()
    link.scheme = "sandtimer"
    link.host = command
    if let minutes { link.queryItems = [URLQueryItem(name: "minutes", value: String(minutes))] }
    guard let url = link.url else { return .failure(Unreachable(reason: "Couldn't put together a link for \(command).")) }

    let asked = Date()
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", url.absoluteString]  // -g: don't take the screen away from whatever is in front
    do {
        try open.run()
    } catch {
        return .failure(Unreachable(reason: "Couldn't reach Sand Timer: \(error.localizedDescription)"))
    }
    open.waitUntilExit()
    guard open.terminationStatus == 0 else {
        return .failure(Unreachable(reason: "Nothing on this Mac answers sandtimer:// links. Is Sand Timer installed?"))
    }
    // The app writes down what it is doing as it does it, so a newer note than the moment we asked is the answer.
    let deadline = Date().addingTimeInterval(6)
    while Date() < deadline {
        let state = currentState()
        if state.updated > asked { return .success(state) }
        usleep(100_000)
    }
    return .failure(Unreachable(reason: """
        Sand Timer didn't answer. It may not be running, or "Control from Claude & Shortcuts" may be off in \
        its right-click menu.
        """))
}

let access = SandTimerAccess(log: currentRecord, state: currentState, allowsControl: controlAllowed, send: send)

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let data = line.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    guard let response = SandTimerMCP.respond(to: request, access: access, now: Date()),
          let reply = try? JSONSerialization.data(withJSONObject: response) else { continue }
    FileHandle.standardOutput.write(reply + Data("\n".utf8))
}
