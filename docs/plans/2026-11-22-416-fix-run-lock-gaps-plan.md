---
title: Close two run-lock gaps for daemon runs in 1.10.0 - Plan
type: fix
date: 2026-11-22
issues: [416]
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

**Suggested build:** Opus 5.5, effort medium. The plan settles the design. Two small edits in one file carry the change.

# Close two run-lock gaps for daemon runs in 1.10.0 - Plan

## Goal Capsule

- **Issue:** #416 (run-lock gaps left after #404, the SQLite run lock).
- **Objective:** two `--rails --daemon` runs in one checkout never share worker databases when the first daemon fails to boot, or when the only worker of a `--jobs 1` run crashes. The second run stops with "another Mutineer run is using <database>", as it does today in the normal case.
- **Means:** keep a lock holder alive for the whole daemon run (KTD1, KTD2). No change to `lib/mutineer/rails_worker_db.rb` or `lib/mutineer/daemon_server.rb`.
- **Authority:** this plan, then `AGENTS.md`, then the issue text.
- **Stop and ask when:** a change would need an edit to `rails_worker_db.rb` or `daemon_server.rb`. The held 2.0 pull requests #244, #245 and #335 rewrite those files. Also stop when a run on its own would get a different verdict, score or exit code.
- **Execution profile:** one pull request. Labels: `enhancement`, `priority: low`, `risk: medium`, `v1.10.0`. Body: `Refs #416`, not `Closes`: gaps 1 and 2 stay open on #416.
- **Size:** S. One `lib/` file (`lib/mutineer/daemon_backend.rb`), two test files, `docs/rails-setup.md`, `CHANGELOG.md`.
- **Release and semver:** a fix inside the 1.10.0 minor batch. No GitHub Action default changes. No agent tags or publishes.

---

## Product Contract

### Summary

Issue #416 lists five gaps. Gap 5 (`file:` URI names) shipped in #412. This plan closes gap 3 (a first daemon that fails to boot) and gap 4 (the `--jobs 1` respawn window). Both fixes live in `DaemonBackend` and reuse the existing "prepare" daemon role. Gap 1 (in-process `--rails` runs take no lock) and gap 2 (the lock is taken after boot and `--require` files) wait for the 2.0 database work. The reasons are in Scope Boundaries.

### Problem Frame

A daemon run takes its run lock in two steps. The first daemon (the "prepare" daemon) boots with Coverage, takes the exclusive lock at `provision`, then holds it shared (`lib/mutineer/daemon_backend.rb:168-197`, `lib/mutineer/rails_worker_db.rb:302-339`). Each worker daemon takes the shared lock at boot (`lib/mutineer/rails_worker_db.rb:350-372`, `lib/mutineer/daemon_server.rb:236-244`). A second run cannot get the exclusive lock, so it stops.

Two paths leave no exclusive lock behind:

- **Gap 3.** When the prepare daemon fails to boot, `prepare_run` returns no client (`lib/mutineer/daemon_backend.rb:172-181`). Nothing calls `provision`. The worker daemon boots with `db_role: "worker"` and takes only the shared lock. Two such runs both get a shared lock and both use the same worker database (`storage/test-0.sqlite3` for SQLite, slot 0 for Postgres and MySQL).
- **Gap 4.** `run_serial` quits the prepare daemon as soon as its worker boots (`lib/mutineer/daemon_backend.rb:303-309`). If that worker crashes, `DaemonClient#restart!` respawns it (`lib/mutineer/daemon_client.rb:408-418`). Between the crash and the respawn, the run holds no lock. A second run can take the exclusive lock, provision, and drop to shared. The respawned worker then takes its shared lock beside that run. Both runs now write the same worker database.

Either case can bring back the false "the unmutated suite is not green" result from #404, or a wrong verdict. No real report shows this harm yet (issue text). The fixes are cheap, so 1.10.0 closes them.

### Requirements

**Gap 3: a first daemon that fails to boot**

