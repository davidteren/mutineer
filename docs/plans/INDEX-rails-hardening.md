# Loop worklist — Rails hardening + CI (issues #8 #9 #10 #11 #13)

type: plan-impl
gate: cd /Users/davidteren/Projects/DT/brutus && bundle exec rake test && ruby -Ilib -e 'require "mutineer"'
branch: feat/issue-<n>-<slug>
commit-policy: --ship (commit on branch + merge to main on green; ONE combined release v0.7.0 after all land)
serial: true
stop-policy: continue-on-red (run all, log + skip)   # ⚠ see Assumed defaults
run-mode: /loop wrapper (re-fires until all boxes ticked)

Each plan was drafted with `/ce-plan` (Plan agent) against the real 0.6.x code and is implementation-ready.
Every acceptance check is verifiable WITHOUT a Rails app (simulated forks / canned JSON / plain fixtures).

## Worklist (dependency-ordered, build in order)

- [x] **#8 — Fork fixture-txn + surface swallowed error** → [`issue-08-fork-fixture-txn.md`](issue-08-fork-fixture-txn.md) · done · branch:feat/issue-8-fork-fixture-txn
  Stop `fork_capture` swallowing the child error (diagnostic under `--verbose`); guard `reconnect_active_record`
  to skip `clear_all_connections!` when a fixture transaction is open (`open_transactions.positive?`).
  _Gate:_ real diagnostic surfaces under `--verbose` (suppressed without); reconnect-decision unit test.
  Depends on: — · Blocks: #9

- [ ] **#9 — uncapturable status (vs no_coverage)** → [`issue-09-uncapturable-status.md`](issue-09-uncapturable-status.md)
  7th Result status `:uncapturable`, excluded from score denominator like no_coverage but counted/reported
  separately; sourced from #8's failed-capture signal; reporter + JSON split the two.
  _Gate:_ a mutant whose covering test errored in capture is `uncapturable` not `no_coverage`; summary + JSON
  report them separately; M4 score oracle unchanged.
  Depends on: #8 · Blocks: —

- [ ] **#10 — equivalent-mutant suppression + stable id** → [`issue-10-equivalent-mutant-suppression.md`](issue-10-equivalent-mutant-suppression.md)
  Content-based stable mutant id (SHA256[0,12] of qualified_name+operator+normalized_token+occurrence);
  inline `# mutineer:disable-line [ops]` + `.mutineer.yml` `ignore:`; new `:ignored` status excluded from
  denominator; stable id emitted in JSON.
  _Gate:_ inline-disabled line → ignored; config-ignored id excluded; all-ignored → 100%; JSON shows the id.
  Depends on: — · Blocks: #13

- [ ] **#11 — auto-pairing + multi-pair one-boot** → [`issue-11-autopair-multipair.md`](issue-11-autopair-multipair.md)
  `lib/mutineer/pairing.rb`: directory→`**/*.rb` + `app/`,`lib/` → `test/…_test.rb`/`spec/…_spec.rb`
  convention (skip+warn on no match); `--test` overrides; per-source reporting via `AggregateResult#by_source`
  (+ JSON `per_source`, schema 1.1). Core fork model already boots once — front-door wiring only.
  _Gate:_ convention pairing inferred correctly; multi-source/dir run → combined per-source report; missing
  test skipped+warned.
  Depends on: — · Blocks: #13

- [ ] **#13 — baseline/delta CI gating + roll-up** → [`issue-13-baseline-ci-gating.md`](issue-13-baseline-ci-gating.md)
  `lib/mutineer/baseline.rb`: `--baseline <file.json>` diffs current AggregateResult by #10's stable id —
  NEW survivor / score-drop ⇒ exit 1, named; OR'd with `--threshold` via max exit code; additive JSON; per-source
  roll-up consumes #11.
  _Gate:_ new survivor vs baseline → exit 1 + named; no new survivors → exit 0; score-drop detected; roll-up combines.
  Depends on: #10, #11 · Blocks: — (ships v0.7.0)

## Assumed defaults (override anytime)
- **stop-policy → continue-on-red (your choice).** ⚠ This batch is a dependency chain (#9 needs #8; #13 needs
  #10 + #11). A red gate on a blocker means its dependents build on broken ground. If #8 or (#10/#11) gates red,
  prefer to stop. **Override:** edit `stop-policy: halt-on-red`, or Ctrl-C on a logged red.
- **release → ONE combined v0.7.0 after all 5 land** (not per issue). Override: release per issue if preferred.
- **branch base → main, fresh branch off the previous issue's committed tip; merge to main (ff) on green.**
- **issue auto-close** via "closes #n" in each commit when merged to main.

## Cross-issue notes (decided)
- **Stable mutant id** (#10) is the shared key reused by #13's baseline diff. #10 must land before #13.
- **`by_source` / `per_source`** aggregate shape (#11) is what #13's roll-up consumes. #11 before #13.
- **Score denominator discipline** is sacred: `:uncapturable` (#9) and `:ignored` (#10) are BOTH excluded from
  killed+survived, like no_coverage/skipped. The M4 exact-survivor oracle must stay green throughout.
- JSON schema changes are **additive** (#11 → 1.1; #13 additive) so existing consumers keep working.
