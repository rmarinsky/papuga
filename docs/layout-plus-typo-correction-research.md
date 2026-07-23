# Layout plus typo correction research

Date: 2026-07-23

## Question

How should Papuga distinguish and safely handle:

1. an ordinary typo in the active layout;
2. text entered in the wrong keyboard layout;
3. text entered in the wrong layout with one or more typos;

without ever recommending a layout-converted target that is itself broken or unlike a valid word?

## Executive recommendation

Keep the existing layout mapper, spell checker, language scorer, proposal UI, and decision journal. Change the decision from “score one converted string” to “compare explicit hypotheses”:

| Hypothesis | Candidate generation | Initial action policy |
| --- | --- | --- |
| `asTyped` | Original token | Keep when valid in the active language |
| `spelling` | Spell suggestions for the original token in the active language | Proposal only, as today |
| `layout` | Exact physical-key conversion to every configured target layout | Auto-replace only when the final target is dictionary-valid and unambiguous |
| `layoutThenSpelling` | Exact layout conversion, then target-language spell suggestions | Proposal only; no automatic replacement until measured data justifies it |

The critical invariant should be:

> A language-identification score can rank candidates, but it can never make an invalid target eligible.

For `layoutThenSpelling`, conversion must happen first. A physical-key typo survives layout conversion as a typo in the intended script, where the target-language spell checker can repair it. For example, `ghbdn` maps to Ukrainian `привт`, after which a target-language suggestion may yield `привіт`. Spell-correcting `ghbdn` as English first asks the wrong dictionary to explain wrong-layout text.

If both a same-layout spelling candidate and a layout-plus-spelling candidate are valid and close, Papuga should do nothing. This is an ambiguity rejection, not a missed correction. The proposal UI should receive only a target that already passed the same validity gates required for an automatic replacement.

## What Papuga does now

### Candidate generation and selection

`AutoFixController.evaluateAndMaybeFix` currently:

1. guards the editing context, target app/range, allowlist, protected lexicon, and custom rules;
2. maps the source token from the active layout to every configured target layout with `CharacterMapper`;
3. scores the original and each mapped string with `LanguageScorer` / `AppleNLScorer`;
4. chooses the best target using the language-score margin and target-separation settings;
5. protects a correctly spelled original word;
6. checks whether the original is probably an ordinary typo in the current language;
7. otherwise allows the selected layout candidate to continue toward a proposal or replacement.

Relevant implementation: `papuga/Core/AutoFixController.swift`, `papuga/Core/AutoFixCandidateGenerator.swift`, `papuga/Core/AutoFixDecision.swift`, and `papuga/Core/CharacterMapper.swift`.

