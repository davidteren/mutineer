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

**Use namespace tests only when existing pairing finds no test. Apply the same path rule to failed capture.**

## Goal Capsule

- **What:** pair a concern with its constant-named test, such as `test/models/storage/totaled_test.rb` for `Storage::Totaled`.
- **Why:** the concern can run and contribute to the score without moving tests or passing `--test`.
- **How:** add a fallback in `Pairing.infer_tests` and the failed-capture check. KTD1 and KTD5 define these decisions.
- **Issue:** #379 (pair a source under `concerns/` with the test that mirrors its namespace).
- **Owners:** the developer or coding agent implements all units and checks. A maintainer owns decisions and merge.
- **Authority:** this plan, then `AGENTS.md`, then the issue text. This plan controls differences; see "Corrections to the issue".
- **Stop and ask:** an existing source's test list would change; `Pairing.logical_path`, split-file helpers or `CoverageMap#ownership_paths` need edits. Also stop if a maintainer changes Q1 (path precedence), Q2 (split names) or Q4 (shared tests).
- **Size:** S (small). Ten files: two under `lib/`, three test files, two new fixtures, `docs/ci.md`, `docs/rails-setup.md` and `CHANGELOG.md`. One GitHub issue through U5 (split-name follow-up). No new runtime dependency.
- **Delivery:** one pull request from `main`. Labels: `enhancement`, `priority: medium` (medium priority), `risk: low` (low risk), `v1.9.0` (target release). Include `Closes #379`. A maintainer merges. No release step.

---

## Product Contract

### Summary

When `app/<dir>/concerns/<rest>.rb` has no test at the `concerns/` path, try exact names at the namespace path. A failed namespace test marks the concern `uncapturable` under the existing failed-capture conditions.

Add no flag, config key, JSON key or message. Keep exit code meanings.

### Problem Frame

Rails treats every `app/<dir>/concerns` directory as an autoload root. Thus `app/models/concerns/storage/totaled.rb` defines `Storage::Totaled`. Many apps use the constant-based test path, `test/models/storage/totaled_test.rb`.

Mutineer searches only the file-path mirror, `test/models/concerns/storage/`. It drops the source with `no test found by convention`. Its mutants do not run or contribute to the score. If it is the only source, the run exits 2.

Vladimir reported this with Mutineer 1.8.0 on Fizzy, a Rails 8 app. He moved two test files into `test/models/concerns/storage/` to make them pair.

### Terms

| Term | Meaning |
|---|---|
| Concern source | `app/<dir>/concerns/<rest>.rb`; `concerns` sits directly below `app/<dir>/`. |
| `concerns/` path | File-path mirror: `app/models/concerns/storage/totaled.rb` maps to `test/models/concerns/storage/totaled_test.rb`. |
| Namespace path | Mirror without `concerns/`: `test/models/storage/totaled_test.rb`, matching `Storage::Totaled`. |
| Exact name | A `Pairing.candidates` name: `<name>_test.rb`, `test_<name>.rb` or `<name>_spec.rb`. |
| Split name | `<name>_*_test.rb`, such as `totaled_bytes_test.rb`. |
| Skip line | Stderr: `[mutineer] no test found by convention for <file>; skipping` (`lib/mutineer/cli.rb:649`). |

### Requirements

**Pairing**

- R1. Without a `concerns/` path test, pair the concern with the first existing exact namespace name. Keep `Pairing.candidates` order, with the preferred framework first.
- R2. Any existing `concerns/` path result, exact or split, prevents the namespace fallback.
- R3. Preserve the test list of every source that pairs on `main`.
- R4. Apply the fallback only to concern sources. Preserve results for `lib/concerns/`, `app/concerns/`, `app/<dir>/<sub>/concerns/` and `concerns/` outside `app/`.
- R5. Exclude namespace split names. Track them through U5.

**Failed capture and test order**

- R6. Failed capture of an exact namespace name marks the concern `uncapturable`, under today's `concerns/` path conditions.
- R7. Put the namespace test first among tests covering its concern's mutant, as for every paired test.

**Surfaces**

- R8. Add no flag, config key, JSON key or message. Preserve exit code meanings and the skip line for unpaired concerns.
- R9. Explain the rule in `docs/ci.md` and `CHANGELOG.md`. Both must state that previously skipped concerns can run and change scores. Both must name the split-name follow-up issue. Add one sentence in `docs/rails-setup.md`, linked to the `docs/ci.md` pairing table.

### Acceptance Examples

Each example gives the source and files on disk. `C` means `app/models/concerns/storage/totaled.rb`.

