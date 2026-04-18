import SwiftUI
import SwiftData
import BackgroundTasks
import UserNotifications
import WebKit

@main
struct KULMSApp: App {
    @StateObject private var store = AssignmentStore()

    let modelContainer: ModelContainer = {
        let schema = Schema([Assignment.self, Course.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        return try! ModelContainer(for: schema, configurations: [config])
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .modelContainer(modelContainer)
                .onAppear {
                    store.setModelContext(modelContainer.mainContext)
                }
                .task {
                    await NotificationService.shared.requestPermission()
                }
        }
    }

    init() {
        registerBackgroundTasks()
    }

    // MARK: - Background Tasks

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.kulms.refresh",
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            self.handleAppRefresh(refreshTask)
        }
    }

    private func handleAppRefresh(_ task: BGAppRefreshTask) {
        scheduleNextRefresh()

        let refreshOperation = Task {
            do {
                let sessionValid = try await SakaiAPIClient.shared.checkSession()
                guard sessionValid else {
                    task.setTaskCompleted(success: true)
                    return
                }

                let results = try await SakaiAPIClient.shared.fetchAllAssignments()
                var assignments: [Assignment] = []
                for result in results {
                    for detail in result.assignments {
                        let raw = detail.raw
                        let deadline = raw.dueTime?.date ?? raw.dueDate?.date ?? raw.closeTime?.date
                        var status = ""
                        if let submission = detail.submissions.first {
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
                            } else if submission.userSubmission == true && submission.draft != true && (submission.status ?? "").isEmpty {
                                status = "提出済"
                            }
                        }
                        if status.isEmpty {
                            if raw.submitted == true {
                                status = "提出済"
                            } else if let s = raw.submissionStatus {
                                status = s
                            }
                        }
                        assignments.append(Assignment(
                            courseId: result.course.id,
                            courseName: result.course.name,
                            title: raw.title ?? "",
                            deadline: deadline,
                            closeTime: raw.closeTime?.date,
                            status: status,
                            grade: raw.gradeDisplay ?? raw.grade ?? "",
                            entityId: raw.assignmentId ?? ""
                        ))
                    }
                    for quiz in result.quizzes {
                        let deadline = quiz.dueDate?.date ?? quiz.retractDate?.date
                        var status = ""
                        if quiz.submitted == true { status = "提出済" }
                        assignments.append(Assignment(
                            courseId: result.course.id,
                            courseName: result.course.name,
                            title: quiz.title ?? "",
                            deadline: deadline,
                            status: status,
                            itemType: "quiz",
                            entityId: quiz.publishedAssessmentId.map { String($0) } ?? ""
                        ))
                    }
                }

                await NotificationService.shared.scheduleNotifications(for: assignments)
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            refreshOperation.cancel()
        }
    }

    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.kulms.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60) // 1 hour
        try? BGTaskScheduler.shared.submit(request)
    }
}

// MARK: - Root View

struct ContentView: View {
    @EnvironmentObject private var store: AssignmentStore

    var body: some View {
        // ログイン状態で画面を完全に切り替える（重ねない）。
        // 共有 WKWebView は各画面（CredentialLoginView / AssignmentListView）が
        // それぞれ HiddenWebView で view hierarchy に保持する。
        Group {
            if store.isLoggedIn {
                AssignmentListView()
            } else {
                LoginView()
            }
        }
    }
}
