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

- **Issue:** #398 (a coverage cache hit still runs the full clean check, so any edit costs a full capture).
- **Objective:** a run that reuses the coverage cache starts its first mutant soon. An edit to one file does not throw away the whole map.
- **Means:** two steps in two pull requests. Step A (U1 to U3): the clean check runs only the tests that cover the run's sources. Step B (U4 and U5): the cache records which files each test ran, and an edit recaptures only the tests that ran the edited file. Step B starts only when the U4 spike passes.
- **Authority:** this plan, then `AGENTS.md`, then the text of #398. Where this plan differs from the issue, this plan wins (see "Corrections to the issue").
- **Stop and ask when:** a change would let a test that fails without mutants reach a mutant run without a stop; a change would alter the score, an exit code or which tests a mutant runs; #201 (split `coverage_map.rb` into smaller units) gets real code on its branch; or the U4 spike fails.
- **Size:** Step A is S: 1 file under `lib/`, 2 test files, 1 fixture file, 3 docs files. Step B is M: 2 files under `lib/`, 2 test files, 2 docs files and a cache format change. No new runtime dependency.
- **Delivery:** Step A is one pull request from `main`. Labels: `enhancement`, `v1.9.0`. Step B is a second pull request after Step A merges, with the same labels and a tentative `v1.9.0` (move to the next minor if it misses the batch). Semver: minor for both. Neither changes a GitHub Action input, output or default. Each body says `Refs #398`; the Step B body says `Closes #398`. A maintainer merges. This plan has no release step.

---

## Product Contract

### Summary

Today a cache hit runs every `--test` file alone, then all of them together (`lib/mutineer/coverage_map.rb:404-405`, `:776-788`, `:819-830`). A miss runs every file once for capture, then all together (`:410-411`). So a hit costs about as much as a miss. Step A makes a hit run only the test files that cover a line of the run's sources, alone and together. A mutant runs only those files (`lib/mutineer/job_plan.rb:261-286`), so the check still covers every test that can decide a verdict. Step B keeps a list of executed files for each test. An edit then recaptures only the tests that ran the edited file.

### Problem Frame

Vladimir Dementyev ran Mutineer on Fizzy, a Rails 8 app, with the whole suite as `--test`. About 6 minutes pass before the first mutant, and any edit pays that again (`vladimir-fizzy-report.md` lines 21 and 438). He asked for per-source invalidation so that Mutineer fits an edit loop.

Two costs stack. First, any edit to a source, a test or any loaded project file misses the cache, because the digest and the dependency list cover the whole run (`coverage_map.rb:1415-1418`, `:1387-1395`). Second, a hit is not cheap: it runs the full clean check.

### Terms

- **Covering test:** a test file that appears in at least one map entry, that is, it ran at least one line of a source in this run. The set is `@map.values.flatten`, as `reuse_capture` computes it (`coverage_map.rb:436`).
- **Clean check:** the runs of the unmutated tests that prove they pass. "Alone" is one test file per process (`verify_cached_clean`, `:776`). "Together" is one process with all of them (`verify_combined_clean`, `:819`).
- **Hit / miss:** the coverage cache is reused (`cached_or`, `:390-407`), or captured again (`:410-413`).
- **Executed files of a test (Step B):** the project files that have at least one non-zero line count in that test's capture.

### Requirements

**Step A: narrow the clean check**

- R1. On a hit, the alone check runs only the covering tests that did not fail capture. A covering test that fails alone stops the run, as today.
- R2. The together check runs only the covering tests that did not fail capture, on a hit, on a miss and with `--coverage-from`. It still skips when fewer than two tests remain (`coverage_map.rb:821`).
- R3. When the map is empty, both checks run every test, as today. Reason: the daemon then runs every test for every mutant (`lib/mutineer/daemon_backend.rb:261-269`).
- R4. The run reports what the check left out. On a hit or with `--coverage-from`, when the alone check skips at least one test, stderr gets one line with both counts (see "Report text"). A miss prints no line: its capture already ran every test alone.
- R5. In-process `--rails`/`--boot`, in-process standalone and `--daemon` runs behave the same, because all three call `cached_or` (`lib/mutineer/runner.rb:149-158`, `:169-175`, `lib/mutineer/daemon_server.rb:281-287`). `--test-command` builds no map and does not change (`lib/mutineer/runner.rb:232-236`).
- R6. The score, every exit code and the tests each mutant runs do not change.

