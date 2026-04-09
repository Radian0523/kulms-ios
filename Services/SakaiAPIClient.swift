import Foundation

actor SakaiAPIClient {
    static let shared = SakaiAPIClient()

    private let baseURL = URL(string: "https://lms.gakusei.kyoto-u.ac.jp")!
    private let session: URLSession
    private let concurrentLimit = 4

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: config)
    }

    // MARK: - Session

    struct SessionInfo: Decodable {
        let userEid: String?
        let userId: String?
        let active: Bool?
    }

    func checkSession() async throws -> Bool {
        let url = baseURL.appendingPathComponent("/direct/session.json")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        let info = try JSONDecoder().decode(SessionInfo.self, from: data)
        return info.userId != nil && !(info.userId?.isEmpty ?? true)
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
        var components = URLComponents(url: baseURL.appendingPathComponent("/direct/site.json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "_limit", value: "200")]

        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let collection = try JSONDecoder().decode(SiteCollection.self, from: data)
        return collection.site_collection
            .filter { $0.type == "course" || $0.type == "project" }
            .map { (id: $0.id, name: $0.title, type: $0.type ?? "course") }
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
    }

    func fetchAssignments(siteId: String) async throws -> [RawAssignment] {
        let url = baseURL.appendingPathComponent("/direct/assignment/site/\(siteId).json")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let collection = try JSONDecoder().decode(AssignmentCollection.self, from: data)
        return collection.assignment_collection
    }

    /// Fetch all assignments across all courses with concurrency limit.
    func fetchAllAssignments(
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [(course: (id: String, name: String, type: String), assignments: [RawAssignment])] {
        let courses = try await fetchCourses()
        var results: [(course: (id: String, name: String, type: String), assignments: [RawAssignment])] = []
        var completed = 0

        for batch in courses.chunked(into: concurrentLimit) {
            let batchResults = await withTaskGroup(
                of: (course: (id: String, name: String, type: String), assignments: [RawAssignment]).self
            ) { group in
                for course in batch {
                    group.addTask {
                        let assignments = (try? await self.fetchAssignments(siteId: course.id)) ?? []
                        return (course: course, assignments: assignments)
                    }
                }
                var collected: [(course: (id: String, name: String, type: String), assignments: [RawAssignment])] = []
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

        // Try object with "time" key
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
