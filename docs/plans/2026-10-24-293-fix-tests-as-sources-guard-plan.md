---
title: "Catch test_*.rb and root-level test files given as sources - Plan"
type: fix
date: 2026-10-24
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
origin: GitHub issue #293 (davidteren/mutineer) and its Claude analysis comment
---

# Catch test_*.rb and root-level test files given as sources - Plan

## Goal Capsule

- Issue: #293. The tests-as-sources guard in `mutineer run` misses Minitest `test_*.rb` files and test files in the project root.
- Goal: when `--test` is given, `mutineer run` exits 2 for a positional argument that is a test file by the pairing rules, also for `test_*.rb` names under `test/` or `spec/`, and for a `*_test.rb` or `*_spec.rb` file in the same directory as a `--test` file.
- Authority: this plan, then `AGENTS.md`, then the issue comment. Where they disagree, this plan wins (see "Corrections to the issue comment").
- Stop conditions: stop and ask if the fix needs a new runtime gem, `eval`, a new exit code, or a change to `Runner`. None is expected.
- Size: S. About 25 lines in `lib/mutineer/pairing.rb` (constant, method and YARD docs), a one-line change in `lib/mutineer/cli.rb`, a CHANGELOG entry, seven unit tests, and four CLI tests.

---

## Product Contract

### Summary

The guard is one regex at `lib/mutineer/cli.rb` line 210. It matches only `*_test.rb` and `*_spec.rb` under a `test/` or `spec/` directory. `Pairing.candidates` also pairs sources with `test_*.rb`, and many small projects keep tests in the root. A test file in either shape slips through. Mutineer then treats it as a source, mutates it, and never runs it as a test. The fix moves the check into a new `Pairing.test_given_as_source?` method beside `Pairing.candidates`, so the guard and the pairing names live in one file. The method adds the `test_*.rb` name under `test/` and `spec/`, and a same-directory rule for `*_test.rb` and `*_spec.rb` names.

### Problem Frame

- `lib/mutineer/cli.rb` `CLI.start`, lines 209 to 215 on `main`. Line 210 is `tests_as_sources = argv[1..].grep(%r{(\A|/)(test|spec)/.*_(test|spec)\.rb\z})`. Line 211 gates the exit on `config.explicit?(:tests)`. Lines 212 to 214 print the message and exit 2. The issue cites line 206; the guard is now at line 210.
- `lib/mutineer/pairing.rb` `Pairing.candidates`, lines 134 to 145. It pairs a source with `test/<base>_test.rb`, `test/<dir>/test_<name>.rb` (except `test_helper.rb`, line 137), and `spec/<base>_spec.rb`.
- `lib/mutineer/runner.rb` `Runner.execute`, line 97. With no boot file, the parent process does `require` on every source. A stray Minitest file runs its `require "minitest/autorun"` there, so a full Minitest run prints to stdout at exit.
- Reproduced on `main` (v1.7.0) for this plan:
  - `mutineer run calculator.rb --test test/test_a.rb test/test_b.rb` exits 0. `test/test_b.rb` is mutated as a source.
  - `mutineer run calculator.rb --test a_test.rb b_test.rb` (all files in the root) exits 0 the same way.
  - The same first command with `--format json` exits 0, and stdout is not valid JSON: the Minitest summary follows the report.

### Requirements

- R1. When one or more `--test` flags were given on the command line (the existing `config.explicit?(:tests)` gate; `.mutineer.yml` has no `tests` key), `mutineer run` exits 2 for each positional argument that `Pairing.test_given_as_source?` flags. The message stays the same: `mutineer: <paths> looks like a test file, not a source. --test takes one file; repeat it for each test file (--test a_test.rb --test b_test.rb)`.
- R2. A path has a test name when its basename ends with `_test.rb` or `_spec.rb`, or starts with `test_` and ends with `.rb`. `test_helper.rb` does not have a test name, to match `Pairing.candidates` line 137. A test name alone flags nothing; R3 decides.
- R3. A path with a test name is flagged when one of these is true:
  - It has a `test/` or `spec/` directory segment. This is the current rule, with the new names added.
  - Its basename ends with `_test.rb` or `_spec.rb` (a suffix name, not a `test_` prefix), and its directory, expanded against the project root, is the directory of a file in the test set. This covers root-level tests. The `test_` prefix is left out of this rule because ordinary sources use it (this repo has `lib/mutineer/test_runners.rb`).
