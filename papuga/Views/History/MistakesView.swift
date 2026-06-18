import SwiftUI

struct MistakesView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case spelling
        case manualCorrection
        case grammar
        case resolved

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "Усі"
            case .spelling: return "Орфографія"
            case .manualCorrection: return "Виправлено вручну"
            case .grammar: return "Граматика beta"
            case .resolved: return "Закриті"
            }
        }
    }

    @Environment(LayoutManager.self) private var layoutManager

    @State private var analyzer = MistakeSuggestionAnalyzer()
    @State private var store = MistakeObservationStore.shared
    @State private var range: HistoryTimeRange = .today
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var editorSeed: RuleEditorSeed?
    @State private var pendingObservationIDs: [UUID] = []

    var body: some View {
        ActionableHistoryScreen(
            range: $range,
            query: $query,
            clearDisabled: rangedEntries.isEmpty,
            clearConfirmationTitle: "Очистити помилки введення \(range.clearScopeTitle)?",
            onClear: clearCurrentRange
        ) {
            VStack(alignment: .leading, spacing: 14) {
                statsRow
                filterControl
                ActionableSuggestionsSection(items: suggestionItems)
                content
            }
        }
        .sheet(item: $editorSeed) { seed in
            RuleEditorSheet(
                seed: seed,
                onClose: {
                    editorSeed = nil
                    pendingObservationIDs = []
                },
                onSave: { result in
                    markPending(result.mode == .replace ? .convertedToRule : .addedToDictionary)
                }
            )
        }
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            stat("Нові", value: openCount, icon: "circle.fill")
            stat("Повторювані", value: repeatedCount, icon: "repeat")
            stat("Правила", value: convertedCount, icon: "wand.and.stars")
            stat("Ігноровано", value: ignoredCount, icon: "hand.raised")
        }
    }

    private func stat(_ title: String, value: Int, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color("BrandAccentDeep"))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
        )
    }

    private var filterControl: some View {
        Picker("", selection: $filter) {
            ForEach(Filter.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        if filteredGroups.isEmpty {
            emptyView
        } else {
            VStack(spacing: 0) {
                ForEach(Array(filteredGroups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 {
                        Divider().opacity(0.45)
                    }
                    let candidates = candidates(for: group)
                    MistakeGroupRow(
                        group: group,
                        candidates: candidates,
                        onCreateRule: { target in openRuleEditor(for: group, target: target) },
                        onIgnore: { addToDictionary(group) }
                    )
                }
            }
            .background(historyCardBackground)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "text.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Поки що немає спостережень" : "Нічого не знайдено")
                .font(.headline)
            if query.isEmpty {
                Text("Коли Papuga помітить повторювані помилки, вони з'являться тут.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
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

    private var groupedObservations: [MistakeGroup] {
        let filtered = rangedEntries.filter { entry in
            switch filter {
            case .all:
                guard entry.status == .open else { return false }
            case .spelling:
                guard entry.status == .open, entry.issueType == .spelling else { return false }
            case .manualCorrection:
                guard entry.status == .open, entry.issueType == .manualCorrection else { return false }
            case .grammar:
                guard entry.status == .open, entry.issueType == .grammar else { return false }
            case .resolved:
                guard entry.status != .open else { return false }
            }

            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return true }
            let appName = entry.bundleID.map(AppContextProvider.displayName(forBundleID:)) ?? ""
            return entry.source.localizedCaseInsensitiveContains(q)
                || (entry.suggestedTarget?.localizedCaseInsensitiveContains(q) ?? false)
                || appName.localizedCaseInsensitiveContains(q)
                || entry.issueType.displayName.localizedCaseInsensitiveContains(q)
        }

        let groups = Dictionary(grouping: filtered) { entry in
            [
                entry.issueType.rawValue,
                entry.normalizedSource,
                entry.normalizedTarget ?? "",
                entry.language,
                entry.bundleID ?? "",
                entry.status.rawValue
            ].joined(separator: "|")
        }

        return groups.values.map(MistakeGroup.init(entries:))
            .sorted { lhs, rhs in
                if lhs.statusRank != rhs.statusRank { return lhs.statusRank < rhs.statusRank }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.lastSeen > rhs.lastSeen
            }
    }

    private var filteredGroups: [MistakeGroup] {
        groupedObservations
    }

    private var rangedEntries: [MistakeObservation] {
        store.entries.filter { range.contains($0.timestamp) }
    }

    private var suggestionItems: [ActionableSuggestionItem] {
        Array(
            groupedObservations
                .filter { $0.status == .open && $0.count >= 2 }
                .prefix(5)
                .map { group in
                    let disabledReason = HistoryWordActionPolicy.disabledReason(
                        source: group.source,
                        truncated: group.sourceTruncated
                    )
                    let target = primaryTarget(for: group)
                    return ActionableSuggestionItem(
                        id: "mistake-advice:\(group.id)",
                        icon: group.issueType.systemImage,
                        title: group.issueType.displayName,
                        subtitle: "Повторюється в цьому періоді. Можна створити правило або додати слово в «не чіпати».",
                        source: group.source,
                        target: target,
                        countText: "\(group.count)×",
                        candidates: candidates(for: group),
                        canAct: disabledReason == nil,
                        disabledReason: disabledReason,
                        onCreateRule: { target in openRuleEditor(for: group, target: target) },
                        onIgnore: { addToDictionary(group) }
                    )
                }
        )
    }

    private var openCount: Int {
        rangedEntries.filter { $0.status == .open }.count
    }

    private var repeatedCount: Int {
        groupedObservations.filter { $0.count > 1 && $0.status == .open }.count
    }

    private var convertedCount: Int {
        rangedEntries.filter { $0.status == .convertedToRule }.count
    }

    private var ignoredCount: Int {
        rangedEntries.filter { $0.status == .dismissed || $0.status == .addedToDictionary }.count
    }

    private func candidates(for group: MistakeGroup) -> [MistakeSuggestionCandidate] {
        analyzer.candidates(
            for: group.source,
            language: group.language,
            recordedTargets: group.recordedTargets,
            layoutManager: layoutManager,
            limit: 4
        )
    }

    private func primaryTarget(for group: MistakeGroup) -> String? {
        guard let target = group.target,
              !group.targetTruncated,
              let sanitizedTarget = HistoryWordActionPolicy.sanitizedTarget(target),
              sanitizedTarget.caseInsensitiveCompare(HistoryWordActionPolicy.normalizedSource(group.source)) != .orderedSame else {
            return candidates(for: group).first?.text
        }
        return sanitizedTarget
    }

    private func clearCurrentRange() {
        let now = Date()
        store.clear { entry in
            range.contains(entry.timestamp, now: now)
        }
    }

    private func openRuleEditor(for group: MistakeGroup, target: String? = nil) {
        pendingObservationIDs = group.observationIDs
        editorSeed = RuleEditorSeed(
            source: HistoryWordActionPolicy.normalizedSource(group.source),
            target: HistoryWordActionPolicy.sanitizedTarget(target ?? primaryTarget(for: group)) ?? "",
            mode: .replace
        )
    }

    private func addToDictionary(_ group: MistakeGroup) {
        IgnoreWordService.add(group.source)
        mark(group, .addedToDictionary)
    }

    private func mark(_ group: MistakeGroup, _ status: MistakeObservation.Status) {
        for id in group.observationIDs {
            store.updateStatus(for: id, to: status)
        }
    }

    private func markPending(_ status: MistakeObservation.Status) {
        for id in pendingObservationIDs {
            store.updateStatus(for: id, to: status)
        }
        pendingObservationIDs = []
    }
}

private struct MistakeGroup: Identifiable {
    let entries: [MistakeObservation]

    var id: String {
        [
            issueType.rawValue,
            source.lowercased(),
            target?.lowercased() ?? "",
            language,
            bundleID ?? "",
            status.rawValue
        ].joined(separator: "|")
    }

    var issueType: MistakeObservation.IssueType { entries[0].issueType }
    var status: MistakeObservation.Status { entries[0].status }
    var source: String { entries[0].source }
    var target: String? { recordedTargets.first }
    var language: String { entries[0].language }
    var bundleID: String? { entries[0].bundleID }
    var sourceTruncated: Bool { entries.contains(where: \.sourceTruncated) }
    var targetTruncated: Bool { entries.contains(where: \.targetTruncated) }
    var count: Int { entries.count }
    var lastSeen: Date { entries.map(\.timestamp).max() ?? .distantPast }
    var confidence: Double { entries.map(\.confidence).max() ?? 0 }
    var observationIDs: [UUID] { entries.map(\.id) }
    var recordedTargets: [String] {
        let counts = entries.reduce(into: [String: Int]()) { result, entry in
            guard let target = entry.suggestedTarget?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty else { return }
            result[target, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map(\.key)
    }

    var statusRank: Int {
        status == .open ? 0 : 1
    }
}

private struct MistakeGroupRow: View {
    let group: MistakeGroup
    let candidates: [MistakeSuggestionCandidate]
    let onCreateRule: (String?) -> Void
    let onIgnore: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            iconTile

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(group.issueType.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(group.count)×")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color("BrandAccentDeep"))
                        .monospacedDigit()
                    Text(group.language.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                    Text(meta)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                ReplacementReceipt(
                    source: group.source,
                    target: primaryTarget ?? "ввести заміну",
                    strikethroughSource: primaryTarget != nil
                )
                .opacity(group.status == .open ? 1 : 0.55)

                if group.status == .open {
                    HistoryCandidateStrip(candidates: candidates) { candidate in
                        onCreateRule(candidate.text)
                    }
                }
            }

            Spacer(minLength: 12)

            if group.status == .open {
                HistoryRowActions(
                    canAct: disabledReason == nil,
                    disabledReason: disabledReason,
                    onCreateRule: { onCreateRule(primaryTarget) },
                    onIgnore: onIgnore
                )
            } else {
                Text(statusTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primaryTarget: String? {
        guard let target = group.target,
              !group.targetTruncated,
              let sanitizedTarget = HistoryWordActionPolicy.sanitizedTarget(target),
              sanitizedTarget.caseInsensitiveCompare(HistoryWordActionPolicy.normalizedSource(group.source)) != .orderedSame else {
            return candidates.first?.text
        }
        return sanitizedTarget
    }

    private var disabledReason: String? {
        HistoryWordActionPolicy.disabledReason(source: group.source, truncated: group.sourceTruncated)
    }

    private var meta: String {
        var parts = ["остання: \(group.lastSeen.formatted(date: .abbreviated, time: .shortened))"]
        if let bundleID = group.bundleID, !bundleID.isEmpty {
            parts.append(AppContextProvider.displayName(forBundleID: bundleID))
        }
        parts.append("впевненість \(Int(group.confidence * 100))%")
        return parts.joined(separator: " · ")
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color("BrandTintSoft"))
            Image(systemName: group.issueType.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color("BrandAccentDeep"))
        }
        .frame(width: 32, height: 32)
    }

    private var statusTitle: String {
        switch group.status {
        case .open: return ""
        case .dismissed: return "ігноровано"
        case .convertedToRule: return "створено правило"
        case .addedToDictionary: return "не чіпати"
        }
    }
}
