import Foundation

/// Up to 1.8.0 the app was called local.sandtimer, a placeholder, and kept its settings and its record under that
/// name. Its proper name keeps them somewhere new, so on the first launch under it everything is carried across —
/// the record, the projects, the target, where the timer stood — and nobody starts again from nothing.
enum PreferencesMove {
    static let oldDomain = "local.sandtimer"
    /// Set once the move has been made, or found unnecessary, so it's only ever tried once.
    static let doneKey = "movedFromLocalSandtimer"

    static func carryOver(into defaults: UserDefaults = .standard,
                          from old: [String: Any]? = UserDefaults.standard.persistentDomain(forName: oldDomain)) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        // Only into a fresh start: if this name already has a record of its own, it isn't overwritten.
        guard let old, !old.isEmpty, defaults.object(forKey: SandLog.defaultsKey) == nil else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