| Example | Requirements | Files or condition | Expected result |
|---|---|---|---|
| AE1 | R1 | `C`; `test/models/storage/totaled_test.rb` | Pair them. |
| AE2 | R2 | `C`; `test/models/concerns/storage/totaled_test.rb`; `test/models/storage/totaled_test.rb` | Pair only the `concerns/` test. |
| AE3 | R2, R3 | `C`; `test/models/concerns/storage/totaled_bytes_test.rb`; `test/models/storage/totaled_test.rb` | Pair only the split file. |
| AE4 | R1 | `app/controllers/concerns/authentication.rb`; `test/controllers/authentication_test.rb` | Pair them. |
| AE5 | R1 | `C`; separately, `spec/models/storage/totaled_spec.rb` or `test/models/storage/test_totaled.rb` | Pair each. The spec pairs under both framework preferences. |
| AE6 | R5 | `C`; `test/models/storage/totaled_bytes_test.rb` | No test pairs. |
| AE7 | R4 | `lib/concerns/foo.rb` with `test/foo_test.rb`; `app/concerns/baz.rb` with `test/baz_test.rb`; `app/models/billing/concerns/bar.rb` with `test/models/billing/bar_test.rb`; `concerns/qux.rb` with `test/qux_test.rb` | None pairs. |
| AE8 | R1, R3 | `app/models/user.rb`; `app/models/concerns/user_authentication.rb`; `test/models/user_test.rb`; `test/models/user_authentication_test.rb` | `user.rb` keeps both tests, as on `main`. The concern pairs with `user_authentication_test.rb`. |
| AE9 | R1 | `app/models/concerns/helper.rb`; `test/models/test_helper.rb` | No pairing. `test_helper.rb` is a support file. |
| AE10 | R6 | Capture of `test/models/storage/totaled_test.rb` fails; no other test covers `C`. Repeat with `spec/models/storage/totaled_spec.rb`. | `uncapturable_source?` is true. |
| AE11 | R6 | Capture of `test/models/other/totaled_test.rb` fails. | Do not mark `C`. |
| AE12 | R5, R6 | Capture of `test/models/storage/totaled_bytes_test.rb` fails. | Do not mark `C`. |
| AE13 | R1, R8 | U3 fixture: `mutineer run app/models/concerns/storage/totaled.rb` | Exit 0; no skip line; one mutant killed by `TotaledTest#test_total`. |

### Scope Boundaries

| Surface | Boundary |
|---|---|
| Path rules | Keep `Pairing.logical_path`, `Pairing.candidates`, split-file helpers and `CoverageMap#ownership_paths` unchanged. |
| CLI pairing | Keep `CLI.autopair!`, its skip line and exit 2 when no source pairs. |
| Dry run | Preserve `main` behaviour: no pairing, so every source's mutants appear (`lib/mutineer/cli.rb:429`). |
| Planned dry run | #381 (count sources skipped for having no paired test) uses the same pairing helper. This change then lowers unpaired counts. See "Risks and Overlaps". |
| Explicit tests | `--test` still disables pairing (`lib/mutineer/cli.rb:642`). |

Considered and not built:

| Option | Reason |
|---|---|
| Run tests from both paths | Changes existing test lists, against R3. Fizzy has no such case. See Q1. |
| Warn when both paths have tests | The second file is already unused on `main`. |
| Guard for a twin source | `app/models/storage/totaled.rb` and `app/models/concerns/storage/totaled.rb` would share a test. Rails loads only one same-constant file. Fizzy has no such pair. |
| Add a config switch | The fallback applies only where no test pairs today. |
| Read autoload roots from the booted app | `Pairing` is path logic without Rails or a process (`lib/mutineer/pairing.rb:6-7`). |

#### Deferred to Follow-Up Work

| Work | Route |
|---|---|
| Namespace split names | U5 opens the issue; KTD3 explains the decision. |
| Concerns without a named test at either path | Fizzy has 20 of 22 unpaired concerns in this category. Use #382 (a `tests:` map in `.mutineer.yml`) or add tests. #381 makes them visible. |
| Engine or pack sources, such as `packs/x/app/models/concerns/` | `logical_path` strips only leading `app/` (`lib/mutineer/pairing.rb:121`), so no test mirrors today. Use #382. |

### Corrections to the issue

| Issue statement or omission | Correction |
|---|---|
| "Runtime behaviour was not checked." | This plan checked it. On `main`, `Pairing.infer_tests` returns `[]`; the CLI skips the sole source and exits 2. See "Probe results", row 1. |
| "Mutineer only checks `test/models/concerns/storage/totaled_test.rb`." | It also checks `test_totaled.rb` and `totaled_spec.rb` (`lib/mutineer/pairing.rb:137-148`), plus `totaled_*_test.rb` (`lib/mutineer/pairing.rb:218-223`). |
| "Update `Pairing.infer_tests`." | Also update `CoverageMap#exact_failed_test?` (`lib/mutineer/coverage_map.rb:279-293`). Its mirror helpers are `mirrored_test_dir?` at `:350-354` and `spec_mirror?` at `:364-368`. Otherwise, failed namespace capture leaves mutants `no_coverage`. Probes 2 and 12 confirmed this; R6 and U2 cover it. |
| "Keep the exact match first." | This leaves two-path precedence unspecified. R2 gives the `concerns/` path priority and prevents namespace lookup. |
| Split names omitted | Pairing supports `<name>_*_test.rb` since #87 (split test files pair with their source). R5 and KTD3 set this change's limit. |
| "Rails treats `app/models/concerns/` and `app/controllers/concerns/` as autoload roots." | Rails includes every `app/<dir>/concerns` through `railties` glob `{*,*/concerns}`. See `lib/rails/engine/configuration.rb`: line 43 in 7.0.4, line 76 in 7.2.4, line 78 in 8.0.5 and 8.1.4. Fizzy also has `app/jobs/concerns` and `app/mailers/concerns`. Nested `app/<dir>/<sub>/concerns` is not a root; R4 excludes it. |
| "Concerns contain much Rails application logic." | Before Vladimir's moves, this rule pairs 2 of 22 unpaired Fizzy concerns, containing 40 mutants. Afterwards, it pairs none. The other 20 lack named tests. This has the lowest yield of the four mapping issues. |
| "He moved tests to `test/models/concerns/`." | Confirmed: Fizzy commit `f220e4832` moves `test/models/storage/totaled_test.rb` and `tracked_test.rb` into `test/models/concerns/storage/`. |

