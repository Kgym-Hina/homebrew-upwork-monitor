import Foundation
import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private static let pendingRouteKey = "pending-job-notification-route"
    nonisolated private static let routeUserInfoKey = "upworkJobRoute"

    var onJobNotificationTap: ((JobNotificationRoute) -> Void)?

    private override init() {
        super.init()
        installDelegate()
    }

    func installDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    func pendingJobRoute() -> JobNotificationRoute? {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingRouteKey) else { return nil }
        return try? JSONDecoder().decode(JobNotificationRoute.self, from: data)
    }

    func clearPendingJobRoute() {
        UserDefaults.standard.removeObject(forKey: Self.pendingRouteKey)
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            ) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func notify(job: UpworkJob, feed: FeedKind) {
        let content = UNMutableNotificationContent()
        content.title = job.title
        if let location = job.client?.location?.displayName, !location.isEmpty {
            content.body = "客户：\(location)"
        } else {
            content.body = "发现新的 Upwork 工作"
        }
        content.sound = .default
        content.threadIdentifier = "upwork-jobs"
        let route = JobNotificationRoute(job: job, feed: feed)
        if let data = try? JSONEncoder().encode(route) {
            content.userInfo[Self.routeUserInfoKey] = data.base64EncodedString()
        }

        let request = UNNotificationRequest(
            identifier: "upwork-job-\(job.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }

        let userInfo = response.notification.request.content.userInfo
        let encoded = userInfo[Self.routeUserInfoKey] as? String
        let routeData = encoded.flatMap { Data(base64Encoded: $0) }
        let route = routeData.flatMap { try? JSONDecoder().decode(JobNotificationRoute.self, from: $0) }
        let legacyRoute: JobNotificationRoute? = {
            let prefix = "upwork-job-"
            let identifier = response.notification.request.identifier
            guard identifier.hasPrefix(prefix) else { return nil }
            let jobID = String(identifier.dropFirst(prefix.count))
            guard !jobID.isEmpty else { return nil }
            return JobNotificationRoute(
                jobID: jobID,
                feed: .mostRecent,
                title: response.notification.request.content.title,
                urlString: nil
            )
        }()
        guard let route = route ?? legacyRoute else {
            return
        }

        Task { @MainActor [weak self] in
            self?.acceptNotificationRoute(route)
        }
    }

    private func acceptNotificationRoute(_ route: JobNotificationRoute) {
        if let data = try? JSONEncoder().encode(route) {
            UserDefaults.standard.set(data, forKey: Self.pendingRouteKey)
        }
        onJobNotificationTap?(route)
    }
}
