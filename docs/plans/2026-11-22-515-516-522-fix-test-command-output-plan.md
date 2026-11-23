---
title: "Group P: --test-command output reading - Plan"
type: fix
date: 2026-11-22
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Group P: --test-command output reading - Plan

- **What:** Three fixes to how `--test-command` reads test output, in one pull request for 1.10.0.
- **Why:** A crash can score `killed`, a stopped chain of suites can score `survived`, and the random-order warning can be wrong.
- **How:** The clean run tells Mutineer where summary lines are and how many a full run prints. The seed check reads RSpec options in RSpec's order.

Build settings: Opus 5.5, effort `high`. The worklist says `medium`. Use `high`, because two of the three commits change verdicts.

Target release: 1.10.0. Issues: #515, #516, #522. One pull request, one commit per issue.
Planned against `main` at `f6f4efe6`. The follow-up issue that U0 files is #549.

---

## Goal Capsule

- **Objective:** A `--test-command` run gives fewer wrong verdicts and fewer wrong order warnings. A crash that only looks like a failing test does not score `killed`. A coverage gate that stops a chain of suites does not score `survived`. The random-order warning follows the option order that RSpec uses.
- **Means:** The clean run tells Mutineer where summary lines are and how many there are (KTD1, KTD3). The seed check reads RSpec options in RSpec's order (KTD7).
- **Authority:** `AGENTS.md`, then `.expectation-fit/ways-of-working.yaml` and `.expectation-fit/decisions/`, then this plan, then the issue texts.
- **Execution profile:** One branch, one worktree, one pull request. Three commits in the order U1, U2, U3. U0 is not a commit.
- **Who ships:** The builder opens the pull request. David merges. No release step.
- **Stop conditions.** Stop and report, do not work around:
  - A row of an existing table test in `test/external_backend_test.rb` changes its verdict under `check_summary: true`.
  - Real Minitest or real RSpec output on a clean run does not give the mode `:line` (see U1, real-runner test).
  - A fix needs a new verdict status, a JSON field, a CLI flag, a config key or a runtime gem.

---

## Product Contract

### Summary

Three fixes in `lib/mutineer/external_backend.rb`, each with tests, docs and a CHANGELOG entry.

1. **#515:** A summary line counts only at the start of a line, when the clean run shows summary lines there. This closes most of limit 4. Limits 3, 7 and 8 stay as they are, with the reason written down.
2. **#516:** With the SimpleCov gate message, a mutant scores `survived` only when its output has as many summary lines as the clean run. If a suite did not run, the mutant scores `error`.
3. **#522:** For RSpec, the last order option wins, in the order `.rspec`, `.rspec-local`, command, `SPEC_OPTS`. `--options` skips the two files. The other blind spots stay documented.

### Problem Frame

Pull request #523 documented the 12 limits of reading test output (#342) and fixed part of the order warning (#368). It changed no verdict.
Three issues remain. #515 lists limits that can score a crash as `killed`. #516 lists one that can score `survived` when a skipped suite could kill. #522 lists warnings that are missed or false.
A false `killed` raises the score with no test that caught the mutant. A false `survived` lowers it and hides a real kill.

### Decision for each limit

| Limit | Decision | Reason | Tracked after this pull request |
| --- | --- | --- | --- |
| #342 limit 3: an exception escapes `Minitest.run` | Accept. Keep documented. | The output is the same as a real kill that logs the error and calls `exit 1` (KTD4). | The follow-up issue (U0) |
| #342 limit 4: fake summary text | Fix now (U1). | The clean run shows where real summary lines are (KTD1). | Rest of the limit: the follow-up issue (#549) |
| #342 limit 7: reporter with no summary line | Accept. Keep documented. | The output holds no evidence that a test ran. The warning already prints once (KTD6). | The follow-up issue |
| #342 limit 8: `exit` during a Minitest test | Accept. Keep documented. | The process status is always 1 and the output is the same for `exit 0`, `exit 1` and `exit 2` (KTD5). | The follow-up issue |
| #342 limit 9: chained suites and the SimpleCov gate | Fix now (U2). | The clean run shows how many summary lines a full run prints (KTD3). | Rest of the limit: the follow-up issue (#549) |
| #522 item 1: a seed in `.rspec` that RSpec does not use | Fix now (U3). | RSpec's order of options is fixed and small (KTD7). | Closed by U3 |
| #522 item 2: `.rspec` is read from Mutineer's working directory | Accept. Keep documented. | Mutineer cannot see a `cd` inside a wrapper. | The follow-up issue |
| #522 item 3: seed in a wrapper, in `~/.rspec`, or Minitest `test_order` | Accept. Keep documented. | A false alarm only. No verdict changes. | The follow-up issue |
| #522 item 4: a seed-like argument meant for a wrapper | Accept. Keep documented. | Mutineer cannot know which program reads an argument. | The follow-up issue |

### Requirements

