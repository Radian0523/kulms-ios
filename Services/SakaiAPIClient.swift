import Foundation
import WebKit

// MARK: - WebViewFetcher

/// Single persistent WKWebView used for both SSO login display and API calls.
/// Must stay in the view hierarchy at all times (ContentView keeps it via ZStack).
@MainActor
class WebViewFetcher {
    static let shared = WebViewFetcher()

    let webView: WKWebView
    private let baseURL = "https://lms.gakusei.kyoto-u.ac.jp"

    private init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
    }

    func fetch(path: String) async throws -> Data {
        // Wait for any ongoing navigation (e.g. SSO redirect) to complete
        var waitCount = 0
        while webView.isLoading && waitCount < 75 { // max ~15s
            try await Task.sleep(nanoseconds: 200_000_000)
            waitCount += 1
        }

        let fullURL = baseURL + path
        let escaped = fullURL.replacingOccurrences(of: "'", with: "\\'")
        let result = try await webView.callAsyncJavaScript(
            "const r = await fetch('\(escaped)', {credentials:'include', cache:'no-store'}); if (!r.ok) throw new Error('HTTP '+r.status); return await r.text();",
            contentWorld: .page
        )

        guard let text = result as? String, let data = text.data(using: .utf8) else {
            throw NSError(domain: "WebViewFetcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty response"])
        }
        return data
    }
}

// MARK: - SakaiAPIClient

