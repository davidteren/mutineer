---
title: Refuse MySQL before 8.0 and warn on MariaDB under --daemon - Plan
type: fix
date: 2026-10-24
issues: [298]
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Refuse MySQL before 8.0 and warn on MariaDB under --daemon - Plan

## Goal Capsule

- **Issue:** #298 (MySQL 5.7 and MariaDB are named unsupported but still run under `--rails --daemon`).
- **Goal:** `--daemon` reads the MySQL server version before it copies any worker database. It stops the run on MySQL older than 8.0 and prints one warning on MariaDB, MySQL 9, or a version it cannot read.
- **Authority:** this plan, then `AGENTS.md`, then the `**Claude:**` comment on #298. Where this plan differs from the comment, this plan wins (see "Corrections to the issue comment").
- **Stop and ask when:** the check needs a new runtime dependency, a new CLI flag, or a new exit code; or PR #245 (daemon by default for Minitest `--rails`) merges first and turns a provisioning error into a serial fallback (see Risks).
- **Size:** S. Two methods and one call in `lib/mutineer/rails_worker_db.rb`, eight unit tests, one integration assertion, a few doc lines, one CHANGELOG entry.

---

## Product Contract

### Summary

`RailsWorkerDb.provision_mysql` runs `SELECT VERSION()` on the maintenance connection it already opens. A pure method classifies the version text. MySQL older than 8.0 raises the usual provisioning error, so the run stops with exit 1 before any mutant gets a verdict. MariaDB, MySQL 9 or later, or a version the method cannot read prints one warning on stderr, and the run continues.

### Problem Frame

The support matrix in `README.md` says "MySQL 5.7 is not supported" and "MariaDB is not tested". `README.md` also says that "not supported" means `--daemon` cannot run that cell. No code compares the server to the matrix:

- `RailsWorkerDb.per_worker_config` (`lib/mutineer/rails_worker_db.rb:262`) and `RailsWorkerDb.mysql_adapter?` (line 517) check only the adapter name (`mysql2` or `trilogy`).
- `RailsWorkerDb.provision_mysql` (line 823) opens a client at line 831, takes the lock at line 832, and then creates each slot. It never reads the server version.
- `RailsWorkerDb.copy_mysql_rows` (line 1180) rescues and ignores `SET SESSION information_schema_stats_expiry = 0` (line 1185). The comment at line 1187 says MariaDB has no such variable. So the code knows about the gap, but the user never sees it.

The result: a run on MySQL 5.7 or MariaDB starts with no refusal and no warning. The issue comment read the provisioning SQL and found no statement that fails on 5.7 or MariaDB. So the defect is the broken docs contract, not a known wrong verdict.

Why refuse 5.7 and not only warn: below MySQL 5.7.5 a session can hold only one `GET_LOCK` name, and a second call releases the first. `try_mysql_exclusive_lock` (line 959) holds a guard name plus up to 256 pool names on one session, so the run guard would silently break there. For 5.7.5 and later the refusal is a docs-contract choice: MySQL 5.7 reached end of life in October 2023, no CI job runs it, and `README.md:448` asks for `SET_USER_ID`, which only MySQL 8 has. The softer alternative is under Open Questions (OQ5).

### Requirements

- **R1.** On a MySQL server older than 8.0, `--daemon` stops the run before it takes the run lock or creates any worker database. The message names the test database and the server version. The CLI exits 1.
- **R2.** On a MariaDB server, or on MySQL 9 or later, `--daemon` prints one warning on stderr per run and continues. The matrix and CI cover only MySQL 8.
- **R3.** When the version cannot be read (the query fails, or the text has no leading `<major>.<minor>`), `--daemon` prints one warning on stderr and continues.
- **R4.** MySQL 8.x (8.0.x, 8.4.x) runs as today, with no new output.
- **R5.** The decision is a pure method that takes the version string. Unit tests check it without a server.
- **R6.** The README, `docs/rails.md`, `docs/rails.html` and `CHANGELOG.md` describe the new behaviour.

### Acceptance Examples