---

## Planning Contract

### Key Technical Decisions

A maintainer owns these decisions. Implementation uses the stated defaults.

- KTD1. **Use the namespace path only as a fallback.** `infer_tests` returns today's result when nonempty. Reject a union: it adds tests to existing pairs, against R3. Reject namespace-first lookup: it changes results when both paths have tests. Fizzy has no two-path case. Existing precedent uses the first exact name (`test/pairing_test.rb:68-72`).
- KTD2. **Run the fallback only when today's result is empty.** A `concerns/` split file blocks it (AE3). Checking only for an exact name would add tests to existing split pairs, against R3.
- KTD3. **Allow exact namespace names only.** One validation report requested split names. These require the longer-source rule across directories. That touches `split_test_files`, `claimed_by_longer_source?`, `longer_source_exists?`, `source_searches_dir?`, `CoverageMap#split_failed_test?` and `CoverageMap#ownership_paths`. It could take a model's split file (AE8), against R3, and needs a maintainer decision. No unpaired Fizzy concern has a namespace split name. Later support is additive; today's skip line keeps the gap visible.
- KTD4. **Use one source-path helper.** `Pairing.namespace_base(source_rel)` returns the namespace base for `app/<dir>/concerns/<rest>.rb`, otherwise `nil`. Reject changing `logical_path`: callers include `lib/mutineer/coverage_map.rb` lines 281, 331 and 1449. That would replace the main mirror and drop existing `concerns/` pairs. Fizzy revision `8112b3dba` has 5 such sources among 27 concerns.
- KTD5. **Share the helper with failed-capture checks.** `CoverageMap#exact_failed_test?` accepts exact names in the `test/` or `spec/` mirror of `Pairing.namespace_base`. Leaving `CoverageMap` unchanged mislabels broken tests as coverage gaps (probe 12). Mutants also leave `no_verdict` (`lib/mutineer/reporter.rb:278`), which affects exit codes (`lib/mutineer/reporter.rb:172-185`). Earlier changes updated both rules: 1.2.0, #120 (failed `test_<name>.rb` capture), and 1.5.0, #87 (split names).
  
  Keep this check path-only, regardless of tests at the `concerns/` path. Run verdicts use `method_uncapturable?` (`lib/mutineer/coverage_map.rb:239-246`, called at `lib/mutineer/job_plan.rb:280`), not `uncapturable_source?` (`:218-224`). Both use `failed_test_blames?`. A failed namespace test therefore marks concern methods with zero successful coverage, even if a `concerns/` test passes. Running both paths requires explicit `--test`, because R2 selects one. Accept this existing failed-exact-test behaviour; reject a path-specific exception.
- KTD6. **Allow a concern and shorter model to share a test.** In AE8, `user.rb` keeps `user_authentication_test.rb` as a split file; the concern also pairs with it. Reject concern ownership through the longer-source rule: `user.rb` could lose its only test, against R3. `config.tests` already removes duplicates (`lib/mutineer/cli.rb:652`). See Q4.
- KTD7. **Use a plain Ruby repro in `test/fixtures/concern_namespace/`.** Reject adding it to `test/fixtures/autopair/`: #380 (let `--test` take a directory or a glob) pins that tree's test files. Reject a Rails fixture in `test/fixtures/rails_app` run through `rake test:daemon`. `CLI.autopair!` runs once (`lib/mutineer/cli.rb:429`), before the daemon check (`lib/mutineer/cli.rb:434`). Every backend receives the same `config.tests`; a daemon test adds CI time without another code path.
- KTD8. **Use a minor release entry under `### Added`.** The issue has `enhancement` and `v1.9.0` labels. `AGENTS.md`, "Releasing", requires a major bump for Action default changes. This change alters no Action input, default or step.
  
  The Action passes `--test` only for a set `test` input (`action.yml:149`, `:380`). Otherwise, CLI pairing applies. Empty `version` installs the latest gem (`action.yml:110-113`, `:134-139`), so unpinned users get this rule next release. Every minor gem release has this exposure. Earlier pairing changes shipped as minors: #87 (split files, `CHANGELOG.md:1101`, 1.5.0) and #120 (`test_*.rb`, `CHANGELOG.md:1351`, 1.2.0). Reject a major bump: that would classify every pairing change as an Action default change. See Q3.

