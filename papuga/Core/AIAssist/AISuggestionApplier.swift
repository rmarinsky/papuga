import Defaults
import Foundation

/// Applies the user-confirmed subset of validated `AISuggestion`s onto the SAME write paths
/// the manual cards use, so an AI bulk-apply is indistinguishable from many manual single
/// applies (AI-ASSIST.md §7). It is NEVER called automatically — only from the review step's
/// "Застосувати" button — and it re-checks each observation is still open at apply time so a
/// stale answer can't reopen already-resolved items (§8.5).
@MainActor
enum AISuggestionApplier {
    struct Outcome: Equatable {
        var rulesCreated = 0
        var addedToDictionary = 0
        var ignored = 0
        var skippedStale = 0

        var totalApplied: Int { rulesCreated + addedToDictionary + ignored }
    }

    /// Synchronous apply (used by tests and small batches).
    static func apply(_ suggestions: [AISuggestion],
                      items: [String: AIPromptItem],
                      store: MistakeObservationStore = .shared,
                      engine: PredictionEngine = .shared,
                      isStillOpen: ((UUID) -> Bool)? = nil) -> Outcome {
        var outcome = Outcome()
        let openCheck = openChecker(store: store, isStillOpen: isStillOpen)
        for suggestion in suggestions {
            applyOne(suggestion, items: items, store: store, openCheck: openCheck, outcome: &outcome)
        }
        engine.noteNewObservations()
        return outcome
    }

    /// Chunked apply that yields to the run loop between items so a big batch (hundreds of
    /// dictionary writes, each a synchronous NSSpellChecker IPC) doesn't freeze the UI and can
    /// report progress. `progress` is called as (done, total) on the main actor.
    static func applyAsync(_ suggestions: [AISuggestion],
                           items: [String: AIPromptItem],
                           store: MistakeObservationStore = .shared,
                           engine: PredictionEngine = .shared,
                           isStillOpen: ((UUID) -> Bool)? = nil,
                           progress: ((Int, Int) -> Void)? = nil) async -> Outcome {
        var outcome = Outcome()
        let openCheck = openChecker(store: store, isStillOpen: isStillOpen)
        let total = suggestions.count
        for (index, suggestion) in suggestions.enumerated() {
            applyOne(suggestion, items: items, store: store, openCheck: openCheck, outcome: &outcome)
            progress?(index + 1, total)
            await Task.yield()
        }
        engine.noteNewObservations()
        return outcome
    }

    // MARK: - per-item

    private static func openChecker(store: MistakeObservationStore,
                                    isStillOpen: ((UUID) -> Bool)?) -> (UUID) -> Bool {
        isStillOpen ?? { id in store.entries.first { $0.id == id }?.status == .open }
    }

    private static func applyOne(_ suggestion: AISuggestion,
                                 items: [String: AIPromptItem],
                                 store: MistakeObservationStore,
                                 openCheck: (UUID) -> Bool,
                                 outcome: inout Outcome) {
        guard let item = items[suggestion.id] else { return }
        let liveIDs = item.observationIDs.filter(openCheck)

        // If every observation for this item was already resolved elsewhere, skip global writes
        // so a stale AI answer can't re-add a rule or word to the dictionary.
        if liveIDs.isEmpty, !item.observationIDs.isEmpty {
            outcome.skippedStale += 1
            return
        }

        switch suggestion.action {
        case .rule, .merge:
            guard let rawTarget = suggestion.target, !rawTarget.isEmpty else { return }
            let source = HistoryWordActionPolicy.normalizedSource(item.source)
            guard let target = HistoryWordActionPolicy.sanitizedTarget(rawTarget),
                  !source.isEmpty,
                  source.caseInsensitiveCompare(target) != .orderedSame else { return }
            guard item.canCreateCoreRule(target: target, tag: suggestion.tag) else { return }

            Defaults[.autoFixAllowlist].removeAll {
                HistoryWordActionPolicy.normalizedSource($0).caseInsensitiveCompare(source) == .orderedSame
            }
            if !Defaults[.customAutoReplaceRules].contains(where: {
                HistoryWordActionPolicy.normalizedSource($0.source)
                    .caseInsensitiveCompare(source) == .orderedSame
            }) {
                Defaults[.customAutoReplaceRules].append(
                    CustomAutoReplaceRule(source: source, target: target, createdFromRecommendation: true)
                )
            }
            store.updateStatus(forIDs: liveIDs, to: .convertedToRule)
            outcome.rulesCreated += 1

        case .dictionary:
            IgnoreWordService.add(item.source)
            store.updateStatus(forIDs: liveIDs, to: .addedToDictionary)
            outcome.addedToDictionary += 1

        case .ignore:
            store.updateStatus(forIDs: liveIDs, to: .dismissed)
            outcome.ignored += 1
        }
    }
}
