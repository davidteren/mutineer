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

- **Issue:** #380 (let `--test` take a directory or a glob).
- **Objective:** a user names the tests for a run with a few `--test` values, not one flag for each file. A value can be a file, a directory or a quoted glob. The command line and the GitHub Action read a value the same way.
- **Means:** the CLI expands each `--test` value one time, before any backend reads the list (KTD1).
- **Authority:** this plan, then `AGENTS.md` and `STABILITY.md`, then the issue text. Where this plan differs from the issue, this plan wins (see "Corrections to the issue").
- **Stop and ask when:** a change would alter the score, a mutant id or the JSON schema. Stop also when it would alter the default of an Action input. Stop when it would alter the result of a `--test` value that works today.
- **Size and delivery:** S. One pull request with `Closes #380`. About 15 files: 2 under `lib/`, `action.yml`, 5 under `test/` and 7 docs files. No new runtime dependency.
- **Release:** labels `enhancement`, `priority: medium`, `risk: low` and `v1.9.0`. Semver class: minor, because a flag and an Action input accept more values. A maintainer merges the pull request. This plan has no release step.

---

## Product Contract

### Summary

`mutineer run` expands each `--test` value before it validates the run. A directory gives the test files under it. A quoted glob gives the files it matches. A file stays as typed. A blank value, or a value that gives no test file, is a usage error with exit 2. With a gem that has this change, the Action passes its `test` input to the CLI with no shell expansion. Both surfaces then read a pattern the same way.

### Problem Frame

`--test` takes one file for each flag (`lib/mutineer/cli.rb:154`). Vladimir Dementyev's Fizzy report lists this under "Missing parts": the user must list every test file. His coverage-guided run over `app/models` and `app/controllers` passed every non-system test (report, "Full-scope coverage-guided run"). In the Fizzy clone that is 261 flags (probe 3). The model and controller tests alone are 215 files (108 plus 107, probe 3).

Every other form of the value fails today, each in a different way. These results are from `main` at `8d9905c4` (probes 1 and 4).

| `--test` value | Result today |
|---|---|
| Directory, in-process run | Exit 2 with a raw `Is a directory @ io_fread - <absolute path>` |
| Directory with `--dry-run` | Exit 0. The value is accepted and not used |
| Directory with `--test-command` | Works. The command receives the directory |
| Quoted glob | Exit 2 with `no such file: test/*_test.rb` |
| Unquoted glob | The shell expands it. Exit 2 with `--test takes one file` |
| Blank value (`--test ""`) | Reads as the project root. Exit 0 with `--dry-run`, exit 2 in a run |
| Directory of specs with `--rails --daemon` | The RSpec check for the daemon does not fire |

### Requirements

**Expansion**

- R1. A `--test` value that is a directory gives each file under it, at any depth, that has a test name. A test name is `*_test.rb`, `*_spec.rb` or `test_*.rb`, but not `test_helper.rb`.
- R2. A `--test` value is a glob when it has `*`, `?`, `[` or `{` and is not an existing path. A glob gives the files it matches from the project root, with no name filter. It does not take a directory that it matches.
- R3. A `--test` value that is an existing file stays as typed, also when its name has a glob character.
- R4. The result of one value is sorted by path. The results keep the order of the `--test` flags. A file that two values give appears one time. An expanded path is relative to the project root when it is inside the root.
- R5. Mutineer detects the framework from the expanded list, unless the user set `--framework` or `framework:`.

**Errors and notes**

- R6. A blank `--test` value exits 2. A directory or a glob that gives no test file exits 2. The message names the value.
- R7. A missing path with no glob character exits 2 with the `no such file` message, as today.
- R8. For each directory or glob value, stderr shows one line with the number of test files that the value gave.
- R9. When a positional argument looks like a test file, the usage error gives three fixes. The fixes are: quote the glob, pass the directory, or repeat `--test`.

**Surfaces**

- R10. Expansion and its errors are the same in a run and in `--dry-run`, and in the in-process and daemon backends.
- R11. With `--test-command`, a directory value goes to the command as typed, as today. A glob follows R2.
- R12. When the installed gem has this change, the Action passes each word of its `test` input to the CLI unchanged. Bash does not expand a pattern first. With an older gem, the Action acts as today.
- R13. The help text, the user docs, `STABILITY.md` and `CHANGELOG.md` describe the three forms of the value.
- R14. The score, mutant ids, the JSON schema and `schema_version` do not change. The config keys, the Action inputs and their defaults do not change.

### Acceptance Examples

AE1 to AE3 and AE6 use the fixture `test/fixtures/autopair`: `lib/calc.rb`, `lib/greeter.rb`, `test/calc_test.rb` and `test/greeter_test.rb`.

