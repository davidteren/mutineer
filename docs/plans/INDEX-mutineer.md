# Mutineer v1 — Plan Index (worklist)

Validated, dependency-ordered implementation plans for the Mutineer mutation-testing gem.
Source spec: [`../../mutineer-implementation-spec.md`](../../mutineer-implementation-spec.md) · Locked decisions: [`_DECISIONS.md`](_DECISIONS.md)

Every plan below was drafted with `/ce-plan` (compound-engineering) and validated in a **separate pass** with
`/ie-validate-plan` (intent-engineering) — all flagged gaps folded back in, **0 unresolved**. Ready for `dte-arc-work`.

## Gate (run before every commit in a milestone; red gate = revert the phase, not patch around it)

```sh
cd /Users/davidteren/Projects/DT/mutineer && rake test && ruby -Ilib -e 'require "mutineer"'
```

Plus each milestone's own acceptance check (the fixture/CLI assertion in its plan). The build is strictly linear —
do **not** start a milestone until the previous one's gate is green.

## Loop run config (dte-loop, set 2026-06-28)

```
type: plan-impl
gate: cd /Users/davidteren/Projects/DT/mutineer && rake test && ruby -Ilib -e 'require "mutineer"'
branch: feat/<milestone-id>-<slug>     # e.g. feat/m0-skeleton
commit-policy: --ship (auto-commit on green gate; no remote → local commits, no PRs)
serial: true                            # strictly linear; M(n) depends on M(n-1)
run-mode: /loop wrapper (re-fires until all boxes ticked)
stop-policy: continue-on-red (run all 6, log reds)   # ⚠ see Assumed defaults
```

## Assumed defaults (override anytime; re-run not needed)
- **stop-policy → continue-on-red (your choice).** ⚠ Conflicts with the strictly-linear build: a red gate at M(n) means M(n+1)…M5 build on broken ground. Recommended is halt-on-red. **Override:** edit `stop-policy: halt-on-red` above before/ during the run, or just Ctrl-C when you see a red gate logged.
- **branch base → main, fresh branch off the previous milestone's committed tip.** Override: set a different base in the run config.
- **gem-name RubyGems availability** → NOT checked by the loop (it's a pre-publish, non-code task per `_DECISIONS.md` #4). Override: run the check yourself before first release.

## Worklist (build in order)

- [x] **M0 — Skeleton** → [`01-m0-skeleton.md`](01-m0-skeleton.md) · done · branch:feat/m0-skeleton
  Gem layout, `version.rb`, `bin/mutineer`, optparse CLI stub. _Gate:_ `mutineer --version` + clean `require`.
  Depends on: — · Blocks: M1
- [x] **M1 — Parse & mutate (no execution)** → [`02-m1-parse-mutate.md`](02-m1-parse-mutate.md) · done · branch:feat/m1-parse-mutate
  Prism parser, subject discovery (namespace path), arithmetic operator, textual apply + validity re-parse, `run --dry-run` diffs.
  _Gate:_ `mutineer run --dry-run test/fixtures/calculator.rb` emits expected arithmetic mutations.
  Depends on: M0 · Blocks: M2
- [x] **M2 — End-to-end, one mutant** → [`03-m2-end-to-end-one-mutant.md`](03-m2-end-to-end-one-mutant.md) · done · branch:feat/m2-end-to-end-one-mutant
  Fork isolation + timeout, whole-file reload (7a), Minitest control, killed/survived/error/skipped/timeout result.
  _Gate:_ one arithmetic mutation **killed** by `calculator_strong_test.rb`, **survives** `calculator_weak_test.rb`.
  Depends on: M1 · Blocks: M3
- [x] **M3 — Coverage map + selection** → [`04-m3-coverage-map.md`](04-m3-coverage-map.md) · done · branch:feat/m3-coverage-map
  Phase A coverage capture, digest-keyed JSON cache (auto-invalidate), Phase B per-test-file selection, `no-coverage` flagging.
  _Gate:_ uncovered mutation flagged `no-coverage`; covered mutation selects exact test file(s).
  Depends on: M2 · Blocks: M4
- [x] **M4 — Full Tier 1 + statement-removal + reporting + CI** → [`05-m4-full-tier1-reporting-ci.md`](05-m4-full-tier1-reporting-ci.md) · done · branch:feat/m4-full-tier1-reporting-ci
  Comparison/boundary, boolean-connector, boolean/nil-literal, statement-removal (v1 default); registry + `--operators` toggle; reporter (score + survivor diffs); `--threshold` exit codes.
  _Gate:_ full fixture run yields the **exact expected survivor set** (incl. `pricing.rb` `>=`→`>`) and no expected-kill survives.
  Depends on: M3 · Blocks: M5
- [x] **M5 — Polish** → [`06-m5-polish.md`](06-m5-polish.md) · done · branch:feat/m5-polish
  `--jobs` worker pool, `.mutineer.yml` (CLI>config>default), remaining Tier-2 ops (return-nil, literal, condition-negation; flagged off), surgical redefinition (7b), `--format json`, `--list-operators`.
  _Gate:_ `--jobs N` matches serial results; config takes effect & CLI overrides; valid JSON; 7b verdicts == 7a on fixtures.
  Depends on: M4 · Blocks: — (ships v1)

## Validation rollup

| Plan | Validator | Findings folded | Unresolved |
|---|---|---|---|
| M0 | ie-validate-plan (4 lens) | 5 | 0 |
| M1 | ie-validate-plan | 10 | 0 |
| M2 | ie-validate-plan (3 lens) | 5 | 0 |
| M3 | ie-validate-plan | 6 | 0 |
| M4 | ie-validate-plan (4 lens) | 8 | 0 |
| M5 | ie-validate-plan (4 lens) | 9 | 0 |

Architecture lens N/A (plain-Ruby gem, no supported framework stack). Experience lens read the CLI surface.

## Cross-milestone notes (decided, not open)
- **`Result` states** are fixed in M2 and reused downstream: `killed · survived · no_coverage · skipped(invalid) · error · timeout`. Score denominator = `killed + survived` only; empty denominator ⇒ score `nil` (not `0.0`).
- **Exit-code taxonomy:** `0` success / score ≥ threshold · `1` survivors-below-threshold or runtime error · `2` usage/flag error. Consistent across M1→M5.
- **Operator default set** (M4): four Tier-1 + statement-removal. `DEFAULT_NAMES` in the registry is the seam M5's flags extend.
- **Pre-publish (not a code task):** confirm `mutineer` is free on RubyGems before first release (`_DECISIONS.md` #4).
