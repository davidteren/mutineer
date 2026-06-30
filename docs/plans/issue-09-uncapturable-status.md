---
title: Issue #9 — Distinct `uncapturable` status (errored capture vs genuine no-coverage) - Plan
type: feat
date: 2026-06-29
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
issue: 9
depends_on: 8
execution: code
---

# Issue #9 — Distinct `uncapturable` status - Plan

**One-line goal:** Split today's overloaded `:no_coverage` into a real
"the harness couldn't run your test" status (`:uncapturable`) and a real
"no test exercises this line" status, count and report them separately, and
keep both out of the mutation-score denominator.

**Depends on:** #8 (surfaces the swallowed `fork_capture` exception so a failed
capture is visible/diagnosable). #8 makes the capture failure *legible*; #9
turns that failure into a first-class per-mutant status. Assume #8 lands first.
This plan does not re-fix the AR-reconnect root cause from #8; it only consumes
the already-recorded `failed_test_files` signal.

---

## Goal Capsule

- **Objective:** Introduce a sixth-vs-seventh terminal status `:uncapturable`
  (a.k.a. errored_capture), distinct from `:no_coverage`. A mutant is
  `:uncapturable` when its line has no covering test *because the test(s) that
  would have covered it errored during capture*, not because the line is
  genuinely untested. Report the two separately ("N uncapturable (tests failed
  to run), M no-coverage (genuinely uncovered)") in both human and JSON output.
- **Authority:** GitHub issue #9; `lib/mutineer/result.rb` status doc-comment;
  `docs/plans/05-m4-full-tier1-reporting-ci.md` score oracle (KTD-4);
  `docs/plans/_DECISIONS.md`.
- **Stop condition:** If attributing a failed capture to a specific source file
  cannot be done from already-persisted state without re-running tests or adding
  a runtime dep, surface the limit rather than inventing a fragile mapping.
- **Execution profile:** Standard — land units in dependency order
  (Result → AggregateResult → CoverageMap → Runner → Reporter), `rake test`
  after each.
- **Tail ownership:** Done when the Verification Contract passes and every
  existing Result/Reporter/JSON test stays green (the M4 score oracle is
  untouched).

---

## Requirements

- **R1.** A new terminal status `:uncapturable` exists with a factory and a
  predicate, mirroring the five existing factory/predicate pairs.
- **R2.** `:uncapturable` is EXCLUDED from the score denominator exactly like
  `:no_coverage`, `:skipped`, `:error`, `:timeout`. `mutation_score` and
  `covered_count` (= killed + survived) are byte-for-byte unchanged. Empty
  denominator still yields `nil` (not 0.0).
- **R3.** `AggregateResult` exposes `uncapturable_count`, counted from results
  like the other counts. `total` still = all classified mutants.
- **R4.** The CoverageMap can answer, from already-persisted state (the map +
  `failed_test_files`, no rerun), whether a source file's empty-coverage lines
  are *uncapturable* (a failed test would have covered them) vs *genuinely
  uncovered*.
- **R5.** Runner maps an empty `tests_for` lookup to `Result.uncapturable` when
  the line is tainted by a failed capture, else `Result.no_coverage` as today.
- **R6.** Human summary distinguishes the two: e.g.
  `Uncapturable:  N  (tests failed to run)` alongside `No coverage:  M`, and the
  score line's "excluded" breakdown lists uncapturable separately.
- **R7.** JSON schema gains `summary.uncapturable` (count) and a top-level
  `uncapturable` list (same shape as `no_coverage`: subject/file/line, sorted).
  Existing keys (`no_coverage`, `summary.no_coverage`, etc.) keep their meaning.
- **R8.** Acceptance is testable WITHOUT Rails, by simulating a failed capture
  (a broken test file whose name maps to a source file) — reusing the existing
  `test_failing_test_file_is_skipped_without_aborting` scaffolding pattern.

---

## Key Technical Decisions

### KTD-1 — `:uncapturable` is excluded from the score denominator, counted separately

The score oracle is locked: `score = killed / (killed + survived)`;
`no_coverage`, `skipped`, `error`, `timeout` are excluded. `:uncapturable`
joins the *excluded* set — it is neither killed nor survived, and a mutant we
could not run must never inflate or deflate the score. Concretely:
`covered_count` and `mutation_score` are NOT edited; we only add a new count and
new reporting. This preserves every M4 oracle test verbatim.

### KTD-2 — How a mutant becomes `:uncapturable` (the taint rule)

The hard constraint: when a test errors during capture, its coverage data is
*lost*, so we cannot know line-by-line which lines it would have covered.
Re-running to find out is off the table (cost + the very failure we're flagging).
So attribution is at SOURCE-FILE granularity, computed purely from state we
already persist:

A source file is **uncapturable-tainted** iff ALL of:
1. `failed_test_files` is non-empty (some capture errored this run), AND
2. the file received **zero** coverage from any successful capture (it does not
   appear in any `@map` key), AND
3. at least one *failed* test file maps to it by the standard Ruby naming
   convention: `basename` with a trailing `_test`/`_spec` stripped equals the
   source file's `basename` (e.g. failed `test/interactors/create_foo_test.rb`
   ↔ source `app/interactors/create_foo.rb`).

