---
title: "Score a mutant that two operators make only once - Plan"
type: fix
date: 2026-10-24
issue: 275
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
depth: lightweight
---

# Score a mutant that two operators make only once - Plan

## Goal Capsule

- **Issue:** #275. When two opt-in operators make the same mutated source, Mutineer runs and scores it twice.
- **Goal:** run one copy of each such mutant, keep the copy of the operator that comes first in `MutatorRegistry::ALL`, keep every kept id unchanged, and keep a dropped copy's `ignore:` entry valid for `mutineer migrate` and the old-id warning.
- **Authority:** `AGENTS.md` first, then this plan, then the `**Claude:**` comment on #275.
- **Stop when:** the new tests behave as each scenario states on `main` and with the fix, the local gate in the Verification Contract is green, and the CHANGELOG entry is in place.
- **Size:** S. About 12 changed lines in `lib/mutineer/job_plan.rb` and `lib/mutineer/migrate.rb`, nine tests, one CHANGELOG entry.

---

## Product Contract

### Summary

On `main`, `JobPlan.result_keys` groups mutations by operator and line, so copies from two operators never share a key. `JobPlan.collect_jobs` builds each subject's mutation list in the `--operators` order, and it returns no ids for dropped copies. This plan makes three changes. `result_keys` groups by line only, so two copies that give the same source share a key, and the existing #159 drop runs one copy. `collect_jobs` builds the list in registry order, so the copy that stays does not depend on the `--operators` order. `collect_jobs` also returns the dropped copies' ids, so `mutineer migrate` still treats them as current ids.

### Problem Frame

Reproduced on `main` (v1.7.0, Ruby 3.4.9), with `collect_jobs` on this repo's `lib/`:

| Operators | Mutants on `main` | With the fix |
| --- | --- | --- |
| `literal_mutation,string_literal` | 3,507 (2,553 + 954) | 2,643 (2,553 + 90) |
| `string_literal,literal_mutation` | 3,507 | 2,643, the same 2,553 + 90 |
| `chain_link,call_to_receiver` | 3,602 | 3,602 |
| all 21 operators | 16,393 | 15,529 |

All 864 dropped mutants are `string_literal` copies. With all 21 operators, no other operator loses a mutant on `lib/`.

