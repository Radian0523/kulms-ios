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

    init(
        courseId: String,
        courseName: String,
        title: String,
        url: String = "",
        deadline: Date? = nil,
        status: String = "",
        grade: String = "",
        isChecked: Bool = false,
        cachedAt: Date = .now,
        itemType: String = "assignment",
        entityId: String = ""
    ) {
        self.compositeKey = "\(courseId):\(itemType):\(title)"
        self.courseId = courseId
        self.courseName = courseName
        self.title = title
        self.url = url
        self.deadline = deadline
        self.status = status
        self.grade = grade
        self.isChecked = isChecked
        self.cachedAt = cachedAt
        self.itemType = itemType
        self.entityId = entityId
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
            case .overdue: return "期限切れ"
            case .danger:  return "緊急"
            case .warning: return "5日以内"
            case .success: return "14日以内"
            case .other:   return "その他"
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
            || s.contains("評定済") || s.contains("graded")
    }

    var remainingText: String {
        guard let deadline else { return "" }
        let diff = deadline.timeIntervalSinceNow
        if diff < 0 { return "期限切れ" }
        let days = Int(diff / (24 * 3600))
        let hours = Int(diff.truncatingRemainder(dividingBy: 24 * 3600) / 3600)
        if days > 0 { return "残り\(days)日\(hours)時間" }
        if hours > 0 { return "残り\(hours)時間" }
        let mins = Int(diff / 60)
        return "残り\(mins)分"
    }

    var deadlineText: String {
        guard let deadline else { return "-" }
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        f.locale = Locale(identifier: "ja_JP")
        return f.string(from: deadline)
    }
}