### Assumptions

No user was present during planning. These assumptions remain unconfirmed:

- A maintainer accepts upgrade-related gate changes when skipped concerns start running (Q3).
- A maintainer accepts delayed namespace split-name support (Q2).
- One app is sufficient to size the rule. Only Fizzy was measured.

### Probe results

All probes used the worktree at `origin/main` `8d9905c4`. Fizzy supplied only a path list from `git ls-tree`; no Fizzy code ran.

| # | Question | Result |
|---|---|---|
| 1 | Does `main` skip a concern with only a namespace test? | Yes. `infer_tests` returns `[]`; the CLI prints the skip line and exits 2. Dry run still lists its mutants. |
| 2 | Does failed namespace capture mark the concern? | No. `uncapturable_source?` is false; it is true for the same test at the `concerns/` path. |
| 3 | Does a model already take a longer-named concern's test? | Yes. `user.rb` pairs with `user_test.rb` and `user_authentication_test.rb`. The concern has no pair. |
| 4 | How many Fizzy sources pair before Vladimir's moves (`8112b3dba`)? | 2 of 22 unpaired concerns: `storage/totaled.rb` and `storage/tracked.rb`. The other 20 remain unpaired. Across `app/models` and `app/controllers`, 106 of 292 are unpaired, matching his report. |
| 5 | How many pair after the moves (`f220e4832`)? | 0 of 17 unpaired concerns. Across `app/models` and `app/controllers`, 92 of 292 are unpaired, matching his report. |
| 6 | How many mutants do the 2 files contain? | 40 with default operators: 23 and 17, matching the report. Its total of 312 unpaired mutants was not remeasured. |
| 7 | How common are Fizzy split names? | 1 of 352 `app/` sources pairs with a split file. No unpaired concern has a namespace split name. |
| 8 | Does a Fizzy concern have both test paths or a twin source? | No, at either revision. |
| 9 | Does the R1 to R7 prototype pass? | Yes: 14 checks, 35 assertions. On `main`, 6 fail and 1 errors; 7 guards pass on both. |
| 10 | Does the prototype break existing tests? | No. `test/pairing_test.rb`: 49 runs, 95 assertions. Failed-capture and order tests in `test/coverage_map_test.rb`: 21 runs, 39 assertions. All pass. |
| 11 | Is the U3 fixture verdict stable? | Yes. Prototype: exit 0, 1 `arithmetic` mutant killed by `TotaledTest#test_total`, score 100.0. On `main`: exit 2. |
| 12 | What does U2 change in a run? | Two sources ran: one passing; one concern whose namespace test fails to load. With U1 only, its mutant is `no_coverage`; `no_verdict` is empty. With U1 and U2, it is `uncapturable` and enters `no_verdict`. As the sole source, the concern causes exit 1 in both cases. |

The passing prototype removes the need for a spike unit.

Not checked:

- The prototype with the full suite, `rake yard:strict` or `rake test:daemon`. Planning rules allow one test file per claim.
- A real Rails app run. Fizzy is read-only and needs installation.
- An end-to-end RSpec run. AE5 covers only `Pairing`.
- Other Rails apps. Only Fizzy was measured.

### System-Wide Impact

| Sibling | Result | Evidence |
|---|---|---|
| Reload and redefine | Same pairing, completed before either strategy. | `lib/mutineer/cli.rb:353-356`, `:429` |
| Daemon and in-process | Same pairing and failed-capture check through `JobPlan.coverage_selection`. | `lib/mutineer/cli.rb:429-434`, `lib/mutineer/job_plan.rb:229-287` |
| `--test-command` | Same pairing through `autopair!`. No coverage narrowing, so U2 does not apply. | `lib/mutineer/runner.rb:229-234` |
| Action and CLI | No Action pairing logic. Set `test` passes `--test`. Empty `test` uses CLI pairing. Empty `version` installs the latest gem, including this rule next release (KTD8). CHANGELOG tells users to pin `version` or refresh the baseline. | `action.yml:110-113`, `:134-139`, `:149`, `:380` |
| Report and dry run | Report adds the concern to `per_source`. Dry run still does not pair. | `lib/mutineer/cli.rb:429`, probe 1 |
| Minitest and RSpec | Both name forms pair (AE5). | `lib/mutineer/pairing.rb:137-148` |
| Explicit `--test` | Pairing stays off. U2 still marks a concern whose explicit namespace test fails. | `lib/mutineer/cli.rb:642` |
| Test order | Namespace test comes first for its concern (R7). | `lib/mutineer/coverage_map.rb:170-180` |
| Coverage cache | Newly paired tests change the digest, causing one rebuild. The owner list stays unchanged. | `lib/mutineer/coverage_map.rb:1415-1434` |

---

## Implementation Units

