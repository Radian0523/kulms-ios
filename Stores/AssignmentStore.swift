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
        let autoComplete = UserDefaults.standard.object(forKey: "autoComplete") as? Bool ?? true

        // Hide overdue + completed (submitted or checked)
        let visible = assignments.filter { a in
            let isCompleted = a.isChecked || (autoComplete && a.isSubmitted)
            return !(a.urgency == .overdue && isCompleted)
        }

        let active = visible.filter { a in !(a.isChecked || (autoComplete && a.isSubmitted)) }
        let completed = visible.filter { a in a.isChecked || (autoComplete && a.isSubmitted) }

        let sorted = active.sorted { a, b in
            guard let da = a.deadline else { return false }
            guard let db = b.deadline else { return true }
            return da < db
        }

        let overdue = sorted.filter { $0.urgency == .overdue }
        let danger = sorted.filter { $0.urgency == .danger }
        let warning = sorted.filter { $0.urgency == .warning }
        let success = sorted.filter { $0.urgency == .success }
        let other = sorted.filter { $0.urgency == .other }

        var sections: [GroupedSection] = []
        if !overdue.isEmpty {
            sections.append(GroupedSection(id: "overdue", label: "遅延提出", colorHex: "#e85555", assignments: overdue))
        }
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
        if !completed.isEmpty {
            sections.append(GroupedSection(id: "completed", label: "完了済み", colorHex: "#777777", assignments: completed))
        }
        return sections
    }

    // MARK: - Load Cache (startup only, no network)

    func loadCached() {
        guard assignments.isEmpty else { return }
        loadFromCache()
    }

    // MARK: - Fetch (network, called from refresh button / after login)

    func fetchAll(forceRefresh: Bool = false) async {
        guard !isLoading else { return }

        // Check cache TTL
        if !forceRefresh, let last = lastRefreshed,
           Date.now.timeIntervalSince(last) < cacheTTL,
           !assignments.isEmpty {
            return
        }

        isLoading = true
        errorMessage = nil
        progress = nil

        do {
            // Check session
            print("[KULMS] fetchAll: checking session...")
            let sessionValid = try await SakaiAPIClient.shared.checkSession()
            print("[KULMS] fetchAll: session valid = \(sessionValid)")
            guard sessionValid else {
                isLoggedIn = false
                isLoading = false
                return
            }

            // Fetch all
            print("[KULMS] fetchAll: fetching assignments...")
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

                // Process assignments
                for detail in result.assignments {
                    let raw = detail.raw
                    let deadline = raw.dueTime?.date ?? raw.dueDate?.date ?? raw.closeTime?.date

                    // Determine status from individual API first
                    var status = ""
                    var grade = ""
                    if let submission = detail.submissions.first {
                        if submission.graded == true {
                            status = "評定済"
                            grade = submission.grade ?? ""
                        } else if submission.userSubmission == true && submission.draft != true {
                            status = "提出済"
                        } else if let s = submission.status, s != "未開始" {
                            status = s
                        }
                    }
                    // Fallback to list API data
                    if status.isEmpty {
                        if raw.submitted == true {
                            status = "提出済"
                        } else if let s = raw.submissionStatus {
                            status = s
                        }
                    }
                    if grade.isEmpty {
                        grade = raw.gradeDisplay ?? raw.grade ?? ""
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
                        grade: grade,
                        entityId: raw.assignmentId ?? ""
                    )

                    if existingChecked.contains(assignment.compositeKey) {
                        assignment.isChecked = true
                    }
                    newAssignments.append(assignment)
                }

                // Process quizzes
                for quiz in result.quizzes {
                    let deadline = quiz.dueDate?.date ?? quiz.retractDate?.date

                    var status = ""
                    if quiz.submitted == true {
                        status = "提出済"
                    }

                    let assignment = Assignment(
                        courseId: course.id,
                        courseName: course.name,
                        title: quiz.title ?? "",
                        url: "https://lms.gakusei.kyoto-u.ac.jp/portal/site/\(course.id)",
                        deadline: deadline,
                        status: status,
                        itemType: "quiz",
                        entityId: quiz.publishedAssessmentId.map { String($0) } ?? ""
                    )

                    if existingChecked.contains(assignment.compositeKey) {
                        assignment.isChecked = true
                    }
                    newAssignments.append(assignment)
                }
            }

            print("[KULMS] fetchAll: \(newAssignments.count) assignments built (\(newAssignments.filter { $0.itemType == "quiz" }.count) quizzes)")

            // Save to SwiftData
            saveToCache(newAssignments)

            assignments = newAssignments
            lastRefreshed = .now
            progress = nil

            // Schedule notifications
            await NotificationService.shared.scheduleNotifications(for: newAssignments)

        } catch SakaiAPIClient.APIError.sessionExpired {
            // セッション切れ: キャッシュを保護し、既存データを維持する
            print("[KULMS] fetchAll: session expired mid-fetch, preserving cache")
            isLoggedIn = false
        } catch {
            print("[KULMS] fetchAll error: \(error)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
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
