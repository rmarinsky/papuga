import Foundation

/// Lifecycle of the background prediction pass, surfaced to the UI.
enum PredictionPhase: Equatable {
    case idle        // nothing loaded yet
    case analyzing   // background pass in flight
    case ready       // everything in the current dataset is analyzed
}

/// The expensive, cacheable part of a prediction: the candidate corrections for
/// one (source, language) — stable across re-renders and app launches. Persisted
/// to disk so a relaunch doesn't recompute what hasn't changed.
struct WordPrediction: Codable, Equatable {
    let key: String                  // group identity (stable)
    let source: String
    let language: String
    let candidates: [MistakeSuggestionCandidate]
    let computedAt: Date

    var bestConfidence: Double { candidates.first?.confidence ?? 0 }
}

/// A settled, ranked suggestion shown on the screen. Combines the cached
/// candidates with the live group stats (how often, when last seen).
struct PredictionGroup: Identifiable, Equatable {
    let id: String
    let source: String
    let language: String
    let count: Int
    let lastSeen: Date
    let candidates: [MistakeSuggestionCandidate]
    let primaryTarget: String?
    let observationIDs: [UUID]

    var renderedPrimaryTarget: String? {
        guard let primaryTarget else { return nil }
        if let plan = candidates.first(where: {
            MistakeObservation.normalizedToken($0.text)
                == MistakeObservation.normalizedToken(primaryTarget)
        })?.replacementPlan {
            return plan.renderedReplacement
        }
        return BufferedToken(rawText: source, keyCodes: []).render(
            correctedCore: BufferedToken.normalizedCore(from: primaryTarget)
        )
    }

    /// Frequency × confidence — "найчастіші + найбільш схожі".
    var score: Double {
        let confidence = candidates.first?.confidence ?? 0
        return Double(count) * (0.4 + 0.6 * confidence)
    }
}

/// One mistake inside a similarity cluster (the "Усі" tab).
struct ErrorClusterMember: Identifiable, Equatable {
    let id: String
    let source: String
    let language: String
    let count: Int
    let target: String?
    let replacementPlan: ReplacementPlan?
    let canCreateCoreRule: Bool?
    let observationIDs: [UUID]

    var isCoreRuleCreationAllowed: Bool {
        canCreateCoreRule ?? replacementPlan?.canCreateCoreRule ?? true
    }

    init(
        id: String,
        source: String,
        language: String,
        count: Int,
        target: String?,
        replacementPlan: ReplacementPlan? = nil,
        canCreateCoreRule: Bool? = nil,
        observationIDs: [UUID]
    ) {
        self.id = id
        self.source = source
        self.language = language
        self.count = count
        self.target = target
        self.replacementPlan = replacementPlan
        self.canCreateCoreRule = canCreateCoreRule
        self.observationIDs = observationIDs
    }

}

/// A group of mistakes that are similar to each other (small edit distance) or
/// that correct to the same word — surfaced so the user can see patterns across
/// ALL their errors, not just the recurring ones.
struct ErrorCluster: Identifiable, Equatable {
    let id: String
    let representative: String
    let language: String
    let members: [ErrorClusterMember]

    var totalCount: Int { members.reduce(0) { $0 + $1.count } }
    var isSingleton: Bool { members.count == 1 }
    var observationIDs: [UUID] { members.flatMap(\.observationIDs) }
}

/// A just-found (typo → suggestion) pair for the live "scanner" feed. Identity
/// is unique per emission so SwiftUI animates each insert/removal.
struct FoundPair: Identifiable, Equatable {
    let id: String
    let source: String
    let target: String
    let kind: MistakeSuggestionKind

    var renderedTarget: String {
        target
    }
}
