# Papuga: research for unmatched grammar and spelling errors

Date: 2026-06-13

## Short answer

We can track a useful subset of mistakes that Papuga did not replace, but the safe MVP is not "track all grammar mistakes everywhere".

The practical MVP is:

- Track completed typed words at word boundaries when AutoFix did not apply a replacement.
- Run local spell checking on that token with `NSSpellChecker`.
- Infer manual corrections when the user deletes a just-typed word and retypes a better one.
- Store those observations in a separate local-only "Помилки" store.
- Let the user convert repeated observations into custom replacement rules through the existing rule editor.

Full sentence-level grammar is technically possible through Apple's grammar checking APIs, but it needs sentence context and has language-quality limits. For Ukrainian specifically, we should treat it as an experimental source, not as the first product promise.

## Current Papuga surface

Relevant existing code:

- `papuga/Core/AutoFixController.swift` already observes key events and keeps a `WordBuffer`.
- `papuga/Core/AutoFixDecision.swift` already uses `NSSpellChecker.shared.checkSpelling(...)` to avoid replacing valid words.
- `papuga/Models/ReplacementHistoryEntry.swift` stores applied, undone, and manual-switch replacement history.
- `papuga/Core/RecommendationEngine.swift` already creates recommendations from repeated manual switch pairs and repeated undone AutoFix events.
- `papuga/Views/Settings/RuleEditorSheet.swift` already has the right interaction model for creating custom rules.

This means we do not need a new global input pipeline for the MVP. We should extend the existing AutoFix boundary logic with a separate observation pipeline.

## Platform research

Apple AppKit has a built-in spelling and grammar stack:

- `NSSpellChecker` can check spelling and grammar in strings.
- `NSSpellChecker.checkSpelling(...)` starts searching for a misspelled word in a string.
- `NSSpellChecker.checkGrammar(...)` performs grammar analysis and returns details.
- `NSSpellChecker.requestChecking(...)` can request spelling/grammar/text checking asynchronously.
- `NSTextCheckingResult.CheckingType` includes `.spelling` and `.grammar`.
- `NSTextCheckingResult` is the result type AppKit uses for spelling, grammar, and correction actions.

Sources:

- Apple `NSSpellChecker`: https://developer.apple.com/documentation/appkit/nsspellchecker
- Apple `checkSpelling`: https://developer.apple.com/documentation/appkit/nsspellchecker/checkspelling%28of%3Astartingat%3Alanguage%3Awrap%3Ainspelldocumentwithtag%3Awordcount%3A%29
- Apple `checkGrammar`: https://developer.apple.com/documentation/appkit/nsspellchecker/checkgrammar%28of%3Astartingat%3Alanguage%3Awrap%3Ainspelldocumentwithtag%3Adetails%3A%29
- Apple `requestChecking`: https://developer.apple.com/documentation/appkit/nsspellchecker/requestchecking%28of%3Arange%3Atypes%3Aoptions%3Ainspelldocumentwithtag%3Acompletionhandler%3A%29
- Apple `NSTextCheckingResult`: https://developer.apple.com/documentation/foundation/nstextcheckingresult
- Apple `NSTextCheckingResult.CheckingType`: https://developer.apple.com/documentation/foundation/nstextcheckingresult/checkingtype

CoreGraphics event taps can receive key events when the process has the required access. Papuga already relies on this class of permission for its global typing behavior.

- Apple `CGEvent.tapCreate`: https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29

LanguageTool is a possible future grammar engine if we want better proofreading than Apple's system checker, especially for multi-language grammar/style checks. It can run as a local self-hosted HTTP server, but that would add a Java runtime/server dependency and should not be in the MVP.

- LanguageTool open-source/dev docs: https://languagetool.org/dev
- LanguageTool local HTTP server: https://dev.languagetool.org/http-server.html

## Feasibility matrix

| Signal | Feasible | Confidence | Notes |
| --- | --- | ---: | --- |
| Wrong-layout words Papuga can convert | Already supported | High | Stored as replacement history when applied or manual-switch history when user triggers switch. |
| Misspelled typed word that Papuga did not replace | Yes | High | Use current `WordBuffer` at boundary and `NSSpellChecker.checkSpelling`. |
| Suggestion for misspelled word | Yes | Medium | Use `NSSpellChecker.guesses(...)`, but suggestions are dictionary-dependent. |
| User deletes word A and retypes word B | Yes | High | Best source for rule creation because it gives us both source and target. Needs heuristic, not document access. |
| Sentence-level grammar issue while typing | Partially | Medium/Low | Needs rolling sentence buffer. Apple grammar quality is language-dependent. Store only if user opts in. |
| Existing mistakes in arbitrary text that user did not type during Papuga session | No, not reliably | Low | Would require reading app/document contents through Accessibility or clipboard-like workflows. Too invasive and inconsistent. |

## Recommended product shape

Add a separate sidebar section:

- `Помилки`

Inside it:

- Summary counters: `Нові`, `Повторювані`, `Створено правил`, `Ігноровано`.
- Filters: `Усі`, `Орфографія`, `Виправлено вручну`, `Граматика beta`, `За застосунком`.
- Rows grouped by normalized mistake:
  - observed source text;
  - suggested/corrected target if known;
  - count and last seen date;
  - source app;
  - confidence;
  - actions: `Створити правило`, `Ігнорувати`, `Додати в словник`.

Use the existing `RuleEditorSheet` for `Створити правило`. If the observation has no target, prefill only the source and ask the user to choose/enter the target.

## Data model proposal

Use a new store instead of extending `ReplacementHistoryEntry`.

