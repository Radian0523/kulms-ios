import Foundation
import SwiftData

@Model
final class Assignment {
    @Attribute(.unique) var compositeKey: String
    var courseId: String
    var courseName: String
    var title: String
    var url: String
    var deadline: Date?
    var status: String
    var grade: String
    var isChecked: Bool
    var cachedAt: Date
    var itemType: String = "assignment"
    var entityId: String = ""
    var closeTime: Date?
    var allowResubmission: Bool = false

    init(
        courseId: String,
        courseName: String,
        title: String,
        url: String = "",
        deadline: Date? = nil,
        closeTime: Date? = nil,
        status: String = "",
        grade: String = "",
        isChecked: Bool = false,
        cachedAt: Date = .now,
        itemType: String = "assignment",
        entityId: String = "",
        allowResubmission: Bool = false
    ) {
        self.compositeKey = "\(courseId):\(itemType):\(title)"
        self.courseId = courseId
        self.courseName = courseName
        self.title = title
        self.url = url
        self.deadline = deadline
        self.closeTime = closeTime
        self.status = status
        self.grade = grade
        self.isChecked = isChecked
        self.cachedAt = cachedAt
        self.itemType = itemType
        self.entityId = entityId
        self.allowResubmission = allowResubmission
    }

    // MARK: - Urgency

    enum Urgency: String, CaseIterable, Comparable {
        case overdue
        case danger   // < 24h
        case warning  // < 5 days
        case success  // < 14 days
        case other

        var sortOrder: Int {
            switch self {
            case .overdue: return 0
            case .danger:  return 1
            case .warning: return 2
            case .success: return 3
            case .other:   return 4
            }
        }

        static func < (lhs: Urgency, rhs: Urgency) -> Bool {
            lhs.sortOrder < rhs.sortOrder
        }

        var label: String {
            switch self {
            case .overdue: return String(localized: "sectionOverdue")
            case .danger:  return String(localized: "sectionDanger")
            case .warning: return String(localized: "sectionWarning")
            case .success: return String(localized: "sectionSuccess")
            case .other:   return String(localized: "sectionOther")
            }
        }

        var colorHex: String {
            switch self {
            case .overdue: return "#e85555"
            case .danger:  return "#e85555"
            case .warning: return "#d7aa57"
            case .success: return "#62b665"
            case .other:   return "#777777"
            }
        }
    }

    // MARK: - Computed

    var urgency: Urgency {
        guard let deadline else { return .other }
        let diff = deadline.timeIntervalSinceNow
        if diff < 0 { return .overdue }
        if diff < 24 * 3600 { return .danger }
        if diff < 5 * 24 * 3600 { return .warning }
        if diff < 14 * 24 * 3600 { return .success }
        return .other
    }

    var isSubmitted: Bool {
        let s = status.lowercased()
        return s.contains("提出済") || s.contains("submitted")
            || s.contains("再提出") || s.contains("resubmitted")
            || s.contains("評定済") || s.contains("graded") || s.contains("採点済")
            || s.contains("返却") || s.contains("returned")
    }

    var remainingText: String {
        guard let deadline else { return "" }
        let diff = deadline.timeIntervalSinceNow
        if diff < 0 {
            // 締切過ぎ: closeTime が未過ぎなら再提出受付期間
            if let ct = closeTime, ct.timeIntervalSinceNow > 0 { return String(localized: "resubmitPeriod") }
            return String(localized: "expired")
        }
        let days = Int(diff / (24 * 3600))
        let hours = Int(diff.truncatingRemainder(dividingBy: 24 * 3600) / 3600)
        let mins = Int(diff.truncatingRemainder(dividingBy: 3600) / 60)
        if days > 0 { return String(format: String(localized: "remainDaysHoursMins"), days, hours, mins) }
        if hours > 0 { return String(format: String(localized: "remainHoursMins"), hours, mins) }
        return String(format: String(localized: "remainMins"), mins)
    }

    var deadlineText: String {
        guard let deadline else { return "-" }
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        f.locale = Locale(identifier: "ja_JP")
        return f.string(from: deadline)
    }
}
