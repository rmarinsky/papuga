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
- Escape or × dismisses the proposal without changing the dictionary. Papuga offers a labelled
  `Повернути підказку` action for 10 seconds while the exact text range remains unchanged.
- Further typing, caret movement, an external click, focus change, or a source-text mismatch
  invalidates that recovery action.
- Actions:
  - accept the replacement and create a custom rule when the proposal supports one;
  - explicitly choose `Ніколи не замінювати “…”` to add the source to the allowlist;
  - dismiss without learning a persistent preference.
- Automatic replacement, proposal acceptance, undo, and reapply replace only an exact validated
  Accessibility text range. The following space, Return, or Tab remains owned by the editor, so
  rich-text paragraph and list semantics are preserved.
- Undo affects only the current occurrence and offers `Застосувати знову` for 10 seconds.
- The feature is controlled by `autoFixProposalEnabled`, default `true`.
- The distance from threshold is controlled by the selected sensitivity preset (Balanced uses a
  `0.22` proposal window).

### Relevant decision signals

The decision history retains full text only for replacements, proposals, near-threshold misses,
real spelling suggestions, confirmed layout incidents, and verified mutation failures. Correct
words, short tokens, missing/identical candidates, allowlisted words, ordinary focus resets, and
far-below-threshold words are counted only in local daily aggregates. Those aggregates contain no
source text, candidate text, or application identity. Blocklisted and secure-input contexts record
nothing. Existing legacy rows remain on disk but the default history screen hides rows that do not
resolve to a useful signal.

### Spelling proposals

When the spelling guard finds a suggestion within the configured edit distance, Papuga presents it
through the same exact-range proposal. Spelling is proposal-only: accepting changes the current
occurrence, does not switch the keyboard layout, and does not create a custom rule. If no usable
suggestion exists, Papuga still suppresses the unsafe cross-layout conversion without retaining a
full-text history row.

### Whole-sentence layout incidents

A suspicious first word waits for a 750 ms grace period. A following printable key turns it into a
single in-memory incident instead of applying or proposing individual words. Papuga captures at
most 30 words or 300 UTF-16 code units and finalizes on sentence punctuation plus a boundary,
Return/Tab, or a 1.2-second pause after a completed word.

Automatic replacement requires at least three strong tokens, 75% support, no contradictions, and
a phrase margin above the active threshold. Two strong tokens with 60% support can produce one
whole-incident proposal even when the raw language coefficient is low. The final mutation uses one
anchored source range, preserves the trailing boundary, and produces one undo/reapply action.
Individual tokens inside the incident contribute only anonymous aggregate counts.

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

### Grammarly-style grammar context

Reliable full-field analysis is not currently safe enough for automatic replacement.

Reasons:

- Accessibility APIs do not expose editable text consistently across all apps.
- Browser fields are especially hard to classify safely.
- Reading full surrounding context is privacy-sensitive.
- Sentence-level grammar quality for Ukrainian needs real validation. The layout-incident tracker
  intentionally evaluates only keyboard-layout conversion, not grammar rewriting.

Recommended next step:

- Keep grammar suggestions separate from the local layout-incident path.
- Use proposals only when Papuga has enough surrounding context to explain the candidate.
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