- R1. When the prepare daemon of a `--rails` daemon run fails to boot, Mutineer boots one more prepare daemon without Coverage. When that daemon boots, it provisions the worker databases and holds the lock as in the normal case.
- R2. When that second daemon also fails to boot, the run behaves as today: one worker, the full `--test` set per mutant, and exactly today's stderr lines. The retry failure adds no line: one "daemon coverage map unavailable" warning and one "could not list this app's databases (the first daemon did not boot)" warning, as `test_a_failed_first_boot_keeps_one_worker_on_rails` asserts (`test/daemon_backend_contract_test.rb:169-188`).
- R3. A run whose first daemon fails keeps today's verdicts and score for a run on its own. It still prints the "daemon coverage map unavailable" warning. When the retry boots, the worker count follows `--jobs` and the database report (KTD3), not today's forced single worker. Parallel verdicts equal `--jobs 1` verdicts, so the score stays the same.

**Gap 4: the `--jobs 1` respawn window**

- R4. A serial `--rails` daemon run (`--jobs 1`, `--fail-fast`, or a forced single worker) keeps the prepare daemon alive until the last mutant ends. The `ensure` in `run_serial` quits it. A `--boot` run without `--rails` has no database lock, so it quits the prepare daemon early, as today.
- R5. A run on its own keeps today's verdicts, score and exit code with `--jobs 1` and with `--jobs N`.

**Docs**

- R6. `docs/rails-setup.md` (the "SQLite lock file" row, line 159) names the gaps that remain and links #416: in-process `--rails` runs; the lock taken after boot and `--require` files; and a run where both prepare boots fail but a worker boots, which then holds only the shared lock. (A worker uses the same plain boot as the retry, so that last case needs a boot that fails once and then works.) `CHANGELOG.md` gets a "Fixed" entry under "Unreleased".

### Acceptance Examples

