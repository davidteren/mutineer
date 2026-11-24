---
title: Pair a concern with the test that mirrors its namespace - Plan
type: feat
date: 2026-11-10
issues: [379]
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Pair a concern with the test that mirrors its namespace - Plan

## Goal Capsule

- **Issue:** #379 (pair a source under `concerns/` with the test that mirrors its namespace).
- **Objective:** a Rails app can name a concern's test after its constant, such as `test/models/storage/totaled_test.rb` for `Storage::Totaled`. Mutineer then mutates and scores that concern. The user does not move the test and does not pass `--test`.
- **Means:** a fallback in `Pairing.infer_tests`, and the same path in the failed-capture check (KTD1, KTD5).
- **Authority:** this plan, then `AGENTS.md`, then the text of #379. Where this plan differs from the issue, this plan wins (see "Corrections to the issue").
- **Stop and ask when:** a change would alter the test list of a source that pairs on `main`. Stop also when the work needs an edit to `Pairing.logical_path`, to the split-file helpers or to `CoverageMap#ownership_paths`. Stop when a maintainer answers Q1, Q2 or Q4 with the alternative.
- **Size:** S. Nine files: two under `lib/`, three test files, two new fixture files, `docs/ci.md` and `CHANGELOG.md`. No new runtime dependency.
- **Delivery:** one pull request from `main`. Labels: `enhancement`, `priority: medium`, `risk: low`, `v1.9.0`. The body says `Closes #379`. A maintainer merges. This plan has no release step.

---

## Product Contract

### Summary

`Pairing.infer_tests` learns one more place to look. A source at `app/<dir>/concerns/<rest>.rb` can have no test at the `concerns/` path. Mutineer then tries the exact test names at the namespace path. The failed-capture check accepts the same path, so a failed namespace test marks the concern `uncapturable`. The change adds no flag, config key, JSON key or message, and no exit code changes its meaning.

### Problem Frame

Rails makes every `app/<dir>/concerns` directory an autoload root. So `app/models/concerns/storage/totaled.rb` defines `Storage::Totaled`, and many apps name the test after the constant: `test/models/storage/totaled_test.rb`.

Mutineer mirrors the file path only. It looks under `test/models/concerns/storage/` and finds nothing. The source is dropped with one stderr line, `no test found by convention`. Its mutants never run, and its code is absent from the score. When it is the only source, the run exits 2.

Vladimir Dementyev reported this from a Mutineer 1.8.0 run on Fizzy, a Rails 8 app. He moved two test files into `test/models/concerns/storage/` to make them pair.

### Terms

- **Concern source:** a source file at `app/<dir>/concerns/<rest>.rb`. The `concerns` directory sits directly below `app/<dir>/`.
- **`concerns/` path:** the test path that mirrors the file path. For `app/models/concerns/storage/totaled.rb` it is `test/models/concerns/storage/totaled_test.rb`.
- **Namespace path:** the same path without the `concerns/` segment: `test/models/storage/totaled_test.rb`. It mirrors the constant `Storage::Totaled`.
- **Exact name:** one of the three names `Pairing.candidates` builds: `<name>_test.rb`, `test_<name>.rb` and `<name>_spec.rb`.
- **Split name:** `<name>_*_test.rb`, such as `totaled_bytes_test.rb`.
- **Skip line:** the stderr line `[mutineer] no test found by convention for <file>; skipping` (`lib/mutineer/cli.rb:649`).

### Requirements

**Pairing**

- R1. A concern source with no `concerns/` path test pairs with the first existing exact name at the namespace path. The order is the order `Pairing.candidates` already uses, and the preferred framework goes first.
- R2. The `concerns/` path wins. When today's rules find any test for the source, exact or split, Mutineer does not try the namespace path.
- R3. No source that pairs on `main` changes its test list.
- R4. The rule applies only to a concern source. A source under `lib/concerns/`, `app/concerns/`, `app/<dir>/<sub>/concerns/` or a `concerns/` directory outside `app/` keeps today's result.
- R5. A split name at the namespace path does not pair with the concern in this change. A follow-up issue tracks it (U4).

**Failed capture and test order**

- R6. A failed capture of an exact name at the namespace path marks the concern `uncapturable`. The conditions are the ones a failed test at the `concerns/` path has today.
- R7. The namespace test runs first among the covering tests of a mutant in its concern, as every paired test does.

**Surfaces**

- R8. This change adds no flag, config key, JSON key or message. No exit code changes its meaning. A concern that still has no test prints today's skip line.
- R9. `docs/ci.md` and `CHANGELOG.md` describe the rule. Both say that a concern that was skipped can now run and change a score. Both name the follow-up issue for split names.

