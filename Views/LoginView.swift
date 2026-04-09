import SwiftUI
import WebKit

struct LoginView: View {
    @EnvironmentObject private var store: AssignmentStore
    @State private var isVerifying = false
    @State private var errorText: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            SSOWebView(onLoginDetected: handleLogin)

            // Bottom overlay with login button
            VStack(spacing: 8) {
                if let error = errorText {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    handleLogin()
                } label: {
                    if isVerifying {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text("認証を確認中...")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text("ログイン完了 → 課題一覧へ")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isVerifying)

                Text("SSOログイン後にタップしてください")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }

    private func handleLogin() {
        guard !isVerifying else { return }
        isVerifying = true
        errorText = nil

        Task {
            // Transfer ALL cookies from WKWebView to URLSession
            let wkStore = WKWebsiteDataStore.default().httpCookieStore
            let cookies = await wkStore.allCookies()
            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }

            // Verify with Sakai API
            do {
                let valid = try await SakaiAPIClient.shared.checkSession()
                if valid {
                    store.isLoggedIn = true
                } else {
                    errorText = "セッションが確認できません。ログインしてから再度タップしてください。"
                }
            } catch {
                errorText = "確認に失敗しました: \(error.localizedDescription)"
            }
            isVerifying = false
        }
    }
}

// MARK: - WKWebView Wrapper

struct SSOWebView: UIViewRepresentable {
    let onLoginDetected: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoginDetected: onLoginDetected)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        let url = URL(string: "https://lms.gakusei.kyoto-u.ac.jp/portal")!
        webView.load(URLRequest(url: url))

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        let onLoginDetected: () -> Void
        private var hasDetected = false

        init(onLoginDetected: @escaping () -> Void) {
            self.onLoginDetected = onLoginDetected
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !hasDetected,
                  let url = webView.url,
                  let host = url.host,
                  host == "lms.gakusei.kyoto-u.ac.jp",
                  url.path.hasPrefix("/portal") else { return }

            // Auto-detect: check for session cookie
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                let hasSakaiSession = cookies.contains { cookie in
                    cookie.domain.contains("gakusei.kyoto-u.ac.jp")
                    && (cookie.name == "JSESSIONID"
                        || cookie.name == "sakai.session"
                        || cookie.name.lowercased().contains("session"))
                }
                guard hasSakaiSession else { return }

                DispatchQueue.main.async {
                    self?.hasDetected = true
                    self?.onLoginDetected()
                }
            }
        }
    }
}
