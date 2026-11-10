---
title: Let --test take a directory or a glob - Plan
type: feat
date: 2026-11-10
issues: [380]
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Let --test take a directory or a glob - Plan

## Goal Capsule

- **What:** let `--test` accept a file, directory or quoted glob. Support directories in the Action `test` input.
- **Why:** users can select tests with fewer flags.
- **How:** expand each value once in the CLI before backend use (KTD1, CLI expansion). Keep the Action loop (KTD7).
- **Issue:** #380 (let `--test` take a directory or a glob).
- **Authority:** this plan, then `AGENTS.md` and `STABILITY.md`, then the issue. This plan controls differences; see "Corrections to the issue".
- **Stop and ask when:** a change affects scores, mutant ids, the JSON schema, Action defaults or currently working values. U3 (Action expansion changes) is excluded. Do not start it before David answers Q1 (the Action glob decision).
- **Size and delivery:** S (small). One pull request with `Closes #380`. About 14 files: 2 under `lib/`, 3 under `test/`, `action.yml` descriptions and 8 docs files. No new runtime dependency.
- **Release:** labels `enhancement`, `priority: medium` (medium priority), `risk: low` (low risk) and `v1.9.0` (target release). This is a minor change: the flag accepts more values, and Action behaviour stays unchanged. A maintainer merges. This plan has no release step.

---

## Product Contract

### Summary

`mutineer run` expands `--test` before validation. Directories supply test files; quoted globs supply matching files. Existing files stay as typed. Blank values and empty selections exit 2.

The Action loop stays unchanged. Bash expands globs in `test`; directories reach the CLI unchanged. Document both behaviours.

### Problem Frame

`--test` takes one file per flag (`lib/mutineer/cli.rb:154`). Vladimir's Fizzy report lists this under "Missing parts".

His coverage-guided run over `app/models` and `app/controllers` used every non-system test ("Full-scope coverage-guided run"). The Fizzy clone needs 261 flags (probe 3). Model and controller tests alone total 215 files: 108 plus 107.

Other values behave as follows on `main` commit `8d9905c4` (probes 1 and 4).

| `--test` value | Result today |
|---|---|
| Directory, in-process run | Exit 2: raw `Is a directory @ io_fread - <absolute path>` |
| Directory with `--dry-run` | Exit 0; accepted but unused |
| Directory with `--test-command` | Works; the command receives the directory |
| Quoted glob | Exit 2: `no such file: test/*_test.rb` |
| Unquoted glob that matches two or more files | Shell expansion causes exit 2: `--test takes one file`. One match works |
| Blank value (`--test ""`) | Becomes the project root. Exit 0 with `--dry-run`; exit 2 otherwise |
| Directory of specs with `--rails --daemon` | The daemon's RSpec check does not fire |

### Requirements

**Expansion**

- R1. A directory selects matching test files recursively: `*_test.rb`, `*_spec.rb` or `test_*.rb`, except `test_helper.rb`.
- R2. A value containing `*`, `?`, `[` or `{` is a glob unless the path exists. Match files from the project root, without a name filter. Ignore matched directories.
- R3. An existing file stays as typed, including names with glob characters.
- R4. Sort each value's results by path. Keep flag order and remove duplicate files. Use root-relative expanded paths inside the project.
- R5. Detect the framework from the expanded list unless the user set `--framework` or `framework:`.

**Errors and notes**

- R6. Blank values and directories or globs with no test files exit 2. Name the value in the message.
- R7. Missing paths without glob characters retain the `no such file` message and exit 2.
- R8. For each expanded directory or glob, stderr shows one line with its test file count.
- R9. A positional argument that looks like a test file gets three fixes: quote the glob, pass a directory, repeat `--test`.

**Surfaces**

- R10. Expansion and errors are identical in normal runs, `--dry-run`, and the in-process and daemon backends.
- R11. With `--test-command`, pass directories as typed, as today. Expand globs under R2.
- R12. Keep the Action `test` loop unchanged (KTD7). Directories reach the CLI unchanged. Bash expands globs; `**` matches one level. State this in `action.yml` and `docs/ci.md`, including the directory requirement: mutineer 1.9.0 or later.
- R13. Describe all three forms in help, user docs, `STABILITY.md` and `CHANGELOG.md`.
- R14. Keep scores, mutant ids, the JSON schema, `schema_version`, config keys, Action inputs and defaults unchanged.

### Acceptance Examples

Acceptance examples AE1 to AE3 and AE6 use `test/fixtures/autopair`: `lib/calc.rb`, `lib/greeter.rb`, `test/calc_test.rb` and `test/greeter_test.rb`.

