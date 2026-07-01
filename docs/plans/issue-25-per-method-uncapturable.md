---
title: Issue #25 — per-method uncapturable granularity
type: fix
date: 2026-07-01
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---

# Issue #25 — per-method uncapturable granularity

**One-line goal:** Taint `:uncapturable` at **method** granularity, not whole-file, so a file
partly covered by a good test but with a method reachable only by a *failed* capture isn't
mis-reported (its uncovered method → `uncapturable`, the rest → genuine `no_coverage`).

**Depends on:** nothing · **Closes:** #25

---

## Goal Capsule
- **Objective:** Replace the file-level `uncapturable_source?(file)` taint with a per-method check
  keyed on the mutant's enclosing method line-range (already available as `subject.def_node`).
- **Stop condition:** existing #9/#19 uncapturable tests stay green (fully-failed files behave
  identically); a new partial-coverage fixture proves the finer attribution.
- **Non-goals:** no new coverage capture, no new statuses, no score-denominator change, no
  reliance on the *failed* run's (non-existent) coverage deltas.

## Verified current behavior (grounded, not assumed)
- `@map` is keyed `"relpath:line" => [test_files]` — coverage is already **line-level**.
- `CoverageMap#uncapturable_source?(file)`: `true` iff (a) `@failed_test_files` non-empty, (b) the
  file has **zero** covered lines (`covered_source_files` excludes it), (c) a failed test's basename
  (minus `_test`/`_spec`) equals the file's basename.
- `Runner.run`: when `tests_for(file, line)` is empty → `uncapturable_source?(file) ?
  Result.uncapturable : Result.no_coverage`. **`subject` is in scope here** (carries `def_node`).
- **The limitation:** condition (b) is all-or-nothing. A file with *any* successful coverage can
  never yield an `uncapturable` mutant, so a method reachable only by a failed test is mislabeled
  `no_coverage` (looks like a test gap, not a harness failure).
- **The hard truth:** a failed capture emits **no** coverage, so per-line intent of the failed test
  is unknowable. The usable signal is Prism method ranges + the *successful* line coverage in `@map`.

## Key Technical Decisions
- **KTD1 — Method-range taint.** A mutant on `(file, line)` is uncapturable iff: a failed sibling
  test targets `file` AND **no line in the enclosing method's range** appears in `@map` (zero
  successful coverage for that whole method). A method with ≥1 covered line → its uncovered lines
  are genuine `no_coverage`. This is derivable today (ranges from `subject.def_node.location`,
  coverage from `@map`) — no new capture.
- **KTD2 — Conservative bias preserved.** When a method has zero coverage and a sibling test failed,
  attribute it to the failure (`uncapturable`), not a gap — same bias as the current file-level rule,
  just per-method. `uncapturable`/`no_coverage`/`ignored` all stay excluded from the score
  denominator (unchanged).
- **KTD3 — No regression by construction.** For a *fully* failed file (zero coverage anywhere),
  every method's range has zero coverage ⇒ every mutant `uncapturable` ⇒ identical to today. Only
  the *partial* case changes. The #19 Miela files are capturable now (this path is for genuinely
  failed captures) and are unaffected.
- **KTD4 — Call-site owns the range.** `Runner.run` computes the range from `subject.def_node`
  (Prism `Location#start_line`/`end_line`) and passes it in; `CoverageMap` stays subject-agnostic
  (it only knows files/lines). Keeps the layer boundary clean.

## Implementation Units

### U1 — CoverageMap: range-aware taint
**Files:** `lib/mutineer/coverage_map.rb`
**Approach:** add
```ruby
# True when no line in line_range got successful coverage AND a failed sibling
# test targets this file — i.e. the method is uncapturable, not a genuine gap.
def method_uncapturable?(file, line_range)
  return false if @failed_test_files.empty?
  rel = relativize(absolute(file))
  return false unless failed_test_targets.include?(File.basename(rel, ".rb"))
  line_range.none? { |ln| @map.key?("#{rel}:#{ln}") }
end
```
Keep `covered_source_files`/`failed_test_targets`. Retain `uncapturable_source?` **only if** other
callers exist (none in lib besides Runner) — otherwise remove it and update its unit tests to the new
method (same scenarios pass: a fully-broken file's method range has zero coverage).

**Verification:** `method_uncapturable?` unit tests: fully-failed file → true for its method range;
no failures → false; failed sibling but method has a covered line → false.

### U2 — Runner: pass the enclosing method range
**Files:** `lib/mutineer/runner.rb`
**Approach:** in `run`, when `chosen.empty?`:
```ruby
loc = subject.def_node.location
range = loc.start_line..loc.end_line
return coverage_map.method_uncapturable?(source_file, range) ? Result.uncapturable : Result.no_coverage
```
(`subject` is already a kwarg; guard `subject&.def_node` — fall back to `no_coverage` if absent, as in
direct unit calls.)

**Verification:** a mutant in an uncovered method of a partly-covered file (failed sibling) →
`uncapturable`; a mutant in a covered method's uncovered line → `no_coverage`.

### U3 — Fixture + tests
**Files:** `test/fixtures/…`, `test/coverage_map_test.rb`, `test/runner_test.rb`
**Approach:** a source with **two methods** where the only test covers **one**, plus a **failed**
test targeting the file (reuse the broken-test pattern). Assert: covered method's mutants are
`no_coverage`/killed; the uncovered method's mutants are `:uncapturable` (not `no_coverage`). Keep the
existing #9 taint tests green (adjust to the new API where they call `uncapturable_source?`).

## Verification Contract
| Gate | Command | Expected |
|---|---|---|
| Suite | `cd /Users/davidteren/Projects/DT/brutus && bundle exec rake test` | all green (incl. existing #9/#19 taint tests) |
| Load | `bundle exec ruby -Ilib -e 'require "mutineer"'` | exit 0 |
| Acceptance | new coverage_map/runner tests | uncovered-method-in-partly-covered-file → `uncapturable`; covered-method uncovered line → `no_coverage`; fully-failed file → all `uncapturable` (unchanged) |

## Definition of Done
- Taint is per-method; partial-coverage case correctly split.
- Every existing test green; new tests cover the partial case + the fully-failed (no-regression) case.
- Score denominator unchanged; no new deps, no eval.

## Validation (4-lens, gaps folded)
- **Predictability (9):** `uncapturable` now means "the method's covering capture failed" precisely;
  no behavior change for fully-failed files. Name `method_uncapturable?` matches behavior.
- **Simplicity (8):** one new predicate + a range at the call site; reuses existing `@map`. No new
  status, no new capture, no config. Rejected the tempting-but-impossible "attribute the failed run's
  lines" (no data exists) in favor of method-range + successful coverage.
- **Convention (9):** CoverageMap stays file/line-only; Runner owns the Prism range — same layer split
  as the rest of the codebase.
- **Experience (8):** the summary already reports `uncapturable` vs `no_coverage` separately (#9); this
  just makes the split accurate. Verbose diagnostics unchanged.
- **Gaps resolved:** (1) ambiguity "zero-coverage method — failed-test vs true gap" → resolved by
  KTD2's documented conservative bias (only when a sibling test failed). (2) direct unit calls without
  a subject → U2 guards `subject&.def_node` → `no_coverage`. **No blocking gaps.**

**Verdict: Ready to implement.**
