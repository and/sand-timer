import UserNotifications

/// The chime when the sand runs out. iOS doesn't let an app keep time in the background, so the moment is handed to
/// the system as a notification when the sand starts, and taken back on a pause or an end.
enum Notifier {
    private static let id = "sand-ran-out"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func schedule(_ session: Session, projects: ProjectList, chime: Bool) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let until = session.runningUntil, until > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time's up"
        let project = projects.project(session.project)?.name
        content.body = "\(session.minutes) minutes" + (project.map { " of \($0)" } ?? "") + " ran out."
        content.sound = chime ? UNNotificationSound(named: UNNotificationSoundName("chime.wav")) : nil
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, until.timeIntervalSinceNow), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

/// Shows the chime's notification even while the app is open, since that is when the sand is most likely watched.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