### Acceptance Examples

Each example names a source and the test files on disk. `C` is `app/models/concerns/storage/totaled.rb`.

- AE1. Covers R1. `C` and `test/models/storage/totaled_test.rb`: `C` pairs with that test.
- AE2. Covers R2. `C`, `test/models/concerns/storage/totaled_test.rb` and `test/models/storage/totaled_test.rb`: `C` pairs with the `concerns/` test only.
- AE3. Covers R2, R3. `C`, `test/models/concerns/storage/totaled_bytes_test.rb` and `test/models/storage/totaled_test.rb`: `C` pairs with the split file only.
- AE4. Covers R1. `app/controllers/concerns/authentication.rb` and `test/controllers/authentication_test.rb`: they pair.
- AE5. Covers R1. `C` pairs with `spec/models/storage/totaled_spec.rb`, under both framework preferences. `C` pairs with `test/models/storage/test_totaled.rb`.
- AE6. Covers R5. `C` and `test/models/storage/totaled_bytes_test.rb`: `C` gets no test.
- AE7. Covers R4. None of these four pairs: `lib/concerns/foo.rb` with `test/foo_test.rb`; `app/concerns/baz.rb` with `test/baz_test.rb`; `app/models/billing/concerns/bar.rb` with `test/models/billing/bar_test.rb`; `concerns/qux.rb` with `test/qux_test.rb`.
- AE8. Covers R1, R3. `app/models/user.rb`, `app/models/concerns/user_authentication.rb`, `test/models/user_test.rb` and `test/models/user_authentication_test.rb`: `user.rb` keeps both tests, as on `main`. The concern pairs with `user_authentication_test.rb`.
- AE9. Covers R1. `app/models/concerns/helper.rb` and `test/models/test_helper.rb`: no pairing. `test_helper.rb` is a support file.
- AE10. Covers R6. The capture of `test/models/storage/totaled_test.rb` fails, and no other test covers `C`: `uncapturable_source?` is true. The same holds for `spec/models/storage/totaled_spec.rb`.
- AE11. Covers R6. The capture of `test/models/other/totaled_test.rb` fails: `C` is not marked.
- AE12. Covers R5, R6. The capture of `test/models/storage/totaled_bytes_test.rb` fails: `C` is not marked.
- AE13. Covers R1, R8. In the fixture of U3, `mutineer run app/models/concerns/storage/totaled.rb` exits 0 and prints no skip line. The report has one killed mutant, and `TotaledTest#test_total` kills it.

### Scope Boundaries

- `Pairing.logical_path` and `Pairing.candidates` do not change.
- The split-file helpers and `CoverageMap#ownership_paths` do not change.
- `CLI.autopair!` does not change. Its skip line and the exit 2 for a run with no paired source stay.
- A dry run stays as it is. It does not pair (`lib/mutineer/cli.rb:429`), so it lists the mutants of every source.
- An explicit `--test` still turns pairing off for the run (`lib/mutineer/cli.rb:642`).

Considered and not built:

- **Run both tests when both paths have one.** Not built: it changes the test list of a source that pairs today (R3). The Fizzy tree has no such case. See Q1.
- **A warning when both paths have a test.** Not built: the second file is unused on `main` too, so nothing gets worse.
- **A guard for a twin source.** `app/models/storage/totaled.rb` beside `app/models/concerns/storage/totaled.rb` would share one test. Not built: Rails loads only one of two files that define the same constant, and the Fizzy tree has no such pair.
- **A config switch to turn the rule off.** Not built: the rule only fires for a source that has no test today.
- **Autoload roots read from the booted app.** Not built: `Pairing` is path logic with no Rails and no process (`lib/mutineer/pairing.rb:6-7`).

#### Deferred to Follow-Up Work

- Split names at the namespace path. U4 opens the issue. KTD3 gives the reason.
- Concerns with no test file named after them at either path. On Fizzy that is 20 of the 22 unpaired concerns. They need #382 (a `tests:` map in `.mutineer.yml`) or a new test. #381 (count sources skipped for having no paired test) makes them visible.
- Sources under an engine or a pack, such as `packs/x/app/models/concerns/`. `logical_path` strips only a leading `app/` (`lib/mutineer/pairing.rb:121`), so such a source mirrors no test today. #382 is the route for them.

### Corrections to the issue