```swift
struct MistakeObservation: Codable, Identifiable, Equatable {
    enum IssueType: String, Codable {
        case spelling
        case manualCorrection
        case grammar
        case layoutCandidate
    }

    enum Status: String, Codable {
        case open
        case dismissed
        case convertedToRule
        case addedToDictionary
    }

    let id: UUID
    let timestamp: Date
    let source: String
    let suggestedTarget: String?
    let issueType: IssueType
    let language: String
    let bundleID: String?
    let confidence: Double
    let status: Status
    let contextHash: String?
}
```

Storage rules:

- Local-only JSON store, same style as replacement history.
- Max stored text length: reuse the existing 80 character limit.
- Default retention: 30 days for raw observations.
- Aggregate counts can live longer if they do not store context.
- Do not store anything when secure input is active or the focused app is blocked.
- Do not store URLs, emails, tokens with digits, or very long strings.

## Pipeline proposal

### 1. Observation hook

Add a `MistakeObservationEngine` and call it from `AutoFixController` when a word boundary is reached and AutoFix did not apply a replacement.

Inputs:

- completed word;
- current layout ID;
- inferred language;
- active bundle ID;
- AutoFix skip/replacement decision;
- whether the word was on allowlist/blocklist.

### 2. Spelling detector

Use `NSSpellChecker.checkSpelling(...)` on the completed word.

Record an observation only when:

- the token passes the same safety filters as AutoFix;
- the word is not in allowlist;
- the spelling checker flags it;
- Papuga did not already create an AutoFix replacement;
- the user enabled mistake tracking.

If `NSSpellChecker.guesses(...)` returns a useful suggestion, store it as `suggestedTarget`.

### 3. Manual correction inference

Track a small rolling edit state:

- user types word `A`;
- user hits backspace/delete enough times to remove `A`;
- user types word `B` in the same short time window;
- `A` is misspelled or uncommon, `B` is valid or repeatedly used;
- edit distance is small enough, or keyboard-neighbor/layout similarity is high.

Then record `A -> B` as `.manualCorrection`. This is the highest-value signal for custom rules.

### 4. Grammar detector beta

Keep a rolling sentence buffer only when the user explicitly enables `Граматика beta`.

Constraints:

- max 250-300 characters;
- flush on app switch, field switch signal, timeout, return, or punctuation;
- run `requestChecking` with `.grammar` and `.spelling`;
- store only the flagged phrase/range, not the whole sentence, unless the user opts into context storage.

This should be behind a feature flag until we test real Ukrainian/English quality.

## Rule-generation algorithm

Extend `RecommendationEngine` with mistake observations:

1. Normalize source/target by lowercasing and trimming punctuation.
2. Group by `source + target + language + bundleID?`.
3. Score:

```text
score =
  repeatedCountWeight
  + recencyWeight
  + manualCorrectionSourceBonus
  + spellCheckerSuggestionBonus
  - dismissedPenalty
  - autoFixUndoPenalty
```

4. Use the same Fibonacci-style thresholds that Papuga already uses: `3, 5, 8, 13, 21`.
5. Show recommendations:
   - `Створити правило: source -> target`
   - `Додати source у словник`
   - `Не трекати такі помилки в цьому застосунку`

This keeps the "own algorithm" deterministic and explainable. No cloud AI should be used by default because the data is raw typed text.

## Privacy requirements

This feature must be opt-in.

Required controls:

- Master switch: `Збирати мої помилки локально`.
- Separate switch: `Граматика beta`, because it needs phrase/sentence context.
- App blocklist reuse.
- One-click `Очистити всі помилки`.
- Per-row dismiss/delete.
- Data retention selector: `7 / 30 / 90 днів`.
- UI copy that clearly says data is stored locally and not sent anywhere.

Do not collect:

- secure input;
- URLs/emails;
- numbers/codes;
- password-manager apps;
- terminal-like apps by default;
- private browser contexts if we can reliably detect them. If not, rely on app blocklist and conservative browser defaults.

## Implementation plan

### Phase 1: safe observations

- Add `MistakeObservation` model.
- Add `MistakeObservationStore`.
- Add setting keys for opt-in, retention, and grammar beta.
- Add `MistakeObservationEngine` with `SpellCheckingClient` protocol for testability.
- Hook spelling observations from `AutoFixController` after word boundary evaluation.
- Add unit tests with mocked spelling results.

### Phase 2: UI

- Add `Помилки` sidebar destination.
- Build list-first SwiftUI view using the current Papuga card/list style.
- Wire `Створити правило` into `RuleEditorSheet`.
- Add empty state and privacy controls.
- Extend AppleScript smoke test to click the new section and create a rule from a seeded observation.

### Phase 3: manual correction inference

- Add rolling edit-state tracker.
- Detect `source -> target` corrections.
- Aggregate repeated corrections into recommendations.
- Add tests for delete/retype sequences and false-positive cases.

### Phase 4: grammar beta

- Add rolling sentence buffer.
- Use `NSSpellChecker.requestChecking` with `.grammar`.
- Keep this behind a setting and verify language quality on real samples before exposing it prominently.

### Phase 5: optional advanced engine

- Evaluate local LanguageTool integration only if Apple grammar is not enough.
- Avoid bundled server/runtime in the first implementation.
- If cloud or external processing is ever added, it must be a separate explicit setting with clear data disclosure.

## Main risks

- Storing raw mistakes is sensitive. The feature must be local-only and opt-in.
- Grammar quality for Ukrainian may be weak with Apple APIs.
- Accessibility cannot reliably read surrounding document context across all apps.
- Browser fields are hard to classify safely.
- False positives can annoy users if we recommend rules too early.

## Recommendation

Implement `Помилки` in two tracks:

1. Now: spelling observations and manual correction inference.
2. Later: grammar beta after real sample validation.

This gives us useful rule-generation data without pretending we can reliably audit every sentence a user writes across macOS.