- AE1. **Covers R1.** Given a `--rails` daemon run whose Coverage daemon fails to boot and whose plain boot works, when `prepare_run` runs, then it returns `[nil, <count>, <client>]`, and that client received `provision`.
- AE2. **Covers R2.** Given both boots fail (today's contract test `test_a_failed_first_boot_keeps_one_worker_on_rails`), then `prepare_run` still returns `[nil, 1, nil]` for `--rails` and `[nil, 4, nil]` without it.
- AE3. **Covers R4.** Given a serial `--rails` run with a stub prepare client and a stub worker, when the run ends, then the prepare client got `quit` only after the last `job_result`. Without `--rails`, it got `quit` right after the worker started.
- AE5. **Covers R3.** Given the Coverage boot fails, the retry boots and reports one database, and `--jobs 4` with 4 or more jobs, then `prepare_run` returns a worker count of 4.
- AE4. **Covers R5.** `test/runner_daemon_parallel_test.rb` `test_strong_suite_jobs2_equals_jobs1_and_scores_100` and `test/daemon_worker_db_test.rb` `test_overlapping_sqlite_runs_stop_and_keep_the_same_verdicts` stay green unchanged.

### Scope Boundaries

Considered and deferred to 2.0 (they stay open on #416):

- **Gap 1: a lock for in-process `--rails` runs.** In-process runs use the base database directly and load no worker-database code. A lock there would make two in-process runs stop each other, which is a new exit-code behavior. Held PR #245 makes the daemon the default for Minitest `--rails` runs, which removes most of this gap. Decide after #245 lands.
- **Gap 2: take the lock before boot and `--require` files.** The lock needs the app's database config, which exists only after the boot. Taking it before `--require` files means splitting "lock" from "copy" in `provision_postgres` and `provision_mysql`, and reordering `DaemonServer#boot`. Held PRs #244, #245 and #335 rewrite both files. The harm is narrow: a `--require` file of the second run that writes the base database while the first run seeds a slot.

Considered and not built:

- **Keep the prepare daemon alive in parallel runs too.** In a parallel run, each worker holds a shared lock. One crashed worker leaves the others holding it, so the window needs every worker to crash at once.
- **A new daemon role that provisions at worker boot (gap 3).** A respawn would provision again. For Postgres that drops slot 0 while an orphaned mutant child of the crashed worker may still hold a connection, so the respawn fails. KTD1 reuses the existing "prepare" role instead.
- **Stop the run when the first daemon fails to boot.** The issue suggests "an error path". That changes the exit code of runs that work today. R2 keeps them.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Gap 3 retries the prepare daemon without Coverage.** In the `rescue DaemonBootError` branch of `prepare_run`, when `config.rails` is set, start `DaemonClient.new(boot: boot_config(config, abs_tests, db_role: "prepare"), ...)`. `coverage:` stays false, so the daemon starts no Coverage. On success, run the same lines as the normal path: `worker_count_for(client.databases, ...)`, then `client.provision(worker_count)`, then return `[nil, worker_count, client]`. On a second `DaemonBootError`, return today's value. A `DaemonBootTimeout` still raises. Why: this reuses the only code path that takes the exclusive lock, with no new daemon role and no change to `daemon_server.rb`.
- KTD2. **Gap 4 keeps the prepare daemon until a serial `--rails` run ends.** In `run_serial`, quit `prepare_client` after the worker boots only when `config.rails` is false. The existing `ensure` quits it otherwise. Why: the prepare daemon holds the shared lock, so a respawned worker never runs while another run holds the exclusive lock. The cost is one idle booted app process for the length of a serial `--rails` run. A parallel run already holds N+1 processes during worker boot. A `--boot` run without `--rails` takes no lock, so it does not pay this cost.
- KTD3. **The fallback daemon's worker count follows its database report.** With KTD1, the daemon lists the databases, so `worker_count_for` can allow more than one worker. That matches a normal run with an empty map. Today's forced single worker stays only when both boots fail.
- KTD4. **No change to the lock code or to daemon boot order.** All edits stay in `lib/mutineer/daemon_backend.rb` (`prepare_run`, `run_serial`, and their YARD comments). This keeps the conflict with held PRs #245 and #335 to a few lines.

### Assumptions

- A boot without Coverage can work when a boot with Coverage fails. Example: a gem that breaks under `Coverage.start` before boot. When both fail, KTD1 costs one more failed boot. Boot timeouts still raise at once.
- An idle prepare daemon uses about the memory of one worker daemon. It forks nothing while idle.

### Sequencing

U1, U2 and U3 can run in any order. They ship in one pull request.

Group F PR A (#496, plan `docs/plans/2026-11-22-496-494-feat-since-capture-and-pack-pairing-plan.md`) gives `boot_config` a `sources:` keyword and narrows `abs_tests` in `DaemonBackend.execute`. `prepare_run` passes those values to its boot. The KTD1 retry must pass the same `abs_tests` and `sources:` as the first boot. Land this pull request first: it is smaller. The builder of Group F PR A then rebases and threads the narrowed lists into both boots in `prepare_run`.

---

## Implementation Units

### U1. Retry the prepare daemon without Coverage (gap 3)

- **Goal:** a first daemon that fails to boot still leaves one process holding the exclusive lock (R1, R2, R3).
- **Files:** `lib/mutineer/daemon_backend.rb` (`prepare_run`), `test/daemon_backend_contract_test.rb`.
- **Approach:** KTD1. Extract the provision lines of the normal path into a small private helper only if both paths need them. Otherwise call them inline. Update the `prepare_run` YARD text: "A boot failure retries once without Coverage under `--rails`."
- **Test scenarios:**
  - The stub `DaemonClient.new` raises `DaemonBootError` for a boot config with `coverage: true` and returns a working stub for `coverage: false`. `prepare_run` returns `[nil, n, client]`. The stub recorded `provision(n)` and the second boot config has `db_role: "prepare"` (AE1).
  - Both boots raise. Today's test `test_a_failed_first_boot_keeps_one_worker_on_rails` passes unchanged, including its exact warning counts (AE2, R2). Without `--rails`, no second boot happens.
  - The retry boots with one database and `--jobs 4`: worker count 4 (AE5).
  - The retry raises `DaemonBootTimeout`. `prepare_run` raises it.
  - `provision` raises on the retry client. The client gets `quit` and the error propagates, as in the normal path.
- **Verification:** `bundle exec rake test`. `bundle exec rake test:daemon` runs the SQLite daemon tests.

### U2. Keep the prepare daemon through a serial run (gap 4)

- **Goal:** a serial run holds the lock across a worker respawn (R4, R5).
- **Files:** `lib/mutineer/daemon_backend.rb` (`run_serial`), `test/daemon_backend_contract_test.rb`.
- **Approach:** KTD2. Guard the early `prepare_client&.quit` and `prepare_client = nil` with `unless config.rails`. Update these comments, which say the prepare daemon quits once workers hold locks: `execute` (`lib/mutineer/daemon_backend.rb:80-83` and `:95-96`), `prepare_run`'s `@return` text (`:165-167`), and `run_serial`'s `@param prepare_client` (`:300-301`). New text: "A serial `--rails` run keeps the prepare daemon, and its lock, until the run ends."
- **Test scenarios:**
  - Stub prepare and worker clients record calls in one shared log. After `run_serial` with `rails: true`, the log shows every `job_result` request before the prepare client's `quit` (AE3). With `rails: false`, `quit` comes right after the worker's `start`. This asserts the mechanism, per the "Assert the mechanism" rule in `.expectation-fit/ways-of-working.yaml`.
  - A stub worker whose `run` triggers one `restart!` (respawn) mid-run: the log shows no prepare `quit` before the respawned worker's next request. A real crash-and-race integration test is not added: the window is a few hundred milliseconds and would make a flaky test. The contract test pins the ordering that closes it.
  - A worker boot that raises still quits the prepare client (existing `ensure`).
- **Verification:** `bundle exec rake test`; `bundle exec rake test:daemon` (AE4).

### U3. Docs and CHANGELOG

- **Goal:** users know which gaps remain (R6).
- **Files:** `docs/rails-setup.md` (row "SQLite lock file", line 159), `CHANGELOG.md`.
- **Approach:** the row says the remaining gaps are in-process `--rails` runs and the window before the lock during boot and `--require` files (#416). The CHANGELOG "Fixed" entry says: a daemon run whose first daemon fails to boot now still takes the run lock, and a `--jobs 1` daemon run keeps it while a crashed worker restarts. It notes the costs: a serial `--rails` daemon run now keeps one extra idle app process, and a run whose Coverage boot fails now boots the app once more before it falls back. It also notes that such a run can now use more than one worker when the retry lists the databases. Also edit the #412 entry text only if it is under "Unreleased". It is under 1.9.0, so leave it.
- **Verification:** `bundle exec rake yard:strict`; read both edits against the code.

---

## Verification Contract

- `bundle exec rake test`
- `ruby -Ilib -e 'require "mutineer"'`
- `bundle exec rake yard:strict` (every changed method keeps a complete docstring)
- `bundle exec rake test:daemon` (SQLite fixture app; CI also runs it with `DB=postgres` and `DB=mysql`)
- Author self-check skill (`.claude/skills/author-self-check/SKILL.md`) before the first push.
- No Minitest 6 or Prism 2 run: the change touches neither.

## Definition of Done

- U1 to U3 done, each with its tests green.
- AE1 to AE5 pass.
- `rails_worker_db.rb` and `daemon_server.rb` have no diff.
- A comment on #416 lists the gaps this pull request closed and the three cases that remain (gaps 1 and 2 for 2.0, and the boot that fails twice and then works, R6).
- No leftover experimental code in the diff.

## Open Questions

- **Q1 (David).** Accept one extra idle app process for the length of a serial `--rails` daemon run (KTD2)? **Recommended: yes.** It is the only fix for gap 4 that needs no change to the lock code, and parallel runs already pay the same cost during boot.
- **Q2 (David).** Defer gaps 1 and 2 to the 2.0 database work, with #416 kept open as their tracker? **Recommended: yes.** Both need edits in `rails_worker_db.rb` and `daemon_server.rb`, which three held 2.0 pull requests rewrite, and no report shows harm.
