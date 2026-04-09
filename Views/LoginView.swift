import SwiftUI
import WebKit

struct LoginView: View {
    @EnvironmentObject private var store: AssignmentStore
    @State private var isVerifying = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("KULMS")
                    .font(.headline.bold())
                Spacer()
                if isVerifying {
                    ProgressView()
                        .controlSize(.small)
                    Text("認証確認中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.bar)

            SSOWebView(onLoginDetected: handleLogin)
        }
    }

    private func handleLogin() {
        guard !isVerifying else { return }
        isVerifying = true

        Task {
            // Transfer WKWebView cookies to URLSession
            let wkStore = WKWebsiteDataStore.default().httpCookieStore
            let cookies = await wkStore.allCookies()
            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }

            // Verify session
            do {
                let valid = try await SakaiAPIClient.shared.checkSession()
                await MainActor.run {
                    if valid {
                        store.isLoggedIn = true
                    }
                    isVerifying = false
                }
            } catch {
                await MainActor.run {
                    isVerifying = false
                }
            }
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
                  url.host == "lms.gakusei.kyoto-u.ac.jp",
                  url.path.hasPrefix("/portal") else { return }

            // Check if we're on the portal (not the login redirect)
            // SSO sends the user through IdP, then back to lms.gakusei.kyoto-u.ac.jp
            webView.evaluateJavaScript(
                "document.querySelector('#loginLink1') === null"
            ) { [weak self] result, _ in
                if let loggedIn = result as? Bool, loggedIn {
                    self?.hasDetected = true
                    self?.onLoginDetected()
                }
            }
        }
    }
}
