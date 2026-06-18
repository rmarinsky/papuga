# Papuga AutoFix: analysis and guardrails

Date: 2026-06-13

## What was risky

AutoFix works from a typed-word buffer, not from the full text field. That is fine when the user types a fresh word from left to right, but it is risky when the user edits existing text.

Risky cases:

- User clicks into the middle/end of an existing word and types a fragment.
- User moves the cursor with arrows and edits a fragment.
- User backspaces after a completed word, then retypes only part of it.
- User selects/replaces text in an app where Papuga cannot reliably inspect the surrounding text.
- A short fragment looks like wrong-layout text and passes language scoring.

The bug pattern is: Papuga thinks the current buffer is the whole word, deletes `buffer.count + boundary.count`, and can remove part of the existing edited word.

## Implemented guardrails

### Conservative editing guard

New helper:

- `papuga/Core/AutoFixEditingGuard.swift`

Behavior:

- If Backspace/Delete happens while Papuga's buffer is empty, the next token is treated as an edit fragment and AutoFix skips it.
- If cursor navigation happens through arrow/home/end/page keys, the next token is skipped.
- Escape and ordinary backspace inside the current typed buffer do not suppress AutoFix.
- The guard is controlled by `autoFixConservativeEditingGuard`, default `true`.

This directly targets the "editing a word deletes part of the word" class of bugs.

### New skip reason

Analytics skip reason:

- `editing_context`

This lets us distinguish a real missed AutoFix from a deliberate guardrail skip.

### Mistake observations instead of forced replacement

When AutoFix skips because the score is below threshold, maps are missing, or the candidate is identical, Papuga can now record a local observation if mistake tracking is enabled.

That means the safer path is:

1. Do not mutate text in ambiguous contexts.
2. Store a local observation.
3. Let the user create a rule from repeated observations.

### Compact proposal UI

Implemented files:

- `papuga/Core/AutoFixProposal.swift`
- `papuga/Core/AutoFixProposalCoordinator.swift`

Behavior:

- If a candidate is below the AutoFix threshold but close enough to it, Papuga shows a small non-blocking proposal near the cursor.
- The proposal never steals focus from the target app.
- Any further typing or external click dismisses the proposal.
- Actions:
  - accept the replacement once;
  - accept and create a custom rule;
  - add the original word to the allowlist;
  - dismiss once for the current session.
- The feature is controlled by `autoFixProposalEnabled`, default `true`.
- The distance from threshold is controlled by `autoFixProposalWindow`, default `0.12`.

## Implemented mistake pipeline

New files:

- `papuga/Models/MistakeObservation.swift`
- `papuga/Core/MistakeObservationStore.swift`
- `papuga/Core/MistakeObservationEngine.swift`
- `papuga/Views/History/MistakesView.swift`

Behavior:

- Master opt-in is off by default.
- Observations are local-only JSONL.
- Retention is configurable: 7, 30, or 90 days.
- Spelling observations use `NSSpellChecker`.
- Manual correction inference detects repeated `source -> target` corrections after delete/retype.
- Repeated observations feed `RecommendationEngine`.
- `Помилки` sidebar section lets the user create a rule, add to allowlist, or ignore.

## What still needs more design before implementation

### Grammarly-style full context

Reliable full-field analysis is not currently safe enough for automatic replacement.

Reasons:

- Accessibility APIs do not expose editable text consistently across all apps.
- Browser fields are especially hard to classify safely.
- Reading full surrounding context is privacy-sensitive.
- Sentence-level grammar quality for Ukrainian needs real validation.

Recommended next step:

- Build a compact proposal UI, not automatic mutation.
- Use it only when Papuga has high confidence and enough context.
- Keep full-context grammar behind a separate beta toggle.

### Future algorithm improvements

- Track per-app false-positive rate.
- Increase threshold automatically in apps with repeated undos.
- Lower confidence for short tokens and mixed punctuation.
- Add a cooldown after undo so the same word is not proposed again in the same session.
- Use observations to propose rules instead of mutating ambiguous text.

## Tests added

- `AutoFixEditingGuardTests`
- `ManualCorrectionTrackerTests`
- `MistakeObservationEngineTests`
- `RecommendationEngineMistakeTests`

The key regression now covered: a token after external edit context is skipped instead of being treated as a normal whole word.
