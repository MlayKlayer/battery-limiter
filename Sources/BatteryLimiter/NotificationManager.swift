import UserNotifications

enum NotificationManager {
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
