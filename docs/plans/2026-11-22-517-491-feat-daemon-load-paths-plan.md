---
title: Group Q Daemon Load Paths - Plan
type: feat
date: 2026-11-22
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
target_release: v1.10.0
issues: [517, 491]
---

# Group Q Daemon Load Paths - Plan

Suggested build settings: Opus (or the strongest model in the session list), effort `high`. The work adds a public config key and a public flag, so a wrong name or a wrong default is expensive.

This plan covers two issues in one pull request, with one commit for each issue.

- Issue #517: the `--daemon` per-file coverage-capture warning shows a missing-file `LoadError` without the note about `RUBYOPT` and `RUBYLIB`.
- Issue #491, the remaining part: a `load_path:` setting and a `-I` style flag.

The hint part of #491 is already on `main` (pull request #502, and #500 in pull request #525).

---

## Goal Capsule

- Objective: A test suite that needs an extra directory on `$LOAD_PATH` runs under `--daemon` and in-process with one setting, and every `--daemon` message about a missing file says why the path is missing.
- Means: an explicit `load_path` setting that travels in the daemon boot config (KTD4), and the existing note applied to the daemon's capture warning in the stderr drain (KTD1).
- Authority: the maintainer answers the questions in "Maintainer questions". Each question has a default. The builder uses the default and does not wait.
- Execution profile: one pull request, two commits, base `main`, labels `enhancement`, `priority: medium`, `risk: medium`, `v1.10.0`. The body has `Closes #517` and `Closes #491`.
- Stop conditions: stop and report if the daemon stops deleting `RUBYOPT` or `RUBYLIB`, if a run with no `load_path` changes its `$LOAD_PATH` or its coverage digest, or if the reproduction in U3 step 0 shows a different cause than a missing load path.
- Who ships: the builder opens the pull request after the repo gates pass. A person merges. Nobody releases without a maintainer's yes.

---

## Product Contract

### Summary

Commit 1 makes the `--daemon` coverage-capture warning useful. `--verbose` now reaches the daemon's coverage build, so the warning shows the real error. The warning then gets the same note that a mutant error and the coverage-build error already get.

Commit 2 adds the `load_path` key to `.mutineer.yml` and the flag `--load-path DIR` (short form `-I DIR`). Mutineer puts those directories on `$LOAD_PATH` before it loads the boot file, the sources, the `require:` files and the tests. This works in-process and under `--daemon`. The daemon still deletes `RUBYOPT` and `RUBYLIB`.

### Problem Frame

`DaemonClient#restored_user_env` (`lib/mutineer/daemon_client.rb`) deletes `RUBYOPT` and `RUBYLIB` on purpose. Issue #100 showed that those variables carry the tool's own `-r` requires and the tool's own library paths into the app. A project that sets `RUBYOPT=-Itest/support` therefore loses that path under `--daemon`, and no setting replaces it. The only fix today is a hand-written `boot:` file.

Two findings from the code change the shape of #517.

1. The daemon never gets `verbose`. `DaemonBackend.boot_config` does not send it, and `DaemonServer#build_coverage_map` builds its `CoverageMap` with the default `verbose: false`. So the daemon's line is always `fork capture produced no result (re-run with --verbose for the error)`, and the re-run shows the same line. The issue text assumes that `--verbose` shows the `LoadError`. It does not on `main`.
2. The tool side can see the line. The daemon prints the warning to its stderr. `DaemonClient#drain_stderr` copies each line to the tool's stderr. The drain runs in the tool process, which still has the user's variables.

Two findings change the shape of #491.

1. `Config` already has a code-only field `load_paths` with the default `["lib"]`. The in-process run without a boot file uses it. It has no key and no flag.
2. The daemon boot config already has a `load_paths` key. `DaemonBackend.boot_config` fills it with `JobPlan.test_load_roots`, and `DaemonServer#boot!` puts each entry on `$LOAD_PATH` before it loads the boot file. So `require "test_helper"` already works when `test_helper.rb` is in a parent directory of the test file. The new setting is for a path that Mutineer cannot find by itself, such as `test/support` or a shared directory outside `test/`.

### Requirements