| `SELECT VERSION()` returns | Classification | User-visible result |
| --- | --- | --- |
| `8.0.36` | `:supported` | no new output |
| `8.0.36-0ubuntu0.22.04.1` | `:supported` | no new output |
| `8.4.0` | `:supported` | no new output |
| `9.1.0` | `:not_tested` | one warning, run continues |
| `5.7.44` | `:not_supported` | run stops, exit 1 |
| `5.7.44-log` | `:not_supported` | run stops, exit 1 |
| `5.6.51` | `:not_supported` | run stops, exit 1 |
| `10.11.6-MariaDB` | `:not_tested` | one warning, run continues |
| `11.4.2-MariaDB-log` | `:not_tested` | one warning, run continues |
| `5.5.5-10.6.12-MariaDB` | `:not_tested` | one warning, run continues |
| `""`, `nil`, `unknown` | `:unreadable` | one warning, run continues |
| query raises (no row) | `:unreadable` (the read passes `nil`) | one warning, run continues |

The MariaDB check runs before the numeric check. MariaDB reports 10.x or 11.x, so a numeric check alone would accept it as "8 or later". The `5.5.5-` prefix row shows that the order also stops a MariaDB string from being refused as 5.x.

### User-visible text (contract)

- Refusal. `provision_mysql` raises a `RuntimeError` with this message: `could not provision <base>: MySQL <version> is not supported. --daemon needs MySQL 8.0 or later. Pass --no-daemon (or daemon: false) to stay serial.` The daemon sends it back as `RuntimeError: could not provision ...` (`DaemonServer#describe_error`, `lib/mutineer/daemon_server.rb:276`). `DaemonClient#provision` raises `DaemonBootError`, and `CLI.run` prints it and exits 1 (`lib/mutineer/cli.rb:367`). The full stderr line is: `mutineer: RuntimeError: could not provision app_test: MySQL 5.7.44 is not supported. --daemon needs MySQL 8.0 or later. Pass --no-daemon (or daemon: false) to stay serial.` This is the same path, prefix and exit code as the existing `another Mutineer run is using <base>` stop. The `RuntimeError:` prefix is on every provisioning error today. This plan keeps it, so all provisioning errors read the same. The workaround names both `--no-daemon` and `daemon: false`, like `Config.warn_rails_default_change` (`lib/mutineer/config.rb:280`), because a user may have turned the daemon on in `.mutineer.yml` and never typed `--daemon`.
- Not-tested warning (MariaDB, or MySQL 9 or later): `[mutineer] <version> is not tested with --daemon. The run continues. If a result looks wrong, pass --no-daemon.` `<version>` is the text the server sent, for example `10.11.6-MariaDB` or `9.1.0`.
- Unreadable warning: `[mutineer] could not read the MySQL server version (got <shown>). The run continues. --daemon is tested on MySQL 8.` `<shown>` is the text in double quotes, or `nothing` when the text is empty or the query failed.
- No new exit code, CLI flag, config key or JSON field. The JSON report is not written, because the run stops before scoring.

### Scope Boundaries

- The check covers every `--daemon` run on `mysql2` or `trilogy`, with `--rails` or `--boot`. Both reach `RailsWorkerDb.provision`.
- `--rails` without `--daemon` does not provision worker databases and stays unchanged. The matrix says that path is serial on every row.
- PostgreSQL and SQLite get no version check.
- `prepare_mysql_worker!` (line 867) gets no check. A worker daemon starts only after the prepare daemon ran `provision_mysql`, so the check runs once per run.
- No escape hatch (env var or flag) to force a 5.7 run. `--no-daemon` (or `daemon: false`) is the documented workaround.

### Deferred to Follow-Up Work

