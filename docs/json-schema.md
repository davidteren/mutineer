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
  "schema_version": "1.1",
  "summary":      { /* run totals, see below */ },
  "survivors":    [ /* mutants the suite failed to catch — the actionable gaps */ ],
  "no_coverage":  [ /* mutants on lines no test exercises */ ],
  "uncapturable": [ /* mutants whose would-be test errored during coverage capture */ ],
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
| `1` | Score below `--threshold`, OR a `--baseline` regression, OR a runtime error. |
| `2` | Usage / invalid-flag error (mistyped flag, bad path, unreadable baseline). |

`--threshold` and `--baseline` are independent gates OR'd together (the worse code wins); usage errors (2)
always win. This lets a pipeline distinguish "tests too weak" (1) from "you invoked me wrong" (2).
