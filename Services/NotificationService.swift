import Foundation
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()
    private static let maxPendingNotifications = 64
    private static let defaultOffsets = [1440, 60] // 24h, 1h (minutes)
    private static let offsetsKey = "notificationOffsets"

    private init() {}

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    // MARK: - Notification Offsets

    static func loadNotificationOffsets() -> [Int] {
        guard let data = UserDefaults.standard.data(forKey: offsetsKey),
              let offsets = try? JSONDecoder().decode([Int].self, from: data),
              !offsets.isEmpty else {
            return defaultOffsets
        }
        return offsets
    }

    static func saveNotificationOffsets(_ offsets: [Int]) {
        let sorted = offsets.sorted(by: >)
        if let data = try? JSONEncoder().encode(sorted) {
            UserDefaults.standard.set(data, forKey: offsetsKey)
        }
    }

    // MARK: - Schedule Notifications

    /// Schedule reminders at user-configured offsets for unsubmitted assignments.
    func scheduleNotifications(for assignments: [Assignment]) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let offsets = Self.loadNotificationOffsets()

        // Build all notification candidates, then trim to 64
        struct NotificationCandidate {
            let id: String
            let title: String
            let body: String
            let date: Date
        }

        var candidates: [NotificationCandidate] = []

        for assignment in assignments {
            guard let deadline = assignment.deadline,
                  !assignment.isSubmitted,
                  !assignment.isChecked else { continue }

            for offset in offsets {
                let date = deadline.addingTimeInterval(-Double(offset) * 60)
                guard date > .now else { continue }

                let (title, body) = Self.notificationContent(
                    for: assignment, offsetMinutes: offset
                )
                candidates.append(NotificationCandidate(
                    id: "kulms-\(offset)m-\(assignment.compositeKey)",
                    title: title,
                    body: body,
                    date: date
                ))
            }
        }

        // Sort by date (nearest first) and limit to 64
        candidates.sort { $0.date < $1.date }
        for candidate in candidates.prefix(Self.maxPendingNotifications) {
            schedule(id: candidate.id, title: candidate.title,
                     body: candidate.body, date: candidate.date)
        }
    }

    // MARK: - Helpers

    static func notificationContent(
        for assignment: Assignment, offsetMinutes: Int
    ) -> (title: String, body: String) {
        let label = formatOffsetLabel(offsetMinutes)
        let title: String
        if offsetMinutes <= 60 {
            title = "課題の締切まもなく"
        } else {
            title = "課題の締切が近づいています"
        }
        let body = "「\(assignment.title)」（\(assignment.courseName)）の締切まで\(label)"
        return (title, body)
    }

    static func formatOffsetLabel(_ minutes: Int) -> String {
        if minutes >= 1440 && minutes % 1440 == 0 {
            return "\(minutes / 1440)日"
        } else if minutes >= 60 && minutes % 60 == 0 {
            return "\(minutes / 60)時間"
        } else {
            return "\(minutes)分"
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