- AE1. Covers R1, R4, R8. `mutineer run lib --test test --format json` uses `test/calc_test.rb` and `test/greeter_test.rb`. Stderr contains `[mutineer] --test test: 2 test files`. JSON `summary` equals the run that lists both files.
- AE2. Covers R2. `mutineer run lib/calc.rb --test 'test/*_test.rb'` uses the same two files.
- AE3. Covers R3, R4. `--test ./test/calc_test.rb --test test` gives `./test/calc_test.rb`, then `test/greeter_test.rb`.
- AE4. Covers R1, R5. A project contains `spec/calc_spec.rb`, `spec/nested/greeter_spec.rb` and `spec/spec_helper.rb`. `--test spec` selects the two specs and detects `rspec`.
- AE5. Covers R6, R10. `--test 'nowhere/*_test.rb'`, `--test <empty directory>` and `--test ""` each exit 2 and name the value. `--dry-run` behaves identically. Stdout is empty.
- AE6. Covers R9. `mutineer run lib/calc.rb --test test/calc_test.rb test/greeter_test.rb` exits 2. Stderr contains `test/greeter_test.rb looks like a test file, not a source` and `Quote the glob`.
- AE7. Covers R11. `--test test --test-command "ruby record.rb %{files}"` passes the directory path, not expanded files.
- AE8. Covers R12. Action input `test: "test/**/*_test.rb test/models"` gives the CLI `--test test/models/x_test.rb --test test/models`, as today. Bash expands the first word one level. With mutineer 1.9.0 or later, the CLI expands `test/models`.
- AE9. Covers R5, R10. `--rails --daemon --test spec`, where `spec` contains specs, exits 2 with `--daemon supports only --framework minitest`.
- AE10. Covers R1, R2. A project contains `test/models/a_test.rb`, `test/system/b_test.rb` and `test/routes_test.rb`. `--test test` selects all three, including the system test. `--test 'test/models/**/*_test.rb' --test test/routes_test.rb` selects the two non-system files. In Fizzy, `--test test` selects 265 files, including 4 under `test/system/`. `--test 'test/{channels,controllers,helpers,integration,jobs,lib,mailers,middleware,models}/**/*_test.rb' --test test/routes_test.rb` selects Vladimir's 261 files (review probe R1).

### Scope Boundaries

- No `test:` or `tests:` key in `.mutineer.yml`; neither exists. See "Corrections to the issue". #382 (the `tests:` map) owns `tests:`.
- Explicit `--test` still replaces convention pairing for every source (`lib/mutineer/cli.rb:629-642`). #382 covers tests added to individual sources.
- The Ruby API, `Mutineer::Config.new` and `Runner.execute`, still takes file paths. Expansion belongs to the CLI.
- No JSON key for expanded files or counts.
- No coverage cache or clean check changes. #398 (full clean checks on coverage cache hits) owns that cost.

Considered and not built:

- Exclusions for `fixtures/`, `dummy/` or `system/`, or an exclude flag. Globs select precisely; R8 reports counts. See Q3 (directory exclusions).
- Globs in positional sources. The issue does not request them. See Q4 (source globs).
- Framework-specific directory rules. One rule preserves current mixed-file behaviour (`lib/mutineer/config.rb:294-298`). Revisit after reports about mixed directories.
- Expanded file lists under `--verbose`. R8 counts provide the smallest selection check.

### Corrections to the issue