### U1. Namespace fallback in `Pairing.infer_tests`

**Goal:** pair concerns without a `concerns/` path test with an exact namespace test.

**Requirements:** R1, R2, R3, R4, R5, R7; AE1 to AE9.

**Dependencies:** U5 supplies the follow-up issue number for the AE6 test comment.

**Files:**

| File | Edit |
|---|---|
| `lib/mutineer/pairing.rb` | Add `Pairing.namespace_base` with YARD documentation. Extend `infer_tests` (lines 103-110). Update module documentation (lines 6-22) and `infer_tests` documentation (lines 93-102). |
| `test/pairing_test.rb` | Add the tests below. |
| `test/coverage_map_test.rb` | Add one order test. |

**Approach:**

1. Match `app/<dir>/concerns/<rest>.rb` in `namespace_base`; return `<dir>/<rest>` (KTD4).
2. Keep today's `infer_tests` body. If its result is empty and `namespace_base` returns a base, use the fallback (KTD2).
3. Return the first existing `candidates` path for that base (KTD1), with `lib: false`; qualifying sources are under `app/`.
4. Reuse `candidates` framework order and its exclusion of `test_helper.rb`.

**Patterns to follow:** `with_tree`, `infer` and `infer_tests` (`test/pairing_test.rb:12-29`); split-file guards (`test/pairing_test.rb:214-239`).

**Test scenarios** (`test/pairing_test.rb`; guards pass before and after):

| Test | Check | Before change |
|---|---|---|
| `test_namespace_base` | `app/models/concerns/storage/totaled.rb` returns `models/storage/totaled`. `app/controllers/concerns/authentication.rb` returns `controllers/authentication`. Return `nil` for `lib/concerns/foo.rb`, `app/concerns/baz.rb`, `app/models/billing/concerns/bar.rb`, `concerns/qux.rb`, `app/models/concerns.rb`, `models/concerns/x.rb`, `app/models/user.rb`. | Fails: method absent. |
| `test_concern_pairs_with_the_test_at_its_namespace_path` | AE1. | Fails: `[]`. |
| `test_concerns_path_wins_over_the_namespace_path` | AE2; R2 guard. | Passes. |
| `test_split_file_at_the_concerns_path_blocks_the_namespace_fallback` | AE3; R2 and R3 guard. | Passes. |
| `test_controller_concern_pairs_at_the_top_level_namespace_path` | AE4. | Fails. |
| `test_concern_namespace_fallback_accepts_spec_and_test_prefix_names` | AE5. Check the spec with `prefer: "minitest"` and `prefer: "rspec"`, plus `test_totaled.rb`. | Fails. |
| `test_split_file_at_the_namespace_path_does_not_pair_a_concern` | AE6; R5 guard. Comment names the U5 follow-up issue. | Passes. |
| `test_only_a_concerns_dir_directly_below_an_app_dir_falls_back` | AE7; R4 guard. | Passes. |
| `test_model_keeps_its_split_file_when_a_concern_shares_it` | AE8. | `user.rb` passes as an R3 guard; concern fails. |
| `test_helper_concern_does_not_pair_with_test_helper` | AE9 guard. | Passes. |

Keep every existing test unchanged and passing to verify R3 at this level.

`test/coverage_map_test.rb`:

- `test_order_tests_puts_a_concern_namespace_test_first`: use `CoverageMap.from_data`, the AE1 tree and one extra test path. Assert that `order_tests` puts the namespace test first. Before the change, path order causes failure. Follow `test_order_tests_puts_paired_files_first_then_the_cheapest` (line 799).

**Verification:** failure cases fail before and pass after; guards and existing tests pass unchanged.

### U2. Failed-capture check for the namespace path

**Goal:** failed namespace capture marks the concern `uncapturable`, not `no_coverage`.

**Requirements:** R6; AE10, AE11, AE12.

**Dependencies:** U1 provides `Pairing.namespace_base`.

**Files:**

| File | Edit |
|---|---|
| `lib/mutineer/coverage_map.rb` | Update `exact_failed_test?` (lines 279-293) and its documentation (lines 270-278). Document any new private helper with YARD. |
| `test/coverage_map_test.rb` | Add the tests below. |

**Approach:**

1. In the `app/` or `lib/` branch, accept `test/` and `spec/` mirrors of `Pairing.namespace_base(source_rel)` (KTD5).
2. Use `Pairing.mirror_dir`; a top-level concern maps directly to `test/<dir>`.
3. Preserve `split_failed_test?`, `mirrored_test_dir?`, `spec_mirror?` and `ownership_paths` (R5, KTD3).

**Patterns to follow:** `test_failing_exact_spec_in_the_mirror_marks_the_source_uncapturable` (`test/coverage_map_test.rb:1426`). Reuse its tree, failing test body and `capture_subprocess_io` wrapper.

**Test scenarios:**

