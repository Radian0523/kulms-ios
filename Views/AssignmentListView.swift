import SwiftUI

struct AssignmentListView: View {
    @EnvironmentObject private var store: AssignmentStore
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                if store.isLoading && store.assignments.isEmpty {
                    loadingView
                } else if let error = store.errorMessage, store.assignments.isEmpty {
                    errorView(error)
                } else {
                    listContent
                }
            }
            .navigationTitle("課題一覧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("KULMS")
                        .font(.headline.bold())
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .task {
                await store.fetchAll()
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
                    Text("課題が見つかりませんでした")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                }
            }

            ForEach(sections) { section in
                Section {
                    ForEach(section.assignments, id: \.compositeKey) { assignment in
                        AssignmentCardView(assignment: assignment)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(hex: section.colorHex))
                            .frame(width: 8, height: 8)
                        Text(section.label)
                        Text("(\(section.assignments.count))")
                            .foregroundStyle(.secondary)
                    }
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
                Text("課題を取得中... (\(p.completed)/\(p.total))")
                    .foregroundStyle(.secondary)
            } else {
                Text("コース情報を取得中...")
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
            Button("再試行") {
                Task { await store.fetchAll(forceRefresh: true) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
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
