import Foundation
import SwiftData
import SwiftUI

@MainActor
final class AssignmentStore: ObservableObject {
    @Published var assignments: [Assignment] = []
    @Published var isLoading = false
    @Published var lastRefreshed: Date?
    @Published var progress: (completed: Int, total: Int)?
    @Published var isLoggedIn = true
    @Published var errorMessage: String?

    private let cacheTTL: TimeInterval = 30 * 60  // 30 min
    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Grouped Assignments

    struct GroupedSection: Identifiable {
        let id: String
        let label: String
        let colorHex: String
        let assignments: [Assignment]
    }

    var groupedAssignments: [GroupedSection] {
        let active = assignments.filter { !$0.isSubmitted && !$0.isChecked }
        let submitted = assignments.filter { $0.isSubmitted && !$0.isChecked }
        let checked = assignments.filter { $0.isChecked }

        let sorted = active.sorted { a, b in
            guard let da = a.deadline else { return false }
            guard let db = b.deadline else { return true }
            return da < db
        }

        let danger = sorted.filter { $0.urgency == .overdue || $0.urgency == .danger }
        let warning = sorted.filter { $0.urgency == .warning }
        let success = sorted.filter { $0.urgency == .success }
        let other = sorted.filter { $0.urgency == .other }

        var sections: [GroupedSection] = []
        if !danger.isEmpty {
            sections.append(GroupedSection(id: "danger", label: "緊急", colorHex: "#e85555", assignments: danger))
        }
        if !warning.isEmpty {
            sections.append(GroupedSection(id: "warning", label: "5日以内", colorHex: "#d7aa57", assignments: warning))
        }
        if !success.isEmpty {
            sections.append(GroupedSection(id: "success", label: "14日以内", colorHex: "#62b665", assignments: success))
        }
        if !other.isEmpty {
            sections.append(GroupedSection(id: "other", label: "その他", colorHex: "#777777", assignments: other))
        }
        if !submitted.isEmpty {
            sections.append(GroupedSection(id: "submitted", label: "提出済み", colorHex: "#777777", assignments: submitted))
        }
        if !checked.isEmpty {
            sections.append(GroupedSection(id: "checked", label: "完了済み", colorHex: "#777777", assignments: checked))
        }
        return sections
    }

    // MARK: - Fetch

    func fetchAll(forceRefresh: Bool = false) async {
        guard !isLoading else { return }

        // Check cache TTL
        if !forceRefresh, let last = lastRefreshed,
           Date.now.timeIntervalSince(last) < cacheTTL,
           !assignments.isEmpty {
            return
        }

        // Try loading from SwiftData cache first
        if !forceRefresh, assignments.isEmpty {
            loadFromCache()
            if !assignments.isEmpty, let last = lastRefreshed,
               Date.now.timeIntervalSince(last) < cacheTTL {
                return
            }
        }

        isLoading = true
        errorMessage = nil
        progress = nil

        do {
            // Check session
            let sessionValid = try await SakaiAPIClient.shared.checkSession()
            guard sessionValid else {
                isLoggedIn = false
                isLoading = false
                return
            }

            // Fetch all
            let results = try await SakaiAPIClient.shared.fetchAllAssignments { [weak self] completed, total in
                Task { @MainActor in
                    self?.progress = (completed, total)
                }
            }

            // Build Assignment objects
            var newAssignments: [Assignment] = []
            let existingChecked = Set(assignments.filter(\.isChecked).map(\.compositeKey))

            for result in results {
                let course = result.course
                for raw in result.assignments {
                    let deadline = raw.dueTime?.date ?? raw.dueDate?.date ?? raw.closeTime?.date

                    var status = ""
                    if raw.submitted == true {
                        status = "提出済"
                    } else if let s = raw.submissionStatus {
                        status = s
                    }

                    let assignUrl: String
                    if let entityURL = raw.entityURL {
                        if entityURL.hasPrefix("http") {
                            assignUrl = entityURL
                        } else {
                            assignUrl = "https://lms.gakusei.kyoto-u.ac.jp\(entityURL)"
                        }
                    } else {
                        assignUrl = "https://lms.gakusei.kyoto-u.ac.jp/portal/site/\(course.id)"
                    }

                    let assignment = Assignment(
                        courseId: course.id,
                        courseName: course.name,
                        title: raw.title ?? "",
                        url: assignUrl,
                        deadline: deadline,
                        status: status,
                        grade: raw.gradeDisplay ?? raw.grade ?? ""
                    )

                    // Preserve checked state
                    if existingChecked.contains(assignment.compositeKey) {
                        assignment.isChecked = true
                    }

                    newAssignments.append(assignment)
                }
            }

            // Save to SwiftData
            saveToCache(newAssignments)

            assignments = newAssignments
            lastRefreshed = .now
            progress = nil

            // Schedule notifications
            await NotificationService.shared.scheduleNotifications(for: newAssignments)

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Toggle Check

    func toggleChecked(_ assignment: Assignment) {
        assignment.isChecked.toggle()
        try? modelContext?.save()
    }

    // MARK: - Cache (SwiftData)

    private func loadFromCache() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Assignment>(
            sortBy: [SortDescriptor(\.deadline)]
        )
        if let cached = try? context.fetch(descriptor), !cached.isEmpty {
            assignments = cached
            lastRefreshed = cached.first?.cachedAt
        }
    }

    private func saveToCache(_ newAssignments: [Assignment]) {
        guard let context = modelContext else { return }
        // Delete old
        try? context.delete(model: Assignment.self)
        // Insert new
        for a in newAssignments {
            context.insert(a)
        }
        try? context.save()
    }

    // MARK: - Logout

    func logout() {
        // Clear cookies
        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        // Clear WebView cookies via WKWebsiteDataStore is handled in LoginView
        assignments = []
        lastRefreshed = nil
        isLoggedIn = false
    }

    // MARK: - Last Refreshed Text

    var lastRefreshedText: String {
        guard let last = lastRefreshed else { return "" }
        let ago = Int(Date.now.timeIntervalSince(last) / 60)
        if ago < 1 { return "最終更新: たった今" }
        return "最終更新: \(ago)分前"
    }
}
