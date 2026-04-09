import SwiftUI
import SwiftData
import BackgroundTasks
import UserNotifications

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
                    for raw in result.assignments {
                        let deadline = raw.dueTime?.date ?? raw.dueDate?.date ?? raw.closeTime?.date
                        var status = ""
                        if raw.submitted == true {
                            status = "提出済"
                        } else if let s = raw.submissionStatus {
                            status = s
                        }
                        assignments.append(Assignment(
                            courseId: result.course.id,
                            courseName: result.course.name,
                            title: raw.title ?? "",
                            deadline: deadline,
                            status: status,
                            grade: raw.gradeDisplay ?? raw.grade ?? ""
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
        if store.isLoggedIn {
            AssignmentListView()
        } else {
            LoginView()
        }
    }
}
