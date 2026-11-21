---
title: Capture only changed sources under --since, and pair nested app roots by convention - Plan
type: feat
date: 2026-11-22
issues: [496, 494]
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

**Suggested build:** Opus 5.5, effort medium. Two small pull requests. The design choices are settled below. The risk is in the score effect, which the tests pin.

# Capture only changed sources under --since, and pair nested app roots by convention - Plan

## Goal Capsule

- **Issues:** #496 (`--since` still captures coverage for every source on the command line) and #494 (convention pairing skips the Packwerk layout `packs/<pack>/app` and `packs/<pack>/test`).
- **Objective:** a pull-request check with `--since` costs about what a run of the changed files alone costs, and a Packwerk or engine app gets its pack sources paired with their mirrored tests without a `tests:` map.
- **Means:** narrow the coverage-capture inputs to the sources that still have jobs and their paired tests (KTD1, KTD2). Re-root the existing convention rules at the nearest nested `app/` or `lib/` root (KTD4).
- **Authority:** this plan, then `AGENTS.md` (Score-model discipline), then the issue texts.
- **Stop and ask when:** a change would edit a file under `lib/mutineer/coverage_map/` (the capture code needs no change), or a run without `--since` would get a different verdict, or a source that pairs today would pair with a different test list.
- **Execution profile:** two pull requests on `main` after #511 (the `coverage_map.rb` split) merges. PR A: U1 to U3 (#496). PR B: U4 to U6 (#494). They touch different files and can go in either order.
  - PR A labels: `enhancement`, `priority: medium`, `risk: medium`, `v1.10.0`. Body: `Closes #496`.
  - PR B labels: `enhancement`, `priority: low`, `risk: low`, `v1.10.0`. Body: `Closes #494`.
- **Size:** S each. PR A: `lib/mutineer/config.rb`, `lib/mutineer/cli.rb`, `lib/mutineer/job_plan.rb`, `lib/mutineer/runner.rb`, `lib/mutineer/daemon_backend.rb`, tests, `docs/ci.md`, `CHANGELOG.md`. PR B: `lib/mutineer/pairing.rb`, `test/pairing_test.rb`, one fixture tree, `docs/cli.md`, `CHANGELOG.md`.
- **Release and semver:** both are minor-class changes in the 1.10.0 batch. No GitHub Action input default changes. Both change scores in narrow cases, so both CHANGELOG entries go under "Changed" (KTD7). No agent tags or publishes.

---

## Product Contract

### Summary

