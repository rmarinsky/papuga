import AppKit
import Defaults
import Foundation

protocol SpellCheckingClient {
    func isMisspelled(_ word: String, language: String) -> Bool
    func guesses(for word: String, language: String) -> [String]
}

struct SystemSpellCheckingClient: SpellCheckingClient {
    func isMisspelled(_ word: String, language: String) -> Bool {
        !AutoFixDecision.isCorrectlySpelled(word, language: language)
    }

    func guesses(for word: String, language: String) -> [String] {
        NSSpellChecker.shared.guesses(
            forWordRange: NSRange(location: 0, length: (word as NSString).length),
            in: word,
            language: language,
            inSpellDocumentWithTag: 0
        ) ?? []
    }
}

enum MistakeSuggestionKind: String, Equatable, Codable {
    case recorded
    case spelling
    case keyboardLayout
    case keyboardAdjacency

    var title: String {
        switch self {
        case .recorded: return "Зафіксовано"
        case .spelling: return "Орфографія"
        case .keyboardLayout: return "Розкладка"
        case .keyboardAdjacency: return "Клавіша"
        }
    }

    var systemImage: String {
        switch self {
        case .recorded: return "arrow.triangle.2.circlepath"
        case .spelling: return "text.magnifyingglass"
        case .keyboardLayout: return "keyboard"
        case .keyboardAdjacency: return "hand.tap"
        }
    }

    var rank: Int {
        switch self {
        case .recorded: return 0
        case .keyboardLayout: return 1
        case .keyboardAdjacency: return 2
        case .spelling: return 3
        }
    }
}

struct MistakeSuggestionCandidate: Identifiable, Equatable, Codable {
    let kind: MistakeSuggestionKind
    let text: String
    let confidence: Double
    let sourceLayoutID: String?
    let targetLayoutID: String?
    let replacementPlan: ReplacementPlan?
    let coreRuleCreationAllowed: Bool?

    var id: String {
        [
            kind.rawValue,
            MistakeObservation.normalizedToken(text),
            sourceLayoutID ?? "",
            targetLayoutID ?? ""
        ].joined(separator: "|")
    }

    /// Full-token layout mappings that consume punctuation-looking edge keys
    /// cannot be represented by Papuga's core-only custom rules.
    var canCreateCoreRule: Bool {
        coreRuleCreationAllowed ?? replacementPlan?.canCreateCoreRule ?? true
    }

    func withCoreRuleCreationAllowed(_ allowed: Bool) -> MistakeSuggestionCandidate {
        MistakeSuggestionCandidate(
            kind: kind,
            text: text,
            confidence: confidence,
            sourceLayoutID: sourceLayoutID,
            targetLayoutID: targetLayoutID,
            replacementPlan: replacementPlan,
            coreRuleCreationAllowed: allowed
        )
    }

    init(
        kind: MistakeSuggestionKind,
        text: String,
        confidence: Double,
        sourceLayoutID: String? = nil,
        targetLayoutID: String? = nil,
        replacementPlan: ReplacementPlan? = nil,
        coreRuleCreationAllowed: Bool? = nil
    ) {
        self.kind = kind
        self.text = text
        self.confidence = min(max(confidence, 0), 1)
        self.sourceLayoutID = sourceLayoutID
        self.targetLayoutID = targetLayoutID
        self.replacementPlan = replacementPlan
        self.coreRuleCreationAllowed = coreRuleCreationAllowed
    }
}

final class MistakeSuggestionAnalyzer {
    private let spellChecker: SpellCheckingClient
    private let mapper = CharacterMapper()
    private var mappedLayoutIDs = Set<String>()

    /// Candidate generation is dominated by synchronous `NSSpellChecker` IPC,
    /// which has no internal result cache. The same misspelled words recur
    /// across every re-render (sheet present, scroll, store mutation), so we
    /// memoize the fully-resolved candidate list per (source, language,
    /// recorded targets, layout set). Keyed on inputs → automatically correct
    /// when the data or layouts change.
    private var candidateCache: [String: [MistakeSuggestionCandidate]] = [:]