Root cause:
- `lib/mutineer/job_plan.rb:67`: `collect_jobs` collects every operator's mutations for a subject with `operator_classes.flat_map`.
- `lib/mutineer/job_plan.rb:115`: `result_keys` groups by `[operator, line]`. Only a group of two or more gets a content key, so copies from two operators always get different keys.
- `lib/mutineer/job_plan.rb:83`: `collect_jobs` drops a repeat key. It runs separately for run and ignored mutants (#159).
- The two operators edit different byte spans. `literal_mutation` replaces the whole node (`"hi"` to `""`). `string_literal` replaces only the content (`hi` to nothing). So the issue's proposed `(file, start, end, replacement)` key misses every pair. The existing span digest in `result_keys` compares the mutated text from the group's first start to its last end, so it catches both shapes.

### Requirements

- R1. Two mutations of one subject on the same line that give the same mutated source run once, whatever their operators.
- R2. The copy that stays is the one whose operator comes first in `MutatorRegistry::ALL` (the `mutineer --list-operators` order). The `--operators` order and the `operators:` order in `.mutineer.yml` do not change which copy stays.
- R3. Every kept mutant keeps the id it has on `main`. The dropped copy's id stops appearing in reports, as for #159.
- R4. The #159 rule stays. Copies are dropped separately among run and ignored mutants, so an ignored copy never hides a copy that should run. Copies that start on different lines both stay.
- R5. A run with only one operator of each pair keeps the same mutants and ids. (Its run order can change, see KTD2.)
- R6. An `ignore:` entry that names a dropped copy stays valid. `mutineer migrate` treats its id as current and maps its old-format id to it. A run still lists an old-format entry for it in the migrate warning. For the #275 pairs this keeps the `main` result. For the #159 same-operator copies it fixes the same gap: on `main`, migrate exits 1 for an `ignore:` list that names both copies, and with U3 it exits 0.

### Stability check (STABILITY.md)

The issue asks whether this is a behaviour change under `STABILITY.md`. It is a fix, and a patch or minor release can ship it.

- **Mutant ids.** The contract is "the same id for the same mutant" (`STABILITY.md`, "What SemVer covers"). `MutantId.for` hashes the operator, the token and an occurrence among same-operator, same-token twins (`lib/mutineer/mutant_id.rb:43-46`, `:98-106`). The occurrence never counts mutations of another operator, and `collect_jobs` computes ids on the full list before the drop. So a kept mutant keeps its id, whatever the operator order (R3).
- **Dropped ids.** The dropped copy's id stops appearing in reports. #159 shipped the same drop in 1.5.0 under `### Fixed`, so there is a precedent. An `ignore:` entry for that id stays valid: a run with that operator alone still uses it, and migrate keeps it (R6).
- **Exit codes.** No new failure. Without R6, `mutineer migrate` would exit 1 for a config that is valid on `main` (confirmed on a prototype, see Risks). With R6, migrate exits 0 instead of 1 for an `ignore:` list that names both #159 same-operator copies. That is a fix, and the CHANGELOG names it.
- **Not in the contract.** Mutant counts and the score are not a SemVer contract. JSON keys, flags and config keys do not change.
- **Not in the contract, but visible.** Within one method, mutants now run and list in registry order. Before, they followed the `--operators` order. This reaches every run whose operator list is not in registry order, also a run with no duplicate pair. The `--dry-run` list, its per-operator summary, the progress output and the survivor that `--fail-fast` stops on follow that order. The JSON, HTML and human reports sort their lists, so they do not change.

### Scope Boundaries

- Only mutations that give the same text. A single-quoted string is not merged: `literal_mutation` turns `'hi'` into `""`, and `string_literal` turns it into `''`. An empty string has no `literal_mutation` copy. On `lib/`, the 90 `string_literal` mutants left are 40 single-quoted strings and 50 empty strings (counted on the prototype). Scenario 7 pins the single-quote case.
- Only the copies that `result_keys` can already see: the same subject and the same start line. Copies that start on different lines both stay (R4). This matches #159 and keeps `--since` safe.
- The `--dry-run` summary gets no "merged" count, as for #159.
- No change to `MutantId`, `MutatorRegistry` or the mutators.

### Deferred to Follow-Up Work

- **Single-quoted strings.** File one issue: `literal_mutation` could keep the quote style (`'hi'` to `''`), so its copy matches `string_literal` and is merged too. That is a mutator change, and it changes `literal_mutation` ids on single-quoted strings, so it needs its own CHANGELOG entry. Name the issue in the PR body.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Group by line only.** In `result_keys`, group the indexes by `lines[i]`, not by `[operator, line]`. Drop `operator` from the content key. The digest already compares the mutated text over the group's span, and the span is the same for every member. So two keys are equal exactly when the mutated sources are equal. This is the approach in the issue comment.
- **KTD2. Build the mutation list in registry order.** At the top of `collect_jobs`, sort `operator_classes` by their position in `MutatorRegistry::ALL.values`. Break ties by input position, and put a class that is not in `ALL` last. Then the existing first-copy-wins rule keeps the registry-first copy (R2). Keep this one line in `collect_jobs`, with a comment that says why. `MutatorRegistry.resolve` keeps the requested order (its YARD says so), so do not sort there. A new `MutatorRegistry.rank` method would add a public method for one caller.
- **KTD3. Keep the separate run and ignored sets.** The #159 loop stays. An ignore entry for one copy's id still ignores only that copy, and the other copy still runs (R4).
- **KTD4. Return dropped ids in a new extras key.** When the drop loop skips a copy, record `id => legacy` in a new `:dropped_id_map` entry of the extras hash. `id_map` stays "kept copies only", as the PR #198 review asked. `Migrate.id_maps` merges both maps, so its current ids and its old-to-new map also cover dropped copies (R6). No other caller reads the new key. This also fixes the same migrate gap for the #159 same-operator copies (R6). Also move the old-format match record (`legacy_ignore_matches`, lines 86-90) above the drop, so a dropped copy's old-format `ignore:` entry still gets the run-time migrate warning.

### High-Level Technical Design

Directional sketch:

```text
collect_jobs:
  ranked = operator_classes sorted by (index in MutatorRegistry::ALL.values, else last; then input index)
  per subject:
    mutations = ranked.flat_map(mutations_for)        # was operator_classes.flat_map
    ids, legacy_ids, lines as today (full list, before the drop)
    keys = result_keys(mutations, source, lines)
    drop loop as today (first copy per key wins, separately for run and ignored)
      old-format ignore match recorded before the drop  # moved up
      a dropped copy: dropped_id_map[id] = legacy      # new
  extras: { legacy_ignore_matches:, id_map:, dropped_id_map: }

result_keys:
  group indexes by line                               # was [operator, line]
  for a group of 2 or more: key = [line, sha256(span)] # was [operator, line, sha256(span)]

Migrate.id_maps:
  all = id_map merged with dropped_id_map             # was id_map
  current = all.keys; old_to_new built from all
```

### Assumptions

- `Mutation#apply` is one splice of `replacement` over `start_offset...end_offset` (`lib/mutineer/mutation.rb:15-17`). So equal span text means equal mutated source. Every operator uses it.
- Grouping by line builds more digests: one per mutation on a line with two or more mutations. Measured with all 21 operators on `lib/`: planning took about 1.5 s on `main` and about 1.7 s with the change. The runs were noisy, and the cost is small next to running 15,000 mutants.

---

## Implementation Units

A prototype of U1 and U3 on an export of `main` confirmed every "fails on `main`" and "passes with the fix" result below. The full suite ran with all nine tests: 1418 runs, one failure. That failure was `test_since_unknown_ref_exits_two`, which needs a git checkout. The export was not one, and the test passes in the clone.

### U1. Drop cross-operator copies and keep the registry-first copy

**Goal:** R1 to R5.

**Requirements:** R1, R2, R3, R4, R5.

**Dependencies:** none.

**Files:**
- `lib/mutineer/job_plan.rb`:
  - `JobPlan.collect_jobs` (lines 50-100). Sort `operator_classes` once, before the subject loop at line 64. Use the sorted list in the `flat_map` at line 67. Update the comment at lines 75-77: the repeat can now come from any operator. Add one sentence to the YARD text (lines 24-45): mutations are collected in registry order, so a repeat keeps the registry-first operator's copy.
  - `JobPlan.result_keys` (lines 113-127). Change the `group_by` at line 115 to the line only. Drop `m.operator` from the key at line 123. Rewrite the YARD text at lines 102-108: two mutations share a key when they are on the same line and give the same mutated source, from any operator.
- `test/runner_test.rb`: seven new tests (scenarios 1 to 7) after `test_collect_jobs_keeps_an_unsuppressed_copy_of_a_suppressed_edit` (line 502). Give each a `# #275:` comment, like the `# #159:` tests.

**Approach:** see KTD1 and KTD2. Keep the existing early `next if group.size < 2`. The sort key must not raise on a class that is not in `ALL`. `MutantId.for_subject` and `legacy_for_subject` keep their calls on the full list.

**Patterns to follow:** the #159 tests at `test/runner_test.rb:438-515` (PR #198). They build a small class in `Dir.mktmpdir`, call `JobPlan.collect_jobs` with `MutatorRegistry.resolve`, and compare ids.

**Test scenarios.** Each source is a small class in a temp file.

1. `test_collect_jobs_runs_a_cross_operator_copy_once`. Source: `class Str` / `def a` / `"hi"` / `end` / `end`. Run `literal_mutation,string_literal`. Assert the job operators are `[:literal_mutation]`. Assert the job id equals the id from a `literal_mutation`-only run (R3). Assert `extras[:id_map].size` is 1 (kept copies only). Fails on `main`: two jobs.
2. `test_collect_jobs_keeps_the_registry_first_copy_in_any_operator_order`. Same source. Run `string_literal,literal_mutation`. Assert the job operators are `[:literal_mutation]`, and the job ids equal those of the forward order (R2). Fails on `main`: two jobs.
3. `test_collect_jobs_runs_a_chain_copy_once`. Source: `class Chain` / `def a(node)` / `node.name.name` / `end` / `end`. Run `call_to_receiver,chain_link`. Assert no two jobs give the same mutated source. Assert exactly one job gives `node.name`, and its operator is `:chain_link`. Fails on `main`: two jobs give `node.name`.
4. `test_collect_jobs_keeps_the_run_copy_when_the_other_operator_copy_is_ignored` (R4). Same source as scenario 1. Put the `string_literal` copy's id (from a `string_literal`-only run) in `ignore:`. Run both operators. Assert `ignored` holds that one id, and the job operators are `[:literal_mutation]`. Passes on `main` too. It guards KTD3.
5. `test_collect_jobs_records_one_ignored_copy_across_operators`. Source: `"hi" # mutineer:disable-line` on line 3. Run `string_literal,literal_mutation`. Assert no jobs, and the ignored operators are `[:literal_mutation]`. Fails on `main`: two ignored copies.
6. `test_collect_jobs_lists_mutants_in_registry_order`. Source: `def a(x)` / `"hi" + x`. Run `string_literal,arithmetic`. Assert the job operators are `[:arithmetic, :string_literal]`. Fails on `main`: `[:string_literal, :arithmetic]`.
7. `test_collect_jobs_keeps_both_copies_of_a_single_quoted_string`. Source: `'hi'` on line 3. Run `literal_mutation,string_literal`. Assert the job operators are `[:literal_mutation, :string_literal]` (scope boundary: different text). Passes on `main` too. It fails if a later change merges copies that are not the same text.

**Existing tests that must stay green unchanged:** `test_collect_jobs_runs_a_repeated_edit_once_and_keeps_ids` (its `result_keys` call keeps the same signature), `test_collect_jobs_runs_a_repeated_operand_removal_once`, `test_collect_jobs_keeps_copies_on_different_lines`, `test_collect_jobs_keeps_an_unsuppressed_copy_of_a_suppressed_edit`, `test/mutant_id_test.rb`, `test/daemon_backend_contract_test.rb`, and the exact-survivor oracle in `test/integration_test.rb`.

R5 has no new test of its own. Every existing single-operator test guards it, and scenario 1 compares the kept id with a `literal_mutation`-only run.

**Verification:** scenarios 1 to 3, 5 and 6 fail on `main` and pass on the branch. Scenarios 4 and 7 pass on both.

### U3. Keep a dropped copy's id current for migrate

**Goal:** R6.

**Requirements:** R6.

**Dependencies:** U1. Without U1, no cross-operator copy is dropped.

**Files:**
- `lib/mutineer/job_plan.rb`: `collect_jobs`. Add a `dropped_id_map` hash next to `id_map` (line 63). In the drop at line 83, record `id => legacy` before the skip. Move the `legacy_ignore_matches` block (lines 86-90) above the drop. Return `dropped_id_map:` in the extras hash at line 99. Update the `@return` text at lines 48-49, the extras sentence at lines 33-40, and the comment at line 77 ("A dropped copy records nothing").
- `lib/mutineer/runner.rb`: the `Runner.execute` YARD at line 35 lists the extras keys. Add `:dropped_id_map`.
- `lib/mutineer/migrate.rb`: `Migrate.id_maps` (lines 42-51). Build both return values from `id_map` merged with `dropped_id_map`. Update its comment (lines 9-14 and 37-41): a dropped copy's id is current too.
- `test/migrate_test.rb`: one new test (scenario 8).
- `test/runner_test.rb`: one new test (scenario 9), next to the U1 tests.

**Approach:** see KTD4. Do not add the dropped ids to `id_map`. `Baseline#diff` reads `id_map` (`lib/mutineer/cli.rb:676`) to match old-format baselines, and a baseline holds only reported mutants.

**Patterns to follow:** `test_fixture_source_maps_each_old_id_to_its_new_id` in `test/migrate_test.rb` (it calls `Migrate.id_maps` and checks `current` and `old_to_new`).

**Test scenarios:**

8. `test/migrate_test.rb`, `test_a_dropped_copy_id_is_still_current`. Source as scenario 1, config with `operators: %w[literal_mutation string_literal]`. Take the `string_literal` copy's new and old ids from a `string_literal`-only `collect_jobs` run. Assert `current` includes the new id. Assert `old_to_new[old]` is `[new]`. Assert `Migrate.rewrite("ignore:\n  - <new>\n", current, old_to_new).unmapped` is empty. Passes on `main` (no copy is dropped there). Fails with U1 alone: the new id is not current. Passes with U1 and U3.

9. `test/runner_test.rb`, `test_collect_jobs_reports_an_old_format_entry_for_a_dropped_copy`. Source as scenario 1. Take both copies' old-format ids from single-operator runs and put both in `ignore:`. Run both operators. Assert one ignored result. Assert `extras[:legacy_ignore_matches].keys` holds both old ids. Fails on `main` (two ignored results). Fails with U1 and the `dropped_id_map` change but without the move (the `string_literal` old id is missing). Passes with all of U3.

**Verification:** scenarios 8 and 9 behave as stated. On the prototype, a `.mutineer.yml` with both operators and both copies' ids under `ignore:` gave `mutineer migrate` exit 0 on `main`, exit 1 with U1 alone ("matched no mutant"), and exit 0 with U1 and U3. The #159 case was also run: `literal_mutation` on `0` with both copies' ids under `ignore:` exits 1 on `main` and 0 with U1 and U3.

### U2. CHANGELOG entry

**Goal:** tell users what changes when they combine these operators.

**Requirements:** R2, R3, R6.

**Dependencies:** U1, U3.

**Files:**
- `CHANGELOG.md`: add a `### Fixed` block after the `### Changed` block under `## [Unreleased]` (the Added, Changed, Fixed order of 1.7.0, 1.6.0 and 1.5.0). Then add this entry. Wrap it near 80 columns like its siblings:

```markdown
- **A mutant that two operators make is scored once** (#275).
  `literal_mutation` and `string_literal` both turn `"hi"` into `""`, and
  `chain_link` and `call_to_receiver` both turn `node.name.name` into
  `node.name`. Each copy had its own id, so one surviving edit counted twice.
  Now one copy runs: the copy of the operator that comes first in
  `mutineer --list-operators`, whatever the `--operators` order. Only the
  same text counts: a single-quoted `'hi'` still gives two mutants (`""` and
  `''`).
  - Every kept mutant keeps its id. The dropped copy's id no longer appears
    in reports. Runs that use only one of these operators keep the same
    mutants and ids.
  - If you combine these operators, the mutant count and the score can move
    with no code change, so a `--threshold` gate can change its result.
    Regenerate a `--baseline` file with `--format json` after upgrading. In a
    full (unscoped) comparison, a dropped copy that survived is listed as
    fixed.
  - An ignore entry for one copy's id still ignores only that copy. Keep the
    entry: a run with that operator alone still uses it, and
    `mutineer migrate` keeps it as a current id. This also fixes the #159
    copies: an `ignore:` list that names both copies of a repeated edit no
    longer makes `mutineer migrate` exit 1.
  - Within a method, mutants now run and list in the `--list-operators`
    order. This applies to any run whose `--operators` or `operators:` list
    is in another order, so `--dry-run` lists and `--fail-fast` can differ.
```

**Test expectation:** none. Text only.

**Verification:** the entry is under `## [Unreleased]`, in a `### Fixed` block after `### Changed`. No em dash in new text.

---

## Verification Contract

Prefix each command with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` in a shell where they are unset.

```sh
bundle exec ruby -Itest test/runner_test.rb
bundle exec ruby -Itest test/migrate_test.rb
bundle exec rake test
ruby -Ilib -e 'require "mutineer"'
bundle exec rake yard:strict
BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle exec rake test
```

Optional count check: run `collect_jobs` on `lib/` with `literal_mutation,string_literal` and with the reverse order. Both give 2,643 mutants (2,553 `literal_mutation`, 90 `string_literal`). The counts move when `lib/` changes.

`AGENTS.md` rules that apply:
- Zero runtime dependencies and no `eval`. The change uses stdlib only (`Digest` and `Set` are already required).
- 100% YARD docs. The changed comments on `collect_jobs`, `result_keys`, `Migrate.id_maps` and `Runner.execute` must stay complete for `rake yard:strict`.
- CHANGELOG entry under `## [Unreleased]`.
- Score model: no change to the denominator rules. The exact-survivor oracle stays green.
- Least astonishment: the kept copy and its id do not depend on flag order (R2), and migrate does not start to fail on a valid config (R6).
- No site page changes, so the website checks do not apply.

## Definition of Done

- Scenarios 1 to 9 exist and behave as stated on `main` and on the branch.
- The local gate above is green on Minitest 5 and Minitest 6.
- `MutantId`, `MutatorRegistry` and the mutators have no diff.
- The CHANGELOG entry is in place.
- The single-quoted string follow-up issue exists, and the PR body names it.
- No prototype or debug code is left in the diff.

---

## Risks and Overlaps

- **Migrate exit 1 without U3.** Confirmed on the prototype. With U1 alone, a config that names both copies' ids under `ignore:` makes `mutineer migrate` warn that the `string_literal` id "matched no mutant" and exit 1. The entry is still valid, so that would be a false warning and a new failure. U3 prevents it. Land U1 and U3 in the same PR.
- **Baselines and gates.** A user who combines the two operators sees a lower mutant count and a different score. A `--threshold` gate can pass or fail differently. In a full `--baseline` comparison, a dropped survivor is listed as fixed, not as a regression. The CHANGELOG says to regenerate the baseline.
- **Run order.** KTD2 changes the order of jobs within a subject for a user whose `--operators` list is not in registry order. Fail-fast and progress output follow job order. The sorted reports do not change.
- **#244 (flip the 2.0 contract)** rewrites the drop loop in `collect_jobs` (it moves the loop into a second pass over `records`), and it removes `legacy_ignore_matches` from the extras hash. It keeps `result_keys`, `id_map` and the `seen` sets. Expect a text conflict near lines 63-99. The rebase must keep the sorted operator list, the line-only grouping and `dropped_id_map`.
- **#310 (read files as UTF-8)** changes `job_plan.rb:65`, next to the `flat_map` at line 67. Expect a small text conflict.
- **#308 (temp-file sweeps)** changes `job_plan.rb` near line 435. No overlap with this change.
- **CHANGELOG conflicts.** #304, #305, #306, #307, #308, #310, #244 and #245 all edit `CHANGELOG.md` under `## [Unreleased]`. Rebase before merge and keep every entry.
- **#202 (split `coverage_map.rb`), #245 (daemon by default) and #301 (expectation-fit conventions)** are open. #302 (website onboarding) is merged. None of them touches `collect_jobs`, `result_keys` or `Migrate`.
- **This plan file.** PR #193 removed `docs/plans/` from `main`. Until #309 (keep `docs/plans` off the published site) merges, `rake site:build` publishes files under `docs/`. Keep this plan on its plan branch. Do not include it in the fix PR.

## Open Questions

- **Alternative not taken: keep the `--operators` order for jobs.** KTD2 sorts the whole list, so jobs within a subject run in registry order. The alternative keeps the input order and picks the copy to keep by registry rank in the drop loop. That keeps the job order, but it needs a two-pass loop. Pick it only if someone depends on the `--operators` order for the run order or the `--dry-run` list.
- **Alternative not taken: accept the migrate exit 1.** #159 shipped without U3, so its same-operator copies already have this gap. Dropping U3 saves about four lines, but a valid config would then fail `mutineer migrate`. This plan keeps U3.

## Sources

- Issue #275 and its `**Claude:**` comment (root cause, the line-only grouping, the registry-first rule, the 864 count).
- `lib/mutineer/job_plan.rb:24-127`, `lib/mutineer/mutant_id.rb:43-106`, `lib/mutineer/mutator_registry.rb:35-99`, `lib/mutineer/migrate.rb:9-51`, `lib/mutineer/cli.rb:248-266` and `:676`.
- `STABILITY.md`, "What SemVer covers".
- `CHANGELOG.md`, the #159 entry under 1.5.0 `### Fixed` (PR #198).
- Open PRs #244, #308 and #310 (`gh pr diff`, `lib/mutineer/job_plan.rb` hunks), and the open PR file lists for #202, #245, #301 and #304 to #310.