actor SakaiAPIClient {
    static let shared = SakaiAPIClient()

    private let concurrentLimit = 4

    private init() {}

    /// Fetch data via WKWebView's JavaScript fetch (uses authenticated session).
    private func fetchData(path: String) async throws -> Data {
        try await WebViewFetcher.shared.fetch(path: path)
    }

    // MARK: - Session

    /// Check if we have a valid Sakai session by trying to fetch sites.
    /// /direct/session.json returns a collection which is hard to parse,
    /// so we just try /direct/site.json and see if it returns data.
    func checkSession() async throws -> Bool {
        let data = try await fetchData(path: "/direct/site.json?_limit=1")
        let collection = try? JSONDecoder().decode(SiteCollection.self, from: data)
        let valid = (collection?.site_collection.count ?? 0) > 0
        print("[KULMS] checkSession: \(collection?.site_collection.count ?? 0) sites → \(valid)")
        return valid
    }

    // MARK: - Courses

    struct SiteCollection: Decodable {
        let site_collection: [Site]
    }

    struct Site: Decodable {
        let id: String
        let title: String
        let type: String?
    }

    func fetchCourses() async throws -> [(id: String, name: String, type: String)] {
        let data = try await fetchData(path: "/direct/site.json?_limit=200")
        let collection = try JSONDecoder().decode(SiteCollection.self, from: data)
        print("[KULMS] fetchCourses: \(collection.site_collection.count) sites total")
        let filtered = collection.site_collection
            .filter { $0.type == "course" || $0.type == "project" }
        print("[KULMS] fetchCourses: \(filtered.count) courses after filter")
        return filtered.map { (id: $0.id, name: $0.title, type: $0.type ?? "course") }
    }

    // MARK: - Assignments

    struct AssignmentCollection: Decodable {
        let assignment_collection: [RawAssignment]
    }

    struct RawAssignment: Decodable {
        let title: String?
        let entityURL: String?
        let dueTime: FlexibleTimestamp?
        let dueDate: FlexibleTimestamp?
        let closeTime: FlexibleTimestamp?
        let submitted: Bool?
        let submissionStatus: String?
        let gradeDisplay: String?
        let grade: String?

        /// Extract assignment ID from entityURL (e.g. "/direct/assignment/a/{uuid}")
        var assignmentId: String? {
            entityURL?.split(separator: "/").last.map(String.init)
        }
    }

    func fetchAssignments(siteId: String) async throws -> [RawAssignment] {
        let data = try await fetchData(path: "/direct/assignment/site/\(siteId).json")
        let collection = try JSONDecoder().decode(AssignmentCollection.self, from: data)
        print("[KULMS] fetchAssignments(\(siteId)): \(collection.assignment_collection.count) items")
        return collection.assignment_collection
    }

    // MARK: - Quizzes

    struct QuizCollection: Decodable {
        let sam_pub_collection: [RawQuiz]
    }

    struct RawQuiz: Decodable {
        let title: String?
        let startDate: FlexibleTimestamp?
        let dueDate: FlexibleTimestamp?
        let retractDate: FlexibleTimestamp?
        let submitted: Bool?
        let publishedAssessmentId: Int?
    }

    func fetchQuizzes(siteId: String) async throws -> [RawQuiz] {
        let data = try await fetchData(path: "/direct/sam_pub/context/\(siteId).json")
        let collection = try JSONDecoder().decode(QuizCollection.self, from: data)
        // 未公開クイズを除外: startDate が未来のものは非表示 (Comfortable Sakai 準拠)
        let now = Date()
        let filtered = collection.sam_pub_collection.filter { quiz in
            guard let startDate = quiz.startDate?.date else { return true }
            return startDate <= now
        }
        print("[KULMS] fetchQuizzes(\(siteId)): \(collection.sam_pub_collection.count) items, \(filtered.count) published")
        return filtered
    }

    // MARK: - Individual Assignment Detail

    struct RawAssignmentItem: Decodable {
        let submissions: [RawSubmission]?
    }

    struct RawSubmission: Decodable {
        let graded: Bool?
        let grade: String?
        let userSubmission: Bool?
        let submitted: Bool?
        let draft: Bool?
        let status: String?
        let dateSubmittedEpochSeconds: Int64?
    }

    struct AssignmentWithDetail {
        let raw: RawAssignment
        let submissions: [RawSubmission]
    }

    func fetchAssignmentItem(entityId: String) async throws -> RawAssignmentItem {
        let data = try await fetchData(path: "/direct/assignment/item/\(entityId).json")
        return try JSONDecoder().decode(RawAssignmentItem.self, from: data)
    }

    /// Fetch all assignments across all courses with concurrency limit.
    func fetchAllAssignments(
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [(course: (id: String, name: String, type: String), assignments: [AssignmentWithDetail], quizzes: [RawQuiz])] {
        let courses = try await fetchCourses()
        print("[KULMS] fetchAllAssignments: \(courses.count) courses found")
        var results: [(course: (id: String, name: String, type: String), assignments: [AssignmentWithDetail], quizzes: [RawQuiz])] = []
        var completed = 0

        for batch in courses.chunked(into: concurrentLimit) {
            let batchResults = await withTaskGroup(
                of: (course: (id: String, name: String, type: String), assignments: [AssignmentWithDetail], quizzes: [RawQuiz]).self
            ) { group in
                for course in batch {
                    group.addTask {
                        let rawAssignments = (try? await self.fetchAssignments(siteId: course.id)) ?? []
                        let rawQuizzes = (try? await self.fetchQuizzes(siteId: course.id)) ?? []

                        // Fetch individual assignment details in parallel
                        let enriched: [AssignmentWithDetail] = await withTaskGroup(of: AssignmentWithDetail.self) { detailGroup in
                            for raw in rawAssignments {
                                detailGroup.addTask {
                                    if let id = raw.assignmentId, !id.isEmpty {
                                        let item = try? await self.fetchAssignmentItem(entityId: id)
                                        return AssignmentWithDetail(raw: raw, submissions: item?.submissions ?? [])
                                    }
                                    return AssignmentWithDetail(raw: raw, submissions: [])
                                }
                            }
                            var collected: [AssignmentWithDetail] = []
                            for await detail in detailGroup {
                                collected.append(detail)
                            }
                            return collected
                        }

                        return (course: course, assignments: enriched, quizzes: rawQuizzes)
                    }
                }
                var collected: [(course: (id: String, name: String, type: String), assignments: [AssignmentWithDetail], quizzes: [RawQuiz])] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            results.append(contentsOf: batchResults)
            completed += batch.count
            onProgress?(completed, courses.count)
        }

        return results
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case httpError(Int)
        case sessionExpired

        var errorDescription: String? {
            switch self {
            case .httpError(let code): return "API error: HTTP \(code)"
            case .sessionExpired: return "セッションが切れました。再ログインしてください。"
            }
        }
    }
}

// MARK: - FlexibleTimestamp

/// Decodes Sakai timestamps that can be a number, an object with {time: number}, or a string.
struct FlexibleTimestamp: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try number (milliseconds)
        if let ms = try? container.decode(Double.self) {
            self.date = Date(timeIntervalSince1970: ms / 1000)
            return
        }

        // Try object with "epochSecond" key (Sakai's Java Instant format)
        if let obj = try? container.decode(EpochSecondObject.self) {
            self.date = Date(timeIntervalSince1970: Double(obj.epochSecond))
            return
        }

        // Try object with "time" key (milliseconds)
        if let obj = try? container.decode(TimestampObject.self) {
            self.date = Date(timeIntervalSince1970: Double(obj.time) / 1000)
            return
        }

        // Try string
        if let str = try? container.decode(String.self), let ms = Double(str) {
            self.date = Date(timeIntervalSince1970: ms / 1000)
            return
        }

        self.date = nil
    }

    private struct EpochSecondObject: Decodable {
        let epochSecond: Int64
    }

    private struct TimestampObject: Decodable {
        let time: Int64
    }
}

// MARK: - Array chunking

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