Then, in Runner, an empty `tests_for(file, line)` is:
- `:uncapturable` when the file is tainted (its only would-be test errored), vs
- `:no_coverage` when it is not (no test targets it, or successful tests reached
  the file but simply not this line).

This is exactly the #8 write-heavy-interactor case: the interactor's own test
errors in the fork → that source gets zero coverage → its `_test` sibling is in
`failed_test_files` → every mutant in it becomes `:uncapturable`, not a sea of
false `:no_coverage`. It also covers situation (b) "boot env wrong, nothing
instrumented": every test fails → every source is zero-coverage with a matching
failed test → uniformly `:uncapturable`, the correct "harness broke" signal.

`# ponytail:` ceiling — file-level, convention-based attribution. A file
partially covered by a *successful* test, whose remaining lines were covered
*only* by a failed test, stays `:no_coverage` for those lines (condition 2
fails). And a source with no naming-convention test match is never tainted.
Upgrade path if this proves too coarse: persist each successful run's per-file
coverage and diff against the failed set, or record test→source targets
explicitly. Not needed for the #8/#9 cases; revisit only if real suites show
mis-attribution.

### KTD-3 — CoverageMap distinguishes "test ran, covered nothing" from "test errored"

Already half-built: `fail_test` records errored test files into
`@failed_test_files`, which is persisted in `coverage.json` and reloaded from
cache. A test that *ran but covered a given line zero times* simply contributes
no `@map` entry — indistinguishable per-line from "no test" but distinguishable
per-file via the taint rule above. No new persisted state is required: the taint
predicate is derived from `@map` keys + `@failed_test_files`, both already saved
(KTD-4 cache key unchanged). The cache digest does NOT change, so existing
caches remain valid.

### KTD-4 — Status name

