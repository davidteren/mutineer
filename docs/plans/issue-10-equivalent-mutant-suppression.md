---
title: "Issue #10 — Equivalent-Mutant Suppression"
type: feat
date: 2026-06-29
issue: 10
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
depends_on: [M5]
blocks: ["#13 baseline gating (reuses the stable mutant id)"]
---

# Issue #10 — Equivalent-Mutant Suppression

**One-line goal:** Let users mark known-equivalent mutants — via an inline `# mutineer:disable-line` comment or a `.mutineer.yml` `ignore:` list of stable mutant ids — so they are excluded from the score denominator (100% becomes reachable) and every survivor's JSON carries a copy-pasteable stable id.

**Depends on:** M5 (config file, JSON reporter, worker pool, surgical/reload strategies).
**Blocks:** #13 (baseline gating) reuses the stable mutant id for run-to-run diffing.

---

## Goal Capsule

- **Objective:** Add a suppression mechanism for equivalent mutants. A suppressed mutant gets a new, distinct `:ignored` status, is never forked, and is removed from `killed + survived` so a strong file can reach 100%. Survivors (and ignored mutants) carry a stable, content-based id; the JSON emits it so the user can paste it straight into `.mutineer.yml`.
- **Authority:** GitHub issue #10. Locked decisions in `docs/plans/_DECISIONS.md` (note: #10 was a v1 non-goal — this is the post-v1 implementation that lifts that restriction). Existing shapes confirmed against v0.6.2.
- **Stop condition:** All Verification Contract gates pass; the four acceptance checks hold against the existing non-Rails fixtures. Do NOT implement block-form `disable/enable` ranges, a CLI `--ignore` flag, or baseline gating (#13) here.
- **Execution profile:** Standard — single-purpose units in dependency order. The id module lands and is unit-tested before the runner/reporter wiring depends on it. Preserve the M4 score oracle: a run with nothing suppressed must produce byte-identical results to today.

---

## Confirmed current shapes (v0.6.2)

- `Mutation = Data.define(:start_offset, :end_offset, :replacement, :operator)` — byte offsets only; no file, no subject. (`lib/mutineer/mutation.rb`)
- `Subject = Struct.new(:file, :namespace, :name, :singleton, :def_node, ...)`; `#qualified_name` → e.g. `"Billing::Invoice#total"` / `".build"`. (`lib/mutineer/subject.rb`)
- `Result = Data.define(:status, :details, :subject, :mutation)`; statuses today: `killed, survived, error, timeout, skipped, no_coverage`. Built bare in the child; `subject`/`mutation` reattached in the parent via `result.with(...)`. (`lib/mutineer/result.rb`)
- `AggregateResult`: `covered_count = killed + survived`; `mutation_score = killed / covered * 100` or `nil`. Denominator already excludes everything except killed+survived. (`lib/mutineer/result.rb`)
- `Runner.execute` builds `jobs = [[subject, mutation], ...]` per subject across operator classes, optionally `filter_since`, runs them through `WorkerPool`, then `bare.each_with_index.map { |r, i| r.with(subject: jobs[i][0], mutation: jobs[i][1]) }`. (`lib/mutineer/runner.rb`)
- `Reporter#survivor_json` already emits `{subject, file, line, operator, diff}` and computes a normalized `token` in `diff_for` (`source.byteslice(start...end).gsub(/\s+/," ").strip`). (`lib/mutineer/reporter.rb`)
- `Config::KNOWN_KEYS = %w[operators jobs threshold only require boot rails since framework]`; YAML parsed by `from_file`, coerced by `coerce`, fields on the `Config` Struct. (`lib/mutineer/config.rb`)

---

## Requirements

- R1: A mutation whose source line bears `# mutineer:disable-line` is suppressed (status `:ignored`, not forked).
- R2: `# mutineer:disable-line <op1,op2>` suppresses only the named operators on that line; bare `# mutineer:disable-line` suppresses every operator on that line.
- R3: A `.mutineer.yml` `ignore:` list of stable mutant ids suppresses any mutant whose id is in the list.
- R4: A suppressed mutant is EXCLUDED from the score denominator (`killed + survived`), so with all survivors suppressed the score reaches `100.0`.
- R5: Suppressed mutants are reported as a distinct count ("N ignored") in both the human summary/score line and the JSON summary; they never appear in `surviving_mutants`.
- R6: Every survivor in the JSON carries a stable `id` (plus the readable `token`) so the ignore entry is copy-pasteable. Ignored mutants are also emitted (with `id`) under a separate JSON key.
- R7: The stable id is content-based, stable across runs, and reasonably stable across edits elsewhere in the file. It is a pure function of `(subject, mutation, source)` reusable by #13.
- R8: With nothing suppressed, output is byte-identical to v0.6.2 (M4 score oracle preserved) — except the additive `id` field in JSON survivors, which is new but does not change scoring.
- R9: All of the above is testable without Rails, using the existing `test/fixtures` standalone fixtures.

---

## Key Technical Decisions

### KTD-10.1 — Stable mutant id: content-based, NOT byte offsets

**Decision.** The id is a short hex digest of four content components joined with a NUL separator:

```
id = Digest::SHA256.hexdigest(
       [subject.qualified_name, mutation.operator, normalized_token, occurrence].join("\x00")
     )[0, 12]
```

where:
- `subject.qualified_name` — e.g. `"Billing::Invoice#total"`. Anchors the mutant to a method, not a byte position. Survives edits anywhere else in the file.
- `mutation.operator` — e.g. `:arithmetic`. Distinguishes families on the same token.
- `normalized_token` — `source.byteslice(start_offset...end_offset).gsub(/\s+/," ").strip` (the exact code being mutated, e.g. `+`, `||=`, `require "csv"`, `:member`). Already computed in `Reporter#diff_for`.
- `occurrence` — 0-based ordinal among mutations sharing the same `(operator, normalized_token)` WITHIN the subject. Disambiguates `a + b + c` (two `+` mutants) without using an offset.

**Why a digest, not a readable composite string.** Tokens legitimately contain every delimiter we might pick (`||=` contains `|`, `require "csv"` contains spaces/quotes/`::`-lookalikes, `qualified_name` contains `::` and `#`). A NUL-joined digest sidesteps all delimiter-collision ambiguity and yields a fixed-length, copy-pasteable key. Readability is preserved by emitting the readable components (`subject`, `operator`, `token`, `line`) right next to `id` in the JSON, so the user always sees WHAT they are silencing. `digest` is stdlib — zero runtime deps preserved.

**Why content-based, not raw byte offsets (`start_offset/end_offset`).** Offsets shift on ANY edit earlier in the file (adding an import, a comment, another method) — an offset-keyed ignore entry would silently stop matching after the next unrelated edit, re-flagging the mutant forever. The content id is invariant under all edits outside the subject method.

**Stability envelope (limitations, stated honestly).**
- STABLE across: runs (deterministic discovery order); edits to other files; edits to other methods; edits to other lines within the same method that don't add/remove an earlier identical `(operator, token)` mutation.
- INVALIDATED by: renaming the method or moving its namespace (acceptable — it is genuinely a different subject); adding/removing an earlier identical-token-same-operator mutation in the same method (shifts `occurrence` of later twins). Occurrence collisions are rare (most tokens are unique per method); the trade-off is accepted over offsets, which break on every unrelated edit.

**Reuse for #13.** The id is a pure function `MutantId.for(subject, mutation, source, occurrence)` (+ a batch helper `MutantId.for_subject(subject, source, mutations) -> [ids]` that assigns occurrence). #13 baseline gating computes the same ids and diffs id-sets across runs — no change needed. This is the single reason the helper is its own small module rather than an inline lambda (ladder rung 7: a real second caller exists).

### KTD-10.2 — Two suppression mechanisms, evaluated at job-build time

Both are checked in `Runner.execute` while the per-subject mutation list is built (where we already have subject + source + all mutations, so occurrence and id are cheap). A suppressed mutant is NEVER added to `jobs` (never forked); instead a `Result.ignored` is created immediately with `subject`, `mutation`, and `id` attached.

1. **Inline comment.** Scan the source once into `disabled = { line_number => :all | Set[operator_syms] }` via one regex (`/#\s*mutineer:disable-line(?:\s+([\w,\s]+))?/`). A mutation on `line` is suppressed when `disabled[line] == :all`, or `disabled[line]` is a Set containing `mutation.operator`. `line` is computed exactly as everywhere else: `source.byteslice(0, start_offset).count("\n") + 1`. Semantics match RuboCop's `disable-line`: same physical line as the code (trailing comment). Block-form `disable`/`enable` ranges are deferred (YAGNI — all the issue's real examples are single lines).
2. **Config ignore list.** `config.ignore` (a `Set` built once) — `Result.ignored` if `ignore.include?(id)`.

