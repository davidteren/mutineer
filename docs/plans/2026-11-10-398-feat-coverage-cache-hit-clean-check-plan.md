---
title: Check only the covering tests on a coverage cache hit, then invalidate per test - Plan
type: feat
date: 2026-11-10
issues: [398]
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Check only the covering tests on a coverage cache hit, then invalidate per test - Plan

## Goal Capsule

- **What:** Start mutants sooner on cache hits and keep unaffected coverage entries after edits.
- **Why:** #398 (a coverage cache hit still runs the full clean check, so any edit costs a full capture) names two costs: full clean checks on hits and full captures after edits.
- **How:** Deliver three steps in three pull requests.

| Step | Scope | Gate |
|---|---|---|
| Step A, U1 to U3 (measurement, implementation and documentation) | Check only tests that cover the run's sources. Speeds up unchanged reruns; every edit still misses. | Independent of Step B |
| Step B1, U5 (test and source invalidation) | Recapture affected tests after test-file edits or edits inside run-source `def` bodies. Other edits force full capture. | U4 spike, part 1 passes |
| Step B2, U6 (other project-file invalidation) | Extend B1 through each test's executed-file list. | U4 spike, part 2 passes |

- **Authority:** this plan, then `AGENTS.md`, then the text of #398. This plan wins conflicts; see "Corrections to the issue".
- **Stop and ask:** A change could let a test that fails without mutants reach a mutant run. A change could alter scores, exit codes or mutant test selection versus full capture, under R6 and R16 (behaviour guarantees). Also stop if #201 (split `coverage_map.rb` into smaller units) gains branch code, or the U4 spike fails.
- **Size:** Step A is S (small): 1 `lib/` file, 2 test files, 1 fixture file and 3 docs files. B1 is M (medium): 1 `lib/` file, 2 test files, 2 docs files and a cache-format change. B2 is M (medium), with the same files. No new runtime dependency; Prism is already a dependency.
- **Delivery:** Open each pull request from `main`, in order. Use `enhancement` (feature) and `v1.9.0` (target release) labels. B1 and B2 target `v1.9.0` tentatively; move missed work to the next minor. All three are minor changes under KTD9 (version classification). No Action input, output or default changes.
  - Step A says `Refs #398`; it does not meet "Done when".
  - B1 says `Closes #398` only if its Fizzy result meets U4's time rule. Otherwise, use `Refs #398`.
  - If U4 fails, keep #398 open and file a per-test invalidation follow-up. A maintainer may close #398 in its favour.
  - A maintainer merges. This plan has no release step.

---

## Product Contract

### Summary

A hit checks every `--test` file alone, then together (`lib/mutineer/coverage_map.rb:404-405`, `:776-788`, `:819-830`). A miss captures every file, then checks them together (`:410-411`). Thus, a hit can cost almost as much as a miss.

Step A checks only files covering the run's sources, alone and together. Mutants use those files (`lib/mutineer/job_plan.rb:261-286`), so every verdict-relevant test remains checked. B1 recaptures tests affected by test-file or run-source method-body edits. B2 extends this to other project files.

### Problem Frame

Vladimir ran Mutineer on Fizzy, a Rails 8 app, with the whole suite as `--test`. The first mutant takes about 6 minutes; any edit repeats that cost (`vladimir-fizzy-report.md` lines 21 and 438). He requested per-source invalidation for an edit loop.

Any source, test or loaded project-file edit misses the cache. The digest and dependency list cover the whole run (`coverage_map.rb:1415-1418`, `:1387-1395`). Hits also run the full clean check. Step A reduces hit cost. Only Step B reduces edit cost and can meet "Done when".

### Terms

| Term | Meaning |
|---|---|
| Covering test | A test file in a map entry: it ran a source line. `reuse_capture` computes `@map.values.flatten` (`coverage_map.rb:436`). |
| Clean-check set | Covering tests, or every test for an empty map under R3 (empty-map fallback). Defined only by `clean_check_test_paths`. |
| Clean check | Unmutated test runs that prove tests pass. Alone: one file per process (`verify_cached_clean`, `:776`). Together: all selected files in one process (`verify_combined_clean`, `:819`). |
| Hit / miss | Reuse coverage (`cached_or`, `:390-407`) / capture again (`:410-413`). |
| File skeleton, Step B | Prism tree without `def` bodies. Body edits preserve it. Class bodies, constants, macros such as `validates`, `has_many` or `enum`, `include`, and top-level edits change it. |
| Executed files, Step B2 | Project files with a non-zero line or method count in a test's capture. |

### Requirements

**Step A: narrow the clean check**

- R1 (hit check). On hits, check the clean-check set alone, excluding failed captures. A covering test that fails alone stops the run.
- R2 (together check). Use the clean-check set, excluding failed captures, on hits, misses and `--coverage-from`. Skip when fewer than two tests remain (`coverage_map.rb:821`).
- R3 (empty-map fallback). Both checks use every test when the map is empty. The daemon then uses every test for each mutant (`lib/mutineer/daemon_backend.rb:258-269`).
- R4 (skipped-test report). Print one stderr line when either check skips a test; see "Report text". On misses, report only together-check exclusions. Capture already ran every test alone.
- R5 (backend consistency). In-process `--rails`/`--boot`, standalone and `--daemon` behave alike. All call `cached_or` (`lib/mutineer/runner.rb:149-158`, `:169-175`, `lib/mutineer/daemon_server.rb:281-287`). `--test-command` builds no map and stays unchanged (`lib/mutineer/runner.rb:232-236`).
- R6 (behaviour guarantee). Preserve scores, exit codes and mutant test selection, except AE3 (a non-covering red test no longer stops a hit).
- R14 (no duplicate alone check). Skip the alone check for tests captured this run. Capture already forks and runs each test; failure adds it to `@failed_clean_tests` (`coverage_map.rb:760-761`). Currently, `retry_failed_captures` (`:796-811`) recaptures a test before `verify_cached_clean` runs it alone again.
- R17 (selection contract). Include every test that `JobPlan.coverage_selection` can return. New mutant-selection paths must add their tests to `clean_check_test_paths`. Pin this contract with a test.

