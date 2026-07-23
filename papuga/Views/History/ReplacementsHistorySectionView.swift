import Defaults
import SwiftUI

struct ReplacementsHistorySectionView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case proposed
        case replaced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "Усі"
            case .proposed: return "Підказки"
            case .replaced: return "Заміни"
            }
        }
    }

    var compactChrome = false

    @State private var store = AutoFixDecisionHistoryStore.shared
    @State private var range: HistoryTimeRange = .today
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var editorSeed: RuleEditorSeed?

    @Default(.replacementHistoryEnabled) private var historyEnabled

    init(compactChrome: Bool = false) {
        self.compactChrome = compactChrome
    }

    var body: some View {
        ActionableHistoryScreen(
            searchPlaceholder: "Слово або кандидат",
            range: $range,
            query: $query,
            clearDisabled: rangeEntries.isEmpty && rangeAggregates.isEmpty,
            clearConfirmationTitle: "Очистити журнал рішень \(range.clearScopeTitle)?",
            onClear: clearCurrentRange
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if !compactChrome {
                    screenIntroduction
                }

                if historyEnabled {
                    summaryGrid
                    filterPicker
                    decisionList
                } else {
                    disabledView
                }
            }
        }
        .sheet(item: $editorSeed) { seed in
            RuleEditorSheet(seed: seed, onClose: { editorSeed = nil })
        }
    }

    private var screenIntroduction: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Як Papuga приймала рішення")
                .font(.system(size: 22, weight: .bold))
            Text("Тут показані лише виконані заміни та підказки з доступною заміною. Очевидні перевірки рахуються анонімно без тексту й назви застосунку.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var summaryGrid: some View {
        let replaced = rangeEntries.filter { $0.outcome == .replaced || $0.outcome == .ruleApplied }.count
        let proposed = rangeEntries.filter { $0.outcome == .proposed }.count
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
            spacing: 10
        ) {
            DecisionSummaryCard(
                title: "Сигнали",
                value: "\(rangeEntries.count)",
                detail: "збережені для аналізу",
                systemImage: "waveform.path.ecg",
                tint: Color("BrandAccentDeep")
            )
            DecisionSummaryCard(
                title: "Замінено",
                value: "\(replaced)",
                detail: percentageText(replaced, of: rangeEntries.count),
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
            DecisionSummaryCard(
                title: "Підказки",
                value: "\(proposed)",
                detail: percentageText(proposed, of: rangeEntries.count),
                systemImage: "lightbulb.fill",
                tint: .orange
            )
            if anonymousCheckCount > 0 {
                Label(
                    "Ще \(anonymousCheckCount) очевидних перевірок пораховано без збереження тексту",
                    systemImage: "lock.shield"
                )
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .gridCellColumns(3)
            }
        }
    }

    private var filterPicker: some View {
        HStack(spacing: 12) {
            Picker("Рішення", selection: $filter) {
                ForEach(Filter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 540)

            Spacer()

            Text("\(visibleEntries.count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder
    private var decisionList: some View {
        if visibleEntries.isEmpty {
            emptyView
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().opacity(0.45) }
                    AutoFixDecisionRow(
                        entry: entry,
                        onCreateRule: { openRuleEditor(for: entry) },
                        onIgnore: { IgnoreWordService.add(entry.source) }
                    )
                }
            }
            .background(cardBackground)
        }
    }

    private var disabledView: some View {
        VStack(spacing: 9) {
            Image(systemName: "pause.circle")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Запис рішень вимкнено")
                .font(.system(size: 15, weight: .semibold))
            Text("Увімкніть «Зберігати журнал рішень» у Загальних налаштуваннях.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
        .background(cardBackground)
    }

    private var emptyView: some View {
        VStack(spacing: 9) {
            Image(systemName: query.isEmpty ? "function" : "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Поки немає корисних сигналів" : "Нічого не знайдено")
                .font(.system(size: 15, weight: .semibold))
            if query.isEmpty {
                Text("Очевидні перевірки та слова без заміни не засмічують цей список. Тут з'являться виконані заміни й підказки.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private var rangeEntries: [AutoFixDecisionObservation] {
        let now = Date()
        return store.entries.filter {
            $0.isDisplayableHistorySignal && range.contains($0.timestamp, now: now)
        }
    }

    private var rangeAggregates: [AutoFixDecisionAggregate] {
        let now = Date()
        return store.aggregates.filter { range.contains($0.day, now: now) }
    }

    private var anonymousCheckCount: Int {
        rangeAggregates.reduce(0) { $0 + $1.count }
    }

    private var visibleEntries: [AutoFixDecisionObservation] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rangeEntries.filter { entry in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .proposed:
                matchesFilter = entry.outcome == .proposed
            case .replaced:
                matchesFilter = entry.outcome == .replaced || entry.outcome == .ruleApplied
            }
            guard matchesFilter else { return false }
            guard !normalizedQuery.isEmpty else { return true }

            return entry.source.lowercased().contains(normalizedQuery)
                || entry.selectedCandidate?.lowercased().contains(normalizedQuery) == true
                || entry.predictionTypeTitle.lowercased().contains(normalizedQuery)
        }
    }

    private func clearCurrentRange() {
        let now = Date()
        store.clear(
            where: { range.contains($0.timestamp, now: now) },
            aggregateWhere: { range.contains($0.day, now: now) }
        )
    }

    private func openRuleEditor(for entry: AutoFixDecisionObservation) {
        guard let candidate = entry.selectedCandidate,
              HistoryWordActionPolicy.disabledReason(
                source: entry.source,
                truncated: entry.source.hasSuffix("…")
              ) == nil,
              HistoryWordActionPolicy.sanitizedTarget(
                candidate,
                truncated: candidate.hasSuffix("…")
              ) != nil else {
            return
        }
        editorSeed = RuleEditorSeed(source: entry.source, target: candidate, mode: .replace)
    }

    private func percentageText(_ value: Int, of total: Int) -> String {
        guard total > 0 else { return "0% від сигналів" }
        return "\(Int((Double(value) / Double(total) * 100).rounded()))% від сигналів"
    }

    fileprivate static func score(_ value: Double) -> String {
        String(format: "%+.2f", value)
    }
}

private struct DecisionSummaryCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
        )
    }
}

