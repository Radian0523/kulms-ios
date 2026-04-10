import SwiftUI
import WebKit

struct LoginView: View {
    @EnvironmentObject private var store: AssignmentStore
    @State private var isVerifying = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            SSOWebView()

            // Bottom bar with login button
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
            .background(.bar)
        }
        .onChange(of: store.isLoggedIn) { _, newValue in
            if !newValue {
                // Session expired — reload portal to trigger SSO redirect
                let url = URL(string: "https://lms.gakusei.kyoto-u.ac.jp/portal")!
                WebViewFetcher.shared.webView.load(URLRequest(url: url))
            }
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
                    // Auto-fetch assignments after login
                    await store.fetchAll(forceRefresh: true)
                } else {
                    errorText = "セッションが確認できません。ログインしてから再度タップしてください。"
                }
            } catch {
                print("[KULMS] login: fetch error: \(error)")
                errorText = "確認に失敗しました: \(error.localizedDescription)"
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

        let url = URL(string: "https://lms.gakusei.kyoto-u.ac.jp/portal")!
        wv.load(URLRequest(url: url))

        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