**Step B: invalidate per test (B1 after U4 part 1 passes, B2 after U4 part 2 passes)**

- R7 (B2 file data). Store one `files` table mapping relative paths to content fingerprints and skeleton digests. Each test stores only its executed relative paths, from line and method counts (`coverage_map.rb:650-652`).
- R8 (shared run inputs). Add `run_inputs` for full-miss inputs that are not per-test data. Include boot file, `--require` files, load paths, framework, seed, source list and owner files (`coverage_map.rb:1415-1433`, `:1405-1407`). Also include the forced-reloading flag that #389 KTD13 adds to the digest, when present. Both modes write it. A difference forces full capture.
  - Preserve `inputs`, `digest` and `dependencies` for older versions and `--coverage-from` (`capture_mismatch`, `:470-505`).
  - Replace the `digest` comparison and `dependencies_match?` hit conditions at `:390-392`. Keep `load_methods`, `timings` and `parallel_workers_match?`.
- R9 (test invalidation). Otherwise, recapture changed test files, new `--test` files and previously failed captures. Remove tests no longer in `--test`. Keep other map entries.
  - B1: For run-source edits confined to `def` bodies under R15 (skeleton gate), recapture tests in that source's map entries. Changes to other `dependencies` files force full capture.
  - B2: For project-file edits confined to `def` bodies, recapture tests that executed the file.
- R10 (standalone limit). Standalone capture loads every source (`coverage_map.rb:1571`); source edits therefore recapture every test. File this limit in the B1 pull request, U5.
- R11 (partial-recapture check). Capture supplies the alone check for recaptured tests, under R14. Run kept clean-check tests alone, then the whole clean-check set together. Print the Step A line using that set's counts.
- R12 (old-cache migration). Rebuild caches without per-test data once, as with `load_methods` and `timings` (`coverage_map.rb:391`, `test/coverage_map_test.rb:838`).
- R13 (capture compatibility). `--coverage-from` must read Step B caches.
- R15 (skeleton gate). A changed skeleton digest forces full capture. Body edits to `@load_methods` methods also count as skeleton changes because those methods ran at load (`coverage_map.rb:56-62`).
- R16 (map equality). After every edit, partial and full captures must produce equal maps. R6 also applies to Step B. U4 verifies this.

### Acceptance Examples

- AE1 (covering-only hit; R1). Copy the fixture; use source `app/models/order.rb` and five model tests. The second run hits. Check `order_test.rb`, `order_weak_test.rb` and `order_subtotal_only_test.rb` alone. Skip `price_list_test.rb` and `billing/fee_test.rb`; probe 2 identifies this set.
- AE2 (covering failure; R1). A covering test turns red without a file change, using `test/coverage_map_test.rb:296`'s marker pattern. Stop the hit with today's message.
- AE3 (non-covering failure; R2, R4). A non-covering test turns red without a file change. Continue the hit; report 1 covering test checked and 1 other skipped. A miss still stops, under #96 (unrelated red tests abort runs).
- AE4 (empty map; R3). Check every test on a hit.
- AE5 (source-body edit; R9, B1). With source `app/models/order.rb`, edit a method body in `order.rb`. Today, all five tests recapture. B1 recaptures only the three covering tests.
- AE6 (declaration edit; R15, B1). Add `validates` to `app/models/order.rb`. Capture every test, as today.
- AE7 (other-file body edit; R9, B2). Edit a method body in non-source `app/models/price_list.rb`. Today, all five tests recapture, as probe 3 shows. B2 recaptures only tests that executed `price_list.rb`.

### Scope Boundaries

In scope: hit clean checks, together checks in all three paths, stderr lines, docs and spike-gated Step B.

Out of scope:

- Selection by mutants kept by `--since` or `--only`. Map creation precedes `collect_jobs` and `scope_since` (`lib/mutineer/runner.rb:149-182`). Reordering belongs to #396 (an in-process `--since` run builds the full map when no changed line holds a mutant). See Q2 (later narrowing).
- Context-keyed maps in one directory, from validation report Sol A11 (cache analysis). Separate `--cache-dir` values already provide this.
- A `--test-command` cache; this mode has no map.
- Together-check ordering: #282 and #338 (test order and seed).
- Naming failed clean tests: #360 (missing failure names).

### Corrections to the issue