    init(spellChecker: SpellCheckingClient = SystemSpellCheckingClient()) {
        self.spellChecker = spellChecker
    }

    /// Drop memoized candidates (e.g. after the spell dictionary or allowlist
    /// changes in a way that should re-open previously-resolved suggestions).
    func invalidateCache() {
        candidateCache.removeAll(keepingCapacity: true)
    }

    func candidates(
        for source: String,
        language: String,
        recordedTargets: [String] = [],
        layoutManager: LayoutManager? = nil,
        limit: Int = 4
    ) -> [MistakeSuggestionCandidate] {
        let token = BufferedToken(rawText: source, keyCodes: [])
        let sourceCore = token.core
        let normalizedSource = MistakeObservation.normalizedToken(sourceCore)
        guard !normalizedSource.isEmpty else { return [] }
        let targetCores = recordedTargets
            .map(BufferedToken.normalizedCore(from:))
            .filter { !$0.isEmpty }

        let layoutSignature = layoutManager?.orderedLayouts().joined(separator: ",") ?? ""
        // Replacement plans preserve the exact raw edges, so punctuated forms
        // must not reuse a bare token's cached plan (or vice versa).
        let cacheKey = "\(token.rawText)\u{1}\(language)\u{1}\(limit)\u{1}\(targetCores.joined(separator: "\u{2}"))\u{1}\(layoutSignature)"
        if let cached = candidateCache[cacheKey] { return cached }
        let result = computeCandidates(
            token: token,
            normalizedSource: normalizedSource,
            language: language,
            recordedTargets: targetCores,
            layoutManager: layoutManager,
            limit: limit
        )
        candidateCache[cacheKey] = result
        return result
    }

    /// Aggregate a core group without losing punctuation/layout safety from
    /// any raw form. A rule is eligible only when the same target is safe for
    /// every observed spelling of the source token.
    func candidates(
        forRawSources rawSources: [String],
        language: String,
        recordedTargets: [String] = [],
        layoutManager: LayoutManager? = nil,
        limit: Int = 4
    ) -> [MistakeSuggestionCandidate] {
        var seenSources = Set<String>()
        let uniqueSources = rawSources.filter { seenSources.insert($0).inserted }
        guard !uniqueSources.isEmpty else { return [] }
        let batches = uniqueSources.map { source in
            candidates(
                for: source,
                language: language,
                recordedTargets: recordedTargets,
                layoutManager: layoutManager,
                limit: limit
            )
        }
        guard let representativeCandidates = batches.first else { return [] }

        return representativeCandidates.map { candidate in
            let targetKey = MistakeObservation.normalizedToken(candidate.text)
            let safeForEveryRawSource = batches.allSatisfy { batch in
                batch.first {
                    MistakeObservation.normalizedToken($0.text) == targetKey
                }?.canCreateCoreRule == true
            }
            return candidate.withCoreRuleCreationAllowed(safeForEveryRawSource)
        }
    }

