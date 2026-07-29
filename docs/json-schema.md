# Mutineer JSON report — schema reference

`mutineer run --format json` emits a single JSON object (one line, newline-terminated) describing the
whole run. It is the **machine-readable contract** for tooling — CI gates, dashboards, and AI coding
agents. Output is deterministic: arrays are sorted by `(file, line, operator)` regardless of `--jobs`
worker finish order, so two runs of the same inputs produce byte-identical output.

## Versioning contract

The top-level `schema_version` (a string, e.g. `"1.1"`) follows these rules:

- **Additive changes** (new keys on existing objects, new top-level keys) bump the **minor** version
  (`1.0` → `1.1`). Existing keys keep their meaning. Consumers MUST ignore unknown keys.
- **Breaking changes** (renaming/removing a key, changing a value's type or meaning) bump the **major**
  version (`1.x` → `2.0`).

A consumer should accept any `1.x` document and read only the keys it knows.

## Top-level shape

```jsonc
{
  "schema_version": "1.2",
  "summary":      { /* run totals, see below */ },
  "survivors":    [ /* mutants the suite failed to catch — the actionable gaps */ ],
  "no_coverage":  [ /* mutants on lines no test exercises */ ],
  "uncapturable": [ /* mutants whose would-be test errored during coverage capture */ ],
  "no_verdict":   [ /* mutants that were attempted and produced no verdict */ ],
  "ignored":      [ /* mutants the user suppressed (equivalent mutants) */ ],
  "per_source":   [ /* per-file roll-up */ ],
  "baseline":     { /* present ONLY with --baseline: the delta vs a prior run */ }
}
```

### `summary` (object)

| Key | Type | Meaning |
|-----|------|---------|
| `total` | int | Total mutants generated (every status, before exclusions). |
| `killed` | int | Mutants a test caught (suite went red). |
| `survived` | int | Mutants no test caught. **These are the actionable test gaps.** |
| `no_coverage` | int | Mutants on a line no test exercises (excluded from score). |
| `uncapturable` | int | Mutants whose covering test errored during capture — a broken harness, not a gap (excluded). |
| `skipped_invalid` | int | Mutants that didn't re-parse and were never run (excluded). |
| `errored` | int | Mutants whose run raised (excluded). |
| `timeout` | int | Mutants whose run exceeded the per-mutant timeout (excluded). |
| `ignored` | int | Mutants suppressed via `# mutineer:disable-line` or `.mutineer.yml` `ignore:` (excluded). |
| `attempted` | int | Mutants actually run: `killed + survived + no_verdict`. **Not** `total` — no-coverage, skipped and ignored mutants were never attempted. |
| `no_verdict` | int | Attempted mutants that produced no verdict: `errored + timeout + uncapturable`. The completeness gate is `no_verdict / attempted`. |
| `score` | float \| null | `killed / (killed + survived) * 100`, rounded. **`null`** when the denominator is empty (no covered mutants) — never `0.0`. |

### `survivors[]` (array of object)

Each surviving mutant — the records an agent or reviewer acts on:

| Key | Type | Meaning |
|-----|------|---------|
| `subject` | string | Fully-qualified subject, e.g. `Calculator#add`. |
| `file` | string | Source file path (as passed to the run). |
| `line` | int | 1-based line of the mutation. |
| `operator` | string | Operator name, e.g. `arithmetic`, `comparison`. |
| `id` | string | **Stable, offset-free id** (12 hex chars). Survives edits elsewhere in the file. Paste into `.mutineer.yml` `ignore:`, or diff between runs (this is what `--baseline` matches on). |
| `token` | string | The exact code being mutated (whitespace-collapsed), e.g. `a + b`. |
| `diff` | string | A unified diff (`@@ -line +line @@` with `-original` / `+mutant`). Ready to hand to an agent as "write a test that fails under this change." |

### `no_coverage[]` and `uncapturable[]` (array of object)

Both use the lean shape `{ subject, file, line }`. `no_coverage` is a genuine coverage gap; `uncapturable`
means the test that should cover the line errored while capturing coverage (fix the harness, not the test).

### `no_verdict[]` (array of object)

Every mutant that was attempted and produced no verdict: `{ subject, file, line, id, status, details }`.
`status` is `"error"`, `"timeout"` or `"uncapturable"`, and its length equals `summary.no_verdict`.

`details` carries the cause where there is one. For `"error"` that is the failure (a daemon crash, say);
for `"timeout"` and `"uncapturable"` it is `null`, because the status is the whole story.

A failure before the mutant could be forked has no subject or mutation, so `subject`, `file`, `line` and
`id` are `null` on that entry. It still appears, because the counts must reconcile — but that means `id`
is not a reliable join key here, unlike in `survivors[]` and `ignored[]`.

Uncapturable mutants appear both here and in `uncapturable[]`, which keeps its lean shape for consumers
that already read it.

Read this array when the score looks better than you expect: these mutants are excluded from the score's
denominator, so a broken harness raises the score rather than lowering it. That is why `--threshold`
gates on completeness as well (see Exit codes).

### `ignored[]` (array of object)

Suppressed (equivalent) mutants, so you can audit what's silenced: `{ subject, file, line, operator, token, id }`.

### `per_source[]` (array of object)

Per-file roll-up: `{ file, total, killed, survived, no_coverage, score }` (`score` is `float | null` as above).

### `baseline` (object, only with `--baseline`)

The delta versus the prior `--format json` report, matched by stable `id`:

| Key | Type | Meaning |
|-----|------|---------|
| `regressed` | bool | True if there are new survivors OR a score drop. **Drives exit 1.** |
| `score_before` | float \| null | Baseline score. |
| `score_after` | float \| null | This run's score. |
| `score_dropped` | bool | True if `score_after < score_before - epsilon`. |
| `new_survivors[]` | array | Survivors present now but absent in the baseline: `{ subject, file, line, operator, token, id }`. |
| `fixed_survivors[]` | array | Baseline survivors no longer present: `{ subject, file, line, operator, id }`. |

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Score ≥ threshold (or no gate) **and** no baseline regression. |
| `1` | Score below `--threshold`, OR more than 10% of attempted mutants produced no verdict, OR a `--baseline` regression, OR a runtime error. |
| `2` | Usage / invalid-flag error (mistyped flag, bad path, unreadable baseline). |

Under a positive `--threshold`, a run is gated on being complete as well as on its score. Mutants with no
verdict are excluded from the score's denominator, so a broken harness inflates the score instead of
lowering it. Past 10% of attempted mutants — and never for a single one, however small the run — the
score is treated as covering too little of the run to gate on. Read `no_verdict[]` to see what failed.
A run where *nothing* was scored and something broke already exits 1.

`--threshold` and `--baseline` are independent gates OR'd together (the worse code wins); usage errors (2)
always win. Exit 2 still means "you invoked me wrong". Exit 1 now covers three distinct situations —
tests too weak, the run did not complete, or a baseline regression — and they are not distinguishable
from the exit code alone. Tell them apart from the JSON: compare `summary.score` against your threshold,
`summary.no_verdict / summary.attempted` against 10%, and `baseline.regressed`. A run that failed only on
completeness is the one worth retrying rather than blaming on the tests.
