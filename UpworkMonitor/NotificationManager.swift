import Foundation
import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            ) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func notify(job: UpworkJob) {
        let content = UNMutableNotificationContent()
        content.title = job.title
        if let location = job.client?.location?.displayName, !location.isEmpty {
            content.body = "客户：\(location)"
        } else {
            content.body = "发现新的 Upwork 工作"
        }
        content.sound = .default
        content.threadIdentifier = "upwork-jobs"

        let request = UNNotificationRequest(
            identifier: "upwork-job-\(job.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