**Crash check (#515)**

- R1. When the clean run prints a Minitest or RSpec summary line at the start of a line, a mutant run counts a summary line and the `# Running:` line only at the start of a line.
- R2. When no summary line of the clean run starts a line, matching stays as in 1.9.0: a summary counts at any position.
- R3. `check_summary: true` and `check_summary: false` keep their 1.9.0 behaviour for a direct caller of `ExternalBackend.run`.
- R4. With the default reporters of Minitest and RSpec, a failing test still scores `killed`. A test proves this with real runner output in four formats: Minitest default, Minitest `-v`, RSpec progress, RSpec documentation.
- R5. Limits 3, 7 and 8 keep their 1.9.0 verdicts. The docs and the code comments say "accepted", give the reason, and cite the follow-up issue (#549).
- R6. When the line-start rule drops a failing summary that is in the output at another position, the `error` reason says so.

**SimpleCov gate (#516)**

- R7. With SimpleCov's gate message and a passing summary, a mutant scores `survived` only when its output has at least as many summary lines as the clean run. With fewer, it scores `error`, and the reason gives both counts and the next step.
- R8. With the gate message and a failing summary, the mutant scores `killed`, whatever the count. When the clean run printed no summary line, the 1.9.0 rule stays.

**Random-order warning (#522)**

- R9. For RSpec, the last order option decides, in this order: `.rspec`, `.rspec-local`, the command, `SPEC_OPTS`. The order is fixed only when that last option is `--seed N`, `--order rand:N` or `--order random:N`.
- R10. When the command has `--options` or `-O`, Mutineer does not read `.rspec` and `.rspec-local`. (Build note: the plan first said the command or `SPEC_OPTS`. RSpec reads `--options` only from the command line and ignores it in `SPEC_OPTS`, so the build checks the command only.)
- R11. The change decides only if the warning prints, and it changes two words of the warning. No verdict, score, exit code or JSON field changes. The Minitest rule does not change.

**Docs and tracking**

- R12. Each doc copy of a changed rule states the new rule in the same commit as the code.
- R13. Each limit of reading `--test-command` output that stays open cites an open GitHub issue in the docs and in the code comment. This includes the seven limits that cite the closed #342 today.

### Acceptance Examples

- AE1. **Covers R1.** Clean run: real Minitest output. Mutant run: exit 1, a `-v` test-name line with `1 failures` in it, then `2 runs, 2 assertions, 0 failures, 0 errors`. Verdict: `error`. In 1.9.0: `killed`.
- AE2. **Covers R2.** A wrapper puts `app | ` before each line. A failing test still scores `killed`, and the "no summary line" warning does not print.
- AE3. **Covers R7.** Clean run: two summary lines. Mutant run: exit 2, one passing summary, the gate message. Verdict: `error`. The reason has "printed 1 summary line where the clean run printed 2". In 1.9.0: `survived`.
- AE4. **Covers R7.** The same wrapper runs one suite twice. Clean run: two summary lines. Mutant run with the gate after the first: `error`.
- AE5. **Covers R8.** Mutant run: exit 2, one failing summary, the gate message, clean run had two. Verdict: `killed`.
- AE6. **Covers R9.** `.rspec` has `--seed 7`. The command has `--order rand`. The output has `Randomized with seed 21709`. The warning prints. In 1.9.0 it does not.
- AE7. **Covers R9.** The command has `--order rand --seed 7`. No warning. The command has `--seed 7 --order rand`. The warning prints.
- AE8. **Covers R10.** `.rspec` has `--seed 7`. The command has `--options other.opts`. The output has a `Randomized with seed` line. The warning prints.

### Scope Boundaries

Not in this work:

- No new verdict status, JSON field, CLI flag, config key or `action.yml` input.
- No summary pattern for Cucumber or other runners (limit 7 stays).
- No trace detection for limit 3 and no patch of `exit` in the app's process for limit 8.
- Mutineer still sets no seed for `--test-command`. David decided that in #368.
- No change to the verdicts of limits 1, 2, 5, 6, 10, 11 and 12. Only the issue they cite changes (R13).
- No change to the `--daemon` path (#296).
- No new dev gem. minitest-reporters and `parallel_tests` are not run in a test.

### Open Questions

None of these blocks the build. Each has a default. The builder uses the default and lists the question in the pull request body.

- Q1. **Limit 4: which rule?** Default: (A) the clean run picks the mode, as in KTD1. Option (B): always need the line start. It fails the constraint "no real kill becomes an error": with a prefix wrapper, a SimpleCov-gate kill would score `error`. Option (C): accept limit 4 and change no code. (C) is the cheapest. The benefit of (A) is small: an estimate of far below 1 project in 1,000. Its cost is one more value of `check_summary`, four constants, a keyword on four predicates, and two new rare cases where a kill scores `error` (see "Limits left open"). (A) is the default because #515 is a `bug` for 1.10.0 and a false `killed` raises the score. No data measures either side.
- Q2. **Where do the accepted limits live?** Default: close #515, #516 and #522 with this pull request, and file one follow-up issue with no version label (U0). It also takes the seven limits that cite the closed #342. This is what #523 did with #342 and #368. Other option: keep #515 and #522 open and use `Refs`.
- Q3. **Limit 3: accept?** Default: yes. The other option is to score `error` when a Ruby exception trace follows `# Running:`. That turns a real kill into `error` when code under test logs `e.full_message` and calls `exit 1`, a common CLI pattern.
- Q4. **Order warning: compare seeds, not options?** Default: not in this pull request. Mutineer could compare the seed of the clean run with the seed of the first mutant run. That would see every case in #522. But the warning would print one suite run later, `ExternalBackend.run` would have to return the output, and it replaces the code from #523. The follow-up issue records the idea.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The clean run picks the match mode.** `smoke_check!` returns `:line` when at least one summary line of the clean run starts a line, `true` when summary lines exist only at other positions, and `false` when there is none. The runner passes that value to `ExternalBackend.run` as `check_summary`. So `check_summary` takes `false`, `true` (any position, the 1.9.0 rule) or `:line`. Rejected: always need the line start (see Q1, option B). Rejected: decide per mutant run (a crashed run has no real summary, so the fake one would count again). Rejected: a fourth value `:any` (it would repeat `true`).
- KTD2. **Line start means: start of the text, or right after `\n` or `\r`, after colour codes are removed.** `\r` is for a progress bar that redraws a line. No real run backs the `\r` case. It is cheap and it can only keep a kill, so it stays.
- KTD3. **The clean run gives the expected number of summary lines, and the compare is "at least".** The keyword is `clean_summaries:`, because the value is a count of summary lines, not of suites. Rejected: "exactly one summary line" from #342. A stopped chain also prints exactly one. Rejected: "equal". A wrapper that reruns failed tests prints more lines.
- KTD4. **Accept limit 3.** An exception that escapes `Minitest.run` prints `file:line:in 'method': message (Class)` after `# Running:` and exits 1. Code under test that runs `warn e.full_message; exit 1` in a test prints the same text and exits 1. The second case is a real kill in process. Any rule that separates them by output turns real kills into `error`.
- KTD5. **Accept limit 8.** Minitest's `autorun` ends with status 1 after any `exit` in a test, and prints nothing more. Only code inside the child could tell `exit 0` from `exit 1`. Mutineer does not patch `exit` in the app's process.
- KTD6. **Accept limit 7.** With no summary line, the output has no sign that a test ran. The crash check stays off and the one warning stays.
- KTD7. **The seed check reads the last RSpec order option.** Join the sources in RSpec's order and take the last `--seed` or `--order` option. Do not read the file that `--options` names: a false alarm is harmless there, and the docs already list it.
- KTD8. **No new status.** The new `error` results use `Result.error` through `error_with_output`. They count as `errored`, appear in `no_verdict[]` with their reason, and stay out of the score.
- KTD9. **`smoke_check!` keeps its array and gets a fourth slot.** Slot 2 is the mode and slot 4 is the count. Rejected: a `Data.define` value. The method has one production caller, and the tests read the array by position.

### Verdict rule after this change

This table gives the direction. It is not code. "Summary" and "`# Running:`" mean a match at the start of a line when the mode is `:line`, and a match at any position when it is `true` or `false`. "Passing summary" means what `tests_passed?` means today: a summary line exists, none reports a failure, and there is no RSpec error outside examples.

| Order | Condition on the mutant run | Verdict | Changed |
| --- | --- | --- | --- |
| 1 | Timeout | `timeout` | no |
| 2 | Exit 0 | `survived` | no |
| 3 | Signal, or exit 126 or 127 | `error` | no |
| 4 | Gate message and a failing summary | `killed` | mode only (U1) |
| 5 | Gate message, a passing summary, at least as many summary lines as the clean run | `survived` | U2 |
| 6 | Gate message, a passing summary, fewer summary lines than the clean run | `error` | new in U2 |
| 7 | Exit code other than 1 | `error` | no |
| 8 | Exit 1, check on, no failing summary, no run stopped during a test | `error` | mode only (U1), plus the new reason of R6 |
| 9 | Exit 1, other cases | `killed` | no |

### Assumptions

- The Ruby methods of `Mutineer::ExternalBackend` are not in `STABILITY.md`. New keywords with defaults keep each present caller working.
- The maintainer batches fixes into the next release (AGENTS.md, "Release policy for agents", item 4). The 1.10.0 target is the issues' `v1.10.0` label. The CHANGELOG names each verdict change.
- Each frequency number in this plan is an estimate. No data measures it. The builder writes it as an estimate.

### Sources

Checked on 2026-11-22 with Ruby 3.4.9, Minitest 5.27.0 and the RSpec in `Gemfile`.

- Real summary lines start a line: Minitest default, Minitest `-v`, RSpec progress, RSpec documentation.
- A `puts` in a Minitest test lands after a progress dot: `.9 runs, 9 assertions, 1 failures, 0 errors, 0 skips`. Not at a line start.
- Minitest `-v` prints the test name before ` = `, so a summary-like name is not at a line start.
- RSpec documentation format indents an example name by two spaces. A top-level group name is at a line start. That case stays open.
- An escaped exception in a reporter and `warn e.full_message; exit 1` in a test give the same output shape and exit 1 (KTD4).
- `exit 0` and `exit 2` in a Minitest test both end with status 1 and no summary (KTD5).
- Not run: minitest-reporters and `parallel_tests`. What this plan says about them comes from memory of their output, not from a run.
- RSpec option order, each line run for real:

| Sources | Result |
| --- | --- |
| `.rspec` `--seed 7` | seed 7 |
| `.rspec` `--seed 7`, command `--order rand` | random seed |
| `.rspec` `--seed 7`, `SPEC_OPTS` `--order rand` | random seed |
| `.rspec` `--seed 7`, `.rspec-local` `--order rand` | random seed |
| `.rspec` `--seed 7`, command `--options other.opts` or `-O other.opts` | `.rspec` not used |
| command `--seed 7 --order rand` | random seed |
| command `--order rand --seed 7` | seed 7 |
| command `--order=rand:9` | seed 9 |
| command `--order rand`, `SPEC_OPTS` `--seed 5` | seed 5 |
| `.rspec` `--order rand`, command `--seed 3` | seed 3 |

- Doc copies to change: `docs/rails-setup.md` (the "Test order" row, the "Subprocess result" table, the "Known limits" table), `README.md` (the "Subprocess result" table), `.expectation-fit/decisions/scoring-and-verdicts.md` (the line "SimpleCov Gate Survivor Condition"), `.expectation-fit/decisions/coverage-and-test-selection.md` (a new line beside "RSpec SPEC_OPTS Order Precedence"), and the `[Unreleased]` entry for #342 in `CHANGELOG.md`.
- Doc copies checked, no edit needed: the stderr note in `lib/mutineer/cli.rb` that starts "--test-command score is an upper bound" (it stays true), the "Test order" section of `docs/cli.md`, the `[Unreleased]` entry for #368 in `CHANGELOG.md` (it stays true), and the decisions line "Detect Interrupted Final Test Suite" (the rule holds in both modes). The builder reads each one again after the code change.
- `docs/rails-setup.md` and `README.md` feed `llms-full.txt` (`rake/docs_contract.rb`), so the website checks apply.
- `Runner.run_external` has three direct callers in `test/runner_external_test.rb`. A new keyword there needs a default.
- `ExternalBackend.child_env` clears each `BUNDLE_`, `GEM_` and `RUBY` key. A child of `ExternalBackend.run` loads the Minitest that plain RubyGems finds, not the one in the Gemfile. `test/seed_contract_test.rb` (`run_minitest`, `run_rspec`) shows how a test starts a child that keeps the test bundle.

---

## Implementation Units

### U0. File the follow-up issue (#549)

- **Goal:** One open issue holds each limit left open, so docs and comments can cite its number from the first commit.
- **Requirements:** R13.
- **Approach:** File it before the first commit. Title: "`--test-command` output reading: limits accepted after #515, #516 and #522". Body in What, Why, How form, starts with `**Claude:**`. Copy each row from "Limits left open" below, with its estimate. Labels: `bug`, no version label. Create no new label.
- **Test expectation:** none. This unit changes no file.
- **Verification:** The issue is open and its number is in the pull request body.

### U1. A summary line counts only at the start of a line (#515)

- **Goal:** Close limit 4 for the default reporters. Record the decision for limits 3, 7 and 8.
- **Requirements:** R1, R2, R3, R4, R5, R6, R12, R13. Decisions: KTD1, KTD2, KTD4, KTD5, KTD6, KTD8.
- **Dependencies:** U0.
- **Files:**
  - `lib/mutineer/external_backend.rb`
  - `lib/mutineer/runner.rb` (YARD type of `check_summary` on `run_external` only)
  - `test/external_backend_test.rb`
  - `test/runner_external_test.rb`
  - `docs/rails-setup.md`
  - `.expectation-fit/decisions/scoring-and-verdicts.md`
  - `CHANGELOG.md`
- **Approach, in `lib/mutineer/external_backend.rb`:**
  - Add a line-start pattern and line-start forms of `MINITEST_SUMMARY`, `RSPEC_SUMMARY` and `MINITEST_RUNNING`. Keep the three present constants as they are. Each new constant needs a comment, for `yard:strict`.
  - Give `summary_line?`, `failure_reported?`, `exited_during_tests?` and `tests_passed?` a `line:` keyword with the default `false`.
  - Add `summary_mode(text)`. It returns `:line`, `true` or `false` (KTD1).
  - `smoke_check!` returns `summary_mode(text)` in its second slot. The value stays truthy when a summary exists, so `Runner.execute_external` needs no code change. Name the slot `summary_mode` in the YARD text.
  - `ExternalBackend.run` reads `check_summary == :line` once and passes it to each predicate, in the SimpleCov branch too.
  - R6: in the exit 1 branch that returns "exited 1 but its output shows no failing test", when the mode is `:line` and `failure_reported?(text)` is true at any position, use a second reason. Wording: "test-command exited 1 and a failing summary is in its output, but not at the start of a line, where the clean run printed its summary (a wrapper or a parallel runner moved it; --verbose shows the output)". (Build note: review added the other cause, so the reason ends "(a wrapper or a parallel runner moved it, or a test printed failing summary-like text; --verbose shows the output)", and it also applies after a SimpleCov gate.)
  - Leave `SIMPLECOV_GATE` and `RSPEC_OUTSIDE_ERROR` without a line start. SimpleCov writes its message to stderr, which can land inside a buffered stdout line. The RSpec text is in the middle of the summary line by design.
  - Update the YARD text of `run`, `smoke_check!` and the module comment. Rewrite the "Ceiling" comments on `failure_reported?` and `exited_during_tests?`: limit 4 is fixed for line-start output, limits 3 and 8 are accepted, with the follow-up issue (#549) number.
- **Execution note:** Write the tests first. Run the present table tests in both modes before any change to a predicate.
- **Test scenarios, `test/external_backend_test.rb`:**
  - Both modes, same verdicts. Run the rows of `test_exit_one_with_failing_summary_is_killed`, `test_exit_one_with_no_failing_test_in_summary_is_error` and `test_simplecov_gate_exit_follows_the_summary` under `check_summary: true` and under `:line`. Each row keeps its verdict. The tables already hold coloured rows, so this also covers "after colour codes are removed".
  - The rule, on many inputs ("Test the rule, not the example"). For each row of those three tables, put two spaces before each summary line. Under `:line` the verdict equals the verdict of the same output with those summary lines removed. Under `true` the verdict does not change. Do the same with the prefix `app | `.
  - Line mode drops a summary that does not start a line. Each output ends with a real passing summary and exit 1. Under `:line` the verdict is `error`. Under `true` it is `killed`. Inputs: a Minitest `-v` name line (`FakeTest#test_x = 9 runs, 9 assertions, 1 failures, 0 errors, 0 skips`), a line after a progress dot (`.9 runs, ...`), an indented RSpec name (`  reports 2 examples, 1 failure`), a prefixed line (`app | 3 runs, 3 assertions, 1 failures, 0 errors`).
  - R6: for those four inputs the details under `:line` have "not at the start of a line". For an output with no failing summary at any position, the details have "shows no failing test".
  - `\r` is a line start: `progress\r3 runs, 3 assertions, 1 failures, 0 errors` scores `killed` under `:line`. Lines that end with `\r\n` also score `killed`.
  - The `# Running:` line: `2 runs, 2 assertions, 0 failures, 0 errors` then `note: # Running:` and exit 1. Under `:line`: `error`. Under `true`: `killed`.
  - A run that stopped during a test: `# Running:`, then a `-v` name line with `0 failures, 0 errors` in it, no real summary, exit 1. Under `:line` it scores `killed`. Under `true` it scores `error`, because the name line reads as a passing summary. (Build note: review showed that a real passing summary a wrapper moved looks the same, so under `:line` it scores `error` too, with the "not at the start of a line" reason.)
  - `smoke_check!` mode: a line-start summary gives `:line`. A prefixed summary only gives `true`. One of each gives `:line`. No summary gives `false`. Update `test_smoke_check_reports_summary_line` and `test_smoke_check_green_returns_elapsed_and_no_summary`.
  - Real runners (R4, "Assert the mechanism"). For Minitest default, Minitest `-v`, RSpec progress and RSpec documentation: start a child that keeps the test bundle, as `run_minitest` and `run_rspec` in `test/seed_contract_test.rb` do, and capture its output and exit status. Each suite has a test whose name holds summary-like text and that prints such a line. Replay the captured bytes and status through the `with_script` helper. A passing suite through `smoke_check!` gives `:line`. A failing suite through `run(check_summary: :line)` gives `killed`. This form follows the Gemfile, so the Minitest 6 run tests Minitest 6.
- **Test scenarios, `test/runner_external_test.rb`:**
  - AE1 end to end. Copy the shape of `test_exit_one_without_summary_scores_error_after_summary_smoke`. On a mutated tree the wrapper prints a failing summary that does not start a line, then a passing one, and exits 1. Expect `killed` 0, `errored` 6, and "not at the start of a line" in `no_verdict[].details`.
  - AE2 end to end. A Ruby wrapper puts `app | ` before each output line of the real suite and keeps its exit status. Expect `killed` 6 with `calculator_strong_test.rb`, and no "no Minitest or RSpec summary line" warning.
- **Docs:**
  - `docs/rails-setup.md`, "Subprocess result" table: the row "Recognised summaries" says a summary must start a line when the clean run's summary does. Add what a user does when a kill scores `error` with "not at the start of a line": remove the prefix, or the parallel runner, from the command.
  - `docs/rails-setup.md`, "Known limits": change the sentence "It accepts these 12 limits and does not tighten the check." and link the follow-up issue (#549) there as the open tracker of each row. Row 4 gives what is left (see "Limits left open"). Rows 3, 7 and 8 say "accepted" and give one sentence of reason. Keep the row numbers.
  - `.expectation-fit/decisions/scoring-and-verdicts.md`: add one line, "Summary Lines at Line Start", that names `ExternalBackend.summary_mode`.
  - `CHANGELOG.md`, `[Unreleased]`, `### Fixed`: one entry. It names the verdict move (`killed` to `error`), says the score can change, gives the estimates, and says limits 3, 7 and 8 are accepted. Also change the #342 entry in the same section: its last two sentences ("tracked in #515 ... No scoring changed.") must stay true for the release.
- **Frequency estimates to record (code comment, pull request body, follow-up issue #549):**
  - The fix (`killed` to `error` for a crash): needs summary-like text away from a line start and a crash with exit 1 after it. Estimate: far below 1 project in 1,000. In such a project it can affect each mutant that crashes the run.
  - The new exposure (a real kill scores `error`): needs a clean run with a line-start summary and a mutant run whose failing summary is not at a line start. Two known ways: interleaved output of parallel test processes, and a chain with one prefixed suite and one plain suite. Estimate: below 1 in 100 `--test-command` setups, unmeasured. The R6 reason names the case.
- **Verification:** The tests above pass. `git grep -n "342 limit\|#515"` shows no comment that still calls limit 4 open without the follow-up issue (#549) number.

### U2. A SimpleCov gate that stops a chain of suites scores `error` (#516)

- **Goal:** Close limit 9: no `survived` when a suite did not run.
- **Requirements:** R7, R8, R12, R13. Decisions: KTD3, KTD8, KTD9.
- **Dependencies:** U1 (the count uses the match mode).
- **Files:**
  - `lib/mutineer/external_backend.rb`
  - `lib/mutineer/runner.rb`
  - `test/external_backend_test.rb`
  - `test/runner_external_test.rb`
  - `docs/rails-setup.md`
  - `README.md`
  - `.expectation-fit/decisions/scoring-and-verdicts.md`
  - `CHANGELOG.md`
- **Approach:**
  - `lib/mutineer/external_backend.rb`: add `summary_count(text, line: false)`, the number of Minitest and RSpec summary lines.
  - `smoke_check!` returns a fourth value: the summary count of the clean run in the mode it found (KTD9). Update its YARD `@return`.
  - `ExternalBackend.run` gets `clean_summaries: 0`. In the SimpleCov branch, after `tests_passed?`: return `survived` when the count is at least `clean_summaries`. Else return `error_with_output`. Wording: "test-command printed 1 summary line where the clean run printed 2, after a SimpleCov coverage gate ended it; a suite that did not run could still kill this mutant (turn the gate off for mutation runs)".
  - `lib/mutineer/runner.rb`: `Runner.execute_external` reads the fourth value and passes it on. `Runner.run_external` gets `clean_summaries: 0` and passes it to `ExternalBackend.run`. The default keeps its three direct callers in the tests unchanged. With 0 the 1.9.0 rule applies.
  - Rewrite the comment above the SimpleCov branch: limit 9 is fixed, and name the follow-up issue (#549) for limits 2 and 10 and for the rest of limit 9.
- **Test scenarios, `test/external_backend_test.rb`:**
  - `smoke_check!` count: one summary gives 1, two give 2, none gives 0. With a line-start summary and a prefixed one, the count is 1.
  - Gate table, exit 2, under `true` and `:line`:

| Output | `clean_summaries` | Verdict |
| --- | --- | --- |
| one passing summary, gate message | 1 | `survived` |
| one passing summary, gate message | 2 | `error`, details have "printed 1 summary line where the clean run printed 2" |
| two passing summaries, gate message | 2 | `survived` |
| three passing summaries, gate message | 2 | `survived` |
| one failing summary, gate message | 2 | `killed` |
| one passing summary, gate message | 0 (default) | `survived` |
| `0 examples, 0 failures, 1 error occurred outside of examples`, gate message | 1 | `error`, as in 1.9.0 |

- **Test scenarios, `test/runner_external_test.rb`:**
  - AE3 and AE4 end to end. A Ruby wrapper stands for `suite && suite`. On the clean tree it prints two passing summaries and exits 0. On a mutated tree it prints one passing summary and the gate message and exits 2. Expect `survived` 0, `errored` 6, and both counts in `no_verdict[].details`.
  - Use a Ruby wrapper, not `sh -c`. If a test must use a shell, pass the files as `"$@"` and never put a path into the script text.
- **Docs:**
  - `docs/rails-setup.md`, "Subprocess result" table: the SimpleCov row adds "and the run printed as many summary lines as the clean run". Add the new `error` case and its next step: turn the coverage gate off for mutation runs.
  - `docs/rails-setup.md`, "Known limits", row 9: now `error`, not `survived`. Name what is left (see "Limits left open").
  - `README.md`, "Subprocess result" table: the row "Only a SimpleCov gate fails, with its gate message and a passing summary" gets the same condition.
  - `.expectation-fit/decisions/scoring-and-verdicts.md`: change the line "SimpleCov Gate Survivor Condition" to include the count.
  - `CHANGELOG.md`, `### Fixed`: one entry. It names the verdict move (`survived` to `error`), says the score can change, and says a run can now exit 1 through the no-verdict rule (more than one mutant and more than 10% with no verdict).
- **Frequency estimate to record:** Needs a wrapper that chains suites with `&&` and a SimpleCov gate that fails on a mutant run. Estimate: below 1 in 100 `--test-command` setups, unmeasured. In such a setup it affects each mutant that trips the gate in a suite that is not the last.
- **Verification:** The tests above pass. The exact-survivor integration oracle stays green.

### U3. The random-order warning follows RSpec's option order (#522)

- **Goal:** Close item 1 of #522. Keep items 2, 3 and 4 documented.
- **Requirements:** R9, R10, R11, R12, R13. Decision: KTD7.
- **Dependencies:** U0. No code depends on U1 or U2.
- **Files:**
  - `lib/mutineer/external_backend.rb`
  - `lib/mutineer/runner.rb` (two words of the warning)
  - `test/external_backend_test.rb`
  - `docs/rails-setup.md`
  - `.expectation-fit/decisions/coverage-and-test-selection.md`
  - `CHANGELOG.md`
- **Approach:**
  - `random_order`, RSpec part: join the option files, the command and `SPEC_OPTS` in that order. Take the last `--seed` or `--order` option. Report a random order unless that option matches `RSPEC_SEED_GIVEN`.
  - Add one constant for an order option (`--seed`, `--order X`, `--order=X`) and one for `--options` or `-O`. Each needs a comment.
  - The option files are skipped when the command has `--options` or `-O` (build note: `random_order` makes this check, not `rspec_option_files`, and not for `SPEC_OPTS`, see R10). It still drops comment lines and still treats an unreadable file as no seed.
  - The Minitest part does not change. Minitest has no option that makes a fixed seed random again, so order between `SEED`, `TESTOPTS` and the command does not matter.
  - `lib/mutineer/runner.rb`, the warning in `Runner.execute_external`: change "found no fixed seed" to "found no fixed seed in effect". A seed in `.rspec` that RSpec overrides is found, but not in effect.
  - Rewrite the "Ceiling" comment on `random_order`: name what is fixed and cite the follow-up issue (#549) for the rest.
- **Test scenarios, `test/external_backend_test.rb`:**
  - Each row of the option-order table in Sources, as a call of `random_order` with a `Randomized with seed 4242` line. Rows with "random seed" return `[:rspec, "4242"]`. Rows with a seed return `nil`.
  - `--options other.opts` and `-O other.opts` with `--seed 7` in `.rspec` return `[:rspec, "4242"]`.
  - `--options` in `SPEC_OPTS` returns `nil`: RSpec ignores it there (build note, see R10).
  - Each present assertion in `test_random_order_is_nil_when_the_order_is_fixed`, `test_random_order_sees_a_seed_in_the_rspec_option_files`, `test_random_order_ignores_an_unreadable_rspec_file` and `test_random_order_checks_each_runner_in_a_combined_run` stays and passes.
- **Docs:**
  - `docs/rails-setup.md`, "Test order" row: the last sentence about `.rspec` (the one that links #522) says the precedence case is now seen. List what is left and link the follow-up issue (#549): the `cd` case, a seed in the file that `--options` names, and the cases already in that row.
  - `.expectation-fit/decisions/coverage-and-test-selection.md`: add one line beside "RSpec SPEC_OPTS Order Precedence". It says the `--test-command` warning uses the last order option in the order `.rspec`, `.rspec-local`, command, `SPEC_OPTS`, and names `ExternalBackend.random_order`.
  - `CHANGELOG.md`, `### Fixed`: one new entry. A warning only, no verdict changes. Leave the #368 entry as it is.
- **Verification:** The tests above pass. `test_random_order_on_clean_run_warns_once` and `test_fixed_seed_on_clean_run_does_not_warn` in `test/runner_external_test.rb` stay green.

### Commit order

1. `fix: --test-command counts a summary line only at the start of a line (#515)` (U1)
2. `fix: a SimpleCov gate that stops a chain of suites scores error, not survived (#516)` (U2)
3. `fix: the random-order warning follows RSpec's option order (#522)` (U3)

Each commit holds its code, tests, docs and CHANGELOG entry, and passes the local gate alone. A fix from review goes in a new commit that names the issue.

---

## Risks

| Risk | Effect | Mitigation |
| --- | --- | --- |
| A reporter prints its summary away from a line start | In `:line` mode a real kill scores `error` | The mode is `:line` only when the clean run shows a line-start summary. The real-runner test covers four default formats. The R6 reason names the case. |
| Output of parallel test processes interleaves | A summary line can land after another process's dots. A kill can score `error` (U1), and a correct `survived` under the gate can score `error` (U2). | Not verified by a run. The R6 reason and the docs tell the user what to do. Listed in "Limits left open". |
| One suite of a chain is prefixed and one is not | The mode is `:line`. A kill in the prefixed suite scores `error`, and the clean count misses that suite. | Rare. Listed in "Limits left open". |
| More `error` verdicts in a chained SimpleCov setup | A run that passed can exit 1 through the no-verdict rule | The CHANGELOG entry says so and tells the user to turn the gate off for mutation runs. |
| minitest-reporters output is not checked by a run | Its summary position is not proven | The clean run picks the mode, so the mutant runs of the same reporter match the same way. Listed in "Limits left open". |
| A doc copy stays stale | A review finding | The author self-check lists doc copies. The list is in Sources. |
| The `[Unreleased]` entry for #342 says "No scoring changed" | The release notes contradict themselves | U1 edits that entry. |

---

## Limits left open

Each row goes into the follow-up issue (#549) from U0. The title of that issue is "`--test-command` output reading: limits accepted after #515, #516 and #522". Docs and code comments cite its number.

| Limit | Result |
| --- | --- |
| #342 limit 3: an exception escapes `Minitest.run` | False `killed`. Accepted (KTD4). |
| #342 limit 7: no summary line on the clean run | Crash check off, one warning, each exit 1 is a kill. Accepted. |
| #342 limit 8: `exit` during a Minitest test | `killed` for each status. Accepted (KTD5). |
| Limit 4, rest: a test prints a full summary line at a line start, or an RSpec top-level group has such a name in documentation format | False `killed` for a crash |
| Limit 4, rest: a wrapper prefixes each line | Matching stays at any position, so limit 4 stays whole there |
| New with U1: a chain with one prefixed suite and one plain suite | A kill in the prefixed suite scores `error`, with the R6 reason |
| New with U1: interleaved output of parallel processes moves a failing summary off the line start | A kill can score `error`, with the R6 reason. Not verified by a run. |
| New with U2: interleaved output moves a passing summary off the line start under the gate | A correct `survived` can score `error`. Not verified by a run. |
| Limit 9, rest: the clean run printed no summary line | The count is 0, so the 1.9.0 rule stays: a passing summary scores `survived` |
| Limit 9, rest: a chain whose plain suite runs first and whose prefixed suite runs second | The clean count is 1, so a gate that stops the first suite still scores `survived` |
| Limit 9, rest: the gate stops a chain | The mutant has no verdict (`error`). Mutineer does not run the skipped suite. |
| Found in planning: a wrapper that loses the exit code (`a; b`, where `a` fails and `b` passes) | Exit 0, so `survived` |
| Not verified: minitest-reporters summary position | No known wrong verdict. No test runs that gem. |
| #522 item 2: `cd` inside a wrapper | The wrong `.rspec` is read |
| #522 item 3: seed in a wrapper, `~/.rspec`, `config.seed`, an ERB branch, Minitest `test_order` | False alarm |
| #522 item 4: seed-like argument for a wrapper | Missed warning |
| #522, rest: a seed in the file that `--options` names | False alarm |
| Idea, not a limit: compare the seed of the clean run with the first mutant run (Q4) | No change now |
| #342 limits 1, 2, 5, 6, 10, 11, 12 | Verdicts unchanged. #342 is closed, so these rows move to the follow-up issue (#549) too. |

The `--daemon` output path stays in #296.

---

## Verification Contract

Run on the exact head commit, from the worktree.

| Check | Command | When |
| --- | --- | --- |
| Suite | `bundle exec rake test` | Each commit |
| Load smoke | `ruby -Ilib -e 'require "mutineer"'` | Each commit |
| YARD, 100% | `bundle exec rake yard:strict` | Each commit |
| Minitest 6 | `BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle install` then `BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle exec rake test` | Before the push. The real-runner test reads Minitest output. |
| Site build | `bundle exec rake site:build` then `node --test test/site_test.js` | Before the push. `docs/rails-setup.md` and `README.md` feed `llms-full.txt`. |
| Browser tests | `npm ci --prefix test/browser`, `npx --prefix test/browser playwright install chromium`, `npm test --prefix test/browser` | Before the push |
| Author self-check | `ruby .claude/skills/author-self-check/self_check.rb origin/main`, then steps 2 to 6 of `.claude/skills/author-self-check/SKILL.md` | Before the first push |
| Pre-PR gate | `/ce-code-review`, `/fit-review`, `/cubic-loop` in local mode | On the head commit |

Not needed: `rake test:daemon` (no daemon, reload or Rails code changes) and the Prism 2 run (no parsing changes).

---

## Definition of Done

- U0: the follow-up issue (#549) is open, and docs, comments and the pull request body cite its number.
- U1: R1 to R6 hold. The table tests pass in both modes. The rule test passes for each table row. The real-runner test passes for four formats.
- U2: R7 and R8 hold. The gate table and the end-to-end test pass.
- U3: R9 to R11 hold. Each row of the option-order table has a test.
- No row of a present table test changed its verdict under `check_summary: true`.
- Each new method and constant has YARD text. No `eval`. No runtime gem. No new status, flag, key or JSON field.
- Each doc copy in Sources states the new rule. The `[Unreleased]` section does not contradict itself.
- Each row in "Limits left open" is in the follow-up issue (#549), and the docs and code comments cite that issue.
- The pull request body has What, Why and How, the decision for each limit, the frequency estimates, the four open questions with the defaults used, `Closes #515`, `Closes #516`, `Closes #522`, and the follow-up issue (#549) number.
- Labels: `bug`, `v1.10.0`, and the matching priority and risk labels from `gh label list`.
- No abandoned code or unused constant stays in the diff. `lib/mutineer/version.rb` is unchanged.
