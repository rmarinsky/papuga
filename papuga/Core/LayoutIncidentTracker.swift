import Foundation

struct LayoutIncidentToken: Equatable {
    enum Evidence: Equatable {
        case strong
        case neutral
        case contradiction
    }

    let original: String
    let candidate: String
    let boundary: String
    let targetLayoutID: String
    let evidence: Evidence
}

enum LayoutIncidentAppendResult: Equatable {
    case accepted
    case reachedCap
    case wouldExceedCap
    case targetChanged
}

enum LayoutIncidentDecision: Equatable {
    case replace
    case propose
    case discard
}

struct LayoutIncidentTracker: Equatable {
    static let defaultMaxWords = 30
    static let defaultMaxUTF16Length = 300

    private let maxWords: Int
    private let maxUTF16Length: Int
    private(set) var tokens: [LayoutIncidentToken] = []
    private(set) var targetLayoutID: String?

    init(
        maxWords: Int = Self.defaultMaxWords,
        maxUTF16Length: Int = Self.defaultMaxUTF16Length
    ) {
        self.maxWords = max(1, maxWords)
        self.maxUTF16Length = max(1, maxUTF16Length)
    }

    var wordCount: Int { tokens.count }
    var isEmpty: Bool { tokens.isEmpty }
    var trailingBoundary: String { tokens.last?.boundary ?? " " }
    var originalBody: String { body(\.original) }
    var candidateBody: String { body(\.candidate) }

    var isAtSafetyCap: Bool {
        wordCount >= maxWords
            || originalBody.utf16.count >= maxUTF16Length
            || candidateBody.utf16.count >= maxUTF16Length
    }

    var strongTokenCount: Int {
        tokens.filter { $0.evidence == .strong }.count
    }

    var contradictionCount: Int {
        tokens.filter { $0.evidence == .contradiction }.count
    }

    var supportRatio: Double {
        guard !tokens.isEmpty else { return 0 }
        return Double(strongTokenCount) / Double(tokens.count)
    }

    var endsSentence: Bool {
        Self.hasSentenceTerminator(originalBody) || Self.hasSentenceTerminator(candidateBody)
    }

    static func isHardBoundary(_ boundary: String) -> Bool {
        boundary == "\r" || boundary == "\n" || boundary == "\t"
    }

    @discardableResult
    mutating func append(_ token: LayoutIncidentToken) -> LayoutIncidentAppendResult {
        if let targetLayoutID, targetLayoutID != token.targetLayoutID {
            return .targetChanged
        }

        let internalBoundaryLength = tokens.last?.boundary.utf16.count ?? 0
        let projectedOriginalLength = originalBody.utf16.count
            + internalBoundaryLength
            + token.original.utf16.count
        let projectedCandidateLength = candidateBody.utf16.count
            + internalBoundaryLength
            + token.candidate.utf16.count
        guard tokens.count + 1 <= maxWords,
              projectedOriginalLength <= maxUTF16Length,
              projectedCandidateLength <= maxUTF16Length else {
            return .wouldExceedCap
        }

        targetLayoutID = token.targetLayoutID
        tokens.append(token)
        return isAtSafetyCap ? .reachedCap : .accepted
    }

    func decision(
        scoreOriginal: Double,
        scoreCandidate: Double,
        threshold: Double
    ) -> LayoutIncidentDecision {
        guard contradictionCount == 0 else { return .discard }
        let margin = scoreCandidate - scoreOriginal
        if strongTokenCount >= 3,
           supportRatio >= 0.75,
           margin >= threshold {
            return .replace
        }
        if strongTokenCount >= 2,
           supportRatio >= 0.60 {
            return .propose
        }
        return .discard
    }

    mutating func reset() {
        tokens.removeAll(keepingCapacity: true)
        targetLayoutID = nil
    }

    private func body(_ keyPath: KeyPath<LayoutIncidentToken, String>) -> String {
        tokens.enumerated().map { index, token in
            let text = token[keyPath: keyPath]
            guard index < tokens.count - 1 else { return text }
            return text + token.boundary
        }.joined()
    }

    private static func hasSentenceTerminator(_ text: String) -> Bool {
        let ignoredClosers = CharacterSet(charactersIn: "\"'”’)]}")
        let trimmed = text.unicodeScalars
            .reversed()
            .drop(while: { CharacterSet.whitespacesAndNewlines.contains($0) || ignoredClosers.contains($0) })
        guard let last = trimmed.first else { return false }
        return last == "." || last == "!" || last == "?"
    }
}

struct LayoutIncidentTimerState: Equatable {
    static let singleWordGrace: TimeInterval = 0.75
    static let incidentIdleDelay: TimeInterval = 1.2

    enum DueAction: Equatable {
        case applySingleWord
        case finalizeIncident
    }

    private enum Pending: Equatable {
        case singleWord(deadline: TimeInterval)
        case incident(deadline: TimeInterval)
    }

    private var pending: Pending?

    mutating func armSingleWord(at timestamp: TimeInterval) {
        pending = .singleWord(deadline: timestamp + Self.singleWordGrace)
    }

    mutating func armIncidentIdle(at timestamp: TimeInterval) {
        pending = .incident(deadline: timestamp + Self.incidentIdleDelay)
    }

    mutating func consumeFastContinuation(at timestamp: TimeInterval) -> Bool {
        guard case .singleWord(let deadline) = pending,
              timestamp < deadline else { return false }
        pending = nil
        return true
    }

    mutating func takeDueAction(at timestamp: TimeInterval) -> DueAction? {
        guard let pending else { return nil }
        let action: DueAction
        let deadline: TimeInterval
        switch pending {
        case .singleWord(let value):
            action = .applySingleWord
            deadline = value
        case .incident(let value):
            action = .finalizeIncident
            deadline = value
        }
        guard timestamp >= deadline else { return nil }
        self.pending = nil
        return action
    }

    mutating func reset() {
        pending = nil
    }
}
