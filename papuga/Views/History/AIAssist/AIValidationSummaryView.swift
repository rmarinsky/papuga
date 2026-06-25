import SwiftUI

/// Shows the outcome of validating a pasted AI answer: a counter strip plus a per-issue
/// list with a severity-coloured left edge (AI-ASSIST.md §5 — the "де не співпадає" view).
/// Every message comes from the validator and is rendered as inert, verbatim text — the
/// pasted answer is untrusted and is never interpreted as markdown.
struct AIValidationSummaryView: View {
    let result: AIValidationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let blocked = result.blocked {
                issueRow(message: blocked.message, severity: .block)
            } else {
                counters
                if !result.issues.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                            issueRow(message: issue.message, severity: issue.severity)
                        }
                    }
                }
            }
        }
    }

    private var counters: some View {
        HStack(spacing: 8) {
            counterChip("\(result.recognizedCount) розпізнано", systemImage: "checkmark.circle.fill", color: Color("BrandAccentDeep"))
            if result.attentionCount > 0 {
                counterChip("\(result.attentionCount) потребують уваги", systemImage: "exclamationmark.triangle.fill", color: .orange)
            }
            if result.skippedCount > 0 {
                counterChip("\(result.skippedCount) пропущено", systemImage: "minus.circle", color: .secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func counterChip(_ title: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        )
    }

    private func issueRow(message: String, severity: AIValidationSeverity) -> some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color(for: severity))
                .frame(width: 3)
            Text(verbatim: message)
                .font(.system(size: 12))
                .foregroundStyle(severity == .info ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 10)
                .padding(.vertical, 6)
            Spacer(minLength: 0)
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color(for: severity).opacity(0.07))
        )
    }

    private func color(for severity: AIValidationSeverity) -> Color {
        switch severity {
        case .block: return .red
        case .warn: return .orange
        case .info: return .secondary
        }
    }
}