- AE1. Covers R1, R4, R8. `mutineer run lib --test test --format json` runs with `test/calc_test.rb` and `test/greeter_test.rb`. Stderr has `[mutineer] --test test: 2 test files`. The JSON `summary` equals the `summary` of a run that lists the two files.
- AE2. Covers R2. `mutineer run lib/calc.rb --test 'test/*_test.rb'` runs with the same two files.
- AE3. Covers R3, R4. `--test ./test/calc_test.rb --test test` gives `./test/calc_test.rb`, then `test/greeter_test.rb`.
- AE4. Covers R1, R5. A project has `spec/calc_spec.rb`, `spec/nested/greeter_spec.rb` and `spec/spec_helper.rb`. `--test spec` gives the two spec files, and the framework is `rspec`.
- AE5. Covers R6, R10. `--test 'nowhere/*_test.rb'`, `--test <empty directory>` and `--test ""` each exit 2 and name the value. `--dry-run` gives the same result. Stdout is empty.
- AE6. Covers R9. `mutineer run lib/calc.rb --test test/calc_test.rb test/greeter_test.rb` exits 2. Stderr has `test/greeter_test.rb looks like a test file, not a source` and `Quote the glob`.
- AE7. Covers R11. `--test test --test-command "ruby record.rb %{files}"` gives the command the directory path, not a list of files.
- AE8. Covers R12. The Action input is `test: "test/**/*_test.rb test/models"`. With a gem at 1.9.0 or later, the CLI receives `--test test/**/*_test.rb --test test/models`. With an older gem, bash expands the first word, as today.
- AE9. Covers R5, R10. `--rails --daemon --test spec`, where `spec` holds spec files, exits 2 with `--daemon supports only --framework minitest`.

### Scope Boundaries

- No `test:` or `tests:` key in `.mutineer.yml`. The key does not exist (see "Corrections to the issue"). #382 (the `tests:` map) owns the name `tests:`.
- An explicit `--test` still replaces pairing by convention for every source (`lib/mutineer/cli.rb:629-642`). Tests that add to one source are #382.
- The Ruby API (`Mutineer::Config.new`, `Runner.execute`) takes file paths as before. Expansion is a CLI step.
- No JSON key for the expanded list or its count.
- No change to the coverage cache or to the clean check. #398 (a coverage cache hit still runs the full clean check) owns that cost.

Considered and not built:

- An exclude list for `fixtures/`, `dummy/` or `system/` folders, or an exclude flag. A glob already selects exactly, and R8 shows the count. See Q3.
- Globs in positional sources. The issue does not ask for them. See Q4.
- A directory rule that changes with the framework. One rule is simpler, and a mixed directory then acts like a mixed list of files does today (`lib/mutineer/config.rb:294-298`). User reports of mixed directories would change this call.
- A list of the expanded files under `--verbose`. The count (R8) is the smallest signal that shows a wrong selection.

### Corrections to the issue