- A CI job on MariaDB that would let the matrix say "supported". That needs its own issue.
- Warnings for other MySQL-compatible servers that report 8.x (for example TiDB, `8.0.11-TiDB-v7.5.0`). See Open questions.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Check before the lock.** The check runs right after `open_mysql_connection` (line 831) and before `try_mysql_lock` (line 832). A refusal then holds no lock and drops no database. The comment suggested "before the first `recreate_mysql_database`". Before the lock is earlier and leaves less to undo. (`remember_mysql_base_config` at line 829 still runs first. That is harmless, because the daemon exits after a provisioning error.)
- **KTD2. Symbol result, messages in the caller.** `mysql_version_support(version)` returns one of `:supported`, `:not_supported`, `:not_tested`, `:unreadable`. The names match the matrix words: MySQL 8 is supported, MySQL 5.7 is not supported, and MariaDB and MySQL 9 have no CI job, so they are not tested. One return type on every branch keeps the method predictable and the tests short. The messages live in the caller, so the pure method has no I/O.
- **KTD3. Close and raise in `provision_mysql`, like the lock miss.** A helper `check_mysql_server(conn)` reads the version, classifies it, prints the warning for `:not_tested` or `:unreadable`, and returns the refusal text for `:not_supported` (else `nil`). It never closes `conn` and never raises. `provision_mysql` then closes `conn` and raises `could not provision <base>: <refusal>`, in the same shape as the lock miss at lines 832 to 835. So the method that opened the connection is the method that closes it.
- **KTD4. Read the version with SQL, not client metadata.** Use the existing `mysql_rows(conn, "SELECT VERSION() AS version")` helper (line 1519). It already handles the row shapes of `mysql2` and `trilogy`, and the alias gives a lowercase key. Client metadata (`Mysql2::Client#server_info`, `Trilogy#server_version`) differs per client.
- **KTD5. Parse with a regex and `to_i`.** Read the major number with `\A(\d+)\.\d+`. Use `to_i`, not `Integer()`, because `Integer("08")` raises.
- **KTD6. Refusal message starts with `could not provision`.** Every other provisioning error uses that prefix. The raise sits before the `begin` block of `provision_mysql`, so no rescue there wraps it. `provision_wrapped?` (line 1562) would also treat it as already wrapped.
- **KTD7. "Warn once" needs no memo.** `provision_mysql` runs once per run, in the prepare daemon (`DaemonBackend.prepare_run`, `lib/mutineer/daemon_backend.rb:183`). A respawned worker uses the `worker` role and does not provision (`DaemonServer#setup_worker_db`, `lib/mutineer/daemon_server.rb:197`). `warn` in the daemon reaches the user's stderr through the client's drain thread, the same way the existing `provisioned N mysql worker database(s)` line does.
- **KTD8. An unreadable version warns, it does not refuse.** This covers a text with no leading number and a `SELECT VERSION()` that raises. The read rescues `StandardError` and passes `nil` to the pure method, so both cases take one path. The matrix names no rule for them, and a refusal could block a real MySQL 8 server behind a proxy. If the connection is really broken, the lock query fails next and stops the run with the existing error. The alternative is under Open questions.

### Assumptions

- `SELECT VERSION()` works for any account that can log in. It needs no privilege.
- On `trilogy` and `mysql2`, the aliased column comes back under the key `version` after `stringify_mysql_row` downcases it. U2 proves this against a real MySQL 8 server on both clients.

---

## Implementation Units

### U1. Version check in `provision_mysql`

**Goal:** Refuse MySQL before 8.0 and warn on MariaDB or an unreadable version, before the lock.

**Requirements:** R1, R2, R3, R4, R5.

**Dependencies:** none.

**Files:**
- Modify: `lib/mutineer/rails_worker_db.rb`
- Test: `test/rails_worker_db_test.rb`

**Approach:**
- Add `RailsWorkerDb.mysql_version_support(version)` next to `mysql_adapter?` (line 517). It is pure. It calls `to_s` on the input, then returns, in this order: `:not_tested` when the text matches `/mariadb/i`; `:unreadable` when it has no leading `<major>.<minor>`; `:not_supported` when the major is below 8; `:not_tested` when the major is above 8; `:supported` otherwise.
- Add `RailsWorkerDb.check_mysql_server(conn)` next to `provision_mysql`. It reads the version with `mysql_rows` (KTD4) inside a `rescue StandardError` that gives `nil` (KTD8). It calls `mysql_version_support`, prints the matching warning on `:not_tested` or `:unreadable` (see "User-visible text"), and returns the refusal text on `:not_supported`, or `nil`. It does not close `conn` and does not raise (KTD3).
- In `provision_mysql`, on the line after `open_mysql_connection` (line 831) and before `try_mysql_lock` (line 832): when `check_mysql_server(conn)` returns a refusal, close `conn` and raise `could not provision <base>: <refusal>`.
- Give both methods full YARD docs (`@param`, `@return`). The summary of `check_mysql_server` says that it prints the warnings. Update the `@raise` line of `provision_mysql` (line 822) to name a MySQL server older than 8.0.
- Do not change the rescue in `copy_mysql_rows` (line 1185). It still protects a MariaDB run, which now continues after the warning.

**Patterns to follow:**
- Pure helpers with no AR access: `mysql_worker_database`, `mysql_lock_names`.
- Close then raise before the lock: the `try_mysql_lock` miss at lines 832 to 835.
- Stderr text: the `[mutineer] provisioned ...` line at line 861.