- **"Apply this to `test:` in `.mutineer.yml`, if present."** Neither key exists. `KNOWN_KEYS` (`lib/mutineer/config.rb:111`) derives from `CONFIG_OPTIONS` (`lib/mutineer/config.rb:43-74`), which has no tests row. Probe 1 reports `unknown config key "test"` and `unknown config key "tests"`. `docs/cli.md:47` directs users to `--test`. No config changes are needed.
- **"It accepts one file."** Incomplete: directories work with `--test-command` (probe 4) and exit 0 with `--dry-run` (probe 1). In-process runs expose raw `Errno::EISDIR` through `lib/mutineer/cli.rb:366-370`, not a designed usage message.
- **The directory rule `**/*_test.rb`, plus `**/*_spec.rb` for RSpec.** This omits `test_*.rb`, already recognised by pairing (`lib/mutineer/pairing.rb:141-143`, `:150-152`). Bundler 2.7.2 uses `test_newgem.rb.tt` in its Minitest template. Use `Pairing::TEST_NAME` (KTD3, the shared name rule).
- **"A directory argument prevents this error."** Partly: several flags in one argument cause exit 2 with `invalid option` (probe 1). Zsh does not split an unquoted variable (probe 2). Directories remove the list, without changing option parsing.
- **Not in the issue: the unquoted glob.** Shell expansion turns `--test test/*_test.rb` into one flag value and positional arguments. The guard catches these (`lib/mutineer/cli.rb:216-223`), but `--test takes one file` becomes incorrect (R9).
- **Not in the issue: the Action.** Unquoted `for t in $TESTS` (`action.yml:380`) already expands globs. With globstar off, `test/**/*_test.rb` silently selects one directory level (probe 2). Changing a working selection is excluded here (R12, KTD7, Q1).
- **Not in the issue: framework detection.** `Config.resolve` reads raw values (`lib/mutineer/config.rb:267`). It treats `spec` as Minitest, bypassing the daemon's RSpec check (probe 4). Expand first (R5).
- **Not in the issue: the blank value.** `--test ""` becomes the project root (probes 4 and 5). Directory expansion would select every test. Reject this unset-variable case (R6), as `cache_dir` and `since` already do (`lib/mutineer/config.rb:372-374`, `:379-385`).
- **"Follow `Pairing.expand_sources`, which already accepts directories."** It accepts directories (`lib/mutineer/pairing.rb:42-43`), but not globs (`lib/mutineer/pairing.rb:44-46`). Glob support needs new code.
- **"Implementation and tests were not checked."** This plan checked both. See "Sources and probes".

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Expand in `CLI.start`'s `run` branch, before the tests-as-sources guard.** Call `CLI.expand_tests!` when `config.explicit?(:tests)` is true, at `lib/mutineer/cli.rb:214-227`. All backends read `config.tests` (`lib/mutineer/runner.rb:144`, `:150`, `:164`, `:170`, `:241`; `lib/mutineer/daemon_backend.rb:57`). The guard reads this list (`lib/mutineer/cli.rb:216-218`); `validate_daemon!` reads the framework (`lib/mutineer/cli.rb:434`, `:500-504`). Reject option-handler expansion (`lib/mutineer/cli.rb:154`): it would affect `migrate` and `mutineer config`. #395 adds that command for Action cache_dir and baseline queries. Reject `Config.resolve`: `lib/mutineer/config.rb` currently does no path work and belongs to self-dogfood (`.github/workflows/ci.yml:216-235`).
- KTD2. **Use one pure function per value: `Pairing.expand_test`.** Return paths; `[]` means no matches. The CLI owns messages and exits, including per-value errors and counts (R6, R8). #382 (the `tests:` map) reuses it per mapped pattern (its KTD4). Reject an `expand_sources` mode: that function takes all `.rb` files, ignores globs and rewrites file paths.
- KTD3. **Select directory files with `Pairing::TEST_NAME`** (`lib/mutineer/pairing.rb:152`). Keep one test-name definition. `Minitest::TestTask` also defaults to `test/**/test_*.rb` and `test/**/*_test.rb` (minitest 5.27.0, `lib/minitest/test_task.rb:142-143`). The rule also selects support files with a `test_` name, such as `test/support/test_helpers.rb` (review probe R1). Reject the issue's two suffixes: they silently omit `test_*.rb`. In Fizzy, this rule selects the same 265 files as `*_test.rb` (probe 3). Here it selects 201 files under `test/`, including 107 fixtures (probe 3). R8 exposes the count.
- KTD4. **Pass directories unchanged with `--test-command`.** This already works (probe 4). `STABILITY.md:14` preserves flag meanings in minor releases. External commands apply their own selection rules; Mutineer builds no coverage map (`lib/mutineer/runner.rb:232-234`). Reject universal expansion: it changes command arguments (`lib/mutineer/external_backend.rb:84-92`). See Q2 (external-command directories).
- KTD5. **Existing paths take precedence over glob syntax.** Check directory, existing file, glob, then unchanged value. This preserves working files (R3) and missing-path errors (R7).
- KTD6. **Remove duplicates by absolute path; keep the first spelling.** R3 preserves typed files. Combining `./test/a_test.rb` with `test` must not run the file twice (probe 5).
- KTD7. **Keep the Action loop. Reserve `set -f` for a "yes" to Q1.** Reviewers agreed; the earlier draft differed. Today, `test: "test/**/*.rb"` selects bash's one-level `test/*/*.rb`. With `set -f`, the CLI would select every depth, including `test/test_helper.rb` and `test/fixtures/**`. This changes a working input. `version` defaults to the latest gem (`action.yml:110-113`, `:135-139`), affecting every unpinned `@v1` user without opt-in. `STABILITY.md:19` preserves input meanings; `AGENTS.md:160-161` requires a major bump for Action behaviour changes. Directories already reach the CLI unchanged, so only descriptions and docs change here. Bash also expands `--test` patterns in `extra-args` (`action.yml:394`, review probe R2); document both together. For U3 after approval, detect glob characters and read the gem version. For 1.9.0 or later, bracket the loop at `action.yml:380` with `set -f` and `set +f`. Reject this in a minor release. Reject `set -f` without version checks: older gems receive the pattern and exit 2. Reject `shopt -s globstar`: it widens selections and is unavailable in macOS `/bin/bash` 3.2.57. See Q1.
- KTD8. **Print one stderr count per expanded value.** Directory selection is name-based; no other output shows it. Stderr preserves JSON and HTML reports. Reject silence and `--verbose`-only output.
- KTD9. **Ignore directories matched by globs.** #380 R2 and #382 R4 both select files only (#382 plan, R4 (Pattern expansion)). Thus `--test 'test/mod*'` and `tests: test/mod*` agree. Use `Dir.glob` with a file check. Reject recursive expansion of matched directories: it combines rules and makes `test/*` select tests at every depth.

### High-Level Technical Design

This sketch defines order and decisions, not implementation.

