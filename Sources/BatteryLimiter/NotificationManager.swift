import os
import UserNotifications

enum NotificationManager {
    private static let log = Logger(subsystem: "com.batterylimiter.app", category: "notifications")

    /// Both callbacks below used to discard their result. That is how "I get no
    /// notifications" stayed unexplainable: the app is listed in Notification
    /// Center whether or not authorization was ever granted, so nothing outside
    /// these two callbacks says the request failed.
    ///
    ///     log show --predicate 'subsystem == "com.batterylimiter.app"' --last 1h
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                log.error("authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.notice("authorization granted=\(granted, privacy: .public)")
            }
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            log.notice("""
                settings: authorization=\(settings.authorizationStatus.rawValue, privacy: .public) \
                alert=\(settings.alertSetting.rawValue, privacy: .public) \
                sound=\(settings.soundSetting.rawValue, privacy: .public) \
                notificationCenter=\(settings.notificationCenterSetting.rawValue, privacy: .public)
                """)
        }
    }

    static func notifyCapReached(percent: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Battery Limiter"
        content.body = "Charging paused at \(percent)%."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "com.batterylimiter.cap-reached",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("cap-reached post failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.notice("cap-reached posted at \(percent, privacy: .public)%")
            }
        }
    }
}
