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
    @Published var collapsedSections: Set<String>

    private let cacheTTL: TimeInterval = 30 * 60  // 30 min
    private var modelContext: ModelContext?

    init() {
        // Load collapsed sections from UserDefaults, default to ["completed"]
        if let data = UserDefaults.standard.data(forKey: "collapsedSections"),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            self.collapsedSections = Set(ids)
        } else {
            self.collapsedSections = ["completed"]
        }
    }

    func toggleSection(_ id: String) {
        if collapsedSections.contains(id) {
            collapsedSections.remove(id)
        } else {
            collapsedSections.insert(id)
        }
        saveCollapsedSections()
    }

    private func saveCollapsedSections() {
        if let data = try? JSONEncoder().encode(Array(collapsedSections)) {
            UserDefaults.standard.set(data, forKey: "collapsedSections")
        }
    }

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
        let autoComplete = true
        let now = Date()

        // Hide completed + closed (closeTime past)
        let visible = assignments.filter { a in
            let isCompleted = a.isChecked || (autoComplete && a.isSubmitted)
            let isClosed = a.closeTime != nil && a.closeTime! < now
            return !(isCompleted && isClosed)
        }

        let active = visible.filter { a in !(a.isChecked || (autoComplete && a.isSubmitted)) }
        let completed = visible
            .filter { a in a.isChecked || (autoComplete && a.isSubmitted) }
            .sorted { ($0.deadline ?? .distantPast) > ($1.deadline ?? .distantPast) }

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
            sections.append(GroupedSection(id: "overdue", label: String(localized: "sectionOverdue"), colorHex: "#e85555", assignments: overdue))
        }
        if !danger.isEmpty {
            sections.append(GroupedSection(id: "danger", label: String(localized: "sectionDanger"), colorHex: "#e85555", assignments: danger))
        }
        if !warning.isEmpty {
            sections.append(GroupedSection(id: "warning", label: String(localized: "sectionWarning"), colorHex: "#d7aa57", assignments: warning))
        }
        if !success.isEmpty {
            sections.append(GroupedSection(id: "success", label: String(localized: "sectionSuccess"), colorHex: "#62b665", assignments: success))
        }
        if !other.isEmpty {
            sections.append(GroupedSection(id: "other", label: String(localized: "sectionOther"), colorHex: "#777777", assignments: other))
        }
        if !completed.isEmpty {
            sections.append(GroupedSection(id: "completed", label: String(localized: "sectionCompleted"), colorHex: "#777777", assignments: completed))
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
            let checkedAssignments = assignments.filter(\.isChecked)
            let existingChecked = Set(checkedAssignments.map(\.compositeKey))
            // Legacy key fallback: old format was "courseId:itemType:title"
            let legacyChecked = Set(checkedAssignments.map { "\($0.courseId):\($0.itemType):\($0.title)" })

            for result in results {
                let course = result.course
                let courseAssignUrl = result.assignmentToolUrl
                    ?? "https://lms.gakusei.kyoto-u.ac.jp/portal/site/\(course.id)"

                // Process assignments
                for detail in result.assignments {
                    let raw = detail.raw
                    let deadline = raw.dueTime?.date ?? raw.dueDate?.date ?? raw.closeTime?.date

                    // Determine status from individual API first
                    // Sakai status文字列はフローチャート（時間比較含む）に基づく正確な判定。
                    // Booleanフィールド（graded, returned等）は前回の提出状態が残るため
                    // 単体では状態#11（返却後に作業中）等を正しく判定できない。
                    // 参照: kulms-extension/docs/sakai-submission-states.md
                    var status = ""
                    var grade = ""
                    let submission = detail.submissions.first
                    if let submission {
                        let subStatus = (submission.status ?? "").lowercased()
                        let statusIndicatesSubmitted =
                            subStatus.contains("提出済") || subStatus.contains("submitted") ||
                            subStatus.contains("再提出") || subStatus.contains("resubmitted") ||
                            subStatus.contains("評定済") || subStatus.contains("graded") ||
                            subStatus.contains("採点済") ||
                            subStatus.contains("返却") || subStatus.contains("returned")

                        if statusIndicatesSubmitted {
                            if submission.graded == true && submission.returned == true {
                                status = "評定済"
                            } else {
                                status = "提出済"
                            }
                            grade = submission.grade ?? ""
                        } else if submission.userSubmission == true && submission.draft != true && (submission.status ?? "").isEmpty {
                            status = "提出済"
                            if submission.graded == true { grade = submission.grade ?? "" }
                        } else if let s = submission.status, s != "未開始", s.lowercased() != "not started" {
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

                    // allowResubmission: check both list API and individual API
                    let allowResubFlag = raw.allowResubmission == true || detail.itemAllowResubmission == true
                    let allowResub: Bool
                    if !allowResubFlag {
                        allowResub = false
                    } else {
                        let remain = submission?.properties?["allow_resubmit_number"]?.stringValue
                        allowResub = remain != "0"
                    }

                    let closeTime = raw.closeTime?.date
                    let entityId = raw.assignmentId ?? ""
                    let title = raw.title ?? ""

                    let assignment = Assignment(
                        courseId: course.id,
                        courseName: course.name,
                        title: title,
                        url: courseAssignUrl,
                        deadline: deadline,
                        closeTime: closeTime,
                        status: status,
                        grade: grade,
                        entityId: entityId,
                        allowResubmission: allowResub
                    )
                    // compositeKey: entityId-based (matching extension's getCheckedKey)
                    assignment.compositeKey = entityId.isEmpty ? "\(course.id):\(title)" : entityId

                    // Preserve checked state (with legacy key fallback)
                    if existingChecked.contains(assignment.compositeKey)
                        || legacyChecked.contains("\(course.id):assignment:\(title)") {
                        assignment.isChecked = true
                    }
                    newAssignments.append(assignment)
                }

                // Process quizzes
                for quiz in result.quizzes {
                    let deadline = quiz.dueDate?.date ?? quiz.retractDate?.date

                    let status = ""
                    let entityId = quiz.publishedAssessmentId.map { String($0) } ?? ""
                    let title = quiz.title ?? ""

                    let assignment = Assignment(
                        courseId: course.id,
                        courseName: course.name,
                        title: title,
                        url: "https://lms.gakusei.kyoto-u.ac.jp/portal/site/\(course.id)",
                        deadline: deadline,
                        closeTime: quiz.retractDate?.date,
                        status: status,
                        itemType: "quiz",
                        entityId: entityId
                    )
                    // compositeKey: entityId-based (matching extension's getCheckedKey)
                    assignment.compositeKey = entityId.isEmpty ? "\(course.id):\(title)" : entityId

                    // Preserve checked state (with legacy key fallback)
                    if existingChecked.contains(assignment.compositeKey)
                        || legacyChecked.contains("\(course.id):quiz:\(title)") {
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
        // Clear WebView cookies/data
        Task { await WebViewFetcher.shared.clearAllData() }
        // Clear stored credentials
        CredentialStore.clear()
        assignments = []
        lastRefreshed = nil
        isLoggedIn = false
    }

    // MARK: - Last Refreshed Text

    var lastRefreshedText: String {
        guard let last = lastRefreshed else { return "" }
        let ago = Int(Date.now.timeIntervalSince(last) / 60)
        if ago < 1 { return String(localized: "lastUpdatedNow") }
        return String(format: String(localized: "lastUpdatedMins"), ago)
    }
}
