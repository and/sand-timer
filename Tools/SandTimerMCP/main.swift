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

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let data = line.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    guard let response = SandTimerMCP.respond(to: request, log: currentRecord, now: Date()),
          let reply = try? JSONSerialization.data(withJSONObject: response) else { continue }
    FileHandle.standardOutput.write(reply + Data("\n".utf8))
}