**Test scenarios** (all in `test/rails_worker_db_test.rb`):
- `test_mysql_version_support_accepts_mysql_8`: `"8.0.36"`, `"8.0.36-0ubuntu0.22.04.1"` and `"8.4.0"` each return `:supported`. Fails before the fix with `NoMethodError`.
- `test_mysql_version_support_refuses_mysql_before_8`: `"5.7.44"`, `"5.7.44-log"` and `"5.6.51"` each return `:not_supported`. Fails before the fix with `NoMethodError`.
- `test_mysql_version_support_marks_mariadb_and_mysql_9_not_tested`: `"10.11.6-MariaDB"`, `"11.4.2-MariaDB-log"`, `"5.5.5-10.6.12-MariaDB"` and `"9.1.0"` each return `:not_tested`. The `5.5.5-` value proves that the MariaDB check runs before the numeric check. Fails before the fix with `NoMethodError`.
- `test_mysql_version_support_marks_an_unreadable_version`: `nil`, `""` and `"unknown"` each return `:unreadable`. Fails before the fix with `NoMethodError`.
- `test_provision_mysql_refuses_mysql_5_7_before_it_takes_a_lock`: stub `routing_config_hash` with `{ adapter: "trilogy", database: "app_test" }` and `open_mysql_connection` with a fake client that answers `SELECT VERSION()` with `"5.7.44"`. Assert that `provision_mysql(1)` raises `RuntimeError` with the full refusal text for `app_test` and `5.7.44`. Assert that the fake is closed and that it received no `GET_LOCK`, `DROP DATABASE` or `CREATE DATABASE` query. Fails before the fix: the fake answers `GET_LOCK` with `0`, so the old code raises `another Mutineer run is using app_test` instead.
- `test_provision_mysql_warns_once_on_mariadb`: same stubs, version `"10.11.6-MariaDB"`, and `GET_LOCK` answers `0` so the run stops at the lock. Capture stderr with `capture_io`. Assert that the error is `another Mutineer run is using app_test` (the check did not refuse) and that stderr holds `10.11.6-MariaDB is not tested with --daemon` exactly once. Fails before the fix: stderr is empty.
- `test_provision_mysql_warns_when_the_version_query_fails`: same stubs, but the fake raises `RuntimeError, "boom"` on `VERSION()`. Assert that the error is still `another Mutineer run is using app_test` (the run went on to the lock) and that stderr holds `could not read the MySQL server version (got nothing)` once. Fails before the fix: stderr is empty.
- `test_provision_mysql_accepts_mysql_8_without_a_warning`: same stubs, version `"8.0.36"`. Assert the lock error and empty stderr. This is a guard against a false warning. It passes before the fix and must still pass after it.
- Fake client: add a small `VersionMysql` class beside `LockMysql` (line 738). It records each query, answers `VERSION()` with its version (or raises when given an error), answers `GET_LOCK` with `"0"`, returns empty `HashRows` for any other query, implements `escape` like `LockMysql`, and sets a `closed?` flag in `close`. `LockMysql` needs a `LockBox` and has no query log or close flag, so a separate fake is simpler than a changed one. The existing `teardown` (line 292) already clears the remembered MySQL base config.
- No new CLI-level test for the exit code. The refusal uses the same raise, daemon reply and `DaemonBootError` path as the lock miss, and `test/daemon_mysql_test.rb:131` already proves that path ends with exit 1 and the message on the terminal. A real refusal needs a MySQL 5.7 server, which CI does not have.

**Verification:** the eight tests pass. `bundle exec rake yard:strict` reports 100%.

### U2. Real-server proof on mysql2 and trilogy

**Goal:** Prove that `SELECT VERSION()` returns readable text on a real MySQL 8 server with both clients, so a supported run gets no false warning.

**Requirements:** R4.

**Dependencies:** U1.

**Files:**
- Modify: `test/daemon_mysql_test.rb`

**Approach:** In `test_provision_runs_again_when_coverage_is_cached` (line 82), after the assertion on `provisioned 1 mysql worker database(s)` (line 90), add a `refute_match` on `err` for `is not tested with --daemon`, `is not supported. --daemon needs MySQL 8.0` and `could not read the MySQL server version`. Do not match a bare `not supported`: `lib/mutineer/cli.rb:472` prints `redefine is not supported on the daemon path` in other runs. The CI job `rails daemon mysql 8` (`.github/workflows/ci.yml:130`) runs this file on `mysql:8.0` for both `mysql2` and `trilogy`.