- **"Apply this to `test:` in `.mutineer.yml`, if present."** The key is not present. `KNOWN_KEYS` (`lib/mutineer/config.rb:111`) comes from `CONFIG_OPTIONS` (`lib/mutineer/config.rb:43-74`), which has no row for tests. Probe 1 shows `unknown config key "test"` and `unknown config key "tests"`. `docs/cli.md:47` tells the user to pass tests with `--test`. There is no config work in this plan.
- **"It accepts one file."** This is not complete. A directory works today with `--test-command` (probe 4). A directory exits 0 with `--dry-run` (probe 1). The in-process failure is a raw `Errno::EISDIR` message from the rescue at `lib/mutineer/cli.rb:366-370`, not a designed usage message.
- **The directory rule `**/*_test.rb`, plus `**/*_spec.rb` for RSpec.** It leaves out `test_*.rb`. Pairing already treats that name as a Minitest test (`lib/mutineer/pairing.rb:141-143`, `:150-152`). Bundler's Minitest template names its test `test_newgem.rb.tt` (Bundler 2.7.2). This plan uses `Pairing::TEST_NAME` (KTD3).
- **"A directory argument prevents this error."** Partly. The error is real: one argument that holds several flags exits 2 with `invalid option` (probe 1). The cause is zsh, which does not split an unquoted variable (probe 2). A directory removes the need for the list. It does not change option parsing.
- **Not in the issue: the unquoted glob.** A shell expands `--test test/*_test.rb` into one flag value plus positional arguments. The tests-as-sources guard catches them (`lib/mutineer/cli.rb:216-223`), but its message says `--test takes one file`. That text becomes wrong (R9).
- **Not in the issue: the Action.** The loop `for t in $TESTS` (`action.yml:380`) is unquoted, so bash already expands a glob in the `test` input. With globstar off, `test/**/*_test.rb` matches one directory level only (probe 2). That is a silent partial list. An Action at the new version can also run an older gem. The fix thus needs a version check (R12, KTD7).
- **Not in the issue: framework detection.** `Config.resolve` detects the framework from the raw values (`lib/mutineer/config.rb:267`). A directory named `spec` reads as Minitest, so the daemon's RSpec check does not fire (probe 4). Expansion must come first (R5).
- **Not in the issue: the blank value.** `--test ""` expands to the project root (probes 4 and 5). With directory expansion it would select every test file in the project. An unset shell variable gives this value, so it must be an error (R6). `cache_dir` and `since` already reject a blank value for the same reason (`lib/mutineer/config.rb:372-374`, `:379-385`).
- **"Follow `Pairing.expand_sources`, which already accepts directories."** True for directories (`lib/mutineer/pairing.rb:42-43`). `expand_sources` does not expand a glob (`lib/mutineer/pairing.rb:44-46`), so the glob rule is new code.
- **"Implementation and tests were not checked."** This plan checked them. The evidence is in "Sources and probes".

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Expand in the `run` branch of `CLI.start`, before the tests-as-sources guard.** A new `CLI.expand_tests!` runs when the user typed `--test` (`config.explicit?(:tests)`). It runs at the top of the `when "run"` branch (`lib/mutineer/cli.rb:214-227`). Reason: each backend reads the same `config.tests` (`lib/mutineer/runner.rb:144`, `:150`, `:164`, `:170`, `:241` and `lib/mutineer/daemon_backend.rb:57`). The guard reads that list to find tests beside an argument (`lib/mutineer/cli.rb:216-218`). `validate_daemon!` reads the framework (`lib/mutineer/cli.rb:434`, `:500-504`). Rejected: expansion in the option handler (`lib/mutineer/cli.rb:154`). It would also run for `migrate`, and for `mutineer config` from #395 (the Action asks the CLI for cache_dir and baseline). Rejected: expansion in `Config.resolve`. `lib/mutineer/config.rb` is in the self-dogfood job (`.github/workflows/ci.yml:216-235`) and does no path work today.
- KTD2. **One pure function for one value: `Pairing.expand_test`.** It returns a list of paths. An empty list means that the value matched nothing. The CLI owns the messages and the exit. Reason: the CLI needs a result for each value (R6, R8). #382 (the `tests:` map) can call the same function for each mapped pattern. Its plan names a list helper, `expand_tests`, which can call this function for each pattern. Rejected: a mode flag on `expand_sources`. Its rules differ: it takes every `.rb` file, it does not expand a glob, and it rewrites a file path.
- KTD3. **A directory selects by `Pairing::TEST_NAME`** (`lib/mutineer/pairing.rb:152`). Reason: the code base then has one definition of a test name. Rejected: the two suffixes from the issue. A project that names tests `test_*.rb` would get a silent partial list. Measured: in the Fizzy clone the rule selects the same 265 files as `*_test.rb` (probe 3). In this repository it selects 201 files under `test/`, and 107 of them are fixtures (probe 3). R8 makes such a selection visible.
- KTD4. **With `--test-command`, a directory stays as typed.** Reason: that value works today (probe 4), and `STABILITY.md:14` says that a minor release keeps a flag and its meaning. The external command applies its own file rules, and Mutineer builds no coverage map there (`lib/mutineer/runner.rb:232-234`). Rejected: one expansion rule for every backend. It would change the arguments that the user's command receives (`lib/mutineer/external_backend.rb:84-92`). See Q2.
- KTD5. **An existing path wins over the glob reading.** The order is: directory, existing file, glob, then the value as typed. Reason: no value that works today changes (R3), and a missing plain path keeps its message (R7).
- KTD6. **Remove duplicates by absolute path, and keep the first spelling.** Reason: R3 keeps a file as typed, and `./test/a_test.rb` with `test` must not run one file two times (probe 5).
- KTD7. **The Action turns off pathname expansion for the test loop, and only for a gem that expands the value.** When the `test` input has a glob character, the Action reads the gem version. For 1.9.0 or later, `set -f` goes before the loop at `action.yml:380` and `set +f` goes after it. Reason: the CLI is then the only expander, so the Action and the CLI agree on `**` and on braces. An older gem keeps bash expansion, so no workflow that runs today breaks. #395 also keeps a fallback for an older CLI. The sources loop (`action.yml:379`) stays as it is, because the CLI does not expand a source glob. Rejected: `set -f` with no version check. An older gem would receive the pattern and exit 2. Rejected: a change to the description only. `**` would keep its silent one-level match. Rejected: `shopt -s globstar`. Two expanders would stay, and bash 3.2.57 (`/bin/bash` on macOS) does not have the option. See Q1.
- KTD8. **One count line on stderr for each expanded value.** Reason: a directory selects by name, and no other output shows the selection. Stderr keeps the JSON and HTML reports clean. Rejected: no output, and output only with `--verbose`.