1. **"Run the clean check only for the tests that cover the selected mutants."** Selected mutants do not yet exist. `Runner.execute` builds the map and calls `abort_if_unclean!` at `lib/mutineer/runner.rb:149-177`. Collection and scoping follow at `:180-182`. Use tests covering any run-source line, as `reuse_capture` does (`coverage_map.rb:430-438`).
2. **"Reuse the existing `reuse_capture` path."** It narrows only the alone check. Its `verify_combined_clean` call (`coverage_map.rb:439`) still uses all `@test_paths` (`:820`), retaining a full-suite run. R2 narrows this too; update `test/coverage_map_test.rb:510-511`.
3. **"A hit costs about as much as a miss" (miss 19.95 s, hit 20.48 s).** Probe 1 did not reproduce those numbers. With five fixture tests, `cached_or` took 1.20 s on a miss, then 0.63 s and 0.62 s on hits. Whole-run times were 3.59 s and 2.68 s. Both paths fork per file, then run together; the gap shrinks as test time grows. The issue cites Opus validation report A11 (cache analysis), marked "not rerun".
4. **"Invalidate only the entries for the tests whose dependencies changed."** No per-test dependencies exist. `@loaded_dependencies` is run-wide, filled at `coverage_map.rb:1344-1356` and saved at `:1540`. The digest includes every source and test (`:1417-1418`). Forks report project files from `$LOADED_FEATURES`, including parent-loaded files (`:1326-1337`). Fizzy eagerly loads the app through its `--require` file (`fizzy-palkan/test/mutineer_boot.rb:5`). Parents load those files at `lib/mutineer/runner.rb:136` and `lib/mutineer/daemon_server.rb:177`. Thus, every Fizzy test "depends" on every app file; loaded-file keys cannot separate tests. Step B instead uses executed files and skeletons under KTD5 and KTD8 (invalidation design), gated by U4.
5. **"407 dependencies for 10 tests."** Confirmed: Fizzy's `.mutineer/coverage.json` contains 407 dependencies, 10 timed tests and 9 covering tests, from probe 4.
6. **"Done when: a second run after an edit to one model starts its first mutant in a small part of the full capture time."** Central models such as `Card` run in most tests. Exact invalidation can therefore recapture most tests. Name the model and report first-mutant time as a share of full capture time, under U4 and U5.
7. **Backends.** In-process boot, standalone and daemon runs use the cache, under R5; `--test-command` does not. Only in-process boot supports `--coverage-from` (`lib/mutineer/runner.rb:156`); the daemon passes none (`daemon_server.rb:281-287`).
8. **Empty map.** The issue omits this case. The daemon then runs every test per mutant (`daemon_backend.rb:258-269`), so R3 must retain all checks.
9. **Step 1 alone does not meet "Done when".** Issue Step 1 speeds up hits only. Edits still change the digest (`coverage_map.rb:1417-1418`); misses capture every test (`:410-411`, `:582-584`). Only Step B can meet that condition.
10. **Step 3: "a test that is red without mutants must still stop the run or be reported."** Today, #96 (unrelated red tests abort runs) stops any red test (`test/boot_mode_test.rb:68-75`). Step A preserves this on misses: failed captures record no coverage, so their coverage is unknown (`coverage_map.rb:760-763`). Hits skip and report red tests outside the clean-check set, under R4. Q5 (cache-state behaviour and version classification) asks the maintainer to accept this difference.

---

## Planning Contract

### Key Technical Decisions

- KTD1 (selection boundary). **Select by run sources.** `clean_check_test_paths` serves `reuse_capture`, the hit branch and `verify_combined_clean`. Reject moving `collect_jobs` and `scope_since` before map creation: this reorders `Runner.execute` and daemon execution, belonging to #396. Q2 tracks the follow-up. Reject `covering_test_paths` as a name because empty maps return every test.
- KTD2 (together-check scope). **Narrow all three paths.** Mutants load covering tests only (`job_plan.rb:261-286`). Non-covering tests never share their process, so failures requiring those tests cannot affect verdicts. R17 extends this contract to new selection paths, including #397 (class-body macro mutation). Reject checking every test together: this retains one full-suite run per hit.
- KTD3 (empty-map safety). **Keep every test for empty maps.** The daemon uses every test then, under R3. Checking none would let red tests reach daemon mutants.
- KTD4 (visible exclusions). **Report skipped tests once on stderr.** Apply "count what you exclude"; print only when at least one test is skipped. Silence hides changed behaviour. Reject `--verbose`-only reporting: the daemon passes no `verbose` to `CoverageMap` (`daemon_server.rb:281-286`). Q1 (report frequency) asks the maintainer.
- KTD5 (B2 dependencies). **Use executed files.** Fork children already read `Coverage.result` before source filtering (`coverage_map.rb:650-652`). Record project files with non-zero line or method counts. Loaded-file keys fail on eager-loaded apps; see correction 4. Per-source keys are insufficient in Sol A11, Grok A11 and Opus A11 (cache analyses). Executed files also need KTD8's gate.
- KTD6 (map correctness). **Accept no known map gap.** Fork children clear boot coverage before each test (`coverage_map.rb:646`). Parent-only execution, such as eager-loaded `validates`, appears in no test's executed files. Executed-file keys alone would miss these edits. KTD8 forces full capture for them. R16 and U4 require equality after every edit. Changed `run_inputs` or deletion of `.mutineer/coverage.json` forces full capture. Reject stale maps until later captures: they can silently omit killing tests and alter scores.
- KTD7 (delivery gates). **Ship each B part only after its U4 part passes.** If part 1 fails, ship A alone and file per-test invalidation with the spike results. If only part 2 fails, ship B1 and file B2 separately.
- KTD8 (partial-capture gate). **Compare skeleton digests.** An unchanged skeleton means only `def` bodies changed. Recapture tests that ran the method; otherwise, capture every test.
  - Reject recapturing tests that loaded the file: eager-loaded apps recapture everything with more code.
  - Reject one Step B. B1 needs no new per-test execution data; source map entries already list tests (`coverage_map.rb:151-153`). It covers model-or-test edit loops. B2 adds executed-file lists after U4 part 2.