private struct AutoFixDecisionRow: View {
    private enum ConfirmedAction {
        case ignored
        case ruleCreated
    }

    let entry: AutoFixDecisionObservation
    let onCreateRule: () -> Void
    let onIgnore: () -> Void

    @Default(.autoFixAllowlist) private var allowlist
    @Default(.customAutoReplaceRules) private var customRules

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(timeText)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .leading)

            appGlyph
            replacementSummary
            predictionBadge
            scoreIndex
            actionButtons
        }
        .padding(14)
    }

    private var replacementSummary: some View {
        HStack(spacing: 7) {
            HistoryWordText(entry.source)
            if let candidate = entry.selectedCandidate {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                HistoryWordText(candidate)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    private var predictionBadge: some View {
        Text(entry.predictionTypeTitle)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(Color.secondary.opacity(0.10)))
            .fixedSize()
    }

    private var scoreIndex: some View {
        Group {
            if let confidence = entry.resolvedConfidence {
                Text("\(Int((confidence * 100).rounded()))%")
                    .foregroundStyle(entry.outcome == .proposed ? .orange : .green)
                    .help("Впевненість у виправленні")
            } else if let margin = entry.margin {
                Text("Δ \(ReplacementsHistorySectionView.score(margin))")
                    .foregroundStyle(marginColor)
            } else {
                Text("Δ —")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .monospacedDigit()
        .frame(width: 58, alignment: .trailing)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button(action: onIgnore) {
                Label(
                    "Не чіпати",
                    systemImage: confirmedAction == .ignored ? "checkmark" : "character.book.closed"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(confirmedAction != nil || !canIgnore)

            Button(action: onCreateRule) {
                Label(
                    "Створити правило",
                    systemImage: confirmedAction == .ruleCreated ? "checkmark" : "wand.and.stars"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color("BrandAccentDeep"))
            .disabled(confirmedAction != nil || !canCreateRule)
        }
        .fixedSize()
    }

    private var appGlyph: some View {
        Group {
            if let bundleID = entry.bundleID,
               let icon = AppContextProvider.icon(forBundleID: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color("BrandTintSoft"))
                    Image(systemName: "function")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color("BrandAccentDeep"))
                }
            }
        }
        .frame(width: 28, height: 28)
    }

    private var timeText: String {
        entry.timestamp.formatted(.dateTime.hour().minute().second())
    }

    private var canIgnore: Bool {
        HistoryWordActionPolicy.disabledReason(
            source: entry.source,
            truncated: entry.source.hasSuffix("…")
        ) == nil
    }

    private var canCreateRule: Bool {
        guard canIgnore,
              let candidate = entry.selectedCandidate,
              !candidate.hasSuffix("…") else { return false }
        return HistoryWordActionPolicy.sanitizedTarget(candidate) != nil
    }

    private var confirmedAction: ConfirmedAction? {
        let source = IgnoreWordService.normalizedWord(entry.source)
        if allowlist.contains(where: { $0.caseInsensitiveCompare(source) == .orderedSame }) {
            return .ignored
        }
        if customRules.contains(where: { $0.source.caseInsensitiveCompare(source) == .orderedSame }) {
            return .ruleCreated
        }
        return nil
    }

    private var marginColor: Color {
        entry.clearedReplacementThreshold ? .green : .orange
    }
}

private struct HistoryWordText: View {
    let text: String

    @State private var renderedWidth: CGFloat = 0
    @State private var naturalWidth: CGFloat = 0

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Group {
            if isTruncated {
                textLabel
                .instantTooltip(text)
            } else {
                textLabel
            }
        }
        .onPreferenceChange(RenderedTextWidthKey.self) { width in
            renderedWidth = width
        }
        .onPreferenceChange(NaturalTextWidthKey.self) { width in
            naturalWidth = width
        }
    }

    private var textLabel: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.tail)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(
                            key: RenderedTextWidthKey.self,
                            value: geometry.size.width
                        )
                }
            )
            .background(
                Text(text)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .background(
                        GeometryReader { geometry in
                            Color.clear
                                .preference(
                                    key: NaturalTextWidthKey.self,
                                    value: geometry.size.width
                                )
                        }
                    )
            )
    }

    private var isTruncated: Bool {
        naturalWidth > renderedWidth + 0.5
    }
}

private struct RenderedTextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct NaturalTextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension AutoFixDecisionObservation {
    var predictionTypeTitle: String {
        if outcome == .ruleApplied || scope == .customRule || candidateOrigin == .customRule {
            return "Правило"
        }
        if candidateOrigin == .spelling || resolvedSignalKind == .spellingSuggestion {
            return "Орфографія"
        }
        return "Розкладка"
    }
}
