---
title: "Continuation-line coverage in one-line blocks - Plan"
type: fix
date: 2026-10-24
issue: 289
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
depth: lightweight
---

# Continuation-line coverage in one-line blocks - Plan

## Goal Capsule

- **Issue:** #289. A mutant on a continuation line inside a one-line block stays `no_coverage`, whatever the tests do.
- **Goal:** such a mutant runs the tests that ran the first or last line of its statement, as a `:maybe` selection, so a kill counts and a survivor stays `no_coverage` (or `ran_at_load`, R5).
- **Authority:** `AGENTS.md` first, then this plan, then the `**Claude:**` comment on #289.
- **Stop when:** the new tests fail on `main` and pass with the fix, the local gate in the Verification Contract is green, and the CHANGELOG line is in place.
- **Size:** S. One logic change in two methods, one fixture method, seven tests.

---

## Product Contract

### Summary

When the strict statement lines of a mutant give no tests, `JobPlan.coverage_selection` retries with the loose lines. The loose lines now keep the first and last line of the statement, but never the `def` line. That retry is a `:maybe` selection, so the existing asymmetric verdict applies.

### Problem Frame

Ruby counts one line of a multi-line statement. For a call split across lines inside a one-line block, that line is the block opener:

```ruby
def self.names(users)
  users.map { |u| format("%s %s",
    u[0] + 1,
    u[1] - 1) }
end
```

`StatementLines.for` drops the first line because `users.map { |u| ` comes before the statement on it. It drops the last line because ` }` follows the statement on it. Only the middle line is left, and Ruby never counts it. The lines are not empty, so the #254 loose fallback does not run. The mutant gets no tests and is `no_coverage` forever. No test can change that verdict, which breaks the #254 contract.

Reproduced on `main` (v1.7.0, Ruby 3.4.9) with a real run: the fixture above with a strong test gives 2 mutants, both `no_coverage`. A lambda inside a method (`pick = ->(r) { format("%d %d",` with `r + 1,` and `r - 1) }` on later lines) gives the same result.

### Requirements

