import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var store: AssignmentStore
    @Environment(\.dismiss) private var dismiss
    @State private var notificationsEnabled = false
    @State private var showLogoutConfirm = false
    @State private var notificationOffsets: [Int] = NotificationService.loadNotificationOffsets()
    @State private var showOffsetPicker = false

    private static let presetOffsets: [(labelKey: String, minutes: Int)] = [
        ("offset10m", 10),
        ("offset30m", 30),
        ("offset1h", 60),
        ("offset3h", 180),
        ("offset5h", 300),
        ("offset12h", 720),
        ("offset24h", 1440),
        ("offset2d", 2880),
        ("offset3d", 4320),
    ]

    var body: some View {
        NavigationStack {
            List {
                // Notifications
                Section(String(localized: "sectionNotifications")) {
                    Toggle(String(localized: "deadlineRemind"), isOn: $notificationsEnabled)
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
                        notificationTimingSection
                    }
                }

                // Info
                Section(String(localized: "sectionInfo")) {
                    if let last = store.lastRefreshed {
                        LabeledContent(String(localized: "lastUpdated")) {
                            Text(last, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent(String(localized: "assignmentCount")) {
                        Text("\(store.assignments.count)")
                            .foregroundStyle(.secondary)
                    }
                }

                // Feedback & Support
                Section {
                    Link(destination: URL(string: "https://docs.google.com/forms/d/e/1FAIpQLSdmc4tCHa98mzt1j4Wxu9IJo88wKz3-VQHVYAQjbtJ3Jo_CPw/viewform")!) {
                        Label(String(localized: "sendFeedback"), systemImage: "envelope")
                    }
                    Link(destination: URL(string: "https://radian0523.github.io/kulms-extension/")!) {
                        Label(String(localized: "homepage"), systemImage: "globe")
                    }
                }

                // Logout
                Section {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            Text(String(localized: "logout"))
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "close")) { dismiss() }
                }
            }
            .confirmationDialog(String(localized: "logoutConfirm"), isPresented: $showLogoutConfirm) {
                Button(String(localized: "logout"), role: .destructive) {
                    performLogout()
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "logoutConfirmBody"))
            }
            .task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                notificationsEnabled = settings.authorizationStatus == .authorized
            }
        }
    }

    // MARK: - Notification Timing Section

    private var notificationTimingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "notificationTiming"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(notificationOffsets.sorted(by: >), id: \.self) { offset in
                    offsetChip(offset)
                }
                if notificationOffsets.count < 5 {
                    Button {
                        showOffsetPicker = true
                    } label: {
                        Label(String(localized: "add"), systemImage: "plus")
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .confirmationDialog(String(localized: "addTiming"), isPresented: $showOffsetPicker) {
            ForEach(availablePresets, id: \.minutes) { preset in
                Button(String(localized: String.LocalizationValue(preset.labelKey))) {
                    addOffset(preset.minutes)
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
    }

    private func offsetChip(_ minutes: Int) -> some View {
        let label = NotificationService.formatOffsetChipLabel(minutes)
        let canDelete = notificationOffsets.count > 1
        return HStack(spacing: 4) {
            Text(label)
                .font(.subheadline)
            if canDelete {
                Button {
                    removeOffset(minutes)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(Capsule())
    }

    private var availablePresets: [(labelKey: String, minutes: Int)] {
        Self.presetOffsets.filter { !notificationOffsets.contains($0.minutes) }
    }

    private func addOffset(_ minutes: Int) {
        guard !notificationOffsets.contains(minutes), notificationOffsets.count < 5 else { return }
        notificationOffsets.append(minutes)
        saveAndReschedule()
    }

    private func removeOffset(_ minutes: Int) {
        guard notificationOffsets.count > 1 else { return }
        notificationOffsets.removeAll { $0 == minutes }
        saveAndReschedule()
    }

    private func saveAndReschedule() {
        NotificationService.saveNotificationOffsets(notificationOffsets)
        notificationOffsets = NotificationService.loadNotificationOffsets()
        Task {
            await NotificationService.shared.scheduleNotifications(for: store.assignments)
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

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight
            if i < rows.count - 1 { height += spacing }
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}