```text
Pairing.expand_test(value, project_root:)    returns paths; [] means "matched nothing"
  a directory                  -> files under it with a test name, sorted (R1)
  an existing file             -> [value], as typed (R3)
  has * ? [ or {               -> the files it matches from the project root, sorted (R2)
  any other value              -> [value], and validate_paths! reports it (R7)

CLI.expand_tests!(config)                    run branch only, only when --test was typed
  a blank value                -> usage error, exit 2 (R6)
  a directory + --test-command -> the value as typed (R11)
  any other value              -> Pairing.expand_test
  a value that gave []         -> usage error, exit 2, names each value (R6)
  each expanded value          -> one count line on stderr (R8)
  config.tests                 -> all results in flag order, one entry for each absolute path (R4)
  config.framework             -> detected again from config.tests, unless the user set it (R5)
```

### Message text

Tests pin the quoted text.

- Blank value: `mutineer: --test must name a file, a directory or a glob, not blank (got: "")`
- No match: `mutineer: --test test/empty matched no test files`. For directories, add: `A directory gives the files under it named *_test.rb, *_spec.rb or test_*.rb.`
- Count: `[mutineer] --test test/models: 108 test files`. Use `1 test file` for one.
- Guard (replaces `lib/mutineer/cli.rb:220-221`): `mutineer: <paths> looks like a test file, not a source. A shell expands an unquoted glob into many files. Quote the glob (--test 'test/**/*_test.rb'), pass the directory (--test test), or repeat --test for each file`
- Help (replaces `lib/mutineer/cli.rb:53-55`): use `--test PATH`. Name files, directories and quoted globs. State that the flag repeats.

### Assumptions

These defaults lack user confirmation. David can change them.

- Print counts on every run that expands values (R8, KTD8).
- Select directory files by name, without exclusions (KTD3, Q3).
- Preserve directories with `--test-command` (KTD4, Q2).
- Keep the Action loop pending Q1 (KTD7).
- Ship in 1.9.0, matching `v1.9.0`, the docs and `action.yml`.

---

## Implementation Units

### U1. `Pairing.expand_test`

- **Goal:** convert one `--test` value to test paths with a pure function.
- **Requirements:** R1, R2, R3, R7; R4 sorting and root-relative paths.
- **Dependencies:** none.
- **Files:** modify `lib/mutineer/pairing.rb` and `test/pairing_test.rb`.
- **Approach:**
  1. Add `expand_test` beside `expand_sources` (`lib/mutineer/pairing.rb:35-49`). Use KTD5's check order.
  2. Reuse `existing_relative` (`lib/mutineer/pairing.rb:59-62`) and `ProjectPath.root_real` for root-relative paths through `./`, absolute paths and symlinked roots. Apply this to each match: `Dir.glob` preserves `./` (probe 5).
  3. Use `Dir.glob` with project-root `base:`. Absolute patterns ignore `base:` (probe 2).
  4. Update the module comment (`lib/mutineer/pairing.rb:6-22`), which currently lists three jobs.
  5. Add YARD comments for new methods and constants.
- **Patterns to follow:** `expand_sources`, its tests (`test/pairing_test.rb:100-170`) and `with_tree` (`test/pairing_test.rb:12-21`).
- **Test scenarios:** use `test/a_test.rb`, `test/models/b_test.rb`, `test/models/deep/c_test.rb`, `test/test_d.rb`, `test/test_helper.rb`, `test/support/helper.rb`, `test/.hidden/e_test.rb`, `spec/x_spec.rb` and `spec/spec_helper.rb`.
  - AE1: `test` gives `test/a_test.rb`, `test/models/b_test.rb`, `test/models/deep/c_test.rb`, then `test/test_d.rb`. Exclude `test_helper.rb`, `support/helper.rb` and `.hidden` contents.
  - AE10: separately add `test/system/s_test.rb` and `test/support/test_helpers.rb`. `test` includes both system tests and `test_` support files. `test/models/**/*_test.rb` includes neither.
  - AE4: `spec` gives only `spec/x_spec.rb`.
  - AE2: `test/**/*_test.rb` gives three `_test.rb` files, excluding `test/test_d.rb`.
  - `{test,spec}/**/*_{test,spec}.rb` gives four sorted files.
  - `test/*.rb` gives `test/a_test.rb`, `test/test_d.rb` and `test/test_helper.rb`, without a name filter.
  - `test/mod*` matches only directory `test/models`, returning `[]`.
  - `./test/a_test.rb` returns `["./test/a_test.rb"]`. Existing file `test/[x]_test.rb` returns itself.
  - `./test/*_test.rb` and the absolute path of `test` return root-relative paths.
  - Missing plain path `test/nope_test.rb` returns itself.
  - `test/**/*_nomatch.rb` and directory `test/support` each return `[]`.
  - An outside-root directory returns absolute paths.
- **Verification:** new tests fail before and pass after implementation. Existing `expand_sources` tests pass unchanged.

### U2. Expand in the CLI, with the errors, the count line and the new guard text