- R1. A mutant on a continuation line of a statement inside a one-line block or lambda runs the tests that ran the line Ruby counts for the statement.
- R2. That selection is `:maybe`. A kill is `killed`. A survivor is `no_coverage` with no `--matrix` row, except under R5. An error or a timeout stays what it is.
- R3. The `def` line is never a source of tests in the retry, because Ruby counts it when the file loads.
- R4. Every selection that gives tests today keeps its kind (`:run` or `:maybe`). A `:run` selection keeps the same tests. A `:maybe` selection (#254) can also gain the tests of a first or last line of its statement.
- R5. `JobPlan.ran_at_load?` keeps the strict lines. A mutant that is `ran_at_load` today because its strict lines ran at load, and whose edge line has tests, now runs as `:maybe`. A kill is `killed`. A survivor stays `ran_at_load`, because `load_verdict` runs before `selection_verdict` (`runner.rb:352-353`, `daemon_backend.rb:393-395`).
- R6. The in-process path and the `--daemon` path give the same verdicts. Both call `coverage_selection`, so one change covers both.

### Scope Boundaries

- The class-body example in the issue (`scope :x, -> { where(a: 1,` ... `) }`) is out of scope. A class body is not a subject, so Mutineer makes no mutants there. The same shape inside a `def` is in scope (R1).
- The heredoc sibling in the issue is out of scope. It does not reproduce. On Ruby 3.4.9 both lines of a split interpolation (`#{out << a + 1` and `a - 1}`) have a count, in an assigned heredoc and in a bare heredoc. The issue comment also found that `#{[a,` / `a * 2].sum}` is killed on `main`.

### Deferred to Follow-Up Work

- Statements whose only counted line is the `def` line. Two shapes: a one-line `def` opener with a continuation line (`def self.untested; [:a,` then `:never_called]; end`), and the body of a multi-line endless method (`def self.empty =` then `:never_counted`, which `test_empty` calls). The retry drops the `def` line (R3), and Ruby counts no other line. So these mutants stay `no_coverage` even when a test calls the method. The method's own call count (#209 style) could give a signal. File one new issue for both shapes; do not fix them here.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Retry on "no tests", not on "no lines".** In `coverage_selection`, compute the tests from the strict lines first. Retry only when that test list is empty. This is the root cause: the strict lines can be non-empty and still have no count. It also keeps R4: a strict selection with tests never reaches the retry.
- **KTD2. The loose mode keeps the edge lines; no new keyword.** `loose: true` already means "the lines of the statement, whose tests may not have run the position". An edge line that holds other code fits that meaning: Ruby can count it without the statement (an empty `users` list counts the `map` line and never runs the block). Its only caller is the retry in `coverage_selection`. So `loose: true` now also skips the first-line and last-line deletes at `statement_lines.rb:45-47` and removes the `def` line instead. The issue comment proposed a separate `edges:` keyword. That gives a second flag that is never set without the first, so this plan folds it into `loose:`. The alternative is under Open Questions.
- **KTD3. Keep `selection_verdict` unchanged.** `JobPlan.selection_verdict` (`job_plan.rb:217-221`) already turns a `:maybe` survivor into `no_coverage`. No new verdict and no new status.
- **KTD4. Leave `ran_at_load?` strict and keep its place in the order.** `job_plan.rb:255` calls `StatementLines.for` without `loose:`. Do not change it. `coverage_selection` checks `ran_at_load?` only when the retry also gives no tests, as today. So a load-time mutant with an edge-line test runs, and only its survivor is `ran_at_load` (R5). A kill is real evidence, so it counts. The alternative (check `ran_at_load?` before the retry) is under Open Questions. #286 also works in that method.

### High-Level Technical Design

The new order in `coverage_selection` (directional):

```text
tests  = tests on the mutant's own line
kind   = :run
if tests empty and subject:
    tests = tests on StatementLines.for(strict)
    if tests empty:
        tests = tests on StatementLines.for(loose: true)   # edge lines kept, def line removed
        kind  = :maybe
if tests empty:
    uncapturable, then ran_at_load, then no_coverage   # unchanged
```

`StatementLines.for` with `loose: true`, after the existing `sometimes?` and `modifier?` guards are skipped (unchanged):

```text
lines = statement start line .. last line (heredoc bodies included)
if loose: return lines without the def line
else: drop the first line if code comes before; drop the last line if code (not a comment) follows   # unchanged
```

### Behaviour change and contract

- **Verdicts.** Some mutants that are `no_coverage` today become `killed` when a test kills them. A survivor stays `no_coverage` (or `ran_at_load`, R5). No mutant becomes `survived` through this path. A mutant can now also end as `error` or `timeout`; that counts toward the `--threshold` completeness check, as for #254.
- **Score.** A score can rise with no test change, because new kills enter the denominator. `attempted` rises by the retried mutants that end `killed`, `error` or `timeout`. A retried survivor is `no_coverage` or `ran_at_load` and is not attempted.
- **Exit codes and JSON.** No new field and no schema change. `summary.no_coverage` and `summary.ran_at_load` can drop, and `summary.killed` can rise. A retried mutant that errors or times out counts toward the `--threshold` completeness check, so a CI gate that passes today can exit 1. That is the #254 rule; the failure is reported, not hidden.
- **Mutants that change.** Only a mutant whose strict lines give no tests and whose loose lines (edge lines kept) give tests. This covers the #289 shape, a #254 mutant whose statement shares its first line with other code (`return if p.nil?; g(p &&` then `qq)`), and a load-time mutant under R5.
- **Unplaceable corner.** Under `--strategy redefine`, a `:maybe` mutant whose owner cannot be named becomes `no_coverage` (`test_an_unplaceable_maybe_mutant_stays_no_coverage`). So a mutant that was `ran_at_load` and is now `:maybe` and unplaceable ends `no_coverage`. Both statuses are out of the score.

### Assumptions

- Ruby counts the block opener line for a one-line block whose body starts on that line. The coverage capture above confirms it (count 2 for one call: one for `map`, one for the block body).
- The `def` line has a count from load in the per-test coverage map. The issue comment saw `test_a_statement_on_the_def_line_of_a_method_no_test_calls_has_no_tests` fail until the `def` line was removed. That test is the guard for R3.

---

## Implementation Units

### U1. Retry on empty tests with the edge lines

**Goal:** a continuation-line mutant inside a one-line block gets `:maybe` tests (R1, R2, R3, R4, R6).

**Requirements:** R1, R2, R3, R4, R5, R6.

**Dependencies:** none.

**Files:**
- `lib/mutineer/statement_lines.rb`: `StatementLines.for` (line 25). Change the line selection at lines 43-48. Update the YARD text for `loose` (lines 15-19) and `@return` (lines 20-24).
- `lib/mutineer/job_plan.rb`: `JobPlan.coverage_selection` (lines 178-203). Change the fallback at lines 182-190. Update the method comment (lines 149-177) to say the retry runs when the strict lines give no tests, and that it keeps the edge lines except the `def` line.
- `test/statement_lines_test.rb`, `test/runner_test.rb`, `test/statement_coverage_test.rb`.
- `test/fixtures/continuation.rb`, `test/fixtures/continuation_test.rb`, `test/fixtures/continuation_weak_test.rb`.

**Approach:**
- In `StatementLines.for`, when `loose` is true, return the full span from the statement's start line to `last_line(statement)` without the `def` line (`def_node.location.start_line`). When `loose` is false, keep lines 45-47 as they are.
- In `coverage_selection`, map the strict lines to tests. When those tests are empty, call `StatementLines.for(..., loose: true)`, map those lines to tests, and set `kind = :maybe`. Keep the empty-selection branch (lines 191-200) as it is.
- Do not touch `ran_at_load?` (line 255) or `selection_verdict` (line 217).

**Patterns to follow:** the #254 change (PR #262): the `loose:` keyword, `test_the_right_side_of_a_multi_line_and_has_lines_only_when_asked`, and `test_a_maybe_mutant_is_killed_or_no_coverage`.

**Fixture:** add `Continuation.names(users)` to `test/fixtures/continuation.rb`, with the four-line body from the Problem Frame. Add `test_names` to `continuation_test.rb`: `assert_equal ["2 1"], Continuation.names([[1, 2]])`. Add `test_names_with_no_users` to `continuation_weak_test.rb`: `assert_equal [], Continuation.names([])`. That test runs the opener line and never runs the block, so it is the case `:maybe` exists for. Update the header comments of the fixture files.

**Test scenarios:** each one fails on `main` and passes with the fix, except where noted.

1. `test/statement_lines_test.rb`, `test_a_continuation_line_in_a_one_line_block_has_its_edge_lines_only_when_loose`. Source: `def f(users)` / `users.map { |u| format("%s %s",` / `u + 1,` / `u - 1) }` / `end`. Assert the strict lines for `u + 1` are `[3]`. Assert the loose lines are `[2, 3, 4]`. Add the lambda shape in the same test (`def f(r)` / `pick = ->(r) { format("%d %d",` / `r + 1,` / `r - 1) }` / `end`): strict `[3]` and loose `[2, 3, 4]` for `r + 1`. Call `Mutineer::StatementLines.for` directly with `loose: true`, as `test_the_right_side_of_a_multi_line_and_has_lines_only_when_asked` does; the `lines_at` helper takes no `loose:`. Fails on `main`: loose gives `[3]`.
2. `test/statement_lines_test.rb`, `test_the_loose_lines_never_include_the_def_line`. Source: `def f; [:a,` / `:b]; end`. Assert the strict lines for `:b` are empty and the loose lines are `[2]`. Fails on `main`: loose gives `[]`.
3. `test/runner_test.rb`, `test_coverage_selection_retries_with_the_edge_lines_as_maybe`. Use `selection` with `FakeCoverageMap` and the scenario 1 source. With tests on line 2 only, assert `selection(source, "u + 1", ...)` is `[:maybe, ["/root/t_test.rb"]]`. With tests on line 2 (`a_test.rb`) and line 3 (`t_test.rb`), assert `selection(source, "u - 1", ...)` is `:run` (R4: `u - 1` is on line 4, its strict line 3 has a test, and that hit wins over the edge line). Fails on `main`: the first case gives `:verdict`.
4. `test/statement_coverage_test.rb`, `test_a_continuation_line_in_a_one_line_block_runs_the_opener_tests_as_maybe`. Assert `selection_for("u[0] + 1")` is `:maybe`. Real coverage capture. Fails on `main`: `:verdict`.
5. `test/statement_coverage_test.rb`, `test_a_continuation_mutant_in_a_one_line_block_is_killed_or_no_coverage`. Mirror `test_a_maybe_mutant_is_killed_or_no_coverage` with `only: "Continuation.names"` and `operators: ["arithmetic"]`. With `continuation_test.rb`, assert `[killed, no_coverage] == [2, 0]`. With `continuation_weak_test.rb`, assert `[0, 2]`. Assert `survived == 0` for both. Fails on `main`: the strong run gives `[0, 2]`. The weak half passes on `main` too; it guards R2.
6. `test/runner_test.rb`, `test_coverage_selection_runs_a_load_time_mutant_with_an_edge_line_test_as_maybe` (R5). Source: `def f(xs)` / `x = 1; y = xs.map { |v|` / `v }.size + 1` / `end`. Mutant `+ 1` on line 3, tests on line 2, `load_lines: [3]`. Assert `[:maybe, ["/root/t_test.rb"]]`. Fails on `main`: gives `[:verdict, ran_at_load]`.
7. `test/runner_test.rb`, `test_coverage_selection_adds_the_shared_first_line_to_a_maybe_selection` (R4). Source: `def f(p, q)` / `return if p.nil?; g(p &&` / `qq)` / `end`. Mutant `qq`. With tests on line 2, assert `[:maybe, ["/root/t_test.rb"]]`. With no tests, assert the verdict is `no_coverage`. Fails on `main`: the first case gives `no_coverage`.

**Existing tests that must stay green unchanged:** `test_a_statement_on_the_def_line_of_a_method_no_test_calls_has_no_tests` (R3), `test_the_body_of_an_endless_method_has_no_tests` (it pins the deferred endless-method limit), `test_the_right_side_of_a_multi_line_and_has_lines_only_when_asked` (loose `[2, 3]` still holds), `test_coverage_selection_ignores_the_def_line_load_count`, `test_coverage_selection_gives_a_statement_that_did_not_run_no_tests` (R5), `test_a_maybe_mutant_is_killed_or_no_coverage`, and the exact-survivor oracle in `test/integration_test.rb`.

**Verification:** scenarios 1 to 7 fail on `main` as stated and pass on the branch. The full suite is green. A prototype of this unit on an export of `main` confirmed it: scenarios 1 to 5 failed on `main` and passed with the fix. Scenarios 6 and 7 gave the `main` result each one states on `main`, and the fix result on the prototype. The full suite (1414 runs) was green on the prototype with scenarios 1 to 5 and the fixture changes. The strong run went from 2 `no_coverage` to 2 `killed`, and the weak run stayed at 2 `no_coverage`.

### U2. CHANGELOG and docs

**Goal:** tell users that these mutants can now be killed.

**Requirements:** R2.

**Dependencies:** U1.

**Files:**
- `CHANGELOG.md`: add a `### Fixed` block under `## [Unreleased]` if none exists, then this entry:
  `- **A mutant on a later line of a call inside a one-line block can be killed (#289).** For a call split across lines, such as \`users.map { |u| format("%s",\` with arguments on the next lines, Mutineer used to pick no tests, so the mutant was always \`no_coverage\`. Now, when the lines of a mutant's statement give no tests, it runs the tests that ran the statement's first or last line, never the \`def\` line. A kill counts. A survivor stays \`no_coverage\` (or \`ran_at_load\`), because those tests may not have run it. A score can rise with no test change. Such a mutant can now also end as \`errored\` or \`timeout\`, which counts toward the \`--threshold\` completeness check.`
  Wrap the entry near 80 columns like its siblings.
- `docs/json-schema.md` line 58 (`no_coverage` row): add "or a later line of a call inside a one-line block, where the tests ran the line but may not have run the block" next to the `a &&` example.
- `lib/mutineer/result.rb` lines 10-13 (`no_coverage` comment): add the same case.

**Test expectation:** none. Text only. `rake yard:strict` covers the YARD text. The site checks cover `docs/json-schema.md`.

**Verification:** the CHANGELOG entry is under `## [Unreleased]`. No em dash in new text.

---

## Verification Contract

Prefix each command with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` in a shell where they are unset.

```sh
bundle exec ruby -Itest test/statement_lines_test.rb
bundle exec ruby -Itest test/statement_coverage_test.rb
bundle exec ruby -Itest test/runner_test.rb
bundle exec rake test
ruby -Ilib -e 'require "mutineer"'
bundle exec rake yard:strict
BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle exec rake test
```

`AGENTS.md` rules that apply:
- Zero runtime dependencies and no `eval`. The change uses Prism and stdlib only.
- 100% YARD docs. The changed `loose` parameter and `@return` text in `StatementLines.for` and the `coverage_selection` comment must stay complete for `rake yard:strict`.
- CHANGELOG entry under `## [Unreleased]`.
- Score model: `no_coverage` stays out of the denominator. The exact-survivor oracle stays green.
- `docs/json-schema.md` is a site page, so the `AGENTS.md` website checks apply: `bundle exec rake site:build`, `node --test test/site_test.js`, and the Playwright tests (`npm ci --prefix test/browser`, `npx --prefix test/browser playwright install chromium`, `npm test --prefix test/browser`).

## Definition of Done

- Scenarios 1 to 7 exist, failed on `main` as stated, and pass.
- The local gate and the website checks above are green, on Minitest 5 and Minitest 6.
- `ran_at_load?` and `selection_verdict` have no diff.
- CHANGELOG, `docs/json-schema.md` and the `Result` comment are updated.
- No prototype or debug code is left in the diff.
- A follow-up issue exists for the statements whose only counted line is the `def` line (both shapes in Deferred to Follow-Up Work), and the PR body names it.

---

## Risks and Overlaps

- **More `:maybe` selections than the issue names.** The retry now also runs for a strict selection with lines but no tests, and the loose lines now keep edge lines. A mutant that was `no_coverage` or `ran_at_load` can become `killed`, `error` or `timeout`. It can never become `survived`. That is the #254 rule, so the risk is low. Check `test/integration_test.rb` exact counts after the change.
- **The `def` line in a multi-line signature.** For `def f(a,` / `b) = g(a,` / `b + 1)`, the statement starts on line 2, so the retry has no `def` line to drop. Line 2 is the body's first line and counts when the method runs. No known false signal; the selection is `:maybe` anyway.
- **#286 (`ran_at_load` hides survivors).** Works in `JobPlan.ran_at_load?`, which also calls `StatementLines.for` at `job_plan.rb:255`. This plan does not touch that call. If #286 changes `ran_at_load?` to use `loose:`, it gets the edge lines too; that plan must decide whether it wants them.
- **#244 (flip the 2.0 contract)** and **#308 (temp-file sweeps)** change `lib/mutineer/job_plan.rb`, but not `coverage_selection`. Expect no code conflict.
- **CHANGELOG conflicts.** #304, #305, #306, #307, #308, #244 and #245 all edit `CHANGELOG.md` under `## [Unreleased]`. Rebase before merge and keep every entry.
- **#202 (split `coverage_map.rb`).** No overlap: this plan does not touch `CoverageMap`.
- **#301 (expectation-fit conventions)** and **#302 (merged, website onboarding).** No overlap.
- **Other fixture suites.** The wider retry can move exact counts in suites with multi-line statements whose first line holds other code (for example `test/load_time_test.rb`). The prototype run was green, but check any count change before you accept it.
- **Runtime.** A retried mutant whose edge line is hot (a guard such as `return if p.nil?;`) now runs every test on that line. Expect a small rise in run time on such code.
- **This plan file.** PR #193 removed `docs/plans/` from `main`, and `rake site:build` publishes every file under `docs/` except `GENERATED` and `UNPUBLISHED` (`rake/site_build.rb:30`). Keep this plan on its plan branch. Do not include it in the fix PR, or the plan becomes a public site page.

## Open Questions

- **Deferred. A separate `edges:` keyword.** KTD2 folds it into `loose: true`. If a reviewer wants the two meanings apart, add `edges:` and pass both at the retry. The behaviour is the same.
- **Deferred. `ran_at_load` before the retry.** KTD4 lets a load-time mutant with an edge-line test run, so a kill counts. The alternative checks `ran_at_load?` on the strict lines before the retry and keeps every `ran_at_load` verdict as today. Pick it only if #286 wants `ran_at_load` to stay stable; then scenario 6 asserts `[:verdict, ran_at_load]` instead.
- **Deferred. The heredoc sibling.** The issue says a split heredoc interpolation (`#{a` / `a}`) gets no countable line. The PR #188 review reply that states this limit did not give a Ruby version. On Ruby 3.4.9 and Ruby 4.0.9 (the two CI Rubies) both lines have a count. Ask the reporter for the exact source and Ruby version. If it reproduces, it needs its own issue.

## Sources

- Issue #289 and its `**Claude:**` comment (root cause, prototype result, scope and heredoc corrections).
- `lib/mutineer/statement_lines.rb:25-49`, `lib/mutineer/job_plan.rb:178-203`, `:217-221`, `:243-257`.
- PR #262 (#254): the `loose:` fallback and the `:maybe` verdict.
- PR #188 review replies: the first-line and last-line rule and the heredoc limit.
- Callers: `lib/mutineer/runner.rb:327` and `:352-353`, `lib/mutineer/daemon_backend.rb:377` and `:393-395`.
