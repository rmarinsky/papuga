import SwiftUI

/// Neutral "this is what was typed" pill — monospaced, grey. Shared by the
/// Dictionary rules and the History redesign so every source word reads the same.
struct SourcePill: View {
    let text: String
    var strikethrough: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, design: .monospaced))
            .strikethrough(strikethrough, color: Color("BrandAccentDeep").opacity(0.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary)
            )
    }
}

/// Green "this is what Papuga produced" pill — the corrected/target word.
struct TargetPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color("BrandAccentDeep"))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color("BrandTintSoft"))
            )
    }
}

/// `source → target` receipt motif shared by Dictionary rule rows and History.
struct ReplacementReceipt: View {
    let source: String
    let target: String
    var strikethroughSource: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            SourcePill(text: source, strikethrough: strikethroughSource)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color("BrandAccentDeep"))
            TargetPill(text: target)
        }
    }
}
