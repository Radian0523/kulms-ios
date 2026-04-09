import Foundation
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    /// Schedule 24h-before and 1h-before reminders for unsubmitted assignments.
    func scheduleNotifications(for assignments: [Assignment]) async {
        let center = UNUserNotificationCenter.current()
        // Remove all existing KULMS notifications
        center.removeAllPendingNotificationRequests()

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        for assignment in assignments {
            guard let deadline = assignment.deadline,
                  !assignment.isSubmitted,
                  !assignment.isChecked else { continue }

            // 24h before
            schedule(
                id: "kulms-24h-\(assignment.compositeKey)",
                title: "課題の締切が近づいています",
                body: "「\(assignment.title)」（\(assignment.courseName)）の締切まで24時間",
                date: deadline.addingTimeInterval(-24 * 3600)
            )

            // 1h before
            schedule(
                id: "kulms-1h-\(assignment.compositeKey)",
                title: "課題の締切まもなく",
                body: "「\(assignment.title)」（\(assignment.courseName)）の締切まで1時間",
                date: deadline.addingTimeInterval(-3600)
            )
        }
    }

    private func schedule(id: String, title: String, body: String, date: Date) {
        guard date > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request)
    }
}