Under `--since`, Mutineer already collects and scopes the jobs before it loads the app (`lib/mutineer/runner.rb:136-150`, from #396). It then still builds the coverage map from every source and every paired test (`lib/mutineer/runner.rb:194-221`; daemon path `lib/mutineer/daemon_backend.rb:56-58` and `boot_config`). PR A passes only the sources that still have jobs, and only their paired tests, to the capture. The result equals a run that names those files alone, which is the issue's documented workaround.

Convention pairing strips a leading `app/` or `lib/` and looks under `test/` and `spec/` at the project root (`lib/mutineer/pairing.rb:416-512`). A pack source `packs/catalog/app/models/item.rb` has no such prefix, so it pairs with nothing. PR B tries the same rules again with the pack directory as the root, only when the root layout finds no test.

### Problem Frame

- #496 reports `--since HEAD~10` over every pack folder: 281 test files captured in 198 s, then a clean-check failure on a test that passes alone. Naming the 8 changed files gave 105 s and 20 of 20 mutants killed.
- #494 reports 0 of 3,592 pack mutants paired without a map. A per-pack `tests:` map raises pairing to 98.6%, but each source then gets the whole pack's tests, so capture runs more tests than it needs.
- The capture runs each test in `test_paths` (`lib/mutineer/coverage_map/capture.rb:31`, `:55`). After `CLI.autopair!` flattens the pairs (`lib/mutineer/cli.rb:918-935`), nothing remembers which tests belong to which source. PR A must keep that link.

### Requirements

**#496: narrow the capture under `--since`**

- R1. Under `--since`, with jobs left after scoping, the coverage capture gets only the sources that have a kept job.
- R2. When Mutineer paired the tests (no `--test`), the capture gets only the tests paired with those sources: convention pairs plus `tests:` map entries, in today's order. With `--test`, the capture keeps every test the user named.
- R3. The in-process path and the daemon path narrow the same way. A full-suite fallback (no coverage map) runs the narrowed test set.
- R4. A run without `--since`, a run with `--coverage-from`, and a `--since` run whose kept sources cover every source get today's capture inputs, verdicts and score. `--coverage-from` reads a saved map and captures nothing, so narrowing it saves no time.
- R5. The report's counts do not change: `summary.unpaired_sources`, `summary.unpaired_mutants`, `unscoped_mutants` and the ignored rows stay as today. Only the capture inputs narrow. The end-of-run sweep (`JobPlan.source_dirs(config)`) keeps the full source list.
- R5a. The clean check (`JobPlan.abort_if_unclean!`) now sees only the narrowed tests. A red test paired only with an unchanged source no longer stops a `--since` run. This matches the issue's workaround, and the issue reports that exact failure. Mutineer prints one stderr line when it narrows, so the exclusion is counted: `[mutineer] --since: capturing <n> of <m> test files for <k> of <j> sources`.

**#494: pair nested app roots by convention**

- R6. A source `<prefix>/app/<rest>.rb` or `<prefix>/lib/<rest>.rb`, with a non-empty `<prefix>`, pairs with the tests that the root rules would find for `app/<rest>.rb` or `lib/<rest>.rb` inside `<prefix>`. Examples: `packs/catalog/app/models/item.rb` pairs with `packs/catalog/test/models/item_test.rb`. `engines/billing/lib/billing/tax.rb` pairs with `engines/billing/test/lib/billing/tax_test.rb` or `engines/billing/test/billing/tax_test.rb`. Split tests (#87), concern namespaces (#408) and spec files work as at the root.
- R7. The nested rules run only when the root rules find no test. A source that pairs today keeps exactly its test list.
- R8. `<prefix>` ends at the first `app/` or `lib/` segment of the path. A nested pack (`packs/a/packs/b/app/x.rb`) uses `packs/a/packs/b/`. A path that starts with `app/` or `lib/` (such as `lib/foo/app/x.rb`) gets no nested try: the root rules already own it.
- R8a. A pack with a `test/` folder but no mirrored file for the source leaves that source unpaired and counted.
- R9. A `tests:` map still adds its tests after the convention tests, as today.

**Docs**

- R10. `docs/ci.md` says a `--since` run captures coverage only for the changed sources and their paired tests. `docs/cli.md` (the `--test` row) names the nested root rule. `CHANGELOG.md` gets one "Changed" entry per pull request (KTD7).

### Acceptance Examples

- AE1. **Covers R1, R2, R5.** Given the fixture `test/fixtures/autopair` (`lib/calc.rb`, `lib/greeter.rb`, each with a test) in a temp git repo where only `lib/calc.rb` changed, when `mutineer run lib --since <base>` runs in-process, then the capture ran only `test/calc_test.rb`, and the verdicts equal those of `mutineer run lib/calc.rb --since <base>`.
- AE2. **Covers R3.** The same as AE1 on the daemon path (boot fixture under `rake test:daemon`): the prepare daemon's boot config lists only the kept source and its test.
- AE3. **Covers R2.** With `--test test/calc_test.rb --test test/greeter_test.rb`, the capture runs both tests.
- AE4. **Covers R4.** Without `--since`, `CoverageMap.new` receives `config.sources` and `config.tests` unchanged.
- AE5. **Covers R6, R8.** `Pairing.infer_tests("packs/catalog/app/models/item.rb", ...)` returns `["packs/catalog/test/models/item_test.rb"]` when that file exists. The same holds for an engine path, a `lib/` path, a nested pack, a split test and an RSpec spec.
- AE6. **Covers R7.** A source that the root rules pair today gets the same list. A pack source with no mirrored test stays unpaired and is still counted in `summary.unpaired_sources`.

### Scope Boundaries

Considered and not built:

- **A `{path}` placeholder in `tests:` map entries** (the second option in #494). Convention pairing covers the reported layout with no new config syntax. A request for a layout that convention cannot pair would change this call.
- **Turn the nested rule on only when a `packs/` folder exists** (an option in #494). Engines and components use the same `<root>/app` plus `<root>/test` shape. A pair needs an existing mirrored test file, so a false pair is unlikely.
- **A flag to keep the full capture under `--since`.** `--no-since` already gives a full run. No user asked for a full capture with a narrowed job list.
- **Narrow the `--test-command` path.** It captures no coverage.
- **Reuse a full cached capture for a narrowed run.** A narrowed run has a different source and test list, so it gets its own cache entry. A later full run does not hit it.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Keep the source-to-tests pairs on `Config`.** Add a code-only field `source_tests` (Hash of source path to its paired test list) to the `Config` Struct, like `unpaired_sources` (`lib/mutineer/config.rb:103-116`). `CLI.autopair!` sets it from the `paired` rows it already builds. It stays `nil` when `--test` was given. Why: the pairs exist only inside `autopair!` today. Recomputing them in `Runner` would call CLI code from the run layer and could drift from the run's actual pairing.
- KTD2. **One shared helper picks the capture inputs.** Add `JobPlan.capture_scope(config, jobs)`. It returns `[sources, tests]`. Without `--since`, or with `--coverage-from`, it returns `[config.sources, config.tests]`. Under `--since` it keeps the sources of the kept jobs, in `config.sources` order and spelling. It matches a job's `subject.file` to a `config.sources` entry with `JobPlan.unpaired_path` (`lib/mutineer/job_plan.rb:698`), which already maps relative, absolute and `./` spellings to one file. Tests are the union of `config.source_tests[source]` in that order when `source_tests` is set, else `config.tests`. Why: `JobPlan` already owns the `--since` vocabulary for both paths, so the daemon path cannot drift from in-process (the rule in the `DaemonBackend` module comment).
- KTD3. **Narrow only the capture inputs, not `config`.** `Runner.execute` passes the helper's lists to `CoverageMap.new` (`source_paths:`, `test_paths:`) in both the boot and standalone branches. `DaemonBackend.execute` computes `abs_tests` (`lib/mutineer/daemon_backend.rb:59`) from the helper's tests and passes the helper's sources to `boot_config` through a new `sources:` keyword. So the worker load roots and the full-suite fallback use the narrowed tests. `boot_config`'s `source_dirs:` (orphan sweep) and `sweep_daemon_temps` keep reading `config`. Report code keeps reading `config`. Why: R5. The report counts and the sweep must stay as today.
- KTD4. **Re-root, do not add new candidate rules.** Rename today's body of `Pairing.infer_tests` to a private `root_tests(source_rel, root, prefer)`. `infer_tests` calls `root_tests` at the project root. When that is empty and `nested_root(source_rel)` returns `[prefix, inner]`, it calls `root_tests(inner, File.join(root, prefix), prefer)` and prefixes each result. The nested call uses `root_tests`, not `infer_tests`, so it never re-roots again. Why: every existing rule (exact, split, `test_*`, spec, concern namespace) then works inside a pack with no copy, and R7 holds by construction.
- KTD5. **First `app/` or `lib/` segment wins, and never at the start.** `nested_root` matches `\A(?!(?:app|lib)/)((?:[^/]+/)+?)(app|lib)/` (lazy, so the first such segment, and no try for a path that already starts with `app/` or `lib/`). Why: it gives the pack root for a nested pack and the gem root for `gems/foo/lib/foo/app/x.rb`, and it leaves root sources such as `lib/foo/app/x.rb` to the root rules (R8).
- KTD8. **Other callers of `infer_tests` get the new pairs too.** `CLI.convention_pairs` (`lib/mutineer/cli.rb:776`) uses it for pairing. `CoverageMap#order_tests` (`lib/mutineer/coverage_map.rb:234-236`) uses it to run a mutant's paired test first. A newly paired pack source now has its mirrored test ordered first, as a root source does. This changes test order only, not which tests run.
- KTD6. **The narrowed capture equals a run of the kept files.** Tests check this equality, not one example list. Why: the issue's workaround defines the expected result, and the "Test the rule, not the example" rule in `.expectation-fit/ways-of-working.yaml` asks for the rule.
- KTD7. **Both CHANGELOG entries go under "Changed" and state the score effect.**
  - PR A: "A `--since` run now captures coverage only for the sources that have a changed mutant and the tests paired with them (#496). It now scores like a run that names only those files. A mutant that only a test paired with an unchanged source killed can now survive. A failing test paired only with an unchanged source no longer stops the run. Mutineer prints how many test files it captured. `--no-since` and `--coverage-from` runs are unchanged."
  - PR B: "Convention pairing now pairs sources under a nested `app/` or `lib/` root, such as `packs/<pack>/app/models/x.rb` with `packs/<pack>/test/models/x_test.rb` (#494). Sources that paired before keep their tests. A Packwerk or engine app without a `tests:` map now scores those sources instead of skipping them, so its score and mutant count change, and `summary.unpaired_sources` drops. To keep the old scope, pass only the sources you want."

### Assumptions

- The Fizzy sample (`bundle exec rake fizzy:sample`) runs without `--since`, so PR A cannot move its counts. Whether Fizzy has a source under a nested `app/` or `lib/` root is not checked. The release check (`rake fizzy:sample` on merged `main`) shows any change, and the PR B builder runs it once before opening PR B.

### Sequencing

PR A: U1, then U2, then U3. PR B: U4, then U5, then U6.

PR #511 (the `coverage_map.rb` split) is still open. Both pull requests branch from `main` after #511 merges. If #511 is still open when a build starts, branch from `refactor/201-coverage-map-modules` and rebase onto `main` once it merges. Neither pull request edits a file that #511 changes, so the rebase is mechanical.

Group I (#416, plan `docs/plans/2026-11-22-416-fix-run-lock-gaps-plan.md`) changes `prepare_run` and `run_serial` in `lib/mutineer/daemon_backend.rb`, and adds a second prepare boot in `prepare_run`. PR A changes how `prepare_run` builds its boot config. Group I lands first. The PR A builder rebases on it and passes the narrowed `abs_tests` and `sources:` to both boots in `prepare_run`.

---

## Implementation Units

### PR A (#496)

Waits on: #511 must merge first (base branch).

#### U1. Keep the pairs on Config

- **Goal:** the run knows each source's paired tests (KTD1).
- **Files:** `lib/mutineer/config.rb`, `lib/mutineer/cli.rb` (`autopair!`), `test/cli_test.rb`.
- **Approach:** add `:source_tests` to the Struct, documented as code only. In `autopair!`, set `config.source_tests = paired.to_h`. Leave it `nil` when `config.tests` was given.
- **Test scenarios:** autopair of the `autopair` fixture sets both pairs. `--test` leaves it `nil`. A `tests:` map entry appears after the convention test in the source's list.
- **Verification:** `bundle exec rake test`; `bundle exec rake yard:strict`.

#### U2. Narrow the capture inputs

- **Goal:** R1 to R5 on both paths (KTD2, KTD3).
- **Files:** `lib/mutineer/job_plan.rb` (`capture_scope`), `lib/mutineer/runner.rb` (both `CoverageMap.new` calls), `lib/mutineer/daemon_backend.rb` (`execute`, `boot_config` with a `sources:` keyword that defaults to `config.sources`), `test/runner_test.rb`, `test/since_empty_run_test.rb` or a new `test/since_capture_scope_test.rb`, `test/daemon_backend_contract_test.rb`.
- **Approach:** the in-process path already holds `since_scope` before capture. Call `capture_scope` with `since_jobs`. The daemon path calls it after `scope_since`. Each `boot_config` call (prepare and workers) gets the same lists, so the worker load roots and the full-suite fallback use the narrowed tests.
- **Test scenarios:**
  - Unit tests for `capture_scope`: no `--since`; `--coverage-from` set; `--since` with one kept source; `--test` given; a kept source with a mapped test; source order kept; `config.sources` spelled relative, absolute and with `./` against an absolute `subject.file` (all keep the source).
  - The narrowing line on stderr names the right counts. No line prints when nothing narrows.
  - A red test paired only with an unchanged source does not stop a `--since` run (R5a). Without `--since`, it still stops the run.
  - The daemon contract test asserts `source_dirs:` in the boot config still lists every source directory (R5).
  - AE1: a temp git repo copy of the `autopair` fixture, change `lib/calc.rb`, run in-process with `--since`. Assert the capture timings list only `test/calc_test.rb`, and the verdict set equals a run of `lib/calc.rb` alone (KTD6).
  - AE2: a contract test stubs `DaemonClient.new` and asserts the prepare daemon's boot config `sources` and `tests` hold only the kept pair.
  - AE3 and AE4 as unit tests on `capture_scope`.
  - A report test asserts `summary.unpaired_sources` and `unscoped_mutants` match a run without the narrowing (R5).
- **Verification:** `bundle exec rake test`; `bundle exec rake test:daemon`.

#### U3. Docs and CHANGELOG for PR A

- **Files:** `docs/ci.md` (the "Changed code" row and the paragraph after the first example), `CHANGELOG.md`.
- **Approach:** state R10 and the KTD7 PR A text. Remove the need for the issue's workaround from any doc that shows it (grep for `git diff --name-only`).
- **Verification:** `bundle exec rake yard:strict`; read the edits against the code. For any change under `docs/` that the site publishes, run the website checks in `AGENTS.md`.

### PR B (#494)

Waits on: nothing. It can merge before or after PR A.

#### U4. Re-root convention pairing

- **Goal:** R6 to R9 (KTD4, KTD5).
- **Files:** `lib/mutineer/pairing.rb` (`infer_tests`, new helpers `root_tests` and `nested_root`, the module comment list), `test/pairing_test.rb`, `test/coverage_map_test.rb`.
- **Approach:** KTD4 and KTD5. `root_tests` holds today's logic unchanged (direct try, then the concern-namespace try). `infer_tests` adds the nested try after it. Update the `Pairing` module comment's `infer_tests` bullet.
- **Test scenarios:** for each of these, one test with the file present and one with it absent: Packwerk `app/` model; Packwerk `lib/` file (both `test/lib/` and `test/` layouts); engine path; nested pack; split test (`item_pricing_test.rb`); concern namespace inside a pack; RSpec spec inside a pack with `prefer: "rspec"`. Also: a source that pairs at the root today keeps its list (R7); `lib/foo/app/x.rb` with `lib/foo/test/x_test.rb` present gets no pair (R8); a pack with a `test/` folder but no mirrored file stays unpaired (R8a).
- **Ordering test (KTD8):** a `CoverageMap#order_tests` test with a pack source and two covering tests puts the mirrored pack test first.
- **Verification:** `bundle exec rake test`; `bundle exec rake yard:strict`.

#### U5. End-to-end fixture

- **Goal:** prove the run pairs and scores a pack source (AE6).
- **Files:** a new fixture `test/fixtures/packwerk/packs/catalog/{app/models/item.rb,test/models/item_test.rb}` plus one unpaired pack source, `test/cli_test.rb` or `test/runner_test.rb`.
- **Approach:** run `mutineer run packs` in-process (standalone, no Rails) from the fixture root. Assert `item.rb` is paired and scored, and the unpaired source is in `summary.unpaired_sources`.
- **Verification:** `bundle exec rake test`.

#### U6. Docs and CHANGELOG for PR B

- **Files:** `docs/cli.md` (the `--test` row and the `tests:` map paragraph at line 156), `CHANGELOG.md`.
- **Approach:** add one sentence on the nested root rule and the KTD7 PR B text. Keep the advice that a `tests:` map still adds tests.
- **Verification:** `bundle exec rake yard:strict`; website checks from `AGENTS.md` if a published page changed.

---

## Verification Contract

For each pull request, on its head commit:

- `bundle exec rake test`
- `ruby -Ilib -e 'require "mutineer"'`
- `bundle exec rake yard:strict`
- PR A: `bundle exec rake test:daemon` (daemon path narrowing).
- Website checks from `AGENTS.md` ("Website checks") when a published docs page changed.
- Author self-check skill (`.claude/skills/author-self-check/SKILL.md`) before the first push.
- Before the 1.10.0 release, `bundle exec rake fizzy:sample` on merged `main` must still match `rake/fizzy_sample.json`.

## Definition of Done

- U1 to U6 done, each with its tests green.
- AE1 to AE6 pass.
- No diff under `lib/mutineer/coverage_map/`.
- A run without `--since` gets the same capture inputs as before (AE4).
- Each CHANGELOG entry states its score effect (KTD7).
- No leftover experimental code in either diff.

## Open Questions

- **Q1 (David).** Ship the #496 narrowing in 1.10.0 as a minor "Changed" entry, though the Action's default `since:` input now captures fewer tests and a cross-covered mutant can survive? **Recommended: yes.** The Action's input defaults do not change, and the result equals the documented workaround of naming the changed files, so it is not a default flip under the semver rule in `AGENTS.md`.
- **Q2 (David).** Apply the #494 rule to any nested `app/` or `lib/` root (packs, engines, components), not only `packs/`? **Recommended: yes, any nested root.** A pair still needs an existing mirrored test file, and an engine user would be surprised by a rule that works only under `packs/`.
- **Q3 (David).** Report the #494 score change only in the CHANGELOG "Changed" entry (KTD7), with no runtime notice? **Recommended: yes.** The newly paired sources are visible in the report already (fewer `unpaired_sources`, more mutants), and a one-time runtime notice would need state Mutineer does not keep.