- **Goal:** expand each `--test` value through `Pairing.expand_test`; report invalid values as usage errors.
- **Requirements:** R4, R5, R6, R8, R9, R10, R11; R13 help text.
- **Dependencies:** U1.
- **Files:** modify `lib/mutineer/cli.rb`, `test/cli_test.rb` and `test/cli_daemon_test.rb`.
- **Approach:**
  1. Add private-API class method `CLI.expand_tests!(config)`, like `autopair!` (`lib/mutineer/cli.rb:641`). Follow the sketch, including KTD4 and KTD6.
  2. Call it first in `when "run"` when `config.explicit?(:tests)` is true (KTD1).
  3. Detect the framework again with `autopair!`'s line (`lib/mutineer/cli.rb:653`).
  4. Apply "Message text" to the guard and help. Change the option to `--test PATH` (`lib/mutineer/cli.rb:154`).
  5. Leave `lib/mutineer/config.rb` unchanged.
- **Patterns to follow:** `autopair!` for config changes and exit 2 (`lib/mutineer/cli.rb:641-660`); `config_resolved_by_cli` for config inspection (`test/cli_test.rb:1437-1448`). Reuse project helpers `with_autopair_project` and `rspec_project` (`test/cli_test.rb:1314-1319`, `:1472-1485`).
- **Test scenarios:**
  - Fixture note: the #379 plan (pair concerns with namespace tests) adds `test/models/storage/totaled_test.rb` to `test/fixtures/autopair`. For AE1 to AE3, delete `test/models` from the temp copy. The expected lists then stay `test/calc_test.rb` and `test/greeter_test.rb` in either merge order.
  - AE1: through `config_resolved_by_cli`, `run lib --test test` gives `config.tests == ["test/calc_test.rb", "test/greeter_test.rb"]`. Through the binary, check stderr counts and JSON `summary` and `per_source` against a run listing both files.
  - AE2: the quoted glob gives identical `config.tests`.
  - AE3: `--test ./test/calc_test.rb --test test` gives `["./test/calc_test.rb", "test/greeter_test.rb"]`. The binary prints exactly one count, for `test`. Plain files print none (R8).
  - AE4: `--test spec` gives two spec paths and `config.framework == "rspec"`. The binary exits 0 with `summary.killed` equal to 1, proving the RSpec runner ran.
  - `--framework minitest --test spec` preserves `config.framework == "minitest"`.
  - AE5: all three invalid values exit 2 with their message and empty stdout, with and without `--dry-run`. `--format json` also leaves stdout empty.
  - `--test test/nope_test.rb` exits 2 with `no such file: test/nope_test.rb` (R7).
  - `--dry-run --test test` exits 0 and prints the stderr count.
  - AE6: in `test_a_test_file_given_as_a_source_after_test_exits_two` (`test/cli_test.rb:224-236`), replace assertion `repeat it for each test file` with `Quote the glob`. The next three guard tests pass unchanged (`test/cli_test.rb:238`, `:249`, `:258`).
  - AE7: use a recorder script that writes arguments to a file. `--test test --test-command "ruby record.rb %{files}"` records the directory, no `_test.rb` path and no stderr count. `--test 'test/*_test.rb'` records both test files.
  - AE9: in `test/cli_daemon_test.rb`, create temporary `lib/calc.rb` and `spec/calc_spec.rb`. `run lib/calc.rb --rails --daemon --test spec` exits 2 with `--daemon supports only --framework minitest`. It stops before daemon startup, keeping the test in the default suite (`test/cli_daemon_test.rb:10-13`).
  - `mutineer --help` contains `--test PATH` and `directory`.
- **Verification:** scenarios fail before and pass after implementation, except `--framework minitest` and R7, which pass both times. Change only the existing assertion at `test/cli_test.rb:234`.

### U3. The Action passes the `test` input unchanged (not in this pull request)

- **Status:** exclude U3 from #380. Build only after David answers "yes" to Q1. Use a separate draft pull request with `breaking change` and a major version label (KTD7).
- **Goal:** prevent bash from expanding `test` patterns when the gem supports expansion.
- **Requirements:** none here; R12 preserves the current Action contract.
- **Dependencies:** U2 and approval of Q1.
- **Files:** modify `action.yml`, `test/fixtures/action_harness.sh` and `test/action_harness_test.rb`.
- **Approach:**
  1. Move `runner` lines (`action.yml:414-418`) above the argument list (`action.yml:378`). #395 already does this.
  2. If `$TESTS` contains a glob character, read the gem version once. Compare with `Gem::Version`, following the floor check (`action.yml:426-429`).
  3. For 1.9.0 or later, bracket the test loop (`action.yml:380`) with `set -f` and `set +f`. Explain why in a comment (KTD7). Keep the sources loop unchanged.
  4. Name files, directories and globs in the `test` description (`action.yml:16-21`).
  5. Make the harness stub print `${STUB_VERSION:-1.0.0}` for `--version` (`test/fixtures/action_harness.sh:24`).
  6. Add harness cases `case19` and `case19b`, with scratch files `test/models/x_test.rb`, `lib/a.rb` and `lib/b.rb`. Both use `TESTS='test/**/*_test.rb test/models'` and `SOURCES='lib/*.rb'`. `case19` also sets `STUB_VERSION=1.9.0`.
  7. Add `"case19" => 1` and `"case19b" => 1` to the exit code map (`test/action_harness_test.rb:25-30`). Assert all three `OK:` lines.