### KTD-10.3 — `:ignored` status, excluded from the denominator

Add `:ignored` to `Result` (`Result.ignored`, `#ignored?`). It is a pre-fork classification like `:no_coverage`/`:skipped`. `AggregateResult` adds `ignored_count`; the denominator stays `killed + survived` (already excludes it), so the score reaches 100% once every would-be survivor is ignored. `surviving_mutants` is `select(&:survived?)` — `:ignored` is naturally absent. `total` grows to include ignored (it is "all classified mutations").

### KTD-10.4 — Reporting

- Human `summary`: add an `Ignored: N` cell. `score_line` excluded-list gains `, N ignored excluded`.
- JSON `summary`: add `ignored: @agg.ignored_count`. `survivor_json` gains `id:` and `token:`. Add an `ignored: [...]` array (each `{subject, file, line, operator, token, id}`) so users can copy ids for mutants they have NOT yet ignored but want to, and audit what is currently suppressed. Bump `schema_version` to `"1.1"` (additive).

---

## Implementation Units

**U1 — `lib/mutineer/mutant_id.rb` (new).**
`module Mutineer::MutantId` with `self.for(subject, mutation, source, occurrence = 0)` and `self.for_subject(subject, source, mutations) -> Array[String]` (assigns occurrence via a `Hash.new(0)` keyed on `[operator, token]`). `require "digest"`. Pure, no I/O.
Test: `test/mutant_id_test.rb` — deterministic across calls; differs by operator/token/occurrence; invariant to a leading inserted line (simulate by re-slicing); two `+` in one method get distinct ids.