Use `:uncapturable` (the issue's primary suggestion). `errored_capture` is the
listed alias; pick one name only, no alias machinery (YAGNI).

---

## Implementation Units

### U1 — `Result.uncapturable` factory + predicate (`lib/mutineer/result.rb`)

- Add `def self.uncapturable = new(status: :uncapturable, details: nil, subject: nil, mutation: nil)`.
- Add `def uncapturable? = status == :uncapturable`.
- Extend the doc-comment's status list to seven, noting it is excluded from the
  denominator like `no_coverage` but reported separately (harness failure, not a
  coverage gap).
- No `details` needed (the diagnostic message is already emitted by
  `fail_test`/#8 on stderr); keep the factory arity-0 like `no_coverage`.

### U2 — `AggregateResult.uncapturable_count` (`lib/mutineer/result.rb`)

- Add `def uncapturable_count = count(:uncapturable)`.
- Do NOT touch `covered_count` or `mutation_score` (KTD-1).

### U3 — CoverageMap taint predicate (`lib/mutineer/coverage_map.rb`)

- Add a public query the Runner calls, e.g.
  `def uncapturable_source?(file)` returning true per KTD-2:
  - short-circuit `false` when `@failed_test_files.empty?`;
  - `rel = relativize(absolute(file))`; `false` if `covered_source_files.include?(rel)`;
  - `true` if `failed_test_targets.include?(File.basename(rel, ".rb"))`.
- Private helpers (derive, do not persist):
  - `covered_source_files` → set of source rel-paths present in `@map` keys
    (`@map.keys.map { |k| k.rpartition(":").first }`).
  - `failed_test_targets` → `@failed_test_files` basenames with a trailing
    `_test`/`_spec` (and `.rb`) stripped.
- Works identically on the cache-hit path (both inputs are reloaded in
  `cached_or`). No digest/schema change.

### U4 — Runner classification (`lib/mutineer/runner.rb`)

- In `self.run`, replace the single `return Result.no_coverage if chosen.empty?`
  with:
  ```ruby
  if chosen.empty?
    return coverage_map.uncapturable_source?(source_file) ? Result.uncapturable
                                                          : Result.no_coverage
  end
  ```
- Nothing else changes; covered mutants still fork exactly as before.

### U5 — Reporter human output (`lib/mutineer/reporter.rb`)

- `summary`: add an Uncapturable line, e.g. extend the block to print
  `Uncapturable:  <n>  (tests failed to run)` next to `No coverage:`. Keep the
  existing aligned `format` style.
- `score_line`: add `"<n> uncapturable"` to the `excluded` breakdown string so
  the reader sees it was excluded.
- Phrasing target from the issue: "N uncapturable (tests failed to run),
  M no-coverage (genuinely uncovered)".

### U6 — Reporter JSON schema (`lib/mutineer/reporter.rb`)

- `json_report`: add `uncapturable: @agg.uncapturable_count` to `summary`, and a
  top-level `uncapturable:` array built like the `no_coverage` array
  (reuse `no_coverage_json` shape — subject/file/line — selecting
  `&:uncapturable?`, sorted by `[file, line]`).
- Keep `schema_version: "1.0"` only if additive keys are acceptable under the
  project's compat rule; otherwise bump per the repo's schema-version policy.
  Decision flagged for the implementer — additive-only suggests no break, but
  confirm against `_DECISIONS.md` KTD7.

### U7 — Tests

- `test/result_test.rb`: add `test_uncapturable` (predicate true, others false,
  nil details); extend `test_each_factory_has_a_distinct_status` to include
  `Result.uncapturable`.
- `test/reporter_test.rb`: assert `uncapturable_count`; assert the summary line
  and the score-line "excluded" breakdown mention uncapturable; assert
  `:uncapturable` does NOT change the score (e.g. killed+survived+uncapturable
  gives the same score as without it).
- `test/json_reporter_test.rb`: assert `summary.uncapturable` and the top-level
  `uncapturable` list (shape + sort), and that score is unaffected.
- `test/coverage_map_test.rb`: extend the failed-capture scenario — build with a
  broken `calculator_test.rb` (name maps to `calculator.rb`) as the ONLY test so
  the source gets zero coverage; assert `uncapturable_source?(CALC)` is true, and
  that with a genuinely uncovered line (add-only suite, no failures)
  `uncapturable_source?` is false.
- Optional `test/runner_test.rb`: a direct unit feeding a stub coverage_map
  (`tests_for → []`, `uncapturable_source? → true`) asserts `Runner.run` returns
  `Result.uncapturable`; the false case returns `Result.no_coverage`.

---

## Verification Contract

**Gate (must pass):**
```
bundle exec rake test \
  && bundle exec ruby -Ilib -e 'require "mutineer"'
```

**Acceptance (all WITHOUT Rails):**
1. A mutant whose covering test errored during capture is classified
   `:uncapturable`, NOT `:no_coverage`. Simulate by building a CoverageMap whose
   only test for `calculator.rb` is a broken `calculator_test.rb`
   (`require 'does/not/exist'`), then run a mutant on a `calculator` line →
   `Result.uncapturable`.
2. A mutant on a line that has no test at all (add-only suite, no failed
   captures) stays `:no_coverage`.
3. The mutation score EXCLUDES both `:uncapturable` and `:no_coverage`: an
   aggregate of `[killed, survived, uncapturable, no_coverage]` scores 50.0
   (same as `[killed, survived]`), and an all-uncapturable aggregate scores
   `nil` ("N/A").
4. Human summary reports the two separately (an Uncapturable line distinct from
   No coverage; score line lists uncapturable as excluded).
5. JSON report exposes `summary.uncapturable` (count) and a top-level
   `uncapturable` list distinct from `no_coverage`.
6. Every pre-existing Result / Reporter / JSON / CoverageMap test stays green
   (no regression; M4 score oracle untouched).

---

## Definition of Done

- U1–U7 landed; gate command green.
- `:uncapturable` is a first-class status with factory + predicate, counted by
  `AggregateResult`, excluded from the denominator, and surfaced in both
  reporters distinctly from `:no_coverage`.
- Runner correctly routes empty-coverage lines to `:uncapturable` vs
  `:no_coverage` via the CoverageMap taint rule, with no rerun and no cache
  digest change.
- No change to `mutation_score`, `covered_count`, or any existing score test.
- The `# ponytail:` ceiling on file-level/convention-based attribution is
  recorded in `coverage_map.rb`.
- #8 dependency noted; #9 consumes its `failed_test_files` signal, does not
  duplicate its root-cause fix.

---

## Validation (4-lens)

- **Least astonishment:** `:uncapturable` follows the exact factory/predicate/
  count/exclude pattern of the existing six states; readers already trained on
  `no_coverage` find an isomorphic seventh. The summary distinction matches the
  issue's own wording. No surprise. *Resolved.*
- **Convention / idiom:** Reuses `Data.define` factories, `count(:status)`,
  `@by_status`, the existing `no_coverage_json` shape, persisted
  `failed_test_files`, and the established `relativize`/`absolute` helpers. No
  new dependency, no new persisted field, stdlib only. The `_test`/`_spec`
  basename convention is the standard Ruby/Rails test↔source mapping.
  *Resolved.*
- **Simplicity / scope:** Additive only — no editing of the score math, no new
  CLI flags, no alias machinery, no `details` plumbing. Attribution is the
  smallest rule that separates the #8 case from genuine gaps, derived from state
  already on disk. Gap considered — per-line attribution from a failed capture —
  rejected as impossible without a rerun and unnecessary for the cases #9 names;
  ceiling documented with an upgrade path. *Resolved.*
- **Experience / output:** The user-facing payoff IS the experience: human and
  JSON now answer "is this a coverage gap or a broken harness?" — opposite
  actions, previously merged. States covered: some-failed, all-failed (boot
  env), none-failed (pure no-coverage), and the empty/N-A path (score still
  `nil`). *Resolved.*

No unresolved gaps.
