---
title: "Issue #13 — CI baseline/delta gating + cross-run roll-up"
type: feat
date: 2026-06-29
issue: 13
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
depends_on: [10, 11]
blocks: []
---

# Issue #13 — CI baseline/delta gating and cross-run roll-up

**One-line goal:** Add `--baseline <file.json>` so a CI run fails (exit 1) when a PR introduces NEW survivors or drops the score, plus a combined roll-up summary across the multi-source/multi-pair runs from #11 — additively, without breaking existing JSON consumers.

**Depends on:** #10 (per-survivor **stable id**) and #11 (combined multi-source/multi-pair run). Both are HARD dependencies — see "Dependencies". This is the LAST of the three; it consumes their output.
**Blocks:** nothing.

---

## Goal Capsule

- **Objective:** Make Mutineer answer the CI question "did this PR regress?" — not just "what is the absolute score?". A stored prior JSON run is the baseline; the current run is diffed against it by stable survivor id; a regression (new survivor OR score drop) exits non-zero and is named in the report. Independently, surface a per-source roll-up when one invocation runs many pairs (#11).
- **Authority:** Issue #13; existing 0.6.x JSON schema (`Reporter#json_report`, `schema_version: "1.0"`); exit-code taxonomy in `CLI` (0/1/2) and `Reporter#exit_code`.
- **Stop condition:** Verification Contract gates pass + the four acceptance checks hold, all testable WITHOUT Rails by feeding canned baseline JSON + a hand-built `AggregateResult`.
- **Execution profile:** Standard. Implement units in dependency order; each unit gets one test file. Additive only — the existing `--format json` document must remain a valid 0.6.x doc.

---

## Confirmed current state (0.6.x — studied, not assumed)

**JSON shape** (`Reporter#json_report`, `survivor_json`), `schema_version: "1.0"`:
```
{ "schema_version":"1.0",
  "summary": { total, killed, survived, no_coverage, skipped_invalid, errored, timeout, score },
  "survivors": [ { subject, file, line, operator, diff } ],   // sorted by [file,line,operator]
  "no_coverage": [ { subject, file, line } ] }                // sorted by [file,line]
```
- `score` is `AggregateResult#mutation_score` = `killed/(killed+survived)` rounded to 1dp, or **null** on empty denominator (never 0.0). Same rounding for human + json.
- `survivor.subject` is `Subject#qualified_name` (e.g. `"Pricing#total"`); `line` is 1-based.

**Exit-code logic** (`CLI` taxonomy + `Reporter#exit_code`):
- `0` ok / requested output / `score >= threshold`; `1` below-threshold OR runtime error; `2` usage/flag error.
- `Reporter#exit_code(threshold:)`: `0` if threshold nil/≤0; `0` if score nil (gate skipped, warning already emitted); else `score >= threshold ? 0 : 1`.
- `execute` calls `reporter.report(...)` then `exit reporter.exit_code(threshold: config.threshold)`.

**Config** is a `Struct` (`config.rb`); CLI flags map to fields; `.mutineer.yml` keys gated by `KNOWN_KEYS`; precedence via `explicit` Set. New field + flag slot in here.

---

## Requirements

- **R1 `--baseline FILE`**: load a stored `--format json` run; diff current run against it; exit non-zero on NEW survivors or a score drop; report `"killed X, N new survivors vs baseline"` and `"score dropped A% -> B%"`.
- **R2 Stable-id keyed diff** (consumes #10): NEW survivor = stable-id present now, absent in baseline. Reliable across `--jobs` ordering because the id is content/location based, not array position.
- **R3 Combined roll-up** (consumes #11): when one invocation runs multiple sources/pairs, emit one combined summary with a per-source/per-pair breakdown; optionally write the updated run as the next baseline.
- **R4 Additive schema**: every new JSON field is added under the existing `schema_version: "1.0"` doc (or a clearly-additive `baseline` block); no existing key is removed or repurposed. Existing consumers keep working.
- **R5 Taxonomy preserved**: regression → exit `1` (same bucket as below-threshold). Bad `--baseline` path / unparseable baseline → exit `2` (usage). `0` only when every active gate passes.
- **R6 No new runtime deps**: stdlib `json` only; pure-data, fork-free, Rails-free, testable in isolation.

---

## Key Technical Decisions

### KTD-1 — Baseline FORMAT = the existing `--format json` output
The baseline file is literally a prior `mutineer run --format json --output baseline.json`. No new file format, no converter. `Baseline.load(path)` is `JSON.parse(File.read(path))` plus a one-line shape check (`schema_version` present, `survivors` is an Array). This means a baseline is reproducible with tools that already exist and stays valid as the schema grows additively.
> ponytail: reuse the JSON we already emit; a bespoke baseline format would be a second schema to version forever.

### KTD-2 — Stable survivor id (depends on #10)
#10 introduces a **stable id** keyed on the tuple `(subject, file:line, operator)` and emits it per survivor in JSON so an ignore entry is copy-pasteable. #13 reuses that exact id as the diff key.
- **Canonical:** once #10 lands, each `survivors[]` entry carries `"id"`; baseline diff keys on `entry["id"]`.
- **Interlock if #10's field name/shape differs:** #13 must read whatever key #10 standardizes on. Define ONE helper `Baseline.survivor_id(hash)` and ONE `Reporter` equivalent for the live run, both returning the SAME string for the SAME mutant, so live-vs-baseline comparison is apples-to-apples. The tuple is the contract; the serialization is #10's call.
- **Bridge (only if #13 must precede #10 in merge order):** compute the id from existing 0.6.x keys — `"#{subject}@#{file}:#{line}:#{operator}"`. This is the same tuple #10 will canonicalize, so the bridge and the canonical id are interchangeable. State in the PR which path was taken. (Per the plan ordering, #10 lands first and the bridge is dead code — do not ship it speculatively. ponytail: add the bridge only if merge order forces it.)

### KTD-3 — DELTA semantics
Given baseline `B` and current run `C` (an `AggregateResult` + its survivor id set):
- **NEW survivor** = id in `C.survivor_ids` and NOT in `B.survivor_ids`. These are the regressions to name.
- **Fixed survivor** (informational, never gates) = id in `B` not in `C`.
- **Score drop** = `C.score < B.score - epsilon`. `epsilon` defaults to `0.0` (any drop gates); optional `--baseline-epsilon FLOAT` for float-jitter tolerance. Round-tripped scores are already 1dp so jitter is unlikely; epsilon stays opt-in.
- **nil-score handling** (mirrors `AggregateResult`/`exit_code` discipline): if `B.score` or `C.score` is null (no covered mutants either side), the **score-drop check is skipped** (cannot compare; warn on stderr). The NEW-survivor check still runs. This matches `exit_code`'s "score nil → gate skipped".
- **Regression** = (any NEW survivors) OR (score-drop detected). On regression → exit `1`.
- **Report strings:** `"killed <killed>, <N> new survivors vs baseline"`; per new survivor name `subject (file:line) operator`; and when dropped, `"score dropped A% -> B%"`. Human goes to stdout; the same facts go into the JSON `baseline` block for machine consumers.

### KTD-4 — `--baseline` composes with `--threshold` (independent gates, OR'd)
Both gates can be active in one run; they are independent and combined by OR. Final exit code:
```
2  if usage/flag error (incl. bad/unparseable --baseline path)        # unchanged, highest precedence
1  if reporter.exit_code(threshold:) == 1  OR  baseline regression    # below-threshold OR regressed
0  otherwise                                                          # all active gates passed
```
- Precedence: usage (2) always wins; otherwise any failing gate yields 1; 0 only when every active gate passes.
- Both verdicts are always reported (threshold PASS/FAIL line AND baseline delta line) so CI logs show which gate fired — never silently collapse one into the other.
- Implementation: keep `Reporter#exit_code(threshold:)` exactly as-is (don't overload it). Compute the combined code in `CLI.execute` as `[reporter.exit_code(threshold:), baseline_exit].max` (1 dominates 0). ponytail: `max` of two 0/1 codes is the OR; no new branching ladder.

### KTD-5 — Roll-up (depends on #11) + optional updated baseline
- `AggregateResult` already aggregates a flat `Results` list across all files, and `survivors[]` already carries `file`, so a global roll-up exists at the data layer today. The #13 addition is a **per-source/per-pair breakdown** in the combined summary: group `agg.results` by `subject.file` (or by #11's pair identity), emit `file → killed/survived/score` lines, then the global totals. Additive JSON block `by_source: [ { source, killed, survived, score } ]`.
- This requires #11 to have established "one invocation, many pairs". If #11 is not present, the breakdown degenerates to a single row (the one run) — still correct, just not interesting. Do not invent a multi-pair driver here; consume #11's.
- **Optional updated baseline:** reuse the existing `--output FILE` path — writing the current run's JSON IS writing the next baseline. No new write flag needed unless the user wants baseline-write decoupled from report-output; if so, add `--write-baseline FILE` later. ponytail: skip `--write-baseline`; `--format json --output next.json` already produces it. Add the flag only when a user needs report and baseline at different paths in one run.

---

## Implementation Units

**U1 — Stable id surface (consume #10).** Confirm #10 emits the per-survivor id in `survivor_json`. Add `Reporter.survivor_id(result)` (or reuse #10's) returning the canonical id for a live `Result`. No behaviour change to existing output beyond the additive `id` key #10 already adds.
Files: `lib/mutineer/reporter.rb` (+ wherever #10 defines the id).

**U2 — `Baseline` class (the core, pure-data).** New `lib/mutineer/baseline.rb`:
- `Baseline.load(path)` → parsed doc; raises `Mutineer::ConfigError` (not exit) on missing/invalid JSON or wrong shape, so the CLI maps it to exit 2 (R8 discipline).
- `#diff(aggregate, reporter_or_id_fn)` → a `Data`-defined `Delta(new_survivors:, fixed_survivors:, score_before:, score_after:, regressed:)`.
- `survivor_id(hash)` helper (KTD-2). Pure, stdlib `json`, no fork. This is where every acceptance test points.
Files: `lib/mutineer/baseline.rb` (new), `test/baseline_test.rb` (new).

**U3 — CLI flag + config + validation.** Add `--baseline FILE` (and opt-in `--baseline-epsilon FLOAT`) to `OptionParser`; add `:baseline`/`:baseline_epsilon` fields to the `Config` Struct + `KNOWN_KEYS` (`baseline`) + precedence; preflight the path in `validate!` like `--output`/`--since` (missing/unreadable/unparseable → exit 2).
Files: `lib/mutineer/cli.rb`, `lib/mutineer/config.rb`, `test/cli_test.rb`, `test/config_test.rb`.

**U4 — Wire into `execute` + render.** After `reporter.report(...)`: if `config.baseline`, `Baseline.load` → `diff` → render the delta section (human: stdout lines from KTD-3; json: additive `baseline` block, gated by `format == "json"` like the existing tier-2 hint suppression). Combine exit codes per KTD-4 (`max`).
Files: `lib/mutineer/cli.rb`, `lib/mutineer/reporter.rb` (additive `baseline` block in `json_report` when a delta is supplied), `test/integration_test.rb` or `test/json_reporter_test.rb`.

**U5 — Roll-up breakdown (consume #11).** Add per-source `by_source` grouping to the summary (human + additive json block) per KTD-5. Document that the updated baseline is `--format json --output next.json`.
Files: `lib/mutineer/reporter.rb`, `test/reporter_test.rb` / `test/json_reporter_test.rb`.

---

## Verification Contract

**Gate (must pass):**
```
bundle exec rake test && bundle exec ruby -Ilib -e 'require "mutineer"'
```

**Acceptance — all testable WITHOUT Rails, by feeding a canned baseline JSON string + a hand-built `AggregateResult` (pattern already used in `test/json_reporter_test.rb`: build `Result.survived.with(subject:, mutation:)`, wrap in `AggregateResult`, render):**
1. **NEW survivor → fail + named:** baseline JSON with survivor set `S`; current run whose survivor set is `S + {x}`. `Baseline#diff` reports 1 new survivor naming `x` (subject/file:line/operator); combined exit code is `1`.
2. **No new survivors → pass:** current survivor set ⊆ baseline set (and no score drop). `diff.regressed == false`; combined exit code from the baseline gate is `0`.
3. **Score drop detected:** baseline `score: 80.0`, current `AggregateResult` scoring `60.0`. `diff` reports `"score dropped 80.0% -> 60.0%"` and `regressed == true`; nil-on-either-side skips the score check (separate assertion).
4. **Roll-up combines multi-source results:** an `AggregateResult` built from results spanning two files yields a `by_source` breakdown (per-file killed/survived/score) plus correct global totals.

**Schema-safety check:** an existing 0.6.x JSON consumer test still parses the doc with no `--baseline` given (no `baseline`/`by_source` keys forced, or they are additive and ignorable).

---

## Definition of Done

- `--baseline FILE` loads a prior JSON run and gates on NEW survivors / score drop, exit `1` on regression, naming each new survivor.
- `--baseline` and `--threshold` compose as OR'd gates with usage(2) > regress/threshold(1) > ok(0); both verdicts reported.
- Diff keys on the #10 stable id (or the agreed equivalent helper); `--jobs` ordering does not affect the verdict.
- Combined roll-up (`by_source`) emitted for multi-pair runs (#11); updated baseline obtainable via `--format json --output`.
- All new JSON is additive under `schema_version: "1.0"`; existing consumers unaffected.
- Gate command green; the four acceptance checks pass without Rails.

---

## Validation (4-lens)

- **Least astonishment:** baseline = the JSON we already emit; regression = exit 1 (same bucket CI already treats as "mutation gate failed"); bad path = exit 2 like every other usage error. Nothing new to learn.
- **Convention / idiom:** mirrors `--output`/`--since` validation, `Reporter#exit_code`'s nil-score discipline, the `Data`/`Struct` value-object style, and the additive `schema_version: "1.0"` schema. `Baseline` is one small single-purpose class per the spec's structure — no service objects.
- **Simplicity / scope:** one new file (`baseline.rb`) + flag wiring; no new runtime deps; `--write-baseline` and `--baseline-epsilon` deferred until a user needs them; exit codes combined with `max`, not a new ladder.
- **Experience / CI ergonomics:** human report names exactly what regressed and the score delta; JSON carries the same facts for dashboards; per-source roll-up removes the hand-aggregation the issue reporter had to do.

---

## Dependencies (stated explicitly — this issue is LAST)

- **#10 (stable survivor id) — HARD.** #13's diff key IS #10's id. Land #10 first; #13 reads the `id` it emits. If serialization differs, #13 routes through one `survivor_id` helper so live and baseline ids match. A from-existing-keys bridge (`subject@file:line:operator`) exists only as a fallback if merge order forces #13 first — do not ship it otherwise.
- **#11 (combined multi-source/multi-pair run) — HARD for the roll-up.** The `by_source` breakdown needs #11's "one invocation, many pairs". Without #11 the breakdown is a correct single row; with it, the full roll-up. #13 consumes #11's pairing, it does not build one.
