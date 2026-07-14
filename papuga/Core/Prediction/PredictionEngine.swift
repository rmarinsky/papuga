import Foundation
import OSLog

/// The "brain" behind the redesigned mistakes screen.
///
/// Computes correction candidates for every mistake group across the user's
/// whole history, but **cooperatively in the background** (chunked with
/// `Task.yield()` so the main thread never freezes), **incrementally** (only new
/// or changed groups), and **persistently** (a disk cache means a relaunch
/// doesn't recompute what hasn't changed). The UI renders only from the
/// published snapshots — `phase`, `analyzedCount`/`totalCount`, `liveFeed`,
/// `ranked` — so it can show the analysis happening live without blocking.
@MainActor
@Observable
final class PredictionEngine {
    static let shared = PredictionEngine()

    // MARK: Published state (read by the screen)

    private(set) var phase: PredictionPhase = .idle
    private(set) var analyzedCount = 0
    private(set) var totalCount = 0
    private(set) var liveFeed: [FoundPair] = []
    private(set) var ranked: [PredictionGroup] = []
    /// All mistakes grouped by mutual similarity — drives the "Усі" tab.
    private(set) var errorClusters: [ErrorCluster] = []

    // MARK: Dependencies / tuning

    private let analyzer: MistakeSuggestionAnalyzer
    private let store: MistakeObservationStore
    private weak var layoutManager: LayoutManager?

    private let chunkSize: Int
    private let liveFeedCap = 6
    private let maxRanked = 80
    private let candidateLimit = 4

    /// Words already handled (allowlist / rules) — filtered out of suggestions.
    /// Injectable so tests stay independent of the machine's real Defaults.
    var handledSourcesProvider: () -> Set<String> = { LearnedVocabulary.handledSources() }

    /// Total open observations still considered mistakes (after known/handled
    /// words are excluded) — drives the "Помилок" stat.
    private(set) var flaggedCount = 0

    // MARK: Learned domain vocabulary

    /// Words Papuga has learned to treat as correct from the user's own history,
    /// so domain jargon (плейрайт, репозиторії, віджет) stops being flagged.
    /// Two sources: (1) words the user *produces* (replacement-history converted
    /// forms), (2) recurring **word-like** mistakes with **no close correction**
    /// — gibberish like кщьфт/кнокп (no vowel) is excluded, so real layout errors
    /// keep getting fixed.
    private(set) var domainVocabulary: Set<String> = []
    private let domainMinOccurrences = 2
    var domainLearningEnabled = true

    // MARK: Cache (in-memory + disk)