- **Patterns to follow:** `run_step` and the argument-recording stub (`test/fixtures/action_harness.sh:20-31`, `:46-62`).
- **Test scenarios:**
  - AE8: `case19` records `--test test/**/*_test.rb --test test/models` and prints `OK: test patterns passed unchanged`. It fails before implementation: bash expands the first word to `test/models/x_test.rb`.
  - `case19` records `lib/a.rb` and `lib/b.rb`, then prints `OK: source glob still expanded by bash`. It passes before and after.
  - AE8: `case19b` records `--test test/models/x_test.rb` and prints `OK: older gem keeps bash expansion`. It passes before and after.
- **Verification:** `test/action_harness_test.rb` passes. Other harness exit codes stay unchanged.

### U4. Docs, stability note and CHANGELOG

- **Goal:** name all three forms wherever the `--test` contract appears.
- **Requirements:** R12 text; R13.
- **Dependencies:** U2.
- **Files:** modify `README.md`, `docs/cli.md`, `docs/index.md`, `docs/rails-setup.md`, `docs/ci.md`, `STABILITY.md`, `CHANGELOG.md` and only the `test` description in `action.yml`.
- **Approach:**
  1. Update `README.md:194`, `docs/cli.md:9`, `docs/index.md:71` and `docs/rails-setup.md:27`. Use `--test PATH`; name files, directories and quoted globs. Use this final `docs/cli.md:9` row, so later plans only append to it: '`--test PATH` | Test file, directory or quoted glob; repeat for more | Paired with each source by convention; unmatched sources are skipped; `--dry-run` with `--rails` or `--boot` still needs `--test`'.
  2. Below the `docs/cli.md` flag table, explain R1 and glob quoting. State that directories include system tests and `test_` support files, such as `test/support/test_helpers.rb`. Show precise Rails selection with `--test 'test/{models,controllers}/**/*_test.rb'`. Explain unchanged directories and no count with `--test-command`; globs still expand (R11, KTD4).
  3. In `docs/rails-setup.md`, place AE10's "every test but system tests" form beside the flag text. State that `--test test` includes `test/system/`.
  4. Update the Action `test` row (`docs/ci.md:138`) and description (`action.yml:16-21`). State that files and directories are accepted; directories require mutineer 1.9.0 or later and fail with older gems. In `docs/ci.md`, explain bash expansion in `test` and `extra-args`, where `**` matches one level. Cite Q1's GitHub issue on that line (`.expectation-fit/ways-of-working.yaml`, "Track every limitation"). Change no other `action.yml` line.
  5. Add an unreleased-note-style line to `STABILITY.md`. State that after 1.8.1, `--test` accepts directories and globs, and Action `test` accepts directories.
  6. Under `## [Unreleased]` (`CHANGELOG.md:7`), add:
     - `### Added`: three forms, exit 2 cases, counts and directory support in Action `test`.
     - `### Changed`: guard text.
     - `### Changed`: `--dry-run` now exits 2 for blanks and directories without test files.
  7. Describe behaviour. Cite a GitHub issue for each stated limit (`.expectation-fit/ways-of-working.yaml`, "Track every limitation").
- **Test expectation:** no new tests. `test/docs_contract_test.rb` and `test/site_docs_test.rb` pass unchanged.
- **Verification:** `rake docs:check` and the Verification Contract's site checks pass.

---

## Verification Contract

Prefix ruby, rake and bundle commands with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` unless the shell already sets them.

| Command | What it proves |
|---|---|
| `bundle exec ruby -Ilib -Itest test/pairing_test.rb` | U1: test-value expansion |
| `bundle exec ruby -Ilib -Itest test/cli_test.rb` | U2: CLI behaviour |
| `bundle exec ruby -Ilib -Itest test/cli_daemon_test.rb` | U2: daemon rejection |
| `bundle exec ruby -Ilib -Itest test/action_harness_test.rb` | U4: descriptions preserve harness behaviour. Requires `bash`, `git` and `jq` |
| `bundle exec ruby -Ilib -Itest test/docs_contract_test.rb` | U4: `STABILITY.md` and `action.yml` agree |
| `bundle exec rake test` | Default suite, including all new tests |
| `ruby -Ilib -e 'require "mutineer"'` | Load succeeds |
| `bundle exec rake yard:strict` | 100% documentation, including `expand_test`, `expand_tests!` and new helpers or constants |
| `bundle exec rake docs:check` | Committed docs match a fresh render |
| `bundle exec rake site:build`, then `node --test test/site_test.js` | U4: published pages work |
| `npm ci --prefix test/browser`, `npx --prefix test/browser playwright install chromium`, `npm test --prefix test/browser` | Website browser checks required by `AGENTS.md` |

No daemon code changes, so local `bundle exec rake test:daemon` is unnecessary. The daemon CI job runs it on the pull request.

Apply `AGENTS.md`: zero runtime dependencies, no `eval`, YARD comments for new methods and constants, and an Unreleased CHANGELOG entry.

## Definition of Done

- All U1 and U2 tests exist. They fail before and pass after implementation, except the two marked "pass before and after".
- AE1 to AE10 hold.
- Only the existing assertion at `test/cli_test.rb:234` changes.
- Existing file values preserve runs, scores, mutant ids, `schema_version` and JSON reports.
- `lib/mutineer/config.rb` is unchanged. Only the `test` description changes in `action.yml`. U3 is absent.
- Docs and `action.yml` name the release shipping U2. The pull request has `v1.9.0`.
- Help, five docs pages, `STABILITY.md` and `CHANGELOG.md` name all three forms. The `action.yml` description names files and directories.
- The pull request has Goal Capsule labels and `Closes #380`.
- No dead code or abandoned implementation remains.

