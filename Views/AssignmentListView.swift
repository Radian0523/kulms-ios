import SwiftUI
import WebKit

struct AssignmentListView: View {
    @EnvironmentObject private var store: AssignmentStore
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Sakai API 呼び出し（JS 実行 / 認証 cookie）のため、
                // WKWebView を常に view hierarchy 内に保持する（不可視）。
                HiddenWebView()
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)

                if store.isLoading && store.assignments.isEmpty {
                    loadingView
                } else if let error = store.errorMessage, store.assignments.isEmpty {
                    errorView(error)
                } else {
                    listContent
                }
            }
            .navigationTitle(String(localized: "assignmentList"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("KULMS")
                        .font(.headline.bold())
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await store.fetchAll(forceRefresh: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(store.isLoading)

                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .task {
                store.loadCached()
            }
        }
    }

    // MARK: - List Content

    private var listContent: some View {
        List {
            if !store.lastRefreshedText.isEmpty || store.isLoading {
                Section {
                    HStack {
                        Text(store.lastRefreshedText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if store.isLoading {
                            ProgressView()
                                .controlSize(.small)
                            if let p = store.progress {
                                Text("\(p.completed)/\(p.total)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            let sections = store.groupedAssignments
            if sections.isEmpty && !store.isLoading {
                Section {
                    VStack(spacing: 12) {
                        Text(String(localized: "noAssignments"))
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await store.fetchAll(forceRefresh: true) }
                        } label: {
                            Label(String(localized: "refetch"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
                }
            }

            ForEach(sections) { section in
                let isCollapsed = store.collapsedSections.contains(section.id)
                Section {
                    if !isCollapsed {
                        ForEach(section.assignments, id: \.compositeKey) { assignment in
                            AssignmentCardView(
                                assignment: assignment,
                                isResubmitActive: section.id != "completed" && assignment.isSubmitted
                            )
                        }
                    }
                } header: {
                    Button {
                        withAnimation {
                            store.toggleSection(section.id)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: section.colorHex))
                                .frame(width: 8, height: 8)
                            Text(section.label)
                            Text("(\(section.assignments.count))")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await store.fetchAll(forceRefresh: true)
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            if let p = store.progress {
                Text(String(format: String(localized: "loadingAssignments"), p.completed, p.total))
                    .foregroundStyle(.secondary)
            } else {
                Text(String(localized: "loadingCourses"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "retry")) {
                Task { await store.fetchAll(forceRefresh: true) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - Hidden WKWebView wrapper

/// 共有 WKWebView を view hierarchy 内に保持する（不可視）。
/// ログイン後の Sakai API 呼び出し（JS fetch）を確実に動作させるため。
private struct HiddenWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        WebViewFetcher.shared.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