    // v6 also AND-merges rule safety across application-specific groups.
    private static let cacheVersion = 6
    private var cache: [String: WordPrediction] = [:]
    private let cacheURL: URL
    private let domainVocabURL: URL
    private var analysisTask: Task<Void, Never>?
    private var noteDebounce: Task<Void, Never>?
    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "Prediction")

    init(
        analyzer: MistakeSuggestionAnalyzer = MistakeSuggestionAnalyzer(),
        store: MistakeObservationStore = .shared,
        chunkSize: Int = 40,
        cacheURL: URL? = nil
    ) {
        self.analyzer = analyzer
        self.store = store
        self.chunkSize = max(1, chunkSize)
        let resolvedCacheURL: URL
        if let cacheURL {
            resolvedCacheURL = cacheURL
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            resolvedCacheURL = appSupport
                .appendingPathComponent("papuga", isDirectory: true)
                .appendingPathComponent("prediction-cache.json")
        }
        self.cacheURL = resolvedCacheURL
        self.domainVocabURL = resolvedCacheURL
            .deletingLastPathComponent()
            .appendingPathComponent("domain-vocabulary.json")
    }

    func configure(layoutManager: LayoutManager) {
        self.layoutManager = layoutManager
        analyzer.invalidateCache() // layout maps may now resolve
    }

    // MARK: Lifecycle entry points

    /// Call once at launch: load the disk cache, then background-analyze anything
    /// not yet cached.
    func bootstrap() {
        loadCacheFromDisk()
        loadDomainVocabularyFromDisk()
        harvestProducedCorpus()
        analyze(observations: store.entries, force: false)
    }

    /// "Переаналізувати все" — wipe the cache and replay the full animated pass.
    func analyzeAll(force: Bool = true) {
        analyze(observations: store.entries, force: force)
    }

    /// A new mistake was just recorded — fold it in without a full rescan.
    func noteNewObservations() {
        noteDebounce?.cancel()
        noteDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            analyze(observations: store.entries, force: false)
        }
    }

    func cancel() {
        analysisTask?.cancel()
    }

    // MARK: Core analysis

    private func analyze(observations: [MistakeObservation], force: Bool) {
        analysisTask?.cancel()
        if force {
            cache.removeAll(keepingCapacity: true)
            analyzer.invalidateCache()
            liveFeed.removeAll()
        }

        let known = handledSourcesProvider().union(domainVocabulary)
        let groups = MistakesScreenDerivation.groups(
            from: MistakesScreenDerivation.rangedEntries(observations, range: .all),
            filter: .all,
            query: ""
        )
        .filter { !known.contains(MistakeObservation.normalizedToken($0.source)) }
        totalCount = groups.count
        flaggedCount = groups.reduce(0) { $0 + $1.count }
        let pending = groups.filter { cache[$0.id] == nil }
        analyzedCount = groups.count - pending.count
        phase = pending.isEmpty ? .ready : .analyzing
        publishRanked(groups: groups) // show whatever is already cached immediately

        computeClusters(groups: groups)

        guard !pending.isEmpty else {
            saveCacheToDisk()
            return
        }

        analysisTask = Task { @MainActor [chunkSize] in
            var index = 0
            while index < pending.count {
                if Task.isCancelled { return }
                let end = min(index + chunkSize, pending.count)
                for group in pending[index..<end] {
                    let candidates = MistakesScreenDerivation.candidates(
                        for: group,
                        analyzer: analyzer,
                        layoutManager: layoutManager,
                        limit: candidateLimit
                    )
                    cache[group.id] = WordPrediction(
                        key: group.id,
                        source: group.source,
                        language: group.language,
                        candidates: candidates,
                        computedAt: Date()
                    )
                    analyzedCount += 1
                    if let best = candidates.first {
                        pushLive(FoundPair(
                            id: "\(group.id)#\(analyzedCount)",
                            source: group.source,
                            target: best.replacementPlan?.renderedReplacement ?? best.text,
                            kind: best.kind
                        ))
                    }
                }
                index = end
                publishRanked(groups: groups) // accumulate cards as we go
                await Task.yield()             // economy: let the UI breathe
            }
            if Task.isCancelled { return }
            learnDomainVocabulary() // now that every group has candidates
            computeClusters(groups: groups) // full similarity map for the "Усі" tab
            phase = .ready
            saveCacheToDisk()
            logger.notice("Prediction pass complete: \(self.totalCount, privacy: .public) groups")
        }
    }

    /// After a full pass: a recurring **word-like** mistake with no close typo
    /// correction is almost certainly a real domain word the user keeps typing,
    /// not an error — learn it so it stops being flagged. Gibberish (no vowel,
    /// e.g. кщьфт) is excluded, so layout errors still get fixed.
    private func learnDomainVocabulary() {
        guard domainLearningEnabled else { return }
        var newlyKnown: [String] = []
        for group in ranked where group.count >= domainMinOccurrences {
            guard WordPlausibility.isWordLike(group.source) else { continue }
            let token = MistakeObservation.normalizedToken(group.source)
            // A "close fix" — a recorded target, a clean layout flip, or any
            // candidate within one (Damerau) edit — means this is a real typo we
            // can correct, so keep flagging it. No close fix → a domain word.
            let hasCloseFix = group.candidates.contains { candidate in
                if candidate.kind == .recorded || candidate.confidence >= 0.82 { return true }
                return SymSpell.damerauLevenshtein(
                    Array(token),
                    Array(MistakeObservation.normalizedToken(candidate.text)),
                    max: 1
                ) >= 0
            }
            guard !hasCloseFix else { continue }
            if !token.isEmpty, !domainVocabulary.contains(token) { newlyKnown.append(token) }
        }
        guard !newlyKnown.isEmpty else { return }
        domainVocabulary.formUnion(newlyKnown)
        let known = handledSourcesProvider().union(domainVocabulary)
        ranked.removeAll { known.contains(MistakeObservation.normalizedToken($0.source)) }
        flaggedCount = ranked.reduce(0) { $0 + $1.count }
        saveDomainVocabularyToDisk()
        logger.notice("Learned \(newlyKnown.count, privacy: .public) domain words")
    }

    /// Seed the known set from the user's *produced* text (the corrected side of
    /// their replacement history) — words they actually output are correct.
    private func harvestProducedCorpus() {
        var produced: Set<String> = []
        for entry in ReplacementHistoryStore.shared.entries {
            guard entry.kind != .autoFixUndone, !entry.convertedTruncated else { continue }
            for token in entry.converted.split(whereSeparator: { !$0.isLetter }) {
                let normalized = MistakeObservation.normalizedToken(String(token))
                if normalized.count >= 3, WordPlausibility.isWordLike(normalized) {
                    produced.insert(normalized)
                }
            }
        }
        if !produced.isEmpty {
            domainVocabulary.formUnion(produced)
            saveDomainVocabularyToDisk()
        }
    }

    private func pushLive(_ pair: FoundPair) {
        liveFeed.append(pair)
        if liveFeed.count > liveFeedCap {
            liveFeed.removeFirst(liveFeed.count - liveFeedCap)
        }
    }

    /// Merge derived groups that LOOK the same to the user — same word, same
    /// language, same suggested correction — even if they came from different
    /// apps (bundleID) or differ only by whether a target was recorded. A rule
    /// is global, so one "кщьфт → roman 6×" beats two "3×" cards.
    private func mergedGroups(from groups: [MistakeGroupData]) -> [PredictionGroup] {
        var merged: [String: PredictionGroup] = [:]
        for group in groups {
            let candidates = cache[group.id]?.candidates ?? []
            let target = primaryTarget(for: group, candidates: candidates)
            let key = [
                MistakeObservation.normalizedToken(group.source),
                group.language,
                target.map { MistakeObservation.normalizedToken($0) } ?? ""
            ].joined(separator: "|")

            if let existing = merged[key] {
                let mergedCandidates = mergeCandidateSafety(
                    existing: existing.candidates,
                    incoming: candidates
                )
                merged[key] = PredictionGroup(
                    id: key,
                    source: existing.source,
                    language: existing.language,
                    count: existing.count + group.count,
                    lastSeen: Swift.max(existing.lastSeen, group.lastSeen),
                    candidates: mergedCandidates,
                    primaryTarget: existing.primaryTarget ?? target,
                    observationIDs: existing.observationIDs + group.observationIDs
                )
            } else {
                merged[key] = PredictionGroup(
                    id: key,
                    source: group.source,
                    language: group.language,
                    count: group.count,
                    lastSeen: group.lastSeen,
                    candidates: candidates,
                    primaryTarget: target,
                    observationIDs: group.observationIDs
                )
            }
        }
        return Array(merged.values)
    }

    private func mergeCandidateSafety(
        existing: [MistakeSuggestionCandidate],
        incoming: [MistakeSuggestionCandidate]
    ) -> [MistakeSuggestionCandidate] {
        guard !existing.isEmpty else {
            // A missing candidate set is missing safety evidence, not approval.
            return incoming.map { $0.withCoreRuleCreationAllowed(false) }
        }
        guard !incoming.isEmpty else {
            return existing.map { $0.withCoreRuleCreationAllowed(false) }
        }

        return existing.map { candidate in
            let targetKey = MistakeObservation.normalizedToken(candidate.text)
            let matching = incoming.first {
                MistakeObservation.normalizedToken($0.text) == targetKey
            }
            return candidate.withCoreRuleCreationAllowed(
                candidate.canCreateCoreRule && (matching?.canCreateCoreRule == true)
            )
        }
    }

    private func publishRanked(groups: [MistakeGroupData]) {
        ranked = mergedGroups(from: groups).sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.lastSeen > rhs.lastSeen
        }
        if ranked.count > maxRanked {
            ranked = Array(ranked.prefix(maxRanked))
        }
    }

    /// Cluster ALL current mistakes by similarity for the "Усі" tab.
    private func computeClusters(groups: [MistakeGroupData]) {
        let known = handledSourcesProvider().union(domainVocabulary)
        let merged = mergedGroups(from: groups)
            .filter { !known.contains(MistakeObservation.normalizedToken($0.source)) }
        errorClusters = ErrorClustering.cluster(merged.map { group in
            let targetCandidate = group.primaryTarget.flatMap { target in
                group.candidates.first {
                    MistakeObservation.normalizedToken($0.text)
                        == MistakeObservation.normalizedToken(target)
                }
            }
            return ErrorClustering.Item(
                source: group.source, language: group.language, count: group.count,
                target: group.primaryTarget,
                renderedTarget: group.renderedPrimaryTarget,
                replacementPlan: targetCandidate?.replacementPlan,
                canCreateCoreRule: targetCandidate?.canCreateCoreRule,
                observationIDs: group.observationIDs
            )
        })
    }

    private func primaryTarget(for group: MistakeGroupData, candidates: [MistakeSuggestionCandidate]) -> String? {
        if let target = group.target,
           !group.targetTruncated,
           let sanitized = HistoryWordActionPolicy.sanitizedTarget(target),
           sanitized.caseInsensitiveCompare(HistoryWordActionPolicy.normalizedSource(group.source)) != .orderedSame {
            return sanitized
        }
        return candidates.first?.text
    }

    // MARK: Domain vocabulary persistence

    private func loadDomainVocabularyFromDisk() {
        guard let data = try? Data(contentsOf: domainVocabURL),
              let words = try? JSONDecoder().decode([String].self, from: data) else { return }
        domainVocabulary = Set(words)
    }

    private func saveDomainVocabularyToDisk() {
        let snapshot = Array(domainVocabulary)
        let url = domainVocabURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Disk cache

    private struct DiskCache: Codable {
        let version: Int
        let entries: [WordPrediction]
    }

    private func loadCacheFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder.iso8601.decode(DiskCache.self, from: data),
              decoded.version == Self.cacheVersion else { return }
        cache = Dictionary(uniqueKeysWithValues: decoded.entries.map { ($0.key, $0) })
        logger.notice("Prediction cache loaded: \(self.cache.count, privacy: .public) entries")
    }

    private func saveCacheToDisk() {
        let snapshot = DiskCache(version: Self.cacheVersion, entries: Array(cache.values))
        let url = cacheURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder.iso8601.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    #if DEBUG
    /// Run one full analysis synchronously to completion (benchmark/test only).
    func analyzeToCompletionForTesting(observations: [MistakeObservation], force: Bool) async {
        analyze(observations: observations, force: force)
        await analysisTask?.value
    }

    var cacheCountForTesting: Int { cache.count }
    #endif
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