- KTD9 (version classification). **Use a minor release.** Step A changes AE3's exit outcome: non-covering red tests no longer fail hits. Verdicts stay unchanged because those tests never run with mutants. No Action input, output or default changes. However, the Action can pass where a miss would fail. State this in CHANGELOG; Q5 permits a different maintainer decision.

### Assumptions

- Non-covering tests never run with mutants. `JobPlan.coverage_selection` reads only the map (`job_plan.rb:261-286`). In-process `run` and daemon `job_result` both call it (`job_plan.rb:228-230`). Verified by reading. R3 covers the daemon's empty-map exception.
- The #397 plan adds `Pairing.infer_tests` tests for macro mutants, under its KTD9 (macro test selection). R17 requires their addition to the clean-check set.
- Saved maps contain no red tests: `save` returns early after any clean failure (`coverage_map.rb:1536`).
- Fizzy's covering share for one source with whole-suite `--test` is unknown; U1 measures it.
- Body edits affect only tests that ran the method. Unverified; U4 tests this, including load-time methods.

### High-Level Technical Design

Directional only.

```text
cached_or
  hit:  load map -> retry_failed_captures (records captured_now)
        set = clean_check_test_paths
        verify_cached_clean(test_paths: set - captured_now)   # was: every test
        verify_combined_clean (uses set)                      # was: every test
  miss: capture every test -> verify_combined_clean (uses set)
reuse_capture: verify_cached_clean(set) -> verify_combined_clean (set)

clean_check_test_paths = map empty ? @test_paths
                                   : @test_paths that appear in @map values
```

Step B adds these to `coverage.json`:

- `run_inputs`, under R8.
- `files`: `{ rel => { "fingerprint" => ..., "skeleton" => ... } }`.
- Per-test data: `{ test_rel => { "self" => fingerprint, "files" => [rel, ...] } }`.

B1 fills source `files` entries and leaves test `files` lists empty. B2 fills both. `cached_or` splits kept and recaptured tests, removes recaptured tests from every map entry, then captures only those tests.

### Report text

- Step A hit: `[mutineer] coverage cache hit: the clean check ran the 3 test files that cover the sources; 2 other test files never run with a mutant and were not checked.` For `--coverage-from`, replace `[mutineer] coverage cache hit:` with `[mutineer] --coverage-from:`. Singular forms: `the 1 test file that covers the sources` and `1 other test file never runs`.
- Step A miss: `[mutineer] coverage capture: the together check ran the 3 test files that cover the sources; 2 other test files ran alone only.` Print only when the together check skips a test, under R4.
- Partial Step B recapture: `[mutineer] coverage cache: recaptured 4 of 261 test files (changed, new or failed before); kept 257. Delete .mutineer/coverage.json for a full capture.` Print only when both kept and recaptured sets are non-empty.

### Probe results

Scripts and output: `probes/398/` in the context folder; see "Sources".

| Probe | Question | Result |
|---|---|---|
| 1. `run.sh` with `timer.rb`; copy of `test/fixtures/rails_app`; source `app/models/order.rb`; five passing model tests (`out-timings.txt`) | Does a hit cost as much as a miss? | Partly. `cached_or`: miss 1.20 s, including capture 1.05 s and together 0.14 s. Hit 0.63 s, including alone 0.52 s and together 0.12 s. Whole run: miss 3.59 s; hit 2.68 s. |
| 2. Same cache (`out-cache-shape.txt`) | Which tests cover the source? | 3 of 5: `order_test.rb`, `order_weak_test.rb`, `order_subtotal_only_test.rb`. Step A skips 2 of 5 alone runs. |
| 3. Append a comment to `app/models/price_list.rb`; rerun | Does an edit outside covering tests force a miss? | Yes. `run_phase_a_via_fork` took 0.91 s; the next run hit. Dependencies contain 8 files: `config/boot.rb`, `config/application.rb`, `config/environment.rb`, `app/models/application_record.rb`, `app/models/order.rb`, `app/models/price_list.rb`, `app/models/billing/fee.rb`, `test/test_helper.rb`. |
| 4. Read Fizzy's `.mutineer/coverage.json`, read-only | Are there 407 dependencies? | 407 dependencies; 10 timed tests; 9 covering tests; 9 mapped sources. Capture totals 9.9 s, with 9.2 s covering. Boot mode has `inputs`. `PARALLEL_WORKERS` is `"1"`. |
| 5. First run, all seven model tests | Does a red test stop the run? | Yes. `tax_table_test.rb` and `seeded_row_test.rb` lack required `--require` setup and fail clean. The run stops with "unmutated suite is not green". |
| 6. Four pinned cache tests in `test/coverage_map_test.rb` on `main` (`out-baseline-tests.txt`) | Is the base green? | 4 runs, 19 assertions, 0 failures. |
| 7. Reviewer probes `probes/398/refute/probe_executed_files.rb` and `probes/398/redesign-executed-files/probe.rb` | Do executed-file keys detect class-body edits? | No. A `model.rb` declaration and `limits.rb` constant edit preserve executed files but move coverage: 5 to 7, and 4 to 6. Fizzy has class-body declarations in 115 of 174 `app/models` files (`out-fizzy-declarations.txt`). KTD8 addresses this. |

Not checked: a whole-suite Fizzy run. The brief forbids it here; U1 measures it. Not checked: the fork-child cost of executed-file lists and skeleton digests. U4 measures it.

---

## Implementation Units

### U1. Spike: measure a hit on a whole-suite Fizzy run