---

## Risks and Overlaps

| Item | Overlap | Handling |
|---|---|---|
| #395 (Action queries for cache_dir and baseline), branch `feat/action-cache-dir-from-cli` | Rewrites much of `action.yml`; moves `runner` up and the unchanged test loop to line 426. Adds harness cases 17b, 18g to 18i, 13b and 14c; edits the stub and exit code map. Adds a help line above `--test FILE` and a `config` command. | Only the `test` description overlaps here. Keep expansion in `run` (KTD1), so `mutineer config` ignores `--test`. Rebase whichever lands second. Later U3 work starts from #395's layout. |
| #369 (warn about random order with `--test-command`) | Changes `--test-command` help and other rows in the same docs tables. | Different lines; text conflicts are unlikely. |
| #244 and #245 (the 2.0 line) | Both retain current `--test` help, option handler, guard and Action loop. | Rebase on this change; no semantic conflict. In 2.0, unknown config keys fail, so `test:` exits 2. |
| #391, #393, #375, #373 (reload fix, parse-error fix, hook-block placement, redaction) | Only `CHANGELOG.md` overlaps this plan. | Resolve Unreleased text conflicts. |
| Plan for #382 (the `tests:` map) | Reuses `Pairing.expand_test` per pattern (its KTD4). Its R4 includes `test_*.rb` and file-only globs (#382 plan, R4 (Pattern expansion)). Changes `run`, `--test` help, `docs/cli.md:9`, `README.md:194` and the `action.yml` `test` description. | Rules agree (KTD9). Land #380 first. If #382 lands first, add the function with these rules. Rebase the second pull request for help and `docs/cli.md` conflicts. |
| Plan for #379 (pair concerns with namespace-matching tests) | Adds `Pairing.namespace_base`, extends `infer_tests`, and changes the `Pairing` module comment (`lib/mutineer/pairing.rb:6-22`), also changed by U1 step 4. It leaves `candidates` and `logical_path` unchanged. Its U3 also adds `test/models/storage/totaled_test.rb` to `test/fixtures/autopair`. | Expect a comment conflict. Rebase the second pull request and retain both jobs. AE1 to AE3 pin exactly two files from that fixture; see the U2 note. If a later change adds another test file under `test/fixtures/autopair/test`, keep the U2 note valid. |
| Plan for #381 (count sources without paired tests) | Changes `autopair!`, reports and the `--test` row at `docs/cli.md:9`, also changed by U4. | Expect a conflict at `docs/cli.md:9`; rebase and retain both sentences. No logic overlap: explicit `--test` makes `autopair!` return immediately (`lib/mutineer/cli.rb:642`). |
| The version in the docs | Docs and `action.yml` require mutineer 1.9.0 for directories. A different release makes this incorrect. | Check in Definition of Done. A differently numbered release pull request must update it. |
| Action globs and `extra-args` | Bash expands `test` globs (`action.yml:380`) and unquoted `--test` patterns in `extra-args` (`action.yml:394`). `**` matches one level (review probe R2). | Keep unchanged (KTD7). Explain in `docs/ci.md` with Q1's issue. |
| A broad directory | `--test .` enters non-dot folders, including `vendor/bundle`, and loads installed gems' tests (probe 2). | R8 reports counts. Q3 covers exclusions. The `ruby/setup-ruby` bundle path on runners was not checked. |
| #398 (full clean checks on coverage cache hits) | A directory puts many tests behind one flag. The digest includes each file (`lib/mutineer/coverage_map.rb:1418`); new files trigger capture. | No change. One validation report claims globs reduce captures; this requires a narrower user selection. |
| #360 and #282 (not-green messages, test order and seed) | Fizzy's full-suite report records 64 test files that were not green. One validation report could not identify the cause. | This change simplifies the command, without fixing failures. Clean checks and mutants use the same expanded list, preserving order. |
| Files with a test name that are not tests | `test_*.rb` includes support files. Here, fixtures account for 107 of 201 matches (probe 3). | R8 reports counts. Globs select precisely. Q3 covers exclusions. |
| Symlinked directories | `Dir.glob`'s `**` skips symlinked directories (probe 2), as `expand_sources` does today. | Fizzy has none under `test/` (probe 3). R8 exposes low counts. |
| Long argument lists | `--test-command` passes one argument per file (`lib/mutineer/external_backend.rb:84-92`). Globs can select many files. | Fizzy's 261 files are well below limits. KTD4 preserves directories as one argument. |

