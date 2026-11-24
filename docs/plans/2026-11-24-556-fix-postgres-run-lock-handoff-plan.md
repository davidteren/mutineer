---
title: "Group 11-B: the PostgreSQL run lock is never free between exclusive and shared - Plan"
type: fix
date: 2026-11-24
issues: [556, 416]
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Group 11-B: the PostgreSQL run lock is never free between exclusive and shared - Plan

- **What:** One fix in `RailsWorkerDb.provision_postgres`. The run takes the shared lock before it releases the exclusive lock.
- **Why:** Today no session holds the lock for one moment. A second run can take it there, and both runs then score mutants against the same worker databases with no message.
- **How:** Move the shared request in front of the release, inside the block that already closes the session on a failure. PostgreSQL lets one session hold the exclusive and the shared advisory lock on one key at the same time.

Build settings: Opus 5.5, effort `medium`. The fix and both tests are written and were run in planning, so the build is small. The model stays one tier below the strongest because this is lock code and the builder answers the review threads.

Target release: 1.11.0. Issues: #556 (fixed, `Closes #556`) and #416 (`Refs #416`, stays open). One pull request, one commit.
Planned against `main` at `c5100143`.

**Verdict: `go`.** The defect is reproduced on a real PostgreSQL server, the fix changes 19 lines in one method, and the new tests fail on `main` and pass with the fix (the tests ran on PostgreSQL 16.16, and a probe of the lock order also ran on 14.25 and 18.7). Unit U3 of #416 is not built (decision 1 in the 1.11.0 run's `DECISIONS.md`, default: no).

---

## Goal Capsule

- **Objective:** A PostgreSQL `--rails --daemon` run holds its run lock at every moment while `provision_postgres` moves it from exclusive to shared. A second run that asks in that step stops with `another Mutineer run is using <base>`. The other ways a run can be without its lock stay open (see "Limits left open").
- **Means:** In `provision_postgres`, ask for the shared lock first and release the exclusive lock second, on the same session (KTD1). Do both inside the `begin` block of the copy, so every failure closes the session (KTD6).
- **Authority:** `AGENTS.md`, then `.expectation-fit/ways-of-working.yaml` and `.expectation-fit/decisions/daemon-and-worker-databases.md`, then this plan, then the issue texts.
- **Execution profile:** One branch (`fix/556-postgres-run-lock-handoff`), one worktree, one pull request, one commit.
- **Who ships:** The builder opens the pull request. David merges. No release step.
- **Size:** Small. One `lib/` file (19 changed lines), two test files, one decision record, `CHANGELOG.md`, and the plan copy.
- **Stop conditions.** Stop and report, do not work around:
  - The CI job `rails daemon postgres 16 (ruby 3.4)` fails the new test with a statement in `FREE_AFTER`, or with `WORKER_JOINS=false`. That means PostgreSQL does not behave as KTD1 says on that server.
  - The fix seems to need a change in `lib/mutineer/daemon_backend.rb`, `lib/mutineer/daemon_server.rb`, the MySQL lock code or the SQLite lock code. This plan changes none of them.
  - A change would alter the text `another Mutineer run is using <base>`, an exit code, or the output of a normal run on its own.

---

## Product Contract

### Summary

A PostgreSQL run takes the exclusive run lock, copies its worker databases, and then holds the shared lock until its lock session ends. After this change it asks for the shared lock while it still holds the exclusive one, and releases the exclusive one after that. No other session can take the lock between the two steps. Nothing a user sees changes for a run on its own.

### Problem Frame

`RailsWorkerDb.provision_postgres` (`lib/mutineer/rails_worker_db.rb`) ends its copy with two calls:

1. `unlock(conn, base)` sends `pg_advisory_unlock`. The exclusive lock is gone.
2. `try_lock(conn, base, shared: true)` sends `pg_try_advisory_lock_shared`.

Between the two calls no session holds the lock. A second run (run B) that asks in that window gets the exclusive lock. Three outcomes are possible:

| Run B's timing | Result on `main` |
|---|---|
| B still holds the exclusive lock when run A asks for the shared lock | A stops with the lock message. B drops A's worker databases in its copy. Loud. |
| B has finished its copy and holds the shared lock | A's shared request succeeds. Both runs score mutants against the same `<base>-mutineer-N` databases. **Silent.** |
| A asks for the shared lock while B is in its own window | Both get the shared lock. **Silent.** |

