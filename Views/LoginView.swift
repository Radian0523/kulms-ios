import SwiftUI
import WebKit

/// ログイン画面のルート。
/// デフォルトでは独自 UI（CredentialLoginView）を表示。
/// 多要素認証が必要な場合や、ユーザーが明示的に選択した場合は WebView ログイン UI に切り替える。
struct LoginView: View {
    @EnvironmentObject private var store: AssignmentStore
    @State private var useWebView = false

    var body: some View {
        Group {
            if useWebView {
                WebViewLoginPanel(onBack: { useWebView = false })
            } else {
                CredentialLoginView(onRequireWebViewLogin: { useWebView = true })
            }
        }
        .onChange(of: store.isLoggedIn) { _, newValue in
            // セッション切れで再ログインに戻る場合は、credential 入力画面に戻す
            if newValue == false {
                useWebView = false
            }
        }
    }
}

// MARK: - WebView fallback (for 2FA / passkey)

/// 従来の WebView ベースのログイン UI（多要素認証用フォールバック）。
struct WebViewLoginPanel: View {
    @EnvironmentObject private var store: AssignmentStore
    @State private var isVerifying = false
    @State private var errorText: String?

    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SSOWebView()

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
                            Text(String(localized: "verifying"))
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text(String(localized: "loginDone"))
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isVerifying)

                Text(String(localized: "tapAfterAuth"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button(String(localized: "backToCredentials"), action: onBack)
                    .font(.caption)
                    .disabled(isVerifying)
            }
            .padding()
            .background(.bar)
        }
    }

    private func handleLogin() {
        guard !isVerifying else { return }
        isVerifying = true
        errorText = nil

        Task {
            let wv = WebViewFetcher.shared.webView

            do {
                let result = try await wv.callAsyncJavaScript(
                    "const r = await fetch('/direct/site.json?_limit=1', {credentials:'include', cache:'no-store'}); return await r.text();",
                    contentWorld: .page
                )
                let text = result as? String ?? ""
                print("[KULMS] login: fetch result (\(text.count) chars)")

                if text.contains("site_collection") && text.count > 60 {
                    store.isLoggedIn = true
                    await store.fetchAll(forceRefresh: true)
                } else {
                    errorText = String(localized: "sessionNotConfirmed")
                }
            } catch {
                print("[KULMS] login: fetch error: \(error)")
                errorText = String(format: String(localized: "verificationFailed"), error.localizedDescription)
            }
            isVerifying = false
        }
    }
}

// MARK: - WKWebView Wrapper

struct SSOWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let wv = WebViewFetcher.shared.webView
        wv.allowsBackForwardNavigationGestures = true

        // 既に IIMC 認証画面に遷移している可能性が高いので、その状態を保つ。
        // セッション切れで初回表示の場合のみ portal をロードする。
        if wv.url == nil {
            let url = URL(string: "https://lms.gakusei.kyoto-u.ac.jp/portal")!
            wv.load(URLRequest(url: url))
        }

        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