**Test scenarios:**
- On MySQL 8.0 with `mysql2`, and again with `trilogy`, a provisioned run prints none of the three messages. This passes before the fix too. After the fix it fails if the row key or the parse is wrong, because the unreadable warning would appear.

**Verification:** `bundle exec rake test:daemon` with `DB=mysql` passes on both adapters (CI, or locally against a MySQL 8 server).

### U3. Docs and CHANGELOG

**Goal:** Say what `--daemon` now does on MySQL 5.7 and MariaDB.

**Requirements:** R6.

**Dependencies:** U1.

**Files:**
- Modify: `README.md`
- Modify: `docs/rails.md`
- Modify: `docs/rails.html`
- Modify: `CHANGELOG.md`

**Approach:**
- `README.md:454-455` (MySQL section of the daemon docs): replace the two lines with these, in the one-sentence-per-line style of that section:
  - "MySQL 5.7 is not supported. `--daemon` stops the run with `could not provision <base>: MySQL <version> is not supported` before it copies any database."
  - "To run on MySQL 5.7, pass `--no-daemon` (or set `daemon: false`). The run is then serial."
  - "MariaDB and MySQL 9 are not tested. `--daemon` prints a warning and runs."
  - "If Mutineer cannot read the server version, it prints a warning and runs."
- `README.md:74-75` (inside the `contract:support-matrix` block): no change. `test/docs_contract_test.rb:114` checks this block, and the words stay true.
- `docs/rails.md:125`: replace "MariaDB is not tested. MySQL 5.7 is not supported." with "MariaDB and MySQL 9 are not tested: `--daemon` prints a warning and runs. On MySQL 5.7, `--daemon` stops the run before it copies any database. Pass `--no-daemon` (or set `daemon: false`) there." `docs/rails.html:126` is the hand-kept twin of that page. Make the same change in its paragraph.
- `CHANGELOG.md`: add a `### Fixed` section under `## [Unreleased]` (line 7), after the existing `### Changed` block. Releases 1.7.0, 1.6.0 and 1.5.0 put Fixed after Changed. Use the bold-headline format of the 1.7.0 Fixed entries: "- **`--daemon` stops on MySQL older than 8.0 (#298).** The support matrix said MySQL 5.7 is not supported, but `--daemon` ran on it. Mutineer now reads the server version before it copies any worker database. MySQL older than 8.0 stops the run with `could not provision <base>: MySQL <version> is not supported`. Pass `--no-daemon` (or set `daemon: false`) to stay serial. MariaDB and MySQL 9 print one warning and run."
- Keep the ASD-STE100 style of the surrounding lines. No em-dashes.

**Test expectation:** none. This is prose. `test/docs_contract_test.rb` and `test/site_docs_test.rb` run in the default suite and must stay green.

**Verification:** the default suite passes. `rake site:build` and the website checks pass, because `docs/rails.html` changed.

---

## Verification Contract

Prefix every ruby, rake and bundle command with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` in a shell where those are unset.

From `AGENTS.md` ("Before every commit"):

- `bundle exec rake test` (zero-dependency suite, includes `test/rails_worker_db_test.rb` and the docs contract tests)
- `ruby -Ilib -e 'require "mutineer"'` (load smoke)
- `bundle exec rake yard:strict` (100% documented, private methods and constants included)
- `BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle install`, then `BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle exec rake test`. AGENTS.md asks for this only for Minitest integration changes. It is cheap, so run it.

Rails integration (U2): `bundle exec rake test:daemon` with the fixture bundle installed and `DB=mysql`, against MySQL 8 with `MYSQL_ADAPTER=mysql2` and `MYSQL_ADAPTER=trilogy`. CI runs this in the `rails daemon mysql 8` job. If no local MySQL 8 is available, rely on that CI job and say so in the pull request.

Website (U3 touches `docs/rails.html`): `bundle exec rake site:build`, `node --test test/site_test.js`, then the Playwright checks in `test/browser` as `AGENTS.md` lists them.

Repo rules that apply: zero runtime dependencies (the check uses only the client the app already loaded), no `eval`, 100% YARD docs, CHANGELOG entry under `## [Unreleased]`, least astonishment (the refusal is explicit and uses the existing provisioning error path).

## Definition of Done

