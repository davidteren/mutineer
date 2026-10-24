---
title: "fix: score a crash of --test-command as error, not killed"
type: fix
date: 2026-10-24
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
origin: GitHub issue #292 (davidteren/mutineer) and its Claude analysis comment
---

# fix: score a crash of --test-command as error, not killed

## Summary

The external backend (`--test-command`) scores every non-zero exit except 126 and 127 as `killed`. A suite that fails to load, an OOM kill behind a wrapper (exit 137), or a segfault then reads as a strong test. This plan ships all three steps from the issue comment in one PR:

1. Only exit 1 scores `killed`, the same rule as `Isolation.decode`. Any other non-zero code scores `error`.
2. Exit 1 scores `killed` only when the captured output has a Minitest or RSpec summary line that reports a failing test. Otherwise it scores `error`. This applies only when the clean run printed a summary line (step 3).
3. Step 2 runs only when the clean smoke run printed a known summary line. If not, Mutineer warns once and keeps the exit-code rule from step 1.

**Decision on scope:** steps 2 and 3 stay in this PR. Together they add regex constants for the summary lines, small predicates over the captured output, one keyword argument, and one warning. Review added the SimpleCov gate and Minitest `# Running:` constants and predicates on top of the first draft. Without step 2, a load error (exit 1) still scores `killed`, which is the most common false kill the issue names. Without step 3, step 2 would turn every kill into `error` for a suite with a custom formatter (RSpec `--format json`, a test-unit suite). Each step has its own direct tests.

---

## Problem Frame

- `lib/mutineer/external_backend.rb` `ExternalBackend.run`: exit 0 is `survived`, nil exit status (signal) is `error`, 126/127 are `error`, and every other code is `killed`.
- `lib/mutineer/isolation.rb` `Isolation.decode`: only exit 1 is `killed`; exit 2 and anything else is `error`.
- An app on Ruby below 3.4 can only use `--test-command`, so these apps get a false high score with no in-process path to compare.
- README (lines near 95 and 523) states "A crash in the command can count as a kill." The CLI end-of-run warning (`lib/mutineer/cli.rb`, `--test-command score is an upper bound`) says infra failures score as kills.

## Requirements

- R1. A non-zero exit other than 1 scores `error` with the reason `test-command exited N (only exit 1 counts as a kill; check RSpec --failure-exit-code, a coverage gate, or your wrapper)`. 126/127 keep their "could not start" reason. A signal death keeps its reason. Exception (added in review): when SimpleCov's gate message is present, the summary decides the verdict (see Key Technical Decisions).
- R2. When summary checking is on, exit 1 with no summary line, or with summary lines that report zero failures (and, for Minitest, zero errors), scores `error` with the reason `test-command exited 1 but its output shows no failing test (the suite or the mutant crashed before tests ran; --verbose shows the output)`. Exit 1 with a summary line that reports at least one failure (Minitest failures or errors; RSpec failures) scores `killed`. Exception (added in review): exit 1 after Minitest's `# Running:` line with no summary scores `killed` (see Key Technical Decisions).
- R3. The smoke check reports whether the clean output contains a known summary line. The runner turns summary checking on only in that case. Otherwise it prints one `[mutineer]` stderr line: what happened (no Minitest or RSpec summary line in the clean run), the effect (an exit 1 counts as a kill even if the suite did not load), and the fix (use a formatter that prints the summary line).
- R4. CHANGELOG `## [Unreleased]` gets a `### Fixed` entry that names the contract change, including that an RSpec `--failure-exit-code 3` setup now scores `error` (fix: the default exit code, or a wrapper that maps failures to exit 1), and that more `error` verdicts can now fail a run through the existing no-verdict gate. Repo shape: `- **Bold lead (#292).** prose`.
- R5. README and the CLI warning no longer say a crash can count as a kill; they state the new rule. The CLI warning reads only config, not the calibration result, so its text must hold in both modes: only exit 1 counts as a kill, and when the clean run printed a Minitest or RSpec summary, the exit 1 output must also show a failing test.

---

## Key Technical Decisions

