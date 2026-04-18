import SwiftUI
import WebKit

/// ECS-ID/パスワードを入力する独自ログイン画面。
/// `.textContentType(.username/.password)` で iOS パスワードアプリの自動入力に対応。
struct CredentialLoginView: View {
    @EnvironmentObject private var store: AssignmentStore

    /// OTP/2FA が必要になった場合のフォールバック (WebView 表示) を要求するクロージャ。
    let onRequireWebViewLogin: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var savePassword = true
    @State private var passwordVisible = false
    @State private var isSubmitting = false
    @State private var errorText: String?
    @State private var didAutoLogin = false
    @FocusState private var focusedField: Field?

    enum Field { case username, password }

    var body: some View {
        ZStack {
            // ナビゲーション delegate コールバックを発火させるため、
            // WKWebView を常に view hierarchy 内に置く（不可視）。
            HiddenWebView()
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)

            credentialForm
        }
    }

    private var credentialForm: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 60)

                VStack(spacing: 8) {
                    Text("KULMS+")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("京都大学 学習支援システム")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 40)

                VStack(alignment: .leading, spacing: 16) {
                    // Username
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ECS-ID / SPS-ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("a0123456", text: $username)
                            .textContentType(.username)
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focusedField, equals: .username)
                            .onSubmit { focusedField = .password }
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .disabled(isSubmitting)
                    }

                    // Password
                    VStack(alignment: .leading, spacing: 4) {
                        Text("パスワード")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Group {
                                if passwordVisible {
                                    TextField("パスワード", text: $password)
                                        .textContentType(.password)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                } else {
                                    SecureField("パスワード", text: $password)
                                        .textContentType(.password)
                                }
                            }
                            .submitLabel(.go)
                            .focused($focusedField, equals: .password)
                            .onSubmit { submit() }
                            .disabled(isSubmitting)

                            Button {
                                passwordVisible.toggle()
                            } label: {
                                Image(systemName: passwordVisible ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // Save password toggle
                    Toggle(isOn: $savePassword) {
                        Text("この端末にパスワードを保存（暗号化）")
                            .font(.subheadline)
                    }
                    .disabled(isSubmitting)

                    // Error
                    if let error = errorText {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Login button
                    Button {
                        submit()
                    } label: {
                        if isSubmitting {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                                Text("ログイン中...")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("ログイン")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isSubmitting || username.isEmpty || password.isEmpty)
                    .padding(.top, 8)
                }

                Divider().padding(.vertical, 24)

                VStack(spacing: 4) {
                    Button {
                        onRequireWebViewLogin()
                    } label: {
                        Text("Web ブラウザでログイン")
                    }
                    .disabled(isSubmitting)

                    Text("（パスキー / 多要素認証を使う場合）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .task {
            tryAutoLogin()
        }
        .onChange(of: store.isLoggedIn) { _, newValue in
            // セッション切れで戻ってきた → 自動再ログインを試行
            if newValue == false {
                didAutoLogin = false
                tryAutoLogin()
            }
        }
    }

    private func submit() {
        guard !isSubmitting, !username.isEmpty, !password.isEmpty else { return }
        focusedField = nil
        Task { await performLogin(saveOnSuccess: savePassword) }
    }

    private func tryAutoLogin() {
        guard !didAutoLogin else { return }
        didAutoLogin = true
        if let creds = CredentialStore.load() {
            username = creds.username
            password = creds.password
            Task { await performLogin(saveOnSuccess: true) }
        }
    }

    @MainActor
    private func performLogin(saveOnSuccess: Bool) async {
        isSubmitting = true
        errorText = nil

        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await WebViewFetcher.shared.loginWithCredentials(
            username: trimmedUser,
            password: password
        )

        switch result {
        case .success:
            if saveOnSuccess {
                CredentialStore.save(username: trimmedUser, password: password)
            }
            store.isLoggedIn = true
            await store.fetchAll(forceRefresh: true)
            isSubmitting = false
        case .otpRequired:
            // 認証情報自体は通った
            if saveOnSuccess {
                CredentialStore.save(username: trimmedUser, password: password)
            }
            isSubmitting = false
            onRequireWebViewLogin()
        case .failed(let msg):
            errorText = msg
            isSubmitting = false
        }
    }
}

// MARK: - Hidden WKWebView wrapper

/// WKNavigationDelegate コールバックを発火させるため、
/// 共有 WKWebView を view hierarchy 内に保持する（不可視）。
private struct HiddenWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        WebViewFetcher.shared.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