**Step B: invalidate per test (only after the U4 spike passes)**

- R7. The cache stores, for each test, its executed files with a fingerprint of each.
- R8. A run inputs key holds everything that today forces a full miss and is not per test: the boot file, `--require` files, load paths, framework, seed, `PARALLEL_WORKERS`, the source list and the owner files (`coverage_map.rb:1415-1433`, `:1405-1407`). If it differs, the run captures every test, as today.
- R9. Otherwise the run recaptures a test when its own file changed, when one of its executed files changed or disappeared, when it is new in `--test`, or when its last capture failed. It drops a test that left `--test`. Other tests keep their map entries.
- R10. Under standalone mode every capture loads every source (`coverage_map.rb:1571`). The plan accepts that a source edit there recaptures every test.
- R11. A recaptured test goes through the same clean check rules as Step A.
- R12. An old cache without the per-test data rebuilds once, as the `load_methods` and `timings` caches did (`coverage_map.rb:391`, `test/coverage_map_test.rb:838`).
- R13. `--coverage-from` keeps working on a cache that Step B writes.

### Acceptance Examples

- AE1 (R1). Fixture copy, sources `app/models/order.rb`, five model tests. The second run is a hit. The alone check runs `order_test.rb`, `order_weak_test.rb` and `order_subtotal_only_test.rb`, not `price_list_test.rb` or `billing/fee_test.rb` (probe 2 gives the covering set).
- AE2 (R1). A covering test turns red without a file change (the marker file pattern of `test/coverage_map_test.rb:296`). The hit run stops with today's message.
- AE3 (R2, R4). A test that covers no source turns red without a file change. The hit run continues. Stderr says the check ran the 1 test file that covers the sources and skipped 1 other.
- AE4 (R3). The map is empty. The hit run checks every test.
- AE5 (R9, Step B). The user appends a comment to `app/models/price_list.rb`. Today the next run misses and captures all five tests (probe 3). After Step B it recaptures only the tests that executed `price_list.rb`.

### Scope Boundaries

In scope: the clean check on a hit, the together check in all three paths, the stderr line, docs, and Step B behind its spike.

Out of scope:

- Choosing tests by the mutants that `--since` or `--only` keeps. The map is built before `collect_jobs` and `scope_since` run (`lib/mutineer/runner.rb:149-182`). Moving that order is the fix for #396 (an in-process `--since` run builds the full map when no changed line holds a mutant). See Q2.
- Several maps in one cache directory, keyed by context (validation report Sol A11). Separate `--cache-dir` values already do that.
- A cache for `--test-command`. It has no map.
- The order of tests inside the together check (#282 and #338, test order and seed).
- Naming the failing test when the clean check fails. That is #360.

### Corrections to the issue

1. **"Run the clean check only for the tests that cover the selected mutants."** The selected mutants do not exist yet when the check runs. `Runner.execute` builds the map and calls `abort_if_unclean!` at `lib/mutineer/runner.rb:149-177`. It collects and scopes the mutants later, at `:180-182`. The plan uses the tests that cover any line of the run's sources, as `reuse_capture` does (`coverage_map.rb:430-438`).
2. **"Reuse the existing `reuse_capture` path."** That path narrows only the alone check. Its together check still runs every test (`coverage_map.rb:439` calls `verify_combined_clean`, which takes all of `@test_paths` at `:820`). Reused as is, a hit would still pay one run of the whole suite. R2 narrows the together check too, and changes the pin at `test/coverage_map_test.rb:510-511`.
3. **"A hit costs about as much as a miss" (miss 19.95 s, hit 20.48 s).** Probe 1 did not reproduce these numbers. On the fixture copy with five tests, `cached_or` took 1.20 s on a miss and 0.63 s and 0.62 s on two hits. The whole run took 3.59 s on a miss and 2.68 s on a hit. The work per test is the same kind (one fork per test file, then one together run), so the gap shrinks as test time grows. The issue's numbers came from the Opus validation report (A11) and say "not rerun".
4. **"Invalidate only the entries for the tests whose dependencies changed."** No per-test dependency data exists. The cache keeps one list for the whole run (`@loaded_dependencies`, filled at `coverage_map.rb:1344-1356`, saved at `:1540`), and the digest holds the content of every source and test (`:1417-1418`). Also, the dependency list is a list of loaded files. A forked capture reports every project file in `$LOADED_FEATURES` (`:1326-1337`), and that includes all the parent loaded. Fizzy's `--require` file eager-loads the whole app in the parent (`fizzy-palkan/test/mutineer_boot.rb:5`; the parent loads `--require` files at `lib/mutineer/runner.rb:136` and `lib/mutineer/daemon_server.rb:177`). So on Fizzy every test "depends" on every app file, and a loaded-file key cannot single out any test. Step B uses executed files instead (KTD5), behind the U4 spike.
5. **"407 dependencies for 10 tests."** Confirmed. Fizzy's `.mutineer/coverage.json` lists 407 dependencies and 10 timed tests, 9 of them covering (probe 4).
6. **"Done when: a second run after an edit to one model starts its first mutant in a small part of the full capture time."** With the whole suite as `--test`, a central model such as `Card` runs in most tests. Even exact per-test invalidation then recaptures most tests. The done check must name the model and report the share of tests it recaptured (U5).
7. **Backends.** The issue does not say which runs use the cache. In-process boot, in-process standalone and the daemon do (R5). `--test-command` does not. `--coverage-from` exists only for in-process boot (`lib/mutineer/runner.rb:156`; the daemon passes none at `daemon_server.rb:281-287`).
8. **Empty map.** The issue does not cover it. With an empty map the daemon runs every test for every mutant (`daemon_backend.rb:261-269`), so the check must not narrow to nothing (R3).

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Narrow by the run's sources, not by the selected mutants.** One helper returns the covering tests from the map. `reuse_capture`, the hit branch and `verify_combined_clean` call it. Rejected: move `collect_jobs` and `scope_since` before the map build. That reorders `Runner.execute` and the daemon path, and it is #396's change. Q2 records the follow-up.
- KTD2. **Narrow the together check in all three paths.** A mutant run loads only covering tests (`job_plan.rb:261-286`). A non-covering test never shares a process with a mutant, so a failure that needs it cannot change a verdict. Rejected: keep the together check over every test. On a whole-suite run it is one more run of the whole suite on every hit, which keeps most of the cost the issue names.
- KTD3. **Keep the full check when the map is empty.** The daemon falls back to every test then (R3). Rejected: narrow to nothing, which would let a red test reach every daemon mutant.
- KTD4. **Say what was skipped, on stderr, once.** The "count what you exclude" rule applies to tests left out of a safety check. One line, only when at least one test was skipped. Rejected: say nothing, which hides a behaviour change. Rejected: only under `--verbose`, because the daemon does not pass `verbose` to `CoverageMap` (`daemon_server.rb:281-286`). Q1 asks the maintainer.
- KTD5. **Step B keys each test on the files it executed, not the files it loaded.** The fork child already reads `Coverage.result` before it filters to the sources (`coverage_map.rb:650-652`). It can also list the project files with a non-zero line count. Rejected: per-test loaded files, which fail on eager-loaded apps (correction 4). Rejected: per-source keys alone, which every validation report calls not enough (Sol A11, Grok A11, Opus A11).
- KTD6. **Step B accepts one known gap and documents it.** An edit can make a test run a file it never ran before, for example a new callback in a model that the test saves only through inherited methods. That test is not recaptured, so the new lines can show `no_coverage` or miss a killing test until the next full capture. The U4 spike measures how often the per-test map differs from a full capture. A cache-input change, a test edit or deleting `coverage.json` forces the full capture. Rejected: recapture every test that loaded the file, which is every test on Fizzy.
- KTD7. **Step B ships only if the U4 spike passes.** If it fails, Step A ships alone, and a new issue tracks per-test invalidation with the spike's numbers.

### Assumptions

- A test file that covers no source line never runs with a mutant. `JobPlan.coverage_selection` takes its tests only from the map (`job_plan.rb:261-286`). The in-process `run` and the daemon `job_result` both call it (`job_plan.rb:228-230`). Verified by reading. The daemon's empty-map fallback is the exception, and R3 covers it.
- A red test is never in a saved map: `save` returns early when any clean test failed (`coverage_map.rb:1536`).
- The Fizzy covering share for a single source with the whole suite as `--test` is unknown. U1 measures it.

### High-Level Technical Design

Directional only.

```text
cached_or
  hit:  load map -> retry_failed_captures -> covering = covering_tests
        verify_cached_clean(test_paths: covering)        # was: every test
        verify_combined_clean (uses covering_tests)      # was: every test
  miss: capture every test -> verify_combined_clean (covering)
reuse_capture: verify_cached_clean(covering) -> verify_combined_clean (covering)

covering_tests = map empty ? @test_paths
                           : @test_paths that appear in @map values
```

Step B adds `per_test` data to `coverage.json`: `{ test_rel => { "self" => fingerprint, "files" => { rel => fingerprint } } }` plus an `inputs` key per R8. `cached_or` then splits the tests into keep and recapture, removes each recaptured test from every map entry, and captures only those tests.

### Report text

- Skipped line, Step A: `[mutineer] coverage cache hit: the clean check ran the 3 test files that cover the sources; 2 other test files never run with a mutant and were not checked.` With `--coverage-from` the line starts `[mutineer] --coverage-from:` in place of `[mutineer] coverage cache hit:`. One covering test reads `the 1 test file that covers the sources`; one skipped test reads `1 other test file never runs`. A miss prints no line (R4).
- Step B, when some tests are kept: `[mutineer] coverage cache: recaptured 4 of 261 test files (their files changed); kept 257.`

### Probe results

Scripts and output are under `probes/398/` in the context folder (see Sources).

| Probe | Question | Result |
|---|---|---|
| 1. `run.sh` with `timer.rb` on a copy of `test/fixtures/rails_app`, source `app/models/order.rb`, five passing model tests (`out-timings.txt`) | Does a hit cost as much as a miss? | Partly. `cached_or`: miss 1.20 s (capture 1.05 s, together 0.14 s). Hit 0.63 s (alone 0.52 s, together 0.12 s). Whole run: miss 3.59 s, hit 2.68 s. |
| 2. Same cache (`out-cache-shape.txt`) | Which tests cover the source? | 3 of 5: `order_test.rb`, `order_weak_test.rb`, `order_subtotal_only_test.rb`. Step A would skip 2 of 5 alone runs on this fixture. |
| 3. Append a comment to `app/models/price_list.rb`, run again | Does an edit to a file the covering tests never run force a miss? | Yes. `run_phase_a_via_fork` ran (0.91 s). The next run was a hit again. The dependency list holds 8 files: `config/boot.rb`, `config/application.rb`, `config/environment.rb`, `app/models/application_record.rb`, `app/models/order.rb`, `app/models/price_list.rb`, `app/models/billing/fee.rb`, `test/test_helper.rb`. |
| 4. Read Fizzy's `.mutineer/coverage.json` (read-only) | The issue's 407 dependencies? | 407 dependencies, 10 timed tests, 9 covering, 9 sources in the map. Capture timings sum to 9.9 s, 9.2 s of it covering. Boot mode (`inputs` key present). `PARALLEL_WORKERS` is `"1"`. |
| 5. The first probe run with all seven model tests | Does a red test still stop the run? | Yes. `tax_table_test.rb` and `seeded_row_test.rb` need their `--require` setup and fail clean. The run stopped with the "unmutated suite is not green" message. |
| 6. Four pinned cache tests of `test/coverage_map_test.rb` on `main` (`out-baseline-tests.txt`) | Is the base green? | 4 runs, 19 assertions, 0 failures. |

Not checked: a whole-suite run on Fizzy. The brief forbids it here, so U1 measures it. Not checked: the cost of the executed-file list in a fork child. U4 measures it.

---

## Implementation Units

### U1. Spike: measure a hit on a whole-suite Fizzy run

**Goal:** know the covering share and the hit time before and after Step A on a real app. No code merges.

**Question:** for one model with the whole Fizzy suite as `--test`, how many test files cover it, and how long do the alone and together checks take on a hit?

**Method:** use a fresh Fizzy clone pinned as the #402 plan (run Mutineer on a pinned Fizzy sample before each release) describes, never `/Users/davidteren/Projects/OSS/fizzy-palkan`. Apply the `timer.rb` probe through `RUBYOPT=-r<path>/timer.rb`. Run `bin/mutineer app/models/magic_link.rb --test <every test file>` twice, then once more after a one-line comment in `app/models/card.rb`. Then read the map with:

```sh
ruby -rjson -e 'c=JSON.parse(File.read(".mutineer/coverage.json")); t=c["timings"]; cov=c["map"].values.flatten.uniq; puts [t.size, cov.size, t.values.sum.round(1), t.slice(*cov).values.sum.round(1)].inspect'
```

**Time box:** 2 hours.

**Pass:** the numbers are recorded in the Step A pull request body. **Fail** (Fizzy does not boot): record the fixture numbers of probe 1 instead and note it. Step A ships either way, because its safety does not depend on the share.

### U2. Narrow the clean check to the covering tests

**Goal:** R1 to R6.

**Requirements:** R1, R2, R3, R4, R5, R6.

**Dependencies:** none (U1 can run in parallel).

**Files:**

- `lib/mutineer/coverage_map.rb`: new private `covering_test_paths` (doc comment for `yard:strict`). The hit branch of `cached_or` (`:404-405`) passes it to `verify_cached_clean`. `reuse_capture` (`:436-438`) uses it in place of its inline set. `verify_combined_clean` (`:819-830`) starts from it. A new private `warn_unchecked` prints the line in "Report text". Update the comments at `:370-372`, `:416-422`, `:769-770` and `:813-814`.
- `test/coverage_map_test.rb`: new tests below; update the pin at `:510-511`.
- `test/fixtures/shared_capture/beta_test.rb`: add `refute ENV["MUTINEER_FLUNK_BETA"]` to one test. The existing `MUTINEER_FLUNK` and `MUTINEER_FLUNK_ALONE` flunk only `alpha_test.rb` (`test/fixtures/shared_capture/alpha_test.rb:11-13`), and `alpha_test.rb` covers `alpha.rb`.

**Approach:** compute the set after `retry_failed_captures` on a hit, because that call can add map entries. Compare paths with `relativize`, as `reuse_capture` does. Return `@test_paths` unchanged when `@map` is empty.

**Patterns to follow:** `reuse_capture` (`coverage_map.rb:428-442`) and its tests with the sentinel file (`test/coverage_map_test.rb:496-520`).

**Test scenarios:**

- `test_cache_hit_runs_only_covering_tests`: `shared_map(%w[alpha.rb], dir)` twice with `MUTINEER_SENTINEL` set. The second build has `phase_a_ran` false. The sentinel shows only `alpha_test.rb`, in one run. Before U2 it also shows `beta_test.rb` alone and the together run.
- `test_cache_hit_stops_on_a_covering_test_that_turns_red`: as AE2, with the marker-file test of `:296`. `failed_clean_tests` names the covering file. This asserts the safety rule still holds.
- `test_cache_hit_skips_a_red_test_that_covers_no_source`: sources `alpha.rb`, both shared tests. Second build with `MUTINEER_FLUNK_BETA=1`. `failed_clean_tests` is empty, `coverage.json` still exists, and stderr matches `ran the 1 test file that covers the sources`. Fails before U2.
- `test_cache_hit_with_an_empty_map_checks_every_test`: a source that no test runs, two tests. The second build runs both tests alone (sentinel), as today. Covers R3.
- `test_miss_runs_the_combined_check_over_covering_tests_only`: a miss over `alpha.rb` with both tests. The sentinel shows two capture forks and no together run, since one covering test is left. Covers R2 on a miss.
- `test_coverage_from_runs_only_the_covering_tests_alone_and_keeps_the_subset_map` (`:496`): change the expected runs at `:510` to `[%w[alpha_test.rb]]`. The message says why.
- `test_combined_clean_fails_when_files_pass_alone` (`:1359`) stays green unchanged: both files cover `calc.rb`.
- Standalone path: `test_warm_cache_records_failed_clean_when_suite_turns_red` (`:296`) stays green unchanged. It runs `build_or_load`.

**Verification:** `test/coverage_map_test.rb` passes. No other test file changes.

### U3. Daemon test, docs and CHANGELOG for Step A

**Goal:** cover the daemon sibling and tell users.

**Requirements:** R4, R5.

**Dependencies:** U2.

**Files:**

- `test/daemon_coverage_test.rb`: one test. It builds the daemon map twice over `app/models/order.rb` with `test/models/order_test.rb` and `test/models/price_list_test.rb` and one `cache_dir`. It asserts the second reply has empty `failed_clean_tests`, a non-empty map, and the stderr line from "Report text". This runs in `rake test:daemon`, not the default suite.
- `README.md:131-132`: the sentence "Tests must pass alone and together, including with a cached map" becomes: covering tests must pass alone and together; a cache hit checks only them.
- `docs/cli.md:98`: one sentence on what a hit checks and what forces a full capture.
- `CHANGELOG.md` under `[Unreleased]`: an entry with the U1 numbers (or probe 1 numbers) and the behaviour change in AE3.

**Test scenario:** as above. If the daemon test helper cannot read the daemon's stderr, assert on the reply and the absence of an abort, and say so in the pull request.

**Verification:** `bundle exec rake test:daemon`.

### U4. Spike: is a per-test executed-file key exact enough and cheap enough?

**Goal:** decide whether Step B ships. No code merges.

**Question:** after a one-file edit, does a map built by recapturing only the tests that executed that file equal a full recapture? How many tests does it recapture? What does the extra list cost per capture?

**Method:** on a spike branch, make the fork child add `"executed_files"` (project-relative files with any non-zero line count, before the filter at `coverage_map.rb:651`) to its payload. Keep it on disk next to the map. Then on the fixture copy and on the pinned Fizzy clone of U1, for each of five edits (a comment in a central model, a comment in a leaf model, a new method, a new `before_save` callback, an edit to `test/test_helper.rb`):

1. Partial map: keep the tests that did not execute the file; recapture the rest.
2. Full map: capture every test.
3. Compare the two maps key by key, and record the recaptured share and the capture time with and without the list.

**Time box:** 1 day.

**Pass:** the maps are equal for every edit except the callback edit, which is the KTD6 gap and is recorded. The leaf model edit recaptures at most 25% of the tests. The list adds at most 5% to capture time. **Fail:** any other map difference, or a share or cost above those limits. Then Step B does not ship. File an issue titled "Per-test coverage cache invalidation" with the spike's numbers, and link it from #398.

### U5. Per-test invalidation (only after U4 passes)

**Goal:** R7 to R13.

**Requirements:** R7, R8, R9, R10, R11, R12, R13.

**Dependencies:** U2, U4 pass.

**Files:**

- `lib/mutineer/coverage_map.rb`: the fork payload and the subprocess script add `executed_files`. `accept_capture_payload` records them per test. `save` writes `per_test` and the R8 inputs key. `cached_or` splits keep and recapture. A new private method removes one test from every map entry. `capture_mismatch` (`:468-505`) keeps accepting the new format for `--coverage-from`. Every new method gets a doc comment.
- `test/coverage_map_test.rb`: tests below.
- `test/daemon_coverage_test.rb`: one test for AE5 on the fixture app.
- `docs/cli.md`, `CHANGELOG.md`: what forces a full capture now, and the KTD6 gap.

**Test scenarios:**

- `test_edit_to_a_file_one_test_ran_recaptures_only_that_test`: two tests, two helpers, each test runs one helper. Edit one helper. The sentinel shows one capture fork. The map equals a fresh full build.
- `test_input_change_recaptures_every_test`: change the `--require` file. Every test captures, as today.
- `test_test_file_edit_recaptures_that_test`: edit one test file only.
- `test_new_and_removed_tests_update_the_map`: add one test to the list and remove another. The new one captures. The removed one leaves the map.
- `test_old_cache_without_per_test_data_rebuilds_once`: like `test_cache_without_timings_is_rebuilt_once` (`:838`).
- `test_standalone_source_edit_recaptures_every_test`: covers R10.
- `test_coverage_from_reads_a_per_test_cache`: covers R13.
- `test_recaptured_red_test_stops_the_run`: covers R11.
- Daemon (AE5): append a comment to `app/models/price_list.rb` between two daemon builds; the second build recaptures only `price_list_test.rb`.

**Verification:** `test/coverage_map_test.rb` and `rake test:daemon`. On Fizzy, the U4 method with the leaf model edit; record the first-mutant time and the recaptured share in the pull request.

---

## Verification Contract

Prefix each ruby, rake and bundle command with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`.

| Command | Proves |
|---|---|
| `bundle exec ruby -Ilib -Itest test/coverage_map_test.rb` | U2 and U5 tests and the changed pin |
| `bundle exec rake test` | The zero-dependency suite |
| `BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle exec rake test` | The fork clean check under Minitest 6 |
| `ruby -Ilib -e 'require "mutineer"'` | Load smoke |
| `bundle exec rake yard:strict` | Doc comments on `covering_test_paths`, `warn_unchecked` and every Step B method |
| `bundle exec rake test:daemon` | U3 and the U5 daemon test |
| Optional, machine-local: `probes/398/run.sh miss`, then `run.sh hit`, after `rm -rf probes/398/cache` | `verify_cached_clean` time drops on the fixture (3 of 5 tests), and the hit line prints |

`docs/cli.md` is a site page (`rake/site_docs.rb:38`) and a contract guide (`rake/docs_contract.rb:98`). So also run `bundle exec ruby -Ilib -Itest test/docs_contract_test.rb` and the website checks from `AGENTS.md`: `bundle exec rake site:build`, `node --test test/site_test.js`, `npm ci --prefix test/browser`, `npx --prefix test/browser playwright install chromium`, `npm test --prefix test/browser`.

## Definition of Done

- Step A: every U2 and U3 test exists, failed before its change where the scenario says so, and passes. The pin at `test/coverage_map_test.rb:510-511` changes with a reason. No other existing test changes.
- A covering test that fails without mutants still stops in-process, standalone and daemon runs.
- The score, exit codes and per-mutant test selection are unchanged.
- The pull request body has the U1 numbers or says why only fixture numbers exist.
- Step B: either U5 merged with its tests and the Fizzy numbers, or the follow-up issue from U4 exists and #398 links it.
- No dead code and no spike code on `main`.

---

## Risks and Overlaps

| Item | Overlap | Handling |
|---|---|---|
| Siblings rule | reload and redefine; daemon and in-process; Action and CLI; report and dry run | The check runs before any mutant, so strategy does not matter. U2 covers in-process boot, standalone and `--coverage-from`; U3 covers the daemon. The Action reuses `.mutineer/` through the CLI and gains the speed with no input change. `--dry-run` builds no map (`lib/mutineer/cli.rb:356`), so it does not change. The report gets no new key; the stderr line is the only text. |
| Behaviour change | A red test that covers no source no longer stops a hit run (AE3). | Intended: that test never runs with a mutant. A miss still captures every test and stops on it. KTD4 makes it visible. CHANGELOG names it. |
| #201 (split `coverage_map.rb`) | Another session owns it. Its branch `refactor/split-coverage-map` holds only a placeholder commit today. | Step A edits about 30 lines. If #201 lands first, move `covering_test_paths` to the unit that owns the clean check. Stop and ask if both are in review together. |
| #396 (`--since` builds the full map) | Same file, and the natural next step of KTD1. | No shared lines in Step A. Q2. |
| #382 (a `tests:` map in `.mutineer.yml`) | Its plan adds tests to a source's list, so the test set grows. | Step A narrows the hit check to covering tests, so extra non-covering tests cost no clean-check time. No shared code. |
| #380 (`--test` takes a directory or a glob) | A glob makes the whole suite easy to pass, so this plan matters more. | No shared code. |
| #360 (a red clean check names no failing test) and #282 and #338 (test order and seed) | Same error path and the together check. | The message at `lib/mutineer/job_plan.rb:176-189` is unchanged. The together check order is unchanged. |
| PR #322 and #286 (`ran_at_load` count) | Step B must keep `load_lines` and `load_methods` right. | Boot mode reads them live (`coverage_map.rb:139-145`). Standalone recaptures every test on a source edit (R10), so its load lines stay right. |
| PR #391 (the reload fix for Rails class bodies), #375 (hook-block placement), #245, #244, #332 and #335 (2.0 line) | They edit `daemon_server.rb`, `runner.rb` and `job_plan.rb`, not `coverage_map.rb`. | No shared lines. |
| KTD6 gap (Step B) | A test that starts running an edited file is not recaptured. | U4 measures it. Docs say how to force a full capture. |
| Cost of the executed-file list (Step B) | A larger `coverage.json`: one list per test. | U4 measures size and time. |

## Open Questions

None blocks Step A. Each has a default and an owner.

- Q1. Should the skipped-tests line print on every hit, or only under `--verbose`? Default: every hit (KTD4). The maintainer decides.
- Q2. After #396 reorders `Runner.execute`, should the hit check narrow further to the tests of the mutants that `--since` keeps? Default: yes, as a follow-up on #396. The maintainer decides.
- Q3. Is the KTD6 gap acceptable for an edit loop, or should Step B also recapture the tests that loaded an edited file when that set is small? Default: accept it and document it, if U4 shows only the callback case. The maintainer decides after U4.
- Q4. Should Step B land in v1.9.0 or wait for the next minor? Default: v1.9.0 if U4 passes before the batch, else the next minor. The maintainer decides.

## Sources

- Issue: context folder `issues/398.md`. Vladimir's report: `vladimir-fizzy-report.md` lines 21 and 438.
- Validation reports of 2026-11-09 under `/Users/davidteren/Projects/DT/mutineer/wip/vlad/`: `opus/` A11 (the source of the issue's numbers), `Sol/` A11 (410 dependencies, 261 captures in about 242 s, per-source keys not enough), `grok-cursor/` A11 (digest covers every source and test; put #380 first).
- Probes, machine-local and best effort: `/private/tmp/claude-501/-Users-davidteren-Projects-claude-worktrees-mutineer-vladimir-issues-planning-21adcb/ae564be8-638b-4dd0-a9e5-9d7a58cb00ae/scratchpad/context/probes/398/` (`timer.rb`, `run.sh`, `out-timings.txt`, `out-cache-shape.txt`, `out-baseline-tests.txt`, `coverage-after.json`).
- Code read: `lib/mutineer/coverage_map.rb:98-146`, `:148-201`, `:370-545`, `:568-830`, `:1320-1592`; `lib/mutineer/runner.rb:100-182`, `:228-240`; `lib/mutineer/job_plan.rb:165-189`, `:228-286`; `lib/mutineer/daemon_server.rb:170-178`, `:275-297`; `lib/mutineer/daemon_backend.rb:240-276`; `test/coverage_map_test.rb:290-320`, `:440-470`, `:484-610`, `:1355-1385`; `test/fixtures/shared_capture/`; Fizzy `test/mutineer_boot.rb:1-5` and `.mutineer.yml`.
