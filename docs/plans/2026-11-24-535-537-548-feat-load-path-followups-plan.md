---
title: "Group 11-D: Load-path follow-ups - Plan"
type: feat
date: 2026-11-24
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
target_release: v1.11.0
issues: [535, 537, 548]
---

# Group 11-D: Load-path follow-ups - Plan

- **What:** Three follow-ups to the `load_path` setting from 1.10.0 (pull request #542), in one pull request for 1.11.0.
- **Why:** `--test-command` ignores `load_path`, the `--daemon` capture warning hides the error without `--verbose`, and the docs name a cache limit with no way out.
- **How:** `--test-command` gets the directories in `RUBYLIB`. A failed fork capture prints its error in one line. The cache key does not change: the docs state the rule and the remedy.

Build settings: Opus 5.5, effort `medium` (as in `WORKLIST.md`). The plan names each function and each test, so no higher effort is needed.

Planned against `main` at `c5100143`. One pull request, one commit for each issue, in the order U1, U2, U3.

**Public contract changes (U1 only):**

1. The config key `load_path` and the flag `--load-path` / `-I` now apply to `--test-command` runs. 1.10.0 ignored them there with a warning.
2. The stderr warning `... has no effect with --test-command ...` no longer appears for `load_path`. A new warning names an entry that `--test-command` cannot use.
3. No run gets a new exit 2 in 1.11.0. `STABILITY.md` gets one new planned break for 2.0: such an entry then exits 2 (D2). A run that failed its smoke check on 1.10.0 because `load_path` was ignored can now pass.

U2 changes stderr text only. U3 changes docs only. No JSON schema change. `schema_version` stays as it is.

---

## Goal Capsule

- **Objective:** One `load_path` setting works in all three backends, and a failed capture says why in the first run.
- **Means:** `ExternalBackend.child_env` sets `RUBYLIB` to the `load_path` directories (KTD1). The smoke check names a missing file and the likely cause in its first sentence (KTD3). The fork capture child sends a one-line cause without `--verbose` (KTD4). The cache key stays as it is (KTD6).
- **Authority:** `AGENTS.md`, then `.expectation-fit/ways-of-working.yaml` and `.expectation-fit/decisions/`, then this plan, then the issue texts.
- **Execution profile:** One branch `feat/535-load-path-followups`, one worktree, one pull request against `main`, ready for review (not a draft). Labels: `enhancement`, `priority: low`, `risk: low`, `v1.11.0`. Body: `Closes #535`, `Closes #537`, `Refs #548`.
- **Who ships:** The builder opens the pull request. David merges. No release step.
- **Stop conditions.** Stop and report, do not work around:
  - `ExternalBackend.child_env` with no `load_path` gives a different hash than on `main`.
  - A `--test-command` child sees the tool's or the user's own `RUBYOPT` or `RUBYLIB` value.
  - The daemon note text changes by one character. These tests pin it: `test/daemon_client_env_test.rb`, `test/runner_daemon_test.rb`, `test/daemon_backend_contract_test.rb`, `test/daemon_coverage_test.rb`, `test/daemon_redaction_test.rb`.
  - A coverage cache digest changes for any run.

---

## Reproductions (done by the planner, on `main` at `c5100143`)

Each defect was reproduced with a probe before the fix was planned.

| Issue | Probe | Result on `main` |
| --- | --- | --- |
| #535, part 1 | Temp project. The test requires `probe_helper`, which is only in `support/`. `mutineer run lib/calc.rb --test test/calc_test.rb -I support --test-command "ruby %{files}"` | stderr: `[mutineer] --load-path has no effect with --test-command (it applies to in-process and --daemon runs); ignoring it.` Then the smoke check fails with `cannot load such file -- probe_helper (LoadError)`. Exit 1. |
| #535, part 2 | The same project with `RUBYLIB=$PWD/support` and no `-I` | The smoke check fails the same way. No line names `RUBYLIB`. The same command without `--test-command` passes with score 100%. |
| #535, mechanism | `Process.spawn(ExternalBackend.child_env.merge("RUBYLIB" => "<dir with a space>"), "ruby", ...)` | The child loads the file. `bundle exec` and the rbenv shim put their own entry in front and keep ours. Under `bundle exec ruby`, the entry is at `$LOAD_PATH` index 2 and the first gem at index 3. |
| #537 | Boot-mode `CoverageMap#build_via_fork` (the code the daemon runs) on a test that requires a missing file, then the line through `DaemonClient#write_redacted` with `RUBYLIB` set | `verbose: false`: `coverage skipped for calc_test.rb: fork capture produced no result (re-run with --verbose for the error)`, and the drain adds no note. `verbose: true`: the error and the note. |
| #548, a | `CoverageMap` with `extra_load_paths: ["support"]`. A test reads `support/settings.yml` and reaches `Gate548#strict_check` only when it says `strict`. Build, edit the YAML, build again | Second build: `phase_a_ran` is false (cache hit) and `tests_for(gate.rb, 11)` is empty. The map is stale. |
| #548, b | The same, with the YAML in `test/data/`, outside every `load_path` directory | The same stale map. The limit is not special to `load_path`. |
| #548, c | The issue's first idea (hash every regular file under each `load_path` directory), applied as a patch in the probe | It fixes case a. It does not fix case b. A file that changes in the directory between runs (`support/examples.txt`) then captures every test again on every run. |

The existing test `test_verbose_capture_warning_shows_the_error_and_the_load_note` in `test/daemon_coverage_test.rb` also pins the #537 defect: its `else` branch asserts the generic line.

A reviewer of this plan ran one more probe: a missing `require` under 45 nested calls prints 49 lines, and the `LoadError` line is line 1. `ExternalBackend.tail` keeps the last 40 lines. So the missing-file check must read the full output, not the error message (KTD3).

---

## Product Contract

### Summary

Commit 1 (#535) gives `--test-command` the `load_path` directories. Mutineer sets `RUBYLIB` for the command to those directories. It still clears the tool's and the user's own `RUBYOPT` and `RUBYLIB`. When the clean run cannot load a file, the first sentence of the error says so and names the likely cause: a load variable that was dropped, or a `RUBYLIB` that did not reach the command's Ruby.

Commit 2 (#537) makes a failed fork capture print `fork capture failed: <Class>: <first message line>` without `--verbose`. The daemon's drain already adds the load note to such a line, so the note now appears in the first run.

Commit 3 (#548) changes docs only. It states that the cache key holds Ruby files and not data files, anywhere in the project, and how to force a new capture.

### Problem Frame

**#535.** `CLI.validate_test_command!` lists `extra_load_paths` in `warn_unused_settings`, and `Runner.execute_external` never reads the setting. `ExternalBackend.child_env` clears every `RUBY*` variable (`ExternalBackend.clear_env_key?`), so a `-I` path in `RUBYOPT` or `RUBYLIB` is missing too. `ExternalBackend.smoke_check!` then fails with its generic hint (`ExternalBackend.generic_env_hint`: "failing tests, or a broken environment: DB, RAILS_ENV, migrations"). Three facts from the code shape the fix:

1. `ExternalBackend.spawn_capture` already sets one `RUBY*` variable for the child: `RUBYOPT` with the redaction copier (`ExternalBackend.command_rubyopt`, #457). So a variable that Mutineer sets itself is an existing pattern there.
2. Ruby prints an uncaught `LoadError` as `...: cannot load such file -- x (LoadError)`. `DaemonClient::MISSING_FILE_CAUSE` matches only the `LoadError: cannot load such file` form of a cause line. So the smoke check needs its own rule for raw command output.
3. `ExternalBackend.smoke_check!` already picks a targeted first sentence from the full output (`ExternalBackend.ruby_version_mismatch_hint`). The error message itself holds only the last 40 output lines.

**#537.** `CoverageMap::Capture#accept_fork_payload` hides the child's error string unless `@verbose` is set. The no-boot subprocess path already prints the error without `--verbose` (`CoverageMap::ChildScripts#load_failure_rescue` prints `[mutineer] load failed: <Class: message>`). So only the fork path (in-process `--rails` or `--boot`, and `--daemon`) hides it. Under `--verbose` the extra part is the first backtrace frame, which for a `require` is Ruby's own `kernel_require.rb` line.

**#548.** `CoverageMap::Cache#extra_load_dirs_key` hashes `**/*.rb` under each `load_path` directory. Probe b shows that a data file is outside the key everywhere, not only there. Probe c shows the cost of the issue's first idea.

### Requirements

**`--test-command` load path (#535)**

- R1. With `--test-command`, the `load_path` directories reach the command through `RUBYLIB`, as absolute paths, in the written order, joined with `File::PATH_SEPARATOR`.
- R2. The smoke check and every mutant run get the same `RUBYLIB`.
- R3. `RUBYLIB` for the child holds only those directories. The tool's and the user's `RUBYOPT`, `RUBYLIB` and other `RUBY*` values are still cleared (#100). With no `load_path`, `ExternalBackend.child_env` returns the same hash as on `main`.
- R4. `load_path` no longer prints the "has no effect with --test-command" warning.
- R5. With `--test-command`, a `load_path` entry is usable when it is a directory and its absolute path has no `File::PATH_SEPARATOR` (`RUBYLIB` cannot hold such a path). Only usable entries go into `RUBYLIB`.
- R6. With `--test-command`, the run prints one warning for the entries that are not usable, and runs: `[mutineer] --test-command skips these load_path entries: <paths> (<origin>). Each must be a directory with no "<sep>" in its path. Mutineer 2.0 exits 2 here; pass -I inside the test command for a path RUBYLIB cannot hold.` `<paths>` is the absolute paths, joined with `, `. The warning adds no exit 2 in 1.11.0. The other backends keep their exit 2 for an entry that is not a directory.
- R7. When the smoke check fails and the full output of the command (not only its last 40 lines) has `cannot load such file -- <name>`, the first sentence of the error replaces the generic hint. It starts with `the suite could not load a file (cannot load such file -- <name>)`, with the first such match of the output, so the file name shows also when its line is above the output tail. Then it has each part that applies, joined with `; `:
  - R7a, when the run has `load_path` directories: `if it is in a load_path directory: Mutineer passes those directories to the command in RUBYLIB, and a wrapper that unsets RUBYLIB, or a Ruby that the command starts in a container, does not get them (pass -I inside the test command there)`.
  - R7b, when the user set `RUBYLIB` or a `RUBYOPT` with `-I`: `--test-command does not pass <names> to the command; if the missing file is in a directory set there, add that directory to load_path: in .mutineer.yml, or pass -I DIR (it replaces that list), see <LOAD_PATH_GUIDE>`. `<names>` is `RUBYOPT`, `RUBYLIB`, or `RUBYOPT or RUBYLIB`.
  - When neither applies, the sentence has the start alone.
  - With no missing file in the output, the generic hint stays, as on `main`.
  - The sentence never prints a value of a variable or a `load_path` directory. The match is cut at 500 characters and redacted.
- R8. The R7b text and the daemon's note share one source, `DaemonClient.load_env_note`. The daemon's note text does not change.
- R9. Every copy of the contract says the new behaviour: `mutineer --help`, `docs/cli.md`, `docs/rails-setup.md`, `STABILITY.md`, `CHANGELOG.md`.

**Capture warning (#537)**

- R10. Without `--verbose`, a fork capture whose child raised prints `[mutineer] coverage skipped for <file>: fork capture failed: <Class>: <first non-blank message line>`. That cause is one line, redacted, and at most 500 characters (`ChildCause.line`). The two causes that the parent writes itself (`child wrote no result (...)` and `parent could not read capture result: ...`) are printed too, with their text from `main`. This holds in-process (`--rails`, `--boot`) and under `--daemon`.
- R11. With `--verbose`, the line is the same as on `main`: the full message and the first backtrace frame.
- R12. Under `--daemon`, the first such line that reports a missing file gets the load note without `--verbose`. `DaemonClient#with_capture_note` does this already. It does not change.
- R13. Verdicts, `failed_test_files` entries and cache digests stay the same as on `main`. A failed capture is still recorded in `failed_test_files`.

**Cache key docs (#548)**

- R14. `docs/cli.md` states what the cache key holds, that a data file a test reads is not part of it in any directory, and that deleting `coverage.json` in the cache directory forces a new capture. The line names #548.
- R15. No code changes for #548. #548 stays open and moves to `backlog`.

### Acceptance Examples

- AE1. Covers R1, R2, R4.
  - **Given:** a temp project whose test requires `probe_helper`, a file that is only in `support/`. The test file appends its `ENV["RUBYLIB"]` to a log file on every spawn.
  - **When:** `mutineer run calculator.rb --test <test> -I support --test-command "<ruby> %{files}"`.
  - **Then:** exit 0, every arithmetic mutant is `killed`, stderr has no `has no effect with --test-command`, and every line of the log (the smoke run and each mutant run) has `<project>/support` as an entry.
- AE2. Covers R1.
  - **Given:** two directories `a` and `b`, each with `shared_name.rb` that sets a different constant.
  - **When:** the run has `-I a -I b`, then `-I b -I a`.
  - **Then:** the test loads the copy in the first directory written, both times.
- AE3. Covers R3.
  - **Given:** `RUBYLIB=/tool/lib` and `RUBYOPT=-I/tool/opt` in the environment of the `mutineer` command.
  - **When:** the run has `-I support`.
  - **Then:** the child's `RUBYLIB` has `<project>/support` and no `/tool/lib`. Its `RUBYOPT` has no `/tool/opt`.
  - **When:** the run has no `load_path`.
  - **Then:** the child has no `/tool/lib` in `RUBYLIB`.
- AE4. Covers R5, R6.
  - **When:** `--test-command` runs with `load_path: [no/such/dir, support]` in `.mutineer.yml`, and the test needs `support`.
  - **Then:** stderr has the R6 warning with `<root>/no/such/dir (load_path in .mutineer.yml)`. The exit code is 0. The child's `RUBYLIB` has `<root>/support` and no `no/such/dir`.
  - **When:** `--test-command` runs with `-I "a<sep>b"`, and that directory exists.
  - **Then:** stderr has the R6 warning with that path, and the child's `RUBYLIB` has no part of it. The same directory without `--test-command` is accepted with no warning.
  - **When:** the same missing entry is given without `--test-command`.
  - **Then:** exit 2 with `mutineer: not a directory: ...`, as on `main`.
- AE5. Covers R7b, R8.
  - **Given:** `RUBYLIB=test/support`, no `load_path`, and a test that requires a missing file.
  - **When:** the run uses `--test-command`.
  - **Then:** exit 1. The first line of the error has `the suite could not load a file (cannot load such file -- <name>); --test-command does not pass RUBYLIB to the command;`, before `--- last output ---`. The output has no `test/support` outside the command's own text.
  - **When:** no load variable is set and there is no `load_path`.
  - **Then:** the first line has `the suite could not load a file (cannot load such file -- <name>)` and no further part.
  - **When:** the smoke check fails on a failing assertion, with `RUBYLIB` set.
  - **Then:** the error has the generic hint.
- AE6. Covers R7 (the full output).
  - **Given:** `RUBYLIB=test/support` and a test file that reaches `require "nope"` under 60 nested calls, so the `LoadError` line is above the last 40 output lines.
  - **Then:** the first line of the error still has the missing file's name and the R7b text.
- AE7. Covers R7a.
  - **Given:** `-I support`, and a wrapper script as the test command that runs `unset RUBYLIB` and then the test.
  - **Then:** exit 1, and the first line of the error has `if it is in a load_path directory: Mutineer passes those directories to the command in RUBYLIB`.
- AE8. Covers R10, R11, R12.
  - **Given:** a boot-mode capture of a test that requires a missing file.
  - **When:** `verbose` is false.
  - **Then:** stderr has `coverage skipped for <file>: fork capture failed: LoadError: cannot load such file -- <name>` and the line has no ` @ `.
  - **When:** `verbose` is true.
  - **Then:** the line has the same text, then ` @ ` and a frame.
  - **Given:** a real daemon, `RUBYLIB` set, `verbose: false`.
  - **Then:** the client's `errio` line has the error and `(the daemon does not pass RUBYLIB to the app;`.
- AE9. Covers R10.
  - **Given:** a test file that raises `RuntimeError` with the message `"first\nsecond"` while it loads.
  - **When:** `verbose` is false.
  - **Then:** the line ends with `fork capture failed: RuntimeError: first`. It has no `second`.

### Scope Boundaries

- No change to which variables `ExternalBackend.child_env` clears, and no change to `DaemonClient#restored_user_env`.
- No copy of `-I` paths out of the user's `RUBYOPT` or `RUBYLIB`. Mutineer cannot tell an app path from a tool path there (#100, #491).
- No `-I` on the child's `RUBYOPT`. `RUBYOPT` has no quoting, so a path with a space breaks every Ruby child (`ExternalBackend.command_redact_file` explains this).
- No change to `DaemonClient::MISSING_FILE_CAUSE`. The daemon keeps its own rule for a cause line.
- No note on a mutant's `details` under `--test-command`. A missing load path fails the smoke check first, so no mutant runs.
- No change to `DaemonBackend.boot_config`, `DaemonServer`, or the `verbose` boot key.
- No change to the coverage cache key (#548, KTD6).
- No new config key, flag, Action input or JSON key.
- No change to `mutineer init` output.
- No de-duplication of equal capture lines, and no restructure of the `docs/cli.md` tables.

### Decisions for David

The run takes each recommendation. None blocks the work. Each can change before the merge.

- D1 (#535). How do the directories reach the command?
  - **Recommended:** `RUBYLIB`, set by `ExternalBackend.child_env`.
  - Why: the command is opaque, so the environment is the only channel, and `RUBYLIB` takes a path with a space.
  - Other option: no support. Keep the warning, and add only the R7b sentence. Then drop R1 to R6 and R7a, and keep the `validate_paths!` skip.
  - If David picks the other option: revert the `child_env`, `spawn_capture`, `run`, `usable_load_dirs` and `validate_paths!` edits of U1. Keep the hint.
- D2 (#535). What happens to a `load_path` entry that `--test-command` cannot use (not a directory, or a path with `File::PATH_SEPARATOR`)?
  - **Recommended:** in 1.11.0, warn and skip the entry (R5, R6). In 2.0, exit 2. `STABILITY.md` lists it as a planned break, and a `v2.0` issue tracks it.
  - Why: `STABILITY.md` says a minor release keeps "which result uses which code". On 1.10.0 a run with such an entry and `--test-command` passes, and `test/runner_external_test.rb` pins that. The repo's path for a warning that becomes an error is "warn in 1.x, error in 2.0". The first draft of this plan chose exit 2 now. One lens of the plan check and the Codex review both named the contract.
  - Cost: until 2.0, a typed path stops an in-process or `--daemon` run and only warns under `--test-command`.
  - Other option: exit 2 in 1.11.0, as the other backends do. `load_path` is one release old (1.10.0, 2026-11-24), so very few runs can depend on the old result. Then `CLI.validate_paths!` drops its `--test-command` skip, and the separator case gets its own exit-2 line.
- D3 (#535). Where does the hint code live?
  - **Recommended:** `DaemonClient.load_env_note(who:, to:)` builds the R7b sentence (it is the inside of today's note). `Runner.execute_external` calls it and gives the string to `ExternalBackend.smoke_check!`, which decides on the full output.
  - Why: the text keeps one source, the check reads the full output, and `ExternalBackend` stays a leaf with no reference to `DaemonClient` (`daemon_client.rb` requires `external_backend.rb`, not the reverse).
  - Other option: a new module `Mutineer::LoadEnv` in `lib/mutineer/load_env.rb` that both backends call. It is a cleaner home and one more file, with four constants and `user_value` moved and aliases left in `DaemonClient` for the tests.
- D4 (#537). What does the line show without `--verbose`?
  - **Recommended:** the error's class and its first message line (R10). No hint to re-run with `--verbose`.
  - Why: the no-boot capture path already prints the error without `--verbose`, and the class and message are what the user needs. A hint on every line would sit between the error and the load note.
  - Other option A: always print today's `--verbose` string (the full message and the first frame). It is one line less code. A multi-line message, such as a pending-migration error, then prints in full for each failed test file.
  - Other option B: the issue's first idea, each capture's error in the coverage reply. It adds state to `CoverageMap`, a protocol field and a second printed line for each file.
  - Other option C: show the error without `--verbose` only for a missing file. It needs a copy of the missing-file rule on the app side.
  - What is uncertain: a suite where every capture fails prints the same cause on each line. The line count is the same as on `main`.
- D5 (#548). Does the cache key take every file under a `load_path` directory?
  - **Recommended:** no. Keep the key, state the rule and the remedy in the docs, and move #548 to `backlog`.
  - Why: probe b shows that a data file is outside the key in every directory, so the change fixes one corner of the limit. Probe c shows that a file a test run rewrites in such a directory then makes every run capture again, with no message. `spec/examples.txt` (RSpec's status file) and `test/reports/` (minitest-reporters) are such files, in the two directories a user is most likely to name.
  - Estimate of the defect: rare. It needs a data file that steers which source lines a test reaches, an edit to it, and a cached map. The wrong result is a mutant shown as `no_coverage` or `survived` until any Ruby file in the key changes.
  - Other option: the issue's first idea. In `CoverageMap::Cache#extra_load_dirs_key`, glob `**/*` and keep `File.file?` entries. Tests: an edit to a YAML file in the directory rebuilds the map, a run with no `load_path` keeps its digest, and the run's own sources and tests stay out of the key. Docs: say that a file a test run writes in the directory defeats the cache. The commit then says `Closes #548`, and the verdict becomes `go`.
  - What changes if David picks it: `lib/mutineer/coverage_map/cache.rb` joins the group's files (also changed by 11-C and 11-F), and every 1.10.0 cache of a run with `load_path` rebuilds once.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **`RUBYLIB`, set in `ExternalBackend.child_env`.** `child_env` takes a new keyword `extra_load_dirs: []`. After the loop that clears the `RUBY*` keys, it sets `env["RUBYLIB"]` to the joined list when the list is not empty. With an empty list it sets nothing, so the hash equals today's (R3). `spawn_capture` passes its own new keyword on, then merges `RUBYOPT` as today.
- KTD2. **The list is threaded as one keyword, `extra_load_dirs:`.** The name matches `JobPlan.extra_load_dirs`, which gives the value. `Runner.execute_external` computes it once and passes it to `ExternalBackend.smoke_check!` and, through `Runner.run_external`, to `ExternalBackend.run`. Each has the default `[]`, as `clean_summaries: 0` has in the same signatures, so every existing caller and test keeps its behaviour.
- KTD3. **`ExternalBackend.smoke_check!` picks the hint, from the full output.** A new constant `ExternalBackend::MISSING_FILE` (`/cannot load such file -- \S+/`) and a new `ExternalBackend.missing_file_hint(output, extra_load_dirs, load_note)` sit beside `ruby_version_mismatch_hint`. The hint line becomes `ruby_version_mismatch_hint(output) || missing_file_hint(output, extra_load_dirs, load_note) || generic_env_hint`. `smoke_check!` takes one more keyword, `load_note: nil`: the R7b sentence, or nil. `Runner.execute_external` computes it with `DaemonClient.load_env_note(who: "--test-command", to: "the command")`. So `ExternalBackend` gets a string and needs no reference to `DaemonClient`.
- KTD4. **The fork capture child sends one line without `--verbose`.** In `CoverageMap::Capture#fork_capture`, the value of the child's `rescue Exception` branch is `ChildCause.line(e)` when `@verbose` is false, and today's string when it is true. It is an expression, not a `return`: a `return` inside the `fork` block raises, and the child then sends no payload. `#accept_fork_payload` then prints `fork capture failed: <payload>` for every String. `ChildCause` is stdlib only, so the daemon can load it.
- KTD5. **No drain change.** `DaemonClient#with_capture_note` already matches a line that starts with `DaemonClient::COVERAGE_SKIPPED` and reports a missing file. The new line has the same start.
- KTD6. **The cache key does not change (#548).** See D5.
- KTD7. **One rule for a usable entry.** A new `ExternalBackend.usable_load_dirs(dirs)` returns the entries that are directories and have no `File::PATH_SEPARATOR` in their path. `Runner.execute_external` passes only those on. `CLI.validate_paths!` warns for the rest (R6). So the warning and the `RUBYLIB` value cannot differ.

### Security check against #100

Issue #100: a child inherited the tool's `RUBYOPT` (a `-r` require ran tool code in the app) and the tool's `RUBYLIB`.

- The setting is explicit. A person writes it for the app. Nothing is read from the tool's environment.
- It holds directories only. It has no `-r` form.
- It gives no new power. The test command already runs any program the user names.
- `ExternalBackend.clear_env_key?` and `CLEAR_ENV_KEYS` do not change. AE3 asserts that a parent `RUBYLIB` and `RUBYOPT` value never reaches the child.
- A `RUBYLIB` value reaches every Ruby process the command starts. That is the same reach as `RUBYOPT` with the copier (#457), and it is what `RUBYLIB=test/support bin/rails test` does without Mutineer.

### Sequencing

1. Commit 1, #535 (U1). Code, tests and docs together, because `test/cli_test.rb` and `test/docs_contract_test.rb` read the help text and `STABILITY.md`.
2. Commit 2, #537 (U2). It does not depend on U1.
3. Commit 3, #548 (U3). Docs only.

Suggested commit titles:

```text
feat: --test-command gets the load_path directories in RUBYLIB, and its smoke check names a missing file (#535)
fix: a failed fork capture shows its error without --verbose (#537)
docs: the coverage cache key holds Ruby files, and how to force a new capture (Refs #548)
```

### Assumptions

- `Runner.execute_external` is the only caller of `ExternalBackend.smoke_check!` and, through `Runner.run_external`, of `ExternalBackend.run` in `lib/`. `child_env` is called only from `spawn_capture`. The planner and a reviewer checked this. The builder checks it again.
- `RbConfig.ruby` in the tests is the real binary, not a shim, so `RUBYLIB` in the child is exactly the joined list. Under a shim an entry is put in front. So AE1 asserts that the list includes the directory, not that it equals it.

### Risks

| Risk | Effect | Mitigation |
| --- | --- | --- |
| A user has `load_path` for `--daemon` runs and also runs `--test-command` | The command now gets those directories. A file name that exists there and in a gem resolves to the user's copy | Same as `RUBYLIB` set by hand. CHANGELOG and `STABILITY.md` say the setting now applies |
| A `load_path` entry that `--test-command` cannot use only warns until 2.0 | A typo is easy to miss in a long log. The smoke check then fails with a `LoadError`, or the entry was not needed | The R6 warning names the path. R7a names `load_path` in the smoke error. The `v2.0` issue makes it an error |
| A wrapper script unsets `RUBYLIB` (the rbenv example in `docs/rails-setup.md` does) | The directories are lost, and the smoke check fails with a `LoadError` | R7a names this cause in the error. U1 removes `RUBYLIB` from that example's `unset` line |
| The command starts Ruby in a container, or a grandchild uses `Bundler.with_original_env` | `RUBYLIB` does not reach it, or names a host path | R7a, the `docs/cli.md` row, and the new issue in "Limits left open" |
| The R7b text says "does not pass RUBYLIB" while the command gets a `RUBYLIB` from `load_path` | A user who prints `ENV["RUBYLIB"]` sees a value | R7a comes first in that case and says where that value comes from |
| `MISSING_FILE` matches any output with `cannot load such file -- <name>` | A red smoke check for another reason gets the hint when a test printed that text | The hint is conditional ("if ..."), and the output tail still follows |
| A long error on every capture line | More text on stderr | One line, at most 500 characters (`ChildCause::LIMIT`), redacted |
| 11-C and 11-F also change `lib/mutineer/coverage_map/` | Merge conflict | This group touches only `Capture#fork_capture` and `Capture#accept_fork_payload` in `capture.rb`, and one `require_relative` line in `coverage_map.rb`. 11-C changes `cache.rb` and `capture_reuse.rb` |

---

## Implementation Units

### U1. `--test-command` gets `load_path`, and the smoke check names a missing file (commit 1, #535)

- **Goal:** R1 to R9.
- **Step 0:** write the AE1 test and the AE6 test first. See AE1 fail with the "has no effect" warning and exit 1, and AE6 fail with the generic hint.
- **GitHub step, before the first push:** file the two new issues from "Limits left open" with their labels. Put the `backlog` issue's number in the `docs/cli.md` `load_path` row (Configuration table) and in the CHANGELOG entry. Put the `v2.0` issue's number in the `docs/cli.md` validation row, in the `STABILITY.md` planned break and in the CHANGELOG entry.
- **Files and functions:**
  - `lib/mutineer/external_backend.rb`:
    - `ExternalBackend.child_env`: new keyword `extra_load_dirs: []`. After the `ENV.each_key` loop: `env["RUBYLIB"] = extra_load_dirs.join(File::PATH_SEPARATOR) unless extra_load_dirs.empty?`. Update the doc comment: it names #535 and says the list replaces the cleared value.
    - `ExternalBackend.spawn_capture`: new keyword `extra_load_dirs: []`. Call `child_env(extra_load_dirs: extra_load_dirs)`.
    - `ExternalBackend.run`: new keyword `extra_load_dirs: []`, passed to `spawn_capture`.
    - `ExternalBackend.smoke_check!`: new keywords `extra_load_dirs: []` and `load_note: nil`. The first goes to `spawn_capture`. The hint line becomes `hint = ruby_version_mismatch_hint(output) || missing_file_hint(output, extra_load_dirs, load_note)`.
    - New constant `MISSING_FILE = /cannot load such file -- \S+/`, with a comment: Ruby's message for a `require` that found no file, in the uncaught form and in the Minitest and RSpec forms, with the file's name.
    - New `ExternalBackend.missing_file_hint(output, extra_load_dirs, load_note)`: `found = output.gsub(ANSI_CODE, "")[MISSING_FILE]`. It returns nil when `found` is nil. The start is `the suite could not load a file (<found>)`, with `found` redacted (`Redaction.text`) and cut (`ChildCause.clip`), in the order `ExternalBackend.error_with_output` uses. The parts are R7a (when `extra_load_dirs` is not empty) and R7b (`load_note`, when not nil). It returns the start and the parts, joined with `"; "`. Mark it `@api private`, with `@param` and `@return` lines.
    - New `ExternalBackend.usable_load_dirs(dirs)`: `dirs.select { |dir| File.directory?(dir) && !dir.include?(File::PATH_SEPARATOR) }` (KTD7). Mark it `@api private`.
    - Each new keyword gets its `@param` line. The module comment ("Child environment: ...") and the `command_rubyopt` comment say that `RUBYLIB` holds only the `load_path` directories.
  - `lib/mutineer/runner.rb`:
    - `Runner.execute_external`: before the smoke check, `extra_load_dirs = ExternalBackend.usable_load_dirs(JobPlan.extra_load_dirs(config))`. Call `ExternalBackend.smoke_check!(config.test_command, abs_tests, extra_load_dirs: extra_load_dirs, load_note: DaemonClient.load_env_note(who: "--test-command", to: "the command"))`. Pass `extra_load_dirs:` to `run_external`.
    - `Runner.run_external`: new keyword `extra_load_dirs: []`, passed to `ExternalBackend.run`. Add its `@param`.
  - `lib/mutineer/daemon_client.rb`:
    - New `DaemonClient.load_env_note(who: "the daemon", to: "the app")`: the body of today's `with_load_env_hint` from `names = LOAD_ENV.select ...` on. It returns nil when no name is set. Otherwise it returns the text inside today's parentheses: `"#{who} does not pass #{names.join(' or ')} to #{to}; if the missing file is in a directory set there, add that directory to load_path: in .mutineer.yml, or pass -I DIR (it replaces that list), see #{LOAD_PATH_GUIDE}"`. Mark it `@api private`. Its comment says: names only, never a value.
    - `DaemonClient.with_load_env_hint(cause)`: `return cause unless cause&.match?(MISSING_FILE_CAUSE)`, then `note = load_env_note`, then `note ? "#{cause} (#{note})" : cause`. Its output is byte for byte the same as on `main`.
    - No constant changes.
  - `lib/mutineer/cli.rb`:
    - `CLI.validate_test_command!`: remove `extra_load_paths` from the `warn_unused_settings` list.
    - `UNUSED_SETTING_SCOPE`: remove the `extra_load_paths` entry. No other caller passes that key (`cli.rb` has three `warn_unused_settings` calls).
    - `CLI.validate_paths!`: the line `return if config.test_command` becomes a branch. When `config.test_command` is set: `dirs = JobPlan.extra_load_dirs(config)`, `skipped = dirs - ExternalBackend.usable_load_dirs(dirs)`, print the R6 warning with `warn` when `skipped` is not empty, then return. It never exits there. The code below it (the exit 2 for the other backends) does not change. Update the doc comment.
    - `BANNER`, the `--load-path` entry: replace `not with --test-command` with `--test-command gets them in RUBYLIB`. Keep the entry's line style.
- **Tests:**
  - `test/runner_external_test.rb`:
    - Replace `test_load_path_warns_that_it_has_no_effect_and_is_not_checked` with AE1, for the flag and for the file key. Use the log-file pattern of `test_test_command_replaces_parallel_workers_and_disables_spring_and_bootsnap_cache` (one line for each spawn). Assert the verdict words from `--format json` and every log line (mechanism), not only the exit code.
    - AE2: the order of two directories, both orders.
    - A directory with a space in its name works.
    - AE3: parent `RUBYLIB` and `RUBYOPT` values do not reach the child, with and without `load_path`.
    - AE4: the three cases, with the exact warning. The `--dry-run --test-command` form prints the warning too and exits 0.
    - AE5 (three runs), AE6 and AE7, each with the exact sentence.
  - `test/external_backend_test.rb`:
    - `child_env` with no argument and with `extra_load_dirs: []`, while `ENV["RUBYLIB"]` is set: the key is present with a `nil` value (as on `main`).
    - `child_env(extra_load_dirs: ["/a b", "/c"])`: `RUBYLIB` is `"/a b<sep>/c"`, also while `ENV["RUBYLIB"]` is set.
    - `MISSING_FILE`, the rule and not one example: match real outputs. Spawn `RbConfig.ruby -e 'require "nope_x"'` (the uncaught form), a file that requires a file that requires a missing file, and a Minitest test that requires a missing file inside a test. Each real output matches. `NameError: uninitialized constant X` and an empty string do not.
    - `missing_file_hint`: the four cases of R7 (R7a only, R7b only, both in that order, neither gives the start alone), nil for an output with no missing file, a name inside ANSI colour codes, and a match longer than 500 characters.
    - `usable_load_dirs`: a directory, a file, a missing path, and a directory with the separator in its name.
  - `test/daemon_client_env_test.rb`:
    - `load_env_note` with no argument equals the inside of the pinned 1.10.0 note. With `who:` and `to:` it has those words. With no load variable set it is nil.
    - One `with_env` block with `BUNDLER_ORIG_RUBYLIB` set (the user's value under `bundle exec`) in `test_missing_file_error_names_dropped_load_variables`, if that case is not there yet.
    - The existing assertions on `with_load_env_hint` stay unchanged.
  - `test/cli_test.rb`: `test_help_documents_load_path` keeps `--test-command` in its word list and adds `RUBYLIB`.
- **Docs and contract copies:**
  - `docs/cli.md`:
    - `load_path` row (Configuration table): replace "`--test-command` ignores it and warns; pass `-I` inside that command instead (#535)" with: "With `--test-command`, Mutineer sets `RUBYLIB` for the command to these directories (1.11.0). Ruby searches them after any `-I` the command passes and after a path the app puts in front itself, and before its gems. A wrapper that unsets `RUBYLIB`, or a command that starts Ruby in a container, does not get them: pass `-I` inside the command there (#<new issue>)." Change "in-process and under `--daemon`" at the start of the row so it names all three backends.
    - `load_path` row (validation table): replace the `--test-command` sentence with the R5 and R6 rules: the entry is skipped with a warning, and 2.0 exits 2 (#<v2.0 issue>).
    - `--load-path` row (flag table): no change needed. Check it.
  - `docs/rails-setup.md`:
    - "Extra load paths" block: replace "`--test-command` ignores it (#535)" with one sentence on `RUBYLIB` and "Mutineer 1.11.0 and later".
    - The rbenv wrapper example: remove `RUBYLIB` from its `unset` line. Add one sentence below it: Mutineer clears the tool's `RUBYLIB` itself, and a wrapper that unsets `RUBYLIB` also drops the `load_path` directories.
    - The `--test-command` trade-off table: one row, "Load paths", with the `RUBYLIB` rule and what the smoke check says for a missing file.
  - `STABILITY.md`:
    - "Config keys": replace "`--test-command` ignores it (#535)." with "From 1.11.0, a `--test-command` run gets the directories in `RUBYLIB`. 1.10.0 ignored the key in that run, with a warning."
    - "2.0 changes": one new item in the style of the others: "**A `load_path` entry that `--test-command` cannot use fails the run.** 1.11.0 warns. Today the run skips an entry that is not a directory, or that has the path separator in its path, and continues. In 2.0 it exits 2 (#<v2.0 issue>)."
  - `CHANGELOG.md`, `## [Unreleased]`, `### Added`: one entry for R1, R3, R5, R6 and R7. It says what a user of both `--daemon` and `--test-command` sees, that an unusable entry warns now and exits 2 in 2.0, and names both new issues.
  - `.expectation-fit/decisions/cli-contract-and-exit-codes.md`: one new line, written by hand, with no cubic id: "**Test-Command Load Paths Come From Config.** When reviewing the `--test-command` child environment, verify that `ExternalBackend.child_env` still clears every `RUBY*` variable of the tool and the user, and that `RUBYLIB` holds only the `load_path` directories (#100, #535)."
  - `docs/json-schema.md`: no change. The note there is about `details` under `--daemon`.
- **No change, with the reason:** `README.md` (its Options table links to `docs/cli.md`), `action.yml` (no new input), `lib/mutineer/init.rb`, `lib/mutineer/config.rb` (the key and the flag exist).
- **Verification:** `bundle exec rake test`, the load smoke, `bundle exec rake yard:strict`, `bundle exec rake test:daemon` (the note tests there must stay green).

### U2. The fork capture warning shows its error without `--verbose` (commit 2, #537)

- **Goal:** R10 to R13.
- **Step 0:** change the `else` branch of `test_verbose_capture_warning_shows_the_error_and_the_load_note` to the AE8 daemon case and see it fail. Write the zero-dependency AE8 test and see it fail.
- **Files and functions:**
  - `lib/mutineer/coverage_map.rb`: add `require_relative "child_cause"` beside the other `require_relative` lines. No function changes.
  - `lib/mutineer/coverage_map/capture.rb`:
    - `CoverageMap::Capture#fork_capture`, the child's `rescue Exception => e`: the branch value becomes `@verbose ? <today's string> : ChildCause.line(e)`. Do not write `return` there (KTD4). `Marshal.dump`, `wr.write` and `exit!(0)` below it stay reached in both modes. Update the comment: one line without `--verbose` (#537), the full message and the first frame with it.
    - `CoverageMap::Capture#accept_fork_payload`: the String branch becomes `fail_test(test_path, "fork capture failed: #{payload}")`. The `:timeout` branch and the `else` branch do not change. Update the doc comment above it.
  - `lib/mutineer/daemon_client.rb`: comment only, on `COVERAGE_SKIPPED` and `#with_capture_note`: the line carries the error without `--verbose` since #537.
  - `lib/mutineer/daemon_backend.rb` and `lib/mutineer/daemon_server.rb`: no change. The `verbose` boot key keeps its use: it selects the long form.
- **Tests:**
  - `test/coverage_map_test.rb` (zero dependencies), with the boot-mode pattern of `boot_partial_run` or `shared_map`:
    - AE8, first two cases. Assert the exact text after the file name for `verbose: false`.
    - AE9. It proves that the path uses `ChildCause.line`. The cut at 500 characters and the redaction are already tested in `test/child_cause_test.rb` and `test/redaction_test.rb`, so they get no new test here.
    - A child that dies with `exit!(3)` in the test file prints `fork capture failed: child wrote no result (exit status 3)` without `--verbose`.
    - R13: `failed_test_files` holds the file in both modes. The existing #517 test already proves that `verbose` does not change the digest. Keep it green.
  - `test/daemon_coverage_test.rb` (`rake test:daemon`): `test_verbose_capture_warning_shows_the_error_and_the_load_note` asserts the error and the note in both modes, ` @ ` only with `verbose: true`. Rename it to say both modes.
  - `test/daemon_redaction_test.rb`: in `test_drain_leaves_other_capture_and_child_lines_alone`, the `generic` input becomes the line the code can still print, `fork capture produced no result`. Add a line that reports no missing file, `fork capture failed: RuntimeError: boom`, which gets no note.
- **Docs:**
  - `docs/rails-setup.md`, "Load paths" row: replace the last sentence ("Under `--verbose`, so does ... (#537)") with: "So does the first `coverage skipped for <file>` warning for a test file that could not load a file. `--verbose` adds the full message and the first backtrace frame."
  - `docs/cli.md`, the `--verbose` rows: check that "Full error details" and "shows capture diagnostics" are still true. They are. No edit expected.
  - `CHANGELOG.md`, `## [Unreleased]`, `### Changed`: one entry. A failed fork capture (in-process `--rails` or `--boot`, and `--daemon`) names the error without `--verbose`, the `--daemon` load note appears in the first run, and `--verbose` adds the full message and the first backtrace frame (#537).
- **Verification:** `bundle exec rake test`, `bundle exec rake yard:strict`, then `bundle exec rake test:daemon`.

### U3. Cache key docs (commit 3, Refs #548)

- **Goal:** R14, R15.
- **Files:**
  - `docs/cli.md`, the paragraph that starts "Coverage uses a digest-keyed cache at `.mutineer/coverage.json`": add after it: "The cache key holds the sources, the tests, the project's Ruby files that the tests load, the Ruby files under each `load_path` directory, and for RSpec the project's `.rspec` and `.rspec-local` files. A data file that a test reads, such as a YAML or JSON file, is not part of the key, in a `load_path` directory or in any other. After an edit to such a file that changes which source lines a test reaches, delete `coverage.json` in the cache directory once. The next run captures every test again ([#548](https://github.com/davidteren/mutineer/issues/548))."
  - `docs/cli.md`, `load_path` row: the last sentence becomes "Other files there, such as YAML or JSON data, are not part of the key, as in every directory; see the coverage cache paragraph below (#548)." Use the real section name or anchor of that paragraph.
  - `CHANGELOG.md`, `## [Unreleased]`, `### Changed`: one line. The docs now say what the cache key holds, that it holds no data files, and how to force a new capture (#548). No behaviour change.
- **No code change.** `CoverageMap::Cache#extra_load_dirs_key` stays as it is.
- **Check before the docs edit:** read `CoverageMap::SkeletonDigest#compute_digest` and `#digest_test_seed`, and correct the sentence if the list of key inputs differs. The planner checked the remedy: after `coverage.json` is deleted, the next build captures again (`phase_a_ran` is true).
- **GitHub steps for the builder, before the first push:**
  1. Comment on #548, starting with `**Claude:**`: the three probe results (a, b, c from "Reproductions"), the decision D5, and that the docs now give the remedy.
  2. Move the label: `gh issue edit 548 --add-label backlog --remove-label v1.11.0`. Both labels exist.
- **Verification:** the website checks, because `docs/cli.md` feeds the site build.

---

## Verification Contract

| Gate | Command | Applies to |
| --- | --- | --- |
| Zero-dependency suite | `bundle exec rake test` | every commit |
| Load smoke | `ruby -Ilib -e 'require "mutineer"'` | every commit |
| 100% YARD docs | `bundle exec rake yard:strict` | every commit. Every new keyword, method and constant needs its doc |
| Daemon integration | `bundle install` in `test/fixtures/rails_app`, then `bundle exec rake test:daemon` | before the push: commit 1 changes `DaemonClient`, commit 2 changes capture code the daemon runs |
| Site build | `bundle exec rake site:build` | before the push, on the head (each commit edits `docs/*.md`) |
| Site tests | `node --test test/site_test.js` | same |
| Browser tests | `npm ci --prefix test/browser`, `npx --prefix test/browser playwright install chromium`, `npm test --prefix test/browser` | same |
| Author self-check | `ruby .claude/skills/author-self-check/self_check.rb origin/main`, then steps 2 to 6 of `.claude/skills/author-self-check/SKILL.md` | before the first push |

Not needed: the Minitest 6 run (no change to the Minitest integration), the Prism 2 run (no parse change), and `rake fizzy:sample` (a release check; the sample sets no `load_path` and uses no `--test-command`).

The pull request then follows "PR review gate" in `AGENTS.md` and rules 6 to 15 for a builder in `RULES.md`.

---

## Definition of Done

- R1 to R15 hold. Each acceptance example has a test that asserts the mechanism: the `RUBYLIB` value each spawn saw, the verdict words, the exact stderr sentence, the exit code with its message.
- `ExternalBackend.child_env` with no `extra_load_dirs` equals its value on `main`, and a test proves it.
- The daemon note text is unchanged, and the tests that pin it are unchanged.
- No coverage cache digest changes.
- Every gate in the Verification Contract is green on the pull request head.
- The pull request has three commits, one for each issue, and its body has "Decisions for David" with D1 to D5.
- The two new issues from "Limits left open" exist with their labels, and their numbers are in `docs/cli.md`, `STABILITY.md` and the CHANGELOG as U1 says.
- No input that exits 0 or 1 on `main` exits 2 now.
- #548 has the comment and the `backlog` label, and the docs line names #548.
- This plan is copied to `docs/plans/2026-11-24-535-537-548-feat-load-path-followups-plan.md` in the pull request (`RULES.md`, builder rule 14).
- No `eval`, no runtime dependency, no change to `lib/mutineer/version.rb`.

---

## Limits left open

"Track every limitation" needs an issue number in the same change. The builder files each new issue before the first push, with all four labels, and puts its number in the doc line or CHANGELOG entry that states the limit.

| Limit | Issue |
| --- | --- |
| The coverage cache key holds no data files. An edit to a YAML or JSON file that a test reads does not rebuild the map, in any directory | #548, existing. It stays open and moves to `backlog` (U3). The comment on it names a possible real fix: a list of extra cache inputs that the user declares |
| `--test-command` passes `load_path` through `RUBYLIB`. Three cases do not get the directories: a Ruby that the command starts in a container, a wrapper that unsets `RUBYLIB` (or a grandchild under `Bundler.with_original_env`), and a directory with `File::PATH_SEPARATOR` in its path (skipped with the R6 warning). The first two fail the smoke check with the R7a sentence | One new issue for the three. Labels: `enhancement`, `priority: low`, `risk: low`, `backlog`. Suggested title: "--test-command: load_path reaches the command only through RUBYLIB". Estimate: containers and such wrappers are a small share of `--test-command` setups, unmeasured. A separator in a directory path is near zero |
| Until 2.0, a `load_path` entry that `--test-command` cannot use warns and is skipped, while the other backends exit 2 for an entry that is not a directory | One new issue. Labels: `enhancement`, `breaking change`, `priority: low`, `risk: low`, `v2.0`. Suggested title: "2.0: a load_path entry that --test-command cannot use exits 2". All five labels exist |
| Without `--verbose`, the capture line shows only the first line of the error, cut at 500 characters | By design (D4). `--verbose` shows all of it. No issue |
| Under `--test-command`, a mutant's `details` has no load note | By design. A missing load path fails the smoke check before any mutant runs. No issue |
| A suite where every capture fails prints the same cause on every line | Same line count as on `main`. By design (D4). No issue |

---

## Files this group changes

Functions are named for the files that another group also changes.

| File | What changes | Also changed by |
| --- | --- | --- |
| `lib/mutineer/external_backend.rb` | `child_env`, `spawn_capture`, `run`, `smoke_check!` (keywords), new `MISSING_FILE`, `missing_file_hint` and `usable_load_dirs`, comments | none |
| `lib/mutineer/runner.rb` | `Runner.execute_external`, `Runner.run_external` | none known |
| `lib/mutineer/daemon_client.rb` | new `DaemonClient.load_env_note`, `DaemonClient.with_load_env_hint` (same output), comments | none known |
| `lib/mutineer/cli.rb` | `BANNER`, `CLI.validate_test_command!`, `UNUSED_SETTING_SCOPE`, `CLI.validate_paths!` | none known |
| `lib/mutineer/coverage_map.rb` | one `require_relative "child_cause"` line. No function | 11-C, 11-F |
| `lib/mutineer/coverage_map/capture.rb` | `Capture#fork_capture` (the child's rescue), `Capture#accept_fork_payload` (the String branch) | 11-F may. 11-C does not (it changes `cache.rb` and `capture_reuse.rb`) |
| `lib/mutineer/coverage_map/cache.rb` | **no change** (only if David picks the other option in D5: `Cache#extra_load_dirs_key`) | 11-C, 11-F |
| `lib/mutineer/daemon_backend.rb` | **no change** | 11-B |
| `CHANGELOG.md` | `## [Unreleased]`: one `### Added` entry (#535), two `### Changed` entries (#537, #548) | all groups |
| `docs/cli.md`, `docs/rails-setup.md`, `STABILITY.md` | the rows named in U1 to U3 | 11-C changes `docs/json-schema.md` only |
| `.expectation-fit/decisions/cli-contract-and-exit-codes.md` | one new line | none known |
| `docs/plans/2026-11-24-535-537-548-feat-load-path-followups-plan.md` | new: the copy of this plan | none |
| Tests | `test/runner_external_test.rb`, `test/external_backend_test.rb`, `test/daemon_client_env_test.rb`, `test/cli_test.rb`, `test/coverage_map_test.rb`, `test/daemon_coverage_test.rb`, `test/daemon_redaction_test.rb` | 11-C adds a test to `test/coverage_map_test.rb` |

---

## Plan review

- `/fit-validate-plan`, round 1, four lenses (predictability, simplicity, convention, experience): no P0 and no P1. Lowest score 6/10 (failure transparency). Verdict: ready to implement. The plan took these P2 findings: the missing-file check reads the full output and not the 40-line tail (KTD3, AE6); the smoke check names a dropped `RUBYLIB` when `load_path` is set (R7a, AE7); the hint is the first sentence, not a note after the output; U1 files the issue for its limits. It took these P3 findings: fewer duplicate tests, the `--verbose` docs sentence, the keyword name, the R6 next step, builder rule 14.
- Not taken, with the reason: a `--verbose` pointer on each capture line and a merge of equal lines (D4, more output code for a rare case), and a new `docs/cli.md` subsection for `load_path` (a docs restructure outside the three issues).
- Second opinion: Codex CLI 0.171.0 on `gpt-6.1-sol` (its default), effort `high`, read-only, on this plan and the base checkout. The two models above it in the Codex list (`gpt-6.2-sol`, `gpt-6.2-astra`) are refused for this login, so the default ran. It found six points and called D1, D3, D4 and D5 sound. The plan took all six: no `return` inside the `fork` block (KTD4); D2 changed to warn in 1.11.0 and exit 2 in 2.0 (the minor-release contract in `STABILITY.md`); the `validate_paths!` step no longer depends on an early return; R13 reworded; the hint shows the missing file's name (R7); the U3 sentence lists the real key inputs.

---

## Sources

- Issues: #535, #537, #548 (no comments on any of the three), #100 (why children lose `RUBYOPT` and `RUBYLIB`), #491 and #517 (the 1.10.0 work), #457 (the copier in the child's `RUBYOPT`).
- Pull request #542 and its plan, `docs/plans/2026-11-22-517-491-feat-daemon-load-paths-plan.md`. Source freshness: current (2026-11-22).
- `lib/mutineer/external_backend.rb`: `child_env`, `clear_env_key?`, `spawn_capture`, `command_rubyopt`, `smoke_check!`, `ruby_version_mismatch_hint`, `generic_env_hint`, `tail`, `run`.
- `lib/mutineer/runner.rb`: `execute_external`, `run_external`.
- `lib/mutineer/daemon_client.rb`: `LOAD_ENV`, `MISSING_FILE_CAUSE`, `RUBYOPT_LOAD_PATH`, `COVERAGE_SKIPPED`, `LOAD_PATH_GUIDE`, `with_load_env_hint`, `user_value`, `with_capture_note`.
- `lib/mutineer/coverage_map/capture.rb`: `fork_capture`, `accept_fork_payload`, `fail_test`. `lib/mutineer/coverage_map/child_scripts.rb`: `load_failure_rescue`.
- `lib/mutineer/coverage_map/cache.rb`: `extra_load_dirs_key`, `digest_extra_load_dirs`.
- `lib/mutineer/child_cause.rb`: `ChildCause.line`, `LIMIT`.
- `lib/mutineer/cli.rb`: `BANNER`, `validate_test_command!`, `validate_paths!`, `UNUSED_SETTING_SCOPE`, `warn_unused_settings`.
- `STABILITY.md`: "What SemVer covers", the exit-code table, the planned breaks.
- Rules: `AGENTS.md`, `.expectation-fit/ways-of-working.yaml`, `.expectation-fit/decisions/` (`coverage-and-test-selection.md`, `daemon-and-worker-databases.md`, `cli-contract-and-exit-codes.md`, `docs-and-changelog.md`).

---

## Verdict

**`go without #548`.** #535 and #537 are reproduced and have a small, tested fix. For #548 the probes show that the key change fixes one corner of a general limit and can make the cache miss on every run, so this group ships a docs commit for it and moves the issue to `backlog`.
