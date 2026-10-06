# Mutineer JSON report — schema reference

`mutineer run --format json` emits a single JSON object (one line, newline-terminated) describing the
whole run. It is the **machine-readable contract** for tooling — CI gates, dashboards, and AI coding
agents. Output is deterministic: arrays are sorted by `(file, line, operator)` regardless of `--jobs`
worker finish order, so two runs of the same inputs produce byte-identical output.

## Versioning contract

The top-level `schema_version` (a string, e.g. `"1.5"`) follows these rules:

- **Additive changes** (new keys on existing objects, new top-level keys) bump the **minor** version
  (`1.0` → `1.1`). Existing keys keep their meaning. Consumers MUST ignore unknown keys.
- **Breaking changes** (renaming/removing a key, changing a value's type or meaning) bump the **major**
  version (`1.x` → `2.0`).

A consumer should accept any `1.x` document and read only the keys it knows.

Mutant `id` values are opaque identifiers. How an id is derived is versioned by
`summary.id_format`, not by `schema_version`: when `id_format` changes, every id
value can change while the key keeps its type and meaning. Compare ids only
between reports with the same `id_format` (a missing key is the old format).

## Top-level shape

```jsonc
{
  "schema_version": "1.5",
  "summary":      { /* run totals, see below */ },
  "survivors":    [ /* mutants the suite failed to catch — the actionable gaps */ ],
  "no_coverage":  [ /* mutants on lines no test exercises */ ],
  "uncapturable": [ /* mutants whose would-be test errored during coverage capture */ ],
  "no_verdict":   [ /* mutants that were attempted and produced no verdict */ ],
  "ignored":      [ /* mutants the user suppressed (equivalent mutants) */ ],
  "per_source":   [ /* per-file roll-up */ ],
  "matrix":       { /* present ONLY with --matrix: which tests kill which mutants */ },
  "baseline":     { /* present ONLY with --baseline: the delta vs a prior run */ }
}
```

### `summary` (object)

| Key | Type | Meaning |
|-----|------|---------|
| `total` | int | Classified results included in this report, across all statuses. With `--fail-fast`, unscheduled candidates are omitted, so this is not the full generated candidate count. |
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
| `scoped` | bool | `true` when the run was diff-scoped (`--since`): the score covers only the changed-line mutants, so it is not comparable to a full-run score. A scoped CURRENT run skips `--baseline`'s score-drop check (new-survivor detection still applies); a scoped report is REFUSED as a baseline (exit 2) because survivors outside its diff would read as new regressions. Additive key (absent in reports from older versions; treat absent as `false`). |
| `id_format` | int | The mutant id format. `2` means ids include the project-relative file path (1.3 and later). **Read this key, not `schema_version`, to learn the id format.** Absent in older reports: treat absent as the old format, whose ids did not include the path and can collide across files. Additive key (schema `1.4`). |
| `legacy_id_matches` | object | `{ ignore, baseline }`, two ints. `ignore` counts `.mutineer.yml` `ignore:` entries in the old id format that matched this run (replace them with the new ids the run prints). `baseline` counts survivors that matched an old-format `--baseline` only through their old id (regenerate the baseline). Both are `0` when nothing old matched. Old-format matching is removed in 2.0. Additive key (schema `1.4`). |

### `survivors[]` (array of object)

Each surviving mutant — the records an agent or reviewer acts on:

| Key | Type | Meaning |
|-----|------|---------|
| `subject` | string | Fully-qualified subject, e.g. `Calculator#add`. |
| `file` | string | Source file path (as passed to the run). |
| `line` | int | 1-based line of the mutation. |
| `operator` | string | Operator name, e.g. `arithmetic`, `comparison`. |
| `id` | string | **Offset-free id** (12 hex chars). Includes the file path relative to the project root (a source outside the root uses its absolute real path, so its ids differ between machines). Unrelated edits preserve it when the path, qualified method name, mutated token, and repeated-name/mutation order stay the same. File moves, renames, and root changes can change it. See [Mutant ids](https://github.com/davidteren/mutineer#mutant-ids). Paste into `.mutineer.yml` `ignore:`, or diff between runs (this is what `--baseline` matches on). |
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
`total` counts classified results for that file. A `--fail-fast` report is partial:
unscheduled candidates are omitted from these counts and from the top-level totals.

### `matrix` (object, only with `--matrix`)

Which tests kill which mutants. A `--matrix` run runs every test in each mutant's covering files, so a
mutant's row names every test that kills it. Coverage is recorded per test file, and a test that never runs
the mutated line cannot kill the mutant. Added in schema `1.5` and absent without the flag. The block never
changes `summary`, the score or the exit code.

A test has a `file` (relative to the project root: the file that defines the test), a `name`
(`CalculatorTest#test_add` under Minitest, the example's full description under RSpec) and an `id`. The `id`
tells apart tests that share a file and name: under RSpec it is the example id
(`./spec/calc_spec.rb[1:2]`; `--matrix` needs RSpec 3.3 or later, and an older RSpec leaves every row
incomplete), and under Minitest it equals `name`. A test of an anonymous Minitest class is named
`(anonymous)#test_x`, and its `id` adds the line of the method (`(anonymous)#test_x@7`).
A test is identified by its `file` and `id`. An example without a description of its own is worded from its
matcher, so its `name` can change with the mutant; the report keeps the name the first mutant gave it.

| Key | Type | Meaning |
|-----|------|---------|
| `complete` | bool | True when every row is complete. When false, a test in `blind[]` may have killed a mutant whose row is incomplete. |
| `tests[]` | array | Every test that ran against at least one mutant: `{ file, name, id, kills }`, sorted by `file`, `name`, then `id`. `kills` counts the mutants the test killed. Rows refer to a test by its index here. |
| `mutants[]` | array | One row per mutant that ran: `{ subject, file, line, operator, id, status, killed_by, ran, complete }`, sorted by `(file, line, operator, id)`. `killed_by` holds indexes into `tests[]`, and `ran` counts the tests that ran against the mutant. No-coverage, skipped and ignored mutants have no row. |
| `blind[]` | array | `{ file, name, id }`: tests that ran in at least one complete row and killed no mutant in any row. |
| `redundant[]` | array | `{ file, name, id }`: tests that killed at least one mutant, where each mutant they killed has another killer. |

A row is complete (`complete: true`) only when the mutant's whole covering set ran and the suite returned
normally before the per-mutant timeout, every line the child sent was read and arrived in order, and the row
agrees with the verdict: a killed mutant names a killer and a survivor names none. Under Minitest the
recorder also counts: it must have seen every test its classes run, so an `Interrupt` that Minitest caught and
returned from leaves the row incomplete; under RSpec, every planned example must have reported, so a run that
RSpec stopped early does too. A test that exits the process, a crash, the timeout, a failed write to the
channel, or a test framework Mutineer could not hook each leave the row incomplete too. A row whose lines
arrived out of order names no tests (`killed_by` and `ran` are empty).

`status` is the verdict a run without `--matrix` gives. After the first failing test, that run skips every
later test, test class and example group, so an exit, a crash or the timeout in one of those leaves the status
`"killed"`. It still runs the code around the failing test (the rest of its Minitest class `run` wrapper, the
`after(:all)` hooks of its RSpec groups) and the suite's own cleanup (RSpec `after(:suite)`), so an end there
keeps the exit status (or `"timeout"`). A failure in the tests of a Minitest `parallelize_me!` class keeps it
too: those run after every serial class and cannot be stopped once queued, while a failure in a serial class
still stops the run, even in a suite that also has a parallel class.

Each redundant test is judged on its own. Two redundant tests can be the only killers of one mutant, so
delete them one at a time and re-run after each. Every answer covers this run's mutants only.

### `baseline` (object, only with `--baseline`)

The delta versus the prior `--format json` report, matched by `id`. A baseline without `summary.id_format` also matches on old-format ids (counted in `summary.legacy_id_matches.baseline`):

| Key | Type | Meaning |
|-----|------|---------|
| `regressed` | bool | True if there are new survivors OR a score drop. **Drives exit 1.** |
| `score_before` | float \| null | Baseline score. |
| `score_after` | float \| null | This run's score. |
| `score_dropped` | bool | True if `score_after < score_before - epsilon`. |
| `score_comparable` | bool | True when the two scores share a denominator (neither side was diff-scoped, both non-null). False means the score-drop check was skipped — do not render the scores as a comparison. Additive key. |
| `new_survivors[]` | array | Survivors present now but absent in the baseline: `{ subject, file, line, operator, token, id }`. |
| `fixed_survivors[]` | array | Baseline survivors no longer present: `{ subject, file, line, operator, id }`. Empty under a diff-scoped side: an out-of-scope survivor was never re-tested, so absence does not mean fixed. |

## Exit codes

<!-- contract:exit-codes -->
| Code | Meaning |
|------|---------|
| `0` | Score ≥ threshold (or no gate) **and** no baseline regression. |
| `1` | Score below `--threshold`, OR nothing could be scored and something broke, or more than one mutant produced no verdict and they exceed 10% of those attempted, OR a `--baseline` regression, OR a runtime error. |
| `2` | Usage / invalid-flag error (mistyped flag, bad path, unreadable baseline). |
<!-- /contract:exit-codes -->

Under a positive `--threshold`, a run is gated on being complete as well as on its score. Mutants with no
verdict are excluded from the score's denominator, so a broken harness inflates the score instead of
lowering it. Past 10% of attempted mutants — and never for a single one, however small the run — the
score is treated as covering too little of the run to gate on. The floor applies only when there *is* a
score: a run where nothing could be scored at all fails on a single broken mutant, because there is no
score to weigh it against. Read `no_verdict[]` to see what failed.
A run where *nothing* was scored and something broke already exits 1.

`--threshold` and `--baseline` are independent gates OR'd together (the worse code wins); usage errors (2)
always win. Exit 2 still means "you invoked me wrong". Exit 1 now covers three distinct situations —
tests too weak, the run did not complete, or a baseline regression — and they are not distinguishable
from the exit code alone. Tell them apart from the JSON: compare `summary.score` against your threshold,
`summary.no_verdict / summary.attempted` against 10%, and `baseline.regressed`. A run that failed only on
completeness is the one worth retrying rather than blaming on the tests.