### High-Level Technical Design

The sketch shows the decisions and their order. It is not an implementation.

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

The tests pin the quoted parts.

- Blank value: `mutineer: --test must name a file, a directory or a glob, not blank (got: "")`
- No match: `mutineer: --test test/empty matched no test files`. For a directory, add: `A directory gives the files under it named *_test.rb, *_spec.rb or test_*.rb.`
- Count line: `[mutineer] --test test/models: 108 test files`. One file prints `1 test file`.
- Guard (replaces `lib/mutineer/cli.rb:220-221`): `mutineer: <paths> looks like a test file, not a source. A shell expands an unquoted glob into many files. Quote the glob (--test 'test/**/*_test.rb'), pass the directory (--test test), or repeat --test for each file`
- Help (replaces `lib/mutineer/cli.rb:53-55`): the option reads `--test PATH`. The text names a test file, a directory and a quoted glob, and says that the flag repeats.

### Assumptions

No user confirmed these choices. Each one is a default that a maintainer can change.

- The count line (R8, KTD8) is wanted on every run that expands a value.
- A directory selects by name only, with no exclude list (KTD3, Q3).
- `--test-command` keeps a directory as typed (KTD4, Q2).
- The Action change is a minor change (KTD7, Q1).
- This change ships in 1.9.0, as the `v1.9.0` label says. KTD7 uses that number.

---

## Implementation Units

### U1. `Pairing.expand_test`

- **Goal:** one pure function turns one `--test` value into a list of test paths.
- **Requirements:** R1, R2, R3, R7, and the sort and root-relative parts of R4.
- **Dependencies:** none.
- **Files:** `lib/mutineer/pairing.rb` (modify), `test/pairing_test.rb` (modify).
- **Approach:**
  1. Add `expand_test` beside `expand_sources` (`lib/mutineer/pairing.rb:35-49`). Follow KTD5 for the order of the checks.
  2. Reuse `existing_relative` (`lib/mutineer/pairing.rb:59-62`) and `ProjectPath.root_real`. A path through `./`, an absolute path or a symlinked root then gives the root-relative path. `Dir.glob` keeps a `./` prefix (probe 5), so each match needs this step.
  3. Match a glob with `Dir.glob` and `base:` set to the project root. An absolute pattern ignores `base:` (probe 2).
  4. Update the module comment (`lib/mutineer/pairing.rb:6-22`): it lists three jobs today.
  5. Write a YARD comment for each new method and constant.
- **Patterns to follow:** `expand_sources` and its tests (`test/pairing_test.rb:100-170`), and the `with_tree` helper (`test/pairing_test.rb:12-21`).
- **Test scenarios** (the tree is `test/a_test.rb`, `test/models/b_test.rb`, `test/models/deep/c_test.rb`, `test/test_d.rb`, `test/test_helper.rb`, `test/support/helper.rb`, `test/.hidden/e_test.rb`, `spec/x_spec.rb`, `spec/spec_helper.rb`):
  - Covers AE1. `test` gives `test/a_test.rb`, `test/models/b_test.rb`, `test/models/deep/c_test.rb`, `test/test_d.rb`, in that order. `test_helper.rb`, `support/helper.rb` and the file in `.hidden` are not in the list.
  - Covers AE4. `spec` gives `spec/x_spec.rb` only.
  - Covers AE2. `test/**/*_test.rb` gives the three `_test.rb` files and not `test/test_d.rb`.
  - `{test,spec}/**/*_{test,spec}.rb` gives four files, sorted.
  - `test/*.rb` gives `test/a_test.rb`, `test/test_d.rb` and `test/test_helper.rb`. A glob has no name filter.
  - `test/mod*` matches only the directory `test/models` and gives `[]`.
  - `./test/a_test.rb` gives `["./test/a_test.rb"]`. An existing file named `test/[x]_test.rb` gives itself.
  - `./test/*_test.rb` and the absolute path of `test` give root-relative paths.
  - `test/nope_test.rb` (missing, no glob character) gives itself.
  - `test/**/*_nomatch.rb` gives `[]`. The directory `test/support` gives `[]`.
  - A directory outside the project root gives absolute paths.
- **Verification:** each new test fails before the change and passes after it. The `expand_sources` tests pass with no edit.

### U2. Expand in the CLI, with the errors, the count line and the new guard text

