---
title: Baseline completeness for 2.0 (update of pull request #314, then the four limits in #343) - Plan
type: fix
date: 2026-11-24
issues: [283, 343]
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Baseline completeness for 2.0 (update of pull request #314, then the four limits in #343) - Plan

> **As built:** the run orchestrator put all five units on pull request #314 (one pull request for the group), not on two. U1 is the merge commit plus one test commit; U2 to U5 follow as one commit each.

**Verdict: go.** Both parts can be built from this plan. A trial update of #314 passes the suite, and all four #343 limits are reproduced.

Group 20-A of the mutineer 2.0 run. Planner: Fable 5.2, effort `high`. Builder: Opus 5.5, effort `medium`.
Base branch: `integration/v2.0` (`d31f709c` when this plan was written: `main` at `c5100143` plus one commit that changes only `.github/workflows/ci.yml` and `AGENTS.md`).

## Goal Capsule

- **Issues:** #283 (`--baseline` has no completeness gate) and #343 (four limits that pull request #314 leaves).
- **Goal:** `integration/v2.0` holds pull request #314, updated to the current code. A second pull request then closes the four limits in #343.
- **Two pull requests, five units:**
  - Pull request #314 (exists, branch `fix/283-286-baseline-unverified-survivors`): unit U1. `Closes #283`.
  - A new pull request (branch `fix/343-baseline-limits`): units U2 to U5, one commit each. `Closes #343` when all four land. `Refs #343` when one is dropped.
- **Order:** U1 merges first. U2 to U5 start from the `origin/integration/v2.0` that holds U1.
- **Authority:** `AGENTS.md`, then `RULES.md` in the run folder, then this plan, then `plans/20-M-merge-order-plan.md`.
- **Do not build when:** `integration/v2.0` already holds the contract flip (pull request #244). Check with `git grep -n "def self.exit_for" origin/integration/v2.0 -- lib/mutineer/cli.rb`. A match means the flip merged first. Return `blocked: #244 merged before #314`. The update is then a different job (see "Risks").
- **Size:** U1 is one merge with 30 conflict hunks in 17 files, plus one test commit. U2 to U5 are small: about 15 to 40 changed lines of `lib/` or `action.yml` each, plus tests and docs.

---

## Product Contract

### Summary

Pull request #314 makes `--baseline` fail an incomplete run and stops listing an undecided stored survivor as fixed.
It was written against `main` from 2026-10-25. `main` has 257 commits and releases 1.8.0 to 1.10.0 since then.
U1 brings the branch up to date and keeps both behaviours.

#343 lists four limits of #314. Each one is real today (see "Reproduction").
U2 makes the score-drop check exact. U3 names a stored path from another machine. U4 adds the baseline section to the HTML report. U5 makes the Action refuse an old gem when it cannot check completeness.

### Problem Frame

- **#314 is stale, not wrong.** A trial merge into `main` conflicts in 17 files. With the conflicts fixed as "The trial" describes, the suite passes except two doc guards that wait for the doc updates.
- **Three merge errors pass the suite.** A "keep both" fix of the CHANGELOG conflicts leaves #314's entries inside the released section `## [1.8.0]`. Five assertions in `test/action_harness_test.rb` merge with no marker and then read the output of the wrong harness cases. Four doc pages that are new on `main` keep the old `--baseline` contract, with no marker. No test finds the first and the third.
- **The four limits give wrong or missing output:**
  - The score-drop check compares scores rounded to one decimal. It misses a real drop, and it reports a drop that is inside `--baseline-epsilon`. Both change the exit code with no message.
  - A stored survivor with a path outside the project stays `not_run` on every run. That label says the run skipped it. It did not.
  - `--format html --baseline` exits 1 on a regression and the report does not say why. The word "baseline" is not in the file.
  - The Action checks `baseline.incomplete` only in a JSON report. With `format: html` or `human` and a gem older than 2.0, a broken baseline run passes with no warning.

### Reproduction

Every probe ran in a scratch worktree on 2026-11-24. The worktrees are removed.

| What | Where | Result |
|---|---|---|
| Trial update of #314 | `git merge origin/fix/283-286-baseline-unverified-survivors` into `origin/main` (`c5100143`), conflicts in `lib/` and `test/` fixed, docs left as on `main` | `bundle exec rake test`: 2531 runs, 2 failures, 0 errors, 5 skips, 1419 s. The 2 failures are the doc guards `DocsContractTest#test_stability_names_the_reporter_schema_version` and `#test_json_schema_page_and_source_name_the_reporter_schema_version` (the docs still said `1.11`). Load check passes. `rake yard:strict` is 100%. |
| A stored survivor in a source that pairing now drops (#381) | The trial tree, a project with two sources, the test of one deleted | `fixed=[]`, `unverified=[["lib/other.rb", "not_run"]]`, exit 0. Correct. U1 adds a test for it. |
| A stored survivor whose id is now a dropped repeat (#329, #374) | `Baseline#diff` on `main` and on #314's head: stored ids `kept` and `copy`, the run has `kept` as a survivor | `fixed=["copy"]` on both. Wrong, and older than #314. See "Limits left open", L1. |
| #343 limit 1, foreign stored path | #314's head, a real project. The baseline survivor's `file` is `/home/runner/work/app/app/lib/calc.rb`, then the method is removed | With the project-relative path: `fixed=1`. With the foreign path: `fixed=0`, `unverified=[[..., "not_run"]]`, on every later run. |
| #343 limit 2, Action and format | #314's head, the Action harness with a stub gem that omits `baseline.incomplete` and exits 0 | `format: json`: exit 2 with the upgrade error. `format: html` and `format: human`: exit 0, 0 errors, 0 warnings. |
| #343 limit 3, rounded scores | `Baseline#diff` on `main`. Case A: baseline 9990 killed and 10 survived, run 9980 killed and the same 10 survivors, epsilon 0. Case B: baseline 9066 and 1000, run 9050 and the same 1000, epsilon 0.05 | A: exact 99.9000 to 99.8999, both display 99.9, `score_drop=false` (a missed drop, exit 0). B: exact 90.0656 to 90.0498 is a drop of 0.016, inside epsilon, but the display is 90.1 to 90.0, so `score_drop=true` (a false drop, exit 1). |
| #343 limit 4, HTML | `main` and #314's head: a run with one new survivor, `--baseline`, `--format html` | Exit 1. The HTML holds 0 lines with "baseline", "REGRESSION" or "new survivor". The human format prints `REGRESSION vs baseline`. |

Two facts about limit 1 that correct the issue text:

- The current CLI stores a project-relative `file` even when the source is given as an absolute path (`mutineer run "$PWD/lib/calc.rb"` stores `lib/calc.rb`; checked on #314's head and on 1.7.0).
- Gem 1.3.0 stored the path as given (the same command stores the absolute path). I did not find the release between 1.3.0 and 1.7.0 that changed it.

### Requirements

**U1, the update of #314**

- R1. Everything in "Must keep" for 20-A in `plans/20-M-merge-order-plan.md` holds. The main points: the completeness rule lives on `AggregateResult`; `Baseline#diff` keeps `partial:`, `sources:`, `operators:`, `not_run`, `unverified_survivors`, `incomplete` and the old-id matching; `--baseline` exits 1 on a regression or an incomplete run; `Reporter::SCHEMA_VERSION` is `"2.0"`; the Action exits 2 for a JSON report with a baseline object and no boolean `baseline.incomplete`.
- R2. Everything `main` added to the same files stays: the unrun-share warning, the unpaired counts, redaction, the `dropped` count, schema keys up to `1.11`, and every harness case `main` added.
- R3. The CHANGELOG entries of #314 sit under `## [Unreleased]` and are marked breaking.
- R4. Every doc copy of the `--baseline` contract says the same thing, also the four pages that are new on `main`.
- R5. A stored survivor in a source that pairing drops is `not_run`, proved by a test.

**U2, exact score drop (#343 limit 3)**

- R6. `Baseline#diff` decides `score_drop` from the exact counts: the run's `killed` and `survived`, and the stored report's `summary.killed` and `summary.survived`. `--baseline-epsilon` is read as the decimal it prints as.
- R7. A stored report with no integer counts keeps today's comparison of the two rounded scores.
- R8. `score_before` and `score_after` stay the rounded display values. When a drop is reported and the two display values are equal, the human report and the Action summary say so in words.

**U3, foreign stored path (#343 limit 1)**

- R9. An absent stored survivor gets the status `foreign_path`, not `not_run`, when the only reason it cannot be checked is its path: the path is absolute, outside the project root, and no file exists there on this machine. The run is full (not `--only`, not `--fail-fast`), has results, and the stored operator is selected.
- R10. Every other outcome keeps its current answer: a matching kill or ignore is fixed, a selected outside-root source that no longer has the mutant is fixed, an existing unselected file is `not_run`, a partial or empty run is `not_run`.
- R11. `foreign_path` never gates and adds nothing to any count. The human report says what to do: write a new baseline from this checkout.

**U4, HTML baseline section (#343 limit 4)**

- R12. `--format html` with `--baseline` shows a "Baseline comparison" section with the same lines as the human report, including the last verdict line.
- R13. Without `--baseline` the HTML report does not change by one byte.

**U5, the Action and non-JSON formats (#343 limit 2)**

- R14. With a baseline in use and `format` not `json`, the Action exits 2 before the run when the gem is older than 2.0.0. A 2.0.0 prerelease passes.
- R15. `format: json` keeps the report check from #314 and gets no version check. A run with no baseline gets no version check.

### Acceptance Examples

- AE1 (U1). On the updated branch, `bundle exec rake test` is green, with 0 failures in `test/docs_contract_test.rb` and `test/action_harness_test.rb`.
- AE2 (U1). `CHANGELOG.md`: the text "fails an incomplete run" is above the line `## [1.10.0] - 2026-11-24`.
- AE3 (U1). Two sources, a baseline with one survivor in each, then the test of one source is deleted. `mutineer run lib --baseline base.json --format json` reports `fixed_survivors: []` and one `unverified_survivors` entry with status `not_run`.
- AE4 (U2). Baseline 9990 killed and 10 survived. Run: 9980 killed and the same 10 survivors. Then `score_drop` is true and `regressed` is true. The human report reads `score dropped 99.9% -> 99.9% (less than the rounding shows; the check uses the exact counts)`.
- AE5 (U2). Baseline 9066 killed and 1000 survived. Run: 9050 killed and the same 1000 survivors, epsilon 0.05. Then `score_drop` is false and `regressed` is false.
- AE6 (U3). A stored survivor with `file` `/home/runner/work/app/app/lib/a.rb`, absent from a full run of 20 kills with `sources: ["lib/a.rb"]`. Then `fixed_survivors` is empty and the entry has status `foreign_path`.
- AE7 (U4). The run of AE4 with `--format html` holds `<h2>Baseline comparison</h2>` and the text `REGRESSION vs baseline`.
- AE8 (U5). The harness, `FORMAT=html`, a baseline, and a stub gem at 1.0.0: exit 2, the stub never ran, and the error names 2.0.0. The same with the stub at `2.0.0.rc1`: the run starts.

### Scope Boundaries

- No change to the score, the denominator, the `no_verdict` set, or the `--threshold` exit code.
- `unverified_survivors` stays informational. It does not gate.
- No new JSON key in U2 to U5. U3 adds one value (`foreign_path`) to `baseline.unverified_survivors[].status`. The schema stays `2.0`, which is not released.
- No change to `lib/mutineer/version.rb` (`RULES.md`, rule 13).
- Exit 3 is not part of this group. Pull request #244 (group 20-D) changes an incomplete `--baseline` run from exit 1 to exit 3 (20-M, Decision 6).
- The fresh-process run for `ran_at_load` mutants stays on #286 (group 20-B).

### Corrections to the issues

- **#343, limit 1, the estimate.** The issue says the limit "hits every survivor in a baseline that was copied between machines with different checkout paths". That is too wide. A stored path is absolute only when the source was outside the project root, when the baseline was written by an old gem with absolute source arguments (1.3.0 does this, 1.7.0 does not), or when someone edited the file. The builder corrects the estimate in a comment on #343.
- **#343, limit 3, direction.** The issue names only the missed drop. The rounded check also reports a false drop when `--baseline-epsilon` is set (case B). That one fails a healthy run.
- **#343, limit 4, origin.** The HTML report has had no baseline section since `--baseline` exists. #314 did not cause it. #314 only adds one more reason to exit 1 that the HTML does not show.
- **#283, the comment.** Its line numbers are for 1.7.0. Find each function by name.
- **Pull request #314, the body.** "Release decision needed" is decided: the change ships in 2.0 (David, 2026-10-25). "Merged `origin/main` up to `03192afa`" is out of date. U1 rewrites the body.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Update #314 with one merge of `origin/integration/v2.0`, not a rebase.** The branch holds 3 merge commits from `main`. A rebase drops them and replays the 12 other commits, so the same conflicts come back several times. One merge gives one round of conflicts, needs no force-push, and keeps the review threads on their lines. The pull request is squash-merged, so `integration/v2.0` gets the same result. This matches 20-M, Decision 2.
- KTD2. **In every conflicted `lib/` file, start from the `integration/v2.0` side and add #314's change.** The #314 side is a month old. "U1" gives the resolved text for each hunk of `lib/mutineer/reporter.rb`. The builder does not improvise there.
- KTD3. **The trial patch is the reference.** `plans/20-A-trial-lib-test.patch` in the run folder is `git diff origin/main -- lib test action.yml` on the trial tree that passed the suite. After the builder's own merge, the same diff against `origin/integration/v2.0` must match it, except for formatting, the R5 test, and any commit that reached the base later.
- KTD4. **Exit-code table: fix the source, then generate.** `docs/fragments/contract.yml` is the single source of the exit-code rows. Resolve it by hand, then run `bundle exec rake docs:generate`. Do not hand-merge the generated rows in `README.md`, `STABILITY.md`, `docs/index.md`, `docs/json-schema.md`, `docs/agentic-coding.md`, `docs/agentic-coding.html`, `skills/mutineer/SKILL.md` and `action.yml`: take the `integration/v2.0` side there and let the task write them.
- KTD5. **U2 compares rationals.** `Rational(killed * 100, killed + survived)` on both sides, and `epsilon.to_s.to_r` for the tolerance. `AggregateResult#meets_threshold?` reads `--threshold` the same way (#306), so both gates follow one rule ("Gate on unrounded values").
- KTD6. **U2 keeps the rounded comparison for a stored report with no counts.** Every report since 1.3.0 has `summary.killed` and `summary.survived` (checked on a 1.3.0 report). A hand-made report with only `summary.score` still loads today, and many unit tests build one. Skipping the check for them would weaken the gate with no message.
- KTD7. **U3 adds a status value, not a new list.** `baseline.unverified_survivors[].status` already carries the reason. `foreign_path` is one more reason. The schema is unreleased `2.0`, so the value costs no version bump now. After 2.0 ships it would cost a minor bump.
- KTD8. **U4 reuses the human lines inside `<pre>`.** `Reporter#baseline_section` already builds every line, with `printable` applied. The HTML section escapes the same text. One source of facts, so the two formats cannot drift. A table layout would need its own tests for each line kind.
- KTD9. **U5 uses the version floor the Action already has.** `action.yml` already checks `mutineer --version` with `Gem::Version` for its `since` handling. U5 adds a second floor of the same form. No new copy of a CLI rule is added: the baseline path comes from the block that pull request #395 wrote (`cli_setting baseline`, with its fallback for an old CLI).
- KTD10. **The floor is `2.0.0.a`, not `2.0.0`.** `Gem::Version.new("2.0.0.rc1") >= Gem::Version.new("2.0.0")` is false. #284 plans a release candidate. `2.0.0.a` sorts below every 2.0.0 prerelease and above every 1.x. As built: `2.0.0.A`, because an upper-case tag such as `2.0.0.RC1` sorts below `2.0.0.a`.

### Assumptions

- A1. `origin/integration/v2.0` is `main` at `c5100143` plus the CI commit, or later syncs from `main`. The builder runs the trial again on the real base first (`git merge --no-commit`). More conflicts than this plan lists mean the base moved: resolve them with KTD2 and say so in the report.
- A2. Pull request #244 is not merged yet. See "Do not build when".
- A3. `jq`, `bash` and `git` are on the builder's machine. Without them `test/action_harness_test.rb` skips and U1 and U5 are not verified. Check that the test ran.
- A4. The suite took 1419 s in the trial, on a busy machine. Plan the time.

### Places that expect fixed text

- `test/docs_contract_test.rb`: `STABILITY.md` and `docs/json-schema.md` must name `Reporter::SCHEMA_VERSION`. `rake docs:check` compares the generated rows.
- `test/action_harness_test.rb`: the exit code of every harness case by name, and the "baseline line" of some cases.
- `test/site_docs_test.rb`, `node --test test/site_test.js`, and the Playwright tests read the built site.
- Tests that pin the schema use `Mutineer::Reporter::SCHEMA_VERSION` on `main`. Keep that form. Do not bring back the literal `"2.0"` from #314's side.

---

## Implementation Units

### U1. Pull request #314: update the branch (#283)

**Worktree and branch.** A fresh worktree on the existing branch `fix/283-286-baseline-unverified-survivors`. Then `git merge origin/integration/v2.0`. One merge commit holds every conflict fix. The R5 test and the plan copy are a second commit.

**Conflicts (17 files, 30 hunks) and the rule for each.**

| File | Hunks | Rule |
|---|---|---|
| `lib/mutineer/reporter.rb` | 4 | The resolved text is below this table. |
| `test/baseline_test.rb`, `test/equivalent_mutant_test.rb` | 1 each | Take the `integration/v2.0` side: `assert_equal Mutineer::Reporter::SCHEMA_VERSION, doc["schema_version"]`. Update the trailing comment in `test/baseline_test.rb` to say `2.0`. |
| `test/cli_test.rb` | 2 | Same: take the `integration/v2.0` side. |
| `test/json_reporter_test.rb` | 1 | Take the `integration/v2.0` side (`render([killed_mutant, survivor])` and the constant). Update the comment. |
| `test/result_test.rb` | 1 | Keep both: `test_unrun_count` from `main`, then the four tests from #314. |
| `test/fixtures/action_harness.sh` | 1 | Keep both sides. `main` already uses the names `case18` to `case19e`. Rename #314's five cases `case18` to `case22` as `case20` to `case24`, also in their `== N:` titles and their `summary.md` paths. |
| `test/action_harness_test.rb` | 1 | Keep every pair from `main`, then add `"case20" => 1, "case21" => 1, "case22" => 1, "case23" => 2, "case24" => 0`. |
| `docs/fragments/contract.yml` | 1 | Start from the `integration/v2.0` side. In code `0`, add "and no incomplete run under an active `--threshold` or `--baseline` gate". In code `1`, add "(under `--threshold` or `--baseline`)" after the 10% clause. Keep `main`'s load-failure and `--since` wording. Then `rake docs:generate`. |
| `README.md` | 3 | Take the `integration/v2.0` side for all three hunks. `main` moved most README sections to `docs/cli.md` and `docs/ci.md`, and #314's side brings the old sections back (a second `--baseline FILE` row, the old CI recipe). Then edit the one `--baseline FILE` option row (item 4 below). |
| `STABILITY.md` (3), `docs/index.md` (1), `docs/agentic-coding.md` (1), `docs/agentic-coding.html` (1), `skills/mutineer/SKILL.md` (1) | 7 | For an exit-code row: take the `integration/v2.0` side, then `rake docs:generate` (KTD4). For any other hunk: keep `main`'s text and add #314's sentence about the incomplete run. In `STABILITY.md`, the schema row reads `schema_version` `2.0` and keeps `main`'s list of which release reports which 1.x version. |
| `docs/json-schema.md` | 4 | Keep every key and note `main` added up to `1.11`. Add #314's rows (`baseline.incomplete`, `baseline.unverified_survivors[]`, the changed `baseline.fixed_survivors[]` row) and its "Schema `2.0`" note at the top. The page names `2.0` as the current version. |
| `CHANGELOG.md` | 3 | See item 1 under "Edits that the conflict markers do not ask for". |

**`lib/mutineer/reporter.rb`, the four hunks.**

1. The requires. Keep both lines: `require_relative "redaction"` and `require_relative "result"`.
2. The constants at the top of `class Reporter`. The result, in this order:
   - `SCHEMA_VERSION = "2.0"` with its comment.
   - `BROKEN_SHARE_LIMIT = AggregateResult::BROKEN_SHARE_LIMIT` and `BROKEN_FLOOR = AggregateResult::BROKEN_FLOOR`, each with #314's "Compatibility name" comment.
   - `UNRUN_SHARE_LIMIT = 0.10` and `UNPAIRED_SHARE_HINT` from `main`, with `main`'s comments unchanged.
   - Do not keep `main`'s literal `BROKEN_SHARE_LIMIT = 0.10`, `BROKEN_FLOOR = 1` or `SCHEMA_VERSION = "1.11"`.
3. In `Reporter#report`, after the report is written:

   ```ruby
   warn_unrun_share(err)
   # --baseline gates on completeness on its own (#283); --threshold always does.
   gates = []
   gates << "--threshold" if threshold&.positive?
   gates << "--baseline" if baseline&.incomplete
   return warn_errors_without_gate(err) if gates.empty?
   ```

   `warn_unrun_share(err)` stays first, as on `main`: it prints for every run.
4. The private block. Delete `Reporter#broken_nil_score?`, `#broken_share_exceeded?`, `#no_verdict_count` and `#attempted_count` (they live on `AggregateResult` now). Keep everything else from the `integration/v2.0` side: `unrun_share_exceeded?`, `unrun_for_share`, `unpaired_in_share?`, `unpaired_mutant_count`, `unpaired_sources_json`, `unpaired_line`, `unpaired_scope_share`, `unpaired_html`.

**Edits that the conflict markers do not ask for.** Each of these is wrong until edited. Items 2 to 4 have no marker at all.

1. **`CHANGELOG.md`.** #314 wrote its entries under the heading that was `## [Unreleased]` in October. Those lines are now inside `## [1.8.0]`, and that is where the three conflict hunks put #314's side. Take the `integration/v2.0` side for all three hunks. Then add #314's entries under `## [Unreleased]` at the top (it is empty on the base). The entries are the 49 added lines of `git diff $(git merge-base origin/main HEAD^1) HEAD^1 -- CHANGELOG.md`, run after the merge commit (`HEAD^1` is the old branch head `6597cd8a`). Keep the subheads #314 used. Start the first entry with `**Breaking:**`. Check: `git diff origin/integration/v2.0 -- CHANGELOG.md` shows added lines only above `## [1.10.0] - 2026-11-24`.
2. **`test/action_harness_test.rb`, the "baseline line" assertions.** Five lines read `out[/case18 baseline line: .*/]` to `out[/case21 baseline line: .*/]`. After the rename they must read `case20` to `case23`: the `incomplete` variable (`case20`), "regressed+incomplete" (`case21`), "nil-score incomplete" (`case22`), "completeness unavailable" (`case23`). Without this edit they read `main`'s cache-directory cases.
3. **Two bare calls in `lib/mutineer/reporter.rb`.** `main`'s `warn_unrun_share` has `tried = attempted_count + unrun`, and `unrun_share_exceeded?` has `UNRUN_SHARE_LIMIT * (attempted_count + unrun)`. Change both to `@agg.attempted_count`. Without it the first run with unplaceable mutants raises `NameError`. Check: `grep -nE "(^|[^.a-z_@])(attempted_count|no_verdict_count|broken_nil_score\?|broken_share_exceeded\?)" lib/mutineer/reporter.rb` prints nothing.
4. **Four doc pages that are new on `main`, and one README row.** Each states the `--baseline` contract without the incomplete run. Find each sentence by its text and add the incomplete run:
   - `README.md`: the option row "`--baseline FILE` | Exit 1 for new survivors, or score drops on full runs".
   - `docs/cli.md`: the same option row.
   - `docs/ci.md`: the table row "`--baseline FILE` compares a saved JSON report and fails on new survivors", and the command comment "exit 1 on NEW survivors or a score drop".
   - `docs/comparison.md`: the row "with `baseline:` set, fails on new survivors".
   - `docs/getting-started.md`: "With `baseline:` set, only new survivors fail."
   `docs/agentic-coding.md` merges with #314's wording ("or if the run is incomplete"): check that the sentence is there.
   Then run `git grep -n -i "baseline" -- README.md docs/*.md STABILITY.md skills/mutineer/SKILL.md action.yml | grep -i -E "exit|fail"` and read every hit once.
5. **`STABILITY.md`, the list of 2.0 changes.** Add one entry in the voice of the list: "**`--baseline` fails an incomplete run.** Documented only. In 1.x a `--baseline` run with no `--threshold` exits 0 when most mutants errored. In 2.0 it exits 1." Do not write exit 3 here. Pull request #244 owns that change.
6. **`lib/mutineer/cli.rb`.** Read the merged `CLI.execute`: the `Baseline.load(...).diff(...)` call keeps `partial:`, `sources:`, `operators:`, `id_map:` and `project_root:`, and the exit line reads `baseline_exit = delta && (delta.regressed || delta.incomplete) ? 1 : 0`. The `--baseline` help text holds "or when the run is incomplete".
7. **`.expectation-fit/decisions/json-schema-and-baseline.md`.** Add one line by hand, as that folder's README says: "**Fixed Means Decided.** A stored survivor is in `baseline.fixed_survivors` only when this run killed or ignored it, or when a full run inside the selected sources and operators no longer has it. Any other current result puts it in `baseline.unverified_survivors` with its status. (#283)". Update "Skip Scoped Baseline Score Drops" only if its text now disagrees.

**New test (second commit).** `test/cli_test.rb`, next to `test_narrower_sources_keep_existing_file_survivors_unverified_but_removed_files_fixed`, in the same style:

- `test_baseline_survivor_in_an_unpaired_source_is_not_run_not_fixed`: two sources with one survivor each and a test for each; write the baseline with `mutineer run lib --format json`; delete one test file; run `mutineer run lib --baseline base.json --format json`. Assert `summary.unpaired_sources` is 1, `baseline.fixed_survivors` is empty, and `baseline.unverified_survivors` has one entry whose `file` is the unpaired source and whose `status` is `not_run`. This asserts the mechanism (the status and the file), not only the exit code.

**Pull request.**

- Keep pull request #314. Base `integration/v2.0` (already set).
- Rewrite the body in What, Why, How form. Remove "Release decision needed" and "Integration with main (head `6597cd8a`)". Add "Decisions for David" with D1, D2 and D3 from this plan. `Closes #283`. Name #343 as the follow-up that the next pull request closes.
- Labels: it has `bug`, `v2.0`, `breaking change`. Add `priority: medium` and `risk: high` (the labels of #283).
- Copy this plan to `docs/plans/2026-11-24-283-343-fix-baseline-completeness-plan.md`. The old plan `docs/plans/2026-10-24-283-286-fix-baseline-unverified-survivors-plan.md` stays in the diff as #314 added it. Add one line at its top: "Updated by `docs/plans/2026-11-24-283-343-fix-baseline-completeness-plan.md`."
- File the issue for L1 ("Limits left open") before the pull request is ready, and name its number in the body.

**Tests to run again for U1.** The full local gate, `bundle exec rake docs:generate` then `bundle exec rake docs:check`, the website checks, and the mutation slice. See "Verification Contract".

### U2. #343 limit 3: the score-drop check compares exact counts

**Files.** `lib/mutineer/baseline.rb`, `lib/mutineer/reporter.rb`, `action.yml`, `test/baseline_test.rb`, `test/fixtures/action_harness.sh`, `test/action_harness_test.rb`, `docs/json-schema.md`, `CHANGELOG.md`.

**Code.**

1. `Baseline#initialize`: also read `@killed = doc.dig("summary", "killed")` and `@survived = doc.dig("summary", "survived")`.
2. `Baseline#diff`: replace `score_drop = comparable && current_score < @score - epsilon` with `score_drop = comparable && score_dropped?(aggregate, epsilon)`.
3. A new private method, with YARD docs:

   ```ruby
   def score_dropped?(aggregate, epsilon)
     counts = [@killed, @survived]
     exact = counts.all? { |n| n.is_a?(Integer) && !n.negative? } && counts.sum.positive?
     # A stored report with no counts (hand-made): the rounded scores, as before.
     return aggregate.mutation_score < @score - epsilon unless exact

     before = Rational(@killed * 100, @killed + @survived)
     after = Rational(aggregate.killed_count * 100, aggregate.covered_count)
     after < before - epsilon.to_s.to_r
   end
   ```

   `comparable` already means that both scores exist, so `aggregate.covered_count` is positive here.
4. `Reporter#baseline_section`: the line `score dropped X% -> Y%` gets the suffix ` (less than the rounding shows; the check uses the exact counts)` when `delta.score_before == delta.score_after`. No other line changes.
5. `action.yml`, the jq line that prints "; score X -> Y": when `.baseline.score_dropped` is true and the two scores are equal, append the same words in parentheses. This reads the JSON report, which the shell rule allows.
6. Update the doc comment of `Delta` (`score_drop`) and of `Baseline#diff`.

**Tests (`test/baseline_test.rb`).** Each of the first two fails before the change.

- `test_a_drop_smaller_than_the_rounding_is_a_score_drop`: AE4. Assert `score_drop`, `regressed`, and that `new_survivors` is empty (the drop is the only cause).
- `test_a_drop_inside_epsilon_is_not_a_score_drop_when_the_rounded_scores_differ_more`: AE5. Assert `score_drop` is false and `regressed` is false.
- `test_score_drop_matches_the_exact_rule_for_many_counts`: the rule, not one example. Loop over stored `(killed, survived)` and run `killed` values (for example `survived` in `[1, 7, 10, 333, 1000]`, each `killed` in a spread of 30 values, and epsilon in `[0.0, 0.05, 0.1, 1.0]`). For each, assert that `score_drop` equals `Rational(k * 100, k + s) < Rational(K * 100, K + s) - eps.to_s.to_r`. Keep the survivor ids equal on both sides so no new survivor appears.
- `test_equal_ratios_with_different_counts_are_not_a_drop`: 1 of 3 killed against 2 of 6 killed.
- `test_a_baseline_with_no_counts_compares_the_rounded_scores`: a stored doc with only `summary.score`; the result equals today's.
- `test_human_report_explains_a_drop_that_the_rounded_scores_do_not_show`: the suffix is present for AE4 and absent for a drop of 90.0 to 88.9.
- Harness: one case with `score_dropped: true` and equal `score_before` and `score_after`. Assert the words on its baseline line, and assert that the baseline line of `case1` does not have them.

**Docs.** `docs/json-schema.md`, the `score_dropped` row: "True when the exact score fell by more than epsilon. The exact score is `killed / (killed + survived)` from the counts of both reports. `score_before` and `score_after` are rounded to one decimal, so `score_dropped` can be true when they are equal. A stored report with no integer `summary.killed` and `summary.survived` is compared on its rounded `summary.score`." Add the change to the "Schema `2.0`" note. `CHANGELOG.md` under `### Fixed`: say that an exit code can change in both directions, with AE4 and AE5 as the examples.

### U3. #343 limit 1: an absent survivor with a path from another machine is `foreign_path`

**Files.** `lib/mutineer/baseline.rb`, `lib/mutineer/reporter.rb`, `test/baseline_test.rb`, `docs/json-schema.md`, `CHANGELOG.md`.

**Code.** In `Baseline#diff`, the `elsif unscoped` branch today decides between `fixed` and `"not_run"` with `outside_selection?`. Replace that predicate with one method that returns the status, or nil for "fixed":

```ruby
# nil when the absent survivor counts as fixed; else the status it gets.
def absent_status(stored, sources, operators, project_root)
  path = stored["file"]
  key = path && ProjectPath.relative(path, ProjectPath.root_real(project_root))
  foreign = key && File.absolute_path?(key)
  # A source file removed from this checkout is a fix whatever was selected.
  return if key && !foreign && !File.exist?(ProjectPath.absolute(path, project_root))
  return "not_run" if operators && !operators.include?(stored["operator"].to_s)
  return unless sources
  return if key && sources.include?(key)
  # Outside the project and not on this machine: the run cannot check it.
  foreign && !File.exist?(key) ? "foreign_path" : "not_run"
end
```

The caller:

```ruby
elsif unscoped
  status = if stored_match(fixed_index, h, foreign, file_key) then nil
           elsif partial || aggregate.total.zero? then "not_run"
           else absent_status(h, source_keys, operator_names, project_root)
           end
  status ? unverified << h.merge("status" => status) : fixed << h
end
```

Every line except the last line of `absent_status` gives the same answer as `outside_selection?` today. Delete `outside_selection?`. Keep `foreign_file?`: the old-id matching still calls it.

`Reporter#unverified_lines`: after the list, when at least one entry has the status `foreign_path`, print one line: `  foreign_path: the stored path is outside this project, so this run cannot check it. Write a new baseline from this checkout.`

**Tests (`test/baseline_test.rb`).** The first fails before the change (the status is `not_run`).

- `test_an_absent_survivor_with_a_path_from_another_machine_is_foreign_path`: AE6.
- `test_a_killed_survivor_with_a_foreign_path_is_still_fixed`: the id matches a killed result.
- `test_a_selected_source_outside_the_project_counts_as_fixed`: a real temp file outside the root, listed in `sources`, with no result for the id.
- `test_an_existing_unselected_file_outside_the_project_is_not_run`: a real temp file outside the root, not in `sources`.
- `test_a_foreign_path_in_a_partial_or_empty_run_is_not_run`: `partial: true`, then an empty aggregate.
- `test_a_foreign_path_with_an_unselected_operator_is_not_run`.
- `test_direct_callers_without_selections_keep_their_answer`: `sources: nil` and `operators: nil` with a foreign path gives `fixed`, as today (the probe confirmed it).
- `test_human_report_explains_foreign_path`: the hint line is present once, and absent when no entry is `foreign_path`.
- Keep `test_selected_sources_and_operators_only_limit_absent_survivors` and `test_missing_file_metadata_keeps_an_absent_survivor_unverified_and_a_known_kill_fixed` green with no edit. They pin the unchanged branches.

**Docs.** `docs/json-schema.md`, the `unverified_survivors[]` row: add `foreign_path` to the status values with its meaning and the action ("write a new baseline from this checkout"). Remove the sentence "A foreign stored path whose removal cannot be checked uses the same label." State how often: "Only a stored path outside the project root, which the current CLI writes only for a source outside the root." `CHANGELOG.md` under `### Changed`. A comment on #343 with the corrected estimate.

### U4. #343 limit 4: the HTML report shows the baseline comparison

**Files.** `lib/mutineer/reporter.rb`, `test/html_reporter_test.rb`, `test/cli_test.rb`, `docs/json-schema.md` or `docs/cli.md` (the `--format` text), `CHANGELOG.md`.

**Code.**

1. Split `Reporter#baseline_section(out, delta)`: the three heading lines stay in it, and the rest moves to a new private `baseline_lines(out, delta)`. `baseline_section` calls it. The human output does not change.
2. `Reporter#report`: pass the delta, `html_report(baseline: baseline, declined: ..., ...)`.
3. `html_report(baseline: nil, ...)`: add `#{baseline_html(baseline)}` on its own line after `#{summary_html(...)}`. The verdict then sits near the top.
4. A new private method, with YARD docs:

   ```ruby
   def baseline_html(delta)
     return "" unless delta

     text = StringIO.new
     baseline_lines(text, delta)
     "<h2>Baseline comparison</h2>\n<pre class=\"baseline\">#{esc(text.string)}</pre>"
   end
   ```

5. CSS: change the selector `pre.diff {` to `pre.diff, pre.baseline {`. No new rule.

R13 needs care: with no delta the template line must add no blank line. Follow what `unpaired_html` and `matrix_html` do when they return `""`, and let the R13 test decide.

**Tests (`test/html_reporter_test.rb`, plus one in `test/cli_test.rb`).**

- `test_baseline_section_shows_a_regression_and_names_the_new_survivor`: the heading, `REGRESSION vs baseline`, and the `+ Subject (file:line) operator` line.
- `test_baseline_section_shows_an_incomplete_run_and_the_unverified_survivors`: `INCOMPLETE vs baseline`, the `incomplete run:` line and one `? ... [error]` line.
- `test_baseline_section_holds_the_same_lines_as_the_human_report`: unescape the text inside `<pre class="baseline">` and compare it with the human section body for the same delta. This asserts the mechanism: one source for both.
- `test_baseline_section_is_html_escaped`: a subject name with `<` and `&`.
- `test_no_baseline_section_without_a_baseline`: the output for `baseline: nil` is byte-equal to the output of a call that does not pass the argument.
- `test/cli_test.rb`, `test_html_report_shows_the_baseline_verdict`: a real run with `--format html --baseline` and one new survivor. Assert exit 1 and that the file holds `REGRESSION vs baseline`.

**Docs.** One sentence where `--format html` is described: "With `--baseline`, the HTML report shows the baseline comparison." `docs/sample-report.html` shows a run with no baseline: do not change it. `CHANGELOG.md` under `### Added`.

### U5. #343 limit 2: the Action refuses an old gem when a baseline is used with a non-JSON format

**Files.** `action.yml`, `test/fixtures/action_harness.sh`, `test/action_harness_test.rb`, `docs/ci.md` (the Action text), `CHANGELOG.md`.

**Code (`action.yml`, the step "Run mutineer").**

1. Before the block that starts with the comment "A finished run copies its report onto `output`", add `baseline_path=""`.
2. That block resolves the baseline only when `output` is set. Change its guard `if [ -n "$OUTPUT" ]; then` to `if [ -n "$OUTPUT" ] || [ "$FORMAT" != "json" ]; then`. Change nothing inside the block. The same-file check after it keeps its own `[ -n "$OUTPUT" ]` guard.
3. After the existing floor for `since` (the `gem_ver=` lines), add:

   ```bash
   # #343: the --baseline completeness gate is in mutineer 2.0.0 and later.
   # The json format proves it from the report (baseline.incomplete, below).
   # The other formats cannot, so they need the gem floor. "2.0.0.A" is below
   # every 2.0.0 prerelease and above every 1.x release.
   if [ "$FORMAT" != "json" ] && [ -n "$baseline_path" ]; then
     gem_ver="$("${runner[@]}" --version 2>/dev/null || echo 0)"
     # Gem output goes into a workflow command: escape %, CR and LF.
     safe_ver="${gem_ver//%/%25}"; safe_ver="${safe_ver//$'\r'/%0D}"; safe_ver="${safe_ver//$'\n'/%0A}"
     if ! ruby -e 'exit(Gem::Version.correct?(ARGV[0]) && Gem::Version.new(ARGV[0]) >= Gem::Version.new("2.0.0.A") ? 0 : 1)' "$gem_ver" 2>/dev/null; then
       echo "::error::mutineer: resolved mutineer $safe_ver, but a baseline with a format other than json needs >= 2.0.0. An older gem passes an incomplete baseline run, and only the json report shows it. Upgrade the Gemfile pin or the version input, or set format: json."
       exit 2
     fi
   fi
   ```

   Do not print `$FORMAT` or the baseline path in the message. Both are user input, and a newline in a workflow command is an injection. The version is already printed by the `since` floor, escaped as `$safe_ver`.
4. The `baseline` input description: add "With a format other than json, the gem must be 2.0.0 or later (a 2.0.0 prerelease also passes; the action exits 2 for an older gem)." As built, `$gem_ver` is escaped as `$safe_ver` before it goes into the workflow command.

**Harness (`test/fixtures/action_harness.sh`).** The stub prints `1.0.0` for `--version`. Change that line to print `${STUB_VERSION:-1.0.0}` (escaped as `\${STUB_VERSION:-1.0.0}` inside the unquoted heredoc). Add cases after `case24`:

| Case | Inputs | Expect |
|---|---|---|
| `case25` | `FORMAT=html`, `BASELINE=<file>` | exit 2, `stub-args.txt` is empty, stdout names `2.0.0` |
| `case25b` | `FORMAT=human`, the baseline only in `.mutineer.yml` | exit 2, the stub never ran |
| `case25c` | `FORMAT=html`, `EXTRA_ARGS="--baseline=<file>"` | exit 2, the stub never ran |
| `case25d` | `FORMAT=html`, `BASELINE=<file>`, `STUB_VERSION=2.0.0`, `STUB_EXIT=1` | exit 1, the stub ran |
| `case25e` | as `case25d` with `STUB_VERSION=2.0.0.rc1`, `STUB_EXIT=0` | exit 0, the stub ran |
| `case25f` | `FORMAT=html`, no baseline anywhere | exit 0 with `STUB_EXIT=0`, the stub ran (no floor) |
| `case25g` | `FORMAT=json`, `BASELINE=<file>`, the default stub version, a report with `baseline.incomplete` | the stub ran (no floor for json) |

Add each exit code to the hash in `test/action_harness_test.rb`, and assert the `OK:` lines. Before adding cases, check that no existing case combines a non-JSON `FORMAT` with a baseline. On the base none does (`grep -n "FORMAT=" test/fixtures/action_harness.sh` shows only the default).

**Docs.** `docs/ci.md`, where the Action's `baseline` input is described: one sentence with the rule. `CHANGELOG.md` under `### Changed`, marked `**Breaking (Action):**`.

**Pull request for U2 to U5.**

- Branch `fix/343-baseline-limits`, from the `origin/integration/v2.0` that holds U1. Base `integration/v2.0`.
- Four commits in the order U2, U3, U4, U5. Each commit message names #343 and the limit.
- Body in What, Why, How form, with "Decisions for David" (D4 to D9) and "Limits left open" (L2 to L5). `Closes #343` when all four are in. When one is dropped, `Refs #343`, and tick the done items in the issue.
- Labels: `bug`, `v2.0`, `breaking change`, `priority: low`, `risk: medium`. `bug` because U2 fixes a wrong exit code. `breaking change` because U2 and U5 can change an exit code.
- A unit that is blocked is dropped, not held (`RULES.md`, builder rule 4). The units do not depend on each other in code. U4 only shows the wording of U2 and U3 when they are in.

---

## Verification Contract

Run from the worktree root. Use `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` in a shell where they are unset.

For both pull requests:

- `bundle exec rake test`: green. Check that `ActionHarnessTest#test_action_run_script_scenarios` ran and was not skipped.
- `ruby -Ilib -e 'require "mutineer"'`.
- `bundle exec rake yard:strict`: 100%. Every new method needs a docstring (`score_dropped?`, `absent_status`, `baseline_lines`, `baseline_html`).
- `bundle exec rake docs:generate`, then `bundle exec rake docs:check`, then `git status` shows no file that the task changed and that is not committed.
- The website checks from `AGENTS.md`: `bundle exec rake site:build`, `node --test test/site_test.js`, `npm ci --prefix test/browser`, `npx --prefix test/browser playwright install chromium`, `npm test --prefix test/browser`. Both pull requests change docs that the site builds.
- The mutation slice: `bundle exec mutineer run lib/mutineer/baseline.rb --test test/baseline_test.rb --no-since --no-fail-fast --format json --output /tmp/20a-slice.json`. Read `survivors[]`. A survivor on a line this group changed needs a test or a written reason in the report. `docs/agentic-coding.md` asks for a full scan when tests change.

Not needed: the Minitest 6 run and the Prism 2 run (no change to the Minitest integration or to parsing), and `rake test:daemon` (no daemon, reload or Rails code). CI still runs them.

For U1 also:

- `git diff origin/integration/v2.0 -- lib test action.yml` against `plans/20-A-trial-lib-test.patch` (KTD3). Explain each difference in the report.
- The three checks from "Edits that the conflict markers do not ask for": the CHANGELOG position, the bare calls, and the `case18` to `case21` baseline lines.

Then the pre-PR gate on the exact head commit (`RULES.md`, builder rule 6): the author self-check skill, `/ce-code-review`, `/fit-review`, `/cubic-loop` in local mode.

## Definition of Done

- AE1 to AE8 hold, each with a named test. AE4, AE5, AE6 and the U4 and U5 tests fail before their unit's change.
- `schema_version` is `2.0` in the reporter, `docs/json-schema.md` and `STABILITY.md`.
- Every #314 CHANGELOG entry and every new entry is under `## [Unreleased]`.
- `--threshold` exit codes are unchanged for a run with no `--baseline`.
- Pull request #314 is merged into `integration/v2.0` with a squash, title `fix!: --baseline fails an incomplete run and stops counting undecided survivors as fixed`. The second pull request is merged with title `fix!: exact score-drop check, foreign_path status, HTML baseline section, Action gem floor (#343)`.
- The L1 issue exists with four labels. #343 has the corrected estimate.
- `reports/20-A.md` in the run folder holds the details, and `runs.jsonl` has one builder line.

---

## Risks

| Risk | What limits it |
|---|---|
| A wrong fix in `lib/mutineer/reporter.rb` changes an exit code with no error. | The resolved text is in U1. The trial patch is the reference (KTD3). The tests of #314 and of `main` both run on the result. |
| A merge error that the suite does not find is missed (CHANGELOG position, harness case names, stale doc pages). | U1 lists each one with a check command. |
| Pull request #244 merges before #314. | "Do not build when". #244 rewrites `Baseline#diff` without the old-id matching and adds exit 3. U1 would then apply #314's rule to that code, and the incomplete exit would be 3. That needs a new plan. |
| Later groups undo part of this. | Notes for them are below this table. |
| U2 fails a run that passed before (a real drop smaller than 0.1 point). | That is the fix. The CHANGELOG says it, and `--baseline-epsilon` is the documented way to allow a small drop. |
| U5 fails a run that passed before (baseline, `format: html`, gem 1.x). | Intended and marked breaking for the Action. The message names two ways out. |
| U5 and the gem on `integration/v2.0`. That gem reports `1.10.0` until the release pull request (20-M, Decision 4). The Action from the branch with the gem from the branch fails the floor for a baseline with a non-JSON format. | No workflow in `.github/workflows` uses the Action (`git grep -n "uses: ./" origin/main -- .github` is empty). The harness uses a stub. The 20-I checklist run must use `format: json` or a 2.0.0 gem version. Listed as L4. |
| The suite is slow (1419 s in the trial). | Run it once per head commit, and run single test files while working: `bundle exec ruby -Ilib -Itest test/baseline_test.rb`. |

Notes for the groups after this one:

- **20-B (#322):** merge #314's final head into #322's branch before #314 is squash-merged (20-M). U2 to U5 do not touch `lib/mutineer/job_plan.rb` or `ran_at_load` code.
- **20-D (#244):** it removes the old-id matching from `Baseline#diff`. It must keep `partial:`, `sources:`, `operators:`, `project_root:`, `absent_status` (U3), `score_dropped?` (U2) and `require_relative "project_path"`. `foreign_file?` loses its last caller then and can go. An incomplete `--baseline` run becomes exit 3 there: the exit line in `CLI.execute`, the STABILITY entry from U1, the contract fragment, and the Action texts.
- **20-E (#508):** new mutant ids make every stored survivor absent once. With U1 they read as `fixed` in a full run. The 20-E plan decides what a baseline with old ids does.

## Decisions for David

The run takes each recommendation. Each row names the other option.

| # | Choice | Recommendation | Why, in one sentence | Other option |
|---|---|---|---|---|
| D1 | How is #314 brought up to date? | One merge of `origin/integration/v2.0` into its branch. | One round of conflicts and no force-push, and the squash merge gives the same result. | Rebase and force-push, as `RULES.md` builder rule 7 says. |
| D2 | Which exit code does an incomplete `--baseline` run get in #314? | 1, as #314 has it. Pull request #244 changes it to 3. | Exit 3 does not exist before #244, so #314 cannot use it. | Wait for #244 and ship it as 3 from the start. |
| D3 | Does #314 keep JSON schema `2.0`? | Yes. | `baseline.fixed_survivors` changes meaning, and the schema rule asks for a major bump for that. | Keep `1.11` and let #244 make the bump. |
| D4 | One pull request for the four #343 limits, or four? | One pull request with four commits. | One review gate and one wait for CI instead of four, and each limit is still one commit that can be reverted. | Four small pull requests, as the issue text allows. |
| D5 | U2: a stored report with no `summary.killed` and `summary.survived`. | Compare the rounded scores, as today. | Only a hand-made report lacks the counts, and skipping the check would weaken its gate with no message. | Treat the scores as not comparable and skip the check, with the existing "score-drop check skipped" line. |
| D6 | U2: how does a reader see a drop that the rounded scores hide? | Words on the human line and the Action line. No new JSON key. | The stored counts are in the baseline file that the reader already has. | Add `baseline.killed_before` and `baseline.survived_before` to the JSON report. |
| D7 | U3: what does an absent survivor with a path from another machine get? | A new status value, `foreign_path`, with a hint to write a new baseline. | `not_run` says the run skipped the mutant, which is false, and a new value is free while schema `2.0` is unreleased. | Keep `not_run`, document it, and close the item on #343. |
| D8 | U4: how is the HTML baseline section built? | The human report's lines, escaped, in one `<pre>`. | One source of facts, so the HTML and the human report cannot disagree. | Tables and lists like the other HTML sections, with their own tests. |
| D9 | U5: what does the Action do with a baseline, a non-JSON format and a gem older than 2.0.0? | Exit 2 before the run. | The JSON path already exits 2 for the same gem, and a gate that cannot be checked must not pass. | Print a `::warning::` and run. |
| D10 | The dropped-repeat defect (L1). | File an issue. Do not fix it in this group. | It is older than #314 and needs its own probe for `--since` and operator changes. | Add a sixth unit to the #343 pull request. |

Uncertain points, so David can weigh them:

- D7: `foreign_path` becomes part of the 2.0 schema. If David prefers fewer status values, D7's other option removes U3's code change and keeps only the doc text.
- D9: the wider choice is one floor for the whole Action: version 2 of the Action runs only with gem 2.0.0 or later. That would also remove the report check from #314 and the rule copies for an old CLI. It belongs to the contract flip (20-D). It is listed under "Open Questions".

## Open Questions

1. **A global gem floor for version 2 of the Action** (see D9). Not decided here. The 20-D plan can take it.
2. **Which release stopped storing absolute paths?** Between 1.3.0 and 1.7.0. It only changes the wording of the estimate on #343. The builder can find it with `git log -S"expand_sources" -- lib/mutineer/pairing.rb lib/mutineer/cli.rb`.
3. **Does cubic or Qodo review a pull request into `integration/v2.0`?** `DECISIONS.md`, "Facts", still says "not checked". If neither does, the local `cubic review` is the lens (`RULES.md`, merge rule 2).
4. **Labels of the second pull request.** `breaking change` is set because an exit code can change. If David reads U2 as a plain bug fix, only U5 keeps the label.

## Limits left open

| # | Limit | Follow-up |
|---|---|---|
| L1 | A stored survivor whose id this run dropped as a repeat of another mutant (#329, #374) is listed as fixed while the same edit still survives under the kept id. Confirmed on `main` and on #314's head with a unit probe. A second form is read from the code and not probed: with a narrower `--operators` list the kept copy can change, so the stored id reads `not_run` and its twin reads as a new survivor. | Filed as #566: "Baseline matching ignores dropped repeats of a mutant". Labels `bug`, `priority: medium`, `risk: medium`, `v2.0` (as 20-M asks). It names `extras[:copies]` in `CLI.execute` as the data that `Baseline#diff` does not get. |
| L2 | A stored report with no integer counts is still compared on rounded scores (KTD6). | Filed as #567: "Baseline score-drop check is rounded for a report with no counts". Labels `enhancement`, `priority: low`, `risk: low`, `backlog`. The code comment in `score_dropped?` names its number. |
| L3 | A `foreign_path` survivor can never be verified. The only way out is a new baseline. | #567, second item. The doc row in `docs/json-schema.md` names its number. |
| L4 | The Action floor is a version number, and the gem on `integration/v2.0` reports 1.x until release. A baseline with a non-JSON format fails there. | The U5 builder adds one line to #284 (the 2.0 checklist): "Action: baseline with a non-JSON format needs the gem version to be 2.0.0 or a 2.0.0 prerelease". |
| L5 | `unverified_survivors` never gates. A stored survivor that errors in a complete run passes. | By design in #314, stated in `docs/json-schema.md`. No issue. |
| L6 | An incomplete `--baseline` run exits 1 on `integration/v2.0` until #244 merges. | Group 20-D (20-M, Decision 6). No issue. |
| L7 | No fresh-process run gives a `ran_at_load` stored survivor a verdict. It stays unverified. | #286, group 20-B. |

## Sources

- Issues #283 (body and one comment) and #343 (body and one comment). Pull request #314: body, 4 comments, 4 reviews, head `6597cd8a`, 26 files. Its old plan on `origin/plan/283-286-baseline-unverified-survivors` and in the branch.
- Pull requests #244 and #322: bodies and the diffs of `lib/mutineer/baseline.rb`, `lib/mutineer/cli.rb` and `action.yml`.
- `AGENTS.md`, `.expectation-fit/ways-of-working.yaml`, `.expectation-fit/decisions/json-schema-and-baseline.md`, `cli-contract-and-exit-codes.md` and `scoring-and-verdicts.md`.
- `RULES.md`, `WORKLIST.md`, `DECISIONS.md`, `plans/20-M-merge-order-plan.md` and `plans/20-B-ran-at-load-plan.md` in the run folder.
- Code on `origin/main` at `c5100143`: `lib/mutineer/baseline.rb`, `result.rb`, `reporter.rb`, `cli.rb`, `project_path.rb`, `action.yml`, `rake/docs_contract.rb`, `docs/fragments/contract.yml`, `test/fixtures/action_harness.sh`.
- Probes: the trial merge and suite run, and six probe scripts (limits 1 to 4, the unpaired source, the dropped repeat). Results are in "Reproduction".
- All sources are current (checked on 2026-11-24). The old plan from 2026-10-24 is current for the design of #314 and out of date for file positions.

## Second opinion (Codex)

Pending.

## Verdict

**Go.** U1: the trial update passes the suite once the docs name schema `2.0`, and every merge error that the suite cannot find has a check. U2 to U5: each limit is reproduced, each fix is small, and none depends on another.
