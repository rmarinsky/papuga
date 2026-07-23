import Foundation

struct AutoFixProposal: Identifiable, Equatable {
    enum Kind: Equatable {
        case detected
        case customRule
        case spelling
    }

    let id = UUID()
    let original: String
    let candidate: String
    let boundary: String
    let fromLayoutID: String
    let targetLayoutID: String
    let scoreOriginal: Double
    let scoreCandidate: Double
    let threshold: Double
    let algorithm: LanguageScorerAlgorithm
    let currentLang: String
    let targetLang: String
    let bundleID: String
    let createdAt: TimeInterval
    let replacementAnchor: TextReplacementAnchor
    let kind: Kind

    var margin: Double {
        scoreCandidate - scoreOriginal
    }

    var createsRuleOnAcceptance: Bool {
        kind == .detected
    }

    var changesInputLayout: Bool {
        kind == .detected
    }

    var candidateOrigin: AutoFixDecisionCandidateOrigin {
        switch kind {
        case .detected: return .keyboardLayout
        case .customRule: return .customRule
        case .spelling: return .spelling
        }
    }

    var displayTitle: String {
        kind == .spelling ? "Можливе виправлення" : "Можлива заміна"
    }

    var primaryActionTooltip: String {
        createsRuleOnAcceptance
            ? "Замінити й створити правило. Enter"
            : "Виправити поточний випадок. Enter"
    }

    var neverActionTitle: String {
        kind == .spelling
            ? "Ніколи не виправляти “\(original)”"
            : "Ніколи не замінювати “\(original)”"
    }
}

enum AutoFixProposalOutcome: Equatable {
    case accepted
    case dismissed
    case timedOut
    case neverReplace

    var shouldAddToAllowlist: Bool {
        self == .neverReplace
    }

    var shouldOfferRecovery: Bool {
        self == .dismissed || self == .timedOut
    }
}

struct PendingProposalRecovery: Equatable {
    let proposal: AutoFixProposal
    let expiresAt: TimeInterval

    func isValid(at timestamp: TimeInterval) -> Bool {
        timestamp < expiresAt
    }
}

enum AutoFixProposalPolicy {
    static func shouldSuggest(
        scoreOriginal: Double,
        scoreCandidate: Double,
        threshold: Double,
        window: Double
    ) -> Bool {
        let margin = scoreCandidate - scoreOriginal
        guard margin > 0 else { return false }
        guard margin < threshold else { return false }
        return threshold - margin <= window
    }
}