- **Goal:** `mutineer run` uses `Pairing.expand_test` for each `--test` value and reports a bad value as a usage error.
- **Requirements:** R4, R5, R6, R8, R9, R10, R11, and the help part of R13.
- **Dependencies:** U1.
- **Files:** `lib/mutineer/cli.rb` (modify), `test/cli_test.rb` (modify), `test/cli_daemon_test.rb` (modify).
- **Approach:**
  1. Add `CLI.expand_tests!(config)` as a private-API class method, like `autopair!` (`lib/mutineer/cli.rb:641`). The sketch above gives its steps. KTD4 and KTD6 own two of them.
  2. Call it at the top of the `when "run"` branch when `config.explicit?(:tests)` is true (KTD1).
  3. Detect the framework again with the line that `autopair!` uses (`lib/mutineer/cli.rb:653`).
  4. Replace the guard message and the help text with the text in "Message text". Change the option to `--test PATH` (`lib/mutineer/cli.rb:154`).
  5. Do not change `lib/mutineer/config.rb`.
- **Patterns to follow:** `autopair!` for a step that changes the config and exits 2 (`lib/mutineer/cli.rb:641-660`). `config_resolved_by_cli` for a test that reads the config the CLI built (`test/cli_test.rb:1437-1448`). `with_autopair_project` and `rspec_project` for projects (`test/cli_test.rb:1314-1319`, `:1472-1485`).
- **Test scenarios:**
  - Covers AE1. Through `config_resolved_by_cli`, `run lib --test test` gives `config.tests == ["test/calc_test.rb", "test/greeter_test.rb"]`. Through the binary, stderr has the count line. The JSON `summary` and `per_source` equal those of the run that lists the two files.
  - Covers AE2. The quoted glob gives the same `config.tests`.
  - Covers AE3. `--test ./test/calc_test.rb --test test` gives `["./test/calc_test.rb", "test/greeter_test.rb"]`.
  - Covers AE4. `--test spec` gives the two spec paths and `config.framework == "rspec"`. Through the binary, the run exits 0 and `summary.killed` is 1, so the RSpec runner ran.
  - `--framework minitest --test spec` keeps `config.framework == "minitest"`.
  - Covers AE5. Each of the three bad values exits 2 with its message and an empty stdout, with and without `--dry-run`. `--format json` also gives an empty stdout.
  - `--test test/nope_test.rb` exits 2 with `no such file: test/nope_test.rb` (R7).
  - `--dry-run --test test` exits 0 and prints the count line on stderr.
  - Covers AE6. In `test_a_test_file_given_as_a_source_after_test_exits_two` (`test/cli_test.rb:224-236`), replace the `repeat it for each test file` assertion with `Quote the glob`. The three guard tests that follow it (`test/cli_test.rb:238`, `:249`, `:258`) pass with no edit.
  - Covers AE7. A small recorder script writes its arguments to a file. With `--test test --test-command "ruby record.rb %{files}"`, the file holds the directory path and no `_test.rb` path, and stderr has no count line. With `--test 'test/*_test.rb'`, the file holds the two test files.
  - Covers AE9, in `test/cli_daemon_test.rb`. A temporary project holds `lib/calc.rb` and `spec/calc_spec.rb`. `run lib/calc.rb --rails --daemon --test spec` exits 2 with `--daemon supports only --framework minitest`. The run stops before a daemon starts, so the test stays in the default suite (`test/cli_daemon_test.rb:10-13`).
  - `mutineer --help` shows `--test PATH` and the word `directory`.
- **Verification:** each scenario fails before the change and passes after it. Two scenarios pass before and after: the `--framework minitest` scenario and the R7 scenario. No existing test changes, except the one assertion at `test/cli_test.rb:234`.

### U3. The Action passes the `test` input unchanged

- **Goal:** with a gem that expands `--test` values, bash does not expand a pattern in the `test` input first.
- **Requirements:** R12, and the Action part of R13.
- **Dependencies:** U2, so that the CLI expands what the Action passes.
- **Files:** `action.yml` (modify), `test/fixtures/action_harness.sh` (modify), `test/action_harness_test.rb` (modify).
- **Approach:**
  1. Move the `runner` lines (`action.yml:414-418`) above the argument list (`action.yml:378`). #395 already has them there.
  2. When `$TESTS` has a glob character, read the gem version one time. Compare it with `Gem::Version`, as the floor check does (`action.yml:426-429`).
  3. For 1.9.0 or later, put `set -f` before the test loop (`action.yml:380`) and `set +f` after it. Add a comment that says why (KTD7). Do not change the sources loop.
  4. Change the `test` description (`action.yml:16-21`) to name files, directories and globs.
  5. In the harness stub, print `${STUB_VERSION:-1.0.0}` for `--version` (`test/fixtures/action_harness.sh:24`).
  6. Add harness cases `case19` and `case19b`. Make `test/models/x_test.rb`, `lib/a.rb` and `lib/b.rb` in the scratch repository. Both cases run with `TESTS='test/**/*_test.rb test/models'` and `SOURCES='lib/*.rb'`. `case19` adds `STUB_VERSION=1.9.0`.
  7. Add `"case19" => 1` and `"case19b" => 1` to the exit code map (`test/action_harness_test.rb:25-30`), and assert the three `OK:` lines.