- R4. A path is not flagged under R3's same-directory rule when the test set holds its own test by name in that directory: `<stem>_test.rb`, `test_<stem>.rb`, `<stem>_spec.rb`, or a split test `<stem>_*_test.rb` (the `Pairing.split_test_files` rule, #87). The stem is the argument's basename without `.rb`, so the stem of `ab_test.rb` is `ab_test`. This keeps a root-level source such as `ab_test.rb` valid next to its test `ab_test_test.rb` or `ab_test_strong_test.rb`.
- R5. These stay valid: `app/models/ab_test.rb` with `--test test/models/ab_test_test.rb` (the directories differ, and the path has no `test/` segment), and a single root-level `calculator.rb --test calculator_test.rb`.
- R6. `*_tests.rb` is not a test name. `Pairing` does not pair it.
- R7. CHANGELOG `## [Unreleased]` gets a `### Fixed` entry (text in U3).

### Acceptance Examples

- AE1. `run calculator.rb --test test/test_a.rb test/test_b.rb` exits 2. Stderr names `test/test_b.rb`.
- AE2. `run calculator.rb --test calculator_strong_test.rb calculator_weak_test.rb`, all in the root, exits 2. Stderr names `calculator_weak_test.rb`.
- AE3. AE2 with `--format json` exits 2 and prints nothing to stdout.
- AE4. `run --dry-run ab_test.rb --test ab_test_test.rb`, both in the root, exits 0.
- AE5. `run --dry-run app/models/ab_test.rb --test test/models/ab_test_test.rb` exits 0 (existing test).
- AE6. `run ab_test.rb --test other_test.rb`, both in the root, exits 2. This is a known limit (see Risks and Q3).
- AE7. The guard does not flag `lib/test_runners.rb` given with `--test lib/runner_test.rb`, because a `test_` prefix name outside `test/` and `spec/` is never flagged.

### Scope Boundaries

- No change to `Runner`, the JSON report schema, exit-code meanings, or `README.md`. `README.md` line 278 already says to repeat `--test`.
- No guard when `--test` is not given. Test inference then decides the test set, and this issue does not cover that path.
- The guard checks positional arguments as typed. A directory argument (for example `run test/ --test ...`) is not expanded first, as today.

### Deferred to Follow-Up Work

- Stdout pollution from any source that loads `minitest/autorun` in the parent process (for example a test file given as a source with no `--test`). With this fix, the issue's repro exits 2 before the run, so it no longer breaks JSON. The general case needs a new issue (see Open Questions, Q2).

---

## Planning Contract

### Key Technical Decisions

- KTD1. Put the rule in `Pairing.test_given_as_source?`, beside `Pairing.candidates`. Reason: the comment's root cause is that the guard and the pairing rules disagree. One file for both makes the next drift easier to see. It does not remove all copies: `lib/mutineer/coverage_map.rb` `failed_test_target_name` (line 303) also knows the `_test`, `_spec`, `test_` and `test_helper` names. Leave it as it is; it maps a test back to a source name, which is a different job. `Pairing` is pure path logic over the filesystem (module comment, lines 16 to 19), so the method fits there and gets plain unit tests.
- KTD1a. Name the method `test_given_as_source?`, not `test_file?`. Reason: it answers "does the guard reject this argument", which depends on the test set. A `b_test.rb` with an empty test set returns false, so `test_file?` would mislead.
- KTD2. Use the same-directory rule, not "equals a file in the resolved test set". Reason: the issue's first idea does not catch the repro, because `test/test_b.rb` is not in the `--test` set. The issue's second idea ("the framework would load it as a test") needs a framework-specific load model. The same-directory rule is path-only and catches both repros. A third option came up in review: flag a test-named argument that directly follows a `--test` value in the raw command line. It matches the message's diagnosis and has no AE6 false exit. It is not chosen as the default, because `OptionParser#parse!` reorders `argv` (the raw order must be copied first), and it misses `run a_test.rb b_test.rb calc.rb --test ...`. See Q6.
- KTD3. Add the R4 exemption for a source whose own test is given beside it. Reason: without it, a root-level source with a test-like name (`ab_test.rb` next to `ab_test_test.rb`) exits 2 with no workaround, because the guard checks every positional argument. The check is one name comparison.
- KTD4. Expand both the positional path and the test paths against `config.project_root` before comparing directories. Reason: `Pairing.expand_sources` (line 38) and `Runner` (lines 107 and 127) read both relative to the project root, so `./a_test.rb` and `a_test.rb` are the same directory.
- KTD5. Read the `test/` and `spec/` segments from the path relative to the project root, and, for a path outside the root, from the relative path as typed (an absolute path outside the root has no segments). Reason: a `test/` folder above the root must not flag a source. This changes one case the old regex caught: `test/../lib/foo_test.rb` normalizes to `lib/foo_test.rb` and is no longer flagged by the segment rule. That path names a non-test location, so the change is accepted.
- KTD6. Keep the `config.explicit?(:tests)` gate and the message text. Reason: the existing test `test_a_test_file_given_as_a_source_after_test_exits_two` asserts the message, and scripts may match it.

