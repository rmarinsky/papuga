# Golden corpus

Tab-separated, one case per line, so a quality regression shows up as a
one-line diff in review.

```
input <TAB> language <TAB> expected <TAB> verdict
```

- `verdict = fix` — `input` is a mistake and `expected` is the correction.
  Measures **coverage** (did we offer it at all), **top1**/**top3** (was it
  ranked usefully) and **MRR**.
- `verdict = nofix` — `input` is correctly typed and must **not** be flagged.
  `expected` is `-`. Measures **fpRate**, the number that regressed while
  nobody was watching it.

Lines starting with `#` and blank lines are ignored.

## Buckets

| File | What it protects |
|---|---|
| `apostrophe.tsv` | Ukrainian apostrophe forms. The bundled list has **zero** of them, so while it was authoritative every one was "misspelled". |
| `jargon.tsv` | Tech/domain vocabulary the user actually types. The original benchmark identified these as the real false-positive source. |
| `common_uk.tsv` / `common_en.tsv` | Ordinary correct words must never be flagged. |
| `russian_contamination.tsv` | The uk frequency list carries 3206 Russian entries (`что` is its 8th most frequent word), so Russian is accepted as valid Ukrainian. |
| `spelling_en.tsv` / `spelling_uk.tsv` | Real typos still get corrected — the guard against "fixed the false positives by suggesting nothing". |

## Adding cases

Prefer real cases over invented ones, but **never paste user text straight in**:
`scripts/extract-golden-candidates.sh` reads the machine-local observation
files and prints reviewable TSV. The manual review step is the privacy
boundary — do not automate the commit.

## Thresholds

`thresholds.json` holds the current floors. The suite fails below them and
prints a copy-pasteable replacement block when it beats them, so improvements
get locked in. Changing a floor is then a deliberate, reviewable diff.

Floors are recorded as of the state they were measured in — several buckets
are *known bad* and are expected to improve as the remaining plan steps land.