## Open Questions

No question blocks U1, U2 or U4. Q1 blocks U3. David decides each question.

- Q1. **Should the Action stop bash expansion of `test` (U3, KTD7)?** Default: not in a minor release. Keep the loop and document one-level `**`. Approval widens working globs: `test/**/*.rb` would also load `test/test_helper.rb` and fixtures. Put U3 in a draft 2.0 pull request with `breaking change`. David must file one GitHub issue covering one-level `**` in `test` and `extra-args`. U4 cites it in `docs/ci.md`.
- Q2. **Should `--test-command` receive expanded directory files?** Default: no; preserve typed values (KTD4). Universal expansion simplifies backend rules but changes command arguments.
- Q3. **Should directories exclude `fixtures/`, `dummy/` and `system/`?** Default: no. `rails test` excludes them only without a path; explicit paths exclude nothing (railties 8.1.4, `rails/test_unit/runner.rb:116-122`, `:133-134`). A `--test` directory is explicit. Fizzy has 4 system tests among 265 files; this repository has 107 fixtures among 201. Docs show a glob excluding system tests (U4, AE10). Revisit after reports of slow or not-green directory runs.
- Q4. **Should positional sources accept quoted globs?** Default: exclude from this pull request. David files an issue if wanted. These docs state no source limit.
- Q5. **Resolved: shared expansion rules.** #380 and #382 (the `tests:` map) share `Pairing.expand_test`, R1's names and KTD9's glob rule. The #382 plan states both (#382 plan, R4 (Pattern expansion)).

## Sources and probes

- Issue #380 and Vladimir's Fizzy report: "Missing parts", item "`--test` accepting directories or globs".
- Three validation reports dated 2026-11-09: Sol, grok-cursor and opus. All target 1.9.0 for #380. Opus calls it the smallest step without score changes.
- Related plan: `docs/plans/2026-10-24-293-fix-tests-as-sources-guard-plan.md`, which confirms that `.mutineer.yml` has no `tests` key.

Probe scripts and output: `/private/tmp/claude-501/-Users-davidteren-Projects-claude-worktrees-mutineer-vladimir-issues-planning-21adcb/ae564be8-638b-4dd0-a9e5-9d7a58cb00ae/scratchpad/context/probes/380/`. This machine-local folder can disappear. Results follow.

| Probe | Question | Result |
|---|---|---|
| 1 | How does `main` handle each value and `test:`? | See "Problem Frame". Two flags in one argument exit 2 with `invalid option`. `test:` and `tests:` print `unknown config key`. |
| 2 | How do Ruby, bash and zsh expand patterns? | Ruby 3.4.9 `Dir.glob` expands `**` recursively, sorts results and expands braces. It skips dot files and symlinked directories. Bash 5.3.15 without globstar treats `**` as one level and does not expand variable-held braces. `set -f` preserves patterns. Zsh rejects unmatched globs and passes unquoted variables as one argument. |
| 3 | What does the directory rule select in real trees? | Fizzy commit `f220e4832`: 287 `.rb` files under `test/`; 265 have test names, all ending `_test.rb`. Of these, 4 are under `test/system/`; 261 occupy nine other directories and one file. This repository at `8d9905c4`: 201 matches under `test/`, including 107 under `test/fixtures/`. |
| 4 | How do external-command directories, blanks and daemon spec directories behave? | `--test-command` receives the directory and exits 0. `--test ""` exits 0 with `--dry-run`; otherwise, exit 2 names the project root. `--rails --daemon --test spec` omits the RSpec message; `--test spec/calc_spec.rb` prints it. |
| 5 | Does `Dir.glob` preserve `./`? Does blank mean root? | Both are true. Absolute-path keys combine `./test/a_test.rb` and `test/a_test.rb` into one entry. |
| R1 | Test KTD5's order on edge trees and Fizzy (`refute/r1_expand_test_prototype.rb`) | `--test test` includes `test/support/test_helpers.rb` and `test/test_case.rb` through `test_`. Fizzy: 265 files, including 4 under `test/system/`; 261 with the nine-folder brace glob plus `test/routes_test.rb`. Models and controllers select 215. `test/mod*` returns `[]`. |
| R2 | Test glob detection, `set -f` and `extra-args` on bash 3.2.57 and 5.3.15 (`refute/r2_action_set_f.sh`) | `set -f` preserves patterns. `--test` globs in `extra-args` still expand one level. |

Not checked: a full daemon directory run; plan rules prohibit `rake test:daemon`. The daemon shares the in-process list (`lib/mutineer/daemon_backend.rb:57`).

Not checked: U3 on GitHub runner bash. The harness uses GitHub's `bash -e -o pipefail` (`test/fixtures/action_harness.sh:2`); `set -f` is POSIX. Runner behaviour remains unverified.