| Test | Check |
|---|---|
| `test_failing_namespace_test_marks_the_concern_uncapturable` | AE10: separate cases for `test/models/storage/totaled_test.rb` and `spec/models/storage/totaled_spec.rb`. Each contains `require 'does/not/exist'`. Assert true for `uncapturable_source?` and `method_uncapturable?(concern, 1..3)`. The run uses the latter (`lib/mutineer/job_plan.rb:280`); follow `test/coverage_map_test.rb:1603`. Before the change, both return false. |
| `test_failing_same_name_outside_both_mirrors_does_not_taint_the_concern` | AE11 guard. Assert false for `uncapturable_source?` and `method_uncapturable?`. |
| `test_failing_split_name_at_the_namespace_path_does_not_taint_the_concern` | AE12; R5 guard. Assert false for `uncapturable_source?` and `method_uncapturable?`. |
| `test_failed_exact_name_in_another_mirror_does_not_taint_that_source` (line 1481) | Keep unchanged and passing. |

These tests check real failed capture and path matching, not a full-run report label. Existing tests cover conversion through `JobPlan.coverage_selection` to `uncapturable`.

**Verification:** the first test fails before and passes after. Existing failed-capture tests pass unchanged.

### U3. Repro fixture with expected verdicts

**Goal:** keep the reported case as a fixture with fixed expected verdicts.

**Requirements:** R1, R8; AE13.

**Dependencies:** U1.

**Files:**

| File | Edit |
|---|---|
| `test/fixtures/concern_namespace/app/models/concerns/storage/totaled.rb` | New plain Ruby module `Storage::Totaled`. Its sole method, `total(used, reserved)`, returns `used + reserved`. No Rails. |
| `test/fixtures/concern_namespace/test/models/storage/totaled_test.rb` | New Minitest class `TotaledTest`. Include the module, load it through `require_relative`, and assert `total(2, 3)` equals 5. |
| `test/cli_test.rb` | Add a `with_concern_namespace_project` copy helper next to `with_autopair_project`. Add one test after `test_orphan_source_warns_and_is_skipped` (lines 1359-1368). |

**Approach:** use a new fixture directory. Do not add files under `test/fixtures/autopair`. Its users and #380 (let `--test` take a directory or a glob) pin its file list. `Rakefile:23` excludes fixture tests from the suite (KTD7).

**Patterns to follow:** copy `with_autopair_project` (`test/cli_test.rb:1314-1319`) for the new helper. Use `matrix` assertions (`test/cli_test.rb:519-524`).

**Test scenarios:**

`test_concern_pairs_with_its_namespace_test_and_is_scored` covers AE13. Run `run app/models/concerns/storage/totaled.rb --matrix --format json` in the fixture copy.

| Assertion | Expected value |
|---|---|
| Exit | 0 |
| Stderr | No `no test found by convention` |
| `per_source` | Only the concern |
| `summary` | `total`: 1; `killed`: 1; `score`: 100.0 |
| `matrix.tests` | One row: `file` is `test/models/storage/totaled_test.rb`; `name` is `TotaledTest#test_total`; `kills` is 1 |
| Mutant row | `status`: `killed`; `killed_by`: `[0]` |

**Verification:** on `main`, the test fails with exit 2 and the skip line. It passes after U1.

### U4. Docs, CHANGELOG and the follow-up issue

**Goal:** explain the rule and identify deferred work by issue number.

**Requirements:** R5, R9.

**Dependencies:** U1, U2, U5.

**Files:**

| File | Edit |
|---|---|
| `docs/ci.md` | Add a pairing-table row (lines 36-41), after `app/foo/bar.rb`. |
| `docs/rails-setup.md` | Add one sentence after the table containing "Tests" (line 37). Do not edit the "Tests" row: #380, #381 and #382 change it. Explain exact namespace pairing for `app/<dir>/concerns/` and link the `docs/ci.md` pairing table. |
| `README.md:176`; `docs/getting-started.md:56` | Leave unchanged. They explain pairing generally; `docs/ci.md` contains the table. |
| `CHANGELOG.md` | Add an entry under `### Added` in `## [Unreleased]`. If absent, add `### Added` above `### Fixed`. |

**Approach:**

1. Use the U5 issue number wherever split-name support is deferred.
2. Add the `docs/ci.md` row for `app/models/concerns/storage/totaled.rb`. Prefer `test/models/concerns/storage/totaled_test.rb`. With no test there, try exact namespace names: `test/models/storage/totaled_test.rb`, `test_totaled.rb` or `spec/models/storage/totaled_spec.rb`. State that split files pair only at the `concerns/` path; cite the follow-up issue. Explain that previously skipped concerns can run and change scores.
3. Title the CHANGELOG entry "A concern pairs with the test that mirrors its namespace (#379)". Include these points in order:
   - New paths, using `Storage::Totaled`.
   - Fallback order preserves existing test lists.
   - Previous behaviour: skip line and no score.
   - Previously skipped concerns can run and change scores or gates.
   - `--baseline` treats their survivors as new. Tell users to refresh the baseline; refer to `docs/ci.md`, "Refresh the baseline".
   - Failed namespace loading can change a `--threshold` run from exit 0 to exit 1. Mutants move from `no_coverage` to `uncapturable`. This fails a `nil`-score gate and increases the broken share (`lib/mutineer/reporter.rb:182-183`, `:191`).
   - Empty Action `version` installs the latest gem, applying the rule next run. Tell users to pin `version` or refresh the baseline.
   - Split-name limit and follow-up issue.