### High-Level Technical Design

Decision flow for one positional argument (directional sketch of `Pairing.test_given_as_source?`):

```text
test_given_as_source?(path, project_root:, tests:)
  name = basename(path)
  not a test name (R2)                         -> false
  path has a test/ or spec/ segment (R3a)      -> true
  dir = dirname(expand(path, root))
  tests (expanded) hold <stem>_test.rb, test_<stem>.rb,
    <stem>_spec.rb or <stem>_*_test.rb in dir (R4) -> false
  name has a suffix (_test.rb, _spec.rb) and
    any test (expanded) has dirname == dir (R3b) -> true
  otherwise                                    -> false
```

The CLI keeps its shape: line 210 selects the positional arguments for which `Pairing.test_given_as_source?` is true, then lines 211 to 214 run unchanged.

### Contract change

- More invocations exit 2 (usage error) that exited 0 before. Each of them was a mistake that silently dropped a test file from the run. No new exit code, no JSON field change.

---

## Implementation Units

### U1. `Pairing.test_given_as_source?`

**Goal:** One method that says whether the guard rejects a positional argument as a test file given as a source, by the pairing naming rules.

**Requirements:** R2, R3, R4, R5, R6.

**Dependencies:** none.

**Files:**
- Modify `lib/mutineer/pairing.rb`: add `test_given_as_source?` after `candidates` (after line 145). Update the module comment: line 7 says "Two jobs:". Make it "Three jobs:" and add a `test_given_as_source?` bullet in the same style as the `expand_sources` and `infer_tests` bullets.
- Test `test/pairing_test.rb`.

**Approach:** Follow the HTD sketch. Keyword arguments `project_root:` and `tests:` match `expand_sources` and `infer_tests`. Put the R2 name rule in one constant with its own comment (`yard:strict` needs it). The method reads no files, so it works for paths that do not exist yet. The YARD docstring says why the segment check uses the path as typed (KTD5) and the directory check uses expanded paths (KTD4), so a later reader does not merge the two.

**Patterns to follow:** `Pairing.candidates` (the `helper` exclusion on line 137), `Pairing.expand_sources` (expansion against the root), YARD tags as on `candidates` (`@param`, `@return`).

**Test scenarios** (each fails before the fix with `NoMethodError`):
- `test_given_as_source_flags_suffix_and_prefix_names_under_test_dirs`: `test/a_test.rb`, `test/test_a.rb`, `spec/a_spec.rb`, and `test/models/test_user.rb` are true with an empty test set.
- `test_given_as_source_skips_test_helper_and_non_test_names`: `test/test_helper.rb`, `test/a_tests.rb`, and `lib/calc.rb` are false.
- `test_given_as_source_flags_a_root_level_test_beside_a_given_test`: `b_test.rb` with tests `["a_test.rb"]` is true. `./b_test.rb` with the same tests is true.
- `test_given_as_source_keeps_a_test_prefixed_source_beside_a_test`: `lib/test_runners.rb` with tests `["lib/runner_test.rb"]` is false, and root-level `test_b.rb` with tests `["test_a.rb"]` is false (R3b covers suffix names only). Covers AE7.
- `test_given_as_source_keeps_a_source_whose_own_test_is_given`: `ab_test.rb` is false with tests `["ab_test_test.rb"]`, with `["test_ab_test.rb"]`, and with `["ab_test_strong_test.rb"]`.
- `test_given_as_source_flags_a_test_named_source_beside_another_test`: `ab_test.rb` with tests `["other_test.rb"]` is true. This pins the known limit (AE6).
- `test_given_as_source_keeps_a_test_named_source_outside_test_dirs`: `app/models/ab_test.rb` with tests `["test/models/ab_test_test.rb"]` is false.

**Verification:** the seven tests pass; `rake yard:strict` reports 100%.

### U2. Use the method in the CLI guard

**Goal:** `mutineer run` exits 2 for the new cases.