- **"Runtime behaviour was not checked."** This plan checked it. On `main`, `Pairing.infer_tests` returns `[]` for the concern with a namespace test. The CLI prints the skip line and exits 2 when it is the only source. See "Probe results", row 1.
- **"Mutineer only checks `test/models/concerns/storage/totaled_test.rb`."** Not complete. It also checks `test_totaled.rb` and `totaled_spec.rb` at that path (`lib/mutineer/pairing.rb:137-148`), and split files `totaled_*_test.rb` (`lib/mutineer/pairing.rb:218-223`).
- **"Update `Pairing.infer_tests`."** Not complete. `CoverageMap#exact_failed_test?` holds a second copy of the mirror rule (`lib/mutineer/coverage_map.rb:279-293`, with `mirrored_test_dir?` at `:350-354` and `spec_mirror?` at `:364-368`). Without a change there, a failed capture of the namespace test leaves the concern's mutants `no_coverage`. Probes 2 and 12 confirmed that. R6 and U2 cover it.
- **"Keep the exact match first."** The issue does not say what happens when both paths have a test. R2 decides: the `concerns/` path wins and the namespace path is not tried.
- **Split names.** The issue does not mention `<name>_*_test.rb` files, which pairing has supported since #87 (split test files pair with their source). R5 and KTD3 decide.
- **"Rails treats `app/models/concerns/` and `app/controllers/concerns/` as autoload roots."** Not complete. Rails adds every `app/<dir>/concerns`: `railties` uses the glob `{*,*/concerns}` (`lib/rails/engine/configuration.rb`, line 43 in 7.0.4, line 76 in 7.2.4, line 78 in 8.0.5 and 8.1.4). Fizzy also has `app/jobs/concerns` and `app/mailers/concerns`. A nested `app/<dir>/<sub>/concerns` is not a root, so R4 leaves it out.
- **"Concerns contain much Rails application logic."** True, but the issue gives no size. On Fizzy before Vladimir's test moves, this rule pairs 2 of the 22 unpaired concern sources. Those 2 files hold 40 mutants. After his moves it pairs none. The other 20 concerns have no test named after them. This is the smallest of the four mapping issues by yield.
- **"He moved tests to `test/models/concerns/`."** Confirmed. Fizzy commit `f220e4832` renames `test/models/storage/totaled_test.rb` and `tracked_test.rb` into `test/models/concerns/storage/`.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The namespace path is a fallback, not a second source of tests.** `infer_tests` runs today's rules first and returns their result when it is not empty. Rejected: a union of both paths. It gives a source that pairs today more tests after an upgrade, which breaks R3. It also has no supporting data: the Fizzy tree has no concern with a test at both paths. Rejected: the namespace path first. It changes the result for every app that has both. Precedent: the first existing exact name already wins (`test/pairing_test.rb:68-72`).
- KTD2. **The fallback fires only when today's rules return nothing.** A split file at the `concerns/` path counts as a result (AE3). Rejected: fire when no exact name exists at the `concerns/` path. A source that pairs today through split files would gain a test (R3).
- KTD3. **Exact names only at the namespace path.** Rejected for this change: split names there, which one validation report asked for. That needs the longer-source rule across two directories, so it touches `split_test_files`, `claimed_by_longer_source?`, `longer_source_exists?`, `source_searches_dir?`, `CoverageMap#split_failed_test?` and `CoverageMap#ownership_paths`. It can also take a split file from a model that holds it today (AE8). That breaks R3 and needs a maintainer decision. The measured need is zero: no unpaired Fizzy concern has a split name at its namespace path. Adding it later is additive. A concern in that case still prints the skip line, so the gap stays visible.
- KTD4. **Decide on the source path, with one new helper.** A new `Pairing.namespace_base(source_rel)` returns the namespace base for `app/<dir>/concerns/<rest>.rb`, and `nil` for every other path. Rejected: strip `concerns/` inside `logical_path`. That method has callers in `lib/mutineer/coverage_map.rb` at lines 281, 331 and 1449. The change would also flip the main mirror and drop every concern that pairs at the `concerns/` path today. On Fizzy at `8112b3dba` that is 5 of 27 concern sources.
- KTD5. **The failed-capture check uses the same helper.** `CoverageMap#exact_failed_test?` accepts a failed exact name in the `test/` or `spec/` mirror of `Pairing.namespace_base`. Rejected: leave `CoverageMap` alone. Probe 12 shows the result: the report calls a broken test a coverage gap. The mutant also leaves `no_verdict` (`lib/mutineer/reporter.rb:278`), which the exit code rule counts (`lib/mutineer/reporter.rb:172-185`). Earlier pairing changes moved both places together: `test_*.rb` names in 1.2.0 (#120, a failed `test_<name>.rb` capture), and split names in 1.5.0 (#87). The check stays path-only. It does not ask whether the `concerns/` path also has a test. The existing condition bounds it: no successful capture covered the source.
- KTD6. **A concern and a shorter model can share one test file.** In AE8, `user.rb` holds `user_authentication_test.rb` as a split file on `main`. The concern now pairs with the same file. Rejected: let the concern claim the file through the longer-source rule. `user.rb` could then lose its only test (R3). `config.tests` is already a deduplicated list (`lib/mutineer/cli.rb:652`). See Q4.
- KTD7. **The repro is a plain Ruby fixture in `test/fixtures/autopair/`.** Rejected: a Rails concern in `test/fixtures/rails_app` with a run under `rake test:daemon`. Pairing runs once in `CLI.autopair!` (`lib/mutineer/cli.rb:429`), before the daemon check (`lib/mutineer/cli.rb:434`). Every backend receives the same `config.tests`, so a daemon run adds CI time and no new code path.
- KTD8. **The change ships as a minor, under `### Added`.** The issue has the `enhancement` and `v1.9.0` labels. No Action input or default changes: the Action passes `--test` only when its `test` input is set (`action.yml:149`, `:380`). The two earlier pairing changes also shipped in minor releases. See Q3.

### Assumptions

No user was present when this plan was written. These are bets, not confirmed decisions.

- A maintainer accepts that a gate can change after an upgrade, because a concern that was skipped now runs (Q3).
- A maintainer accepts the delay of split names at the namespace path (Q2).
- One app is enough to size the rule. Only Fizzy was measured.

### Probe results

All probes ran on the worktree at `origin/main` `8d9905c4`. Fizzy was read as a path list with `git ls-tree`. No Fizzy code ran.

| # | Question | Result |
|---|---|---|
| 1 | Does `main` skip a concern whose only test is at the namespace path? | Yes. `infer_tests` returns `[]`. The CLI prints the skip line and exits 2. A dry run still lists the source's mutants. |
| 2 | Does a failed capture of the namespace test mark the concern? | No. `uncapturable_source?` is false. For the same test at the `concerns/` path it is true. |
| 3 | Does a model already take a longer-named concern's test? | Yes. `user.rb` pairs with `user_test.rb` and `user_authentication_test.rb`. The concern pairs with nothing. |
| 4 | How many Fizzy sources does the rule pair before Vladimir's test moves (`8112b3dba`)? | 2 of 22 unpaired concern sources: `storage/totaled.rb` and `storage/tracked.rb`. 20 stay unpaired. Unpaired sources in `app/models` and `app/controllers`: 106 of 292, as his report says. |
| 5 | How many after his moves (`f220e4832`)? | 0 of 17 unpaired concern sources. Unpaired in `app/models` and `app/controllers`: 92 of 292, as his report says. |
| 6 | How many mutants do the 2 files hold? | 40 with the default operators: 23 and 17. His report gives the same two numbers. His report counts 312 unpaired mutants in total; this plan did not measure that total again. |
| 7 | How common are split names in Fizzy? | 1 of 352 sources under `app/` pairs with a split file. No unpaired concern has a split name at its namespace path. |
| 8 | Does any Fizzy concern have a test at both paths, or a twin source? | No, at both revisions. |
| 9 | Does a prototype of R1 to R7 hold? | Yes. 14 checks with 35 assertions pass. On `main`, 6 of them fail and 1 errors; the other 7 are guards that pass on both. |
| 10 | Does the prototype break existing tests? | No. `test/pairing_test.rb`: 49 runs, 95 assertions, green. The failed-capture and order tests in `test/coverage_map_test.rb`: 21 runs, 39 assertions, green. |
| 11 | Does the U3 fixture give a stable verdict? | Yes. With the prototype: exit 0, 1 `arithmetic` mutant, killed by `TotaledTest#test_total`, score 100.0. On `main`: exit 2. |
| 12 | What does U2 change in a run? | Two sources ran: one with a passing test, and the concern with a namespace test that fails to load. With U1 only, the concern's mutant reads `no_coverage` and `no_verdict` is empty. With U1 and U2 it reads `uncapturable` and is in `no_verdict`. With the concern as the only source, the run stops with exit 1 in both cases. |

Because the prototype passed, this plan has no spike unit.

Not checked:

- The full suite, `rake yard:strict` and `rake test:daemon` with the prototype. The planning rules allow one test file per claim.
- A run on a real Rails app with the rule. Fizzy is read-only and needs an install step.
- An RSpec run end to end. AE5 is checked at the `Pairing` level only.
- Other Rails apps. Only Fizzy was measured.

### System-Wide Impact

| Sibling | Result | Evidence |
|---|---|---|
| Reload and redefine | Same pairing. Pairing ends before a strategy runs. | `lib/mutineer/cli.rb:353-356`, `:429` |
| Daemon and in-process | Same pairing, and the same failed-capture check. Both use `JobPlan.coverage_selection`. | `lib/mutineer/cli.rb:429-434`, `lib/mutineer/job_plan.rb:229-287` |
| `--test-command` | Same pairing through `autopair!`. It has no coverage narrowing, so U2 does not apply. | `lib/mutineer/runner.rb:229-234` |
| Action and CLI | The Action has no pairing logic. It passes `--test` only when the input is set. | `action.yml:149`, `:380` |
| Report and dry run | The report gains the concern in `per_source`. The dry run does not pair and does not change. | `lib/mutineer/cli.rb:429`, probe 1 |
| Minitest and RSpec | Both name forms pair (AE5). | `lib/mutineer/pairing.rb:137-148` |
| Explicit `--test` | Pairing stays off. U2 still marks a concern when its explicit namespace test fails. | `lib/mutineer/cli.rb:642` |
| Test order | The namespace test sorts first for its concern (R7). | `lib/mutineer/coverage_map.rb:170-180` |
| Coverage cache | A newly paired test joins the digest, so the cache rebuilds once. The owner list does not change. | `lib/mutineer/coverage_map.rb:1415-1434` |

---

## Implementation Units

### U1. Namespace fallback in `Pairing.infer_tests`

**Goal:** a concern with no test at the `concerns/` path pairs with the exact name at the namespace path.

**Requirements:** R1, R2, R3, R4, R5, R7. AE1 to AE9.

**Dependencies:** none.

**Files:**

- `lib/mutineer/pairing.rb`: add `Pairing.namespace_base` (new) with a YARD comment. Extend `infer_tests` (lines 103-110). Update the module comment (lines 6-22) and the `infer_tests` comment (lines 93-102).
- `test/pairing_test.rb`: new tests below.
- `test/coverage_map_test.rb`: one order test.

**Approach:**

1. `namespace_base` matches `app/<dir>/concerns/<rest>.rb` on the source path and returns `<dir>/<rest>` (KTD4).
2. `infer_tests` keeps today's body. The fallback runs only when that result is empty and `namespace_base` gives a base (KTD2). It returns the first existing path from `candidates` for that base (KTD1).
3. The fallback passes `lib: false`. A qualifying source is always under `app/`.
4. `candidates` already skips `test_helper.rb` and sets the framework order. The fallback inherits both.

**Patterns to follow:** the `with_tree`, `infer` and `infer_tests` helpers (`test/pairing_test.rb:12-29`). The guard-style tests for split files (`test/pairing_test.rb:214-239`).

**Test scenarios** (`test/pairing_test.rb`; "guard" means the test passes before and after):

- `test_namespace_base`: `app/models/concerns/storage/totaled.rb` gives `models/storage/totaled`. `app/controllers/concerns/authentication.rb` gives `controllers/authentication`. These give `nil`: `lib/concerns/foo.rb`, `app/concerns/baz.rb`, `app/models/billing/concerns/bar.rb`, `concerns/qux.rb`, `app/models/concerns.rb`, `models/concerns/x.rb`, `app/models/user.rb`. Fails before: no such method.
- `test_concern_pairs_with_the_test_at_its_namespace_path`: Covers AE1. Fails before: `[]`.
- `test_concerns_path_wins_over_the_namespace_path`: Covers AE2. Guard for R2.
- `test_split_file_at_the_concerns_path_blocks_the_namespace_fallback`: Covers AE3. Guard for R2 and R3.
- `test_controller_concern_pairs_at_the_top_level_namespace_path`: Covers AE4. Fails before.
- `test_concern_namespace_fallback_accepts_spec_and_test_prefix_names`: Covers AE5. Asserts the spec under `prefer: "minitest"` and `prefer: "rspec"`, and the `test_totaled.rb` name. Fails before.
- `test_split_file_at_the_namespace_path_does_not_pair_a_concern`: Covers AE6. Guard for R5. A comment names the follow-up issue.
- `test_only_a_concerns_dir_directly_below_an_app_dir_falls_back`: Covers AE7. Guard for R4.
- `test_model_keeps_its_split_file_when_a_concern_shares_it`: Covers AE8. The `user.rb` half is a guard for R3. The concern half fails before.
- `test_helper_concern_does_not_pair_with_test_helper`: Covers AE9. Guard.
- Every existing test in the file stays green unchanged. That is the proof of R3 at this level.

`test/coverage_map_test.rb`:

- `test_order_tests_puts_a_concern_namespace_test_first`: a map from `CoverageMap.from_data` with the AE1 tree and one more test path. `order_tests` returns the namespace test first. Fails before: path order. Pattern: `test_order_tests_puts_paired_files_first_then_the_cheapest` (line 799).

**Verification:** the new tests fail before the change and pass after. No existing test changes.

### U2. Failed-capture check for the namespace path

**Goal:** a failed capture of the namespace test marks the concern `uncapturable`, not `no_coverage`.

**Requirements:** R6. AE10, AE11, AE12.

**Dependencies:** U1 (`Pairing.namespace_base`).

**Files:**

- `lib/mutineer/coverage_map.rb`: `exact_failed_test?` (lines 279-293). Update its comment (lines 270-278). A new private helper needs a YARD comment.
- `test/coverage_map_test.rb`: new tests below.

**Approach:**

1. Change the branch for an `app/` or `lib/` source. It accepts two more directories: the `test/` and `spec/` mirrors of `Pairing.namespace_base(source_rel)` (KTD5).
2. Build each directory with `Pairing.mirror_dir`, so a top-level concern maps to `test/<dir>` itself.
3. Leave `split_failed_test?`, `mirrored_test_dir?`, `spec_mirror?` and `ownership_paths` unchanged (R5, KTD3).

**Patterns to follow:** `test_failing_exact_spec_in_the_mirror_marks_the_source_uncapturable` (`test/coverage_map_test.rb:1426`) for the tree, the failing test body and the `capture_subprocess_io` wrap.

**Test scenarios:**

- `test_failing_namespace_test_marks_the_concern_uncapturable`: Covers AE10. One case with `test/models/storage/totaled_test.rb`, one with `spec/models/storage/totaled_spec.rb`. Each test file holds `require 'does/not/exist'`. Asserts `uncapturable_source?` is true. Fails before: false.
- `test_failing_same_name_outside_both_mirrors_does_not_taint_the_concern`: Covers AE11. Guard.
- `test_failing_split_name_at_the_namespace_path_does_not_taint_the_concern`: Covers AE12. Guard for R5.
- `test_failed_exact_name_in_another_mirror_does_not_taint_that_source` (line 1481) stays green unchanged.

This seam checks the path rule on a real failed capture. It does not check the report label of a full run. `JobPlan.coverage_selection` turns the answer into the `uncapturable` verdict, and existing tests cover that step.

**Verification:** the first test fails before the change and passes after. The existing failed-capture tests pass unchanged.

### U3. Repro fixture with expected verdicts

**Goal:** the reported case lives in the repo as a fixture, with its verdicts pinned.

**Requirements:** R1, R8. AE13.

**Dependencies:** U1.

**Files:**

- `test/fixtures/autopair/app/models/concerns/storage/totaled.rb` (new): a plain Ruby module `Storage::Totaled` with one method, `total(used, reserved)`, that returns `used + reserved`. No Rails.
- `test/fixtures/autopair/test/models/storage/totaled_test.rb` (new): a Minitest class `TotaledTest` that includes the module and asserts `total(2, 3)` is 5. It loads the source with `require_relative`.
- `test/cli_test.rb`: one test, placed after `test_orphan_source_warns_and_is_skipped` (lines 1359-1368).

**Approach:** the other users of this fixture run `lib` or `lib/calc.rb` only (`test/cli_test.rb:1325`, `:1340`, `:1362`, `:1424`). The two new files do not change their results. `Rakefile:23` keeps fixture tests out of the suite (KTD7).

**Patterns to follow:** `with_autopair_project` (`test/cli_test.rb:1314-1319`) and the `matrix` assertions near `test/cli_test.rb:519-524`.

**Test scenarios:**

- `test_concern_pairs_with_its_namespace_test_and_is_scored`: Covers AE13. Runs `run app/models/concerns/storage/totaled.rb --matrix --format json` in the fixture copy. Asserts exit 0. Asserts stderr has no `no test found by convention`. Asserts `per_source` names only the concern. Asserts `summary` has `total` 1, `killed` 1 and `score` 100.0. Asserts `matrix.tests` has one row with `file` `test/models/storage/totaled_test.rb`, `name` `TotaledTest#test_total` and `kills` 1. Asserts the mutant row has `status` `killed` and `killed_by` `[0]`. Fails before: exit 2 and the skip line.

**Verification:** the test fails on `main` with exit 2, and passes after U1.

### U4. Docs, CHANGELOG and the follow-up issue

**Goal:** users can read the rule, and the delayed part has an issue number.

**Requirements:** R5, R9.

**Dependencies:** U1, U2.

**Files:**

- `docs/ci.md`: one row in the pairing table (lines 36-41), after the `app/foo/bar.rb` row.
- `CHANGELOG.md`: one entry under `### Added` in `## [Unreleased]`. Add that heading above `### Fixed` when it does not exist yet.

**Approach:**

1. Open a GitHub issue named "Pair split test files at a concern's namespace path", with the labels `enhancement` and `priority: low`. Its body states R5, KTD3 and probe 7.
2. The `docs/ci.md` row: source `app/models/concerns/storage/totaled.rb`. Pairing: `test/models/concerns/storage/totaled_test.rb` first; with no test there, the exact test at the namespace path, `test/models/storage/totaled_test.rb`, `test_totaled.rb` or `spec/models/storage/totaled_spec.rb`. Split files pair only at the `concerns/` path, with the issue number.
3. The CHANGELOG entry is titled "A concern pairs with the test that mirrors its namespace (#379)". It says these things, in this order:
   - The new paths, with the `Storage::Totaled` example.
   - The fallback order, so a source that paired before keeps its tests.
   - The old result: the skip line and no score.
   - The effect: a concern that was skipped can now run, so a score or a gate can change.
   - The `--baseline` effect: survivors in a newly paired concern count as new. The entry tells the user to refresh the baseline (`docs/ci.md`, "Refresh the baseline").
   - The failed-capture change.
   - The split-name limit and its issue number.
4. Do not copy the reporter's private gist link from the issue body. That holds for every file and for the pull request text.

**Test scenarios:** Test expectation: none. This unit is documentation.

**Verification:** `docs/ci.md` and `CHANGELOG.md` name #379 and the follow-up issue. The site build passes.

---

## Verification Contract

Prefix every `ruby`, `rake` and `bundle` command with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` in a shell where they are unset.

- `bundle exec ruby -Ilib -Itest test/pairing_test.rb`: U1, and R3 at the `Pairing` level.
- `bundle exec ruby -Ilib -Itest test/coverage_map_test.rb`: the U1 order test, and U2.
- `bundle exec ruby -Ilib -Itest test/cli_test.rb -n "/concern|autopair|orphan|unpaired/"`: U3, and the unchanged skip line and exit 2. The run must report more than 0 tests.
- `bundle exec rake test`: the zero-dependency suite.
- `ruby -Ilib -e 'require "mutineer"'`: the load smoke.
- `bundle exec rake yard:strict`: `Pairing.namespace_base` and any new private helper have a doc comment.
- `bundle exec rake site:build`, then `node --test test/site_test.js`: `docs/ci.md` is a published page (`docs/llms.txt:33`).

Not required: `bundle exec rake test:daemon` (no Rails-dependent test; CI runs it) and the Minitest 6 Gemfile (no change to the Minitest integration).

Run each new test once on `main` before the change. The tests marked "Fails before" must fail there.

## Definition of Done

- Every test named in U1 to U3 exists. Each test marked "Fails before" failed before its unit and passes after.
- Every existing test passes with no edit. That is the proof of R3.
- `mutineer run app/models/concerns/storage/totaled.rb` in the fixture exits 0 with one killed mutant.
- A concern with no test at either path still prints `no test found by convention` and is skipped.
- `docs/ci.md` and `CHANGELOG.md` describe the rule and name the follow-up issue. The CHANGELOG entry has the `--baseline` note.
- `bundle exec rake yard:strict` reports 100%.
- The pull request has the four labels and `Closes #379`. No file or pull request text holds the private gist link.
- No dead code or abandoned attempt remains in the diff.

---

## Risks and Overlaps

| Item | Overlap | Handling |
|---|---|---|
| A score or gate changes after an upgrade | A concern that was skipped now runs. Its survivors lower the score. A `--baseline` gate reports them as new survivors (`lib/mutineer/baseline.rb:133-141`, `:170`). | Intended. The CHANGELOG entry says so and tells the user to refresh the baseline. Same as #87 (split test files) in 1.5.0. See Q3. |
| Plan for #381 (count sources skipped for having no paired test) | Changes `CLI.autopair!` and uses a copy of the `autopair` fixture. After this change, fewer sources are unpaired. Both plans edit `docs/ci.md` near the pairing table, and `test/cli_test.rb`. | No shared code: this plan does not touch `lib/mutineer/cli.rb`. The #381 tests run `lib` in the fixture, so the new concern files do not change them. Text conflicts only. Either merge order works. Two validation reports want #381 first or in the same release. |
| Plan for #382 (a `tests:` map in `.mutineer.yml`) | Adds mapped tests to the paired tests, and adds functions to `lib/mutineer/pairing.rb`. | The namespace fallback is part of the paired result. The fallback does not look at mapped tests. Both plans edit the module comment (`lib/mutineer/pairing.rb:6-22`) and the `docs/ci.md` table: text conflicts only. |
| Plan for #380 (let `--test` take a directory or a glob) | Adds an expansion method to `lib/mutineer/pairing.rb` and edits its module comment (lines 6-22). | Different methods. The module comment is a text conflict for the plan that lands second. This plan does not edit `candidates` or `logical_path`. |
| #201 (split `coverage_map.rb` into smaller units) | May move `exact_failed_test?`. | U2 is a small edit in one method. Rebase onto whichever lands first. |
| #391 (the reload fix for Rails class bodies) | Adds `app/models/concerns/trackable.rb` and `test/models/concerns/trackable_test.rb` to `test/fixtures/rails_app`. | No overlap. That test sits at the `concerns/` path, and the dogfood script passes `--test`. |
| #395 (the Action asks the CLI for cache_dir and baseline) | Edits `test/cli_test.rb` and `CHANGELOG.md`. | The U3 test is an insert at one place. Text conflict only. This plan checked the branch by file name, not by content. |
| 2.0 pull requests #244 (the 2.0 contract flip) and #245 (parallel Rails runs by default) | Each edits `test/cli_test.rb` and `CHANGELOG.md`. | Same handling as #395. |
| 2.0 pull requests #314 (baseline and unverified survivors) and #322 (count tested `ran_at_load` mutants) | Each edits `test/cli_test.rb` and `CHANGELOG.md`. | Same handling as #395. |
| Every other open pull request | Each adds a `CHANGELOG.md` entry under `## [Unreleased]`. | Text conflict only. |
| A shared test file | In AE8 a model and a concern pair with one test. | Kept on purpose (KTD6). `config.tests` is deduplicated. See Q4. |
| One validation report asked for split names and `ownership_paths` in this change | This plan delays them. | KTD3 gives the reason and probe 7 the measurement. Q2 lets a maintainer reverse it. |
| The issue body links the reporter's private gist | A copy would spread the link. | U4 step 4 and the Definition of Done forbid it. |

## Open Questions

None blocks implementation. Each has a default that this plan uses.

- Q1. When both paths have a test, should both run? Default: no, the `concerns/` path wins (KTD1). A maintainer decides. The union is additive later, but it changes test lists.
- Q2. Should split names at the namespace path pair in this change? Default: no, U4 opens a follow-up issue (KTD3). A maintainer decides.
- Q3. Is a minor release right when a gate can change? Default: yes, `v1.9.0`, as for the two earlier pairing changes (KTD8). A maintainer decides at release time.
- Q4. Should a concern take its namespace test away from a shorter model (AE8)? Default: no, they share it (KTD6). A maintainer decides together with Q2, because both need the longer-source rule.

## Sources

- `lib/mutineer/pairing.rb:103-148` (`infer_tests`, `logical_path`, `candidates`), `:218-357` (split files and the longer-source rule).
- `lib/mutineer/coverage_map.rb:170-180` (`order_tests`), `:263-368` (failed-capture checks), `:1442-1470` (`ownership_paths`).
- `lib/mutineer/cli.rb:417-444` (`validate!`), `:641-660` (`autopair!`), `:898-930` (`dry_run`).
- `lib/mutineer/job_plan.rb:229-287` (`coverage_selection`, shared by the daemon and in-process paths).
- `lib/mutineer/reporter.rb:172-185` and `:278` (the exit code and `no_verdict` count `uncapturable`, not `no_coverage`). `lib/mutineer/baseline.rb:133-141` (new survivors).
- `CHANGELOG.md:1101-1124` (#87, split test files, 1.5.0) and `:1351-1357` (`test_*.rb` names, 1.2.0): the two earlier pairing changes.
- Vladimir Dementyev's Fizzy report, sections "Missing parts" and "Unpaired sources".
- Three validation reports of 2026-11-09. They agree that #379 is real and small. One counts 2 files and 40 mutants, as probes 4 and 6 do. One asks for split-name and `ownership_paths` changes (KTD3).
- Probe scripts and output, machine-local and best effort: `/private/tmp/claude-501/-Users-davidteren-Projects-claude-worktrees-mutineer-vladimir-issues-planning-21adcb/ae564be8-638b-4dd0-a9e5-9d7a58cb00ae/scratchpad/context/probes/379/`. A missing folder is not a blocker: the "Probe results" table holds every number, and this plan governs any difference.