4. Never copy the reporter's private gist link into any file or pull request text.

**Test scenarios:** none; documentation only.

**Verification:** `docs/ci.md` and `CHANGELOG.md` name #379 and the follow-up issue. `docs/rails-setup.md` links the pairing table. Site build and browser checks pass.

### U5. Open the follow-up issue for split names

**Goal:** assign an issue number to deferred split-name support before code or documentation cites it.

**Requirements:** R5, R9.

**Dependencies:** none. Complete this unit before U1.

**Approach:** open "Pair split test files at a concern's namespace path". Apply `enhancement` and `priority: low` (low priority). State R5, KTD3 and probe 7. Record the number for U1's AE6 comment and U4's `docs/ci.md` and `CHANGELOG.md` entries.

**Test scenarios:** none; issue creation only.

**Verification:** the issue exists. Its number appears in the U1 test comment, `docs/ci.md` and `CHANGELOG.md`.

---

## Verification Contract

Where unset, prefix every `ruby`, `rake` and `bundle` command with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`.

- `bundle exec ruby -Ilib -Itest test/pairing_test.rb`: U1; R3 at the `Pairing` level.
- `bundle exec ruby -Ilib -Itest test/coverage_map_test.rb`: U1 order test and U2.
- `bundle exec ruby -Ilib -Itest test/cli_test.rb -n "/concern|autopair|orphan|unpaired/"`: U3; unchanged skip line and exit 2. Require more than 0 tests.
- `bundle exec rake test`: zero-dependency suite.
- `ruby -Ilib -e 'require "mutineer"'`: load smoke test.
- `bundle exec rake yard:strict`: documentation for `Pairing.namespace_base` and any new private helper.
- `bundle exec rake site:build`, then `node --test test/site_test.js`: published-page checks for `docs/ci.md` (`docs/llms.txt:33`).
- `npm ci --prefix test/browser`, then `npx --prefix test/browser playwright install chromium`, then `npm test --prefix test/browser`: browser checks required by `AGENTS.md`, "Website checks". They need Node.js 22+ and a free port 8766.

Not required: `bundle exec rake test:daemon`; no Rails-dependent test changes, and CI runs it. The Minitest 6 Gemfile is also unnecessary because the Minitest integration does not change.

Run every new test once on `main` before implementation. Cases marked "Fails before" must fail there.

## Definition of Done

- All U1 to U3 tests exist. Each "Fails before" case failed before its unit and passes afterwards.
- Every existing test passes unchanged, verifying R3.
- Fixture command `mutineer run app/models/concerns/storage/totaled.rb` exits 0 with one killed mutant.
- A concern without tests at either path still prints `no test found by convention` and is skipped.
- `docs/ci.md` and `CHANGELOG.md` explain the rule and name the follow-up issue.
- CHANGELOG includes the `--baseline`, exit code and Action notes. `docs/rails-setup.md` links the pairing table.
- `bundle exec rake yard:strict` reports 100%.
- The pull request has all four labels and `Closes #379`. No file or pull request text contains the private gist link.
- The diff contains no dead code or abandoned implementation.

---

## Risks and Overlaps