- **Patterns to follow:** `run_step` and the stub that records its arguments (`test/fixtures/action_harness.sh:20-31`, `:46-62`).
- **Test scenarios:**
  - Covers AE8. In `case19`, the stub arguments hold `--test test/**/*_test.rb --test test/models`. The harness prints `OK: test patterns passed unchanged`. This fails before the change, because bash expands the first word to `test/models/x_test.rb`.
  - In `case19`, the stub arguments hold `lib/a.rb` and `lib/b.rb`. The harness prints `OK: source glob still expanded by bash`. This passes before and after.
  - Covers AE8. In `case19b`, the stub arguments hold `--test test/models/x_test.rb`. The harness prints `OK: older gem keeps bash expansion`. This passes before and after.
- **Verification:** `test/action_harness_test.rb` passes. The other harness cases keep their exit codes.

### U4. Docs, stability note and CHANGELOG

- **Goal:** each place that states the `--test` contract names the three forms.
- **Requirements:** R13.
- **Dependencies:** U2, U3.
- **Files:** `README.md`, `docs/cli.md`, `docs/index.md`, `docs/rails-setup.md`, `docs/ci.md`, `STABILITY.md`, `CHANGELOG.md` (all modify).
- **Approach:**
  1. Update the four flag texts: `README.md:194`, `docs/cli.md:9`, `docs/index.md:71` and `docs/rails-setup.md:27`. Each reads `--test PATH` and names a file, a directory and a quoted glob.
  2. In `docs/cli.md`, add a short note under the flag table. It gives the directory rule (R1) and says to quote a glob. It shows one Rails example: `--test 'test/{models,controllers}/**/*_test.rb'`. It says that a glob selects more exactly than a directory.
  3. Update the `test` row of the Action inputs table (`docs/ci.md:138`). Say that a glob in the Action needs mutineer 1.9.0 or later to match at every depth.
  4. Add one line to `STABILITY.md`. Use the style of its other notes for a change that is not yet in a release. The line says that `--test` and the `test` input also take a directory or a glob after 1.8.1.
  5. Add CHANGELOG entries under `## [Unreleased]` (`CHANGELOG.md:7`):
     - `### Added`: the three forms, the exit 2 cases and the count line.
     - `### Changed`: with mutineer 1.9.0 or later, the Action passes a pattern in `test` to the CLI. `**` then matches at every depth.
     - `### Changed`: the new guard text.
     - `### Changed`: with `--dry-run`, a blank value and a directory with no test files now exit 2.
  6. Describe behaviour, not limits. If a doc line states a limit, name its GitHub issue in the same change (`.expectation-fit/ways-of-working.yaml`, "Track every limitation").
- **Test expectation:** none new. This unit changes text only. `test/docs_contract_test.rb` and `test/site_docs_test.rb` must pass with no edit.
- **Verification:** `rake docs:check` is clean, and the site checks in the Verification Contract pass.

---

## Verification Contract