**Goal:** Measure covering share and hit time before and after Step A. Merge no code.

**Question:** For one model and the whole Fizzy suite, how many files cover it? How long do hit checks take alone and together?

**Method:** Use a fresh Fizzy clone pinned by the #402 plan (test a pinned Fizzy sample before releases). Never use `/Users/davidteren/Projects/OSS/fizzy-palkan`. Fizzy's `.mutineer.yml` sets `daemon: true`; checks run in the daemon (`daemon_server.rb:278-287`).

Apply `timer.rb` through `RUBYOPT=-r<path>/timer.rb`. Confirm daemon timer output. If absent, also run with `--no-daemon` and record both results.

Run `bin/mutineer app/models/magic_link.rb --test <every test file>` twice. Add a one-line comment to `app/models/card.rb`, then rerun. Read the map:

```sh
ruby -rjson -e 'c=JSON.parse(File.read(".mutineer/coverage.json")); t=c["timings"]; cov=c["map"].values.flatten.uniq; puts [t.size, cov.size, t.values.sum.round(1), t.slice(*cov).values.sum.round(1)].inspect'
```

**Time box:** 2 hours.

**Pass:** Record results in the Step A pull request. If covering capture time exceeds about 80%, state that Step A offers little Fizzy gain; B1 carries it.

**Fail:** If Fizzy cannot boot, record probe 1 fixture results and explain why. Step A ships either way; its safety does not depend on the share. U4 uses the non-covering share.

### U2. Narrow the clean check to the clean-check set

**Goal:** R1 to R6, R14 and R17.

**Requirements:** R1, R2, R3, R4, R5, R6, R14, R17.

**Dependencies:** None; U1 can run in parallel.

**Files:**

- `lib/mutineer/coverage_map.rb`: Add private `clean_check_test_paths`, documented for `yard:strict`. At `cached_or`'s hit branch (`:404-405`), pass it to `verify_cached_clean`, excluding tests captured this run. Make `retry_failed_captures` (`:796-811`) record those tests, under R14. Replace `reuse_capture`'s inline set (`:436-438`); use the helper in `verify_combined_clean` (`:819-830`). Add private `warn_unchecked` for "Report text". Update comments at `:370-372`, `:416-422`, `:769-770` and `:813-814`.
- `test/coverage_map_test.rb`: Add the tests below; update `:510-511`.
- `test/fixtures/shared_capture/beta_test.rb`: Add `refute ENV["MUTINEER_FLUNK_BETA"]` to one test. Existing `MUTINEER_FLUNK` and `MUTINEER_FLUNK_ALONE` fail only `alpha_test.rb` (`test/fixtures/shared_capture/alpha_test.rb:11-13`), which covers `alpha.rb`.

**Approach:** Compute the hit set after `retry_failed_captures`, which can add entries. Compare paths through `relativize`, as `reuse_capture` does. Return unchanged `@test_paths` for empty `@map`.

**Patterns to follow:** `reuse_capture` (`coverage_map.rb:428-442`) and sentinel tests (`test/coverage_map_test.rb:496-520`).

**Test scenarios:**