**Requirements:** R1, R3, R4, R5. Covers AE1 to AE5.

**Dependencies:** U1.

**Files:**
- Modify `lib/mutineer/cli.rb` line 210: select from `argv[1..]` with `Pairing.test_given_as_source?(arg, project_root: config.project_root, tests: config.tests)`. Lines 211 to 214 stay as they are. Update the guard's comment if one is added.
- Test `test/cli_test.rb`, beside `test_a_test_file_given_as_a_source_after_test_exits_two` (line 203).

**Test scenarios:**
- `test_a_test_prefixed_file_given_as_a_source_after_test_exits_two`: copy the calculator fixtures to `test/test_a.rb` and `test/test_b.rb` (fix their `require_relative`, or use empty files with `--dry-run`). Run AE1. Assert exit 2 and that stderr includes `test/test_b.rb looks like a test file, not a source`. Covers AE1. Fails before: exit 0.
- `test_a_root_level_test_file_given_as_a_source_after_test_exits_two`: `with_project`, run `calculator.rb --test calculator_strong_test.rb calculator_weak_test.rb`. Assert exit 2 and stderr names `calculator_weak_test.rb`. Covers AE2. Fails before: exit 0.
- `test_a_stray_test_file_with_json_format_exits_two_before_any_output`: `with_project`, the AE2 command with `--format json`. Assert exit 2 and empty stdout. Covers AE3. Fails before: exit 0 and stdout holds the Minitest summary.
- `test_a_root_level_source_named_like_a_test_still_runs`: temp dir with `ab_test.rb` (`class AbTest; def n = 1 + 1; end`) and an empty `ab_test_test.rb`. Run `--dry-run ab_test.rb --test ab_test_test.rb`. Assert exit 0 and stdout includes `AbTest#n`. Covers AE4. This passes before and after; it guards R4.
- Keep `test_a_source_named_like_a_test_outside_test_dirs_still_runs` (line 217) green. Covers AE5.

**Verification:** the four new tests pass; the two existing guard tests pass unchanged.

### U3. CHANGELOG

**Goal:** Record the fix.

**Requirements:** R7.

**Dependencies:** U2.

**Files:** `CHANGELOG.md`, under `## [Unreleased]` (line 7). Add `### Fixed` if no such heading exists there yet.

**Approach:** Suggested text:

```text
- **A test file given as a source after `--test` now exits 2 in more layouts
  (#293).** The check missed Minitest `test_*.rb` files and test files in the
  same directory as a `--test` file, such as the project root. Mutineer then
  mutated that file as a source and never ran it as a test. With
  `--format json`, the stray file's Minitest output also made the report
  invalid JSON.
```

This follows the style of the existing `### Fixed` entries (for example `CHANGELOG.md` line 135): a bold first sentence, then the detail.

**Test expectation:** none (documentation).

---

## Verification Contract