- The eight U1 tests exist and pass. The seven that fail before the fix were seen failing first.
- U2's assertion is in `test/daemon_mysql_test.rb`, and the MySQL CI job is green on both adapters.
- README, `docs/rails.md`, `docs/rails.html` and `CHANGELOG.md` carry the U3 text.
- Every gate in the Verification Contract is green.
- The diff holds no dead code from abandoned attempts and no new runtime dependency.

---

## Risks and Overlaps

- **Behaviour change for 5.7 users.** A 5.7 run that worked before now stops with exit 1. The docs already called 5.7 "not supported", so this is a fix (patch release). The message names the workaround.
- **PR #245 (daemon by default for Minitest `--rails`).** It is based on an old integration branch and edits `RailsWorkerDb.provision`. Expect a text conflict near line 298 when it rebases. When the daemon becomes the default, a provisioning error may fall back to a serial run instead of stopping. For 5.7 that fallback is safe and matches "serial only". The #245 author must decide whether this refusal falls back or stops, and keep the warning text.
- **PR #244 (2.0 contract flip).** It maps `DaemonBootError` to exit 3 and removes the `rescue Mutineer::DaemonBootError` block in `lib/mutineer/cli.rb`. `STABILITY.md` already says that in 2.0 a provisioning failure exits 3. This refusal uses that path, so in 2.0 it exits 3 like every provisioning failure. R1's exit 1 is the 1.x behaviour. Whichever PR merges second updates R1 and the stderr line in "User-visible text (contract)". #244 does not edit `provision_mysql` itself. A rebase may also conflict in the CHANGELOG.
- **PR #308 (temp-file sweep).** It edits `lib/mutineer/daemon_server.rb` and `lib/mutineer/daemon_backend.rb`. This plan does not edit those files.
- **PRs #304, #305, #306, #307.** They touch other files. Each adds a CHANGELOG entry under `## [Unreleased]`, so expect small CHANGELOG conflicts only. #305 also edits `README.md`, but not the MySQL lines.
- **PR #301** (AGENTS.md and expectation-fit conventions) and **#202** (coverage map split): no overlap.
- **Issue #296** (an in-test database error is scored killed under `--daemon`). Its plan edits the in-test error path of `RailsWorkerDb`, not provisioning. No conflict expected.
- **Issue #284** (preconditions for the 2.0 daemon default). This refusal is one more provisioning error that the default-daemon fallback must handle.

## Corrections to the issue comment

- Line numbers drifted after #302 merged: `per_worker_config` is at `lib/mutineer/rails_worker_db.rb:262` (comment: 278). The matrix lines are `README.md:74-75` and `README.md:454-455` (comment: 81-82 and 461-462). `docs/rails.md` says it at line 125 (comment: 102). The `SET_USER_ID` line is `README.md:448` (comment: 455).
- The comment places the check "before the first `recreate_mysql_database`". This plan places it before the lock (KTD1), which is earlier and leaves nothing to undo.
- The comment does not cover a version text that cannot be read, or a `docs/rails.html` twin that must match `docs/rails.md`. This plan covers both (R3, U3).
- The rest is correct: `mysql_adapter?` at line 517, `provision_mysql` at line 823 with the client at line 831, the rescued `SET` at line 1185, the stop at `lib/mutineer/daemon_backend.rb:183`, and the need to check MariaDB before the number.

## Open Questions

All are deferred. None blocks implementation.

- **OQ1. Unreadable version: warn or refuse?** Default: warn and continue (KTD8). Alternative: refuse like 5.7. Choose refuse if the maintainer wants the matrix enforced strictly.
- **OQ2. Other MySQL-compatible servers that report 8.x** (TiDB, some proxies). Default: accept them silently, because they report a MySQL version. Alternative: warn on a known non-MySQL suffix such as `TiDB`. Add that only when a user reports a problem.
- **OQ3. Escape hatch for 5.7.** Default: none. `--no-daemon` is the workaround. Add an env var only if a user asks for one.
- **OQ4. MySQL 9: warn or stay silent?** Default: warn as not tested (KTD2), because no CI job runs MySQL 9. Alternative: accept MySQL 9 silently and add one docs sentence that says so. Choose that if a MySQL 9 CI job is added.
- **OQ5. MySQL 5.7.5 and later: refuse or warn?** Default: refuse (Problem Frame). Alternative: warn on 5.7.5 and later, refuse only below 5.7.5, and relabel 5.7 "not tested" in the matrix. Choose that if 5.7 users report that the stop blocks real work.