`CharacterMapper` uses the installed macOS input source rather than a hard-coded Ukrainian/English table. It resolves the character to a physical key and then asks the target layout what that key emits. Apple's `UCKeyTranslate` maps a virtual key code plus modifier and dead-key state through a Unicode keyboard-layout resource, which matches Papuga's conversion model ([Apple `UCKeyTranslate`](https://developer.apple.com/documentation/coreservices/1390584-uckeytranslate)). CLDR also treats keyboard data as mappings that transform keystrokes or text, while noting that pre-existing platform layouts remain platform-specific ([Unicode LDML Part 7: Keyboards](https://www.unicode.org/reports/tr35/tr35-keyboards.html)). Therefore Papuga should continue using the actual installed input-source maps instead of introducing a second static layout database.

### Existing typo protection

`AutoFixDecision.spellingTypoGuardAssessment` already asks the current-language spell checker for suggestions and suppresses cross-layout replacement when a suggestion is within one Damerau-style edit. Existing tests cover `fster → faster`, `wrold → world`, and `важлво → важливо`.

This correctly handles the second hypothesis (`spelling`) but not the fourth (`layoutThenSpelling`). The current guard asks the source-language dictionary about the original token; it does not ask the target-language dictionary about the converted token.

### The unsafe gap

The chosen direct layout candidate is not required to be a valid target-language word before it can reach `applyFix` or `maybeShowProposal`. `layoutIncidentEvidence` checks source and target spelling, but a cross-script candidate can still become `strong` through `shouldSuggestSingleTokenLayoutMistake` even when the target spell checker says it is invalid. In other words, target validity is currently evidence, not an eligibility gate.

This matters because Apple's Natural Language API performs language identification by first identifying dominant script and then language, and exposes language hypotheses with probabilities ([Apple `NLLanguageRecognizer`](https://developer.apple.com/documentation/naturallanguage/nllanguagerecognizer), [Apple language-identification guide](https://developer.apple.com/documentation/naturallanguage/identifying-the-language-in-text)). It is not a spelling or lexical-validity API. A high Ukrainian score for a Cyrillic-shaped string therefore cannot establish that the string is a Ukrainian word. This is why raising the existing language-score threshold alone cannot satisfy the safety requirement.

`NSSpellChecker`, by contrast, directly exposes spelling checks and word guesses for a specified language ([Apple `NSSpellChecker`](https://developer.apple.com/documentation/appkit/nsspellchecker)). Apple does not expose a documented calibrated confidence value for each returned guess, so Papuga should validate guesses itself and tune its own acceptance policy on a corpus rather than treating list position as a probability. This last sentence is a design inference from the public API surface, not a claim about Apple's private ranking algorithm.

### Reusable components already present

No new dependency or model is needed for the first safe version:

- `CharacterMapper`: exact installed-layout conversion.
- `SystemSpellCheckingClient`: current-language and target-language word validity and guesses.
- `AutoFixDecision.spellingEditDistance`: insertion, deletion, substitution, and adjacent transposition distance.
- `KeyboardAdjacency`: physical-neighbour substitutions.
- `WordPlausibility`: cheap garbage rejection.
- `AutoFixCandidateGenerator`: target-layout ranking and runner-up ambiguity.
- `AutoFixProposalCoordinator`: non-destructive, exact-range proposals.
- `AutoFixDecisionHistoryStore`: outcomes and later threshold evaluation.
- `SymSpell`, `HybridSpellChecker`, and `DictionaryBuilder`: existing optional seams for deterministic local candidate generation; they are not currently wired into live `AutoFixController` and no bundled `frequency_<language>.txt` resources are present.

The current `SymSpell` implementation is a natural future performance optimization, not a prerequisite. The owning SymSpell project describes symmetric deletes as a way to reduce candidate-generation and dictionary-lookup work within a Damerau-Levenshtein distance ([official SymSpell repository](https://github.com/wolfgarbe/SymSpell)).

## Proposed candidate pipeline

The following is a design recommendation tailored to the existing code, not behavior supplied by Apple or Unicode.

### 1. Normalize without changing evidence

Keep the raw token for range replacement and history. Derive a core token only by removing the edge punctuation already recognized by Papuga. Preserve case separately and reapply it only after a candidate is accepted.

Reject automatic mutation for URLs, emails, domains, digits, mixed code-like punctuation, edit fragments, changed target sessions, and protected/allowlisted tokens using the current guards.

For script checks, use script as a gate, not proof of language. Unicode defines `Script` and `Script_Extensions` as character properties and explicitly distinguishes scripts from Unicode blocks; `Common` and `Inherited` characters require contextual handling ([Unicode Standard Annex #24](https://www.unicode.org/reports/tr24/)). Papuga's current hard-coded Latin and Cyrillic scalar ranges are adequate for the current EN/UK/RU scope, but a general multi-language implementation should move to Unicode script properties rather than adding more block ranges.

### 2. Generate all four hypotheses

For a token `x` in active layout/language `Ls`:

1. `asTyped`: `x`.
2. `spelling`: up to eight `spellChecker.guesses(x, Ls)`, filtered to single tokens and a tight edit radius.
3. `layout`: for each configured target layout `Lt`, calculate `y = CharacterMapper.convert(x, Ls, Lt)`.
4. `layoutThenSpelling`: only when `y` is invalid in `Lt`, request target-language guesses for `y` and retain close valid suggestions `z`.

Do not generate `spell source → convert suggestion` in the first version. A source-language suggestion is useful evidence for the ordinary-typo hypothesis, but converting it compounds two inferences and can produce a plausible unrelated target. `convert → spell target` follows the user's physical action and asks the intended-language dictionary to repair the remaining typo.

This is the same general decomposition used by noisy-channel spelling correction: candidate plausibility and the probability of the observed error are separate signals. Brill and Moore model spelling correction by combining an error model with a language/word model rather than accepting candidates from edit distance alone ([Brill & Moore, ACL 2000](https://aclanthology.org/P00-1037/)). Papuga does not need their model; the relevant design lesson is to keep “valid intended word” separate from “plausible path from typed input.”

### 3. Apply hard validity gates before scoring

A candidate is eligible only if all applicable checks pass:

- It differs from the source and remains within the exact validated replacement range.
- Its letters belong to the target script, allowing `Common`/`Inherited` punctuation or marks only at established token boundaries.
- It is a single token and passes the existing protected/code/URL filters.
- `spellChecker.isMisspelled(candidate, targetLanguage) == false`, or it is explicitly present in Papuga's allowlist, protected lexicon, learned-known vocabulary, or a user-confirmed rule target.
- A `layoutThenSpelling` candidate is within edit distance 1 of the direct converted token for the initial release.
- `WordPlausibility.isWordLike` may reject garbage, but may not make an unknown word valid. A vowel/consonant heuristic is not a dictionary.

Damerau's original spelling-correction formulation focused on one insertion, deletion, substitution, or adjacent transposition ([Damerau, 1964](https://doi.org/10.1145/363958.363994)). That supports Papuga's existing one-edit starting point. It does not prove that every distance-one candidate is correct, so distance remains an error-cost feature behind lexical validity and ambiguity checks.

### 4. Rank only eligible candidates

Use an ordered evidence tuple instead of adding unrelated numbers into a pseudo-probability:

1. user-confirmed target / learned rule;
2. dictionary-valid final word;
3. hypothesis cost: direct layout before layout-plus-one-typo before larger edits;
4. current `NLLanguageRecognizer` target score;
5. current language-margin and target-layout separation;
6. edit distance;
7. keyboard adjacency for a substitution;
8. stable deterministic tie-break.

Keyboard adjacency should lower the error cost of a candidate, not bypass dictionary validity or ambiguity rejection. The existing key-code-based implementation is preferable to character-specific tables because it follows the same physical keys across configured layouts.

Do not interpret Apple language-hypothesis values, edit similarity, or current fixed confidences (`0.82`, `0.78`, and similar) as mutually calibrated probabilities. Keep them as ranking features until measured against Papuga's corpus.

### 5. Decide with a fail-closed matrix

| Evidence | Result |
| --- | --- |
| Original is valid in active language | Keep; no layout proposal |
| Original invalid; one close source-language spelling candidate; no clear layout candidate | Spelling proposal only |
| Original invalid; direct converted target valid; target wins existing language and separation gates | Existing layout auto-fix policy may apply |
| Original invalid; direct converted target invalid; exactly one close valid target-language repair; no competing source typo | Layout-plus-typo proposal only |
| Both normal-typo and layout-plus-typo hypotheses are plausible | Abstain; record ambiguity without retaining unnecessary full text |
| Two target layouts or two repaired targets are close | Abstain or show no proposal in the first version |
| Final target invalid or only “word-like” | Never propose or replace |

Failing closed intentionally trades coverage for correctness. Selective-classification research formalizes this as a risk/coverage trade-off: a system can reject uncertain cases to raise accuracy on the cases it accepts ([El-Yaniv & Wiener, JMLR 2010](https://jmlr.org/papers/v11/el-yaniv10a.html)). Papuga's asymmetric cost makes this appropriate: leaving a typo untouched is cheaper than silently replacing it with unrelated text.

## Confidence and threshold policy

The following thresholds are launch policy, not sourced constants:

- Preserve the current language-margin and target-layout separation for already-valid direct layout conversions; retune only from evaluation data.
- Require edit distance `<= 1` from direct conversion to repaired target for `layoutThenSpelling` initially.
- Require one unique repaired target after normalization. If multiple target spell suggestions survive at the same distance, abstain regardless of their returned order.
- Keep every `layoutThenSpelling` case proposal-only for the first release.
- Do not auto-promote the composite path based on acceptance count alone. Consider auto-replacement only after a held-out corpus shows the required false-positive bound per language/layout pair and production undo/rejection remains below the agreed limit.
- Keep the proposal threshold separate from the auto-replacement threshold. A candidate can be safe to show but not safe to mutate automatically.

The current `autoFixThreshold` and `autoFixCandidateSeparation` compare language scores. Add no new user-facing sliders for the composite path. Internal policy should be corpus-calibrated; the existing Careful/Balanced/More Hints presets can continue controlling whether an already-safe candidate is shown, while the new validity gates remain non-configurable.

## Minimal implementation shape

This is not an implementation request; it identifies the smallest seams for later work.

1. Extract or extend the existing candidate generation near `AutoFixController.evaluateAndMaybeFix` so each target layout produces:
   - direct converted token;
   - direct target validity;
   - at most a few target-language repaired candidates with edit distance.
2. Make target validity a hard gate before `shouldReplace`, `handleLayoutIncidentToken`, and `maybeShowProposal`.
3. Compare the best current-language spelling hypothesis with the best layout hypothesis before selecting an action.
4. Reuse `AutoFixProposal.Kind.detected` for user interaction, but record a distinct decision origin such as `keyboardLayoutSpelling`; otherwise evaluation cannot separate pure-layout from composite cases.
5. Persist the direct converted form, selected repaired target, edit distance, competing-hypothesis class, and abstention reason only for reviewable signals; retain the current aggregate-only privacy behavior for ordinary skips.
6. Add one focused pure decision test table before touching event-tap behavior.

Do not wire the full background `PredictionEngine` into the real-time event tap. The live controller already has the necessary lightweight spell-check seam, and the background engine has different caching and ranking goals.

## Required regression cases

At minimum, a later implementation should prove:

- `fster` in English: propose `faster`; never convert to Cyrillic.
- `wrold` in English: transposition proposal `world`; never convert.
- `ghbdsn` in English layout: direct conversion `привіт` is valid and eligible.
- `ghbdn` in English layout: direct conversion `привт` is invalid; only a validated target-language repair such as `привіт` may be proposed.
- `руддщ` in Ukrainian layout: direct conversion `hello` is valid and eligible.
- a source token whose direct conversion is invalid and has no close valid target repair: no proposal and no replacement even when the target language score is high.
- a token with a valid normal-typo correction and a valid layout-plus-typo correction: abstain.
- a source with two close target layouts (for example UK/RU): abstain unless the existing separation requirement is met after final-target validation.
- proper names, domain terms, code identifiers, mixed-script text, URLs, emails, punctuation-bearing tokens, and learned vocabulary: preserve current protection.
- accepted composite proposal: exact-range replacement, correct target layout switch, one undo/reapply action, and decision origin retained as composite.

## Evaluation corpus and metrics

This section is a Papuga-specific design proposal.

### Corpus construction

Create a versioned, reviewable corpus split by intended word, not by generated typo, to prevent variants of the same word leaking into train and test sets. Keep separate buckets:

1. **Clean negatives:** correctly typed EN/UK/RU words, proper names, product vocabulary, abbreviations, code identifiers, mixed-language text, URLs, and punctuation cases. These are the primary false-positive set.
2. **Ordinary typos:** insertion, deletion, substitution, adjacent transposition, repeated key, and adjacent-key substitution in the active layout.
3. **Pure layout errors:** valid words converted through every real configured source/target layout pair.
4. **Layout plus typo:** apply exactly one controlled typo to the intended target keystrokes, then emit them through the wrong layout. Include every edit type and both adjacent/non-adjacent substitutions.
5. **Ambiguity/adversarial cases:** valid candidates in multiple languages, source-typo versus layout-plus-typo collisions, short tokens, proper nouns absent from the system dictionary, and converted strings that have the right script but are not words.

Use user-confirmed accept/undo/never-replace observations as a second, sequestered real-world set. Do not use the same observations to choose thresholds and report final quality. Record macOS version, enabled layouts, and dictionary/lexicon snapshot because the live system checker is an external dependency.

Synthetic composite generation must operate on physical key codes and real layout maps, not transliteration. This ensures that punctuation, Shift, and layout-specific keys exercise the same `CharacterMapper` path as production.

### Metrics

Report metrics by hypothesis class, language pair, token length, app policy, and known-vocabulary status:

- **Broken-target rate:** fraction of shown/applied targets that fail the final target validator. Required: `0`.
- **Clean false-replacement rate:** automatic layout changes on clean negatives. Required launch gate: `0` in the frozen regression corpus.
- **Wrong-operation rate:** layout action chosen when the gold case is an ordinary typo, or spelling-only action chosen for a layout error.
- **Auto-fix precision:** correct automatic replacements / all automatic replacements.
- **Proposal precision:** accepted gold target / all shown proposals.
- **Candidate recall:** gold target appeared anywhere among valid candidates.
- **Coverage:** fraction auto-fixed, proposed, and abstained separately.
- **Top-two margin distribution:** measured separately for correct and incorrect selections; use it to set separation, not intuition.
- **Production rejection signals:** undo, proposal dismissal, “never replace,” manual retyping, and per-app mutation failure.

Optimize for false-positive constraints first, then maximize coverage. A single aggregate accuracy number would hide the exact failure the user cares about: rare destructive changes among many easy correct cases.

## Final conclusion

Papuga should not try to infer “wrong layout plus typo” by relaxing its current layout score. It should explicitly generate `convert → target-language spell repair`, require the repaired output to be a valid word, compare it against the ordinary-typo hypothesis, and abstain whenever the hypotheses compete.

The first safe release can be small: one additional candidate path, one hard target-validity gate shared by proposals and replacements, one ambiguity check, and one new decision-history origin. No new dependency, neural model, or user-facing setting is required.
