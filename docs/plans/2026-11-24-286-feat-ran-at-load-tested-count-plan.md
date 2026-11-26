---
title: ran_at_load mutants that survived their tests are counted, marked and put in the unrun share - Plan
type: feat
date: 2026-11-24
issues: [286]
pull_requests: [322]
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# ran_at_load mutants that survived their tests are counted, marked and put in the unrun share - Plan

Suggested model and effort for the build: Opus 5.5, `medium`. The plan settles the design, names each function and gives the text of each new string.

## Goal Capsule

- **Group:** 20-B "`ran_at_load` verdicts" of the mutineer 2.0 run.
- **Issue:** #286 (`ran_at_load` hides survivors on lines that tests also cover, and those mutants have no verdict path).
- **Pull request:** #322 (draft, +109 and -20 lines over pull request #314). The builder keeps it and updates its branch `feat/286-count-tested-ran-at-load`.
- **Objective:** every report shows how many `ran_at_load` mutants survived their tests. The JSON report lists which ones. stderr warns when `ran_at_load` mutants are a large share of the run.
- **Verdict rule for 2.0:** no `ran_at_load` mutant gets a verdict in a coverage-guided run. All of them stay out of the score and out of `no_verdict`. The exit code does not change. See KTD1.
- **Means:** three commits. U1 is the content of #322 on the current code, plus the block rule of #493 that #322 does not know. U2 puts `ran_at_load` in the unrun share warning. U3 pins the counts in the oracle tests, files two follow-up issues and moves the limit citations to them.
- **Authority:** this plan, then `AGENTS.md`, then the issue text. Where this plan differs from #286 or from the body of #322, this plan wins (see "Corrections to the issue and the pull request").
- **Depends on:** group 20-A. Pull request #314 must be in `origin/integration/v2.0` before the build starts. If it is not there, do not build. Set 20-B to `waiting`.
- **Leave a commit out when:** never. All three commits ship. `AggregateResult#unrun_count` has one caller, `Reporter#unrun_for_share`, so U2 can change only the warning. If the builder finds another caller on `integration/v2.0`, it stops and reports (A3).
- **Execution profile:** one pull request (#322), base `integration/v2.0`, ready for review. Labels: `enhancement`, `v2.0`, `priority: medium`, `risk: medium`. Remove `breaking change` (D6). Body: `Closes #286`.
- **Who ships:** the builder updates #322. The orchestrator merges it into `integration/v2.0`. No agent merges into `main`, tags or releases.
- **Size:** small. About 45 lines in `lib/`, about 150 lines of tests, and doc rows.

---

## Product Contract

### Summary

Each `ran_at_load[]` entry in the JSON report says if the mutant survived its tests before a load rule moved it (`tested`).
`summary.ran_at_load_tested` counts those entries. The human and HTML reports show the same count.
`ran_at_load` mutants count in the unrun share, so stderr warns when they are more than 10% of the mutants the run tried to score.
The score, the `no_verdict` gate and every exit code stay as they are.

### Problem Frame

A mutant gets the status `ran_at_load` in three places. All three are on `main` at `c5100143` (1.10.0).

| # | Place | When | Did the run execute tests for the mutant? |
|---|---|---|---|
| 1 | `JobPlan.coverage_selection` (`lib/mutineer/job_plan.rb`) | No test covers the line, and the line ran at load. | No. The mutant never ran. |
| 2 | `JobPlan.load_verdict` | The mutant survived its tests, and its line ran at load (#187, pull request #215). | Yes. No test failed. |
| 3 | `JobPlan.stored_block_verdict` | The mutant survived its tests, it is in a block whose call ran at load, and the reach probe did not see the mutated expression return in a test (#493, pull request #524). | Yes. No test failed. |

`Runner.run` (`lib/mutineer/runner.rb`) and `DaemonBackend.job_result` (`lib/mutineer/daemon_backend.rb`) call the rules of rows 2 and 3 in the same order.

Rows 2 and 3 can hide a real test gap. Row 1 is different: no test was selected, so the mutant never ran.
Today the report gives all three the same entry. Probe P1 shows two runs of one fixture, one of row 1 and one of row 2, with identical `ran_at_load[]` entries.

**What #322 gives.** A `Result` field `tested_at_load`, set by `JobPlan.load_verdict` only. `summary.ran_at_load_tested`, `ran_at_load[].tested`, a line in the human report and a count in the HTML report.

**What #322 lacks.** It was written on 2026-10-24. Three things changed after that date:

1. Pull request #524 added row 3. With #322 as written, a row 3 mutant has `tested: false`, and the docs of #322 say "the rest of `ran_at_load` had no test run them". Probe P2: 7 `ran_at_load` mutants, 6 passed their tests, #322 marks 1.
2. Pull request #509 gave `ran_at_load[]` entries a `diff` (`Reporter#mutant_with_diff_json`). `Result` got a `seconds` field (#495). The load-time text moved from `README.md` to `docs/rails-setup.md`.
3. `ran_at_load` is "excluded from the denominator and from the no-verdict gate, like unplaceable" (`lib/mutineer/result.rb`). `unplaceable` counts in the unrun share (#291). `ran_at_load` does not, so no warning says that a run moved many mutants out of the score.

**What #286 asks beyond #322.**

| Ask in #286 | Answer in this plan |
|---|---|
| Report "ran at load and covered by a test" separately | U1. |
| Do not list such a baseline survivor as fixed | Done in pull request #314 (`Baseline#diff`, `baseline.unverified_survivors[]`). This plan adds no baseline code. R8 keeps the test green. |
| Measure the hidden-survivor rate on the dogfood runs and one real app | Probes P3 and P5 below. The share of `ran_at_load` is 0 on both, so they give no rate. F1 holds the question. |
| Consider a flag that runs only `ran_at_load` mutants in a fresh process | Considered. Not in 2.0 (KTD1). `--test-command` with `--only` already gives one method a verdict (probe P11). Follow-up issue F1. (#588) |
| A `ran_at_load` budget in the exact-verdict oracle | U3 pins the count and the tested count in four oracles. |
| Conditional code in a statement that ran at load is never `ran_at_load` | Reproduced (probe P4). It is a false survivor, not a hidden one. Follow-up issue F2. (#589) |
| The two cases that the fix for #493 added (issue comment of 2026-11-22) | Both get `tested: true` in U1, so a reader sees them. Their verdict needs F1. |

### Probes run for this plan

All probes ran on 2026-11-24 in a scratch worktree of `origin/main` at `c5100143`. Fixtures are in `test/fixtures/load_time/`. "Marker" means the U1 change applied by hand.

- **P1. The two kinds look the same on `main`.** `mutineer run lib/catalog.rb --test test/catalog_test.rb --strategy redefine --format json`, with and without `--boot boot.rb`. Both reports hold one `ran_at_load[]` entry with the same keys and values. Without the boot file the test ran and passed (row 2). With it no test ran the mutant (row 1).
- **P2. #322 as written misses the block rule.** Sources `lib/language_record.rb` and `lib/language_product.rb`, test `test/language_product_test.rb`, `--strategy redefine --boot language_lazy_boot.rb`, operators `comparison,statement_removal,call_to_receiver`. Result: 17 mutants, 9 killed, 1 survived, 7 `ran_at_load`. With #322 as written, `ran_at_load_tested` is 1. With the marker on both rules it is 6. The one mutant that no test ran is `statement_removal` of `limits[:language] = 35`.
- **P3. What a fresh process says about the tested mutants.** The same fixtures with `--test-command`:

  | Fixture | Tested `ran_at_load` mutants | Killed in a fresh process | Survived in a fresh process |
  |---|---|---|---|
  | `lib/catalog.rb` | 1 | 1 | 0 |
  | `lib/shelf.rb` | 2 | 2 | 0 |
  | `lib/language_record.rb` | 6 | 6 | 0 |
  | `lib/apply_each.rb` with `test/apply_each_empty_test.rb` | 1 | 0 | 1 |
  | Total | 10 | 9 | 1 |

  So "tested" is not "survived". On these fixtures 9 of 10 are kills that the coverage-guided run cannot see, and 1 is a real gap. The fixtures were written to show false survivors, so this is not a rate for real code.
- **P4. Conditional code on a load line stays a false survivor.** A scratch class `Cond` with `def self.price(base, double = true)`, the body `base *= 2 if double` then `base + 0`, and `ALL = [price(3)].freeze`. The test checks `Cond::ALL`. Under `--strategy redefine`: the `statement_removal` mutant of `base *= 2 if double` is `survived`, and the score is 0.0. With `--test-command` the same mutant is `killed`.
- **P5. How often real code hits `ran_at_load`.**

  | Run | Mutants | `ran_at_load` | Tested | Source |
  |---|---|---|---|---|
  | Self-dogfood command of `.github/workflows/ci.yml`, `main` plus the marker | 280 | 0 | 0 | this plan, 2026-11-24 |
  | Fizzy sample, 8 files, mutineer at `d770a991` (has the block rule of #493) | 63 | 0 | 0 | `~/.cache/mutineer/fizzy-sample/report.json`, 2026-11-24 (current) |
  | Fizzy, all of `app/models` and `app/controllers`, `main` at `c30cfc68` | 1,071 | 4 | not measured | `wip/Vladimir/2026-11-09-deep-validation-brief.md` (current, before #493) |
  | A 378-file app, the change of pull request #215 | not recorded | 84 moved from `survived`, 11 from `no_coverage` | not measured | body of #215 (current, 2026-10) |

  The share is small in the three measured runs. Only the full Fizzy run is older than #493, so only that run lacks the block rule.
- **P6. The unrun share does not count `ran_at_load`.** `lib/shelf.rb` under `--strategy redefine`: 6 mutants, 2 killed, 2 survived, 2 `ran_at_load`. stderr has no unrun-share line. With `ran_at_load` in `AggregateResult#unrun_count` the share is 2 of 6 (33.3%). With the text of U2 applied by hand, the same run with `--threshold 50` prints the line of AE5, has the score 50.0 and exits 0. `test/reporter_test.rb` (70 runs) stays green with that text.
- **P7. The whole suite with `ran_at_load` in `unrun_count`.** `bundle exec rake test` on `main` plus the marker and step 1 of U2, with no text change. Result: 2,496 runs, 0 failures, 0 errors, 5 skips. No existing test fails, so U2 changes one existing test by choice (`test_unrun_count`) and adds the others.
- **P8. The merge recipe of KTD4.** In a scratch worktree of `origin/feat/286-count-tested-ran-at-load`: `git merge --no-commit --no-ff origin/main` gave 19 conflicted files. `git restore --source=origin/main --staged --worktree -- .` left 0 unmerged paths and a tree equal to `origin/main`, with the merge still open for the commit.
- **P9. The net diff of #322 on `main`.** `git apply --3way` of `git diff origin/fix/283-286-baseline-unverified-survivors...origin/feat/286-count-tested-ran-at-load` on `origin/main`: 5 files apply clean, 8 conflict (`CHANGELOG.md`, `README.md`, `docs/json-schema.md`, `lib/mutineer/reporter.rb`, `lib/mutineer/result.rb`, `test/baseline_test.rb`, `test/json_reporter_test.rb`, `test/result_test.rb`). Each conflict is "keep both sides". U1 names the result for each file.
- **P10. The tested list of each oracle fixture, with the marker on both rules.** `Runner.execute` in a child process, as the tests do.

  | Fixture and run | `ran_at_load` | Tested |
  |---|---|---|
  | `lib/catalog.rb`, `redefine`, no boot | 1 | 1 |
  | `lib/catalog.rb`, `reload`, `boot.rb` | 1 | 0 |
  | `lib/shelf.rb`, `redefine`, no boot | 2 | 2 (`Shelf.bump`, `Shelf.short`) |
  | `lib/shelf.rb`, `redefine` and `reload`, `shelf_boot.rb` | 2 | 0 |
  | `lib/language_record.rb`, `redefine` and `reload`, `language_eager_boot.rb` | 7 | 6 |
  | both language sources, `redefine`, `language_lazy_boot.rb` | 7 | 6 |
  | `lib/apply_each.rb`, `redefine` and `reload`, `apply_boot.rb`, the empty test | 1 | 1 |

  In each language run the one mutant without the mark is `statement_removal` of `limits[:language] = 35`. In every row, a `ran_at_load` result has the mark exactly when its `seconds` is not nil (R13).
- **P11. One method in a fresh process.** `mutineer run lib/shelf.rb --test test/shelf_test.rb --only Shelf.bump --test-command "ruby %{files}"` runs 1 mutant and kills it. So a user can verify one `ran_at_load` mutant today without a run of the whole file.

### Requirements

**The marker (U1)**

- R1. `Result` has a field `tested_at_load`, default `false`. `Result#tested_at_load?` is true only for that field equal to `true`.
- R2. `JobPlan.load_verdict` and `JobPlan.stored_block_verdict` set `tested_at_load: true` on the result they move to `ran_at_load`. Any result they do not move comes back as the same object.
- R3. A `ran_at_load` result of `JobPlan.coverage_selection` keeps `tested_at_load` false.
- R4. In-process (`Runner.run`) and daemon (`DaemonBackend.job_result`) give the same value for the same mutant. Neither function changes: they already call the two rules.
- R5. JSON: `summary.ran_at_load_tested` is an integer. Each `ran_at_load[]` entry has a boolean `tested`. `copies`, when present, stays the last key of the entry.
- R6. Human report: one more row under `Ran at load:`, printed at 0 too, as the other rows are. HTML report: one more count, `ran_at_load (tested)`, right after `ran_at_load`.
- R7. The score, `no_verdict`, `attempted` and every exit code are the same as before for every run. `AggregateResult#mutation_score`, `#meets_threshold?` and `Reporter#exit_code` do not change.
- R8. `test_ran_at_load_baseline_survivor_is_unverified_not_fixed` (`test/baseline_test.rb`, from pull request #314) stays green with no edit.

**The unrun share (U2)**

- R9. `AggregateResult#unrun_count` is `unplaceable_count + skipped_invalid_count + ran_at_load_count`.
- R10. The stderr warning of `Reporter#warn_unrun_share` names the `ran_at_load` mutants and how many of them survived their tests. The rule for when it prints is the same as today: more than 1 mutant, and more than 10% of attempted plus unrun.
- R11. The warning changes no exit code, with or without `--threshold`, and prints on every format.

**Oracles, limits and docs (U3)**

- R12. Four oracle tests pin the tested count: `test/load_time_test.rb`, `test/class_macro_load_test.rb` (in-process and the daemon step), `test/daemon_backend_contract_test.rb`, and the Rails dogfood script `test/fixtures/rails_app/bin/dogfood`.
- R13. In the fixture runs, a `ran_at_load` result has `tested_at_load` true exactly when it has a run time (`seconds` is not nil). This catches a later rule that moves a survivor and forgets the field. A comment at the check says so, and says what to do when a later change gives a run time to a result that never ran: change the check, not the field.
- R14. Each limit this plan leaves open names a follow-up issue in the code, the tests and the docs. No live limit cites #286 after the merge.
- R15. Each contract copy changes in the commit that makes it false: `docs/json-schema.md`, `docs/rails-setup.md`, `docs/agentic-coding.md`, `docs/agentic-coding.html`, `skills/mutineer/SKILL.md`, `docs/sample-report.html`, `CHANGELOG.md`.
- R16. `Reporter::SCHEMA_VERSION` keeps the value it has on `integration/v2.0`. The docs label each new key with that version.

### Acceptance Examples

Each example is a real run in `test/fixtures/load_time/`. The values come from the probes.

- AE1. **Covers R2, R5.** `lib/catalog.rb`, `test/catalog_test.rb`, `--strategy redefine`, no boot file. Then `Catalog.price` is `ran_at_load` with `tested` true, `summary.ran_at_load` is 1, `summary.ran_at_load_tested` is 1, and the score is `null`.
- AE2. **Covers R3.** The same run with `--boot boot.rb`, under `reload` and under `redefine`. Then `Catalog.price` is `ran_at_load` with `tested` false, and `summary.ran_at_load_tested` is 0.
- AE3. **Covers R2, R4.** The run of probe P2. Then 7 mutants are `ran_at_load` and 6 have `tested` true. The five block mutants (`LANGUAGE_BLOCK_MUTANTS`) are among the 6.
- AE4. **Covers R2.** `lib/apply_each.rb`, `test/apply_each_empty_test.rb`, `--boot apply_boot.rb`, operator `literal_mutation`. Then the one mutant is `ran_at_load` with `tested` true.
- AE5. **Covers R9, R10.** `lib/shelf.rb`, `test/shelf_test.rb`, `--strategy redefine`. Then stderr holds: `[mutineer] 2 of the 6 mutants mutineer tried to score were not run or were classed as ran at load (2 ran at load of which 2 survived their tests; 33.3%, limit 10%).`
- AE6. **Covers R7, R11.** The run of AE5 with `--threshold 50`. Then the score is 50.0 and the exit code is 0, as on `main`.
- AE7. **Covers R10.** A report of 18 killed and 2 `ran_at_load` results prints no unrun-share line (2 is exactly 10% of 20, and the rule is "more than"). A report of 17 killed and 2 prints it. A report of 1 killed and 1 `ran_at_load` prints none (the floor of 1).

### Scope Boundaries

Considered and not built:

- **A verdict for `ran_at_load` mutants.** See KTD1 and follow-up issue F1. (#588)
- **A flag that runs only `ran_at_load` mutants in a fresh process.** It needs a test command for the app, a second backend in one run, and one score from two backends that count uncovered mutants in different ways. Follow-up issue F1. (#588)
- **A field that names the rule** (`line` or `block`) on each entry. Nobody asked. `docs/rails-setup.md` already tells the reader what to do for a block.
- **`tested` derived from `seconds`.** A `ran_at_load` result with a run time is one that ran its tests. The rule is true today (R13 pins it), but it is a hidden link between two fields. An explicit field says what it means.
- **A `tested` key on `baseline.unverified_survivors[]`.** The entry has `status`. The reader finds the mutant in `ran_at_load[]` by `id`, when the baseline has the current id format.
- **A `--baseline` failure when `summary.ran_at_load_tested` rises.** A new gate. Named as an option in F1.
- **A new count in `rake/fizzy_sample.json`.** `fizzy:sample` prints a new report key as a note and does not compare it. The next `fizzy:record` stores it.

### Corrections to the issue and the pull request

1. **The body of #322 says "Fixes #286" and "stacked on #314".** After the build it says `Closes #286`, its base is `integration/v2.0`, and it does not name the stack.
2. **#322 says a `ran_at_load` mutant without the mark "had no test run it".** False since #493. U1 sets the mark in both rules, and the docs say so.
3. **#322 adds its sentence to `README.md`.** That text moved. U1 puts it in `docs/rails-setup.md`.
4. **#286 cites `lib/mutineer/job_plan.rb:243-272` and `:228-230`.** The functions are `JobPlan.ran_at_load?` and `JobPlan.load_verdict`. Line numbers moved.
5. **#286 says a baseline survivor that is now `ran_at_load` is listed as fixed.** Pull request #314 changes that. On `integration/v2.0` after 20-A it is false.
6. **The issue comment of 2026-10-24 suggests `details: "survived"` as the marker.** `details` is the error text of a result. This plan keeps the field of #322.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **No `ran_at_load` mutant gets a verdict in 2.0, and none enters the score.** A correct verdict needs the load to run again with the mutant in place. Three paths do that today, each for a part: `--test-command` (every case; `--only` limits it to one method, probe P11), `--strategy reload` with no boot file (the class body of the mutated file), and `--daemon` with eager load off (a caller that loads after the mutant). Full reload (#389, group 20-G) will add the class body of a caller. U1 names these paths in the docs. Probe P3 shows why no cheaper rule works: of 10 tested mutants, 9 are kills and 1 is a survivor in a fresh process. Counting them as `survived` brings back the false survivors of #187 (84 on one app). Counting them in `no_verdict` makes `--threshold` fail on a run that is not broken, with no fix a user can apply except `--test-command`. Governs R7.
- KTD2. **One boolean, two writers.** Keep the field of #322 (`tested_at_load`). `JobPlan.load_verdict` and `JobPlan.stored_block_verdict` both write `result.with(status: :ran_at_load, tested_at_load: true)`. Governs R1 to R4.
  - **The meaning, in every text:** "the run scored the mutant `survived` with the tests it selected, and a load rule then moved it to `ran_at_load`". The short phrase for a person is "survived their tests". Use that one phrase in the warning, the human report, the docs and the CHANGELOG.
  - **Do not write** "the tests ran the mutated code" (for a block mutant the probe says they did not), "ran in their covering tests" (the text of #322), or "every test passed" (a child that exits 0 during load is also scored `survived`).
  - **One idea, four names.** Each follows the pattern of its place:

    | Place | Name |
    |---|---|
    | `Result` field and predicate | `tested_at_load`, `tested_at_load?` |
    | `AggregateResult` count | `ran_at_load_tested_count` |
    | JSON | `summary.ran_at_load_tested`, `ran_at_load[].tested` |
    | HTML count label | `ran_at_load (tested)` |
- KTD3. **`tested` goes before `copies` in a row, through a keyword of the existing builder.** `Reporter#mutant_with_diff_json(result, seconds: false)` puts `copies` last, and `test_copies_follow_the_diff_on_a_killed_row` pins that for `killed[]`. Add a keyword `tested: false` beside `seconds:`, and the line `row[:tested] = result.tested_at_load? if tested` before `row[:copies] = copies if copies`. Only the `ran_at_load:` list passes `tested: true`. No new method. Governs R5.
- KTD4. **Update the branch with one merge commit that takes the tree of `integration/v2.0`. No force-push.** The branch holds merge commits of the old #314 branch, and #314 arrives in `integration/v2.0` as a squash. The recipe (probe P8):

  ```sh
  git fetch origin
  git worktree add ../mutineer-20B -B feat/286-count-tested-ran-at-load origin/feat/286-count-tested-ran-at-load
  cd ../mutineer-20B
  git merge --no-commit --no-ff origin/integration/v2.0      # conflicts are expected
  git restore --source=origin/integration/v2.0 --staged --worktree -- .
  git diff --cached --stat origin/integration/v2.0            # must print nothing
  git commit -m "chore: take the tree of integration/v2.0 (U1 to U3 write the #322 changes again) (Refs #286)"
  ```

  After this commit the branch equals `integration/v2.0`. U1, U2 and U3 follow as three new commits, written from this plan. The old commits stay in the history of the branch. The pull request is squash-merged, so they do not reach `integration/v2.0`.

  **This recipe replaces the four #322 steps of `plans/20-M-merge-order-plan.md`** ("#322, after #314 is merged"). Those steps merge the final head of #314 and fix 8 conflicted files by hand. Both ways give the same content, with no force-push. This way has no conflict to fix, and it does not need `refs/pull/314/head`. Every item of the "Must keep" list of 20-M ("20-B: #322") is in U1 or U3 of this plan.
- KTD5. **No schema bump in this pull request.** Pull request #314 sets `Reporter::SCHEMA_VERSION` to `"2.0"`. The two new keys are additive inside that version, which is not released. Read the constant on `integration/v2.0` and write that value in the docs ("New in schema `2.0`", in the wording 20-A uses for its own keys). `STABILITY.md` names the schema version and not single keys, so it needs no edit. If 20-A added a key list there, add the two keys to it. Governs R16.
- KTD6. **All `ran_at_load` mutants join the unrun share, not only the tested ones.** `AGENTS.md` ("Score-model discipline") gives a mutant that exists but has no verdict a place in `AggregateResult#unrun_count`. One number is simpler than two, and the warning text gives the tested part. The warning is the "budget or warning" that the rule "Count what you exclude" asks for. Governs R9 to R11.
- KTD7. **The lead of the warning changes only when a `ran_at_load` mutant is in it.** A tested mutant did run, so "were not run" alone would be false. With at least one `ran_at_load` mutant the lead is "were not run or were classed as ran at load". The words "classed as" matter: the status is a class, and the mutated code itself did not always run at load. With none the lead stays "were not run", so each existing assertion on that text stays green.
- KTD8. **#286 closes. Two follow-up issues take what stays open.** F1 holds the verdict path. F2 holds the false survivors that the rule does not catch. Both get the label `backlog`. See "Limits left open".
- KTD9. **Three commits, in this order: U1, U2, U3.** `RULES.md` asks for one commit per issue. This group has one issue, so the plan splits it by unit, for review. Each commit message names #286. All three ship.

### Decisions for David

The run takes the recommended option. Each row names the other option.

| # | Choice | Recommended (taken) | Why | Other option |
|---|---|---|---|---|
| D1 | Do `ran_at_load` mutants get a verdict in 2.0? | No. All stay out of the score and out of `no_verdict`. The report counts and marks the ones that survived their tests. | In a fresh process 9 of 10 tested fixture mutants are kills and 1 is a survivor, so each fixed verdict is wrong for some. | Count the tested ones as `survived` (the behaviour before #215), or build the fresh-process flag now (issue F1). |
| D2 | Which mutants get `tested: true`? | Every mutant that survived its tests and then became `ran_at_load`: the line rule (#187) and the block rule (#493). The merge-order plan (20-M, Decision 10) and Codex chose the same. | Both hide a possible gap in the same way. With the line rule only, 5 of the 6 tested mutants of probe P2 read as "no test ran it". | Mark the line rule only, as #322 does, and give the block rule its own key. |
| D3 | Does a large `ran_at_load` share give a signal? | Yes. A stderr warning through the unrun share, above 1 mutant and above 10%. The exit code does not change. | `unplaceable` already works this way, and `result.rb` says `ran_at_load` is "like unplaceable". A `--since` run of a method that boot calls can lose most of its mutants with no line on stderr today. | No warning (the count alone), or count the tested ones in `no_verdict` so they can fail `--threshold` (a breaking change, against the decision in #215 to keep them out of the gate). |
| D4 | What happens to #286? | Close it with #322. File F1 and F2 with the label `backlog`. | The reporting half of #286 is done. The rest is one feature and one defect, each with its own scope. | Keep #286 open with `Refs #286`, move its label from `v2.0` to `backlog`, and change no citation. |
| D5 | How does the branch of #322 get onto `integration/v2.0`? | One merge commit that takes the tree of `integration/v2.0`, then three new commits. No force-push. | No conflict to fix by hand, and the pull request is squash-merged. | The four merge steps of 20-M (merge the head of #314, fix 8 files, `merge -s ours`, merge the branch). Or a rebase with `--force-with-lease`, which the global rule forbids. |
| D6 | Does #322 keep the label `breaking change`? | No. Remove it. | It had the label because it sat on #314 (schema `2.0`). On `integration/v2.0` it only adds keys and one warning. | Keep it. |
| D7 | Labels of F1 and F2 | `backlog` for both. F1 gets `priority: medium`, as #286 has. | 2.0 can ship without them: `--test-command` gives the verdict today, and #389 changes the facts for F1. | `v2.0`, if David wants a verdict path before 2.0 ships. 20-M names `priority: low` for F1. |

### Assumptions

- A1. Group 20-0 created `origin/integration/v2.0` and set the base of #322 to it. The builder checks with `gh pr view 322 --json baseRefName` and runs `gh pr edit 322 --base integration/v2.0` if needed.
- A2. Group 20-A merged #314, so `lib/mutineer/baseline.rb` on `integration/v2.0` has `unverified_survivors` and `Reporter::SCHEMA_VERSION` is `"2.0"`. The builder checks with `git grep -n "unverified_survivors" origin/integration/v2.0 -- lib/mutineer/baseline.rb`.
- A3. 20-A may have moved gate methods from `Reporter` to `AggregateResult` (the #314 branch has `AggregateResult#attempted_count`, `#no_verdict_count` and `#incomplete?`). The builder finds each function by name, not by file. On `main`, `unrun_count` has one caller, `Reporter#unrun_for_share`. The builder checks with `git grep -n "unrun_count\|unrun_for_share" origin/integration/v2.0 -- lib rake action.yml`. If another caller reads it for an exit code or a gate, stop and report.
- A4. No group that merges before 20-B adds a fourth place that gives `ran_at_load`. The builder checks with `git grep -n "status: :ran_at_load\|Result.ran_at_load" origin/integration/v2.0 -- lib`. Expected: the factory `Result.ran_at_load` in `result.rb`, its one use in `job_plan.rb` (`coverage_selection`), and two `with(status: :ran_at_load)` calls in `job_plan.rb`.

### Places that compare reports or expect fixed text

- `test/json_reporter_test.rb` and `test/baseline_test.rb` assert the schema version with a comment. #322 changed only the comment. Take the lines of `integration/v2.0` as they are.
- `test/json_reporter_test.rb`: `test_other_lists_have_no_seconds`, `test_ran_at_load_summary_count_and_list_stay_out_of_no_verdict`, and the diff tests (`test_killed_unplaceable_and_ran_at_load_rows_have_diff_encoding` and the others that read `ran_at_load[]`) must stay green. A test that asserts the exact key list of a `ran_at_load[]` entry gains `tested`.
- `test/result_test.rb`: `test_unrun_count` (U2).
- `test/reporter_test.rb`: the block "unrun share (#291)". Each assertion on "were not run" stays green with no edit (KTD7).
- `test/cli_test.rb`: `refute_includes err, "were not run"` in the empty-run test stays green: that run has no `ran_at_load` result.
- `test/html_reporter_test.rb`: `test_summary_counts_ran_at_load`.
- `docs/sample-report.html`: the list of counts.
- `rake/docs_contract.rb`, `HEADING_IDS`: the heading "`no_coverage[]`, `uncapturable[]`, `unplaceable[]` and `ran_at_load[]` (array of object)" must keep its exact text.
- `rake/fizzy_sample.rb`: a new integer key in `summary` is a note, not a failure. No change.
- Probe P7: no existing test fails with `ran_at_load` in `unrun_count`.

---

## Implementation Units

### U1. Count and mark the `ran_at_load` mutants that survived their tests

- **Goal:** the content of #322 on the current code, with the mark set by both rules.
- **Requirements:** R1 to R8, R15, R16.
- **Dependencies:** the merge commit of KTD4.
- **Commit:** `feat: count the ran_at_load mutants that survived their tests (Refs #286)`.
- **Files:**
  - `lib/mutineer/result.rb`
  - `lib/mutineer/job_plan.rb`
  - `lib/mutineer/reporter.rb`
  - `test/result_test.rb`
  - `test/runner_test.rb`
  - `test/json_reporter_test.rb`
  - `test/reporter_test.rb`
  - `test/html_reporter_test.rb`
  - `docs/json-schema.md`
  - `docs/rails-setup.md`
  - `docs/agentic-coding.md`, `docs/agentic-coding.html`, `skills/mutineer/SKILL.md`
  - `docs/sample-report.html`
  - `CHANGELOG.md`
- **Approach:**
  1. `lib/mutineer/result.rb`, `Result`:
     - Add `:tested_at_load` as the last member of `Data.define`, after `:seconds`.
     - Add `tested_at_load: false` as the last keyword of `initialize`, with `@param tested_at_load [Boolean] a ran_at_load mutant that the run scored survived before a load rule moved it (#286).`
     - Add `def tested_at_load? = tested_at_load == true` after `ignored?`, with a YARD `@return` line.
     - In the status comment of `ran_at_load`, add: "`tested_at_load` is true when the run scored the mutant survived with its tests and a load rule then moved it (`JobPlan.load_verdict`, `JobPlan.stored_block_verdict`), so the mutant may hide a test gap (#286). It is false when no test was selected, so the mutant never ran (`JobPlan.coverage_selection`)."
     - Change the comment above `Result` from "Every field but `status` defaults to nil" to name the one field that defaults to `false`.
  2. `lib/mutineer/result.rb`, `AggregateResult`: add `def ran_at_load_tested_count = (@by_status[:ran_at_load] || []).count(&:tested_at_load?)` after `ran_at_load_count`, with a YARD `@return` line.
  3. `lib/mutineer/job_plan.rb`: in `load_verdict` and in `stored_block_verdict`, change `result.with(status: :ran_at_load)` to `result.with(status: :ran_at_load, tested_at_load: true)`. Extend each comment with one sentence: the result is marked `tested_at_load`, because it survived its tests first (#286).
  4. `lib/mutineer/reporter.rb`:
     - `json_report`, `summary`: add `ran_at_load_tested: @agg.ran_at_load_tested_count` on the line after `ran_at_load:`, with a comment that names the schema version and #286.
     - `mutant_with_diff_json`: the keyword and the line of KTD3. Add `@param tested [Boolean] also add tested (#286), for ran_at_load.`
     - `json_report`, the `ran_at_load:` list: call `mutant_with_diff_json(r, tested: true)`. Keep the `sort_by`.
     - `summary_html`: add `"ran_at_load (tested)" => @agg.ran_at_load_tested_count` right after `"ran_at_load"`.
     - `summary(out, ...)` (the human report): right after the `Ran at load:` row, add one more `format` row, printed at 0 too: `format("  after tests: %-6d  (of those: survived their tests before the load rule moved them, so each can hide a test gap; tested: true in --format json)", @agg.ran_at_load_tested_count)`. The label is 13 characters wide, as `Ran at load: ` is.
     - The comment of `attempted_count` says "Mutants that were actually run". Add one clause: a `ran_at_load` mutant that survived its tests also ran, and it is not counted here, because its result is not trusted.
  5. `docs/json-schema.md`:
     - `summary` table: add a `ran_at_load_tested` row after `ran_at_load`. Text: "The `ran_at_load` mutants that the run scored `survived` with their tests before a load rule moved them. Each can hide a test gap. The other `ran_at_load` mutants had no test selected and never ran. Excluded from the score, from `attempted` and from `no_verdict`, as `ran_at_load` is. To get a verdict, see `ran_at_load[]` below."
     - `attempted` row: add "A `ran_at_load` mutant is not in `attempted`, also when it survived its tests first."
     - The paragraph under the heading of `ran_at_load[]`: say that each `ran_at_load[]` entry also has `tested` (boolean). True for the line rule and for the block rule of #493. False when no test was selected for the line. Then the ways to get a verdict: `--test-command` for the file, or with `--only Class#method` for one method; `--strategy reload` with no boot file, when the class body of the mutated file made the call; `--daemon` with eager load off, when another class made the call.
     - Add both keys to the list of schema `2.0` changes that 20-A wrote at the top of the file.
  6. `docs/rails-setup.md`, the load-time table: add one row. Result: "A `ran_at_load` mutant survived its tests first". Treatment: "The JSON report marks it `tested: true` and counts it in `summary.ran_at_load_tested`. It can be a missing test or a kill that this run cannot see. Check it before you write a test: run its method with `--test-command` and `--only Class#method`."
  7. `docs/agentic-coding.md`, the paragraph that starts "Zero survivors alone is not success": after the sentences on `summary.unpaired_mutants`, add: "Also check `summary.ran_at_load_tested` (Mutineer 2.0 or later). Above 0, that many mutants survived their tests and are not in the score. Each one has `tested: true` in `ran_at_load[]`. Check each one before you write a test: run its method with `--test-command` and `--only`. Add a test only if the mutant survives there." Make the same change in `docs/agentic-coding.html` and `skills/mutineer/SKILL.md`.
  8. `docs/sample-report.html`: add `<span><strong>0</strong> ran_at_load (tested)</span>` after the `ran_at_load` span.
  9. `CHANGELOG.md`, under `## [Unreleased]`, "Added": "**`summary.ran_at_load_tested` and `ran_at_load[].tested` (#286).** They count and mark the `ran_at_load` mutants that survived their tests first: a survivor on a line that ran at load, and a survivor in a block whose call ran at load (#493). Such a mutant can hide a test gap. The human and HTML reports show the count. The score and the exit code do not change."
- **Patterns to follow:** the `seconds` field of `Result` and the `seconds:` keyword of `mutant_with_diff_json` (#495).
- **Test scenarios:**
  - `test/result_test.rb`. Take `test_load_verdict_marks_only_a_survivor_as_tested_at_load` and `test_tested_at_load_defaults_to_false` from #322 (`git show origin/feat/286-count-tested-ran-at-load:test/result_test.rb`). The first needs `require "minitest/mock"`.
  - `test/runner_test.rb`, `test_stored_block_verdict_moves_only_an_unreached_probed_candidate_survivor`: in the loop over the 16 combinations, assert `after.tested_at_load?` equals `moved`. The `assert_same` lines below it stay.
  - `test/runner_test.rb`, `test_the_three_verdict_steps_keep_the_maybe_and_define_method_verdicts`: in the last loop, assert that the `ran_at_load` result is `tested_at_load?`.
  - `test/json_reporter_test.rb`. Take `test_ran_at_load_entries_say_which_ran_in_their_tests` from #322, with the name `test_ran_at_load_entries_say_which_survived_their_tests`. It covers both values of `tested`. Add one test: a `ran_at_load` row with a dropped copy (`copies: { id => [other] }`) has keys that end in `tested`, `copies`. Add to `test_other_lists_have_no_seconds` or beside it: `killed[]`, `unplaceable[]` and `no_verdict[]` entries have no `tested` key.
  - `test/reporter_test.rb`. A test for the human row: with 1 killed and 1 tested `ran_at_load`, the output includes `"  after tests: 1"`. With 1 killed and 1 `ran_at_load` that is not tested, it includes `"  after tests: 0"`. Take `test_html_counts_tested_ran_at_load` from #322. Do not take `test_ran_at_load_tested_count_prints_only_when_positive`: its text and its rule are replaced.
  - R7. In `test/reporter_test.rb`: results of 1 killed, 1 survived and 3 tested `ran_at_load`. `mutation_score` is 50.0, `exit_code(threshold: 50.0)` is 0, and `exit_code(threshold: 51.0)` is 1. The same three values for the same results with `tested_at_load` false. In the JSON of both, `summary.attempted` is 2 and `summary.no_verdict` is 0.
- **Verification:** the checks of the Verification Contract.

### U2. `ran_at_load` mutants count in the unrun share

- **Goal:** stderr warns when `ran_at_load`, `unplaceable`, skipped and unpaired mutants together are more than 10% of the mutants the run tried to score.
- **Requirements:** R9, R10, R11, R15.
- **Dependencies:** U1 (`ran_at_load_tested_count`).
- **Commit:** `feat: ran_at_load mutants count in the unrun share warning (Refs #286)`.
- **Files:**
  - `lib/mutineer/result.rb`
  - `lib/mutineer/reporter.rb`
  - `test/result_test.rb`
  - `test/reporter_test.rb`
  - `docs/json-schema.md`
  - `docs/agentic-coding.md`, `docs/agentic-coding.html`, `skills/mutineer/SKILL.md`
  - `.expectation-fit/decisions/scoring-and-verdicts.md`
  - `CHANGELOG.md`
- **Approach:**
  1. `AggregateResult#unrun_count`: add `+ ran_at_load_count`. New comment: "Mutants that exist and have no verdict in a run that is not broken: unplaceable, skipped invalid and ran at load. None is in the score. A ran_at_load mutant can have run its tests (`tested_at_load`), so the name is wider than 'not run'. The reporter adds unpaired mutants to the unrun share unless `--fail-fast` is set. `unrun_count` excludes them."
  2. `Reporter#warn_unrun_share`:
     - `ran = @agg.ran_at_load_count`.
     - After the "skipped (invalid)" part: `parts << "#{ran} ran at load of which #{@agg.ran_at_load_tested_count} survived their tests" if ran.positive?`.
     - The lead: "were not run or were classed as ran at load" when `ran.positive?`, else "were not run" (KTD7).
     - After the `unplaceable[]` hint: `message << " A ran_at_load mutant is on code that ran while the app or its class loaded, so this run cannot judge it. See ran_at_load[] in --format json: tested is true for one that survived its tests. --test-command verifies them." if ran.positive?`.
     - Update the YARD comment: the unrun mutants are unplaceable, skipped invalid and ran at load.
  3. `Reporter::UNRUN_SHARE_LIMIT`, the comment: add the measures of probe P5, each with its date and commit: 0 of 280 on the self-dogfood (2026-11-24), 0 of 63 on the Fizzy sample at `d770a991` (with the block rule of #493), 4 of 1,071 on the full Fizzy run of 2026-11-09 (before #493). So the limit of 10% stays. This is the estimate that "Estimate exclusion frequency" asks for.
  4. `lib/mutineer/result.rb`, the status comment of `ran_at_load`: add "Counted in the unrun share."
  5. `docs/json-schema.md`: in the `unplaceable` and `skipped_invalid` rows, the sum becomes `unplaceable + skipped_invalid + ran_at_load + unpaired_mutants`, on both sides of the comparison. In the `ran_at_load` row, add: "Counted in the unrun share (see `skipped_invalid`). The warning names how many of them survived their tests."
  6. `docs/agentic-coding.md`, the sentences added in U1: add "They count in the unrun-share warning on stderr." Same change in the two copies.
  7. `.expectation-fit/decisions/scoring-and-verdicts.md`: add one line. "**Ran at Load After Tests.** A survivor that a load rule moves to `ran_at_load` (`JobPlan.load_verdict`, `JobPlan.stored_block_verdict`) is marked `tested_at_load`, counted in `summary.ran_at_load_tested`, and stays out of the score, out of `attempted` and out of `no_verdict`. All `ran_at_load` mutants count in the unrun share. A new rule that moves a survivor to `ran_at_load` sets the mark. Say 'survived their tests', never 'the tests ran the mutated code'. (#286)"
  8. `CHANGELOG.md`, "Changed": "**`ran_at_load` mutants count in the unrun share (#286).** When `unplaceable`, skipped, `ran_at_load` and unpaired mutants together are more than 1 and more than 10% of the mutants the run tried to score, stderr warns, and names how many `ran_at_load` mutants survived their tests. The exit code does not change."
- **Patterns to follow:** the `unplaceable` part and hint in `warn_unrun_share`.
- **Test scenarios:**
  - `test/result_test.rb`, `test_unrun_count`: add one `Result.ran_at_load` to the list and expect 4.
  - `test/reporter_test.rb`, in the "unrun share" block, with the `unrun_err` helper:
    - 2 killed and 3 `ran_at_load`, 2 of them `tested_at_load`. stderr includes "3 of the 5 mutants mutineer tried to score were not run or were classed as ran at load", "(3 ran at load of which 2 survived their tests; 60.0%, limit 10%)", "does not change the exit code" and "ran_at_load[]". It does not include "unplaceable".
    - 2 killed, 1 unplaceable and 2 `ran_at_load`. The parts read "1 unplaceable, 2 ran at load of which 0 survived their tests".
    - AE7: 18 killed and 2 `ran_at_load` print no warning (exactly 10%). 17 killed and 2 print it. 1 killed and 1 `ran_at_load` print none.
    - R11: the first results with `format: "json", threshold: 80.0` print the warning, and `exit_code(threshold: 80.0)` is 0.
    - 2 killed and 3 unplaceable still print "were not run (" with no "classed as" (KTD7).
    - 2 killed and 2 `ran_at_load` with one unpaired source of 2 mutants: the warning names all three kinds. With `fail_fast: true` the unpaired part is not in it, and the `ran_at_load` part is.
  - `test_exit_code_does_not_count_ran_at_load_toward_the_no_verdict_limit` stays green with no edit.
  - Probe P7 found no existing test that fails on `main`. If a test on `integration/v2.0` expects an empty stderr and now sees the warning, assert the warning there. Do not remove results from the test.
- **Verification:** the checks of the Verification Contract.

### U3. Pin the counts in the oracles, file the follow-up issues, move the limit citations (#588, #589)

- **Goal:** a change that moves a mutant into or out of `ran_at_load`, or that forgets the mark, fails a test. Each open limit has an issue.
- **Requirements:** R12, R13, R14, R15.
- **Dependencies:** U1 and U2.
- **Commit:** `test: pin the tested ran_at_load counts in the oracles, and track the open limits (Refs #286)`.
- **Files:**
  - `test/load_time_test.rb`
  - `test/class_macro_load_test.rb`
  - `test/daemon_backend_contract_test.rb`
  - `test/fixtures/rails_app/bin/dogfood`
  - `lib/mutineer/job_plan.rb` and `lib/mutineer/statement_lines.rb` (comments only)
  - `docs/json-schema.md`
  - `docs/rails-setup.md`
  - `docs/plans/2026-11-24-286-feat-ran-at-load-tested-count-plan.md` (the copy of this plan)
- **Approach:**
  1. File F1 and F2 first (texts in "Limits left open"), so their numbers exist. Use `gh issue create` with all four labels.
  2. `test/load_time_test.rb`:
     - `run_load_time`: take the change of #322. The child script also prints the subjects of the results with `tested_at_load?`, and the helper returns them as a third value.
     - In the child script, before the print, add the check of R13 with its comment: for each result with `ran_at_load?`, raise unless `r.tested_at_load? == !r.seconds.nil?`.
     - `test_standalone_redefine_reports_ran_at_load_not_survived`: tested is `["Catalog.price"]` (AE1).
     - `test_boot_reports_ran_at_load_not_no_coverage`: tested is empty for both strategies (AE2).
     - `test_survivors_and_kills_that_do_not_depend_on_load_keep_their_verdict`: tested is `["Shelf.bump", "Shelf.short"]`.
     - `test_boot_reports_one_line_defs_called_at_load_as_ran_at_load`: tested is empty for both strategies. In boot mode no test is selected for `Shelf.bump` and `Shelf.short`, so they never ran (probe P10).
     - New test for AE5 and AE6. Run the CLI with `Open3.capture3(RbConfig.ruby, "-I#{LIB}", File.expand_path("../bin/mutineer", __dir__), "run", "lib/shelf.rb", "--test", "test/shelf_test.rb", "--strategy", "redefine", "--format", "json", "--threshold", "50", "--cache-dir", cache, chdir: ROOT)`, with `CI` removed from the child's environment. Assert the exit code 0, the stderr line of AE5, `summary.ran_at_load` 2, `summary.ran_at_load_tested` 2 and `summary.score` 50.0.
  3. `test/class_macro_load_test.rb`:
     - `run_rows`: the child script also prints `result.tested_at_load?` for each row, with the same R13 check. Return the tested keys as a fourth value. Existing callers take three values and do not change.
     - `test_a_block_that_the_caller_stored_before_the_mutant_is_ran_at_load`: the tested keys are `LANGUAGE_BLOCK_MUTANTS` plus `"statement_removal normalizers[:language] = ->(value) { value.strip }"` (AE3). `"statement_removal limits[:language] = 35"` is not tested.
     - `test_eager_load_gives_the_same_verdicts_under_both_strategies`: the same six tested keys, under both strategies (probe P10).
     - `test_a_block_that_no_test_runs_is_ran_at_load`: the mutant is tested, under both strategies (AE4).
     - `test_a_branch_of_a_stored_block_that_no_test_takes_is_ran_at_load`: `literal_mutation "no"` is tested.
     - `test_the_daemon_moves_a_block_survivor_only_when_the_probe_did_not_fire`: the `run` lambda also collects `result.tested_at_load?` for each row. In the "probe did not fire" case, all seven macro mutants are tested: the map covers every line, and the stub client answers `survived` for each request. In the "probe fired" case, the two statement mutants are tested and the five block mutants are `survived`.
  4. `test/daemon_backend_contract_test.rb`, `test_a_survivor_on_a_line_that_ran_at_boot_is_ran_at_load`: add `assert_predicate results.first, :tested_at_load?` (from #322).
  5. `test/fixtures/rails_app/bin/dogfood`, the `ran_at_load` check of `price_list`: read `ran_at_load_tested` too and expect 0. No test covers the line of `PriceList.price`: the initializer runs it at boot, and the forked tests do not repeat the load. So the mutant never ran. If the run gives another value, stop and explain it in the pull request body before any change to the expected value.
  6. Move the limit citations. In each place below, `#286` names a limit that stays open. Replace it with the number of F1 or F2:

     | Place | Text near the citation | New citation |
     |---|---|---|
     | `lib/mutineer/statement_lines.rb`, the comment in `stored_method_lines` | "an empty `each` on the same line can count without this call" | F1 |
     | `test/class_macro_load_test.rb`, above `test_a_block_that_no_test_runs_is_ran_at_load` | "A limit of the rule" | F1 |
     | `test/class_macro_load_test.rb`, above `test_a_branch_of_a_stored_block_that_no_test_takes_is_ran_at_load` | "A limit of the rule" | F1 |
     | `docs/json-schema.md`, "the call can still be `ran_at_load`" | `each` on a `define_method` line | F1 |
     | `docs/rails-setup.md`, the row "A mutant survives on a line executed during loading" | the same `each` limit | F1 |
     | `docs/json-schema.md`, first limit bullet of the #493 rule | "no test reaches" | F1 |
     | `docs/json-schema.md`, second limit bullet | "raises or throws" | F1 |
     | `docs/json-schema.md`, third limit bullet | "it can be a false survivor (#286, #389)" | F2, #389 |
     | `docs/json-schema.md`, "Code that runs only sometimes, such as the body of `x if c`, does not." | (no citation today) | add F2 |
     | `lib/mutineer/job_plan.rb`, the comment of `ran_at_load?`, "So code that runs only sometimes ... never counts" | (no citation today) | add F2 |

     Leave `#286` where it gives the reason for a rule and not a limit: the `each` sentence in the comment of `JobPlan.ran_at_load?`, the comment in `test/runner_test.rb` above `test_a_mutant_that_shares_a_load_line_is_ran_at_load`, and every `CHANGELOG.md` entry of a released version. Run `git grep -n "#286" -- lib test docs skills README.md` at the end and check each hit against this table. A hit that is in neither list is a limit: give it the F1 number.
  7. `docs/json-schema.md`, the first two limit bullets: add "Each such mutant has `tested: true`."
  8. Measure (no code). On the head commit, run the self-dogfood command of `.github/workflows/ci.yml` with `--format json --output <file>`. Read `summary.ran_at_load` and `summary.ran_at_load_tested`. Expected: 0 and 0 (probe P5). Write the numbers of P3 and P5 in the pull request body and in F1. Do not run `fizzy:sample` for this: its recorded `ran_at_load` is 0, so it gives no rate.
  9. Copy this plan to `docs/plans/2026-11-24-286-feat-ran-at-load-tested-count-plan.md`.
  10. Post one comment on #286 that starts with `**Claude:**`: what the pull request ships (the mark, the count, the unrun share), that the baseline part shipped in #314, the probe numbers of P3 and P5, and that F1 and F2 hold what stays open.
- **Test scenarios:** the tests named in steps 2 to 5.
- **Verification:** the checks of the Verification Contract. The Rails dogfood job is green in CI.

---

## Verification Contract

Set `LANG=en_US.UTF-8` and `LC_ALL=en_US.UTF-8` for every command. Run each check on the head commit, before each push.

| Check | Command | Proves |
|---|---|---|
| Zero-dependency suite | `bundle exec rake test` | R1 to R13, unit and CLI scenarios |
| Load smoke | `ruby -Ilib -e 'require "mutineer"'` | The gem loads |
| Docs coverage | `bundle exec rake yard:strict` | Each new method, parameter and constant has a comment |
| Daemon tests | `bundle exec rake test:daemon` | The daemon gives the same mark (R4) |
| Generated docs | `bundle exec rake docs:check` | The contract copies are not stale |
| Website checks | The commands in `AGENTS.md`, "Website checks" | `docs/json-schema.md`, `docs/rails-setup.md`, `docs/agentic-coding.*` and `docs/sample-report.html` build, and the browser tests pass |
| Only planned files | `git diff origin/integration/v2.0...HEAD --stat` | The diff holds only the files this plan names |
| Every writer sets the mark | `git grep -n "status: :ran_at_load" -- lib` | Three hits: the factory `Result.ran_at_load`, and two `with` calls that both have `tested_at_load: true` |
| The oracle | `test/integration_test.rb` is green with no edit | The exact-survivor oracle does not move |
| No version change | `git diff origin/integration/v2.0...HEAD -- lib/mutineer/version.rb` prints nothing | `RULES.md`, rule 13 |

Not needed: the Minitest 6 run and the Prism 2 run. No Minitest integration, parsing or parse-error code changes.

Then the pre-PR gate of `RULES.md`, rule 6: the author self-check skill, `/ce-code-review`, `/fit-review`, and `/cubic-loop` in local mode against `integration/v2.0`.

## Definition of Done

- U1, U2 and U3 are in the pull request, as three commits after the merge commit of KTD4.
- AE1 to AE7 hold, and each one has its test.
- The body of #322 is in What, Why, How form, has "Decisions for David" with D1 to D7, has `Closes #286`, names F1 and F2, and ends with the attribution line.
- #322 is ready for review, has the base `integration/v2.0`, and has the labels `enhancement`, `v2.0`, `priority: medium`, `risk: medium`. It does not have `breaking change`.
- F1 and F2 exist with four labels each.
- CI is green on the head commit. Each review thread has a reply that starts with `**Claude:**`.
- `reports/20-B.md` in the run folder has the details, and `runs.jsonl` has the builder's line.

## Risks

| Risk | What to do |
|---|---|
| 20-A or 20-M left `reporter.rb` or `result.rb` in another shape than this plan saw on `main`. | Find each function by name. The content of each change is in U1 and U2. |
| A group that merges later (20-F for #507, 20-G for #389, or a sync of `main` with #467) adds a rule that moves a survivor to `ran_at_load` and does not set the mark. | The R13 check in the fixture helpers fails for it. The decision line of U2, step 7 tells a reviewer. |
| The warning of U2 prints in a test that expects an empty stderr. | Assert the warning there (U2, "Test scenarios"). |
| A reader takes `tested: true` as good news, or as "survived". | Each text says "can hide a test gap" and tells the reader to check with `--test-command` first. Probe P3 is in the pull request body. |
| The Rails dogfood gives a tested count other than 0. | Stop and explain it first (U3, step 5). |
| #244 (group 20-D) changes `job_plan.rb` and `reporter.rb` after this group. | 20-D adapts (20-M, "20-B: #322"). The R13 check and the tests of U1 fail if it drops the mark. |

## Open Questions

- Q1. Does David want a verdict path before 2.0 ships (D7)? The run takes `backlog`.
- Q2. Did 20-A keep schema `"2.0"`? The builder reads the constant (KTD5).
- Q3. The hidden-survivor rate on a real app is not measured. The count is 0 on the Fizzy sample today, so the sample cannot give a rate. F1 holds the question.

## Limits left open

Each limit has a follow-up issue that the builder files in U3, step 1. Both get the labels shown. (#588, #589)

**F1 (filed as #588). `ran_at_load` mutants have no verdict in the run that finds them.** Labels: `enhancement`, `priority: medium`, `risk: medium`, `backlog`.

- **What:** a coverage-guided run cannot give a verdict to a `ran_at_load` mutant. Since #322 the report marks the ones that survived their tests (`ran_at_load[].tested`, `summary.ran_at_load_tested`) and counts all of them in the unrun share. To get a verdict, the user starts a second run by hand: `--test-command` for the file, or with `--only` for one method.
- **Why:** such a mutant can be a real test gap. On the fixtures of `test/fixtures/load_time/`, 1 of 10 tested mutants survives in a fresh process and 9 are killed. Cases that end here with `tested: true`: a block that no test runs, a branch of a stored block that no test takes, the right side of `&&` or `||` that no test reaches, an expression that raises into a `rescue` in each test, and an `each` call on a `define_method` line.
- **How:** options, none chosen. (1) A flag that runs only the `ran_at_load` mutants again in a fresh process, with a test command from the user. It must say how the two backends share one score. (2) Wait for full reload (#389) and measure which `ran_at_load` mutants it gives a verdict. (3) Fail `--baseline` when `summary.ran_at_load_tested` rises. Measure first: the share of `ran_at_load` on a real app after #493, and how many tested mutants survive there.

**F2 (filed as #589). Two false survivors that the `ran_at_load` rule does not catch.** Labels: `bug`, `priority: low`, `risk: high`, `backlog`.

- **What:** (1) Code that runs only sometimes, in a statement that ran at load (`base *= 2 if double`), is never `ran_at_load` (`JobPlan.ran_at_load?`, `StatementLines`). When the tests check only the value that the load computed, its mutant is a false `survived`. (2) A test can run a new copy of a stored block and check the result of the old copy. The reach probe counts, so the mutant stays `survived`.
- **Why:** a false survivor lowers the score and sends a user to write a test that exists. Probe: class `Cond` in this plan (P4). `--strategy redefine` gives `survived` and a score of 0.0, and `--test-command` gives `killed`. No user report exists. Estimate: rare. It needs a method that the app calls at load, conditional code in it, and tests that check only the loaded value.
- **How:** case 1 needs a way to know that the branch ran at load (branch coverage of the load, or the reach probe during the load). Case 2 is the reload of the caller's class body: #389.

Not a limit of this plan, and not filed:

- `rake/fizzy_sample.json` does not record `ran_at_load_tested`. The next `fizzy:record` adds it.
- The four limits of the block rule in #507 keep their issue.

## Sources

- Issue #286 with both comments (2026-10-24 and 2026-11-22). Pull request #322, head `cecfb76c`: no review comments and no reviews. Pull request #314 and its branch. Issues #283, #343, #389 and #507. Pull request #215.
- `plans/20-M-merge-order-plan.md` in the run folder: the section "20-B: #322", the #322 merge steps, and Decisions 8, 10 and 11.
- Code read on `origin/main` at `c5100143`: `lib/mutineer/job_plan.rb` (`coverage_selection`, `selection_verdict`, `ran_at_load?`, `stored_block_candidate?`, `stored_block_verdict`, `load_verdict`), `lib/mutineer/runner.rb` (`Runner.run`), `lib/mutineer/daemon_backend.rb` (`job_result`), `lib/mutineer/result.rb`, `lib/mutineer/reporter.rb` (`json_report`, `summary_html`, `summary`, `warn_unrun_share`, `unrun_share_exceeded?`, `unrun_for_share`, `mutant_with_diff_json`), `rake/fizzy_sample.rb`.
- Code read on `origin/fix/283-286-baseline-unverified-survivors`: `lib/mutineer/baseline.rb` (`Baseline#diff`, `DECIDED`), `test/baseline_test.rb`.
- Rules: `AGENTS.md` ("Score-model discipline", "Fix it in the pull request, or file an issue?"), `.expectation-fit/ways-of-working.yaml` ("Count what you exclude", "Cover the siblings", "Track every limitation", "Estimate exclusion frequency", "Assert the mechanism"), `.expectation-fit/decisions/scoring-and-verdicts.md`, `.expectation-fit/decisions/json-schema-and-baseline.md`. (#286)
- Source freshness: every source above is current (checked on 2026-11-24). The full Fizzy run of 2026-11-09 is current but older than #493.
- Probes P1 to P11: scratch worktrees of `origin/main` and of the #322 branch, created and removed by the planner on 2026-11-24.

## Second opinion and plan validation

- **Codex:** `codex exec`, model `gpt-6.2-sol` (the first model in Codex's own priority list), read-only, on 2026-11-24. It agreed with KTD1, KTD2 and KTD6. It gave 9 findings, and all 9 are applied:
  1. A `survived` result does not prove that each selected test ran and passed. The meaning of `tested` in KTD2 now says "scored `survived`, then moved".
  2. Cheaper verdict paths exist for parts of the set. KTD1, the docs of U1 and F1 name them (probe P11 checked `--only` with `--test-command`).
  3. The CLI test of AE5 named a `bin/mutineer` that is not in the fixture folder. U3 gives the full call.
  4. The lead of the warning now says "classed as ran at load", and the `attempted` docs change in U1.
  5. The goal says which report lists the mutants.
  6. AE7 tests exactly 10%, and U2 has a `--fail-fast` case.
  7. `docs/rails-setup.md` is in the citation table, and the grep check expects three hits.
  8. Probe P5 says which Fizzy run has the block rule.
  9. The baseline lookup by `id` names the id format.
- **`/fit-validate-plan`:** four lenses, on 2026-11-24. Report: `reports/20-B-fit-validate-plan.md` in the run folder. Verdict before the fixes: "Revise first", for one P1: this plan and 20-M named two methods for the branch of #322. KTD4 now names one. The other findings (11, P2 and P3) are applied or answered in that report.

## Verdict

**Go, after #314 is merged into `integration/v2.0`.** The design is settled, each choice has one option taken, the probes reproduce each claim, and the change is about 45 lines of library code with no effect on the score or an exit code. If #314 is not in the branch, 20-B waits and 20-C can go first (20-M, Decision 11).
