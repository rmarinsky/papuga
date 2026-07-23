import Foundation

/// Filter tabs on the "Помилки введення" screen, extracted so the derivation
/// pipeline is testable and benchmarkable outside SwiftUI.
enum MistakesFilter: String, CaseIterable, Identifiable {
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

/// A grouped bucket of observations that share the same (issue, source, target,
/// language, app, status). Mirrors the private `MistakeGroup` in `MistakesView`
/// exactly — this is the single source of truth the view should render from.
struct MistakeGroupData: Identifiable {
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
    var rawSources: [String] {
        var seen = Set<String>()
        return entries.map(\.source).filter { seen.insert($0).inserted }
    }
    var target: String? { recordedTargets.first }
    var renderedTarget: String? {
        entries.first(where: { $0.suggestedTarget != nil })?.renderedSuggestedTarget
    }
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

/// Pure derivation pipeline for the mistakes screen. Behaviour-preserving
/// extraction of the computed properties currently inlined in `MistakesView`.
///
/// Keeping it here (rather than inside the view) makes it (a) benchmarkable on
/// real data and (b) memoizable — the view can compute it once per input change
/// instead of several times per `body` evaluation.
enum MistakesScreenDerivation {
    static func rangedEntries(
        _ entries: [MistakeObservation],
        range: HistoryTimeRange,
        now: Date = Date()
    ) -> [MistakeObservation] {
        entries.filter { range.contains($0.timestamp, now: now) }
    }

    /// Mirrors `MistakesView.groupedObservations`.
    static func groups(
        from ranged: [MistakeObservation],
        filter: MistakesFilter,
        query: String
    ) -> [MistakeGroupData] {
        let filtered = ranged.filter { entry in
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

        let buckets = Dictionary(grouping: filtered) { entry in
            [
                entry.issueType.rawValue,
                entry.normalizedSource,
                entry.normalizedTarget ?? "",
                entry.language,
                entry.bundleID ?? "",
                entry.status.rawValue
            ].joined(separator: "|")
        }

        return buckets.values.map(MistakeGroupData.init(entries:))
            .sorted { lhs, rhs in
                if lhs.statusRank != rhs.statusRank { return lhs.statusRank < rhs.statusRank }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.lastSeen > rhs.lastSeen
            }
    }

    /// Groups that feed the "Поради" (suggestions) section — mirrors
    /// `MistakesView.suggestionItems` selection.
    static func suggestionGroups(_ groups: [MistakeGroupData]) -> [MistakeGroupData] {
        Array(groups.filter { $0.status == .open && $0.count >= 2 }.prefix(5))
    }

    // MARK: - Header counts (mirror MistakesView)

    static func openCount(_ ranged: [MistakeObservation]) -> Int {
        ranged.lazy.filter { $0.status == .open }.count
    }

    static func repeatedCount(_ groups: [MistakeGroupData]) -> Int {
        groups.lazy.filter { $0.count > 1 && $0.status == .open }.count
    }

    static func convertedCount(_ ranged: [MistakeObservation]) -> Int {
        ranged.lazy.filter { $0.status == .convertedToRule }.count
    }

    static func ignoredCount(_ ranged: [MistakeObservation]) -> Int {
        ranged.lazy.filter { $0.status == .dismissed || $0.status == .addedToDictionary }.count
    }

    // MARK: - Per-group candidates (mirror MistakesView.candidates / primaryTarget)

    static func candidates(
        for group: MistakeGroupData,
        analyzer: MistakeSuggestionAnalyzer,
        layoutManager: LayoutManager?,
        limit: Int = 4
    ) -> [MistakeSuggestionCandidate] {
        analyzer.candidates(
            forRawSources: group.rawSources,
            language: group.language,
            recordedTargets: group.recordedTargets,
            layoutManager: layoutManager,
            limit: limit
        )
    }

    static func primaryTarget(
        for group: MistakeGroupData,
        analyzer: MistakeSuggestionAnalyzer,
        layoutManager: LayoutManager?
    ) -> String? {
        guard let target = group.target,
              !group.targetTruncated,
              let sanitizedTarget = HistoryWordActionPolicy.sanitizedTarget(target),
              sanitizedTarget.caseInsensitiveCompare(HistoryWordActionPolicy.normalizedSource(group.source)) != .orderedSame else {
            return candidates(for: group, analyzer: analyzer, layoutManager: layoutManager).first?.text
        }
        return sanitizedTarget
    }
}
