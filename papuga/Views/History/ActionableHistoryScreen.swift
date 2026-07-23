import SwiftUI

struct ActionableHistoryScreen<Content: View>: View {
    let searchPlaceholder: String
    @Binding var range: HistoryTimeRange
    @Binding var query: String
    let clearDisabled: Bool
    let clearConfirmationTitle: String
    let onClear: () -> Void
    let content: () -> Content

    @State private var showingClearConfirmation = false

    init(
        searchPlaceholder: String = "Пошук",
        range: Binding<HistoryTimeRange>,
        query: Binding<String>,
        clearDisabled: Bool,
        clearConfirmationTitle: String,
        onClear: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.searchPlaceholder = searchPlaceholder
        _range = range
        _query = query
        self.clearDisabled = clearDisabled
        self.clearConfirmationTitle = clearConfirmationTitle
        self.onClear = onClear
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content()
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Spacer(minLength: 0)

            Picker("", selection: $range) {
                ForEach(HistoryTimeRange.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            searchField

            Button(role: .destructive) {
                showingClearConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Очистити \(range.clearScopeTitle)")
            .accessibilityLabel("Очистити")
            .disabled(clearDisabled)
            .confirmationDialog(
                clearConfirmationTitle,
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Очистити", role: .destructive, action: onClear)
                Button("Скасувати", role: .cancel) {}
            } message: {
                Text("Цю дію не можна скасувати.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(searchPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .frame(width: 140)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

struct ActionableSuggestionItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let source: String
    let target: String?
    let countText: String?
    let candidates: [MistakeSuggestionCandidate]
    let canAct: Bool
    let disabledReason: String?
    let ruleDisabledReason: String?
    let onCreateRule: (String?) -> Void
    let onIgnore: () -> Void
}

struct ActionableSuggestionsSection: View {
    let items: [ActionableSuggestionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
                Text("Поради")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text("Поки що немає повторюваних патернів для правила або списку «не чіпати».")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider().opacity(0.45)
                        }
                        ActionableSuggestionCard(item: item)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color("BrandAccentDeep").opacity(items.isEmpty ? 0.1 : 0.22), lineWidth: 1)
                )
        )
    }
}

private struct ActionableSuggestionCard: View {
    let item: ActionableSuggestionItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            iconTile

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                    if let countText = item.countText {
                        Text(countText)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color("BrandAccentDeep"))
                            .monospacedDigit()
                    }
                }

                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ReplacementReceipt(
                    source: item.source,
                    target: item.target ?? "ввести заміну",
                    strikethroughSource: item.target != nil
                )

                HistoryCandidateStrip(candidates: item.candidates) { candidate in
                    guard candidate.canCreateCoreRule else { return }
                    item.onCreateRule(candidate.text)
                }
            }

            Spacer(minLength: 12)

            HistoryRowActions(
                canAct: item.canAct,
                disabledReason: item.disabledReason,
                ruleDisabledReason: item.ruleDisabledReason,
                onCreateRule: { item.onCreateRule(item.target) },
                onIgnore: item.onIgnore
            )
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color("BrandTintSoft"))
            Image(systemName: item.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color("BrandAccentDeep"))
        }
        .frame(width: 32, height: 32)
    }
}

struct HistoryCandidateStrip: View {
    let candidates: [MistakeSuggestionCandidate]
    let onSelect: (MistakeSuggestionCandidate) -> Void

    var body: some View {
        if !candidates.isEmpty {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                Text("Схоже на")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)

                ForEach(candidates) { candidate in
                    Button {
                        onSelect(candidate)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: candidate.kind.systemImage)
                                .font(.system(size: 10, weight: .semibold))
                            Text(candidate.replacementPlan?.renderedReplacement ?? candidate.text)
                                .lineLimit(1)
                            Text(candidate.kind.title)
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!candidate.canCreateCoreRule)
                    .help(candidate.canCreateCoreRule
                        ? "Створити правило для «\(candidate.replacementPlan?.renderedReplacement ?? candidate.text)»"
                        : HistoryWordActionPolicy.fullTokenLayoutRuleReason)
                }
            }
        }
    }
}

struct HistoryRowActions: View {
    let canAct: Bool
    let disabledReason: String?
    let ruleDisabledReason: String?
    let onCreateRule: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onIgnore) {
                Label("Зберегти в словник", systemImage: "character.book.closed")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canAct)
            .help(disabledReason ?? "Зберегти слово у словник (Papuga не чіпатиме його)")

            Button(action: onCreateRule) {
                Label("Створити правило заміни", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color("BrandAccentDeep"))
            .disabled(!canAct || ruleDisabledReason != nil)
            .help(ruleDisabledReason ?? disabledReason ?? "Відкрити модалку створення правила заміни")
        }
    }
}

enum HistoryWordActionPolicy {
    static let fullTokenLayoutRuleReason =
        "Ця розкладкова заміна використовує крайній знак як літеру, тому її не можна зберегти як правило слова."
    static let unverifiedEdgeRuleReason =
        "Дочекайтеся аналізу розкладки: Papuga ще не може безпечно визначити, чи крайній знак є пунктуацією."

    static func ruleDisabledReason(for candidate: MistakeSuggestionCandidate?) -> String? {
        guard let candidate, !candidate.canCreateCoreRule else { return nil }
        return fullTokenLayoutRuleReason
    }

    static func normalizedSource(_ text: String) -> String {
        BufferedToken.normalizedCore(from: text)
    }

    static func canUseSource(_ text: String, truncated: Bool) -> Bool {
        disabledReason(source: text, truncated: truncated) == nil
    }

    static func disabledReason(source: String, truncated: Bool) -> String? {
        let source = normalizedSource(source)
        if truncated {
            return "Обрізаний запис не можна безпечно перетворити на правило."
        }
        if source.count < 2 {
            return "Потрібне слово з двох або більше символів."
        }
        if source.contains(where: \.isWhitespace) {
            return "Правила і «не чіпати» зараз працюють тільки з одним словом."
        }
        return nil
    }

    static func sanitizedTarget(_ text: String?, truncated: Bool = false) -> String? {
        guard !truncated, let text else { return nil }
        let target = BufferedToken.normalizedCore(from: text)
        guard !target.isEmpty, !target.contains(where: \.isWhitespace) else { return nil }
        return target
    }
}
