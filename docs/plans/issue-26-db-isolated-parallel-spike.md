---
title: Issue #26 — DB-isolated parallel workers (spike + phased plan)
type: feat / spike
date: 2026-07-01
artifact_readiness: spike-first
execution: code
---

# Issue #26 — DB-isolated parallel workers

**One-line goal:** Make `--jobs N` safe under `--rails` by giving each worker its own database, so
parallel mutant execution matches serial verdicts exactly — the only high-impact speed lever
(everything else is marginal; measured).

**Depends on:** #12 (why jobs=1), #19 (fork + AR reconnect), #11 (one-boot multi-source).

## Measured motivation (don't re-derive)
- Boot 1.26s (once). One test run ~3.5s. **Per mutant ≈ 3.5s, serial** → full audit = tens of min–hours.
- **Naive `--jobs 4` is correctness-broken:** 100% vs true 71.4%, a survivor→"errored", 18 PG
  deadlock / referential-integrity warnings. Parallel forks share ONE DB and clobber each other's
  fixture transactions. Serial is the only *correct* mode today.

## The make-or-break question (spike this FIRST — ~1 day, throwaway)
> Can a forked worker, booted from a shared parent, run its covering test against an **isolated
> database** and produce the **same kill/survive verdict as serial**, with N=2 deterministic?

If per-worker DB routing after fork can't be made clean, the feature is blocked — learn it cheaply.
Everything below assumes the spike succeeds.

### Spike steps
1. Provision 2 test DBs from the app's config (`<database>_test-0`, `-1`): create + load schema
   (`ActiveRecord::Tasks::DatabaseTasks` or `db:test:prepare` per worker DB). Mirror Rails
   `parallelize` naming so users recognise it.
2. In each forked worker, before running the test: point ActiveRecord at that worker's DB
   (`ActiveRecord::Base.establish_connection` with the worker's config / a per-worker `DATABASE_URL`),
   extending the existing `Runner.reconnect_active_record` (which currently just drops the shared
   connection). Reconnect happens post-fork so no socket is shared.
3. Run the SAME weak/strong fixture-backed mutant under N=2 and assert: verdicts identical to `--jobs 1`,
   zero deadlock/referential-integrity warnings, real speedup.
4. Verify against a genuinely write-heavy fixture-backed test (the #19 family) — the exact case that
   corrupts today.

**Spike exit criteria:** N=2 parallel == serial verdicts, no DB warnings, measurable wall-clock drop.

## Phased build (only if the spike passes)
- **P1 — Worker-DB provisioning.** A setup path that creates/migrates N worker DBs (idempotent), and a
  clear actionable error when `--jobs N --rails` is asked but the worker DBs aren't present (don't
  silently corrupt — the current failure mode). Consider auto-provision behind a flag.
- **P2 — Per-worker connection routing.** WorkerPool learns a per-worker index (0..N-1); the fork uses
  it to pick its DB. Keep the pool framework-agnostic — pass an `after_fork` hook (Rails adapter sets
  the connection); non-Rails runs pass no hook (today's behaviour).
- **P3 — Default & safety.** `--jobs N --rails` stays 1 unless worker DBs exist (preserve #12 safety);
  document the setup. Non-fixture / non-DB apps parallelize without any of this.
- **P4 — Parallelize coverage capture.** `run_phase_a_via_fork` is serial too; once workers are
  DB-isolated, capture can fan out on the same mechanism.

## Key technical decisions
- **KTD1 — Isolation via separate databases, not shared-DB locking.** Matches Rails `parallelize`;
  the only approach that avoids fixture-transaction cross-talk. Schema-per-worker is a lighter variant
  to evaluate in the spike.
- **KTD2 — after_fork hook keeps the core agnostic.** WorkerPool/Isolation stay Prism+stdlib; the Rails
  DB routing lives in a Rails adapter invoked via the hook. (Aligns with the framework-adapter framing
  in `wip/state-machines-callbacks-and-pro.md` — this is the "speed engine".)
- **KTD3 — Correctness gate is non-negotiable.** Any parallel mode must prove `== serial` verdicts in
  CI before it can be a default; otherwise it stays opt-in with a loud precondition check.

## Verification contract
- Spike: N=2 parallel verdicts == `--jobs 1` on a fixture-backed weak/strong pair + a write-heavy case;
  0 DB warnings; wall-clock drop.
- Build: gem's own suite green (Prism+stdlib core unchanged); a Rails dogfood test (the bundled
  `test/fixtures/rails_app`, extended with worker DBs) shows `--jobs 2 == --jobs 1` verdicts.

## Risk / effort
- **High risk, concentrated in the spike** (post-fork DB routing + provisioning across AR versions).
- **Effort:** spike ~1 day; build medium-large, framework-coupled, ongoing maintenance surface.
- **Payoff:** ~N× on the dominant cost — the difference between "hours" and "minutes" for a full audit.

> Zero-dep constraint holds for the core; the Rails adapter uses the app's own ActiveRecord (already
> loaded via `--rails`), not a new gem dependency of Mutineer.
