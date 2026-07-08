import SwiftUI

/// Summary-first review (AI-ASSIST.md §6/§7, simplified UX). The user reads as little as
/// possible: confirmed rules + dictionary collapse into one "безпечні" card (pre-selected,
/// one tap applies); uncorroborated rules sit in "на перевірку"; the AI's unsure pile is
/// "не впевнені". EVERY row is editable — the user can change the action (Заміна / У словник /
/// Прибрати) and edit the replacement word. The parent owns the editable state and applies;
/// this view never writes anything.
struct AISuggestionReviewView: View {
    let recognized: [AISuggestion]
    let items: [String: AIPromptItem]
    let issues: [AIValidationIssue]
    @Binding var selected: Set<String>
    @Binding var editedAction: [String: AISuggestionAction]
    @Binding var editedTarget: [String: String]

    @State private var showSafe = false
    @State private var showUncertain = false
    @State private var showIssues = false

    private func isRuleProposal(_ s: AISuggestion) -> Bool {
        guard s.action == .rule || s.action == .merge else { return false }
        guard let target = s.target else { return false }
        return !target.isEmpty
    }

    // Buckets are by the AI's ORIGINAL proposal, so the summary stays stable while the user edits.
    private var safe: [AISuggestion] {
        recognized.filter { s in
            if s.action == .dictionary { return true }
            return isRuleProposal(s) && !s.needsReview
        }
    }
    private var attention: [AISuggestion] { recognized.filter { isRuleProposal($0) && $0.needsReview } }
    private var uncertain: [AISuggestion] { recognized.filter { $0.action == .ignore } }
    private var dictionaryCount: Int { recognized.filter { $0.action == .dictionary }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ШІ розібрав \(recognized.count) \(pluralWords(recognized.count))")
                .font(.system(size: 15, weight: .semibold))

            if !safe.isEmpty { safeCard }
            if !attention.isEmpty { attentionSection }
            if !uncertain.isEmpty { uncertainSection }
            if !issues.isEmpty { issuesDisclosure }
        }
    }

    // MARK: безпечні (collapsed count, pre-selected, editable when expanded)

    private var safeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color("BrandAccentDeep"))
                Text("\(safe.count) безпечні").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(showSafe ? "сховати" : "переглянути / редагувати") { withAnimation { showSafe.toggle() } }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Перевірені заміни й розкладкові фліпи — застосуються кнопкою внизу.")
                .font(.caption).foregroundStyle(.secondary)
            if dictionaryCount > 0 {
                Text("Зокрема \(dictionaryCount) у словник — лишається в системному словнику.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showSafe { rowList(safe, showReason: false) }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color("BrandTintSoft").opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color("BrandAccentDeep").opacity(0.22), lineWidth: 1))
        )
    }

    // MARK: на перевірку (always expanded — the only thing you must read)

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                Text("\(attention.count) на перевірку").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Text("Заміну не підтверджено автоматично — глянь, виправ за потреби й познач.")
                .font(.caption).foregroundStyle(.secondary)
            rowList(attention, showReason: true)
        }
    }

    // MARK: не впевнені (collapsed; ШІ не знає — шум чи рідкісне слово)

    private var uncertainSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("🤔")
                Text("\(uncertain.count) не впевнені").font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: showUncertain ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { showUncertain.toggle() } }
            if showUncertain {
                Text("ШІ не певний — шум це чи справжнє рідкісне слово. Обери дію для тих, що впізнав; решту лиши як «Прибрати».")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                rowList(uncertain, showReason: true)
            }
        }
    }

    private var issuesDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(issues.count) зауважень щодо формату").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: showIssues ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { showIssues.toggle() } }
            if showIssues {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Text(verbatim: issue.message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: editable rows

    @ViewBuilder
    private func rowList(_ list: [AISuggestion], showReason: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, suggestion in
                if index > 0 { Divider().opacity(0.4) }
                editableRow(suggestion, showReason: showReason)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }

    private func editableRow(_ suggestion: AISuggestion, showReason: Bool) -> some View {
        let source = items[suggestion.id]?.source ?? suggestion.id
        let action = currentAction(suggestion)
        let isRule = (action == .rule || action == .merge)
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    SourcePill(text: source, strikethrough: isRule)
                    if isRule {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(Color("BrandAccentDeep"))
                        TextField("заміна", text: targetBinding(suggestion.id))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(maxWidth: 130)
                    }
                }
                if showReason, !suggestion.reason.isEmpty {
                    Text(verbatim: suggestion.reason)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            actionMenu(suggestion, current: action)
            Toggle("", isOn: includeBinding(suggestion.id)).labelsHidden().toggleStyle(.checkbox)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(suggestion.reason)
    }

    private func actionMenu(_ suggestion: AISuggestion, current: AISuggestionAction) -> some View {
        Menu {
            Button { setAction(suggestion.id, .rule) } label: { Label("Заміна", systemImage: "wand.and.stars") }
            Button { setAction(suggestion.id, .dictionary) } label: { Label("У словник", systemImage: "character.book.closed") }
            Button { setAction(suggestion.id, .ignore) } label: { Label("Прибрати", systemImage: "eye.slash") }
        } label: {
            HStack(spacing: 3) {
                Text(actionTitle(current)).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(.quaternary))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: state helpers

    private func currentAction(_ s: AISuggestion) -> AISuggestionAction { editedAction[s.id] ?? s.action }

    private func actionTitle(_ a: AISuggestionAction) -> String {
        switch a {
        case .rule, .merge: return "Заміна"
        case .dictionary: return "У словник"
        case .ignore: return "Прибрати"
        }
    }

    private func setAction(_ id: String, _ action: AISuggestionAction) {
        editedAction[id] = action
        selected.insert(id) // choosing an action means "do this"
    }

    private func targetBinding(_ id: String) -> Binding<String> {
        Binding(get: { editedTarget[id] ?? "" }, set: { editedTarget[id] = $0 })
    }

    private func includeBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in if isOn { selected.insert(id) } else { selected.remove(id) } }
        )
    }

    private func pluralWords(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "слово" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "слова" }
        return "слів"
    }
}
