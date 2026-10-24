---
title: "fix: Run the Minitest clean check and the mutant runs with one seed"
type: fix
date: 2026-10-24
issue: 282
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
depth: lightweight
---

# fix: Run the Minitest clean check and the mutant runs with one seed

## Summary

Every Minitest run that Mutineer starts (all backends except `--test-command`, which runs the user's own command) uses one seed: `SEED` from the
environment when it is set, else the pinned seed `1`. Today only the
in-process mutant run (stop or matrix hook armed) pins the seed. Coverage
capture, the clean checks and the `--daemon` mutant run use a random seed.

## Problem Frame

An order-dependent Minitest suite can pass the random clean check and then
fail under seed 1 in every in-process mutant run. Each mutant then scores
`killed` (a false kill). Reproduced on main with a two-test fixture: in six
runs, two aborted with `SmokeCheckError` and four scored the `a + b` mutant
`killed`. The verdict depends on luck, and a green clean check proves nothing
about the order the mutant runs use.

## Requirements

- R1. Coverage capture and every clean check (fork path and subprocess path)
  run Minitest with the same seed as the in-process mutant run.
- R2. The `--daemon` mutant run uses that seed too, so each mutant fork gets
  the same order (and matches the daemon's fork-path clean check).
- R3. `SEED` in the environment still wins on every path.
- R4. The seed lives in one place. The subprocess scripts and the daemon read
  it from there.
- R5. An order-dependent fixture that fails under the pinned seed now aborts
  with `SmokeCheckError` on every run.

## Key Technical Decisions

- **One helper in `MinitestIntegration`: `seed_args`.** It returns the
  `Minitest.run` arguments as `Array<String>`: empty when `ENV["SEED"]` is set
  (Minitest reads it itself and applies its own `% 0xFFFF`), else
  `["--seed", PINNED_SEED.to_s]`. Marked `@api private` (cross-file internal,
  like `keep_file_order`). All four call sites use it. Rationale: one source of
  truth, smallest diff at each site. Rejected: `ENV["SEED"] ||= "1"` in the
  parent, because a library that writes the user's environment is a hidden
  side effect.
- **Rename the constant** `STOP_AT_FIRST_FAILURE_SEED` to `PINNED_SEED`. It is
  no longer tied to the stop. No alias: the class is documented as
  child-process-only, and its readers are the seed expression in
  `minitest_integration.rb` (replaced by `seed_args`) and this repo's tests.
- **Subprocess scripts interpolate the helper result** at build time
  (`Minitest.run(<args>.inspect)`). The child inherits the parent's
  environment, so the build-time `SEED` check gives the same answer.
- **Every Minitest entry point starts from an empty class list.** Minitest
  shuffles `Minitest::Runnable.runnables` with the seed before it runs a
  class. `MinitestIntegration.run` resets that list, but the two subprocess
  scripts do not (their list still holds `Minitest::Test`), and neither does
  `DaemonServer.run_tests`. With the same seed, `[Minitest::Test, A, B]` and
  `[A, B]` shuffle to different class orders, so a file with two
  order-dependent classes would still differ. The two scripts add
  `Minitest::Runnable.reset` before their test `load` lines (after the
  preloads, as `MinitestIntegration.run` resets after boot).
- **The daemon mutant run calls `MinitestIntegration.run`.** `run_tests` drops
  its early `rails/test_help` require (the test files' `require "test_helper"`
  loads it after the reset, as in the daemon's clean-check forks; requiring it
  first would register Rails test base classes only on the clean-check side,
  found in code review) and delegates to
  `MinitestIntegration.run(tests)` with no hook. That gives the reset, the
  autorun guard and the seed in one place, and the daemon's mutant run then
  matches its own fork-path clean check, which already goes through the same
  method. The 0/1 return contract is the same.
- **Daemon requires `minitest_integration` lazily** inside `run_tests`. That
  file and its requires are stdlib only (`json`), and `build_coverage_map`
  already loads it lazily through `coverage_map`. The lazy require in
  `run_tests` covers a daemon that never built a map. This keeps the daemon's
  no-Prism load constraint.
- **Do not change `keep_file_order`.** It stays armed-only. Class order across
  several files is a separate, smaller gap (see Scope Boundaries).
- **CHANGELOG:** add a `### Fixed` entry under `[Unreleased]`. Do not rewrite
  the 1.1.0 note: it described 1.1.0 correctly, and Keep a Changelog keeps
  released entries as history. The new entry says what changed and names the
  gap that stays (class order across several covering files). It does not
  claim the whole 1.1.0 caveat is gone.
- **Seed hint in the abort message.** The fix turns a silent false kill into a
  `SmokeCheckError`. A user whose `rake test` passes in a random order would
  not know why. For Minitest, the "not green" message names the seed and how
  to reproduce it (`SEED=1`) or pick another (`SEED=<n>`).

## Scope Boundaries

- **RSpec stays out of scope.** RSpec passes no `--seed` on any path
  (`lib/mutineer/test_runners/rspec.rb`). With a defined order, the clean
  check and the mutant runs share it. With `config.order = :random`, each
  process picks its own seed, so the same false-kill hazard exists there, plus
  the `killed` vs `timeout` flip the issue names. That needs its own design
  (pin RSpec's seed or respect the user's) and stays for a follow-up issue,
  as the issue comment suggests. The PR body says so.
- The `--test-command` backend runs the user's own command and stays as is.
- `i_suck_and_my_tests_are_order_dependent!` is not used in the fixture: it
  sorts by name and ignores the seed.

### Deferred to Follow-Up Work

- Class order across files: when a mutant runs several covering files, the
  mutant run keeps file order and seeds the shuffle over a different class
  list than the combined clean check. Method order inside a class depends only
  on the seed, so one-file selections match. Mention in the PR body as the
  remaining gap.

## Implementation Units

### U1. Shared seed helper and in-process run

**Goal:** Every `MinitestIntegration.run` call pins the seed unless `SEED` is set.

**Requirements:** R1, R3, R4

**Dependencies:** none

**Files:** `lib/mutineer/minitest_integration.rb`,
`test/test_runners/minitest_test.rb`, `test/runner_test.rb`

**Approach:** The fork-path capture and clean checks reach this method
through `TestRunners::Minitest.run`, so they need no edit of their own.
Rename the constant, add `seed_args` with YARD docs
(`@api private`, `@return [Array<String>]`), and replace the armed-only seed
expression with it. Update the constant comment and the inline comment near
the `Minitest.run` call (an unknown Minitest shape now also gets the pinned
seed).

**Test scenarios:**
- A plain run (no stop, no matrix) records `Minitest.seed` equal to the pinned
  seed (fork, `SEED` unset).
- A plain run with `SEED=4242` records `4242`.
- Existing stop and matrix seed tests still pass with the renamed constant.

**Verification:** The seed tests pass on Minitest 5 and Minitest 6, and the
AGENTS.md local gate passes (`rake test`, load smoke, `yard:strict`).

### U2. Subprocess capture and clean-check scripts

**Goal:** `minitest_subprocess_script` and `minitest_clean_check_script` in
`lib/mutineer/coverage_map.rb` pass the helper result to `Minitest.run`.

**Requirements:** R1, R5

**Dependencies:** U1

**Files:** `lib/mutineer/coverage_map.rb`, `test/runner_test.rb`

**Approach:** In each script, pass `seed_args` to `Minitest.run` and add
`Minitest::Runnable.reset` before the test `load` lines. No other edit to
`coverage_map.rb` (draft PR #202 also edits this file).

**Test scenarios:**
- Covers R5. Fixture (written in a tmpdir, like the sibling runner tests):
  `test_a` asserts a global that `test_b` sets; `test_b` calls `add` with no
  assertion. With `SEED` unset (delete it, restore it after), `Runner.execute`
  raises `SmokeCheckError` on each of three runs (subprocess capture path).
  Three runs make the "fails on main" check likely to catch the bug (the
  repro aborted in two of six runs). Seed 1 runs `test_a` first on both
  Minitest 5 and Minitest 6 (checked).
- The clean-check script alone (`subprocess_clean_pass?` on the same fixture)
  returns false on each of three runs.
- One file with two order-dependent classes: the subprocess clean check and
  an in-process `MinitestIntegration.run` of that file agree (both fail, or
  both pass) under the pinned seed.

**Verification:** Both scenarios fail on main and pass after the change.

### U3. Daemon mutant run

**Goal:** `DaemonServer.run_tests` delegates to `MinitestIntegration.run`.

**Requirements:** R2, R3

**Dependencies:** U1

**Files:** `lib/mutineer/daemon_server.rb`, new `test/daemon_seed_test.rb`
(default suite, Rails-free; `send(:run_tests, ...)` style as in
`test/daemon_redaction_test.rb`)

**Approach:** `require_relative "minitest_integration"` inside `run_tests`,
drop the early `rails/test_help` require, then return
`MinitestIntegration.run(expanded test paths)`.

**Test scenarios:**
- In a fork (setpgid, silenced stdout, `exit!` with the return code, as
  `fork_status` in `test/test_runners/minitest_test.rb` does) with
  `@framework` set to `"minitest"` and `SEED` unset, `run_tests` on
  `test/fixtures/stop_at_first_failure_seed_test.rb` writes the pinned seed to
  the marker. The reset inside `MinitestIntegration.run` keeps the fork from
  running the loaded Mutineer suite.

**Verification:** The test passes in the default suite; `rake test:daemon`
still passes where the machine can run it.

### U5. Seed hint in the abort message

**Goal:** The "not green" `SmokeCheckError` for a Minitest run names the seed.

**Requirements:** R5

**Dependencies:** U1

**Files:** `lib/mutineer/job_plan.rb`, `lib/mutineer/runner.rb`,
`lib/mutineer/daemon_backend.rb`, `test/runner_test.rb`

**Approach:** `JobPlan.abort_if_unclean!` takes an optional `framework:`
keyword. For `"minitest"`, the message appends a hint that names the seed
the runs used (`MinitestIntegration.seed`: `SEED` when set, else
`PINNED_SEED`). It tells the user to run the listed test files with that
seed to look for the order-dependent test (all of them together for
"combined suite"), or to set `SEED` to pick another order. Changed in
review: the first draft always named seed 1, which was wrong when `SEED` is
set. `seed_args` is built on `seed`, so both use one rule. Both callers pass
`config.framework`. Other frameworks keep today's text.

**Test scenarios:**
- Minitest: the U2 fixture's `SmokeCheckError` message includes the seed
  hint.
- No framework given: the message is unchanged (existing tests still pass).

**Verification:** `test/daemon_backend_contract_test.rb` still passes
(`abort_if_unclean!` stays public).

### U4. CHANGELOG

**Goal:** Users learn that the clean check and the mutant runs share one seed.

**Requirements:** R1, R2

**Dependencies:** U1 to U3, U5

**Files:** `CHANGELOG.md`

**Approach:** New `### Fixed` heading under `[Unreleased]`. Bold lead ending
in `(#282)`, as the existing Fixed entries do. Body: the shared seed, the
`SEED=1` check and `SEED=<n>` hint, and the multi-file class-order gap.

**Test expectation:** none (docs only).

## Risks

- A suite that is order-dependent under seed 1 now aborts with
  `SmokeCheckError` instead of scoring. This is the intended fix, but it can
  look like a new failure. The CHANGELOG line says how to check (`SEED=1`) and
  how to pick another seed (`SEED=<n>`).
- Coverage capture now runs in a fixed order. State that leaks between tests
  can change which branches run, so a map can differ from one built under a
  random seed. Pinning makes the map more deterministic; a cache hit still
  re-runs the clean checks, so an old cache cannot hide the new abort.
- The daemon change routes the Rails mutant run through
  `MinitestIntegration.run`. Run `rake test:daemon` where the machine allows,
  and say in the PR body if it could not run.
- The deferred RSpec and multi-file gaps need tracking issues once #282
  closes. Filing them is for the maintainer to approve; the PR body names
  both.