- **Exit 1 only, like `Isolation.decode`.** Minitest, Rails `bin/rails test`, and RSpec all exit 1 on a failing test by default. A wrapper that maps a signal to 128+N, a crash code, or a custom failure code is not proof that a test caught the mutant. Scoring it `error` is the safe direction: it lowers no score falsely and the no-verdict gate surfaces it.
- **Summary lines recognised.** Minitest 5 and 6 print `N runs, N assertions, N failures, N errors, N skips`; minitest-reporters prints `N tests, ...` with the same tail. RSpec prints `N examples, N failures` (singular forms for 1), with an optional `, N errors occurred outside of examples`. ANSI colour codes are stripped before matching, so a coloured line still matches.
- **"Reports a failure" rather than "has a summary line".** An RSpec spec file that raises while loading prints `0 examples, 0 failures, 1 error occurred outside of examples` and exits 1. Matching only the presence of a line would still score that `killed`, which is the same failure #246/#269 fixed in process. Requiring failures (or Minitest errors) above zero mirrors `TestRunners::RSpec.failure_code`. A Minitest `errors` count stays a kill: the in-process Minitest path also counts a test that raised as a failure.
- **A mutant that crashes the suite at load scores `error`.** The smoke check proved the clean tree loads, so an exit 1 with no summary after a green smoke is often the mutant itself (a method called from a class body or initializer). No test assertion caught it, so it is not a kill. This matches the in-process RSpec rule from #246 (an error outside examples scores `error`). The reason string names both causes.
- **Exit during tests stays a kill (added in review).** Minitest prints `# Running:` after every test file loads. Exit 1 after it with no summary line means code under test called `exit 1` or `abort`; in process that is a kill, so it stays `killed` here too. A load crash ends before that line.
- **A SimpleCov gate exit follows the summary (added in review).** SimpleCov `minimum_coverage` can replace the exit code with 2. Under Minitest its plugin runs the gate in `Minitest.after_run`, even after a failing test. So when SimpleCov's `SimpleCov failed with exit N due to a coverage related error` line is present, the summary decides: a failing test is `killed`, and a recognized passing summary is `survived` (in process the fork exits before that hook). With no recognized summary line, the exit scores `error`, because a failing run cannot be ruled out. Without SimpleCov's line, a non-1 exit stays `error`: RSpec prints `N examples, 0 failures` even when code under test calls `exit 2` mid-example.
- **Any matching line counts.** A wrapper that runs two suites prints two summary lines; a kill in either is a kill. Ceiling: a test that prints a fake summary line to stdout fools the check. That is acceptable and named in a plain code comment (the repo does not use tool-specific comment prefixes).
- **Calibration lives in the smoke check.** `smoke_check!` already captures the clean output. It returns `[elapsed_seconds, summary_seen]` (YARD `Array(Float, Boolean)`, the tuple idiom `wait_with_timeout` uses). Its only caller is `Runner` (runner.rb, the smoke call), and the daemon contract tests stub it with a lambda that never returns, so a pair is safe. The runner passes the flag to `ExternalBackend.run` as `check_summary:` (named like `verbose:`). The keyword defaults to false, so a direct caller of `run` keeps the exit-code-only rule from step 1.
- **Encoding.** Match against a binary copy of the output so a suite that prints non-ASCII bytes under an unset locale cannot raise `invalid byte sequence`.

---

## Implementation Units

### U1. Exit-code rule and summary check in the external backend

**Goal:** `ExternalBackend.run` follows R1 and R2; `smoke_check!` reports summary presence (R3 backend half).

**Requirements:** R1, R2, R3

**Dependencies:** none

**Files:** `lib/mutineer/external_backend.rb`, `test/external_backend_test.rb`

**Approach:**
- Add two documented regex constants (Minitest, RSpec) and two documented private-API predicates: one for "a summary line is present", one for "a summary line reports a failure".
- In `run`, after the existing 0 / signal / 126-127 branches: a code other than 1 returns `error` naming the code; exit 1 with checking on and no reported failure returns `error`; otherwise `killed`. The two review-added exceptions in Key Technical Decisions (SimpleCov gate exit, exit during tests) take precedence over these rules.
- `smoke_check!` returns the elapsed seconds and the summary flag together; update its YARD `@return`.
- Update the module docstring that says the backend cannot tell an infra error from a kill.

**Patterns to follow:** existing `CANNOT_RUN_CODES` constant and comment style; `Isolation.decode` reason strings.