| Item | Overlap | Handling |
|---|---|---|
| Upgrade changes a score or gate | Previously skipped concerns run. Survivors lower scores and count as new under `--baseline` (`lib/mutineer/baseline.rb:133-141`, `:170`). | Intended. CHANGELOG explains the effect and baseline refresh. Same as #87 (split test files), 1.5.0. See Q3. |
| #381 (count sources skipped for having no paired test) | Changes `CLI.autopair!`, a copied `autopair` fixture, `test/cli_test.rb` and the `docs/ci.md` pairing area. This change reduces unpaired sources. | No shared production edit: `lib/mutineer/cli.rb` stays unchanged. U3 uses its own fixture, so #381 fixture copies do not change. Text conflicts only; either merge order works. Two validation reports request #381 first or in the same release. Its dry run calls pairing and adds `summary.unpaired_sources` and `summary.unpaired_mutants` (#381 plan, R13 "dry-run counts" and U3 "Dry run summary"). This change reduces those counts and the dry-run unpaired clause. If #381 is on the base, U3 must also assert `summary.unpaired_sources` equals 0. |
| #382 (a `tests:` map in `.mutineer.yml`) | Adds mapped tests to paired tests and functions in `lib/mutineer/pairing.rb`. | The fallback belongs to the paired result and ignores mapped tests. Shared edits: module comment (`lib/mutineer/pairing.rb:6-22`) and `docs/ci.md` table. Text conflicts only. |
| #380 (let `--test` take a directory or glob) | Adds an expansion method in `lib/mutineer/pairing.rb` and changes its module comment (lines 6-22). | Different methods; the second merge resolves the comment conflict. This plan preserves `candidates` and `logical_path`. |
| #380 fixture file list | #380 AE1 and AE3 run `--test test` on `test/fixtures/autopair` and pin two files. | This plan adds no files under `test/fixtures/autopair/test`. U3 uses `test/fixtures/concern_namespace/` (KTD7). |
| #201 (split `coverage_map.rb` into smaller units) | May move `exact_failed_test?`. | U2 changes one method. Rebase onto the first merged change. |
| #391 (reload fix for Rails class bodies) | Adds `app/models/concerns/trackable.rb` and `test/models/concerns/trackable_test.rb` under `test/fixtures/rails_app`. | No overlap. Its dogfood step omits `--test`, so it pairs through today's `concerns/` rule. The fallback does not run. |
| #395 (Action asks CLI for `cache_dir` and baseline) | Changes `test/cli_test.rb` and `CHANGELOG.md`. | U3 inserts one test. Text conflict only. This plan checked branch file names, not content. |
| 2.0 pull requests #244 (2.0 contract flip) and #245 (parallel Rails runs by default) | Both change `test/cli_test.rb` and `CHANGELOG.md`. | Same handling as #395. |
| 2.0 pull requests #314 (baseline and unverified survivors) and #322 (count tested `ran_at_load` mutants) | Both change `test/cli_test.rb` and `CHANGELOG.md`. | Same handling as #395. |
| #383 (lazy-loaded concern scores every mutant `error`), fixed by #391 | More Rails concerns run. With lazy loading, reload of an `included do` concern raises `MultipleIncludedBlocks` until #391. See Fizzy report, lines 26 and 85; #391 body, "Lazy concerns (#383)". Every mutant becomes `error`; the broken-share rule can exit 1 under `--threshold` (`lib/mutineer/reporter.rb:191`). | Land after #391, a patch fix due before 1.9.0. If it remains unmerged when this pull request is ready, add a CHANGELOG warning. State that newly paired lazy-loaded concerns can score `error` without it. |
| Every other open pull request | Adds a `CHANGELOG.md` entry under `## [Unreleased]`. | Text conflict only. |
| Shared test file | AE8 pairs a model and concern with one test. | Intentional (KTD6). `config.tests` removes duplicates. See Q4. |
| Validation request for split names and `ownership_paths` | Deferred by this plan. | KTD3 explains why; probe 7 measures need. A maintainer can reverse Q2. |
| Private gist link in the issue body | Copying would spread the link. | U4 step 4 and the Definition of Done prohibit copying. |

## Open Questions

None blocks implementation. A maintainer owns each decision; implementation uses these defaults.

| Question | Default | Revisit condition |
|---|---|---|
| Q1. Should tests at both paths run? | No. The `concerns/` path wins (KTD1). | A maintainer requests a union. Later support is additive but changes test lists. |
| Q2. Should namespace split names pair now? | No. U5 opens the follow-up issue (KTD3). | A maintainer includes them in this change. |
| Q3. Is a minor release correct when gates can change? | Yes: `v1.9.0`. `AGENTS.md` requires major releases for Action default changes; none changes here. Earlier pairing changes were minor releases (KTD8). Unpinned Action users still receive the rule next release. | A maintainer decides at release time. |
| Q4. Should a concern take its namespace test from a shorter model (AE8)? | No. Share the test (KTD6). | A maintainer decides with Q2; both require the longer-source rule. |

## Sources

- `lib/mutineer/pairing.rb:103-148`: `infer_tests`, `logical_path`, `candidates`; `:218-357`: split files and longer-source rule.
- `lib/mutineer/coverage_map.rb:170-180`: `order_tests`; `:263-368`: failed-capture checks; `:1442-1470`: `ownership_paths`.
- `lib/mutineer/cli.rb:417-444`: `validate!`; `:641-660`: `autopair!`; `:898-930`: `dry_run`.
- `lib/mutineer/job_plan.rb:229-287`: `coverage_selection`, shared by daemon and in-process execution.
- `lib/mutineer/reporter.rb:172-185` and `:278`: exit codes and `no_verdict` count `uncapturable`, not `no_coverage`. `lib/mutineer/baseline.rb:133-141`: new survivors.
- `CHANGELOG.md:1101-1124`: #87, split test files, 1.5.0. `:1351-1357`: `test_*.rb` names, 1.2.0.
- Vladimir's Fizzy report: "Missing parts" and "Unpaired sources".
- Three validation reports dated 2026-11-09 agree that #379 is real and small. One counts 2 files and 40 mutants, matching probes 4 and 6. One requests split-name and `ownership_paths` changes (KTD3).
- Machine-local, best-effort probe scripts and output: `/private/tmp/claude-501/-Users-davidteren-Projects-claude-worktrees-mutineer-vladimir-issues-planning-21adcb/ae564be8-638b-4dd0-a9e5-9d7a58cb00ae/scratchpad/context/probes/379/`. A missing folder does not block work. "Probe results" records every number; this plan controls differences.