Prefix each ruby, rake and bundle command with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` in a shell where they are not set.

| Command | What it proves |
|---|---|
| `bundle exec ruby -Ilib -Itest test/pairing_test.rb` | U1 |
| `bundle exec ruby -Ilib -Itest test/cli_test.rb` | U2 |
| `bundle exec ruby -Ilib -Itest test/cli_daemon_test.rb` | U2, the daemon scenario |
| `bundle exec ruby -Ilib -Itest test/action_harness_test.rb` | U3. It needs `bash`, `git` and `jq` |
| `bundle exec ruby -Ilib -Itest test/docs_contract_test.rb` | U4. `STABILITY.md` and `action.yml` still agree |
| `bundle exec rake test` | The default suite, with every new test |
| `ruby -Ilib -e 'require "mutineer"'` | The load check |
| `bundle exec rake yard:strict` | 100% documented. `expand_test`, `expand_tests!` and each new helper or constant need a comment |
| `bundle exec rake docs:check` | The committed docs match a fresh render |
| `bundle exec rake site:build`, then `node --test test/site_test.js` | U4 changes pages that the site publishes |
| `npm ci --prefix test/browser`, `npx --prefix test/browser playwright install chromium`, `npm test --prefix test/browser` | The website browser checks from `AGENTS.md` |

`bundle exec rake test:daemon` is not needed for this change: no daemon code changes. The CI job for the daemon runs it on the pull request.

`AGENTS.md` rules that apply: zero runtime dependencies and no `eval`. Each new method and constant needs a YARD comment. The change needs a CHANGELOG entry under Unreleased.

## Definition of Done

- Each test named in U1 to U3 exists. Each one failed before its unit and passes after it, except the four marked "passes before and after".
- AE1 to AE9 hold.
- No existing test changed, except the assertion at `test/cli_test.rb:234` and the exit code map in `test/action_harness_test.rb`.
- A `--test` value that is an existing file gives the same run as before. The score, mutant ids, `schema_version` and the JSON report do not change.
- `lib/mutineer/config.rb` did not change.
- The version in `action.yml` is the release that ships U2. The pull request has the `v1.9.0` label.
- The help text, the five docs pages, `action.yml`, `STABILITY.md` and `CHANGELOG.md` name the three forms.
- The pull request has the labels from the Goal Capsule and `Closes #380`.
- No dead code and no abandoned attempt remains in the diff.

---

## Risks and Overlaps

| Item | Overlap | Handling |
|---|---|---|
| #395 (the Action asks the CLI for cache_dir and baseline), branch `feat/action-cache-dir-from-cli` | It rewrites much of `action.yml`. It moves `runner` up and the test loop down to line 426, unchanged. It adds harness cases 17b, 18g to 18i, 13b and 14c, and edits the stub and the exit code map. It adds a help line above `--test FILE` and a `config` command. | Text conflicts only. `case19` and `case19b` are free on both branches. Expansion stays in the `run` branch (KTD1), so `mutineer config` still ignores `--test`. Rebase on the one that lands first. |
| #369 (warn when `--test-command` runs tests in random order) | It edits the help text of `--test-command`, and other rows of the same docs tables. | Different lines. A text conflict is not likely. |
| #244 and #245 (the 2.0 line) | Both branches keep today's help line, option handler, guard text and Action loop for `--test`. | They rebase on this change. No semantic conflict. In 2.0 an unknown config key is an error, so a `test:` key exits 2 there. |
| #391, #393, #375, #373 (reload fix, parse-error fix, hook-block placement, redaction) | `CHANGELOG.md` only, among the files of this plan. | A text conflict in the Unreleased section. |
| Plan for #382 (the `tests:` map) | It needs the same expansion for each mapped test pattern. It edits the `run` branch and `docs/cli.md`. Two details differ in that plan. Its directory rule has no `test_*.rb` name. Its helper is `expand_tests`, for a list of patterns. | Land #380 first. One helper serves both: the second pull request reuses the first, as both plans say. Q5 holds the directory rule. The #382 plan stops and asks when the rules differ at merge time. |
| Plan for #379 (pair a concern with the test that mirrors its namespace) | It edits `Pairing.candidates` and `logical_path`, in the same file. | Different methods. A text conflict is not likely. |
| Plan for #381 (count sources that have no paired test) | It edits `autopair!` and the report. | No overlap. With an explicit `--test`, `autopair!` returns at once (`lib/mutineer/cli.rb:642`), so that run has no unpaired sources. |
| The version in the Action | KTD7 compares the gem version with 1.9.0. If this change ships in a different release, a gem can have that number without the change. That gem would get an unexpanded pattern. | The number has a comment in `action.yml`. The Definition of Done checks it. A release pull request with a different number must change it. |
| #398 (a coverage cache hit still runs the full clean check) | A directory makes a large test list one flag. The cache digest holds each test file (`lib/mutineer/coverage_map.rb:1418`), so a new test file under the directory starts a new capture. | No change here. One validation report says that globs make the capture set smaller. That is true only when the user passes a narrower value. |
| #360 and #282 (the not-green message, test order and seed) | The Fizzy report says that its full-suite run had 64 test files that were not green. One validation report could not find the cause. | This change makes that run easy to type. It does not fix it. The clean check and the mutant runs read the same expanded list, so the order contract does not change. |
| Files with a test name that are not tests | `test_*.rb` can match a support file. A directory can hold fixtures: 107 of the 201 name matches in this repository (probe 3). | R8 shows the count. A glob selects exactly. Q3 holds the exclude list. |
| Symlinked directories | `**` in `Dir.glob` does not enter a symlinked directory (probe 2). `expand_sources` has the same limit today. | The Fizzy clone has no symlinked directory under `test/` (probe 3). R8 shows a low count. |
| Long argument lists | With `--test-command`, each file is one argument for the user's command (`lib/mutineer/external_backend.rb:84-92`). A glob can give many files. | Fizzy has 261 test files, which is far below the limits. KTD4 keeps a directory as one argument. |