**U2 — `lib/mutineer/result.rb`.**
Add `Result.ignored` + `#ignored?`. Add `id` to the `Data.define` field list (nil by default, attached in the parent). Add `AggregateResult#ignored_count`. No denominator change.
Test: `test/result_test.rb` — `ignored` excluded from `covered_count`/`mutation_score`; with killed=5 survived=0 ignored=2 → score 100.0.

**U3 — `lib/mutineer/config.rb`.**
Add `"ignore"` to `KNOWN_KEYS`; `field_for` maps it to `:ignore`; `coerce` returns `Array(value).map(&:to_s)`. Add `:ignore` to the `Config` Struct + `self.ignore ||= []` in `initialize`. (No CLI flag; ignore lists live in the file.)
Test: `test/config_test.rb` — `ignore:` list parsed; unknown-key warning gone for `ignore`.

**U4 — `lib/mutineer/runner.rb` (the integration point).**
In `execute`'s discovery loop: for each subject collect all mutations, compute `ids = MutantId.for_subject(...)`, build `disabled` line-map once per source. Partition: suppressed → `ignored_results << Result.ignored.with(subject:, mutation:, id:)`; else → `jobs << [subject, mutation, id]`. After the worker pool, reattach `id:` in the existing `with(...)` map. `AggregateResult.new(run_results + ignored_results)`. `filter_since` still operates on `jobs` only. Add a private `suppress_map(source)` (regex scan) and `suppressed?(operator, line, id, disabled, ignore_set)` helper.
Test: `test/runner_test.rb` / a new `test/equivalent_mutant_test.rb`.

**U5 — `lib/mutineer/reporter.rb`.**
`survivor_json`: add `id: result.id` and `token:`. `json_report` summary: add `ignored:`; add `ignored:` array; bump `schema_version`. `summary`/`score_line`: surface the ignored count.
Test: `test/json_reporter_test.rb`, `test/reporter_test.rb`.

**U6 — fixtures.**
Add `test/fixtures/equivalent.rb` (a method with one line carrying `# mutineer:disable-line` and one normal mutatable line) + a covering test, and a tiny inline `.mutineer.yml`-style `ignore:` fixture string in the test (no need for a real dotfile — pass `config.ignore` directly, as the integration tests already construct `Config` in-process).

---

## Verification Contract

**Gate (run after every unit):**
```sh
bundle exec rake test && bundle exec ruby -Ilib -e 'require "mutineer"'
```

**Acceptance (all without Rails, against standalone fixtures):**
1. A line bearing `# mutineer:disable-line` produces NO surviving mutant for that line — those mutants are classified `:ignored` (assert via `AggregateResult`: that operator/line not in `surviving_mutants`, present in ignored).
2. A mutant whose stable id is placed in `config.ignore` is classified `:ignored` and absent from `surviving_mutants`.
3. Take a fixture whose only survivors are equivalent; suppress them all → `mutation_score == 100.0` (and the M4 oracle fixtures with nothing suppressed still produce their exact unchanged survivor set + score).
4. JSON: every entry in `survivors` has a non-nil `id`; copying that `id` into `config.ignore` and re-running moves that mutant to `ignored` (round-trip).

---

## Definition of Done

- U1–U6 implemented; gate green.
- All four acceptance checks pass.
- `MutantId.for` is pure and reused by both runner and reporter (single source of truth); documented as the id #13 will diff on.
- Nothing-suppressed runs match v0.6.2 scoring exactly (M4 oracle intact); only additive JSON fields changed, `schema_version` bumped.
- README/CLI help note the two suppression mechanisms (one paragraph; `--help` unchanged since there is no new flag).

---

## Validation (4-lens)

- **Predictability / least astonishment:** `disable-line` matches RuboCop semantics (same physical line, optional operator list) — users already know it. `:ignored` mirrors the existing `:no_coverage`/`:skipped` excluded-bucket pattern, so the score arithmetic is unsurprising.
- **Convention / idiom:** Reuses existing line-number math, `diff_for`'s token normalization, the `Result.with(...)` reattach path, the `KNOWN_KEYS`/`coerce` config pattern, and stdlib `digest`. No new dependency; zero-dep invariant held. One new small module (`MutantId`), justified by a real second caller (#13).
- **Simplicity / scope:** Deferred block-form ranges and a CLI flag (YAGNI — the issue's examples are all single lines, and ignore lists belong in the committed config). The whole change is one new module + additive fields on three existing files + one runner branch.
- **Experience / UX:** The JSON puts a copy-pasteable `id` next to human-readable `subject`/`token`/`line`, so a user reads the survivor, understands it, and pastes one line into `.mutineer.yml`. The human report's "N ignored excluded" makes the denominator change visible rather than silent.
