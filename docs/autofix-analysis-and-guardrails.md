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

- If Backspace/Delete happens while Papuga's buffer is empty, the next token is treated as an edit fragment and AutoFix skips it; later tokens resume normally.
- If cursor navigation happens through arrow/home/end/page keys, only the next token is skipped.
- Escape and ordinary backspace inside the current typed buffer do not suppress AutoFix.
- The guard is controlled by `autoFixConservativeEditingGuard`, default `true`.

This directly targets the "editing a word deletes part of the word" class of bugs.

### New skip reason

Analytics skip reason:

- `editing_context`

This lets us distinguish a real missed AutoFix from a deliberate guardrail skip.

Web editors may recreate their accessibility proxy while typing. Target validation therefore uses
the logical field identity plus expected caret movement, and falls back from `AXStringForRange` to
an exact UTF-16 slice of the full `AXValue` when the editor does not expose the parameterized API.

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

A suspicious first word normally waits for a 300 ms grace period. A safe, unambiguous replacement
whose candidate score is displayed as 100% bypasses that grace period and applies immediately.
A following printable key turns other candidates into a single in-memory incident instead of
applying or proposing individual words. Papuga captures at most 30 words or 300 UTF-16 code units
and finalizes on sentence punctuation plus a boundary, Return/Tab, or a 600 ms pause after a
completed word.

Automatic replacement requires at least three strong tokens, 75% support, no contradictions, and
a phrase margin above the active threshold. Two strong tokens with 60% support can produce one
whole-incident proposal even when the raw language coefficient is low. The final mutation uses one
anchored source range, preserves the trailing boundary, and produces one undo/reapply action.
Individual tokens inside the incident contribute only anonymous aggregate counts.

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

## Tests added

- `AutoFixEditingGuardTests`
- `RecommendationEngineTests`

The key regression now covered: a token after external edit context is skipped instead of being treated as a normal whole word.


## Local layout evidence (2026-10-12)

The normal autocorrect scorer now combines bundled Ukrainian/English word frequencies
with a compact character-trigram model. Other languages use macOS language scoring;
all candidates still require the existing spelling and editing safety gates. The saved
`appleNL` setting remains compatible and selects this local scorer. No cloud requests,
new activation switch, or model download is required. Scores are ranking signals, not
calibrated probabilities of correctness.

Layout language comes from macOS input-source metadata. Conversion uses the actual
source and target Unicode keyboard tables, including Option modifiers and dead-key
sequences. Unknown or non-Unicode input methods are not treated as English. This does
not provide general IME composition support. Exact dictionary evidence can support
same-script conversion only with a reversible mapping and a misspelled source.

Personal learning uses at most 2,000 retained manual/undo records. Only manual records
with successful focused-field insertion readback can teach word pairs and preceding-word
context. Legacy, copy-only, unverified, truncated, unchanged, and non-layout conversions
cannot teach. Repeated attempts within 60 seconds in one app count as one episode.
Three separated verified episodes in the same context can resolve a unique target among
otherwise dictionary-valid alternatives; conflicting preferences remain suggestions.
Undo retracts older pair evidence, and clearing history removes learned evidence.
Validated pairs and input sources are cached; normal updates do not reconvert retained
phrases. The temporary full-field readback is bounded to 65,536 UTF-16 units and is not
persisted. Editors without usable readback can still convert but cannot teach from it.

Verification uses unit and in-process integration tests with real macOS layout tables.
Test hosts do not start keyboard services or show application windows. XCUI and live
editor typing checks were intentionally not run. Cross-app insertion reliability is
therefore not established by these checks. Existing toast, history, and Undo flows remain
the feedback path; this change does not add sentence-level grammar generation.


## Punctuation and proposal audit records (2026-10-15)

The word evaluator checks source spelling on the token core independently of target
interpretation. Correct words such as `інші?`, `одягу,`, and `рух))` stay in their
source language. A verified leading-key conversion such as `];f` → `їжа` can still
consume physical letter keys. Existing ambiguity between `те` and `теж` remains a
suggestion for `nt;`; punctuation is not blanket-stripped from layout conversions.

A compound layout-plus-spelling guess now requires a lexical mapped token and the
configured layout-score margin before consulting the target dictionary. A target
spelling guess cannot create evidence that the source layout was wrong. Ambiguous
punctuation and weak evidence are left unchanged rather than being used to generate
a compound suggestion. This conservative gate can miss genuine layout-plus-typo
cases; relaxing it requires evidence from verified corrections and regression cases.

All proposal producers write the actual displayed candidate under the proposal ID.
Resolution events use that same ID. Proposal context records its kind and the bounded
source core/edge punctuation; compound suggestions have no fabricated effective score.
Delayed word/phrase presentations no longer write a second proposed decision, and
reopening a recovery panel does not add a new presentation record. Older records
without proposal context still decode; their missing linkage cannot be reconstructed.

Regression checks cover the reported punctuation failures, genuine punctuation-key
conversions, low-evidence compound guesses, and controller-to-JSONL recording using a
temporary store. They do not type into applications or start XCUI automation.

Proposal action callbacks append `auto_fix_proposal_resolved` with `proposal_id` and
`outcome` (`accepted`, `dismissed`, `timed_out`, or `never_replace`). These events
contain no source or candidate text. `accepted` records the user's choice, not
proof of insertion; a successful `auto_fix_applied` event carries the same
`proposal_id` separately. Recovery can produce a later choice for the same proposal.
