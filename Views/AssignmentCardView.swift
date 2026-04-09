import SwiftUI

struct AssignmentCardView: View {
    @EnvironmentObject private var store: AssignmentStore
    let assignment: Assignment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Checkbox
            Button {
                store.toggleChecked(assignment)
            } label: {
                Image(systemName: assignment.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(assignment.isChecked ? .green : .secondary)
            }
            .buttonStyle(.plain)

            // Card body
            VStack(alignment: .leading, spacing: 6) {
                // Course name pill
                Text(assignment.courseName)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(urgencyColor.opacity(0.15))
                    .foregroundStyle(urgencyColor)
                    .clipShape(Capsule())

                // Title (tappable link)
                if let url = URL(string: assignment.url) {
                    Link(assignment.title, destination: url)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(assignment.isChecked ? .secondary : .primary)
                        .strikethrough(assignment.isChecked)
                } else {
                    Text(assignment.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(assignment.isChecked ? .secondary : .primary)
                        .strikethrough(assignment.isChecked)
                }

                // Meta: deadline + remaining
                HStack(spacing: 8) {
                    Label(assignment.deadlineText, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !assignment.remainingText.isEmpty {
                        Text(assignment.remainingText)
                            .font(.caption.bold())
                            .foregroundStyle(remainingColor)
                    }
                }

                // Status badge
                if assignment.isSubmitted {
                    Text(statusLabel)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.12))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .opacity(assignment.isChecked ? 0.6 : 1)
    }

    // MARK: - Helpers

    private var urgencyColor: Color {
        Color(hex: assignment.urgency.colorHex)
    }

    private var remainingColor: Color {
        switch assignment.urgency {
        case .overdue, .danger: return Color(hex: "#e85555")
        case .warning: return Color(hex: "#d7aa57")
        case .success: return Color(hex: "#62b665")
        case .other: return .secondary
        }
    }

    private var statusLabel: String {
        let s = assignment.status.lowercased()
        if s.contains("評定済") || s.contains("graded") { return "評定済" }
        if s.contains("提出済") || s.contains("submitted") { return "提出済" }
        return assignment.status
    }
}
