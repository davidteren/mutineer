---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
issues: [26, 27]
title: "feat: persistent app-side daemon with DB-isolated parallel workers (#26 + #27 Phase 2)"
depth: deep
created: 2026-07-01
supersedes:
  - "docs/plans/issue-26-db-isolated-parallel-spike.md (build phases)"
  - "docs/plans/issue-27-ruby-lt-3.4.md (U7–U9, Phase 2)"
spike: docs/plans/issue-26-27-phase2-spike-findings.md (PASSED)
---

# feat: Persistent app-side daemon + DB-isolated parallel workers

**Issues:** #27 (Phase 2) + #26 — one converged effort · **Gate:** the R8 spike
**PASSED** (`docs/plans/issue-26-27-phase2-spike-findings.md`) · **Builds on:** Phase 1
(PR #28), #11 (one-boot), #12 (why jobs=1), #19 (fork + AR)

---

## Summary

Phase 1 unblocked older-Ruby apps by running each mutant's suite as a *fresh*
subprocess — correct but slow (the app re-boots per mutant) and coarse (it loses
coverage narrowing and can't tell an infra error from a kill). Phase 2 replaces
that with **one persistent daemon** that boots the app **once** and **forks per
mutant**, restoring the one-boot speed, restoring coverage-guided test selection,
and — by giving each parallel worker its **own database** — making `--jobs N`
safe under Rails for the first time (the #26 goal). The spike proved every piece
of this end-to-end, including a daemon on Ruby 3.3.6 (< 3.4) driven by the 3.4
tool. One daemon design serves both issues; it supersedes #26's standalone-daemon
framing and #27's U7–U9.

---

## What / Why / How (plain language)

**What.** Make mutation testing on a Rails app both *fast* and *parallel-safe*.
Today a full audit is either slow (Phase 1: re-boots the app for every single
mutant) or unsafe in parallel (`--jobs 4` corrupts results because all workers
share one test database and clobber each other's fixtures).

**Why it matters.** A real audit is hundreds of mutants; per-mutant boot makes it
"tens of minutes to hours." Parallelism is the one measured high-impact lever —
but only if it's *correct*. Both problems have the same root: there was no
long-lived, per-worker-isolated place to run the tests.

**How.** A small helper process (the "daemon") runs inside the app's own bundle,
boots the app once, and waits for work. For each mutant the tool sends it —
already-mutated source text plus which tests to run and which worker slot to use —
the daemon forks a child, points that child's database connection at *that
worker's own database*, loads the text, runs the tests, and reports back
survived/killed/error/timeout. N workers run at once, each with its own database,
so parallel results exactly match serial. All the parsing and mutating stays in
the tool (Ruby ≥ 3.4); the daemon only loads ready-made text, so the app's bundle
never needs mutineer and can be any older Ruby.

Glossary: *mutant* = one small code change; *killed* = tests caught it; *worker*
= one parallel execution slot; *fixtures* = seed rows a test DB is loaded with.

---

## Problem Frame

Two shipped states, both deficient, with one shared cause:

- **Phase 1 (subprocess) — slow + coarse.** `Runner.execute_external`
  (`lib/mutineer/runner.rb`) spawns a fresh `bundle exec` per mutant via
  `lib/mutineer/external_backend.rb`. Correct on any Ruby, but the app re-boots
  every mutant (no one-boot), coverage narrowing is gone (every mutant runs the
  full `--test` set), and the exit-code→verdict mapping can't distinguish an
  infra failure from a kill (documented upper-bound, KTD-3 of the Phase 1 plan).
- **In-process `--jobs N` — fast but unsafe under Rails.** `Runner.execute` boots
  once and forks via `WorkerPool`, but `--jobs > 1` under `--rails` is
  correctness-broken (#12/#26): parallel forks share one DB and clobber each
  other's transactional fixtures (measured: 100% vs true 71.4%, 18 PG deadlock
  warnings). It is forced serial to stay correct.

**Shared cause:** no persistent, per-worker-DB-isolated execution context. Phase 2
builds exactly that. The spike proved the mechanism (boot-once daemon + fork +
per-worker DB → N=2 == serial, cross-Ruby).

---

## Requirements

- **R1.** A persistent daemon boots the app once and serves per-mutant test runs
  over IPC; its serial verdicts are identical to the in-process and Phase 1 paths
  on the same mutants. *(Phase 2a)*
- **R2.** The daemon returns a **structured verdict** distinguishing
  `survived / killed / error / timeout` natively — fixing Phase 1's coarse mapping
  for failures *outside* the test body. In-test infra errors (a worker-DB failure
  raised through Minitest) are tagged `error` only via the KTD-8 adapter's re-raise
  wrapper; absent that, the score stays an upper bound for that case and says so. *(2a)*
- **R3.** Daemon lifecycle is robust: spawn under the app's bundle, a ready
  handshake, graceful shutdown, crash detection with restart, and a per-fork
  timeout so one hung mutant can never wedge the daemon. *(2a)*
- **R4.** All mutation/parsing/Prism/subject-discovery stays tool-side (KTD-2);
  the daemon receives ready-to-`load` text and needs neither Prism nor mutineer
  (proven: daemon ran on 3.3.6). *(2a)*
- **R5.** Worker-DB **provisioning** for **Postgres and SQLite**: create + load
  schema for `<db>_test-0..N-1` (mirror Rails `parallelize` naming), idempotent.
  Missing-DB handling is the single rule in KTD-9 (explicit `--jobs N>1` → error;
  default → force 1 with a notice) — never silent corruption (the #12 failure). *(Phase 2b)*
- **R6.** Per-worker AR **connection routing after fork** via a framework-agnostic
  `after_fork` hook (Rails adapter establishes the worker's connection; non-Rails
  passes no hook); `WorkerPool` supplies each fork its worker index `0..N-1`. *(2b)*
- **R7.** `--jobs N` under the daemon yields verdicts **identical to `--jobs 1`**
  on a fixture-backed write-heavy case, with **zero DB warnings** and a measurable
  speedup. *(2b)*
- **R8.** Coverage narrowing is **restored** on the daemon path (daemon-side
  `Coverage` + coverage map), and coverage capture parallelizes on the isolated
  workers (#26 P4). *(Phase 2c)*
- **R9.** **Backend selection** via a `--daemon` boolean opt-in (not an enum);
  `--test-command` + `--daemon` together is a usage error (KTD-10). Missing-DB
  handling per the KTD-9 rule (preserve #12 safety). *(2c)*
- **R10.** The gem **core** stays Prism + stdlib, zero runtime deps, no `eval`;
  Rails DB routing uses the app's **own** already-loaded ActiveRecord through the
  `after_fork` adapter — never a new mutineer gem dependency. *(all)*

---

## Key Technical Decisions

**KTD-1 — One daemon serves both issues.** #27's "persistent app-side worker" and
#26's "DB-isolated parallel workers" are the same process: a booted-once app
runtime that forks per mutant. #26's parallelism is that daemon forking N children
concurrently, each routed to its own DB. Supersedes both source plans' Phase-2
framings.

**KTD-2 — Mutation stays tool-side; daemon only `load`s (carry KTD-7).** The tool
(≥3.4) does all Prism parsing, subject discovery, mutation generation, and the
surgical-snippet reparse validation (`isolation.rb`), then ships the daemon a
**ready-to-`load` payload**. The daemon needs no Prism and no mutineer — proven by
the 3.3.6 run against a mutineer-free bundle. This is what makes the app bundle
free to be any older Ruby.

**KTD-3 — Default to the spike-proven whole-file reload; redefine snippet is opt-in.**
The spike PASSED end-to-end on whole-file `load` (reload), so that is the **default**
daemon payload — ship what was validated. Reload re-runs file-level code and
re-defines constants (benign but noisy `already initialized constant` warnings, and
unsafe for files with load-time side effects); the tool-side **wrapped redefine
snippet** (the surgical single-method form, `Isolation.apply_surgical`'s output)
avoids that and is available as the opt-in payload for side-effecting files. The
daemon just `load`s whichever it receives. **Do not flip the default to redefine until
the U4/U7 gates show reload's re-execution actually bites** — and when redefine is
exercised, prove `redefine == reload` verdicts separately (it carries edge cases
reload doesn't: scope-collapse C2, singleton #20, compact-namespace #5, visibility,
reparse validation).

**KTD-4 — IPC = newline-delimited JSON; source carried as an escaped JSON string.**
Zero-dep (stdlib `json`), human-debuggable, and — critically — **version-agnostic**
across the tool/daemon Ruby boundary (Marshal is rejected: it couples Ruby
versions and undoes KTD-2's decoupling). Multiline source is a normal JSON string;
no separate framing needed. One JSON object per line, both directions.
- **Request:** `{id, worker, payload:{kind:"redefine"|"reload", code, ...}, tests:[...], timeout}`
- **Response:** `{id, verdict:"survived"|"killed"|"error"|"timeout", worker, detail?}`
- A control line `{cmd:"quit"}` shuts the daemon down; the daemon's first line is a
  ready handshake `{ready:true, ruby:"..."}`.

**KTD-5 — Structured verdict at the source (improves on Phase 1 KTD-3).** The daemon's
fork exits with a code the daemon maps to a verdict *with app-side knowledge the tool
lacks*: `0=survived`, `1=killed`, `2=error` (the child raised **around** the test —
LoadError, boot failure), plus parent-detected `timeout`. This restores the `error`
state the Phase 1 subprocess path collapsed into `killed` for failures that surface
*outside* the test body.

**Honest limit (must be stated in R2/docs, not overclaimed):** the shipped harness
tags killed vs error by *where* the exception is caught, not *what* it is —
`MinitestIntegration.run` returns 1 for any failure/error → `killed`; only an exception
escaping `Minitest.run` becomes exit 2. So a worker-DB deadlock/connection-drop that
fires *inside a test's queries* (exactly the #26 concurrency failure) surfaces as a
Minitest error → `killed`, **not** `error`. To make the "exact, not upper bound" claim
true for that case, the `after_fork` DB adapter (KTD-8) must wrap the test run and
**re-raise AR/connection errors past Minitest so the child exits 2** (tagged `error`).
Absent that wrapper, the daemon score is still an upper bound for in-test infra errors
— state it plainly rather than claim exactness. U9 asserts: worker DB unreachable
mid-test → `error`, not `killed`.

**KTD-6 — Child stdout is isolated from the IPC pipe (spike lesson).** A forked
child shares the daemon's stdout — Minitest/schema output would corrupt the JSON
channel. The child reopens `$stdout` to `File::NULL` before running; only the
parent writes verdicts, after `waitpid`. (Captured child output, when needed for
`--verbose` or an `error` detail, goes through a separate captured fd, not the IPC
pipe.)

**KTD-7 — Isolation via separate databases (carry #26 KTD1), Postgres-first.** Each
worker gets its own database `<db>_test-0..N-1` (Rails `parallelize` naming), not
shared-DB locking. Provisioning supports **Postgres** (the measured #26 corruption
case: `CREATE DATABASE` + schema load per worker) **and SQLite** (per-worker file,
spike-proven, hermetic for CI). The routing after fork is one `establish_connection`
to the worker's config — adapter-agnostic.

**KTD-8 — `after_fork` hook keeps the core framework-agnostic (carry #26 KTD2).**
`WorkerPool`/the daemon core stay stdlib and know nothing about Rails. DB routing lives
in a Rails **adapter** invoked via an `after_fork(worker)` hook; a non-Rails run passes
no hook and behaves as today. The adapter follows the existing zero-dep discipline —
it probes `defined?(ActiveRecord::Base)` and **never `require "active_record"`**
(exactly as `Runner.reconnect_active_record` documents) — so it uses the app's own
already-loaded AR and adds no gem dependency (R10). It extends
`reconnect_active_record` + `fixture_transaction_open?` (#8/#19) rather than replacing
them, and also owns the KTD-5 re-raise of AR errors past Minitest so an in-test DB
failure is tagged `error`.

**KTD-9 — Correctness gate is non-negotiable (carry #26 KTD3), and one missing-DB
rule.** The daemon and any parallel mode must prove `== serial` verdicts (R7) before
becoming a default; until then they are opt-in with a loud precondition check. **One
canonical behavior when the worker DBs are absent** (aligns R5/R9/U5/U8, never
silent):
- **Explicit `--jobs N>1`** requested but worker DBs missing → **clear actionable
  error, zero mutants run** (the user asked for unsafe parallelism; refuse, don't
  corrupt — the #12 failure).
- **No explicit `--jobs`** (default) under the daemon → **force 1 with a loud notice**
  (the user didn't ask for parallelism; run serially so the audit completes). Mirrors
  Phase 1's explicit-vs-default `--jobs` handling (`config.rb` resolve).

**KTD-10 — Backend selection: a `--daemon` boolean opt-in, not a backend enum.** The
daemon is opt-in; a single `--daemon` boolean (gated on `--rails`/boot + worker-DBs,
per KTD-9) turns it on with no precedence machinery — matching the shipped
`--test-command`/`--baseline` flag pattern. Resolution: `--test-command` selects the
Phase 1 subprocess path; `--daemon` selects the Phase 2 daemon; **passing both is a
usage error** ("choose one backend", exit 2 — never silently pick one over the
other); absent both, the in-process path is unchanged. Defer a general `--backend`
enumerator until a genuine third opt-in backend or a real new conflict exists.

---

## High-Level Technical Design

### Architecture: tool (≥3.4) vs daemon (app bundle, any Ruby)

```
┌─ tool process (Ruby ≥ 3.4, mutineer) ───────────┐         ┌─ daemon (app bundle, any Ruby; NO mutineer/Prism) ─┐
│ Prism parse · subjects · mutations · coverage    │  spawn  │ boot app ONCE (config/environment)                 │
│ ready-to-load payload per mutant (KTD-2/3)       │────────▶│ provision/attach worker DBs 0..N-1 (KTD-7)         │
│ WorkerPool: assign worker slot 0..N-1 (KTD-8)    │         │ request loop (newline JSON, KTD-4):                │
│ send request  ─────────────────────────────────────JSON──▶│   fork child:                                      │
│                                                  │         │     $stdout→/dev/null (KTD-6)                       │
│                                                  │         │     after_fork(worker): AR → worker DB (KTD-8)     │
│                                                  │         │     load(payload.code); run tests                  │
│ read structured verdict ◀──────────────────────────JSON───│   waitpid → verdict (KTD-5); reply                 │
│ survived/killed/error/timeout                    │         │ {cmd:quit} → graceful shutdown                     │
└──────────────────────────────────────────────────┘         └────────────────────────────────────────────────────┘
   crash/health: tool detects EOF/exit, restarts the daemon (R3)
```

### Per-mutant sequence (one worker)

```
tool                                   daemon                         forked child (worker N)
 │ build payload (redefine snippet)
 │ pick worker slot N
 │ send {id,worker:N,payload,tests,timeout} ─▶ read request
 │                                            fork ───────────────────▶ $stdout→NULL
 │                                            │                         after_fork(N): AR→<db>_test-N
 │                                            │                         load(code); run covering tests
 │                                            │                         exit 0/1/2  ◀── framework result
 │                                            waitpid → map to verdict
 │ read {id,verdict} ◀───────────────────────┘ (per-fork timeout: SIGKILL the child's
 │                                               process group, verdict=timeout — never wedges the loop)
 ▼ next mutant (slot freed)
```

### Parallel N=2 (the #26 payoff)

```
daemon forks child-0 (→ db_test-0) and child-1 (→ db_test-1) CONCURRENTLY;
each runs its mutant's covering tests against its OWN database → no fixture
cross-talk → verdicts identical to serial (R7). Coverage capture fans out
the same way (R8).
```

### Backend selection (KTD-10)

```
--test-command AND --daemon? ──yes─▶ usage error "choose one backend" (exit 2)
      │no
--test-command set? ──yes─▶ Phase 1 subprocess
      │no
--daemon set (requires --rails/boot; jobs gated on worker DBs, KTD-9)? ──yes─▶ Phase 2 daemon
      │no
in-process (today)
```

---

## Phased Delivery

- **Phase 2a — Daemon core (U2–U4).** Boot-once daemon, inline newline-JSON IPC,
  structured verdict, lifecycle, tool-side payload. Serial only (one worker); proves
  daemon verdicts == in-process/Phase-1 serial. Ships value alone (one-boot speed +
  `error`-for-load-failures on the daemon path).
- **Phase 2b — DB isolation + parallelism (U5–U6).** Worker-DB provisioning
  (PG + SQLite) and `after_fork` routing; `WorkerPool` per-worker index; the
  correctness gate `--jobs N == --jobs 1`.
- **Phase 2c — Coverage, selection, verification (U7–U9).** Restore coverage
  narrowing on the daemon path + parallelize capture; backend-selection flag and
  safety defaults; the Rails dogfood verification suite (PG + SQLite).

---

## Implementation Units

> The IPC framing is stdlib `JSON.generate`/`JSON.parse` inline (KTD-4 — no separate
> `protocol.rb`), and the payload builder is one tool-side method reusing
> `Isolation.apply_surgical`; both live in U2 (daemon-side decode) and U4 (tool-side
> build) rather than their own files/unit. (The former "U1" folded in here — U-IDs
> are not reused.) Files are flat compound-named, matching the repo's
> `external_backend.rb`/`isolation.rb` norm, not a `daemon/` subdir.

### U2. Daemon process — boot once, request loop, fork-per-mutant

**Goal:** The app-side daemon: boot the app once, serve requests, fork a child per
mutant that runs the covering tests and exits with the KTD-5 code, isolate child
stdout from the pipe, enforce a per-fork timeout.
**Requirements:** R1, R2, R3, R4.
**Dependencies:** none.
**Files:** new `lib/mutineer/daemon_server.rb` (the app-side daemon entry;
loadable WITHOUT Prism/mutineer per R4), `test/daemon_server_test.rb`.
**Approach:** Boot via the configured boot file once (like `Runner.execute` boot
mode); put the app's test root on `$LOAD_PATH` (spike lesson). Read requests inline
with `JSON.parse(line)` and reply with `JSON.generate` (KTD-4 — no framing module).
Per request: fork, `$stdout.reopen(File::NULL)` (KTD-6), apply the `after_fork` hook
(U5; no-op in 2a), `load` the payload `code`, run the covering tests via the
framework runner, exit `0/1/2` (map to verdict per KTD-5 — with the honest in-test
limit; the KTD-8 adapter owns the DB-error re-raise). Parent `waitpid2` with a
wall-clock deadline mirroring `Isolation` + Phase 1 `ExternalBackend.wait_with_timeout`
(SIGKILL the child's **process group** on breach — carry the Phase 1 pgroup fix);
map to verdict; reply. Never let a child error or hang propagate into the loop.
**Patterns to follow:** `lib/mutineer/isolation.rb` (fork + deadline + decode — but
cannot be `require`d here: it pulls in Prism, forbidden app-side, so re-implement the
Prism-free fork/timeout/decode core); `lib/mutineer/external_backend.rb` (pgroup
kill, timeout loop); `Runner.execute` boot-mode `$LOAD_PATH` handling; the throwaway
`spike/daemon.rb` as reference.
**Execution note:** Start with a failing test that boots the daemon against the
bundled fixture app and asserts one correct `survived` + one `killed` verdict.
**Test scenarios:**
- Boots once; serves 3 sequential mutants with correct survived/killed/error verdicts (fixture app).
- Round-trip a request with multiline source (newlines/quotes/UTF-8 preserved) — the inline JSON channel is multiline-safe.
- Child Minitest output does NOT appear on the IPC channel (KTD-6 — assert the reply line is clean JSON).
- A mutant that raises **on load** → `error` (not killed) — the structured-verdict win outside the test body.
- A hung child (infinite loop) → `timeout`, its process group is killed, and the daemon serves the NEXT request normally (loop not wedged).
- A malformed/truncated request line → a protocol error reply, not a daemon crash.
- `{cmd:quit}` → clean shutdown, exit 0.

### U3. Tool-side daemon client — spawn under app bundle, lifecycle, crash-restart

**Goal:** The tool-side handle that spawns the daemon under the app's bundle/Ruby,
completes the ready handshake, sends requests / reads verdicts, detects a crash
(EOF/exit) and restarts, and shuts down gracefully.
**Requirements:** R1, R3.
**Dependencies:** U2.
**Files:** new `lib/mutineer/daemon_client.rb`, `test/daemon_client_test.rb`.
**Approach:** Spawn `bundle exec ruby <daemon entry>` in the app dir with a cleaned
env (strip the gem's `BUNDLE_*`, set the app `BUNDLE_GEMFILE`, honor `RBENV_VERSION`)
— the exact pattern proven in `spike/driver.rb`. Drain daemon stderr to the tool's
stderr (surface child errors). Ready handshake before first request. On an
unexpected EOF/exit mid-run: mark the in-flight mutant `error`, respawn the daemon,
continue (bounded restart count → hard fail with a clear message). Graceful `quit`
on completion.
**Patterns to follow:** `spike/driver.rb` (cleaned-env spawn, handshake, stderr
drain); `lib/mutineer/external_backend.rb` (spawn discipline).
**Test scenarios:**
- Spawn + handshake against the fixture app; one request returns the expected verdict.
- Daemon killed mid-run → client respawns and the run completes; the interrupted mutant is `error`, not a wrong verdict.
- Repeated crashes past the restart cap → clean hard failure with an actionable message (not an infinite respawn loop).
- Graceful shutdown leaves no orphaned daemon/child processes.

### U4. Wire the daemon backend into the runner (serial first)

**Goal:** A daemon execution path in `Runner` selected when the daemon backend is
chosen: build the per-mutant payload (the folded-in tool-side builder), drive one
daemon (serial) via U3, aggregate identically. Proves daemon serial verdicts ==
in-process/Phase-1.
**Requirements:** R1, R2, R9 (partial — serial path).
**Dependencies:** U2, U3.
**Files:** `lib/mutineer/runner.rb` (new `execute_daemon` + a payload builder reusing
`Isolation.apply_surgical` for the redefine snippet / whole-file text; reuse
`collect_jobs`), `test/runner_daemon_test.rb`.
**Approach:** Branch like `execute_external` does for `--test-command`; reuse
`collect_jobs` (shared selection — no drift). For each job build the payload
(**whole-file reload by default**, KTD-3; the redefine snippet is the opt-in), where
the redefine snippet reparses cleanly tool-side before send (never ship an invalid
snippet — mirrors Phase 1 KTD-8). Send to the daemon, attach subject/mutation/id to
the returned verdict, honor `--fail-fast`. Coverage selection wired in U7; here run
the provided `--test` set (like Phase 1) so the path lands before U7.
**Patterns to follow:** `Runner.execute_external` (Phase 1 branch + aggregate);
`collect_jobs`; `Isolation.apply_surgical`/`apply_whole_file`; `AggregateResult`.
**Test scenarios:**
- Daemon-path verdicts on the fixture app == the in-process `--rails` verdicts for the same mutants, **holding the strategy constant (reload both sides)** — the R1 correctness identity, one variable at a time.
- Separately: `redefine == reload` verdicts on the same mutants (proves the opt-in payload doesn't change outcomes before it can be chosen).
- Payload round-trip carries multiline source intact; an invalid redefine snippet is caught tool-side and never sent.
- `error` verdict surfaces distinctly (a load-error mutant) — not folded into killed/survived.
- `--fail-fast` stops at the first survivor on the daemon path.
- Absent the daemon backend → in-process/Phase-1 paths unchanged (regression guard).

### U5. Worker-DB provisioning + per-worker after-fork routing (Postgres + SQLite)

**Goal:** Provision N isolated worker DBs (idempotent) and route each fork's
ActiveRecord to its worker DB via a framework-agnostic `after_fork` hook; make the
daemon fork N children concurrently across workers.
**Requirements:** R5, R6, R7, R10.
**Dependencies:** U2, U4.
**Files:** new `lib/mutineer/rails_worker_db.rb` (flat, matching the repo's
adapter-file naming — Rails adapter: provision + `after_fork(worker)` routing,
loaded app-side, uses the app's own AR), `lib/mutineer/daemon_server.rb` (accept a
worker index; invoke the hook), `lib/mutineer/worker_pool.rb` (supply a per-worker
index 0..N-1), `test/rails_worker_db_test.rb`, extend `test/fixtures/rails_app` DB
config for worker DBs (PG + SQLite).
**Approach:** The adapter follows the zero-dep discipline — probe
`defined?(ActiveRecord::Base)`, **never `require "active_record"`** (as
`reconnect_active_record` documents, R10). Provision: for **SQLite**, per-worker
file `<db>_test-N.sqlite3` + `load schema` (spike-proven). For **Postgres**,
`CREATE DATABASE <db>_test-N` if absent + schema load, via
`ActiveRecord::Tasks::DatabaseTasks` (idempotent — skip existing). Naming mirrors
Rails `parallelize` (`_test-0..N-1`). Routing: extend `Runner.reconnect_active_record`
into `after_fork(worker)` that `establish_connection`s to that worker's
config/`DATABASE_URL`, preserving the `fixture_transaction_open?` guard (#8). The
adapter also **wraps the test run to re-raise AR/connection errors past Minitest so
the child exits 2 (`error`)** — the KTD-5 honest-limit fix (an in-test worker-DB
failure is `error`, not `killed`). `WorkerPool` threads a stable worker index so
each concurrent fork picks its DB. Missing-DB handling per the KTD-9 rule (explicit
`--jobs N>1` → error, zero mutants; default → force 1 with a notice) — never corrupt.
**Patterns to follow:** `Runner.reconnect_active_record` / `fixture_transaction_open?`
(`lib/mutineer/runner.rb`); `lib/mutineer/worker_pool.rb`; Rails `parallelize`
naming; the spike's per-worker `establish_connection`.
**Execution note:** Test-first on the correctness identity — a fixture-backed
write-touching test under N=2 must equal N=1 before optimizing anything.
**Test scenarios:**
- Provisioning is idempotent: running twice creates nothing new, errors on neither adapter.
- **Covers R7.** N=2 verdicts == N=1 on the fixture app's strong + weak suites (Postgres AND SQLite), with **zero** DB deadlock / referential-integrity warnings.
- Each concurrent fork connects to a distinct `<db>_test-N` (assert the two workers used two DBs).
- **Worker DB unreachable mid-test → `error`, not `killed`** (the KTD-5 re-raise; asserts the in-test infra-error distinction actually holds).
- Explicit `--jobs 2` with worker DBs absent → clear actionable error, zero mutants run; a default run with DBs absent → forced to 1 with a notice (KTD-9).
- Transactional-fixture rollback still isolates tests within a worker (the #8 guard holds after routing).
- Non-Rails run passes no hook → behaves exactly as today (regression).

### U6. Parallelize the daemon (N concurrent workers end-to-end)

**Goal:** Drive N daemon workers concurrently from the runner over the isolated DBs,
producing the measured speedup with identical verdicts.
**Requirements:** R7, R9.
**Dependencies:** U5.
**Files:** `lib/mutineer/runner.rb` (`execute_daemon` fans out across N workers),
`lib/mutineer/daemon_client.rb` (multiplex / or N daemon handles),
`test/runner_daemon_parallel_test.rb`.
**Approach:** Either one daemon forking N concurrent children, or N daemon handles
(one per worker) — choose per the simplest correct shape (the spike used N handles;
one-daemon-N-forks is lighter on boots). Schedule jobs across workers via
`WorkerPool`, each carrying its worker index (U5). Aggregate identically; honor
`--fail-fast` (drain in-flight, stop scheduling).
**Test scenarios:**
- N=2 full-run verdicts == serial full-run verdicts on the fixture app (end-to-end, not just per-mutant).
- Measurable wall-clock drop vs serial on a multi-mutant run.
- `--fail-fast` under N=2 stops scheduling after the first survivor; in-flight workers drain cleanly.
- A worker's daemon crash mid-run is contained (U3 restart) without corrupting other workers' verdicts.

### U7. Restore coverage narrowing on the daemon path (+ parallel capture)

**Goal:** Re-enable coverage-guided per-mutant test selection on the daemon path
(lost in Phase 1), and parallelize coverage capture on the isolated workers.
**Requirements:** R8.
**Dependencies:** U4, U5.
**Files:** `lib/mutineer/daemon_server.rb` (run `Coverage` in-process; build/serve
the coverage map), `lib/mutineer/coverage_map.rb` (reuse `build_via_fork` daemon-
side), `lib/mutineer/runner.rb` (select covering tests per mutant on the daemon
path), `test/daemon_coverage_test.rb`.
**Approach:** The daemon boots with `Coverage.start` before the app require (as
`Runner.execute` boot mode does), builds the coverage map by forking the booted app
(`CoverageMap#build_via_fork`), and returns per-mutant covering tests — so the tool
sends only the covering set, not the full `--test` set. Capture forks route to
worker DBs too (U5), so capture parallelizes (#26 P4). This also makes the daemon
score directly comparable to the in-process score (removing Phase 1 KTD-6's
non-comparability caveat on this path).
**Patterns to follow:** `Runner.execute` boot-mode coverage
(`CoverageMap#build_via_fork`, `runner.rb`); `coverage_map.rb`.
**Test scenarios:**
- A mutant on an uncovered line → `no_coverage` (excluded), NOT run as `survived` (the Phase 1 regression is gone on this path).
- Per-mutant covering-test selection matches the in-process boot-mode selection for the same sources/tests.
- Coverage capture runs across ≥2 workers without DB cross-talk (isolated), producing the same map as serial capture.
- Daemon-path score == in-process score on the fixture app (comparability restored).

### U8. `--daemon` opt-in flag + safety defaults

**Goal:** A `--daemon` boolean that selects the Phase 2 backend, with the KTD-9/KTD-10
safety and collision rules.
**Requirements:** R9, R10.
**Dependencies:** U4, U5.
**Files:** `lib/mutineer/cli.rb` (`--daemon` flag + `validate_daemon!` + usage),
`lib/mutineer/config.rb` (boolean field + KNOWN_KEYS/coerce), `test/cli_daemon_test.rb`.
**Approach:** Add a `--daemon` boolean following the existing explicit-tracking flag
pattern (like `--test-command`/`--baseline`) — not a general `--backend` enum
(KTD-10). In `validate!`: (a) `--daemon` + `--test-command` → usage error "choose one
backend" (exit 2); (b) `--daemon` without `--rails`/boot → usage error; (c) the
missing-worker-DB rule (KTD-9): explicit `--jobs N>1` + DBs absent → error, zero
mutants; default `--jobs` + DBs absent → force 1 with a loud notice. Document the
daemon workflow.
**Patterns to follow:** Phase 1 `--test-command` flag + `validate_test_command!`
(`lib/mutineer/cli.rb`); `Config` field/KNOWN_KEYS/coerce.
**Test scenarios:**
- `--daemon` selects the daemon path; absent it, the default path is unchanged (regression).
- `--daemon` + `--test-command` → usage error "choose one backend" (exit 2).
- `--daemon` without `--rails`/boot → clear usage error.
- `--daemon --jobs 4` (explicit) with worker DBs absent → error, zero mutants run.
- `--daemon` (default jobs) with worker DBs absent → forced to 1 with a notice.

### U9. Rails dogfood verification + docs

**Goal:** Prove the whole thing end-to-end in CI on the bundled fixture app (PG +
SQLite), with the correctness identity and the structured-verdict distinctions;
document the daemon workflow and setup.
**Requirements:** R7, R2, R8.
**Dependencies:** U5, U6, U7, U8.
**Files:** extend `test/fixtures/rails_app` (worker-DB config, a write-heavy
fixture-backed test — the #19 family), new `test/rails_dogfood_daemon_test.rb`,
`README.md`, `CHANGELOG.md`, a CI job (SQLite always; Postgres via a CI service).
**Approach:** A dogfood test that provisions worker DBs and asserts `--jobs 2 ==
--jobs 1` verdicts with zero DB warnings on both adapters (PG behind a CI service,
SQLite hermetic), plus a test asserting `error` vs `killed` vs `timeout` are
distinguished. Document the daemon backend, worker-DB provisioning/setup, and when
to use daemon vs Phase 1 subprocess vs in-process.
**Test scenarios:**
- **Covers R7.** Dogfood: `--jobs 2` verdicts == `--jobs 1`, zero deadlock/referential-integrity warnings (PG + SQLite).
- **Covers R2.** A load-error mutant reports `error`; a hung mutant reports `timeout`; a real gap reports `survived` — all distinct in the report.
- Gem's own suite stays green (core Prism+stdlib unchanged; no new runtime dep) — regression guard.
- Docs section renders the workflow, provisioning, and backend-selection guidance.

---

## Scope Boundaries

**In scope:** the daemon (boot-once + fork-per-mutant), IPC protocol + structured
verdict, lifecycle/crash-restart, worker-DB provisioning (Postgres + SQLite) +
after-fork routing, N-worker parallelism with the `== serial` gate, restored +
parallelized coverage, backend selection + safety defaults, Rails dogfood
verification.

### Deferred to Follow-Up Work

- **Making the daemon the default backend.** Ships opt-in via `--daemon` (KTD-10);
  flip to default only after R7 holds in CI across adapters (KTD-9).
- **Auto-provisioning worker DBs.** This plan provisions explicitly with a clear
  missing-DB error; a `--provision`/auto path is a fast-follow once naming/idempotency
  are proven.
- **Non-fixture / connection-pool DB strategies** (schema-per-worker as a lighter
  PG variant; `DATABASE_URL`-only apps). Evaluate after the separate-database path
  ships.
- **MySQL and other adapters.** Postgres + SQLite first; others on demand.

### Outside this effort's identity

- **A new mutineer runtime dependency for DB work.** The Rails adapter uses the
  app's own ActiveRecord via the `after_fork` hook; the gem core stays zero-dep
  (R10). Non-negotiable.

---

## Risks & Dependencies

- **R (correctness): parallel verdicts diverge from serial** — the whole #26
  reason-for-being. *Mitigation:* KTD-9 gate; U5/U6/U9 assert `== serial` on
  fixture-backed write-heavy cases, both adapters, before the daemon can default.
  Test-first on this identity.
- **R (data/infra): Postgres worker-DB provisioning is environment-coupled**
  (roles, `CREATE DATABASE` perms, CI service). *Mitigation:* idempotent
  provisioning with a clear actionable error; SQLite path stays hermetic for CI;
  PG behind a CI service (U9).
- **R (reliability): daemon crash or a hung mutant wedges the run.** *Mitigation:*
  per-fork process-group timeout (KTD-6, carried from Phase 1) + bounded
  crash-restart (U3); a hung/ crashed mutant becomes `timeout`/`error`, never a
  stall or wrong verdict.
- **R (correctness): IPC channel corruption from child output** (the spike hit
  this). *Mitigation:* KTD-6 child-stdout isolation; U2 asserts a clean channel.
- **R (scope): the daemon re-implements fork/timeout/coverage that in-process
  already has.** *Mitigation:* reuse `Isolation`, `ExternalBackend`'s timeout loop,
  `CoverageMap#build_via_fork`, `reconnect_active_record`, `collect_jobs` — extend,
  don't fork the logic.
- **Dependency:** builds directly on Phase 1 (PR #28) merged; the spike
  (`spike/`, gitignored) is the reference implementation.

---

## Definition of Done

- A persistent daemon boots the app once and serves per-mutant runs; its serial
  verdicts are identical to the in-process/Phase-1 paths (R1), with a **structured
  verdict** distinguishing survived/killed/error/timeout (R2).
- Daemon lifecycle is robust: spawn-under-bundle, handshake, per-fork timeout,
  crash-restart, graceful shutdown; no orphaned processes (R3).
- Mutation stays tool-side; the daemon needs no Prism/mutineer (R4).
- Worker DBs provision idempotently for Postgres and SQLite with a clear missing-DB
  error (R5); each fork routes to its own DB via the framework-agnostic after-fork
  hook (R6).
- `--jobs N` verdicts are **identical to `--jobs 1`** on a fixture-backed
  write-heavy case, zero DB warnings, measurable speedup — both adapters (R7).
- Coverage narrowing is restored on the daemon path and capture parallelizes (R8);
  the daemon-path score is comparable to the in-process score.
- Backend selection + safety defaults in place; `--jobs N` stays 1 without worker
  DBs (R9). Gem core stays Prism+stdlib zero-dep, no eval (R10).
- Rails dogfood verification green in CI (SQLite always; Postgres via service); the
  gem's own suite stays green.

---

## Verification Contract

- **Unit:** each U1–U9 unit's test scenarios; feature-bearing units test happy
  path + error/edge (load-error→error, hang→timeout, missing-DB→clear error) +
  the cross-worker isolation integration.
- **Correctness identity (the gate):** `--jobs 2 == --jobs 1` verdicts on the
  fixture app's strong + weak + a write-heavy suite, Postgres AND SQLite, zero DB
  warnings (U5/U6/U9). Non-negotiable before the daemon can default (KTD-9).
- **Equivalence:** daemon serial verdicts == in-process `--rails` verdicts on the
  same mutants (U4); daemon-path coverage selection == in-process boot-mode
  selection (U7).
- **Regression:** gem's own suite green (core unchanged, no new runtime dep);
  in-process and Phase-1 subprocess paths unchanged when the daemon isn't selected.
- **CI:** SQLite dogfood hermetic; Postgres dogfood behind a CI service.
