import Defaults
import SwiftUI

struct ReplacementsHistorySectionView: View {
    var compactChrome = false

    @Environment(LayoutManager.self) private var layoutManager

    @State private var analyzer = MistakeSuggestionAnalyzer()
    @State private var store = ReplacementHistoryStore.shared
    @State private var range: HistoryTimeRange = .today
    @State private var query = ""
    @State private var editorSeed: RuleEditorSeed?

    @Default(.replacementHistoryEnabled) private var historyEnabled

    init(compactChrome: Bool = false) {
        self.compactChrome = compactChrome
    }

    var body: some View {
        ActionableHistoryScreen(
            range: $range,
            query: $query,
            clearDisabled: rangeEntries.isEmpty,
            clearConfirmationTitle: "Очистити історію замін \(range.clearScopeTitle)?",
            onClear: clearCurrentRange
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if historyEnabled {
                    ActionableSuggestionsSection(items: suggestionItems)
                    content
                } else {
                    disabledView
                }
            }
        }
        .sheet(item: $editorSeed) { seed in
            RuleEditorSheet(seed: seed) { editorSeed = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        if visibleEntries.isEmpty {
            emptyView
        } else {
            VStack(spacing: 0) {
                ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider().opacity(0.45)
                    }
                    ReplacementActionRow(
                        entry: entry,
                        candidates: candidates(for: entry),
                        onCreateRule: { target in openRuleEditor(for: entry, target: target) },
                        onIgnore: { ignore(entry) }
                    )
                }
            }
            .background(historyCardBackground)
        }
    }

    private var disabledView: some View {
        VStack(spacing: 8) {
            Image(systemName: "pause.circle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Запис історії вимкнено")
                .font(.headline)
            Text("Увімкніть «Зберігати історію замін» у вкладці «Загальні», щоб тут з'являлися записи.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Поки немає записів" : "Нічого не знайдено")
                .font(.headline)
            if query.isEmpty {
                Text("Зроби перше перемикання або зачекай, поки спрацює автозаміна.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
        .background(historyCardBackground)
    }

    private var historyCardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    // MARK: - Derived Data

    private var rangeEntries: [ReplacementHistoryEntry] {
        let now = Date()
        return store.entries.filter { entry in
            range.contains(entry.timestamp, now: now)
        }
    }

    private var visibleEntries: [ReplacementHistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return rangeEntries }
        return rangeEntries.filter { entry in
            let inText = entry.original.lowercased().contains(q) || entry.converted.lowercased().contains(q)
            let inApp = entry.bundleID.map { AppContextProvider.displayName(forBundleID: $0).lowercased().contains(q) } ?? false
            return inText || inApp || entry.kind.displayName.lowercased().contains(q)
        }
    }

    private var suggestionItems: [ActionableSuggestionItem] {
        Array(
            aggregateReplacementSuggestions(rangeEntries)
                .filter { $0.count >= 2 }
                .prefix(5)
                .map { suggestion in
                    let disabledReason = HistoryWordActionPolicy.disabledReason(
                        source: suggestion.source,
                        truncated: suggestion.sourceTruncated
                    )
                    let target = ruleTarget(source: suggestion.source, target: suggestion.target)
                    let candidateList = candidates(
                        source: suggestion.source,
                        target: target,
                        sourceLayoutID: suggestion.sourceLayoutID,
                        rawSources: [suggestion.source] + suggestion.rawSources.filter {
                            $0 != suggestion.source
                        }
                    )
                    let targetCandidate = target.flatMap { target in
                        candidateList.first {
                            MistakeObservation.normalizedToken($0.text)
                                == MistakeObservation.normalizedToken(target)
                        }
                    }
                    return ActionableSuggestionItem(
                        id: suggestion.id,
                        icon: suggestion.kind.icon,
                        title: suggestion.kind.title,
                        subtitle: suggestion.subtitle,
                        source: suggestion.source,
                        target: target,
                        countText: "\(suggestion.count)×",
                        candidates: candidateList,
                        canAct: disabledReason == nil,
                        disabledReason: disabledReason,
                        ruleDisabledReason: HistoryWordActionPolicy.ruleDisabledReason(for: targetCandidate),
                        onCreateRule: { target in
                            openRuleEditor(source: suggestion.source, target: target ?? suggestion.target)
                        },
                        onIgnore: {
                            IgnoreWordService.add(suggestion.source)
                        }
                    )
                }
        )
    }

    private func clearCurrentRange() {
        let now = Date()
        store.clear { entry in
            range.contains(entry.timestamp, now: now)
        }
    }

    private func candidates(for entry: ReplacementHistoryEntry) -> [MistakeSuggestionCandidate] {
        candidates(
            source: entry.original,
            target: ruleTarget(source: entry.original, target: entry.converted, targetTruncated: entry.convertedTruncated),
            sourceLayoutID: entry.sourceLayoutID
        )
    }

    private func candidates(
        source: String,
        target: String?,
        sourceLayoutID: String?,
        rawSources: [String]? = nil
    ) -> [MistakeSuggestionCandidate] {
        analyzer.candidates(
            forRawSources: rawSources ?? [source],
            language: sourceLayoutID.map(AutoFixDecision.languageHintForLayoutID) ?? "",
            recordedTargets: target.map { [$0] } ?? [],
            layoutManager: layoutManager,
            limit: 4
        )
    }

    private func openRuleEditor(for entry: ReplacementHistoryEntry, target: String? = nil) {
        openRuleEditor(source: entry.original, target: target ?? entry.converted)
    }

    private func openRuleEditor(source: String, target: String? = nil) {
        editorSeed = RuleEditorSeed(
            source: HistoryWordActionPolicy.normalizedSource(source),
            target: HistoryWordActionPolicy.sanitizedTarget(target) ?? "",
            mode: .replace
        )
    }

    private func ignore(_ entry: ReplacementHistoryEntry) {
        IgnoreWordService.add(entry.original)
    }

    private func ruleTarget(
        source: String,
        target: String?,
        targetTruncated: Bool = false
    ) -> String? {
        guard let target = HistoryWordActionPolicy.sanitizedTarget(target, truncated: targetTruncated) else {
            return nil
        }
        let source = HistoryWordActionPolicy.normalizedSource(source)
        guard target.caseInsensitiveCompare(source) != .orderedSame else { return nil }
        return target
    }
}

private struct ReplacementActionRow: View {
    let entry: ReplacementHistoryEntry
    let candidates: [MistakeSuggestionCandidate]
    let onCreateRule: (String?) -> Void
    let onIgnore: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            appGlyph
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(entry.kind.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(entry.kind == .autoFixUndone ? .orange : .secondary)
                    if let appName {
                        Text(appName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(timestampText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                ReplacementReceipt(
                    source: entry.original,
                    target: entry.converted.isEmpty ? "ввести заміну" : entry.converted,
                    strikethroughSource: entry.kind != .autoFixUndone
                )

                HistoryCandidateStrip(candidates: candidates) { candidate in
                    guard candidate.canCreateCoreRule else { return }
                    onCreateRule(candidate.text)
                }
            }

            Spacer(minLength: 12)

            HistoryRowActions(
                canAct: disabledReason == nil,
                disabledReason: disabledReason,
                ruleDisabledReason: HistoryWordActionPolicy.ruleDisabledReason(for: primaryCandidate),
                onCreateRule: { onCreateRule(primaryTarget) },
                onIgnore: onIgnore
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primaryTarget: String? {
        HistoryWordActionPolicy.sanitizedTarget(entry.converted, truncated: entry.convertedTruncated)
    }

    private var primaryCandidate: MistakeSuggestionCandidate? {
        primaryTarget.flatMap { target in
            candidates.first {
                MistakeObservation.normalizedToken($0.text)
                    == MistakeObservation.normalizedToken(target)
            }
        }
    }

    private var disabledReason: String? {
        HistoryWordActionPolicy.disabledReason(source: entry.original, truncated: entry.originalTruncated)
    }

    @ViewBuilder
    private var appGlyph: some View {
        if let bundleID = entry.bundleID, !bundleID.isEmpty,
           let icon = AppContextProvider.icon(forBundleID: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color("BrandTintSoft"))
                Image(systemName: entry.kind.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(entry.kind == .autoFixUndone ? .orange : Color("BrandAccentDeep"))
            }
        }
    }

    private var appName: String? {
        guard let bundleID = entry.bundleID, !bundleID.isEmpty else { return nil }
        return AppContextProvider.displayName(forBundleID: bundleID)
    }

    private var timestampText: String {
        "\(relativeDay), \(Self.timeFormatter.string(from: entry.timestamp))"
    }

    private var relativeDay: String {
        let cal = Calendar.current
        if cal.isDateInToday(entry.timestamp) { return "сьогодні" }
        if cal.isDateInYesterday(entry.timestamp) { return "вчора" }
        return entry.timestamp.formatted(.dateTime.weekday(.abbreviated))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("HH:mm")
        return f
    }()
}

private struct ReplacementHistorySuggestion: Identifiable {
    enum Kind {
        case makeRule
        case ignoreWord

        var title: String {
            switch self {
            case .makeRule: return "Повторювана заміна"
            case .ignoreWord: return "Часто скасовується"
            }
        }

        var icon: String {
            switch self {
            case .makeRule: return "wand.and.stars"
            case .ignoreWord: return "hand.raised"
            }
        }
    }

    let id: String
    let kind: Kind
    let source: String
    let target: String?
    let sourceLayoutID: String?
    let rawSources: [String]
    let sourceTruncated: Bool
    let count: Int
    let lastSeen: Date

    var subtitle: String {
        switch kind {
        case .makeRule:
            return "Ця пара повторюється. Можна зробити її правилом або додати джерело в «не чіпати»."
        case .ignoreWord:
            return "AutoFix для цього слова часто відкатували. Ймовірно, його краще не чіпати."
        }
    }
}

private func aggregateReplacementSuggestions(_ entries: [ReplacementHistoryEntry]) -> [ReplacementHistorySuggestion] {
    struct Acc {
        var kind: ReplacementHistorySuggestion.Kind
        var source: String
        var target: String?
        var sourceLayoutID: String?
        var rawSources: Set<String>
        var sourceTruncated: Bool
        var count: Int
        var lastSeen: Date
    }

    var map: [String: Acc] = [:]
    for entry in entries {
        let sourceCore = HistoryWordActionPolicy.normalizedSource(entry.original)
        guard !sourceCore.isEmpty else { continue }

        let kind: ReplacementHistorySuggestion.Kind
        let target: String?
        let key: String
        if entry.kind == .autoFixUndone {
            kind = .ignoreWord
            target = nil
            key = "ignore:\(sourceCore.lowercased())"
        } else {
            guard !entry.originalTruncated,
                  !entry.convertedTruncated,
                  let sanitizedTarget = HistoryWordActionPolicy.sanitizedTarget(entry.converted),
                  sanitizedTarget.caseInsensitiveCompare(sourceCore) != .orderedSame else {
                continue
            }
            kind = .makeRule
            target = sanitizedTarget
            key = "rule:\(sourceCore.lowercased())->\(sanitizedTarget.lowercased())"
        }

        if var acc = map[key] {
            acc.count += 1
            acc.rawSources.insert(entry.original)
            if entry.timestamp > acc.lastSeen {
                acc.source = entry.original
                acc.target = target
                acc.sourceLayoutID = entry.sourceLayoutID
                acc.sourceTruncated = entry.originalTruncated
                acc.lastSeen = entry.timestamp
            }
            map[key] = acc
        } else {
            map[key] = Acc(
                kind: kind,
                source: entry.original,
                target: target,
                sourceLayoutID: entry.sourceLayoutID,
                rawSources: [entry.original],
                sourceTruncated: entry.originalTruncated,
                count: 1,
                lastSeen: entry.timestamp
            )
        }
    }

    return map.map { key, acc in
        ReplacementHistorySuggestion(
            id: key,
            kind: acc.kind,
            source: acc.source,
            target: acc.target,
            sourceLayoutID: acc.sourceLayoutID,
            rawSources: acc.rawSources.sorted(),
            sourceTruncated: acc.sourceTruncated,
            count: acc.count,
            lastSeen: acc.lastSeen
        )
    }
    .sorted { lhs, rhs in
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs.lastSeen > rhs.lastSeen
    }
}