**Capture warning (#517)**

- R1. Under `--daemon --verbose`, the line `[mutineer] coverage skipped for <file>: ...` shows the real capture error, as the in-process run does.
- R2. When that line reports a missing file and the user set `RUBYLIB` or a `RUBYOPT` with `-I`, the line ends with the note from `DaemonClient.with_load_env_hint`. Only the first such line of one daemon gets the note. Later lines carry no note and no pointer to it.
- R3. The note names variables only. It never prints a value of `RUBYOPT` or `RUBYLIB`.
- R4. No other daemon stderr line changes. The `[daemon-child]` line of an errored mutant stays as it is.

**Setting and flag (#491)**

- R5. `.mutineer.yml` accepts `load_path`, a directory or a list of directories. The command line accepts `--load-path DIR` and `-I DIR`, and each can repeat.
- R6. A value on the command line replaces the list in the file, as for every other key.
- R7. Mutineer puts each directory on `$LOAD_PATH` before it loads the boot file, the sources, the `require:` files and the tests. Ruby searches them in the written order. Ruby searches the test-helper directories that Mutineer finds itself before them. In a run with no boot file, `lib` comes first, then the test-helper directories, then these directories, as `lib` and the test-helper directories are ordered today. Every place uses the same rule: the in-process parent, the capture subprocess, and the daemon.
- R8. The setting works for in-process runs and for `--daemon` runs. `--test-command` ignores it and prints the standard "has no effect" warning. That run does not check the directories.
- R9. A relative directory resolves against the project root. An absolute directory is allowed. A path that is not a directory is a usage error with exit 2. The message is `mutineer: not a directory: <absolute path> (<origin>)`, with every bad path on the one line, separated by commas. `<origin>` is `--load-path` or `load_path in .mutineer.yml`.
- R9a. The value must be a string or a list of strings. A blank entry, a key with no value, `true`, `false`, a number, a map and a nested list are usage errors with exit 2. `load_path: []` is valid and means no directory. The message comes from `Config.parse`, so it has that method's two forms:
  - flag: `--load-path must name a directory, not blank (got: "")`;
  - file: `.mutineer.yml: load_path must name a directory, not blank (got: nil)`;
  - wrong shape, file: `.mutineer.yml: load_path must be a directory or a list of directories (got: <value>)`.
- R10. The daemon still deletes `RUBYOPT` and `RUBYLIB` from its environment. Mutineer never reads a load path from those variables. The directories travel in the boot config, not in the environment.
- R11. A run with no `load_path` and no flag behaves as before: the same `$LOAD_PATH`, the same daemon boot config, the same coverage cache digest.
- R12. The note from `DaemonClient.with_load_env_hint` names `load_path` and `-I` as the fix. Its text is `(the daemon does not pass <names> to the app; if the missing file is in a directory set there, add that directory with load_path: in .mutineer.yml or with -I DIR, see <LOAD_PATH_GUIDE>)`. The condition stays in the text, because the note reads only the error and the environment. It can appear after `load_path` is set, when a different file is missing. `<names>` is `RUBYOPT`, `RUBYLIB`, or `RUBYOPT or RUBYLIB`, as today. Every place that prints the note uses this one text: a mutant's `details`, the coverage-build message, the clean-check message, and the capture warning.

**Contract copies**

- R13. Every copy of the flag list and the key list names the new flag and key: `mutineer --help`, `docs/cli.md`, `STABILITY.md`, `docs/rails-setup.md`, and `CHANGELOG.md`.

### Acceptance Examples

- AE1. Covers R7, R8, R10.
  - **Given:** a Rails fixture test that requires a file that is only in `extra_load_path/`, and `RUBYOPT=-Iextra_load_path` in the environment.
  - **When:** the run uses `--daemon` with no `load_path`.
  - **Then:** every mutant scores `error`, and `details` carries the note.
  - **When:** the same run has `load_path: extra_load_path`.
  - **Then:** the mutants score `killed` or `survived`, none scores `error`, and the daemon process has no `RUBYOPT`.
- AE2. Covers R7, R8.
  - **Given:** the same test, with no `RUBYOPT`.
  - **When:** the run is in-process with `-I extra_load_path`.
  - **Then:** the verdicts match the `--daemon` run with the same setting.
- AE3. Covers R9, R9a.
  - **When:** `mutineer run lib -I no/such/dir` in `/work/app`.
  - **Then:** stderr has `mutineer: not a directory: /work/app/no/such/dir (--load-path)`, and the exit code is 2.
  - **When:** `mutineer run lib -I ""`.
  - **Then:** stderr has `mutineer: --load-path must name a directory, not blank (got: "")`, and the exit code is 2.
- AE4. Covers R8.
  - **When:** `--test-command` runs with `load_path: no/such/dir` in the file.
  - **Then:** stderr has `[mutineer] load_path in .mutineer.yml has no effect with --test-command (it applies to in-process and --daemon runs); ignoring it.` The run does not exit 2 for the missing directory.
  - **When:** the same run has `-I test/support` on the command line.
  - **Then:** the warning starts with `[mutineer] --load-path has no effect with --test-command`.
- AE5. Covers R1, R2, R3.
  - **Given:** `RUBYLIB=test/support` and a daemon whose test file cannot load its helper.
  - **When:** the run uses `--daemon --verbose`.
  - **Then:** the first `coverage skipped` line shows `LoadError: cannot load such file` and the note, with no `test/support` in the note.
  - **When:** the run has no `--verbose`.
  - **Then:** the line reads `fork capture produced no result (re-run with --verbose for the error)` and has no note.

### Scope Boundaries

- No change to which variables the daemon deletes.
- No automatic copy of `-I` paths out of `RUBYOPT` or `RUBYLIB`. Mutineer cannot tell an app path from a tool path there, and `RUBYOPT` can hold a secret.
- No change to `mutineer init` output. Only a suite with a custom load path needs the key.
- No new GitHub Action input. `extra-args` and `.mutineer.yml` already carry the setting.
- No new JSON report key. The JSON `schema_version` stays `1.11`.
- No `load_path` support for `--test-command` (see "Limits left open").

### Maintainer questions

The builder uses each default. None of these blocks the work.

- Q1. Does the setting apply to the daemon only, or to in-process runs too?
  - Default: in-process and `--daemon`. `--test-command` ignores it with a warning.
  - Cost of the default: #491 reports only `--daemon`, and `RUBYOPT=-I` still works in-process. The in-process half adds the three `lib/mutineer/runner.rb` edits, KTD7, the in-process order tests, the R11 argument test, the `test/runner_test.rb` pair and AE2.
  - Why: one key then has one meaning. A project keeps the same file when it adds or removes `--daemon`, and when 2.0 makes the daemon the default under `--rails`. A daemon-only key would warn on every in-process run and would still need `RUBYOPT` there.
  - Other choice: daemon only. Then drop the `lib/mutineer/runner.rb` part of U3 and add `extra_load_paths` to the "has no effect" warning for runs without `--daemon`.
- Q2. Are the names right: key `load_path`, flag `--load-path DIR`, short form `-I DIR`?
  - Default: yes, all three.
  - Why: every existing pair is `snake_key` and `--kebab-flag` (`cache_dir` and `--cache-dir`). `-I` is what `ruby`, `rake` and `rspec` use, and it is what users already have in `RUBYOPT`.
  - Other choice: `-I` only, or `--load-path` only.
- Q3. Is a missing directory an error, and may a directory be outside the project?
  - Default: a missing directory exits 2. An absolute path and a path outside the project root are allowed.
  - Why: a typed path that does nothing is a silent failure, and a missing `boot:` file already exits 2. `boot:` and `cache_dir` already accept paths outside the root, and a shared test-support directory in a monorepo is a real case.
  - Other choice: ignore a missing directory, as `ruby -I` does.
- Q4. Does `-I` on the command line replace the file's list or add to it?
  - Default: replace. `Config.resolve` merges the command line over the file for every key.
  - This differs from `ruby -I`, which only adds. So the help text, the `docs/cli.md` row and the pull request body all say "replaces `load_path:` in `.mutineer.yml`".
  - Other choice: add. That needs a special case in `Config.resolve`.
- Q5. For #517, is a note under `--verbose` enough?
  - Default: yes. Without `--verbose` the daemon line stays generic, as in-process, and tells the user to re-run with `--verbose`. That re-run now works and shows the error and the note.
  - Cost of the default: the user runs the coverage build twice to see the cause. A new issue tracks the note without `--verbose` (see "Limits left open").
  - Not done on purpose: a note on the generic line. That line has no error text, so the note would also appear for a capture that failed for another reason.
  - Other choice: send each capture's real error in the coverage reply, and print the note without `--verbose`. That adds state to `CoverageMap` and a second printed line for each file.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The stderr drain adds the note for #517.** `DaemonClient#write_redacted_piece` already rewrites each daemon stderr line on the tool side. It applies `DaemonClient.with_load_env_hint` to a line that starts with `[mutineer] coverage skipped for `. This needs no protocol change. The two ideas in the issue both need new state: reasons in the coverage reply need storage in `CoverageMap` and print each file twice, and variable names in the boot config need the note text and the match rule on the app side.
- KTD2. **`verbose` travels in the boot config.** `DaemonBackend.boot_config` sends `verbose: config.verbose`. `DaemonServer#build_coverage_map` passes it to `CoverageMap.new`. `@verbose` is read only in `CoverageMap::Capture#accept_fork_payload` and in the subprocess scripts, so the digest does not change.
- KTD3. **The note appears once for each daemon client.** A suite that cannot load its helper fails every capture. One long note on every line hides the errors. The cost is one instance variable. The other choice is a note on every matching line with no state, as each errored mutant has in `details`.
- KTD4. **The directories travel in the existing boot config key `load_paths`.** `DaemonBackend.boot_config` sets it to `JobPlan.extra_load_dirs(config).reverse + JobPlan.test_load_roots(abs_tests)`. `DaemonServer#boot!` unshifts one entry at a time, so the last entry is searched first. The reversed user list in front gives R7's order with no change to `daemon_server.rb`. With no user directory the value is the same as today (R11). The daemon's `CoverageMap` already digests this key.
- KTD5. **A new `Config` field `extra_load_paths` holds the user's list.** The config key is `load_path` and the flag is `--load-path`, as `require` maps to `require_paths`. The existing code-only field `load_paths` (default `["lib"]`) stays as it is. Reusing it would either drop `lib` for a user who sets the key, or put `lib` on the path in boot mode where it is not today.
- KTD6. **One helper resolves the list.** `JobPlan.extra_load_dirs(config)` returns the absolute directories. Every place that touches `$LOAD_PATH` or the disk calls it: the runner's unshift, the daemon boot config and the CLI check. The two in-process `CoverageMap.new` calls get the list as the user wrote it, because the in-process digest must not depend on the checkout path (the existing comment in `Runner.execute` says so). `CoverageMap#absolute` expands it against the same project root.
- KTD7. **In-process, one early `$LOAD_PATH.unshift(*dirs)` in `Runner.execute`.** It is one call with a splat, so the written order holds. A loop of single unshifts would reverse it. It has no `include?` filter, unlike the two existing unshift sites in that method. The capture subprocess and the daemon do not filter, and a filter in the parent alone would give the parent a different order when the user keeps the same directory in `RUBYLIB`. A repeated library call then adds a duplicate entry, which does no harm. It runs before the boot file and the sources load. The later unshift of the test-helper roots then puts those roots first, which gives the same order as KTD4.
- KTD8. **The directories never go into `RUBYLIB`.** See "Security check against #100".
- KTD9. **The CLI validates the directories.** `CLI.validate_paths!` already turns a missing source or test into exit 2. It skips the directory check when `--test-command` is set, because that run ignores the setting and only warns. `Runner.execute` as a library call does not validate, as for sources.

### Security check against #100

Issue #100 fixed this hazard: the daemon inherited the tool's `RUBYOPT` (a `-r` require ran tool-only code inside the app) and the tool's `RUBYLIB` and Bundler settings.

The new setting does not reopen it, for these reasons.

- It is explicit. A person writes it for the app. Nothing is inherited from the tool's environment.
- It holds directories only. It has no `-r` form, so the setting itself runs no code.
- It gives no new power. `boot:` and `require:` already load any project file. A person who can edit `.mutineer.yml` can already run code in the app.
- It does not use the environment. A value in `RUBYLIB` would also reach every subprocess the app starts, and it would end the invariant "the daemon has no `RUBYLIB`". The boot config reaches only the daemon's own `$LOAD_PATH`.
- `DaemonClient#restored_user_env` and `DaemonClient::LOAD_ENV` do not change. `test/daemon_client_env_test.rb` keeps its assertions that `RUBYOPT` and `RUBYLIB` are absent, and U3 adds a run that asserts both facts together.

### Sequencing

1. Commit 1, issue #517 (U1). It is a small bug fix and does not depend on the setting.
2. Commit 2, issue #491 (U2, U3, U4). `test/docs_contract_test.rb` fails when `STABILITY.md` does not list a new config key, so code and docs go in the same commit.

Suggested commit titles:

```text
fix: show the capture error and the load-variable note in the --daemon coverage warning (#517)
feat: load_path setting and -I flag put directories on $LOAD_PATH (#491)
```

### Assumptions

- The reporter's layout in #491 is not known. `JobPlan.test_load_roots` already finds `test/` when `test/test_helper.rb` exists, so a plain `RUBYOPT=-Itest` layout should not fail on `main`. U3 step 0 checks this before any code changes.
- Booting `config/environment` in the Rails fixture does not put `test/` on `$LOAD_PATH`. U1's daemon test depends on this. The builder confirms it with the first failing test.
- No test or CI job runs every file under `test/fixtures/rails_app/test/`, and no fixture run pairs sources with tests by convention in a way that finds the new file. The tests in `Rakefile` `DAEMON_TESTS` name explicit files. The builder confirms both before adding a fixture test file.

### Risks

| Risk | Effect | Mitigation |
| --- | --- | --- |
| `--l` becomes ambiguous between `--list-operators` and `--load-path` | `mutineer --l` exits 2. `--li` and `--list` still work | Say so in the pull request body. No doc uses `--l` |
| `-I` on the command line replaces the file's list, but `ruby -I` adds | A user who adds `-I extra` in CI loses the directories in `.mutineer.yml` | The help text, `docs/cli.md` and the pull request body say "replaces" (Q4) |
| `-I` is the first short flag in this CLI | A new style in `mutineer --help` | Say so in the pull request body (Q2) |
| The drain matches the warning by its text | A reworded warning loses the note silently. A warning that follows app output with no final newline does not start the line, and also loses it | A test feeds the drain a line that the real `CoverageMap#fail_test` printed |
| The user directories sit behind the test-helper roots | A file name that exists in both resolves to the test root | State the order in `docs/cli.md`. It matches what `RUBYOPT=-I` gives in-process today |
| A user directory can hide a gem or stdlib file in the tool process in-process | The run loads the user's file | Same as `RUBYOPT=-I` today. No new exposure |
| `--verbose` now changes the daemon's capture lines | More text on stderr under `--verbose` | `CoverageMap#fail_test` and the drain both redact the line |
| `rake test:daemon` skips PostgreSQL and MySQL tests without a server | Local run is not the full gate | CI runs them. Say so in the pull request body |
| `rake/fizzy_sample.json` counts | They must not move, because the sample sets no `load_path` | No run needed for this pull request. The release check runs it |

---

## Implementation Units

### U1. Capture warning note and `--verbose` in the daemon (commit 1, #517)

- **Goal:** R1, R2, R3, R4.
- **Requirements:** R1 to R4, AE5, KTD1, KTD2, KTD3.
- **Files and functions:**
  - `lib/mutineer/daemon_backend.rb`, `DaemonBackend.boot_config`: add `verbose: config.verbose`. Update its doc comment.
  - `lib/mutineer/daemon_server.rb`, `DaemonServer#build_coverage_map`: pass `verbose: @cfg["verbose"] == true` to `CoverageMap.new`. Add `"verbose"` to the boot line in the protocol comment at the top of the file.
  - `lib/mutineer/daemon_client.rb`:
    - New constant for the warning's start, `[mutineer] coverage skipped for `, with a comment that names `CoverageMap::Capture#fail_test` as the writer.
    - `DaemonClient#write_redacted_piece`: after `Redaction.text`, give each line that starts with the constant to `self.class.with_load_env_hint`, until one line got the note. Keep the state in one instance variable. Later lines pass through unchanged (R2). A piece can hold several lines when a password form has a newline, so check each line of the piece.
    - Update the doc comment of `DaemonClient.with_load_env_hint` and of `@param boot` in `#initialize`.
  - `lib/mutineer/coverage_map/capture.rb`, `CoverageMap::Capture#fail_test`: comment only. Say that `DaemonClient` matches this prefix (#517).
- **Test scenarios:**
  - `test/daemon_backend_contract_test.rb`: `boot_config` carries `verbose` as `true` and as `false`.
  - `test/coverage_map_test.rb`: two `CoverageMap` objects for one temp project, one with `verbose: true` and one with `verbose: false`, give the same cache digest. This proves KTD2's claim, so `--verbose` does not rebuild a user's cache.
  - `test/daemon_redaction_test.rb`, with its `drain` helper and `with_env`:
    - A line printed by the real `CoverageMap#fail_test` (call it and capture stderr) with a `LoadError: cannot load such file` reason, and `RUBYLIB` set: the output has the note once. A second such line has no note.
    - The value of `RUBYLIB` and of `RUBYOPT` is not in the output.
    - A `[daemon-child] LoadError: cannot load such file -- x` line is unchanged.
    - With no load variable set, the line is unchanged.
    - The generic line `fork capture produced no result (re-run with --verbose for the error)` is unchanged.
    - A piece with two lines, the second one the warning: the second line gets the note.
  - `test/daemon_coverage_test.rb` (runs under `rake test:daemon`): start a real daemon with `load_paths: []` and `RUBYLIB` set. With `verbose: true` the client's `errio` has `fork capture failed: LoadError: cannot load such file -- test_helper` and the note. With `verbose: false` it has the generic line and no note.
- **Docs:** `docs/rails-setup.md`, "Load paths" row: add that with `--verbose` the per-file coverage warning carries the same note.
- **CHANGELOG:** `## [Unreleased]`, `### Fixed`. Two facts: `--verbose` now reaches the daemon's coverage build, and the warning carries the note (#517).
- **Verification:** the new tests fail before the change and pass after it. The first test to write is the `verbose: true` daemon test, because it proves finding 1 in the Problem Frame.

### U2. Config key and flag (commit 2, #491)

- **Goal:** R5, R6, R9, and the `--test-command` part of R8.
- **Requirements:** R5, R6, R8, R9, R9a, AE3, AE4, KTD5, KTD9.
- **Files and functions:**
  - `lib/mutineer/config.rb`:
    - `CONFIG_OPTIONS`: add `ConfigOption.new(field: :extra_load_paths, type: :string_list, yaml_key: "load_path", flag: "--load-path")`.
    - `Config` struct: add `:extra_load_paths`. Default `[]` in `#initialize`. Add a paragraph to the struct comment that tells `extra_load_paths` (user) from `load_paths` (code only).
    - `Config.parse`, `:string_list` branch: for `extra_load_paths`, check the raw value before `Array(value).map(&:to_s)`. It must be a `String` or an `Array` of `String`. A blank entry, `nil`, `true`, `false`, a number, a `Hash` and a nested list raise `ConfigError` with the R9a texts. This follows the `operators` check in the same branch. `[]` stays valid. Without the shape check, `load_path: {a: b}` becomes the entries `a` and `b`, which the user never wrote.
  - `lib/mutineer/cli.rb`:
    - `CLI.start`: `o.on("-I DIR", "--load-path DIR")`. Each use appends to `opts[:extra_load_paths]` through `Config.parse`. The existing `rescue` around `parser.parse!` prints a `ConfigError` and exits 2.
    - `BANNER`: add this entry, in the style of `--cache-dir`:

      ```text
      --load-path DIR, -I DIR  Put DIR on $LOAD_PATH before the boot file, the sources
                           and the tests (repeat for more; relative to the project
                           root; replaces load_path: in .mutineer.yml; not with
                           --test-command)
      ```

    - `CLI.validate_paths!`: for each entry of `JobPlan.extra_load_dirs(config)` that is not a directory, collect it, then print the R9 line and exit 2. Skip this check when `config.test_command` is set (KTD9).
    - `UNUSED_SETTING_SCOPE`: add `extra_load_paths: "in-process and --daemon runs"`.
    - `CLI.validate_test_command!`: add `:extra_load_paths` to the `warn_unused_settings` list. The warning keeps the standard shape. The next step for the user (`-I` in the test command itself) goes in the `docs/cli.md` row.
- **Test scenarios:**
  - `test/config_test.rb`: a string value, a list value, `[]` (valid), no value (error, with the file form of the message), `[""]` (error), `true` (error), `1`, `{a: b}` and `[[a, b]]` (shape errors), `KNOWN_KEYS` has `load_path`, the command line replaces the file list, `origin` gives `--load-path` or `load_path in .mutineer.yml`.
  - `test/cli_test.rb`: `-Idir`, `-I dir`, `--load-path dir`, `--load-path=dir`, and two flags in one command all reach the config. A missing directory exits 2 with the exact R9 line, including the absolute path. Two bad directories print on one line. A file path (not a directory) exits 2. `-I ""` exits 2 with the R9a line. `-I` with no value exits 2. The `--help` entry has `-I`, `--load-path`, `replaces` and `--test-command`.
  - `test/runner_external_test.rb`: the "has no effect with --test-command" warning for the flag and for the file key. A missing `load_path` directory with `--test-command` prints only that warning and does not exit 2.
- **Verification:** `bundle exec rake test` and `bundle exec rake yard:strict`.

### U3. Apply the directories in both backends (commit 2, #491)

- **Goal:** R7, R8, R10, R11, R12.
- **Requirements:** R7, R8, R10, R11, R12, AE1, AE2, KTD4, KTD6, KTD7, KTD8.
- **Step 0, before any code:** reproduce the failure on the Rails fixture under `--daemon` with a test that requires a file outside every test-helper root. Record the verdict word of each mutant. AE1 expects `error`. If the run gives another word, correct AE1 and the test to the word the run gives, and say so in the pull request body. Then run a second case: a plain test under `test/` that requires `test_helper`, with `RUBYOPT=-Itest`. The second case must pass on `main`. If it fails, `JobPlan.test_load_roots` or `DaemonServer#boot!` has a different bug. Stop and report it.
- **Files and functions:**
  - `lib/mutineer/job_plan.rb`: new `JobPlan.extra_load_dirs(config)`. It returns `config.extra_load_paths`, each expanded against `config.project_root`.
  - `lib/mutineer/daemon_backend.rb`, `DaemonBackend.boot_config`: `load_paths:` becomes the reversed user directories followed by `JobPlan.test_load_roots(abs_tests)`. The comment explains the order (KTD4).
  - `lib/mutineer/runner.rb`, `Runner.execute`:
    - One `$LOAD_PATH.unshift(*JobPlan.extra_load_dirs(config))` call above the `if config.boot` branch, with no `include?` filter (KTD7, R7).
    - Boot branch: `CoverageMap.new(load_paths: config.load_paths + config.extra_load_paths, ...)`.
    - No-boot branch: `load_paths: config.load_paths + rel_roots + config.extra_load_paths`. The capture subprocess builds its own `$LOAD_PATH` from this list, in this order.
  - `lib/mutineer/daemon_client.rb`:
    - `DaemonClient.with_load_env_hint`: the note takes the R12 text. The words `does not pass <names> to the app` stay, so the existing assertions on them still hold.
    - `LOAD_PATH_GUIDE`: point it at the new docs block, `docs/rails-setup.md#extra-load-paths` (U4).
    - Update the comment on `LOAD_ENV`.
  - `lib/mutineer/daemon_server.rb`: comment only. The protocol comment says that `load_paths` also carries the user's directories.
- **Fixture:** `test/fixtures/rails_app/extra_load_path/load_path_probe.rb`, and `test/fixtures/rails_app/test/load_path/load_path_probe_test.rb` that requires `test_helper` and `load_path_probe`. The test file must kill at least one `app/models/order.rb` mutant, and the test that uses it states the exact verdict counts. The file name must not match `order_*_test.rb`: `lib/mutineer/pairing.rb` pairs that pattern with `app/models/order.rb`, and a paired run would then fail without the setting. Keep the probe directory outside `test/`, so no test-helper root finds it.
- **Test scenarios:**
  - `test/daemon_backend_contract_test.rb`: with `extra_load_paths: %w[a b]`, `boot_config[:load_paths]` starts with the absolute `b`, then `a`, then the test roots. With none, the whole hash equals today's hash plus the `verbose` key from U1.
  - Order rule, zero-dependency: a temp project with a test-helper root and two, then three, extra directories. Every directory holds `shared_name.rb`. Assert the real `$LOAD_PATH` in three places:
    - after `Runner.execute` starts in-process, with `boot:` and without it;
    - in the no-boot capture subprocess, through which copy of `shared_name.rb` the test loads;
    - in a real `DaemonServer` that boots with `DaemonBackend.boot_config` for that project. Use the `daemon_boot` pattern in `test/daemon_redaction_test.rb`: the boot file writes `$LOAD_PATH.first(5)` to a file.
    - Expected, as relative positions and not as the first entries: with a boot file and in the daemon, the test-helper roots come before the extra directories. With no boot file, in the parent and in the capture subprocess, `lib` comes first, then the test-helper roots, then the extra directories. The extra directories keep the written order in every place.
    - In-process with a boot file, read `$LOAD_PATH` from a test file, not from the boot file. `Runner.execute` adds the test-helper roots after the boot file loads.
    - One more case: `RUBYLIB` holds extra directory `a`, and `load_path` is `[a, b]`. The parent, the no-boot capture subprocess and a mutant fork all load the copy of `shared_name.rb` in `a`. This case proves that no place filters a directory that is already on `$LOAD_PATH`.
  - `test/runner_daemon_test.rb` (under `rake test:daemon`): AE1 in full, through `Runner.execute`, with `RUBYOPT=-I...` set in the test's environment. Assert the verdict counts with the setting, zero `error` results, and the exact R12 note in `details` without it.
  - AE2: the same fixture in-process (`rake test:daemon`, because it boots Rails), with `strategy: "reload"` set. `Config.resolve` picks `redefine` for `--rails` without `--daemon`, and the daemon always reloads. The verdict set equals the `--daemon` run's set.
  - `test/daemon_client_env_test.rb`: update the note assertions from `boot:` to the R12 text. The assertions that `RUBYOPT` and `RUBYLIB` are absent stay unchanged.
  - A zero-dependency in-process test (`test/runner_test.rb`, temp project, no Rails): a test file requires a feature from an extra directory. Without the setting the capture fails. With the setting the mutant is `killed`. Run it once with `boot:` and once without.
  - R11, argument: a test that records the `load_paths:` argument `Runner.execute` gives `CoverageMap.new` (Minitest `stub`), for a config with no `extra_load_paths`. The value must equal today's value in both branches.
- **Verification:** `bundle exec rake test`, then `bundle exec rake test:daemon`.

### U4. Docs and contract copies (commit 2, #491)

- **Goal:** R13.
- **Requirements:** R13.
- **Files:**
  - `docs/cli.md`: one row in the flag table (`--load-path DIR`, `-I DIR`), one row in the Configuration table (`load_path`), and a row in the validation table for R9 and R9a. The rows state: the order (R7), the backends (R8), relative to the project root, exit 2 for a path that is not a directory, the command line replaces the file list, and that a `--test-command` user passes `-I` in the test command itself.
  - `STABILITY.md`, "Config keys": add `` `load_path` `` with "new in 1.10.0", its flag, and "`--test-command` ignores it". `test/docs_contract_test.rb` (`test_stability_lists_every_config_key`) fails without it.
  - `docs/rails-setup.md`:
    - New short block with the heading "Extra load paths", below the `--daemon` feature table. The note links here, so a user who comes from the error finds text to copy. It has:
      - "Mutineer 1.10.0 and later", a `.mutineer.yml` example (`load_path: [test/support]`) and the command form (`--daemon -I test/support`).
      - One sentence that `RUBYOPT=-Itest/support` becomes `load_path: test/support`.
      - A link to the `load_path` row in `docs/cli.md` for the order rule. Do not repeat the rule here, so it has one copy.
      - One sentence that the note can still appear after `load_path` is set, when a different file is missing.
      - One sentence for Mutineer 1.9 and earlier: set `boot:` to a file that adds the path and then loads `config/environment`. The released 1.9 gem prints a note that names this `boot:` fix and links to this page.
    - Keep the heading "Faster, parallel-safe Rails (the `--daemon` backend)" unchanged. The 1.9 gem links to its anchor.
    - "Load paths" row of the table: one sentence that the daemon does not pass `RUBYOPT` or `RUBYLIB`, and a link to the new block. Move the `boot:` workaround into the block, and remove the sentence "A setting for this is open in #491".
  - `docs/json-schema.md`, the `details` paragraph: check the sentence about the note. Add that the note names `load_path`.
  - `CHANGELOG.md`, `## [Unreleased]`, `### Added`: the key, the flag, the backends, the order, exit 2 for a missing directory, `--test-command` ignores it (with the issue from "Limits left open"), and that `RUBYOPT` and `RUBYLIB` are still not passed (#100).
  - `.expectation-fit/decisions/daemon-and-worker-databases.md`: one new line, written by hand, with no cubic id. Text: "**Daemon Load Paths Come From Config.** When reviewing how the daemon gets a load path, verify that it comes from `load_path` or `-I` through `DaemonBackend.boot_config`, and that `DaemonClient#restored_user_env` still deletes `RUBYOPT` and `RUBYLIB` (#100, #491)."
- **No change, with the reason:**
  - `README.md`: its Options table is a short list that links to `docs/cli.md`.
  - `lib/mutineer/init.rb`: see Scope Boundaries.
  - `action.yml`: no new input. Its `extra-args` checks match prefixes of `--cache-dir`, `--format` and `--output` only.
  - `docs/rails.md`, `docs/rails.html`, `docs/comparison.md`: they do not describe load paths. The author self-check lists any stale copy.
- **Verification:** the website checks in the Verification Contract, because `docs/*.md` feeds the site build.

---

## Verification Contract

| Gate | Command | Applies to |
| --- | --- | --- |
| Zero-dependency suite | `bundle exec rake test` | both commits |
| Load smoke | `ruby -Ilib -e 'require "mutineer"'` | both commits |
| 100% YARD docs | `bundle exec rake yard:strict` | both commits. Every new method and constant needs a comment |
| Daemon integration | `bundle install` in `test/fixtures/rails_app`, then `bundle exec rake test:daemon` | both commits |
| Site build | `bundle exec rake site:build` | commit 2, and commit 1 for its `docs/rails-setup.md` line |
| Site tests | `node --test test/site_test.js` | same |
| Browser tests | `npm ci --prefix test/browser`, `npx --prefix test/browser playwright install chromium`, `npm test --prefix test/browser` | same |
| Author self-check | `ruby .claude/skills/author-self-check/self_check.rb origin/main`, then steps 2 to 6 of `.claude/skills/author-self-check/SKILL.md` | before the first push |

Not needed: the Minitest 6 run (no change to the Minitest integration), the Prism 2 run (no parse change), and `rake fizzy:sample` (a release check).

The pull request then follows "PR review gate" in `AGENTS.md`.

---

## Definition of Done

- R1 to R13 hold, and each acceptance example has a test that asserts the mechanism: the line text, the verdict words, the boot config order, the exit code with the message.
- The daemon environment tests in `test/daemon_client_env_test.rb` still pass with no weaker assertion.
- A run with no `load_path` gives the same boot config and the same `CoverageMap` `load_paths` as `main` (R11 test).
- Every gate in the Verification Contract is green on the pull request head.
- Each limit in "Limits left open" has an issue number in the CHANGELOG entry or the doc line that states it.
- The pull request has two commits, one for #517 and one for #491, and no code from an abandoned attempt.
- No `eval`, no runtime dependency, no change to `DaemonClient::LOAD_ENV`.

---

## Limits left open

The rule "Track every limitation" in `.expectation-fit/ways-of-working.yaml` needs an issue number in the same change. Before the first push, the builder followed these steps. They gave the issue numbers #535, #536 and #537:

1. File the three new issues in the table.
2. Search the open issues for the two existing limits in the table. Cite the issue that exists, or file one.
3. Put each number in the CHANGELOG entry or the doc line that states the limit.

| Limit | Issue |
| --- | --- |
| `--test-command` ignores `load_path`. It also clears every `RUBY*` variable for its child (`ExternalBackend.clear_env_key?`), and a missing-file failure there has no note. The user's command can pass `-I` itself | #535. New issue. Suggested title: "--test-command: no load_path support and no note when it drops RUBYOPT and RUBYLIB" |
| The coverage digest sorts its load paths (`CoverageMap` in `coverage_map/cache.rb` and `coverage_map/skeleton_digest.rb`). A changed order of `load_path` entries does not rebuild the map. It matters only when two entries hold the same file name. Estimate: rare | #536. New issue. Suggested title: "Coverage cache does not rebuild when load_path entries change order" |
| Without `--verbose`, the daemon's capture warning shows no error and no note. The user runs the coverage build a second time with `--verbose` to see the cause | #537. New issue. Suggested title: "--daemon: show the capture error's load-variable note without --verbose". Cite it in the `docs/rails-setup.md` line and the #517 CHANGELOG entry |
| The Action's `extra-args` splits on spaces, so a `-I` path with a space cannot pass through it. The `load_path` key works | Existing limit of `extra-args` for every flag. No doc line in this change states it, so no issue |
| `--daemon` supports Minitest only, so `load_path` under `--daemon` does too. `CLI.validate_daemon!` already rejects RSpec | Existing limit. No new doc line states it, so no issue |
| The `[daemon-child]` stderr line of an errored mutant has no note. The mutant's `details` has it | By design (R4). No issue |

---

## Sources

- Issues: #517, #491, #100 (why the daemon deletes the variables), #500 (the note on the coverage build and the clean check).
- Pull requests: #502 (the note on a mutant's cause), #525 (#500).
- `lib/mutineer/daemon_client.rb`: `LOAD_ENV`, `restored_user_env`, `with_load_env_hint`, `drain_stderr`, `write_redacted_piece`.
- `lib/mutineer/daemon_server.rb`: `boot!` (the `load_paths` unshift, before the boot file), `build_coverage_map`.
- `lib/mutineer/daemon_backend.rb`: `boot_config`, `coverage_map_from_client`, `warn_coverage_fallback`.
- `lib/mutineer/coverage_map/capture.rb`: `accept_fork_payload`, `fail_test`.
- `lib/mutineer/job_plan.rb`: `test_load_roots`.
- `lib/mutineer/runner.rb`: `Runner.execute`, the two `CoverageMap.new` calls and the two `$LOAD_PATH.unshift` sites.
- `lib/mutineer/config.rb`: `CONFIG_OPTIONS`, `Config.parse`, `Config.resolve`.
- `lib/mutineer/cli.rb`: `BANNER`, `CLI.start`, `validate_paths!`, `validate_test_command!`, `UNUSED_SETTING_SCOPE`.
- `test/docs_contract_test.rb`: `test_stability_lists_every_config_key`.
- Rules: `AGENTS.md`, `.expectation-fit/ways-of-working.yaml`, `.expectation-fit/decisions/daemon-and-worker-databases.md`, `redaction-and-security.md`, `cli-contract-and-exit-codes.md`, `docs-and-changelog.md`.
