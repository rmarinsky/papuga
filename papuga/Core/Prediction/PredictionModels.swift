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
    let observationIDs: [UUID]
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
}
