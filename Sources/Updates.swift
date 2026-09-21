import Foundation

/// Noticing that a newer Sand Timer has come out. Once a day at most, the app asks GitHub what the latest release
/// is, compares its tag with its own version, and offers it in the menu if it is newer. It downloads nothing and
/// installs nothing — the menu item opens the release page in a browser. "Check for Updates" in the menu turns the
/// whole thing off, and with it off the app makes no network calls at all.
enum Updates {
    static let latestRelease = URL(string: "https://api.github.com/repos/and/sand-timer/releases/latest")!
    /// Where the menu item leads when the check has nothing more specific to offer.
    static let releasesPage = URL(string: "https://github.com/and/sand-timer/releases/latest")!
    static let interval: TimeInterval = 24 * 60 * 60

    /// This copy's version, from the bundle. Nil when there is no bundle to read it from, and then there is nothing
    /// to compare a release against, so no check is made.
    static var currentVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    /// Whether `candidate` is a later version than `current`: numbers separated by dots, a leading "v" ignored and
    /// missing parts counted as zero, so 1.10 is newer than 1.9, and 1.4.1 newer than 1.4.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let (new, old) = (numbers(candidate), numbers(current))
        guard !new.isEmpty else { return false }
        for place in 0..<max(new.count, old.count) {
            let (a, b) = (place < new.count ? new[place] : 0, place < old.count ? old[place] : 0)
            if a != b { return a > b }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int] {
        version.drop { !$0.isNumber }.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// A tag as people write the version: "v1.5.0" becomes "1.5.0".
    static func label(_ version: String) -> String {
        version.first == "v" || version.first == "V" ? String(version.dropFirst()) : version
    }

    /// The version and page from GitHub's reply, or nil when it isn't a reply we understand.
    static func release(from data: Data) -> (version: String, page: URL)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, !tag.isEmpty, !numbers(tag).isEmpty else { return nil }
        return (tag, (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage)
    }

    /// Time for another look: a day has gone by, or the clock has been set back, or it has never looked at all.
    static func isDue(lastChecked: Date?, at now: Date) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= interval || now < lastChecked
    }
}

/// Keeps the daily check going while the app is open, and remembers what it found between launches.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private(set) var isEnabled = UserDefaults.standard.object(forKey: "updateChecks") as? Bool ?? true
    private var timer: Timer?

    /// The newer release to offer in the menu, if one was found. Worked out afresh each time, so it goes away by
    /// itself once this copy has caught up with it.
    var available: (version: String, page: URL)? {
        let defaults = UserDefaults.standard
        guard isEnabled, let current = Updates.currentVersion, let found = defaults.string(forKey: "updateVersion"),
              Updates.isNewer(found, than: current) else { return nil }
        return (found, defaults.url(forKey: "updatePage") ?? Updates.releasesPage)
    }

    /// Starts the daily check; called once, as the app finishes launching.
    func start() {
        // Every half hour it asks whether a day has passed, so a Mac that slept through the moment catches up soon
        // after it wakes.
        let timer = Timer(timeInterval: 1800, repeats: true) { [weak self] _ in self?.checkIfDue() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Not the instant it opens: logging in is busy enough without a network call.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "updateChecks")
        if enabled { checkIfDue() } else { UserDefaults.standard.removeObject(forKey: "updateVersion") }
    }

    private func checkIfDue() {
        guard isEnabled, Updates.currentVersion != nil,
              Updates.isDue(lastChecked: UserDefaults.standard.object(forKey: "updateCheckedAt") as? Date, at: Date())
        else { return }
        check()
    }

    /// Asks GitHub what the latest release is. Whatever goes wrong — no network, a reply that makes no sense — is
    /// left until tomorrow: a timer on the desk is no place for an error about updates.
    private func check() {
        UserDefaults.standard.set(Date(), forKey: "updateCheckedAt")  // a failed look still counts as today's
        var request = URLRequest(url: Updates.latestRelease, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SandTimer/\(Updates.currentVersion ?? "") (macOS)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let found = Updates.release(from: data) else { return }
            DispatchQueue.main.async {
                UserDefaults.standard.set(found.version, forKey: "updateVersion")
                UserDefaults.standard.set(found.page, forKey: "updatePage")
            }
        }.resume()
    }
}
