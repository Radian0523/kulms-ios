import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var store: AssignmentStore
    @Environment(\.dismiss) private var dismiss
    @State private var notificationsEnabled = false
    @State private var showLogoutConfirm = false

    var body: some View {
        NavigationStack {
            List {
                // Notifications
                Section("通知") {
                    Toggle("締切リマインド", isOn: $notificationsEnabled)
                        .onChange(of: notificationsEnabled) { _, newValue in
                            if newValue {
                                Task {
                                    let granted = await NotificationService.shared.requestPermission()
                                    if !granted {
                                        notificationsEnabled = false
                                    }
                                }
                            }
                        }
                    if notificationsEnabled {
                        Text("締切24時間前と1時間前に通知します")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Info
                Section("情報") {
                    if let last = store.lastRefreshed {
                        LabeledContent("最終更新") {
                            Text(last, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("課題数") {
                        Text("\(store.assignments.count)")
                            .foregroundStyle(.secondary)
                    }
                }

                // Feedback
                Section {
                    Link(destination: URL(string: "https://docs.google.com/forms/d/e/1FAIpQLSdFa9VASkP0ea8uHK9GEPS3r3VnoOcIpKO0dsIeCACElvCH-Q/viewform")!) {
                        Label("ご意見・要望を送る", systemImage: "envelope")
                    }
                }

                // Logout
                Section {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("ログアウト")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .confirmationDialog("ログアウトしますか？", isPresented: $showLogoutConfirm) {
                Button("ログアウト", role: .destructive) {
                    performLogout()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("セッションとキャッシュが削除されます")
            }
            .task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                notificationsEnabled = settings.authorizationStatus == .authorized
            }
        }
    }

    private func performLogout() {
        // Clear WKWebView data
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: types) { records in
            dataStore.removeData(ofTypes: types, for: records) {}
        }

        store.logout()
        dismiss()
    }
}
