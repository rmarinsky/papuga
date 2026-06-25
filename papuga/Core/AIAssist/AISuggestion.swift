import Foundation

/// What Papuga should do with a flagged word, as decided by an external AI.
/// Maps 1:1 to a real write path:
///   .rule       -> CustomAutoReplaceRule(source -> target)
///   .dictionary -> IgnoreWordService.add(source)        (⚠️ irreversible: NSSpellChecker.learnWord, no unlearn)
///   .ignore     -> MistakeObservationStore.updateStatus(.dismissed)
///   .merge      -> several aliases share a clusterId; usually one rule on the canonical target
enum AISuggestionAction: String, CaseIterable, Equatable {
    case rule
    case dictionary
    case ignore
    case merge
}

/// How the AI categorised the item. Drives the chip colour + implied action.
enum AISuggestionTag: String, CaseIterable, Equatable {
    case layout       // wrong keyboard layout (ghbdtn -> привіт)
    case spelling     // ordinary misspelling
    case domain       // deliberate jargon/anglicism -> dictionary
    case confusable   // two real words the user swaps
    case gibberish    // noise -> hide
}

/// A validated, accepted AI suggestion, ready to be reconciled onto a MistakeGroupData.
/// `id` is the opaque round-trip alias (e.g. "m1"), never a real UUID.
struct AISuggestion: Identifiable, Equatable {
    let id: String
    let action: AISuggestionAction
    let target: String?
    let tag: AISuggestionTag
    let clusterId: String?
    let confidence: Double
    let reason: String
    /// True when a `rule` target could NOT be independently corroborated (script/edit-distance/
    /// layout-flip/engine-agreement). Such rules must NOT be auto-applied — surface for review.
    let needsReview: Bool
}

/// Severity of a validation finding, mirroring the «Перевірка» screen.
enum AIValidationSeverity: Equatable {
    case block   // nothing usable — hard stop
    case warn    // a bad item was dropped
    case info    // silently auto-corrected
}

/// One user-facing validation finding (Ukrainian message), optionally tied to an alias.
struct AIValidationIssue: Equatable {
    let alias: String?
    let message: String
    let severity: AIValidationSeverity
}

/// Everything the validator needs to know about the round-trip it generated.
/// Built by `AIPromptBuilder` alongside the prompt; the alias set is the source of truth.
struct AIRoundTripContext: Equatable {
    /// Aliases we actually sent this round (the only ids we will accept back).
    let knownAliases: Set<String>
    /// Aliases whose source word was truncated ("…") — never build a rule from these.
    let truncatedAliases: Set<String>
    /// alias -> the exact source word we sent (for self-replace + plausibility checks).
    let sourceForAlias: [String: String]
    /// alias -> language code ("uk"/"en") for plausibility script checks.
    let languageForAlias: [String: String]

    init(knownAliases: Set<String>,
         truncatedAliases: Set<String> = [],
         sourceForAlias: [String: String] = [:],
         languageForAlias: [String: String] = [:]) {
        self.knownAliases = knownAliases
        self.truncatedAliases = truncatedAliases
        self.sourceForAlias = sourceForAlias
        self.languageForAlias = languageForAlias
    }
}

/// Outcome of validating a pasted/returned AI answer.
struct AIValidationResult: Equatable {
    /// Non-nil means the whole answer was unusable (show this, offer regenerate).
    var blocked: AIValidationIssue?
    /// Accepted suggestions, ready to apply (after user confirmation).
    var recognized: [AISuggestion]
    /// Per-item findings (warn = dropped, info = auto-corrected).
    var issues: [AIValidationIssue]
    /// Known aliases the AI never answered — offer to re-prompt just these.
    var missingAliases: [String]

    var recognizedCount: Int { recognized.count }
    var attentionCount: Int { issues.filter { $0.severity == .warn }.count }
    var skippedCount: Int { missingAliases.count }
    var isBlocked: Bool { blocked != nil }

    init(blocked: AIValidationIssue? = nil,
         recognized: [AISuggestion] = [],
         issues: [AIValidationIssue] = [],
         missingAliases: [String] = []) {
        self.blocked = blocked
        self.recognized = recognized
        self.issues = issues
        self.missingAliases = missingAliases
    }
}
