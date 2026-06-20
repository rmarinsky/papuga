# Mistakes-screen performance benchmark

Living record of the optimization loop for the "Помилки введення" screen.

## How to run

```bash
# Heavy benchmarks are gated; data is read live from
# ~/Library/Application Support/papuga/mistake-observations.jsonl
# (override with PAPUGA_BENCH_DATA=/path). Nothing private is committed.
TEST_RUNNER_PAPUGA_BENCH=1 xcodebuild test \
  -project papuga.xcodeproj -scheme papuga -destination 'platform=macOS' \
  -only-testing:papugaTests/MistakesScreenBenchmarkTests
```

Files: `MistakesBenchmarkSupport.swift` (spell-checker doubles, real-data loader,
render-cost model), `MistakesScreenBenchmarkTests.swift` (benchmarks),
`SpellCheckerLanguageProbeTests.swift` (uk-dictionary diagnostic),
`papuga/Core/MistakesScreenDerivation.swift` (behaviour-preserving extraction of
the screen's derivation pipeline — the single source of truth to render from).

## Dataset (real, captured)

1019 observations → **819 open groups** on "Усі / Увесь час", 57 repeated, 88% `uk`.
The extraction reproduces this grouping exactly (correctness test).

## Metrics

- **M1 call counts** — NSSpellChecker calls per render (deterministic).
- **M2 wall-clock** — real NSSpellChecker, cold (fresh) + warm (reused analyzer).
- **M3 save path** — wall-clock + rewrites/invalidations to mark a group.

## Ukrainian dictionary probe (verdict)

macOS **has** a working `uk` dictionary (10/10 correct words recognised; good
guesses; not a Russian fallback). The flood of "errors" is **domain
false-positives** — tech jargon/anglicisms (`пофіксити`, `фідбек`, `дев`) absent
from the standard dictionary. → A custom/domain dictionary (SymSpell) is a
false-positive *and* speed win, not a correctness fix.

## Results

| Metric | Baseline | After cycle 1 (QW3+QW4) | Δ |
|---|---|---|---|
| Render #1 (cold, open tab) | 4925 ms / 1530 calls | 4925 ms / 1530 calls | — (needs QW2) |
| Render #2 (warm: modal, scroll, save) | 4657 ms / 1650 calls | **28 ms / 0 calls** | **~166×** |
| Save group of 7 ("Створити правило") | 62 ms + **7** re-renders (~33 s) | 10 ms + **1** re-render (~38 ms) | **7× disk, ~870× felt** |

### Cycle 1 — implemented
- **QW3** `MistakeSuggestionAnalyzer` candidate cache keyed by
  (source, language, recordedTargets, layouts). Re-render NSSpellChecker calls
  1530 → 0; warm render 4657 ms → 28 ms.
- **QW4** `MistakeObservationStore.updateStatus(forIDs:)` — one pass, one disk
  rewrite, one `entries` mutation. Marking a group: N rewrites/invalidations → 1.

Fixes: "модалка відкривається довго" and "створення дуже довге".

## Redesign (decided direction)

Not "make the old screen faster" but a **prediction engine + live-scanner UI**:
compute similarities across all history, in the background, cached, and show the
process visually. Ranking = frequency × confidence ("найчастіші + найбільш
схожі"), not chronology. Differentiator: keystroke/keyboard-adjacency typo model
(language-agnostic). Engine mode: continuous background (economy) + on-demand
"Переаналізувати все".

### Phase A — PredictionEngine (DONE)

`Core/Prediction/PredictionEngine.swift` (+ `PredictionModels.swift`). @MainActor
@Observable; chunked cooperative analysis (`Task.yield()` between 40-group
chunks → never a single freeze); disk cache (`prediction-cache.json`, relaunch =
no recompute); published `phase` / `analyzedCount`,`totalCount` / `liveFeed` /
`ranked`.

| Metric (real 819 groups) | Value |
|---|---|
| Cold background pass | 5418 ms, chunked off the render path (not one freeze) |
| Warm (cache hit) | 36 ms |
| Disk cache round-trip | fresh engine serves all from cache, 0 recompute |
| Top ranked | ентер 7×, дев 5×, кнокп 5×, … (frequency × confidence) |

Caveat surfaced: ranking still shows garbage suggestions (`кнокп → ryjrg`,
`црууді → wheels`) → needs a quality threshold + Phases C/D.

### Phase B — Live-scanner UI (DONE)

`MistakesView` rewritten to render only from engine snapshots: progress banner
(X/Y + `ProgressView`), streaming found-pairs feed (`FlowLayout` + spring/scale
transitions, capped at 6), accumulating ranked cards (`LazyVStack`, animated
insert/reorder), `contentTransition(.numericText())` stats, fast `RuleEditorSheet`,
"Переаналізувати все". Quality filter: only recurring (count ≥ 2) groups with a
suggestion and confidence ≥ 0.6 → 819 raw → the genuinely useful "найчастіші".

### Phase C — Keystroke / keyboard-adjacency generator (DONE)

`Core/Prediction/KeyboardAdjacency.swift` (ANSI physical-neighbour table by
`kVK_ANSI_*`, derived from a staggered grid; symmetric, validated) + a generator
in `MistakeSuggestionAnalyzer` (`.keyboardAdjacency` kind). Language-agnostic:
uses `CharacterMapper` keyCode↔char maps to try physically adjacent keys and keep
substitutions that land on a real word. Test: `hwllo → hello` (E next to W).

### Phase D — SymSpell engine (DONE; dictionaries pending decision)

`Core/Prediction/SymSpell.swift` (Symmetric-Delete, prefix index, bounded OSA
Damerau-Levenshtein on a flat buffer) + `SymSpellSpellChecker.swift` (per-language
`SpellCheckingClient` adapter with NSSpellChecker fallback — the drop-in seam).
Correctness: 6 tests incl. transposition + Cyrillic `привт→привіт`. Throughput:
**1345 µs/word** on a harsh random 20k dict at ED2 (~4× faster than NSSpellChecker;
structured dicts + ED1-for-short go faster) — and off-main + cacheable + a domain
dictionary that cuts false positives. (The "~150×" from research is SymSpell vs
Norvig brute-force, not vs NSSpellChecker.)

**Hybrid dictionary scaffold (DONE — user chose base + learned):**
`DictionaryBuilder.swift` (bundled-base resource loader `frequency_<lang>.txt` +
learned-from-history overlay, normalized + weighted) and `HybridSpellChecker.swift`
(learned-known overlay that can ONLY remove false positives + SymSpell-first merged
guesses). 5 tests: `дев` becomes known while `кнокп` stays flagged; corrections
merged. NOT wired live yet (would over-flag without a comprehensive base).

### Suggestion-quality fixes (from real-usage bug reports)

- **Duplicate cards** (`кщьфт → roman` shown twice): `PredictionEngine.publishRanked`
  now merges groups by visible identity (source + language + target), summing
  counts and unioning observation IDs — so the same correction across apps /
  with-or-without a recorded target is ONE card. (`SuggestionQualityTests`)
- **Gibberish suggestions** (`плейрайт → gktqhfqn`, `віджет → dsl;tn`,
  `репозиторії → htgjpbnjhs]`, keystroke `від.ет`): `WordPlausibility.isWordLike`
  gate in `computeCandidates` drops any non-recorded candidate that isn't a
  plausible word (letters-only + has a vowel + no absurd consonant run). Keeps
  real ones like `roman`.
- **Already-handled words** resurfacing: `LearnedVocabulary.handledSources`
  (allowlist + rule source/target) filtered out of the engine's groups, so a word
  the user already ruled/allowlisted never re-appears as a suggestion.

### Domain-vocabulary learning (task #9 — DONE)

`PredictionEngine` now learns which "mistakes" are actually the user's domain
words and stops flagging them — so `плейрайт`/`репозиторії`/`віджет` leave both
the suggestions list AND the "Помилок" count:
- **Produced corpus** (`harvestProducedCorpus`): words from the corrected side of
  the user's replacement history are known-good.
- **Recurring-uncorrectable** (`learnDomainVocabulary`, after each pass): a
  **word-like** source (has a vowel — so gibberish like `кщьфт`/`кнокп` is
  excluded and still gets fixed) that recurs ≥ 2× with **no close fix** (no
  recorded target, no clean layout flip, nothing within Damerau distance 1) is a
  domain word, not a typo. Real typos (`помилак→помилка` = transposition = dist 1;
  `кіт` = dist-1 guess) keep their close fix and stay flagged.
- Persisted to `domain-vocabulary.json`; combined with allowlist/rules via
  `handledSourcesProvider` and filtered out of groups. `flaggedCount` drives the
  stat. Tests: `test_engine_learnsDomainWordButKeepsRealTypos` + others. 164 green.

**Still optional (enrichment, not blocking):** bundle real uk/en base frequency
lists as `frequency_<lang>.txt` resources and wire `HybridSpellChecker`/SymSpell
for guess speed; the `DictionaryBuilder`/`HybridSpellChecker` seam is ready.