- `test_cache_hit_runs_only_covering_tests`: Call `shared_map(%w[alpha.rb], dir)` twice with `MUTINEER_SENTINEL`. The second build has `phase_a_ran` false and only one `alpha_test.rb` run. Before U2, the sentinel also records `beta_test.rb` alone and the together run.
- `test_cache_hit_stops_on_a_covering_test_that_turns_red`: Use AE2 and `:296`'s marker test. `failed_clean_tests` names the covering file, preserving the safety rule.
- `test_cache_hit_skips_a_red_test_that_covers_no_source`: Use `alpha.rb` and both shared tests. Rebuild with `MUTINEER_FLUNK_BETA=1`. Require empty `failed_clean_tests`, existing `coverage.json`, and stderr matching `ran the 1 test file that covers the sources`. Fails before U2.
- `test_cache_hit_with_an_empty_map_checks_every_test`: Copy `test/fixtures/shared_capture` temporarily. Add `gamma.rb` with one method; require it from the copied `boot.rb`. Use only `gamma.rb` as source, with both tests; neither calls it. The second build runs both alone, shown by the sentinel. Covers R3. A copy is required because existing `boot.rb` loads only covered `alpha.rb` and `beta.rb`.
- `test_miss_runs_the_combined_check_over_covering_tests_only`: Miss over `alpha.rb` with both tests. Expect two capture forks and no together run: only one covering test remains. Print no miss line because the together check did not run. Covers R2.
- `test_retried_capture_skips_its_alone_check`: Cache `alpha_test.rb` in `failed_test_files`. The hit retries capture; the sentinel records `alpha_test.rb` once, not twice. Covers R14; fails before U2.
- `test_every_selectable_test_is_in_the_clean_check_set`: Build over `alpha.rb` and `beta.rb`. Every `tests_for` result for every map key must belong to `clean_check_test_paths`. Covers R17.
- `test_coverage_from_runs_only_the_covering_tests_alone_and_keeps_the_subset_map` (`:496`): Expect `[%w[alpha_test.rb]]` at `:510`; explain why in the message.
- `test_combined_clean_fails_when_files_pass_alone` (`:1359`): Keep unchanged and green; both files cover `calc.rb`.
- Standalone: Keep `test_warm_cache_records_failed_clean_when_suite_turns_red` (`:296`) unchanged and green. It calls `build_or_load`.
- Keep `test_failing_unrelated_test_aborts_before_scoring` (`test/boot_mode_test.rb:70`, #96's unrelated-failure rule) unchanged and green. Its fresh cache misses.

**Verification:** Pass `test/coverage_map_test.rb` and `test/boot_mode_test.rb`. Change no other test file.

### U3. Daemon test, docs and CHANGELOG for Step A

**Goal:** Cover daemon behaviour and document the change.

**Requirements:** R4, R5.

**Dependencies:** U2.

**Files:**

- `test/daemon_coverage_test.rb`: Add one test using a temporary `test/fixtures/rails_app` copy. Add a sentinel write to `test/models/price_list_test.rb`. Build the daemon map twice for `app/models/order.rb`, using `test/models/order_test.rb`, `test/models/price_list_test.rb` and one `cache_dir`. Clear the sentinel between builds. Assert no second-build `price_list_test.rb` run, empty `failed_clean_tests`, a non-empty map and the "Report text" stderr line. This fails before U2. Run under `rake test:daemon`, outside the default suite.
- `README.md:131-132`: Replace "Tests must pass alone and together, including with a cached map" with both rules. Fresh captures stop on any red test. Hits check only covering tests, alone and together.
- `docs/cli.md:98`: State both rules and full-capture triggers.
- `CHANGELOG.md`, under `[Unreleased]`: Include U1 or probe 1 numbers, AE3's behaviour change and KTD9's hit-versus-miss difference.

**Test scenario:** As above. If the helper cannot read daemon stderr, assert sentinel and reply results; disclose this in the pull request.

**Verification:** `bundle exec rake test:daemon`.

### U4. Spike: is per-test invalidation exact enough and cheap enough?

**Goal:** Decide whether B1 and B2 ship. Merge no code.

**Question:** After a one-file edit, do R9 and R15 produce the full-capture map? Measure first-mutant time, skeleton-digest cost and executed-file-list cost.

**Method:** On a spike branch, digest each `dependencies` file's Prism tree without `def` bodies. Add `"executed_files"` to fork payloads before the source filter at `coverage_map.rb:651`. Include project-relative files with non-zero line or method counts. Store both beside the map.

Apply these edits individually to the fixture copy and U1's pinned Fizzy clone:

- Part 1, B1: Run-source body edits in a leaf model and `app/models/card.rb`; a new method; `validates`, `enum` and `has_many ... dependent:` changes. Also change a constant read by another file's branch, an `@load_methods` method body and one test file.
- Part 2, B2: A method-body edit in a model that is not a run source; an eager-loaded model's `scope`; another file's constant; an initializer; `config/routes.rb`; `test/test_helper.rb` configuration.

For each edit:

1. Build a partial map under R9 and R15, keeping permitted tests and recapturing the rest.
2. Build a full map by capturing every test.
3. Compare every map key. Record recaptured share, first-mutant time, full-capture time, capture time with and without new data, and `coverage.json` size.

**Time box:** 1 day.

**Pass, part 1:** Every part 1 map matches, without exemptions. On Fizzy, leaf-model body edits reach the first mutant within 25% of full-capture time. New data adds at most 5% capture time; `coverage.json` grows at most 2 times. Then ship B1, U5.

**Pass, part 2:** Apply the same rules to every part 2 edit. Then ship B2, U6, after U5.

**Fail:** Any map difference or exceeded time, cost or size limit blocks that part. File "Per-test coverage cache invalidation" for part 1 or "Per-test cache invalidation for files outside the run's sources" for part 2. Include spike results and link from #398. Part 1 failure leaves #398 open; see "Delivery".

### U5. Step B1: per-test invalidation for test files and run sources (only after U4 part 1 passes)

**Goal:** R8 to R13, R15 and R16 for test files and run sources.

**Requirements:** R8, R9 (B1 part), R10, R11, R12, R13, R15, R16.

**Dependencies:** U2, U4 part 1 pass.

**Files:**

- `lib/mutineer/coverage_map.rb`: Make `save` write `run_inputs`, source `files` entries and per-test `self` fingerprints. Preserve `inputs`, `digest` and `dependencies`. Add private methods for Prism skeleton digests and removing one test from every map entry. Make `cached_or` split kept and recaptured tests under R8, R9 and R15. Apply R11 to checks. Keep `capture_mismatch` (`:468-505`) unchanged. Document every new method.
- `test/coverage_map_test.rb`: Add tests below.
- `test/daemon_coverage_test.rb`: Add the AE5 fixture test.
- `docs/cli.md`, `CHANGELOG.md`: State full-capture triggers and name the issues below.

**Issues to file in this pull request:** R10's standalone source-edit limit. If U6 has not shipped, also file B2's full capture after non-source edits. Cite each issue number in docs, CHANGELOG and the code comment.

**Test scenarios:**

- `test_body_edit_in_a_source_recaptures_only_its_tests`: Use `alpha.rb`, `beta.rb` and both shared tests. Edit an `alpha.rb` method body. Expect one `alpha_test.rb` capture fork and a map equal to a fresh full build.
- `test_class_body_edit_in_a_source_recaptures_every_test`: Add an `alpha.rb` constant. Capture every test; covers R15.
- `test_body_edit_of_a_load_method_recaptures_every_test`: Cover R15's `@load_methods` rule.
- `test_input_change_recaptures_every_test`: Change the `--require` file; capture every test.
- `test_non_source_dependency_edit_recaptures_every_test`: Change a loaded non-source file; capture every test.
- `test_test_file_edit_recaptures_that_test`: Edit one test file.
- `test_new_and_removed_tests_update_the_map`: Add one test and remove another. Capture the new test; remove the old test's map entries.
- `test_partial_recapture_runs_kept_covering_tests_alone_once`: Under R11, run the recaptured test once and each kept covering test alone once.
- `test_old_cache_without_per_test_data_rebuilds_once`: Follow `test_cache_without_timings_is_rebuilt_once` (`:838`).
- `test_standalone_source_edit_recaptures_every_test`: Cover R10.
- `test_coverage_from_reads_a_per_test_cache`: Cover R13.
- `test_recaptured_red_test_stops_the_run`: Cover R11.
- Daemon, AE5: Edit an `app/models/order.rb` method body between daemon builds. Recapture only the three covering tests.

**Verification:** Run `test/coverage_map_test.rb` and `rake test:daemon`. Repeat U4's Fizzy leaf-model body edit. Record first-mutant time as a full-capture share in the pull request.

### U6. Step B2: per-test invalidation for files outside the run's sources (only after U4 part 2 passes)

**Goal:** R7 and the B2 part of R9.

**Requirements:** R7, R9 (B2 part), R16.

**Dependencies:** U5, U4 part 2 pass.

**Files:**

- `lib/mutineer/coverage_map.rb`: Add `executed_files` from line and method counts to fork payloads and subprocess scripts. Record them per test in `accept_capture_payload`. Make `save` fill `files` for every dependency and each test's `files` list. Apply R9's B2 rule in `cached_or`.
- `test/coverage_map_test.rb`, `test/daemon_coverage_test.rb`: Add tests below.
- `docs/cli.md`, `CHANGELOG.md`: Explain the rule; close or update U5's B2 issue.

**Test scenarios:**

- `test_body_edit_to_a_helper_one_test_ran_recaptures_only_that_test`: Use two tests, each running one of two helpers. Edit one helper's method body. Expect one capture fork and a map equal to a fresh full build.
- `test_class_body_edit_to_a_helper_recaptures_every_test`: Cover R15 outside run sources.
- Daemon, AE7: Edit an `app/models/price_list.rb` method body between daemon builds. Recapture only tests that executed it.

**Verification:** Follow U5, using U4 part 2's Fizzy edits.

---

## Verification Contract

Prefix each ruby, rake and bundle command with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`.

| Command | Proves |
|---|---|
| `bundle exec ruby -Ilib -Itest test/coverage_map_test.rb` | U2, U5 and U6 tests; changed pin |
| `bundle exec ruby -Ilib -Itest test/boot_mode_test.rb` | #96's unrelated-failure rule holds on misses |
| `bundle exec rake test` | Zero-dependency suite |
| `BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle exec rake test` | Fork clean check under Minitest 6 |
| `ruby -Ilib -e 'require "mutineer"'` | Load smoke |
| `bundle exec rake yard:strict` | Documentation for `clean_check_test_paths`, `warn_unchecked` and every Step B method |
| `bundle exec rake test:daemon` | U3, U5 and U6 daemon tests |
| Optional, machine-local: `probes/398/run.sh miss`, then `run.sh hit`, after `rm -rf probes/398/cache` | Lower fixture `verify_cached_clean` time for 3 of 5 tests; hit report |

`docs/cli.md` is a site page (`rake/site_docs.rb:38`) and contract guide (`rake/docs_contract.rb:98`). Also run `bundle exec ruby -Ilib -Itest test/docs_contract_test.rb` and the `AGENTS.md` website checks:

1. `bundle exec rake site:build`
2. `node --test test/site_test.js`
3. `npm ci --prefix test/browser`
4. `npx --prefix test/browser playwright install chromium`
5. `npm test --prefix test/browser`

## Definition of Done

- Step A: All U2 and U3 tests exist and pass; specified scenarios fail before their changes. Explain the changed `test/coverage_map_test.rb:510-511` pin. Change no other existing test.
- Covering red tests stop in-process, standalone and daemon runs. Any red test stops a miss.
- Scores, exit codes and mutant test selection stay unchanged, except AE3.
- Step A's pull request includes U1 numbers or explains fixture-only results.
- B1: Merge U5 with tests, filed issues and Fizzy first-mutant share, or link U4's follow-up issue from #398.
- Close #398 only when U5 meets U4's Fizzy time rule, or a maintainer chooses the follow-up issue.
- B2: Merge U6, or file its follow-up issue and name it in docs.
- Leave no dead or spike code on `main`.

---

## Risks and Overlaps

| Item | Overlap | Handling |
|---|---|---|
| Siblings rule | Reload/redefine; daemon/in-process; Action/CLI; report/dry run | Checks precede mutants, so strategy is irrelevant. U2 covers boot, standalone and `--coverage-from`; U3 covers daemon. Action reuses `.mutineer/` through CLI without input changes, under KTD9. `--dry-run` builds no map (`lib/mutineer/cli.rb:356`) and stays unchanged. Add no report key; use stderr only. |
| Behaviour change | Non-covering red tests no longer stop hits, under AE3; misses still stop. | Intended under R17. KTD4 reports it. README, `docs/cli.md` and CHANGELOG state both rules. Q5 requires a decision. |
| #96 (unrelated red tests abort runs) | `test/boot_mode_test.rb:68-75` states the old rule. | Keep it green: its fresh cache misses. Correction 10 explains hits. |
| #389 (full-reload strategy for Rails daemon runs) | Its KTD6 and Q3 propose whole-suite reload-safety checks every run, restoring costs removed by KTD2. | Shared code with the #389 plan: `verify_combined_clean` (#389 runs it for one file under `full_reload` and names red files per file), `fork_clean_pass?` (#389 adds `clean_after_fork:`), and `compute_digest` (#389 KTD13). Keep the fewer-than-two skip as a default that a strategy may override. Keep `clean_check_test_paths` the only source of the set. #389 rebases on Step A. |
| #397 (class-body macro mutation) | Its KTD9 selects `tests_for` results plus `Pairing.infer_tests` matches, which can be absent from the map. | R17 requires those tests in `clean_check_test_paths`. U2's contract test rejects selections outside that set. Macro edits change skeletons and force full capture. Its KTD9 also re-runs survivors on the whole `--test` set. When a macro operator is selected, `clean_check_test_paths` returns every test. The R17 contract test covers this case once #397 PR3 exists. |
| #201 (split `coverage_map.rb`) | Another session owns `refactor/split-coverage-map` (coverage-map refactor), currently a placeholder commit. | Step A changes about 40 lines. If #201 lands first, move `clean_check_test_paths` into the clean-check unit. Stop and ask if both enter review. |
| #396 (`--since` builds the full map) | Same file; KTD1's next step. | No shared Step A lines. See Q2. |
| #382 (`tests:` map in `.mutineer.yml`) | Adds tests to source lists. | Extra non-covering tests add no hit clean-check cost. No shared code. If #382 is on the base, U3 also changes #382's docs note in `docs/cli.md` ("a hit checks every listed file") to the covering-only rule. |
| #380 (`--test` accepts directories or globs) | Makes whole-suite selection easier. | Increases this plan's value. No shared code. |
| #360 (missing clean-test failure names), #282 and #338 (test order and seed) | Same error path and together check. | Preserve `lib/mutineer/job_plan.rb:176-189`'s message and together-check order. |
| PR #322 and #286 (`ran_at_load` count) | Step B must preserve `load_lines` and `load_methods`. | Boot reads them live (`coverage_map.rb:139-145`). Standalone source edits recapture all tests under R10, preserving load lines. Load-method body edits force full capture under R15. |
| PR #391 (Rails class-body reload fix), #375 (hook-block placement), #245, #244, #332 and #335 (2.0 line) | Changes affect `daemon_server.rb`, `runner.rb` and `job_plan.rb`, outside `coverage_map.rb`. | No shared lines. |
| Stale Step B map | Missed edits can leave incorrect maps and scores. | Apply KTD6, KTD8 and R16. Any map difference fails U4; no exemptions. |
| Step B data cost | Larger `coverage.json`; Prism parsing per changed file. | Use one `files` table and per-test path lists, under R7. U4 limits time and size. |

## Open Questions

None blocks Step A implementation. Each has a default; the maintainer owns every decision.

- Q1 (report frequency). Print skipped-test reports on every hit or only with `--verbose`? Default: every hit, under KTD4.
- Q2 (later narrowing). After #396 reorders `Runner.execute`, narrow checks to tests for mutants kept by `--since`? Default: yes, through a #396 follow-up.
- Q3 (B1 sufficiency). If U4 part 2 fails, is B1 sufficient for edit loops? Default: ship B1; track B2 separately. Decide after U4.
- Q4 (release target). Ship B1 and B2 in v1.9.0 or the next minor? Default: v1.9.0 if U4 passes before the batch; otherwise, next minor.
- Q5 (cache-state behaviour and version classification). A red test outside the clean-check set stops a miss but not a hit. Is that acceptable, and is it a minor change for the Action? Default: yes, under KTD9, because those tests never run with mutants. Decide before Step A merges.

## Sources

- Issue: `issues/398.md` in the context folder. Vladimir's report: `vladimir-fizzy-report.md` lines 21 and 438.
- Validation reports, 2026-11-09, under `/Users/davidteren/Projects/DT/mutineer/wip/vlad/`: `opus/` A11 supplies issue numbers; `Sol/` A11 reports 410 dependencies and 261 captures in about 242 s, with insufficient per-source keys. `grok-cursor/` A11 confirms all-source-and-test digests and recommends #380 (directory/glob test selection) first.
- Machine-local, best-effort probes: `/private/tmp/claude-501/-Users-davidteren-Projects-claude-worktrees-mutineer-vladimir-issues-planning-21adcb/ae564be8-638b-4dd0-a9e5-9d7a58cb00ae/scratchpad/context/probes/398/`. Files: `timer.rb`, `run.sh`, `out-timings.txt`, `out-cache-shape.txt`, `out-baseline-tests.txt`, `coverage-after.json`, `refute/`, `redesign-executed-files/`.
- Sibling plans: `docs/plans/2026-11-10-389-feat-rails-full-reload-strategy-plan.md`, KTD6 and Q3 (reload-safety checks); #397 plan, KTD9 (macro test selection).
- Code read: `lib/mutineer/coverage_map.rb:50-64`, `:98-146`, `:148-201`, `:370-545`, `:568-830`, `:1320-1592`; `lib/mutineer/runner.rb:100-182`, `:228-240`; `lib/mutineer/job_plan.rb:165-189`, `:228-286`; `lib/mutineer/daemon_server.rb:170-178`, `:275-297`; `lib/mutineer/daemon_backend.rb:240-276`; `test/coverage_map_test.rb:290-320`, `:440-470`, `:484-610`, `:1355-1385`; `test/boot_mode_test.rb:62-75`; `test/fixtures/shared_capture/`; Fizzy `test/mutineer_boot.rb:1-5` and `.mutineer.yml`.

Whole-suite Fizzy performance and new-data costs remain unchecked. Each Step B part must pass its U4 gate before shipping.