    private func computeCandidates(
        token: BufferedToken,
        normalizedSource: String,
        language: String,
        recordedTargets: [String],
        layoutManager: LayoutManager?,
        limit: Int
    ) -> [MistakeSuggestionCandidate] {

        var result: [MistakeSuggestionCandidate] = []
        let layoutCandidates: [MistakeSuggestionCandidate]
        if let layoutManager {
            layoutCandidates = keyboardLayoutCandidates(
                for: token,
                language: language,
                layoutManager: layoutManager,
                limit: limit
            )
        } else {
            layoutCandidates = []
        }
        for target in recordedTargets {
            let matchingLayout = layoutCandidates.first {
                MistakeObservation.normalizedToken($0.text)
                    == MistakeObservation.normalizedToken(target)
            }
            let fallbackRuleSafety = matchingLayout == nil
                ? CoreRuleSafety.canCreateWithoutLayoutInterpretation(
                    rawSource: token.rawText,
                    targetCore: target,
                    isLayoutCandidate: false
                )
                : nil
            let plan: ReplacementPlan
            if let matchedPlan = matchingLayout?.replacementPlan {
                plan = matchedPlan
            } else if fallbackRuleSafety == false {
                // The recorded output proves the edge was consumed, even when
                // the corresponding keyboard layout is unavailable today.
                plan = ReplacementPlan(
                    rawSource: token.rawText,
                    correctedCore: target,
                    preservedLeadingPunctuation: "",
                    preservedTrailingPunctuation: "",
                    renderedReplacement: target,
                    boundary: "",
                    interpretationReason: .layoutFullToken
                )
            } else {
                plan = token.replacementPlan(
                    correctedCore: target,
                    boundary: "",
                    reason: .sameLanguageSpelling
                )
            }
            append(
                MistakeSuggestionCandidate(
                    kind: .recorded,
                    text: target,
                    confidence: 0.9,
                    sourceLayoutID: matchingLayout?.sourceLayoutID,
                    targetLayoutID: matchingLayout?.targetLayoutID,
                    replacementPlan: plan,
                    coreRuleCreationAllowed: fallbackRuleSafety
                ),
                to: &result,
                sourceKey: normalizedSource
            )
        }

        if let layoutManager {
            for candidate in layoutCandidates {
                append(candidate, to: &result, sourceKey: normalizedSource)
            }
            for candidate in keyboardAdjacencyCandidates(
                for: token,
                language: language,
                layoutManager: layoutManager,
                limit: limit
            ) {
                append(candidate, to: &result, sourceKey: normalizedSource)
            }
        }

        for guess in spellChecker.guesses(for: token.core, language: language).prefix(8) {
            let candidate = guess.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty,
                  !candidate.contains(where: \.isWhitespace),
                  candidate.count <= MistakeObservation.maxStoredCharCount else {
                continue
            }
            append(
                MistakeSuggestionCandidate(
                    kind: .spelling,
                    text: candidate,
                    confidence: spellingConfidence(source: token.core, candidate: candidate),
                    replacementPlan: token.replacementPlan(
                        correctedCore: candidate,
                        boundary: "",
                        reason: .sameLanguageSpelling
                    )
                ),
                to: &result,
                sourceKey: normalizedSource
            )
        }

        return result
            // Never surface gibberish (consonant soup / punctuation from a layout
            // flip of a real word). Trust the user's own recorded corrections.
            .filter { $0.kind == .recorded || WordPlausibility.isWordLike($0.text) }
            .sorted { lhs, rhs in
                if lhs.kind.rank != rhs.kind.rank { return lhs.kind.rank < rhs.kind.rank }
                if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                return lhs.text.localizedCaseInsensitiveCompare(rhs.text) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    private func keyboardLayoutCandidates(
        for token: BufferedToken,
        language: String,
        layoutManager: LayoutManager,
        limit: Int
    ) -> [MistakeSuggestionCandidate] {
        let ordered = layoutManager.orderedLayouts()
        guard ordered.count >= 2 else { return [] }

        let sourceLanguage = language.isEmpty ? nil : language
        let sourceLayoutIDs = ordered.filter { id in
            sourceLanguage.map { AutoFixDecision.languageHintForLayoutID(id) == $0 } ?? false
        }
        let fromIDs = sourceLayoutIDs.isEmpty ? ordered : sourceLayoutIDs
        let targetIDs = ordered.filter { id in
            guard !fromIDs.contains(id) else { return false }
            guard let sourceLanguage else { return true }
            return AutoFixDecision.languageHintForLayoutID(id) != sourceLanguage
        }

        var result: [MistakeSuggestionCandidate] = []
        for fromID in fromIDs.prefix(3) {
            guard ensureMapped(layoutID: fromID, layoutManager: layoutManager) else { continue }
            for toID in targetIDs.prefix(6) {
                guard ensureMapped(layoutID: toID, layoutManager: layoutManager) else { continue }
                let fullMapped = mapper.convert(
                    text: token.rawText,
                    fromSourceID: fromID,
                    toSourceID: toID
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let coreMapped = mapper.convert(
                    text: token.core,
                    fromSourceID: fromID,
                    toSourceID: toID
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard fullMapped != token.rawText || coreMapped != token.core else {
                    continue
                }

                let targetLanguage = AutoFixDecision.languageHintForLayoutID(toID)
                let fullCore = BufferedToken.normalizedCore(from: fullMapped)
                let fullIsValid = !fullCore.isEmpty
                    && !spellChecker.isMisspelled(fullCore, language: targetLanguage)
                let coreIsValid = !coreMapped.isEmpty
                    && !spellChecker.isMisspelled(coreMapped, language: targetLanguage)
                let decision = LayoutInterpretationPolicy.select(
                    token: token,
                    fullMapped: fullMapped,
                    coreMapped: coreMapped,
                    fullIsValid: fullIsValid,
                    coreIsValid: coreIsValid,
                    boundary: ""
                )
                for plan in decision.suggestions {
                    guard !plan.correctedCore.isEmpty,
                          !plan.correctedCore.contains(where: \.isWhitespace),
                          plan.correctedCore.count <= MistakeObservation.maxStoredCharCount else {
                        continue
                    }
                    result.append(MistakeSuggestionCandidate(
                        kind: .keyboardLayout,
                        text: plan.correctedCore,
                        confidence: 0.82,
                        sourceLayoutID: fromID,
                        targetLayoutID: toID,
                        replacementPlan: plan
                    ))
                    if result.count >= limit { return result }
                }
            }
        }
        return result
    }

    /// Language-agnostic "fat-finger" model: for each character, try the
    /// physically adjacent keys (same layout) and keep substitutions that land
    /// on a correctly-spelled word. Works on key *codes*, so it is identical for
    /// QWERTY / ЙЦУКЕН / AZERTY — the differentiator: "it doesn't matter which
    /// language, only which keys were pressed".
    private func keyboardAdjacencyCandidates(
        for token: BufferedToken,
        language: String,
        layoutManager: LayoutManager,
        limit: Int
    ) -> [MistakeSuggestionCandidate] {
        let ordered = layoutManager.orderedLayouts()
        guard !ordered.isEmpty else { return [] }

        let sourceLanguage = language.isEmpty ? nil : language
        let layoutID = ordered.first { id in
            sourceLanguage.map { AutoFixDecision.languageHintForLayoutID(id) == $0 } ?? false
        } ?? ordered.first!
        guard ensureMapped(layoutID: layoutID, layoutManager: layoutManager) else { return [] }

        let source = token.core
        let chars = Array(source)
        guard chars.count >= 2, chars.count <= MistakeObservation.maxStoredCharCount else { return [] }

        var result: [MistakeSuggestionCandidate] = []
        var seen = Set<String>()
        for index in chars.indices {
            guard let mapping = mapper.mapping(for: chars[index], sourceID: layoutID) else { continue }
            for neighbour in KeyboardAdjacency.neighbours(of: mapping.keyCode) {
                guard let neighbourChars = mapper.characters(forKeyCode: neighbour, sourceID: layoutID) else { continue }
                guard let replacement = mapping.needsShift ? neighbourChars.shifted : neighbourChars.normal,
                      replacement != chars[index],
                      !replacement.isWhitespace else { continue }

                var candidateChars = chars
                candidateChars[index] = replacement
                let candidate = String(candidateChars)
                guard candidate != source, seen.insert(candidate).inserted else { continue }
                guard !spellChecker.isMisspelled(candidate, language: language) else { continue }

                result.append(MistakeSuggestionCandidate(
                    kind: .keyboardAdjacency,
                    text: candidate,
                    confidence: 0.78,
                    replacementPlan: token.replacementPlan(
                        correctedCore: candidate,
                        boundary: "",
                        reason: .sameLanguageSpelling
                    )
                ))
                if result.count >= limit { return result }
            }
        }
        return result
    }

    private func ensureMapped(layoutID: String, layoutManager: LayoutManager) -> Bool {
        if mappedLayoutIDs.contains(layoutID) { return true }
        guard let source = layoutManager.sourceForID(layoutID) else { return false }
        mapper.buildMap(for: source, sourceID: layoutID)
        mappedLayoutIDs.insert(layoutID)
        return true
    }

    private func append(
        _ candidate: MistakeSuggestionCandidate,
        to result: inout [MistakeSuggestionCandidate],
        sourceKey: String
    ) {
        let candidateKey = MistakeObservation.normalizedToken(candidate.text)
        guard !candidateKey.isEmpty, candidateKey != sourceKey else { return }

        if let index = result.firstIndex(where: { MistakeObservation.normalizedToken($0.text) == candidateKey }) {
            let existing = result[index]
            if candidate.kind.rank < existing.kind.rank || candidate.confidence > existing.confidence {
                result[index] = candidate
            }
        } else {
            result.append(candidate)
        }
    }

    private func spellingConfidence(source: String, candidate: String) -> Double {
        let distance = ManualCorrectionTracker.levenshteinDistance(source.lowercased(), candidate.lowercased())
        let maxLength = max(source.count, candidate.count, 1)
        let ratio = Double(distance) / Double(maxLength)
        return max(0.5, min(0.86, 0.86 - (ratio * 0.42)))
    }
}

struct CompletedWordObservation {
    let word: String
    let language: String
    let bundleID: String?
    let timestamp: Date
    let allowlist: [String]
    let blocklist: [String]
    let minWordLength: Int
}

struct ManualCorrectionCandidate: Equatable {
    let source: String
    let target: String
    let language: String
    let bundleID: String?
    let confidence: Double
}

final class ManualCorrectionTracker {
    private struct CompletedToken {
        let word: String
        let language: String
        let bundleID: String?
        let timestamp: TimeInterval
    }

    private struct ActiveCorrection {
        let source: CompletedToken
        var deleteCount: Int
        var startedAt: TimeInterval
    }

    private var lastCompleted: CompletedToken?
    private var activeCorrection: ActiveCorrection?

    private let correctionWindow: TimeInterval
    private let minDeleteCount: Int
    private let minWordLength: Int

    init(correctionWindow: TimeInterval = 12, minDeleteCount: Int = 2, minWordLength: Int = 3) {
        self.correctionWindow = correctionWindow
        self.minDeleteCount = minDeleteCount
        self.minWordLength = minWordLength
    }

    func noteCompletedWord(
        _ word: String,
        language: String,
        bundleID: String?,
        timestamp: TimeInterval
    ) -> ManualCorrectionCandidate? {
        let token = CompletedToken(word: word, language: language, bundleID: bundleID, timestamp: timestamp)
        defer { lastCompleted = token }

        guard let active = activeCorrection else { return nil }
        activeCorrection = nil

        guard timestamp - active.startedAt <= correctionWindow else { return nil }
        guard active.deleteCount >= minDeleteCount else { return nil }

        let source = active.source.word
        let target = word
        guard isLikelyCorrection(source: source, target: target) else { return nil }

        return ManualCorrectionCandidate(
            source: source,
            target: target,
            language: language,
            bundleID: bundleID ?? active.source.bundleID,
            confidence: confidence(source: source, target: target)
        )
    }

    func noteBackspace(bufferWasEmpty: Bool, timestamp: TimeInterval) {
        guard bufferWasEmpty else { return }
        if var active = activeCorrection {
            active.deleteCount += 1
            activeCorrection = active
            return
        }
        guard let lastCompleted else { return }
        guard timestamp - lastCompleted.timestamp <= correctionWindow else { return }
        activeCorrection = ActiveCorrection(
            source: lastCompleted,
            deleteCount: 1,
            startedAt: timestamp
        )
    }

    func resetEditingState() {
        activeCorrection = nil
    }

    private func isLikelyCorrection(source: String, target: String) -> Bool {
        let src = MistakeObservation.normalizedToken(source)
        let tgt = MistakeObservation.normalizedToken(target)
        guard src.count >= minWordLength, tgt.count >= minWordLength else { return false }
        guard src != tgt else { return false }
        guard !src.contains(where: \.isWhitespace), !tgt.contains(where: \.isWhitespace) else { return false }
        guard AutoFixDecision.shouldSkipWord(src, minLength: minWordLength) == nil else { return false }
        guard AutoFixDecision.shouldSkipWord(tgt, minLength: minWordLength) == nil else { return false }

        let distance = Self.levenshteinDistance(src, tgt)
        let maxLength = max(src.count, tgt.count)
        guard maxLength > 0 else { return false }

        let ratio = Double(distance) / Double(maxLength)
        return distance <= 3 || ratio <= 0.34
    }

    private func confidence(source: String, target: String) -> Double {
        let distance = Self.levenshteinDistance(source.lowercased(), target.lowercased())
        let maxLength = max(source.count, target.count, 1)
        let ratio = Double(distance) / Double(maxLength)
        return max(0.55, min(0.95, 0.95 - ratio))
    }

    static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            previous = current
        }

        return previous[b.count]
    }
}

final class MistakeObservationEngine {
    static let shared = MistakeObservationEngine()

    private let spellChecker: SpellCheckingClient
    private let store: MistakeObservationRecording

    init(
        spellChecker: SpellCheckingClient = SystemSpellCheckingClient(),
        store: MistakeObservationRecording = MistakeObservationStore.shared
    ) {
        self.spellChecker = spellChecker
        self.store = store
    }

    @discardableResult
    func observeCompletedWord(_ input: CompletedWordObservation) -> MistakeObservation? {
        let token = BufferedToken(rawText: input.word, keyCodes: [])
        guard shouldInspect(input, token: token) else { return nil }
        guard spellChecker.isMisspelled(token.core, language: input.language) else { return nil }

        let suggestion = bestSuggestion(for: token.core, language: input.language)
        let observation = MistakeObservation(
            timestamp: input.timestamp,
            issueType: .spelling,
            source: input.word,
            suggestedTarget: suggestion,
            language: input.language,
            bundleID: input.bundleID,
            confidence: suggestion == nil ? 0.58 : 0.68
        )
        store.record(observation)
        return observation
    }

    @discardableResult
    func recordManualCorrection(_ candidate: ManualCorrectionCandidate) -> MistakeObservation? {
        let sourceToken = BufferedToken(rawText: candidate.source, keyCodes: [])
        let targetToken = BufferedToken(rawText: candidate.target, keyCodes: [])
        if let bundleID = candidate.bundleID, Defaults[.autoFixBlocklist].contains(bundleID) {
            return nil
        }
        guard AutoFixDecision.shouldSkipWord(sourceToken.core, minLength: Defaults[.autoFixMinWordLength]) == nil else {
            return nil
        }
        guard AutoFixDecision.shouldSkipWord(targetToken.core, minLength: Defaults[.autoFixMinWordLength]) == nil else {
            return nil
        }
        guard !AutoFixDecision.isInAllowlist(sourceToken.core, allowlist: Defaults[.autoFixAllowlist]) else {
            return nil
        }
        let observation = MistakeObservation(
            issueType: .manualCorrection,
            source: candidate.source,
            suggestedTarget: targetToken.core,
            language: candidate.language,
            bundleID: candidate.bundleID,
            confidence: candidate.confidence
        )
        store.record(observation)
        return observation
    }

    private func shouldInspect(_ input: CompletedWordObservation, token: BufferedToken) -> Bool {
        let word = input.word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard word == input.word, !word.isEmpty else { return false }
        guard !token.core.isEmpty else { return false }
        guard input.bundleID.map({ !input.blocklist.contains($0) }) ?? true else { return false }
        guard !AutoFixDecision.isInAllowlist(token.core, allowlist: input.allowlist) else { return false }
        guard AutoFixDecision.shouldSkipWord(token.core, minLength: input.minWordLength) == nil else { return false }
        guard !word.contains(where: \.isWhitespace) else { return false }
        return true
    }

    private func bestSuggestion(for word: String, language: String) -> String? {
        spellChecker.guesses(for: word, language: language)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first {
                !$0.isEmpty
                    && !$0.contains(where: \.isWhitespace)
                    && $0.caseInsensitiveCompare(word) != .orderedSame
                    && $0.count <= MistakeObservation.maxStoredCharCount
            }
    }
}
