---
title: "#26/#27 Phase 2 spike — findings (R8 gate)"
type: spike-findings
date: 2026-07-01
status: PASSED
---

# Phase 2 spike — findings

**Gate:** the shared R8 spike for #27 Phase 2 (persistent app-side daemon) and #26
(DB-isolated parallel workers). One spike answers both, as both plans intended.

## Question (make-or-break)

> Can the tool (Ruby ≥ 3.4) spawn a **persistent worker under the app's own
> bundle/older Ruby** that boots the app **once**, then per mutant **forks** a
> child which **routes ActiveRecord to an isolated per-worker database**, `load`s
> the mutated source, runs its covering test, and returns the **correct
> kill/survive** — with **N=2 parallel verdicts identical to serial**?

If per-worker DB routing after fork couldn't be made clean, or the cross-runtime
IPC didn't hold, Phase 2 was blocked. It holds.

## Verdict: **PASS** (all criteria, exit 0)

| Criterion | Result | Source plan |
|---|---|---|
| Tool → daemon IPC round-trip (newline JSON over a pipe) | **PASS** | #27 U7 |
| Daemon boots the app **once**, reused for every mutant | **PASS** | #11 / #27 |
| Fork per mutant, AR routed to an **isolated** worker DB | **PASS** | #26 |
| N=2 parallel verdicts **== serial**, deterministic | **PASS** | #26 exit criterion |
| Correct fixture-backed kill/survive (real Rails + transactional fixtures) | **PASS** | both |
| **Cross-Ruby**: tool 3.4.9 driving a daemon on **3.3.6** (< 3.4, no stdlib Prism) | **PASS** | #27 (the blocker) |
| Measurable wall-clock drop | **PASS** (~1.8×: 4 mutants / 2 workers) | #26 payoff |

## How it was proven

Substrate: the bundled `test/fixtures/rails_app` (real Rails, `Order` model,
transactional fixtures, strong + weak suites, file-backed SQLite).

- **`spike/daemon.rb`** — runs under the app's bundle. Boots `config/environment`
  once, then serves per-mutant requests. Each request forks a child that
  `establish_connection`s to `storage/test-<worker>.sqlite3` (isolated), loads the
  schema into it, `load`s the mutated `Order` source (reload strategy), runs the
  covering test, and exits `0=survived / 1=killed`. The parent decodes the child's
  exit status to a verdict — the exact contract Phase 1 already ships.
- **`spike/driver.rb`** — the "tool". Runs on 3.4 with **zero app dependencies**
  (stdlib `json`/`open3` only), spawns the daemon under the app bundle (optionally
  a different Ruby via `RBENV_VERSION`), and drives it. Runs 4 hand-crafted mutants
  (1 original → survives, 3 arithmetic/boolean → killed) serially on one worker,
  then across two concurrent workers with isolated DBs, and asserts the verdict
  sets are identical.

Run it: `RBENV_VERSION=3.4.9 ruby spike/driver.rb 3.4.9` (same-Ruby mechanism) and
`SPIKE_APP_GEMFILE=spike/app_gemfile RBENV_VERSION=3.4.9 ruby spike/driver.rb 3.3.6`
(cross-Ruby). Both exit 0. The daemon that served 3.3.6 ran under a
**mutineer-free** app bundle (`spike/app_gemfile`) — proving the app's bundle never
pulls in mutineer (the ≥3.4 dependency that is the #27 blocker).

## What this confirms for the build

- **KTD-7 holds (Prism stays tool-side).** The 3.3.6 daemon has no stdlib Prism
  and no mutineer, yet served correct verdicts — because the tool ships it
  ready-to-`load` source text; the daemon never parses. The decoupling is total.
- **#26's isolation model works.** Per-worker DB after fork gives deterministic
  `== serial` verdicts. The routing is a 3-line `establish_connection` in the
  fork — a small `after_fork` hook, exactly the framework-agnostic shape #26 KTD2
  proposes.
- **#27 Phase 2 is unblocked.** The persistent daemon restores the one-boot speed
  Phase 1 gives up, and is the same machinery #26 needs — build them as one.

## Caveats / not covered by the spike (address in the build, not blocking)

- **SQLite, not Postgres.** Isolation was proven with per-worker SQLite **files**;
  #26's measured corruption (PG deadlocks / "could not disable referential
  integrity") is Postgres-specific. The *routing mechanism* (each fork → its own
  DB) is identical; real **worker-DB provisioning** for PG (`create` + schema load
  per `<db>_test-N`, mirroring Rails `parallelize`) is #26 build-phase P1, not a
  spike unknown.
- **3.3.6 stands in for 3.1.x.** The local 3.1.6 rbenv build is broken (can't
  `require "socket"`), so 3.3.6 (also < 3.4, also no stdlib Prism) was used. The
  daemon code is interpreter-version-agnostic — the version number doesn't change
  the fork/IPC/routing mechanics.
- **Reload strategy warnings.** The spike uses whole-file `load` (reload), which
  re-defines `Order`'s constants (benign `already initialized constant` warnings).
  The build should ship the redefine/surgical snippet (KTD-7) to avoid re-running
  file-level code.
- **Spike-grade mutants.** Four hand-crafted string substitutions, not the real
  Prism mutators; the point was the execution/isolation mechanism, which is
  operator-agnostic.

## Next

Proceed to the Phase 2 build (re-plan U7–U9 of #27 and the #26 phased build as one
converged effort): IPC protocol + daemon lifecycle, per-worker DB provisioning +
`after_fork` routing hook, and the default/safety gate. The spike code under
`spike/` is throwaway (gitignored) — keep as a reference, not shipped.
