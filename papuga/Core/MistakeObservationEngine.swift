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

enum MistakeSuggestionKind: String, Equatable {
    case recorded
    case spelling
    case keyboardLayout

    var title: String {
        switch self {
        case .recorded: return "Зафіксовано"
        case .spelling: return "Орфографія"
        case .keyboardLayout: return "Розкладка"
        }
    }

    var systemImage: String {
        switch self {
        case .recorded: return "arrow.triangle.2.circlepath"
        case .spelling: return "text.magnifyingglass"
        case .keyboardLayout: return "keyboard"
        }
    }

    var rank: Int {
        switch self {
        case .recorded: return 0
        case .keyboardLayout: return 1
        case .spelling: return 2
        }
    }
}

struct MistakeSuggestionCandidate: Identifiable, Equatable {
    let kind: MistakeSuggestionKind
    let text: String
    let confidence: Double
    let sourceLayoutID: String?
    let targetLayoutID: String?

    var id: String {
        [
            kind.rawValue,
            MistakeObservation.normalizedToken(text),
            sourceLayoutID ?? "",
            targetLayoutID ?? ""
        ].joined(separator: "|")
    }

    init(
        kind: MistakeSuggestionKind,
        text: String,
        confidence: Double,
        sourceLayoutID: String? = nil,
        targetLayoutID: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.confidence = min(max(confidence, 0), 1)
        self.sourceLayoutID = sourceLayoutID
        self.targetLayoutID = targetLayoutID
    }
}

final class MistakeSuggestionAnalyzer {
    private let spellChecker: SpellCheckingClient
    private let mapper = CharacterMapper()
    private var mappedLayoutIDs = Set<String>()

    init(spellChecker: SpellCheckingClient = SystemSpellCheckingClient()) {
        self.spellChecker = spellChecker
    }

    func candidates(
        for source: String,
        language: String,
        recordedTargets: [String] = [],
        layoutManager: LayoutManager? = nil,
        limit: Int = 4
    ) -> [MistakeSuggestionCandidate] {
        let normalizedSource = MistakeObservation.normalizedToken(source)
        guard !normalizedSource.isEmpty else { return [] }

        var result: [MistakeSuggestionCandidate] = []
        for target in recordedTargets {
            append(
                MistakeSuggestionCandidate(kind: .recorded, text: target, confidence: 0.9),
                to: &result,
                sourceKey: normalizedSource
            )
        }

        if let layoutManager {
            for candidate in keyboardLayoutCandidates(
                for: source,
                language: language,
                layoutManager: layoutManager,
                limit: limit
            ) {
                append(candidate, to: &result, sourceKey: normalizedSource)
            }
        }

        for guess in spellChecker.guesses(for: source, language: language).prefix(8) {
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
                    confidence: spellingConfidence(source: source, candidate: candidate)
                ),
                to: &result,
                sourceKey: normalizedSource
            )
        }

        return result
            .sorted { lhs, rhs in
                if lhs.kind.rank != rhs.kind.rank { return lhs.kind.rank < rhs.kind.rank }
                if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                return lhs.text.localizedCaseInsensitiveCompare(rhs.text) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    private func keyboardLayoutCandidates(
        for source: String,
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
                let converted = mapper.convert(text: source, fromSourceID: fromID, toSourceID: toID)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard converted != source,
                      !converted.isEmpty,
                      !converted.contains(where: \.isWhitespace),
                      converted.count <= MistakeObservation.maxStoredCharCount else {
                    continue
                }

                let targetLanguage = AutoFixDecision.languageHintForLayoutID(toID)
                let targetLooksCorrect = !spellChecker.isMisspelled(converted, language: targetLanguage)
                let confidence = targetLooksCorrect ? 0.82 : 0.64
                result.append(
                    MistakeSuggestionCandidate(
                        kind: .keyboardLayout,
                        text: converted,
                        confidence: confidence,
                        sourceLayoutID: fromID,
                        targetLayoutID: toID
                    )
                )
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
        guard shouldInspect(input) else { return nil }
        guard spellChecker.isMisspelled(input.word, language: input.language) else { return nil }

        let suggestion = bestSuggestion(for: input.word, language: input.language)
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
        if let bundleID = candidate.bundleID, Defaults[.autoFixBlocklist].contains(bundleID) {
            return nil
        }
        guard AutoFixDecision.shouldSkipWord(candidate.source, minLength: Defaults[.autoFixMinWordLength]) == nil else {
            return nil
        }
        guard AutoFixDecision.shouldSkipWord(candidate.target, minLength: Defaults[.autoFixMinWordLength]) == nil else {
            return nil
        }
        guard !AutoFixDecision.isInAllowlist(candidate.source, allowlist: Defaults[.autoFixAllowlist]) else {
            return nil
        }
        let observation = MistakeObservation(
            issueType: .manualCorrection,
            source: candidate.source,
            suggestedTarget: candidate.target,
            language: candidate.language,
            bundleID: candidate.bundleID,
            confidence: candidate.confidence
        )
        store.record(observation)
        return observation
    }

    private func shouldInspect(_ input: CompletedWordObservation) -> Bool {
        let word = input.word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard word == input.word, !word.isEmpty else { return false }
        guard input.bundleID.map({ !input.blocklist.contains($0) }) ?? true else { return false }
        guard !AutoFixDecision.isInAllowlist(word, allowlist: input.allowlist) else { return false }
        guard AutoFixDecision.shouldSkipWord(word, minLength: input.minWordLength) == nil else { return false }
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
