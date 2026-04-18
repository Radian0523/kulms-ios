import Foundation
import WebKit

// MARK: - LoginResult

enum LoginResult {
    case success
    case otpRequired
    case failed(String)
}

// MARK: - WebViewFetcher

/// Single persistent WKWebView used for both SSO login display and API calls.
/// Must stay in the view hierarchy at all times (ContentView keeps it via ZStack).
@MainActor
class WebViewFetcher: NSObject {
    static let shared = WebViewFetcher()

    let webView: WKWebView
    let baseURL = "https://lms.gakusei.kyoto-u.ac.jp"
    let loginPortalURL = "https://lms.gakusei.kyoto-u.ac.jp/portal/login"
    let iimcHost = "auth.iimc.kyoto-u.ac.jp"

    /// ログイン進行中のナビゲーション通知用クロージャ。
    private var navigationListeners: [(URL) -> Void] = []

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        // Safari Web Inspector でのデバッグを許可
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
    }

    func fetch(path: String) async throws -> Data {
        // 必要なら lms.gakusei に navigate してから JS fetch を実行
        // （SAML SSO 直後など、WebView の document が別 origin にいるケースを救済）
        try await ensureOnLMS()

        // Wait for any ongoing navigation (e.g. SSO redirect) to complete
        await waitForStableNavigation(maxSeconds: 15)

        // 相対 URL で fetch（カレント origin = lms.gakusei に対して解決される）
        let escaped = path.replacingOccurrences(of: "'", with: "\\'")
        let js = """
            try {
                const r = await fetch('\(escaped)', {credentials:'include', cache:'no-store'});
                if (r.redirected && /\\/portal\\/(x?login|relogin|logout)/.test(r.url)) throw new Error('SESSION_EXPIRED');
                var ct = r.headers.get('content-type') || '';
                if (ct && ct.indexOf('json') === -1) throw new Error('SESSION_EXPIRED');
                if (!r.ok) throw new Error('HTTP '+r.status);
                return await r.text();
            } catch (e) {
                throw new Error('FETCH_FAILED: ' + (e && e.message ? e.message : String(e)) + ' @ ' + window.location.href);
            }
            """
        let result = try await webView.callAsyncJavaScript(js, contentWorld: .page)

        guard let text = result as? String, let data = text.data(using: .utf8) else {
            throw NSError(domain: "WebViewFetcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty response"])
        }
        return data
    }

    /// 現在の WebView がまだ lms.gakusei.kyoto-u.ac.jp の document を表示していなければ
    /// /portal をロードする。SAML SSO 直後など origin が auth.iimc に残ってる場合の救済。
    /// 未ログインで SAML へリダイレクトされた場合は `APIError.sessionExpired` を投げる。
    private func ensureOnLMS() async throws {
        if let host = webView.url?.host, host == "lms.gakusei.kyoto-u.ac.jp" {
            return
        }
        let target = baseURL + "/portal"
        print("[KULMS] ensureOnLMS: navigating to \(target) (current=\(webView.url?.absoluteString ?? "nil"))")
        if let url = URL(string: target) {
            webView.load(URLRequest(url: url))
        }
        await waitForStableNavigation(maxSeconds: 15)
        if let host = webView.url?.host, host != "lms.gakusei.kyoto-u.ac.jp" {
            // SAML 認証画面へリダイレクトされた = セッション無効
            print("[KULMS] ensureOnLMS: session expired (redirected to \(host))")
            throw SakaiAPIClient.APIError.sessionExpired
        }
    }

    // MARK: - Credential login

    /// ECS-ID/パスワードを使って KULMS にログインする。
    ///
    /// フロー:
    /// 1. /portal/login へアクセス → IIMC SAML SSO へリダイレクト
    /// 2. login.cgi が表示されたら DOM に値を注入してフォーム送信
    /// 3. 以下のいずれかが起きるまで URL を監視:
    ///    - lms.gakusei に戻る → success
    ///    - login.cgi にエラーメッセージが現れる → failed
    ///    - OTP 入力欄が表示される → otpRequired
    func loginWithCredentials(username: String, password: String) async -> LoginResult {
        await withCheckedContinuation { continuation in
            var credentialsInjected = false
            var hasResumed = false

            let resume: (LoginResult) -> Void = { [weak self] result in
                guard !hasResumed else { return }
                hasResumed = true
                self?.navigationListeners.removeAll()
                continuation.resume(returning: result)
            }

            let listener: (URL) -> Void = { [weak self] url in
                guard let self = self, !hasResumed else { return }
                let urlString = url.absoluteString
                print("[KULMS] loginWithCredentials: navigated to \(urlString)")

                // 成功判定: lms.gakusei の portal 系ページに到達し、/login を含まない。
                // 中継 URL（/Shibboleth.sso/* など）は除外して、本当のセッション確立を待つ。
                let isPortalPage = urlString.hasPrefix(self.baseURL + "/portal")
                    && !urlString.contains("/login")
                    && !urlString.contains("/relogin")
                    && !urlString.contains("/logout")
                if isPortalPage {
                    print("[KULMS] loginWithCredentials: portal reached, waiting for stable state")
                    Task { @MainActor in
                        // ページが完全に安定するまで待つ（追加リダイレクトを吸収）
                        await self.waitForStableNavigation()
                        guard !hasResumed else { return }
                        print("[KULMS] loginWithCredentials: SUCCESS")
                        resume(.success)
                    }
                    return
                }

                // 2段階認証 (authselect.php / u2flogin.cgi / otplogin.cgi / motplogin.cgi)
                // → ECS-ID/パスワードは通ったが追加認証が必要 → WebView UI に切替
                let twoFactorPaths = ["/authselect.php", "/u2flogin.cgi",
                                       "/otplogin.cgi", "/motplogin.cgi"]
                if urlString.contains(self.iimcHost)
                    && twoFactorPaths.contains(where: { urlString.contains($0) }) {
                    print("[KULMS] loginWithCredentials: 2FA required → WebView fallback")
                    resume(.otpRequired)
                    return
                }

                // login.cgi (ID/パスワード入力画面)
                // ※ "/login.cgi" でマッチさせる（u2flogin.cgi 等の誤マッチ回避）
                if urlString.contains(self.iimcHost) && urlString.contains("/login.cgi") {
                    if !credentialsInjected {
                        credentialsInjected = true
                        Task { @MainActor in
                            self.injectCredentials(username: username, password: password)
                        }
                    } else {
                        // 2回目以降の login.cgi の判定:
                        // - error メッセージあり → 即座に failed
                        // - OTP 要素あり (古いフロー) → otpRequired
                        // - unknown → 次の navigation (authselect.php 等) を待つ
                        //   ※ login.cgi (back なし) は認証成功後の中継ページである場合があるため、
                        //     ここで failed と判定すると authselect 遷移より早く終わってしまう
                        Task { @MainActor in
                            guard !hasResumed else { return }
                            let state = await self.checkLoginCgiState()
                            guard !hasResumed else { return }
                            switch state {
                            case .otp:
                                print("[KULMS] loginWithCredentials: OTP required")
                                resume(.otpRequired)
                            case .error(let msg):
                                print("[KULMS] loginWithCredentials: failed - \(msg)")
                                resume(.failed(msg))
                            case .unknown:
                                print("[KULMS] loginWithCredentials: login.cgi unknown state, waiting for next navigation")
                                // resume せず、次の navigation を待つ。
                                // 全体タイムアウト (30秒) があるので最終的には終わる。
                            }
                        }
                    }
                }
            }

            navigationListeners.append(listener)

            // 全体タイムアウト 30 秒
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                resume(.failed("ログイン処理がタイムアウトしました。ネットワーク状況を確認してください。"))
            }

            // ログイン開始
            if let url = URL(string: loginPortalURL) {
                webView.load(URLRequest(url: url))
            }
        }
    }

    /// IIMC ログイン画面（login.cgi）に再アクセスする。
    func loadLoginPortal() {
        if let url = URL(string: loginPortalURL) {
            webView.load(URLRequest(url: url))
        }
    }

    /// login.cgi のフォームに認証情報を注入して送信する。
    private func injectCredentials(username: String, password: String) {
        let u = username
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let p = password
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
            (function() {
                try {
                    var u = document.getElementById('username_input');
                    var p = document.getElementById('password_input');
                    var f = document.getElementById('login');
                    if (u && p && f) {
                        u.value = '\(u)';
                        p.value = '\(p)';
                        u.dispatchEvent(new Event('input', {bubbles: true}));
                        p.dispatchEvent(new Event('input', {bubbles: true}));
                        f.submit();
                    }
                } catch (e) {}
            })();
            """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private enum CgiState {
        case unknown
        case error(String)
        case otp
    }

    /// 現在の login.cgi ページの状態を判定する。
    private func checkLoginCgiState() async -> CgiState {
        let js = """
            (function() {
                try {
                    var otpSend = document.getElementById('otp_send_button');
                    var dusername = document.getElementById('dusername_area');
                    var commentEl = document.getElementById('comment');

                    var otpVisible = false;
                    if (otpSend && otpSend.style.display !== 'none') otpVisible = true;
                    if (dusername && dusername.children.length > 0) otpVisible = true;

                    if (otpVisible) return JSON.stringify({type: 'otp'});

                    var msg = '';
                    if (commentEl) {
                        var t = (commentEl.innerText || commentEl.textContent || '').trim();
                        if (t && t.length > 1) msg = t;
                    }
                    if (msg) return JSON.stringify({type: 'error', message: msg});

                    return JSON.stringify({type: 'unknown'});
                } catch (e) {
                    return JSON.stringify({type: 'unknown'});
                }
            })();
            """
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js) { result, _ in
                guard let str = result as? String else {
                    continuation.resume(returning: .unknown)
                    return
                }
                if str.contains("\"type\":\"otp\"") {
                    continuation.resume(returning: .otp)
                } else if str.contains("\"type\":\"error\"") {
                    let regex = try? NSRegularExpression(pattern: "\"message\":\"([^\"]*)\"")
                    let range = NSRange(str.startIndex..<str.endIndex, in: str)
                    if let match = regex?.firstMatch(in: str, range: range),
                       let r = Range(match.range(at: 1), in: str) {
                        continuation.resume(returning: .error(String(str[r])))
                    } else {
                        continuation.resume(returning: .error("ログインに失敗しました"))
                    }
                } else {
                    continuation.resume(returning: .unknown)
                }
            }
        }
    }

    /// WKWebView のナビゲーションが安定するまで待機する。
    /// `isLoading` が連続して `quietPeriodMs` ミリ秒間 false であれば安定とみなす。
    /// SAML SSO のような連続リダイレクト中、`isLoading` は短時間 false になる隙間があるため、
    /// 安定期間を確保することでロード途中での JS 実行を防ぐ。
    func waitForStableNavigation(maxSeconds: Double = 10) async {
        let stepNs: UInt64 = 100_000_000  // 100ms
        let quietRequired = 5  // 連続 5 ステップ (= 500ms) 静止で安定とみなす
        let maxSteps = Int(maxSeconds * 10)

        var quietCount = 0
        var totalSteps = 0
        while totalSteps < maxSteps {
            try? await Task.sleep(nanoseconds: stepNs)
            totalSteps += 1
            if webView.isLoading {
                quietCount = 0
            } else {
                quietCount += 1
                if quietCount >= quietRequired { return }
            }
        }
    }

    /// 全 cookie とキャッシュをクリアする（ログアウト時用）。
    func clearAllData() async {
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await dataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewFetcher: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            // 同期的なリスト変更の中で iterate するためコピー
            let listeners = navigationListeners
            for l in listeners { l(url) }
        }
    }
}

// MARK: - SakaiAPIClient

actor SakaiAPIClient {
    static let shared = SakaiAPIClient()

    private let concurrentLimit = 4

    private init() {}

    /// Fetch data via WKWebView's JavaScript fetch (uses authenticated session).
    private func fetchData(path: String) async throws -> Data {
        do {
            return try await WebViewFetcher.shared.fetch(path: path)
        } catch {
            // JS の SESSION_EXPIRED を APIError.sessionExpired に変換
            if error.localizedDescription.contains("SESSION_EXPIRED") {
                throw APIError.sessionExpired
            }
            throw error
        }
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
        let returned: Bool?
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
            let batchResults = try await withThrowingTaskGroup(
                of: (course: (id: String, name: String, type: String), assignments: [AssignmentWithDetail], quizzes: [RawQuiz]).self
            ) { group in
                for course in batch {
                    group.addTask {
                        let rawAssignments: [RawAssignment]
                        do {
                            rawAssignments = try await self.fetchAssignments(siteId: course.id)
                        } catch is APIError {
                            throw APIError.sessionExpired // セッション切れは上位に伝播
                        } catch {
                            rawAssignments = []
                        }

                        let rawQuizzes: [RawQuiz]
                        do {
                            rawQuizzes = try await self.fetchQuizzes(siteId: course.id)
                        } catch is APIError {
                            throw APIError.sessionExpired
                        } catch {
                            rawQuizzes = []
                        }

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
                for try await result in group {
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
