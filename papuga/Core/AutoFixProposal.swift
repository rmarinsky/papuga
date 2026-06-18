import Foundation

struct AutoFixProposal: Identifiable, Equatable {
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
    let canApplyDirectly: Bool
    let targetSession: AutoFixTargetSession?

    var margin: Double {
        scoreCandidate - scoreOriginal
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