Run from the repo root. Prefix each command with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` in a shell where the locale is unset.

- `bundle exec rake test` (zero-dependency suite; U1 and U2 tests).
- `ruby -Ilib -e 'require "mutineer"'` (load smoke).
- `bundle exec rake yard:strict` (100% documentation, private methods and constants included).
- The Minitest 6 run is not required: this change does not touch the Minitest integration.
- No site checks: no file under `docs/` that the site builds changes. The plan file is not part of the site build.
- AGENTS.md rules: no runtime gem, no `eval`, match the surrounding idiom, CHANGELOG under Unreleased.
- Manual check: the three repro commands in "Problem Frame" exit 2, and AE4 exits 0.

A prototype of U1 and U2 was run against `main` while writing this plan, then removed. The full suite passed (1409 runs, 0 failures), and the repros gave the expected exits.

## Definition of Done

- U1 to U3 are done, and each new test failed before its unit's change (except the R4 guard test, which passes before and after).
- All Verification Contract commands pass.
- The fix diff touches only `lib/mutineer/pairing.rb`, `lib/mutineer/cli.rb`, `test/pairing_test.rb`, `test/cli_test.rb`, and `CHANGELOG.md`. This plan file lives on its own branch (`plan/293-tests-as-sources-guard`). The fix branch does not need to carry it.

---

## Risks and Overlaps

- Risk: a user script that passes extra test files as positionals now gets exit 2. That is the intended fix. The message tells the user what to do.
- Risk: a root-level source with a test-like name, next to another test but not its own. Example: `run ab_test.rb --test other_test.rb`, both in the root. It is flagged (AE6), and the message tells the user to repeat `--test`, which does not help. There is no override. This layout is rare. The unit test pins the behaviour so a change is a choice. See Q3.
- Risk: a root-level Minitest file named `test_b.rb` (not under `test/`) is not caught, because R3b leaves out the `test_` prefix. Minitest puts `test_*.rb` files under `test/`, so this is accepted to keep `test_*.rb` sources valid.
- Risk: under a `test/` or `spec/` segment, a support file with a `test_` prefix (for example `spec/support/test_helpers.rb`) is now flagged when given as a source. Only `test_helper.rb` is exempt. No user is known to mutate such a file.
- Risk: KTD4 uses plain `File.expand_path`. `Pairing.expand_sources` also tries the root's real path (macOS `/var` and `/private/var`). A source typed as an absolute path through the other alias can miss the same-directory rule. That is a missed catch, not a false exit 2.
- PR #307 (output path checks for the cache dir and baseline, #270 and #281) edits `lib/mutineer/cli.rb` and `test/cli_test.rb`. It adds a `require` at the top of `cli.rb` (the guard moves to line 211), and edits `validate!` and `preflight_baseline!`. Its tests go near `test/cli_test.rb` lines 288 and 1083, not near lines 203 to 228. Expect no code conflict. Both add a CHANGELOG `### Fixed` entry under Unreleased, so expect a small text conflict there. Rebase on whichever merges first.
- PR #244 (2.0 contract) and PR #245 (daemon default) edit `cli.rb` and `cli_test.rb` but not the guard lines or `pairing.rb`. Line numbers may shift.
- PR #301 adds the review rule "a guard's test list mirrors the pairing rules it protects". This fix applies that rule. The new unit tests list the pairing names.
- PRs #304, #305, #306, #308, #202: no shared files apart from `CHANGELOG.md`. #302 is merged.
- No other open issue or PR touches `lib/mutineer/pairing.rb` or `test/pairing_test.rb`.

## Open Questions

All are deferred. None blocks implementation.

- Q1. Should `*_tests.rb` count as a test name? Default: no, because `Pairing` does not pair it (R6). Alternative: add it to R2.
- Q2. Should a source that loads `minitest/autorun` in the parent process be caught in general (for example `run test/test_b.rb` with no `--test`)? Default: out of scope. No issue tracks it yet. The person who opens the fix PR files one for stdout pollution in `--format json` from such a source, and cites it in the PR.
- Q3. Keep the R4 exemption, and accept AE6? Default: yes to both. Alternatives: drop R4 and accept exit 2 for a root-level `*_test.rb` source next to its own test; or give the same-directory rule its own message that names the `--test` file it shares a directory with.
- Q4. Should the guard check expanded sources (after `Pairing.expand_sources`), so a directory argument such as `test/` is caught? Default: no, the guard checks arguments as typed, as today.
- Q5. The message says "looks like" also for two or more paths. Default: keep the text (KTD6). Alternative: use the plural for two or more paths. Tests come only from `--test` flags, because `.mutineer.yml` has no `tests` key.
- Q6. Use the raw-argument-order rule (a test-named argument directly after a `--test` value) instead of, or with, R3b? Default: no (KTD2). Choose it if AE6 false exits are reported.
- Q7. Add an escape hatch for a real source with a test name that the guard flags (for example a flag, or a `.mutineer.yml` setting)? Default: no, until a user reports the case.

## Corrections to the issue comment

- The comment's step 2 flags any test-named file in the same directory as a `--test` file. That flags a root-level source `ab_test.rb` next to its test `ab_test_test.rb`. This plan adds R4 to keep that case valid. The step also applies the same-directory rule to `test_*.rb` names, which flags ordinary sources such as `lib/test_runners.rb` next to a test. This plan limits that rule to suffix names (R3).
- The comment's name rule `test_*.rb` matches `test_helper.rb`. `Pairing.candidates` excludes it (line 137). This plan excludes it too (R2).
- All file and line references in the comment are correct on `main`: `cli.rb:210`, `pairing.rb:134`, `runner.rb:97`, `cli_test.rb:203` and `:217`. The repros and the JSON finding reproduce as described (exit 0, invalid JSON).

## Sources

- Issue #293 and its Claude comment.
- `lib/mutineer/cli.rb`, `lib/mutineer/pairing.rb`, `lib/mutineer/runner.rb`, `test/cli_test.rb`, `test/pairing_test.rb`, `AGENTS.md` on `main` at `18ef483`.
- PR diffs: #307, #244, #245 (file lists and guard lines).