Every PostgreSQL `--rails --daemon` run uses this path: the first daemon (`db_role` `prepare`, on the `provision` command), the one worker of a fallback run (`db_role` `solo`, #416), and a direct client with no role. All three call `RailsWorkerDb.provision`, which calls `provision_postgres`. So one fix covers all three.

The window is the time between the server's work on run A's release and on run A's shared request. Its length varies: it is one client round trip on a healthy machine, and longer when run A is paused or the network is slow. The silent outcome needs run B's whole copy inside it, so it needs a stalled run A. It is rare. Its effect is the false verdicts the run lock exists to prevent (#404, #416).

### Reproduction (done in planning, 2026-11-24)

All runs used a private PostgreSQL server from the Postgres.app binaries on port 55432, not the developer's own server. The code was `origin/main` at `c5100143`.

1. **The lock is free.** A probe ran the real `provision_postgres(1)`. After each statement of the lock session, a second session asked for the exclusive lock. On `main` it got the lock once, right after `SELECT pg_advisory_unlock($1, $2)`. Result line: `lock free after: ["SELECT pg_advisory_unlock($1, $2)"]`.
2. **The silent outcome.** A second probe paused run A after its `unlock` and started run B, a second process that ran the whole `provision_postgres(1)` on the same base. Run B printed `provisioned`. Run A then went on and also printed `provisioned`. `pg_locks` showed two sessions with `ShareLock` on the run lock key. Run B had dropped and recreated run A's worker database.
3. **With the fix.** The first probe found the lock never free. In the second probe run B stopped, and one session held `ShareLock`. The first probe gave the same result on PostgreSQL 14.25, 16.16 and 18.7.
4. **The new tests.** The tests of U1 fail on `main` and pass with the fix (see U1, "Test scenarios"). With the fix, all 13 tests in `test/daemon_postgres_test.rb` pass on PostgreSQL 16.16. The tests did not run on 14 or 18.
5. **A waiting session.** A probe on PostgreSQL 16.16: session A holds the exclusive lock, session C waits for it with the blocking `pg_advisory_lock`, and A's `pg_try_advisory_lock_shared` then returns false. So the shared request can be refused. Mutineer never sends a blocking request, so this needs a session that is not Mutineer's (see KTD1).

The defect came from a review bot (Devin, on pull request #555), not from a user report. The tests in U1 are its lasting reproduction.

### Requirements

- R1. From the first successful lock request in `provision_postgres` until the method returns, at least one advisory lock on the run key is held by that session. After that the session keeps the shared lock for as long as it lives.
- R2. Every copy statement runs under the exclusive lock. After `provision_postgres` returns, the session holds the shared lock only, and `RailsWorkerDb` keeps that session. A worker daemon of the same run gets the shared lock. A second run does not get the exclusive lock.
- R3. A refused shared request raises `another Mutineer run is using <base>`, as today. A shared request or a release that raises gives `could not provision <base> from <base>: <cause>`. In both cases the session is closed. The closed session frees the exclusive lock, so the next run is not blocked.
- R4. A normal run on its own keeps its verdicts, scores, exit codes and messages. No new output line.
- R5. Every lock request stays non-blocking.
- R6. The siblings are named and each one is covered or tracked: MySQL, SQLite, the `solo` role and the direct client (see "Siblings").
- R7. `CHANGELOG.md` names #556. #416 holds every open limit before the pull request opens.

### Acceptance Examples

- AE1. **Covers R1, R2.** Given a real PostgreSQL server, when `RailsWorkerDb.provision(1)` runs and a second session asks for the exclusive lock after each statement of the lock session, then the second session never gets it. After the call, the second session gets the shared lock and does not get the exclusive lock.
- AE2. **Covers R1, R2.** Given an in-memory model of session advisory locks, when `provision_postgres(2)` runs, then the model was never free, each copy statement ran under the exclusive lock, the session ends with one shared lock and no exclusive lock, and `RailsWorkerDb` keeps that session.
- AE3. **Covers R3.** Given a session whose shared request is refused, or raises, when `provision_postgres(1)` runs, then it raises the message of R3, the session is closed, and no lock is held.
- AE4. **Covers R4.** Every existing test in `test/daemon_postgres_test.rb` stays green, with no changed assertion.

### Siblings

| Sibling | Same window? | Evidence | Action |
|---|---|---|---|
| MySQL: `provision_mysql` with `downgrade_mysql_lock_to_shared` | No. The guard lock is held across the step. Only pool names are released. | Read the code. `test_mysql_lock_downgrade_never_drops_every_lock` in `test/rails_worker_db_test.rb` holds the rule. | None. |
| SQLite: `provision_sqlite` (`flock` exclusive, then `flock` shared, on one open file) | None seen. The probes found no free moment. This is an observation, not a guarantee: the Linux `flock(2)` page allows a gap in a conversion. | A probe converted the lock in a loop while a second process asked for the exclusive lock. macOS (Darwin 25.6): 3,290,518 conversions, the second process never got the lock. Linux (kernel 7.2, overlayfs): 7,584,244 conversions, never. | No code. Tracked as limit L8 (see "Limits left open"). |
| PostgreSQL worker daemons: `prepare_worker!` | No. One request for the shared lock. No step from one mode to the other. | Read the code. | None. |
| `db_role` `solo` and the direct client | Same code path as the first daemon (`provision` calls `provision_postgres`). | `DaemonServer.setup_worker_db` and `provision_slots` in `lib/mutineer/daemon_server.rb`. | Covered by the one fix. |

### Scope Boundaries

Considered and not built:

- **Unit U3 of #416 (the early SQLite lock).** Decision 1 in the 1.11.0 run's `DECISIONS.md`. The default is no. See "Decisions for David".
- **A guard lock for PostgreSQL, as MySQL has.** MySQL needs it because `GET_LOCK` has no shared mode. PostgreSQL has both modes on one key, so the guard adds a second key and gains nothing.
- **A check of the result of `pg_advisory_unlock`.** See KTD2.
- **A race test with two real runs.** It depends on timing, so it would fail now and then or prove nothing. The probe after each statement is exact (KTD3).
- **A stress test for the SQLite conversion.** The kernel does that step, not Mutineer. The probe result is recorded here and on #416.
- **A change to `docs/rails-setup.md`.** The "Concurrent runs" row already says a second run stops. The fix makes that true in one more case. No doc sentence becomes false.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Share first, then release, on the same session.** The locks one PostgreSQL session holds do not conflict with its own new request, so `pg_try_advisory_lock_shared` succeeds while the session holds the exclusive lock on the same key. One case refuses it: another session waits for the exclusive lock with a blocking `pg_advisory_lock` (seen run on 16.16, Reproduction step 5). Mutineer sends only non-blocking requests, so two Mutineer runs never make that queue. If it happens, the run stops with the lock message and closes its session (R3). `pg_advisory_unlock` then releases the exclusive lock only. `pg_advisory_unlock_shared` is the call that would release the shared one, and the code never sends it. Seen run on PostgreSQL 14.25, 16.16 and 18.7: after the two calls `pg_locks` shows one `ShareLock` for the session. Other option: a second key as a guard (MySQL's design). Rejected: more code, same result.
- **KTD2. Do not check the result of `unlock`.** `pg_advisory_unlock` returns false only when the session does not hold the exclusive lock. `provision_postgres` reaches that line only after its own exclusive request succeeded on that session. If the release did fail, the session would hold the exclusive and the shared lock. In a run with a first daemon, the worker daemon's shared request would be refused and the run would stop with `another Mutineer run is using <base>` (the text would name a second run that does not exist). In a `solo` run or a direct client no other daemon asks, so nothing would show, and the kept exclusive lock would still stop every second run. No case gives a false verdict. Other option: raise `could not provision <base>` when the result is not `t`. Rejected: a branch that no direct session can reach.
- **KTD3. Two tests, one mechanism: "ask after every statement".** The unit test uses an in-memory model of session advisory locks (`PgLockBox`), like `LockBox` for MySQL. It models sessions that never wait, as Mutineer's are. It also checks what the server test cannot see cheaply: each copy statement runs under the exclusive lock, and the module keeps the lock session. It runs in the default suite on every machine. The daemon test runs the same check on a real server in the `DB=postgres` CI job. It proves that the model matches PostgreSQL. Both check every statement, not one chosen point, and both check the end state, so a "fix" that never releases the exclusive lock fails too. Other option: the daemon test only. Rejected: it runs in one CI job, and a contributor without PostgreSQL would see nothing locally.
- **KTD4. Add one line to the decision records.** `.expectation-fit/decisions/README.md` says: when a review teaches a new fact, add the line. A review taught this rule. Pull requests #335 and #245 (2.0, held) change `provision`, and the line tells their authors and reviewers the rule. Other option: no line, because the tests hold the rule (the #416 plan chose that). Rejected here: the line costs one sentence, and the next change to this code is a large rebase.
- **KTD5. The new limits go on #416 as a comment, not in a new issue.** #416 is the tracker for run lock limits. Pull request #555 added L5 and L7 the same way. Other option: one new `backlog` issue for each limit. Rejected: two trackers for one subject.
- **KTD6. The handoff goes inside the `begin` block of the copy.** `provision_mysql` already does this: it raises the lock message inside its `begin` block, and its `rescue` releases and closes. With the new order the session still holds the exclusive lock while it asks for the shared one. If that request raised outside the block (a cancelled query, a lost connection), the session would stay open with the exclusive lock until the daemon exits. Inside the block, the existing `rescue` releases, closes and wraps the error. Other option: move only the one call and keep the `unless` block after the `rescue`. Rejected: it leaves that open session, and it is two lines longer.

### Assumptions

- The fixture bundle resolves with `BUNDLE_WITH=postgres` (checked on the build machine: `pg` 1.7.0 is installed for Ruby 3.4.9).
- `define_singleton_method` on a `PG::Connection` with `super(*args)` reaches the real `exec` and `exec_params` (seen run with `pg` 1.7.0). The fixture `Gemfile` allows `pg` `~> 1.5`.
- Advisory locks are per database. The lock session and the probe session both connect to `RailsWorkerDb::MAINTENANCE_DATABASE` (`postgres`).

### Sources

| Source | Freshness |
|---|---|
| Probe runs against PostgreSQL 14.25, 16.16 and 18.7 (Postgres.app builds), 2026-11-24 | current |
| `flock` probe runs on macOS (Darwin 25.6) and Linux (kernel 7.2), 2026-11-24 | current |
| `flock(2)` on Linux: "Converting a lock ... is not guaranteed to be atomic". From memory, not read again in planning. | durable (kernel interface text); the kernel code may be better than the text says |
| PgBouncer feature table: session advisory locks do not work with transaction pooling. From memory, not seen run. | aging; check before you rely on it |

---

## Implementation Units

### U1. Share the PostgreSQL run lock before the exclusive lock is released (#556)

- **Goal:** R1 to R7.
- **Dependencies:** none.
- **Files:**
  - `lib/mutineer/rails_worker_db.rb`
  - `test/rails_worker_db_test.rb`
  - `test/daemon_postgres_test.rb`
  - `.expectation-fit/decisions/daemon-and-worker-databases.md`
  - `CHANGELOG.md`
  - `docs/plans/2026-11-24-556-fix-postgres-run-lock-handoff-plan.md` (the copy of this plan)

#### Approach

1. **Write the tests first** (steps 5 and 6), run them, and see the failures from the "Test scenarios" table. Then make the `lib/` change (steps 2 to 4). Do not use `git stash` to get the unfixed code: the stash stack is shared with other worktrees.

   **After the local checks pass and before the pull request opens, post the comment on #416** from "Limits left open" below. It records L8, L9, L10 and the U3 decision. The pull request then cites #416 for each of them.

2. **`RailsWorkerDb.provision_postgres`.** Today the method ends like this:

   ```ruby
   begin
     disconnect_app!
     count.times do |slot|
       name = postgres_worker_database(base, slot)
       recreate_from_template(conn, name, base)
     end
   rescue StandardError => e
     unlock(conn, base)
     conn.close
     raise provision_wrapped?(e) ? e : provision_failure(base, base, e.message)
   end

   unlock(conn, base)
   unless try_lock(conn, base, shared: true)
     conn.close
     raise "another Mutineer run is using #{base}"
   end
   @lock_connection = conn
   warn "[mutineer] provisioned #{count} postgres worker database(s) from #{base}"
   ```

   Change it to:

   ```ruby
   begin
     disconnect_app!
     count.times do |slot|
       name = postgres_worker_database(base, slot)
       recreate_from_template(conn, name, base)
     end
     # Share first, then release. The locks one session holds do not
     # conflict, and the unlock frees only the exclusive lock (#556).
     raise "another Mutineer run is using #{base}" unless try_lock(conn, base, shared: true)

     unlock(conn, base)
   rescue StandardError => e
     unlock(conn, base)
     conn.close
     raise provision_wrapped?(e) ? e : provision_failure(base, base, e.message)
   end

   @lock_connection = conn
   warn "[mutineer] provisioned #{count} postgres worker database(s) from #{base}"
   ```

   Do not change the `rescue` block. `provision_wrapped?` is true for the lock message, so a refused request still raises that exact text. The first lock request at the top of the method does not change.

3. **The comment above `provision_postgres`.** Replace the two sentences about the lock with:

   ```ruby
   # Drop and recreate slots `0...count` from the booted test database.
   # Holds the exclusive advisory lock for the copy. Then takes the shared
   # lock on the same session and only after that releases the exclusive one.
   # The lock is never free in between, so a second run cannot drop those
   # databases (#556). The shared lock stays for the rest of this process.
   ```

4. **The comment above `RailsWorkerDb.unlock`.** It says "Release one advisory lock". Make it exact:

   ```ruby
   # Release the exclusive advisory lock this session holds for `base`.
   # A shared lock that the same session holds stays.
   ```

5. **Unit tests in `test/rails_worker_db_test.rb`.** Put the two tests after `test_mysql_lock_downgrade_never_drops_every_lock`. Put the helper and the two classes before the comment `# In-memory GET_LOCK / RELEASE_LOCK so two sessions can race without MySQL.`

   ```ruby
   # #556: the Postgres run lock is never free while provision moves from
   # exclusive to shared, so no second run can start a copy in between.
   def test_postgres_provision_never_frees_the_run_lock
     box = PgLockBox.new
     conn = LockPg.new(box, :first)
     db = Mutineer::RailsWorkerDb
     base = "app_test"
     capture_io { provision_postgres_on(conn, base, slots: 2) }
     refute box.went_free?, "the run lock was free between the exclusive and the shared lock"
     assert_equal [{ exclusive: 1, shared: 0 }], conn.held_at_copy.uniq, "a copy statement ran without the exclusive lock"
     assert_equal({ exclusive: 0, shared: 1 }, box.held_by(:first))
     assert_same conn, db.instance_variable_get(:@lock_connection), "the lock session is not kept"
     assert db.try_lock(LockPg.new(box, :worker), base, shared: true), "a worker daemon could not join"
     refute db.try_lock(LockPg.new(box, :second_run), base, shared: false), "a second run got the lock"
   ensure
     db.instance_variable_set(:@lock_connection, nil)
   end

   # A shared request that is refused, or that raises, closes the session.
   # That frees the exclusive lock, so the next run is not blocked. Postgres
   # refuses the request while another session waits for the exclusive lock.
   def test_postgres_provision_frees_the_lock_when_the_share_fails
     db = Mutineer::RailsWorkerDb
     { refuse: "another Mutineer run is using app_test",
       raise: "could not provision app_test from app_test: the query was cancelled" }.each do |on_shared, message|
       box = PgLockBox.new
       conn = LockPg.new(box, :first, on_shared: on_shared)
       db.instance_variable_set(:@lock_connection, nil)
       error = assert_raises(RuntimeError) { provision_postgres_on(conn, "app_test", slots: 1) }
       assert_equal message, error.message
       assert conn.closed?, "#{on_shared}: the session stays open"
       assert box.free?, "#{on_shared}: the failed run still holds the lock"
       assert_nil db.instance_variable_get(:@lock_connection)
     end
   end
   ```

   ```ruby
   # Run provision_postgres with `conn` as the maintenance session and no app.
   def provision_postgres_on(conn, base, slots:)
     db = Mutineer::RailsWorkerDb
     db.stub(:current_config_hash, { adapter: "postgresql", database: base }) do
       db.stub(:open_maintenance_connection, conn) do
         db.stub(:disconnect_app!, nil) { db.provision_postgres(slots) }
       end
     end
   end

   # In-memory session advisory locks for one key, so two sessions can race
   # without Postgres. It models sessions that never wait, as Mutineer's are:
   # the locks one session holds do not conflict, and each unlock releases one
   # lock of one mode.
   class PgLockBox
     def initialize
       @held = Hash.new { |hash, session| hash[session] = { exclusive: 0, shared: 0 } }
       @went_free = false
     end

     def try(session, mode)
       others = @held.reject { |who, _counts| who == session }.values
       return false if others.any? { |counts| counts[:exclusive].positive? }
       return false if mode == :exclusive && others.any? { |counts| counts[:shared].positive? }

       @held[session][mode] += 1
       true
     end

     def unlock(session, mode)
       return false unless @held[session][mode].positive?

       @held[session][mode] -= 1
       @went_free = true if free?
       true
     end

     # A closed session loses its locks. This is not counted as a free moment.
     def close(session)
       @held.delete(session)
     end

     def held_by(session)
       @held[session].dup
     end

     def free?
       @held.values.all? { |counts| counts.values.sum.zero? }
     end

     def went_free?
       @went_free
     end
   end

   # One session against a {PgLockBox}. Answers the advisory lock calls of
   # RailsWorkerDb and records the locks it holds at each copy statement.
   # `on_shared` makes the shared request fail: `:refuse` or `:raise`.
   class LockPg
     attr_reader :held_at_copy

     Row = Struct.new(:value) do
       def getvalue(_row, _column)
         value
       end
     end

     def initialize(box, id, on_shared: nil)
       @box = box
       @id = id
       @on_shared = on_shared
       @closed = false
       @held_at_copy = []
     end

     def exec_params(sql, _params)
       got =
         case sql
         when /pg_try_advisory_lock_shared\(/ then try_shared
         when /pg_try_advisory_lock\(/ then @box.try(@id, :exclusive)
         when /pg_advisory_unlock\(/ then @box.unlock(@id, :exclusive)
         else raise "unexpected statement: #{sql}"
         end
       Row.new(got ? "t" : "f")
     end

     def exec(_sql)
       @held_at_copy << @box.held_by(@id)
       nil
     end

     def escape_literal(value)
       "'#{value}'"
     end

     def close
       @closed = true
       @box.close(@id)
     end

     def closed?
       @closed
     end

     private

     def try_shared
       raise "the query was cancelled" if @on_shared == :raise

       @on_shared != :refuse && @box.try(@id, :shared)
     end
   end
   ```

   Each pattern ends with `\(`, so one name cannot match another. The code never sends `pg_advisory_unlock_shared`. If it ever does, the fake raises `unexpected statement`.

6. **Daemon test in `test/daemon_postgres_test.rb`.** Put it after `test_a_second_run_stops_while_the_first_holds_the_lock`. It skips unless `DB=postgres` (the `setup` of the class does that).

   ```ruby
   # #556: the run lock is never free while provision moves from exclusive to
   # shared. A second session asks for the exclusive lock after every statement
   # of the lock session. It must never get it.
   def test_provision_never_frees_the_run_lock
     out, status = fixture_ruby(<<~RUBY)
       require "./config/environment"
       require "pg"
       require #{WORKER_DB.inspect}
       db = Mutineer::RailsWorkerDb
       keys = db.lock_keys(#{BASE.inspect})
       probe = PG.connect(#{pg_connect_literal('dbname: Mutineer::RailsWorkerDb::MAINTENANCE_DATABASE')})
       ask = ->(function) { probe.exec_params("SELECT \#{function}($1, $2)", keys).getvalue(0, 0) == "t" }
       seen = []
       free_after = []
       open_session = db.method(:open_maintenance_connection)
       db.define_singleton_method(:open_maintenance_connection) do |hash, base|
         conn = open_session.call(hash, base)
         %i[exec exec_params].each do |name|
           conn.define_singleton_method(name) do |*args|
             result = super(*args)
             seen << args.first
             if ask.call("pg_try_advisory_lock")
               free_after << args.first
               ask.call("pg_advisory_unlock")
             end
             result
           end
         end
         conn
       end
       db.provision(1)
       puts "LOCK_STATEMENTS=\#{seen.count { |sql| sql.include?("advisory") }}"
       puts "FREE_AFTER=\#{free_after.inspect}"
       puts "WORKER_JOINS=\#{ask.call("pg_try_advisory_lock_shared")} SECOND_RUN_STARTS=\#{ask.call("pg_try_advisory_lock")}"
     RUBY
     assert status.success?, out
     assert_includes out, "LOCK_STATEMENTS=3"
     assert_includes out, "FREE_AFTER=[]"
     assert_includes out, "WORKER_JOINS=true SECOND_RUN_STARTS=false"
   end
   ```

   - `LOCK_STATEMENTS=3` proves that the probe saw all three lock statements of the session: the exclusive request, the shared request and the release. Without it, a refactor that sends the lock statements on another path would pass with an empty list. A later change to the lock design must update this number on purpose.
   - `WORKER_JOINS=true` proves that the exclusive lock was released. `SECOND_RUN_STARTS=false` proves that the shared lock is held.
   - Keep each `\#{` as written. It must reach the fixture script as `#{`.

7. **Decision record.** Add one line at the end of `.expectation-fit/decisions/daemon-and-worker-databases.md`:

   ```markdown
   - **Run Lock Handoff Leaves No Free Moment.** When changing how `RailsWorkerDb` moves a run lock from exclusive to shared (`provision_postgres`, `provision_mysql` with `downgrade_mysql_lock_to_shared`, `provision_sqlite`), verify that the process holds a lock at every moment: take the shared lock before the exclusive lock is released (PostgreSQL, on the same session), or keep the guard lock (MySQL). Never release first and ask again. SQLite changes the mode of one `flock` on one open file; probes found no free moment on macOS and Linux, and the kernel gives no guarantee. `test_postgres_provision_never_frees_the_run_lock` in `test/rails_worker_db_test.rb` and `test_provision_never_frees_the_run_lock` in `test/daemon_postgres_test.rb` hold the rule for PostgreSQL, and `test_mysql_lock_downgrade_never_drops_every_lock` holds it for MySQL (#556). No test holds it for SQLite: the kernel does that step, and #416 tracks it.
   ```

8. **`CHANGELOG.md`.** Under `## [Unreleased]`, add a `### Fixed` heading if another group has not added it yet. Then add:

   ```markdown
   - **The PostgreSQL run lock is never free while a run moves it from exclusive to shared (#556).**
     A `--rails --daemon` run on PostgreSQL takes the exclusive run lock, copies its worker databases, and then shares the lock.
     Before this fix it released the exclusive lock first and asked for the shared lock second.
     For that moment no session held the lock.
     A second run on the same test database could take it there and copy its own worker databases over the first run's. Both runs could then score mutants against the same databases, with no message.
     The run now takes the shared lock on the same session before it releases the exclusive one.
     A second run that asks in that moment now stops with `another Mutineer run is using <base>`.
     A run on its own does not change.
     MySQL keeps a guard lock across that step, so it did not have this window.
     On SQLite a probe found no free moment on macOS and Linux. Other systems are not checked (#416).
     The other run lock limits are unchanged (#416).
   ```

   Another group may change the same heading. On a conflict, keep both entries.

9. **Plan copy.** Copy this file to `docs/plans/2026-11-24-556-fix-postgres-run-lock-handoff-plan.md` in the same commit. `docs/plans/` is not published (`UNPUBLISHED` in `rake/site_build.rb`).

#### Patterns to follow

- `LockBox`, `LockMysql` and `test_mysql_lock_downgrade_never_drops_every_lock` in `test/rails_worker_db_test.rb` for the in-memory lock model.
- `test_provision_uses_the_url_host_without_a_live_server` for the `stub` style on `RailsWorkerDb`.
- `test_a_second_run_stops_while_the_first_holds_the_lock` and `fixture_ruby` in `test/daemon_postgres_test.rb` for a script that runs under the fixture bundle.

#### Test scenarios

| Test | Suite | Covers | On `main` | With the fix |
|---|---|---|---|---|
| `test_postgres_provision_never_frees_the_run_lock` | `rake test` | AE2 | Fails: "the run lock was free between the exclusive and the shared lock" | Passes |
| `test_postgres_provision_frees_the_lock_when_the_share_fails` | `rake test` | AE3 | Fails in the `raise` case: "raise: the session stays open". The `refuse` case passes. | Passes |
| `test_provision_never_frees_the_run_lock` | `rake test:daemon` with `DB=postgres` | AE1 | Fails: `FREE_AFTER=["SELECT pg_advisory_unlock($1, $2)"]` | Passes: `LOCK_STATEMENTS=3`, `FREE_AFTER=[]`, `WORKER_JOINS=true SECOND_RUN_STARTS=false` |
| The other 12 tests in `test/daemon_postgres_test.rb` | `rake test:daemon` with `DB=postgres` | AE4 | Pass | Pass (seen run on PostgreSQL 16.16) |

Planning also ran the first unit test against two wrong versions of the fix, each in a clean copy of the tree:

| Wrong version | Result |
|---|---|
| The handoff moved in front of the copy | Fails: "a copy statement ran without the exclusive lock" |
| `@lock_connection = conn` removed | Fails: "the lock session is not kept" |

#### Verification

- Run the new tests before the `lib/` change (step 1) and see the failures from the table. Do not use `git stash`.
- `bundle exec ruby -Ilib -Itest test/rails_worker_db_test.rb -n /postgres_provision/`
- The PostgreSQL daemon test on a private server (see "Verification Contract").

### Commit order

One commit: `fix: the PostgreSQL run lock is never free between exclusive and shared (#556)`. It holds every file of U1. A fix from review goes in a new commit that names #556.

---

## Decisions for David

The run takes each recommendation. David can change any of them before the merge. The builder copies this list into the pull request body.

| # | Choice | Taken | Other option | Why |
|---|---|---|---|---|
| 1 | Build unit U3 of #416 (the early SQLite lock) in 1.11.0? | No. Build #556 only. The pull request uses `Refs #416`. | Yes: add U3 from `docs/plans/2026-11-22-416-fix-run-lock-gaps-plan.md` as a second commit. It also changes `lib/mutineer/daemon_backend.rb`, `daemon_server.rb` and `daemon_client.rb`. | David said "later" on 2026-11-23 and has not said yes since (the 1.11.0 run's `DECISIONS.md`, decision 1). U3 adds one new stop (limit L2d in that plan). |
| 2 | How to close the window | Take the shared lock before the release, on the same session (KTD1). | A guard key, as MySQL has. | PostgreSQL has both modes on one key, so no second key is needed. |
| 2a | Where the handoff goes | Inside the `begin` block of the copy, as `provision_mysql` does (KTD6). | Move one call and keep the `unless` block after the `rescue`. | A request that raises then closes the session. Otherwise the session stays open with the exclusive lock until the daemon exits. |
| 3 | Check the result of `pg_advisory_unlock`? | No (KTD2). | Raise `could not provision <base>` when it is not `t`. | No direct session can reach that branch. A failure would stop a normal run at the worker boot, and would only keep a stricter lock in a `solo` run. No case gives a false verdict. |
| 4 | Which tests | A unit test with an in-memory lock model, and a real-server test in the `DB=postgres` job (KTD3). | The real-server test only. | The unit test runs on every machine. The server test proves the model. |
| 5 | Add a line to `.expectation-fit/decisions/daemon-and-worker-databases.md`? | Yes (KTD4). | No line. | A review taught the rule, and held 2.0 pull requests change this code. |
| 6 | Where the three limits found in planning go (L8, L9, L10) | A comment on #416 (KTD5). | A new `backlog` issue for each. | #416 is the tracker for run lock limits. |
| 7 | Labels and links for the pull request | `bug`, `priority: low`, `risk: medium`, `v1.11.0`. `Closes #556`, `Refs #416`. | `enhancement`, as on #416. | The labels of #556. This is a defect fix. |
| 8 | The `v1.11.0` label on #416 | Leave it. #416 stays open after 1.11.0, and David moves the label when he decides U3. | The builder moves it to `backlog` now. | A yes to U3 before the merge would need the label. |

What is uncertain:

- The silent outcome was produced with a paused run A, not seen in a real run. No report of harm exists (#416, #556).
- The CI job tests PostgreSQL 16 only. Planning ran the tests on 16.16, and a probe of the lock order on 14.25 and 18.7, by hand.

---

## Risks

- **`CHANGELOG.md` conflicts.** Every group of this run adds to `## [Unreleased]`. Keep both entries.
- **`lib/mutineer/daemon_backend.rb` is not touched.** The worklist names it as shared with group 11-D. That was for U3. With the default, groups 11-B and 11-D share only `CHANGELOG.md`.
- **Held 2.0 pull requests (#335, #245) change `provision`.** Their rebase must keep the new order. The decision line (KTD4) and the two tests say so.
- **The daemon test wraps two methods of a real `PG::Connection`.** A `pg` major version that changes how `exec` or `exec_params` is defined could break the wrapper. A change in `lib/` could also send the lock statements another way. In both cases `LOCK_STATEMENTS=3` fails, so the test does not pass with nothing probed.
- **The refused-share branch is hard to reach after the fix.** The session holds the exclusive lock when it asks for the shared one, so no other Mutineer session can refuse it. Two cases can: a session that waits for the exclusive lock with a blocking request (seen run, KTD1), and a pooler in transaction mode (limit L9, not seen run). In both the message would name a second Mutineer run that does not exist. The branch stays because it fails closed (R3).
- **A failed release inside the `rescue`.** The `rescue` calls `unlock` before `close`. If the connection is dead, that `unlock` raises and the raw client error leaves the method. A dead connection holds no lock. This is the behaviour of a failed copy today, and the plan does not change it.
- **The fake in the unit test is a model of sessions that never wait.** If it differed from PostgreSQL for such sessions, the unit test could pass on wrong code. The daemon test on a real server closes that gap (KTD3).

---

## Limits left open

No new issue is filed. #416 is the tracker for run lock limits and stays open. After the local checks pass and before the pull request opens, the builder posts this comment on #416 (KTD5):

```markdown
**Claude:** an update from the plan for #556.

- #556 (the PostgreSQL window in `provision_postgres`) is fixed by the pull request that closes #556. It takes the shared lock before it releases the exclusive one.
- Unit U3 (the early SQLite lock, limit L2) is not built in 1.11.0. The maintainer has not said yes, so the answer from 2026-11-23 stands. L2 stays open here.
- Three limits found in planning join the open list:
  - L8. On SQLite, the step from exclusive to shared changes the mode of one `flock` on one open file (`provision_sqlite`). A probe found no free moment on macOS (Darwin 25.6, 3.3 million conversions) and on Linux (kernel 7.2, overlayfs, 7.6 million conversions). That is an observation, not a guarantee: the Linux `flock(2)` page says the conversion is not guaranteed to be atomic. It was not checked on a network file system or on another Unix system.
  - L9. A PostgreSQL test database behind a connection pooler in transaction mode. A session advisory lock then belongs to the pooler's server connection, so the run lock is not reliable. This is older than #556, and the fix does not change it. Not verified by a run.
  - L10. The lock session ends while the run goes on. PostgreSQL and MySQL hold the run lock on one idle session for each daemon. If the server or a proxy closes that session (PostgreSQL `idle_session_timeout`, MySQL `wait_timeout`, a failover, an idle TCP limit), the lock is gone and the daemon does not notice. A second run can then start. This is older than #556. Not verified by a run.

L1 to L7 from the comments above stay open.
```

| Limit | Status after this group | Tracked in |
|---|---|---|
| L1. In-process `--rails` runs and `--test-command` runs take no database lock | Open | #416 |
| L2. The lock is taken after the boot file and the `--require` files (U3 would fix the `--require` half on SQLite) | Open. U3 not built. | #416 |
| L3. A parallel run whose worker daemons are all down at one moment | Open | #416 |
| L4. A fallback run holds no lock while its only daemon respawns | Open, loud | #416 |
| L5. A custom SQLite VFS in a `file:` URI is locked by its path | Open | #416 |
| L6. Only the primary database is locked | Open | #416, #337 (2.0) |
| L7. A first daemon that dies after it booted | Open | #416 |
| L8. New: SQLite relies on an in-place `flock` conversion. Checked on macOS and Linux only. | Open. No known failure. | #416 (the comment above) |
| L9. New: PostgreSQL behind a pooler in transaction mode. Not verified by a run. | Open. Older than #556. | #416 (the comment above) |
| L10. New: the server or a proxy closes the idle lock session (PostgreSQL and MySQL). Not verified by a run. | Open. Older than #556. | #416 (the comment above) |
| The PostgreSQL window is in 1.10.0 and earlier releases | Fixed in 1.11.0. No backport. | #556 |

---

## Verification Contract

Run on the exact head commit, from the worktree.

| Check | Command | When |
|---|---|---|
| Suite | `bundle exec rake test` | The commit |
| Load smoke | `ruby -Ilib -e 'require "mutineer"'` | The commit |
| YARD, 100% | `bundle exec rake yard:strict` | The commit (two method comments in `lib/` change) |
| Daemon tests, SQLite | `bundle exec rake test:daemon` | Before the push. The change is in Rails daemon code. |
| Daemon tests, PostgreSQL, local | See the commands below | Before the push, if Postgres.app is on the machine |
| Daemon tests, PostgreSQL and MySQL, CI | Jobs `rails daemon postgres 16 (ruby 3.4)`, `rails daemon mysql 8 (mysql2, ruby 3.4)` and `rails daemon mysql 8 (trilogy, ruby 3.4)` | After the push |
| Author self-check | `ruby .claude/skills/author-self-check/self_check.rb origin/main`, then the steps of `.claude/skills/author-self-check/SKILL.md` | Before the first push |
| Pre-PR gate | `/ce-code-review`, `/fit-review`, `/cubic-loop` in local mode | On the head commit |

The local PostgreSQL run uses a private server that listens on a Unix socket in a new temp folder and on no TCP port. So it cannot reach another server, and the tests cannot drop a database outside it. Save the lines below as a script in a scratch folder (not in the repository) and run it with `bash` from the worktree root. `set -e` stops the script when the server does not start. The `unset` line clears the libpq variables that could point the commands at another server. The `trap` stops the server and keeps the exit code of the tests.

```sh
set -euo pipefail
# libpq reads these, and PGHOSTADDR or a service would win over the private socket.
unset DATABASE_URL PGHOSTADDR PGSERVICE PGSERVICEFILE PGPORT PGPASSWORD PGHOST
PGBIN=/Applications/Postgres.app/Contents/Versions/16/bin
PGTMP=$(mktemp -d /tmp/m11b.XXXXXX)
trap '"$PGBIN/pg_ctl" -D "$PGTMP/data" -m fast stop >/dev/null 2>&1 || true; rm -rf "$PGTMP"' EXIT
"$PGBIN/initdb" -D "$PGTMP/data" -U postgres -A trust >/dev/null
"$PGBIN/pg_ctl" -D "$PGTMP/data" -o "-c listen_addresses='' -c unix_socket_directories='$PGTMP'" -l "$PGTMP/pg.log" -w start
"$PGBIN/psql" -h "$PGTMP" -U postgres -c "create database mutineer_rails_test"
(cd test/fixtures/rails_app && BUNDLE_WITH=postgres bundle install >/dev/null)
env DB=postgres BUNDLE_WITH=postgres PGHOST="$PGTMP" PGUSER=postgres \
  PGDATABASE=mutineer_rails_test RAILS_ENV=test bundle exec ruby -Ilib -Itest test/daemon_postgres_test.rb
```

Planning ran this script: 13 runs, 0 failures, about 95 seconds on a quiet machine and 190 seconds on a busy one. Keep the temp folder path short: a Unix socket path has a limit of about 100 bytes. Never point these tests at the server on port 5432: it holds the developer's own databases. If Postgres.app is missing, skip the local run and rely on the CI job.

Not needed: the Minitest 6 run and the Prism 2 run (no change to the Minitest integration or to parsing), and the website checks (`docs/plans/` is not published, and no page of the site changes).

---

## Definition of Done

- R1 to R7 hold.
- The two unit tests fail without the `lib/` change and pass with it. The builder saw both results. The same holds for the daemon test when a local PostgreSQL server is available. Planning saw both results for both tests.
- All checks of the Verification Contract are green on the pull request head, the PostgreSQL CI job included.
- The pull request has one commit, the labels `bug`, `priority: low`, `risk: medium` and `v1.11.0`, and a body with What, Why, How, "Decisions for David" (the table above), `Closes #556` and `Refs #416`.
- The comment on #416 exists before the pull request opens, and the pull request body links to it.
- `lib/mutineer/daemon_backend.rb`, `lib/mutineer/daemon_server.rb`, `docs/rails-setup.md` and `lib/mutineer/version.rb` are unchanged.
- No probe code, debug output or abandoned attempt stays in the diff. No `eval`. No runtime gem.

---

## Open Questions

Only David can answer these. Each has a default, so the build is not blocked.

1. **Build U3 of #416 in 1.11.0?** Default: no (row 1 above).
2. **Where does the `v1.11.0` label on #416 go after the release?** Default: David moves it when he decides U3 (row 8 above).

## Second opinions

- `/fit-validate-plan` (expectation-fit 0.9.0), 2026-11-24, lenses predictability, simplicity and convention: **Ready to implement.** Lowest score 7/10. No P0, P1 or P2 finding. Three P3 findings and five advisory notes, all applied: the reason in KTD2, the SQLite sentence in the CHANGELOG entry, the time and wording of the #416 comment, anchored patterns in the fake, `LOCK_STATEMENTS=3` in the daemon test, the decision line, no `git stash`, and the Definition of Done line. Two lenses ran the unit tests themselves and saw the same results as the table in U1. The report is in the run folder of the 1.11.0 orchestrated run, outside the repository.
- Codex (`codex exec`, model `gpt-6.2-astra`, read-only), 2026-11-24: its verdict on the first draft was no-go, for one P1: the local PostgreSQL commands could go on after a failed server start and then run the tests against another server. Fixed: the script now uses a private Unix socket, `set -e` and a `trap`, and planning ran it. It also gave five P2 and two P3 points. Applied: the handoff inside the `begin` block, so a request that raises closes the session (KTD6); the limit of the same-session rule for a waiting session, which a probe confirmed (KTD1); two more assertions in the unit test (copy under the exclusive lock, the kept session), each shown to catch a wrong version; the narrower objective and CHANGELOG sentence; limit L10 (a closed lock session); the SQLite result worded as an observation; the exact evidence for each PostgreSQL version. Declined: a second server probe after a garbage collection. A collection is not deterministic, and the unit test checks the kept session directly. Codex confirmed that the call order closes the reported race and had no finding for MySQL.
