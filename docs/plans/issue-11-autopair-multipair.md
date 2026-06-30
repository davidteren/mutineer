---
title: "Issue #11 — Source→Test Auto-Pairing & One-Boot Multi-Pair Runs"
type: feat
issue: 11
date: 2026-06-29
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---

# Issue #11 — Source→Test Auto-Pairing & One-Boot Multi-Pair Runs

**One-line goal:** Let one `mutineer run` take a directory or a list of sources, infer each source's test by convention when `--test` is omitted, and mutate them all under a single app boot — with a per-source breakdown in the report.

**Depends on:** v0.6.x (boot-once fork model, coverage map, AggregateResult/Reporter).
**Blocks / enables:** #13 (roll-up + baseline) consumes the per-source aggregate shape introduced here.

---

## Goal Capsule

- **Objective:** Remove the two costs the issue names — re-booting Rails per file when fanning out, and hand-mapping every `app/.../x.rb` to `test/.../x_test.rb`. Achieve both at the CLI/config front door; the execution core already does the heavy lifting.
- **Authority:** GitHub issue #11; `_DECISIONS.md` (Prism + stdlib only, Ruby ≥ 3.4, zero runtime deps, clean-room); existing v0.6.x architecture.
- **Stop condition:** All Verification Contract gates pass. Do NOT add per-test-method coverage, parallel coverage capture, baseline/roll-up (#13), or any new strategy.
- **Execution profile:** Small, additive. One new pure module + thin wiring in `cli.rb`, plus a `by_source` accessor on `AggregateResult` and a per-source section in `Reporter`. No change to `Runner.execute`'s fork/boot logic.

---

## Key Finding — what is already done vs. what is missing

`Runner.execute` (`lib/mutineer/runner.rb`) is **not** single-source. It already:
- boots once: the `--boot` file is `require`d a single time in the parent (line ~53), inherited by every fork;
- builds **one** coverage map over the full `config.sources × config.tests` cross-product (`CoverageMap#build_via_fork` forks the booted parent per test);
- discovers subjects across **all** `config.sources` (`Project.discover(config.sources)`), fans every `(subject, mutation)` out through `WorkerPool`, sweeps every source dir, and runs each mutant against only its empirically-covering tests (`coverage_map.tests_for`).

So passing 22 sources + 22 tests to **one** invocation already boots once and pairs correctly by measured coverage. The issue's hypothesis is confirmed.

**What is missing (all front-door):**
1. **Directory / source-list expansion.** `config.sources = argv[1..]` are literal paths. A directory reaches `Prism.parse_file(dir)` → `SystemCallError` → `ParseError`. Nothing globs a dir to its `.rb` files.
2. **Test inference.** When `--test` is omitted the run errors (`execute`: "run requires at least one --test file"; `validate!`: "--boot/--rails requires at least one --test file"). There is no path-convention inference anywhere.
3. **Per-source reporting.** The summary block is global; only the survivor list groups by file. No per-source score breakdown.

Because the coverage map re-derives the source→test mapping empirically, **auto-pairing only needs to populate `config.tests` with the union of inferred tests** (and drop sources that have none). The existing core does the rest — no changes to the fork/boot model.

---

## Requirements

- **R1 — Directory expansion.** A positional source that is a directory expands to its `**/*.rb` files (sorted, deduped). A file stays as-is. Mixed dirs + files + globs in one invocation are allowed.
- **R2 — Convention pairing.** When `--test` is omitted, each source's test file is inferred by path convention (R4) and the union of found tests becomes `config.tests`.
- **R3 — Skip, don't fail, on no test.** A source with no inferred test that exists on disk is dropped from the run with a one-line stderr warning. The run continues with the rest. If *no* source has a test, exit 2 with a clear message ("no test files found by convention; pass --test or add tests").
- **R4 — Pairing convention (exact rules in KTD1).** Cover Rails `app/` and `lib/` sources mapping to `test/…_test.rb` and `spec/…_spec.rb`, preserving namespaced subdirectories.
- **R5 — `--test` overrides auto-pairing.** Any explicit `--test` disables inference entirely; explicit tests apply as today.
- **R6 — One boot, many pairs.** Multiple sources + their inferred tests run under a single `--boot`/`--rails` boot, reusing the existing booted-parent fork model. (No core change required — verify it holds.)
- **R7 — Per-source breakdown.** The human report adds a per-source section (file → score, killed/survived/no-coverage); the JSON report adds a `per_source` array. The global summary and exit-code behaviour are unchanged.
- **R8 — Reusable aggregate.** Expose `AggregateResult#by_source → { file => AggregateResult }` so #13 can roll up / diff per-source scores against a baseline.
- **R9 — Stack discipline.** Prism + stdlib only (`Dir.glob`, `File`). No new gems, no `mutant` references.

---

## Key Technical Decisions

### KTD1 — The pairing convention (pure path logic)

A single pure function, `Pairing.infer_test(source_rel, project_root:, prefer:)`, returns the first **existing** candidate test path (relative to `project_root`) or `nil`. Steps:

1. **Strip the source root** to get the logical path `L`:
   - `app/foo/bar.rb` → `foo/bar`
   - `lib/foo/bar.rb` → `foo/bar`
   - anything else → the path minus `.rb` (still attempted)
2. **Generate candidates** (base = `L`):
   - Minitest: `test/{base}_test.rb`; **plus, for `lib/` sources only**, `test/lib/{base}_test.rb` (Rails apps put lib tests under either).
   - RSpec: `spec/{base}_spec.rb`; plus, for `lib/`, `spec/lib/{base}_spec.rb`.
3. **Order** by `prefer` (the resolved framework): preferred framework's candidates first, the other framework's as fallback — so a minitest default still finds a spec and vice-versa.
4. **Return the first that `File.exist?`** under `project_root`; else `nil`.

**Namespaced paths** are handled structurally, not by constant resolution: `app/services/billing/charge.rb` → `test/services/billing/charge_test.rb`. The directory layout under the source root is preserved verbatim — no `::`→`/` logic, no class loading.

This is the unit-testable acceptance surface: pure in/out, no Rails, no process.

### KTD2 — Expansion + pairing live in a new `lib/mutineer/pairing.rb`, wired from `CLI.start`

`Pairing` is a stdlib-only module with two pure-ish class methods:
- `expand_sources(args, project_root:) → [rel_paths]` — `Dir.glob("#{arg}/**/*.rb")` for directories (sorted), pass-through for files, flatten + uniq.
- `infer_test(source_rel, project_root:, prefer:) → rel_path | nil` (KTD1).

Wired in `CLI.start`, replacing the bare `config.sources = argv[1..]`:
```
config.sources = Pairing.expand_sources(argv[1..], project_root: config.project_root)
if config.tests.empty?            # R5: explicit --test skips inference
  paired   = config.sources.filter_map { |s| t = Pairing.infer_test(s, project_root:, prefer: config.framework); [s, t] if t }
  skipped  = config.sources - paired.map(&:first)
  skipped.each { |s| warn "[mutineer] no test found by convention for #{s}; skipping" }   # R3
  config.sources = paired.map(&:first)
  config.tests   = paired.map(&:last).uniq
  config.framework = Config.detect_framework(config.tests) unless explicit.include?(:framework)
end
```
Placed in `start` because it needs the `explicit` set (for the framework re-detect) and runs before `run(config)` → `validate!` → `validate_paths!`, which then sees only real files. New module, not folded into `Project` (AST discovery) or `Config` (precedence) — it is a distinct concern and the acceptance contract wants it independently unit-testable. (ponytail: one new file earns its keep here; smearing path logic into `cli.rb` would not be testable without driving argv + exits.)

Why re-detect framework after pairing: `Config.resolve` runs `detect_framework([])` → `minitest` before tests exist. Once inference fills `config.tests`, re-detect so a spec-only project reports/loads as rspec. An explicit `--framework`/config value still wins (guarded by `explicit`).

### KTD3 — Reuse the existing one-boot core unchanged

No change to `Runner.execute`, `CoverageMap`, or the fork model. Auto-pairing's only job is to produce a correct `config.sources` + `config.tests`; the boot-once-fork-per-test machinery already pairs by measured coverage. Validation in `validate!` ("--boot/--rails requires at least one --test file") now passes naturally because inference has populated `config.tests` (or the run already exited 2 per R3).

### KTD4 — Per-source aggregation shape (reusable for #13)

Add to `AggregateResult` (`lib/mutineer/result.rb`):
```
def by_source
  @results.group_by { |r| r.subject.file }
          .transform_values { |rs| AggregateResult.new(rs) }
end
```
Every result carries a `subject` by the time `execute` returns (re-attached via `r.with(subject:, mutation:)`), so grouping is total. Returning `{ file => AggregateResult }` gives the Reporter (R7) and #13 (per-source roll-up + baseline diff) the same shape — score, counts, survivors per file — with zero new types.

### KTD5 — Reporter per-source section

`Reporter` already holds the `AggregateResult`. Add:
- **Human:** a "Per-source" block after the global summary — one line per file: `path  score%  (k killed / s survived / n no-cov)`, sorted by path. Reuses `score_line` math via `by_source`.
- **JSON:** a top-level `per_source` array (`{ file, total, killed, survived, no_coverage, score }`), sorted by `file`, alongside the existing `summary`/`survivors`/`no_coverage`. Bump `schema_version` to `"1.1"` (additive; consumers keying on 1.0 fields keep working).

---

## Implementation Units

### U1 — `Pairing` module (expansion + inference)
**Files:** `lib/mutineer/pairing.rb` (new), `test/pairing_test.rb` (new).
**Requirements:** R1, R2, R3 (the path half), R4.
- Implement `expand_sources` and `infer_test` per KTD1/KTD2.
- Unit tests (no Rails, plain fixture tree under a tmp dir or `test/fixtures`):
  - `app/models/user.rb` → `test/models/user_test.rb` when that file exists.
  - `lib/billing/invoice.rb` → `test/billing/invoice_test.rb`; also resolves `test/lib/billing/invoice_test.rb` when only that exists.
  - rspec preference: with `prefer: "rspec"`, `app/foo/bar.rb` → `spec/foo/bar_spec.rb`.
  - namespaced: `app/services/billing/charge.rb` → `test/services/billing/charge_test.rb`.
  - no test on disk → `nil`.
  - `expand_sources` on a directory returns its sorted `.rb` files; on a file returns `[file]`.

### U2 — CLI wiring
**Files:** `lib/mutineer/cli.rb`, `test/cli_test.rb`.
**Requirements:** R1, R2, R3 (skip+warn+exit-2), R5, R6.
- Replace `config.sources = argv[1..]` with the KTD2 block.
- Add the all-sources-skipped → exit 2 guard with a clear message.
- Tests: directory arg expands; omitted `--test` infers; explicit `--test` bypasses inference; a source with no test warns to stderr and is dropped; framework re-detected from inferred specs.

### U3 — Per-source aggregate + reporting
**Files:** `lib/mutineer/result.rb`, `lib/mutineer/reporter.rb`, `test/result_test.rb`, `test/reporter_test.rb`, `test/json_reporter_test.rb`.
**Requirements:** R7, R8.
- Add `AggregateResult#by_source` (KTD4).
- Add the human per-source block and JSON `per_source` array (KTD5); bump `schema_version` to `"1.1"`.
- Tests: `by_source` splits a mixed-file result list into per-file aggregates with correct scores; human report shows one line per source; JSON `per_source` present, sorted, parseable.

---

## Verification Contract

**Gate (must pass):**
```
bundle exec rake test && bundle exec ruby -Ilib -e 'require "mutineer"'
```

**Acceptance (all testable WITHOUT Rails, via plain fixtures + standalone mode):**
1. **Convention inference is correct (pure path logic).** `Pairing.infer_test` maps `app/`/`lib/` sources to the right `test/…_test.rb` / `spec/…_spec.rb`, preserving namespaced subdirs, and returns `nil` when no candidate exists. (U1 unit tests, no process, no Rails.)
2. **Multi-source / directory run → combined report with per-source results.** A standalone run over a fixture directory containing ≥2 sources, each with its own test, produces one AggregateResult whose `by_source` and report show per-source killed/survived/score. (U2/U3.)
3. **No-test source is skipped + warned, not fatal.** A run including a source with no inferred test emits `[mutineer] no test found by convention for …; skipping` to stderr, mutates the rest, and exits on the surviving sources' result — not exit 2 (unless *every* source lacks a test). (U2.)
4. **`--test` overrides inference.** With an explicit `--test`, inference does not run and the explicit tests are used. (U2.)

---

## Definition of Done

- Gate command passes (`rake test` green; `require "mutineer"` loads).
- `lib/mutineer/pairing.rb` exists; `expand_sources` + `infer_test` are pure and unit-tested.
- Omitting `--test` infers tests by convention; a directory source expands to its `.rb` files.
- A source with no test is skipped with a stderr warning; all-skipped exits 2 with a clear message.
- `--test` still fully overrides auto-pairing.
- A multi-source run boots once (verified by the unchanged `Runner.execute` path) and reports per-source results in both human and JSON formats.
- `AggregateResult#by_source` exists and returns `{ file => AggregateResult }`; JSON `schema_version` is `"1.1"`.
- No new runtime gem dependency; no `mutant` source referenced; CHANGELOG updated under Unreleased.

---

## Validation (4-lens)

| Lens | Reading | Resolution baked into the plan |
|---|---|---|
| **Predictability** | Risk: inferred-test selection surprises users; framework chosen before tests exist. | First-existing-candidate with a deterministic order (KTD1); framework re-detected from the inferred set (KTD2); every skip is announced on stderr (R3). |
| **Simplicity** | Tempting to add explicit per-source→test mapping plumbing, parallel coverage, or a new pairing config schema. | Rejected — the coverage map already pairs empirically; auto-pairing only fills `config.tests`. One new pure module + a `by_source` one-liner + a report section. No `Runner` change. |
| **Convention** | Must match the repo: small single-purpose classes, stdlib path ops, additive JSON schema. | `Pairing` mirrors existing module style; `Dir.glob`/`File` only; `schema_version` bumped additively to 1.1; reuses `AggregateResult` rather than a new result type. |
| **Experience** | A whole-layer audit must be one command; failures must be legible, not backtraces. | One invocation takes a dir/list; missing tests warn-and-skip (not abort); per-source breakdown tells the user which file is weak; all-skipped gives a usage error, not a crash. |

**Architecture lens:** N/A for a plan doc (code-only).

---

## Dependency note — #13 (roll-up + baseline)

#13 builds on this multi-pair combined report. The reusable shape is **`AggregateResult#by_source → { file => AggregateResult }`** (KTD4) plus the JSON `per_source` array (KTD5): #13 rolls these per-file aggregates up across runs and diffs them against a stored baseline. Keep `by_source` returning real `AggregateResult` instances (not bare hashes) so #13 reuses the score/count methods unchanged.
