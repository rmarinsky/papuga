import Defaults
import SwiftUI

struct ReplacementsHistorySectionView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case completed
        case potential

        var id: String { rawValue }

        var title: String {
            switch self {
            case .completed: return "Виконані"
            case .potential: return "Потенційні"
            }
        }
    }

    var compactChrome = false

    @Environment(LayoutManager.self) private var layoutManager

    @State private var analyzer = MistakeSuggestionAnalyzer()
    @State private var store = ReplacementHistoryStore.shared
    @State private var mistakeStore = MistakeObservationStore.shared
    @State private var predictionEngine = PredictionEngine.shared
    @State private var mode: Mode = .completed
    @State private var range: HistoryTimeRange = .today
    @State private var query = ""
    @State private var editorSeed: RuleEditorSeed?
    @State private var pendingPotentialObservationID: UUID?

    @Default(.replacementHistoryEnabled) private var historyEnabled
    @Default(.autoFixAllowlist) private var autoFixAllowlist
    @Default(.customAutoReplaceRules) private var customAutoReplaceRules

    init(compactChrome: Bool = false) {
        self.compactChrome = compactChrome
    }

    var body: some View {
        ActionableHistoryScreen(
            range: $range,
            query: $query,
            clearDisabled: mode == .potential || rangeEntries.isEmpty,
            clearConfirmationTitle: "Очистити історію замін \(range.clearScopeTitle)?",
            onClear: clearCurrentRange
        ) {
            VStack(alignment: .leading, spacing: 14) {
                modePicker
                switch mode {
                case .completed:
                    if historyEnabled {
                        ActionableSuggestionsSection(items: suggestionItems)
                        completedContent
                    } else {
                        disabledView
                    }
                case .potential:
                    potentialContent
                }
            }
        }
        .sheet(item: $editorSeed) { seed in
            RuleEditorSheet(
                seed: seed,
                onClose: {
                    editorSeed = nil
                    pendingPotentialObservationID = nil
                },
                onSave: { result in
                    resolvePendingPotential(
                        as: result.mode == .replace ? .convertedToRule : .addedToDictionary
                    )
                }
            )
        }
        .task {
            predictionEngine.configure(layoutManager: layoutManager)
            predictionEngine.bootstrap()
        }
        .onChange(of: mistakeStore.entries) {
            predictionEngine.noteInputsChanged()
        }
        .onChange(of: autoFixAllowlist) {
            predictionEngine.noteInputsChanged()
        }
        .onChange(of: customAutoReplaceRules) {
            predictionEngine.noteInputsChanged()
        }
    }

    private var modePicker: some View {
        Picker("Тип історії", selection: $mode) {
            ForEach(Mode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 280)
        .accessibilityLabel("Тип історії замін")
    }

    @ViewBuilder
    private var completedContent: some View {
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

    @ViewBuilder
    private var potentialContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
                Text("Журнал потенційних замін")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if predictionEngine.phase == .analyzing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Papuga аналізує історію")
                } else {
                    Text("\(visiblePotentialEntries.count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if visiblePotentialEntries.isEmpty {
                potentialEmptyView
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visiblePotentialEntries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().opacity(0.45) }
                        PotentialReplacementActionRow(
                            entry: entry,
                            onCreateRule: { openRuleEditor(for: entry) },
                            onIgnore: { ignore(entry) }
                        )
                    }
                }
            }
        }
        .padding(14)
        .background(historyCardBackground)
    }

    private var potentialEmptyView: some View {
        HStack(spacing: 10) {
            Image(systemName: predictionEngine.phase == .analyzing ? "hourglass" : "checkmark.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(
                predictionEngine.phase == .analyzing
                    ? "Papuga аналізує збережену історію — записи зʼявлятимуться тут."
                    : (query.isEmpty ? "Потенційних замін у цьому періоді немає." : "Нічого не знайдено.")
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
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

    private var handledSources: Set<String> {
        LearnedVocabulary.handledSources(
            allowlist: autoFixAllowlist,
            rules: customAutoReplaceRules
        )
        .union(predictionEngine.domainVocabulary)
    }

    private var potentialEntries: [PotentialReplacementLogEntry] {
        PotentialReplacementLogEntry.derive(
            observations: mistakeStore.entries,
            predictedTargetsByObservationID: predictionEngine.actionableTargetsByObservationID,
            handledSources: handledSources
        )
    }

    private var rangePotentialEntries: [PotentialReplacementLogEntry] {
        let now = Date()
        return potentialEntries.filter { range.contains($0.timestamp, now: now) }
    }

    private var visiblePotentialEntries: [PotentialReplacementLogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return rangePotentialEntries }
        return rangePotentialEntries.filter { entry in
            let inText = entry.source.lowercased().contains(q) || entry.target.lowercased().contains(q)
            let inApp = entry.bundleID.map {
                AppContextProvider.displayName(forBundleID: $0).lowercased().contains(q)
            } ?? false
            return inText || inApp || entry.origin.searchText.contains(q)
        }
    }

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

    private func openRuleEditor(for entry: PotentialReplacementLogEntry) {
        pendingPotentialObservationID = entry.id
        openRuleEditor(source: entry.source, target: entry.target)
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

    private func ignore(_ entry: PotentialReplacementLogEntry) {
        IgnoreWordService.add(entry.source)
        mistakeStore.updateStatus(forIDs: [entry.id], to: .addedToDictionary)
        predictionEngine.noteInputsChanged()
    }

    private func resolvePendingPotential(as status: MistakeObservation.Status) {
        guard let id = pendingPotentialObservationID else { return }
        mistakeStore.updateStatus(forIDs: [id], to: status)
        pendingPotentialObservationID = nil
        predictionEngine.noteInputsChanged()
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

private extension PotentialReplacementLogEntry.Origin {
    var title: String {
        switch self {
        case .recorded: return "Записана корекція"
        case .prediction: return "Прогноз Papuga"
        }
    }

    var searchText: String { title.lowercased() }

    var systemImage: String {
        switch self {
        case .recorded: return "arrow.uturn.backward.circle"
        case .prediction: return "wand.and.stars"
        }
    }
}

private struct PotentialReplacementActionRow: View {
    let entry: PotentialReplacementLogEntry
    let onCreateRule: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            appGlyph
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Label(entry.origin.title, systemImage: entry.origin.systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
                    source: entry.source,
                    target: entry.target,
                    strikethroughSource: true
                )
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button(action: onIgnore) {
                    Label("Не чіпати", systemImage: "character.book.closed")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Зберегти слово у словник — Papuga більше не пропонуватиме цю заміну")

                Button(action: onCreateRule) {
                    Label("Створити правило", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color("BrandAccentDeep"))
                .help("Створити правило з цієї потенційної заміни")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Image(systemName: entry.origin.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
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
        let calendar = Calendar.current
        if calendar.isDateInToday(entry.timestamp) { return "сьогодні" }
        if calendar.isDateInYesterday(entry.timestamp) { return "вчора" }
        return entry.timestamp.formatted(.dateTime.weekday(.abbreviated))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter
    }()
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
            return "Автозаміну для цього слова часто відкатували. Ймовірно, його краще не чіпати."
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