**Test scenarios:**
- Exit 3 and exit 137 score `error`, not `killed` (replaces `test_other_nonzero_is_killed`).
- Exit 1 with no output and checking off scores `killed` (keeps `test_exit_one_is_killed`).
- Checking on: exit 1 with no summary line scores `error`.
- Checking on: exit 1 printing `1 runs, 1 assertions, 1 failures, 0 errors, 0 skips` scores `killed`; same with `0 failures, 1 errors`.
- Checking on: exit 1 printing `3 tests, ...` (minitest-reporters form) with a failure scores `killed`.
- Checking on: exit 1 printing `2 examples, 1 failure` scores `killed`.
- Checking on: exit 1 printing `0 examples, 0 failures, 1 error occurred outside of examples` scores `error`.
- Checking on: exit 1 printing a summary line with non-ASCII bytes around it does not raise.
- Checking on: exit 1 printing a summary line wrapped in ANSI colour codes scores `killed`.
- Reason strings: assert `details` for exit 3 and for exit 1 with no failing summary.
- Summary formats are literal strings checked against the gem sources: Minitest 5.25 and 6.0 `lib/minitest.rb` (`%d runs, %d assertions, %d failures, %d errors, %d skips`) and rspec-core 3.13 `Notifications::SummaryNotification#totals_line`. No real-RSpec child run: `child_env` clears `BUNDLE_*`/`GEM_*`, so rspec is not loadable in the child under a CI vendor bundle.
- `smoke_check!` on a green run with a Minitest summary returns the flag true; with no output returns false; elapsed is still a Float.

**Verification:** the external backend test file passes; YARD strict passes.

### U2. Runner calibration and one warning

**Goal:** the runner turns summary checking on from the smoke result and warns once when it cannot (R3).

**Requirements:** R3

**Dependencies:** U1

**Files:** `lib/mutineer/runner.rb`, `test/runner_external_test.rb`

**Approach:** unpack the smoke result; when no summary line was seen, print one `[mutineer]` stderr warning that names the consequence (an exit 1 counts as a kill even if the suite did not load); pass the flag through `run_external` to `ExternalBackend.run`.

**Test scenarios:**
- End to end, the strong fixture (`ruby calculator_strong_test.rb`, Minitest autorun) still scores 100% and prints no summary warning.
- End to end, a command whose clean run prints no summary (the existing probe-script test) prints the warning exactly once.
- End to end, a mutant run that exits 1 with no summary scores `error` when the clean run had a summary. Use a small wrapper script that runs the suite on the clean tree and exits 1 silently when the source is mutated (detect by reading the source file).

**Verification:** runner external tests pass; the AGENTS.md local gate passes (`rake test`, load smoke, `yard:strict`), and the suite passes under `gemfiles/minitest6.gemfile` (the Minitest 5 and 6 summary lines are identical; the U1 literal-string tests cover the format).

### U3. Contract text: CHANGELOG, README, CLI warning

**Goal:** R4 and R5.

**Requirements:** R4, R5

**Dependencies:** U1, U2

**Files:** `CHANGELOG.md`, `README.md`, `lib/mutineer/cli.rb`

**Approach:** add `### Fixed` under `## [Unreleased]`. Replace both README "A crash in the command can count as a kill." lines and merge the 126/127 line into the new rule. Reword the CLI warning and its comment; keep the phrase "upper bound" (a test asserts it).

**Test expectation:** none beyond the existing `upper bound` assertion and docs contract tests; this unit changes text only.

---

## Scope Boundaries

- No change to the in-process or `--daemon` backends.

### Deferred to Follow-Up Work

- #296: the same failure class on `--daemon`.
- #283: `--baseline` has no completeness gate, so more `error` verdicts raise its stakes.
- A parity test (fixture app scored in process and through `--test-command`, same counts), the gate the issue names. The calculator fixture has no load-time crash, so it would not exercise this fix; it belongs with #296.
- An infra failure that starts mid-run and makes every test error in setup still prints `N errors` and scores `killed`. Steps 1 to 3 do not close that path.
- The issue's "warn when 100% killed with near-zero time" heuristic is not needed once crashes score `error`.
- test-unit, Cucumber, or custom formatter summary lines: these fall back to the step 1 rule with the warning.

---

## Risks

- A user with RSpec `--failure-exit-code N` (N not 1) sees every kill become `error` and may fail the no-verdict gate. Mitigated by the CHANGELOG entry; the fix for them is the default exit code or a wrapper that maps to 1.
- A formatter that prints a summary on the clean run but not on a failing run would turn kills into `error`. No known formatter does this.