## Open Questions

All are deferred. None blocks the implementation. The maintainer (David Teren) decides each one.

- Q1. Is the Action change in KTD7 right for a minor release? Recommended default: yes. The default of `test` is `""`. A list of plain files acts the same, and an older gem acts the same. Only a glob with a 1.9.0 gem changes: `**` then matches at every depth. If the answer is no, keep the loop as it is. Say in the docs that bash expands the input and that `**` matches one level. Move the change to a draft pull request for 2.0 with the `breaking change` label.
- Q2. Should `--test-command` also receive the expanded files for a directory? Recommended default: no, keep the value as typed (KTD4). The other choice gives one rule for every backend, and it changes what the user's command receives.
- Q3. Should a directory skip `fixtures/`, `dummy/` and `system/` folders? Recommended default: no. `rails test` skips them only when it gets no path. With a path it skips nothing (railties 8.1.4, `rails/test_unit/runner.rb:116-122`, `:133-134`). A `--test` directory is such a path. Measured: 4 of the 265 files in the Fizzy clone are system tests. In this repository, 107 of the 201 are fixtures. User reports of slow or not-green directory runs would change this call.
- Q4. Should a positional source take a quoted glob too? Recommended default: not in this pull request. If the maintainer wants it, file one issue. The docs for this change do not state a limit for sources.
- Q5. Which directory rule do #380 and #382 (the `tests:` map) share? Recommended default: R1 of this plan, with `test_*.rb` (KTD3). The #382 plan states the rule of the issue text, with two suffixes only. Its own directory test passes with both rules. The two plans must agree before the second pull request merges.

## Sources and probes

- Issue #380 and Vladimir Dementyev's Fizzy report, section "Missing parts", item "`--test` accepting directories or globs".
- The three validation reports of 2026-11-09 (Sol, grok-cursor and opus). All three put #380 in 1.9.0. The opus report calls it the smallest step with no score change.
- Related plan: `docs/plans/2026-10-24-293-fix-tests-as-sources-guard-plan.md`, which states that `.mutineer.yml` has no `tests` key.

Probe scripts and their output are in `/private/tmp/claude-501/-Users-davidteren-Projects-claude-worktrees-mutineer-vladimir-issues-planning-21adcb/ae564be8-638b-4dd0-a9e5-9d7a58cb00ae/scratchpad/context/probes/380/`. That folder is on one machine and can go away. The results are below.

| Probe | Question | Result |
|---|---|---|
| 1 | What does `main` do with each form of the value, and with a `test:` key? | The table in "Problem Frame". One argument that holds two flags exits 2 with `invalid option`. `test:` and `tests:` print `unknown config key`. |
| 2 | How do Ruby, bash and zsh expand a pattern? | Ruby 3.4.9 `Dir.glob` with `**` is recursive and sorted. It expands braces, skips dot files, and does not enter a symlinked directory. Bash 5.3.15 with globstar off reads `**` as one level. It does not expand braces from a variable. With `set -f` the pattern stays. zsh stops on a glob with no match. It passes an unquoted variable as one argument. |
| 3 | Which files does the directory rule select in real trees? | Fizzy clone at `f220e4832`: 287 `.rb` files under `test/`, and 265 have a test name. All 265 end in `_test.rb`. 4 are under `test/system/`, so 261 are outside it. Nine directories and one file hold the 261. This repository at `8d9905c4`: 201 name matches under `test/`, 107 under `test/fixtures/`. |
| 4 | Does a directory work with `--test-command`? What do a blank value and a spec directory with the daemon do? | The command receives the directory, and the run exits 0. `--test ""` exits 0 with `--dry-run` and exits 2 in a run, with the project root in the message. `--rails --daemon --test spec` does not print the RSpec message, and `--test spec/calc_spec.rb` does. |
| 5 | Does `Dir.glob` keep a `./` prefix, and does a blank value expand to the root? | Yes to both. A list with `./test/a_test.rb` and `test/a_test.rb` becomes one entry when the key is the absolute path. |

Not checked: a full daemon run with a directory value, because the plan rules allow no `rake test:daemon` run. The daemon reads the same list as the in-process backend (`lib/mutineer/daemon_backend.rb:57`). Not checked: bash on a GitHub runner. The harness runs the step with `bash -e -o pipefail` as GitHub does (`test/fixtures/action_harness.sh:2`), and `set -f` is a POSIX option. Not checked: the gem version check in a real workflow. The harness stub stands in for the gem.
