---
title: "fix: redact the in-process sinks and stop blanking identifier-equal passwords"
type: fix
date: 2026-10-24
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
origin: GitHub issue #288 (davidteren/mutineer) and its Claude analysis comment
size: M
---

# fix: redact the in-process sinks and stop blanking identifier-equal passwords

## Goal Capsule

**Issue:** #288.

**Goal:** no message that mutineer prints, and no daemon stderr line, shows the `DATABASE_URL` password. Two cases stay visible by design outside a URL: a raw password equal to the username (the redacted URL already shows that value), and a password form of 3 characters or fewer glued to an ASCII word character. The drain also cannot identify a bare password loaded only into the app environment after boot. A password that equals the username no longer blanks unrelated text, and a short password no longer blanks a longer word that contains it.

**Authority:** this plan, then `AGENTS.md`, then the issue comment. Where the plan and the comment differ, the plan wins. The differences are listed under "Corrections to the issue comment".

**Stop conditions:** stop and ask when a change needs a new runtime gem, `eval`, or a change to the daemon wire protocol.

---

## Summary

Redaction (PR #266) covers the daemon replies and one coverage warning. Other print paths in the tool process still show the raw password:

1. The in-process boot (`--boot`, and `--rails` without `--daemon`) requires the app in the CLI process. A malformed `DATABASE_URL` raises `URI::InvalidURIError`, and nothing rescues it. Ruby prints the full URL and a backtrace.
2. The `CLI.run` rescues print `e.message` as is. An `ArgumentError` from the app reaches the one at line 337. `SmokeCheckError` carries the tail of the test command's output.
3. The per-mutant fork child prints `#{e.class}: #{e.message}` as is.
4. The daemon client copies the daemon's stderr (which also carries the app's stdout) to the tool's stderr byte for byte.
5. Under `--verbose`, the `--test-command` backend prints the test command's output as is.
6. A crash inside a worker fork becomes `worker crashed: Class: message` in the result details, which reach the JSON report.

Redaction also over-matches. Its last pass replaces every substring equal to the password. With `postgres://postgres:postgres@...` the message `role "postgres" does not exist` becomes `role "[REDACTED]" does not exist`. With password `a`, `ActiveRecord::NoDatabaseError` becomes `ActiveRecord::NoD[REDACTED]t[REDACTED]b[REDACTED]seError`.

This plan routes every sink above through `Redaction.text` and turns a load failure into a clean exit 1. Password forms of 3 characters or fewer use whole-token matching. Longer forms keep substring matching. A raw password that exactly equals the username stays visible outside a URL.

---

## Problem Frame

Line numbers are on `main` at `18ef483`.

- `lib/mutineer/runner.rb:95` `Runner.execute` requires the boot file. Line 97 requires each source (standalone mode). Line 99 requires each `--require` path. None of the three has a rescue.
- `lib/mutineer/cli.rb:328` `CLI.run` has eight rescues (lines 337 to 371). Each prints `e.message` with no redaction. `StandardError` classes outside that list, and `LoadError`, are not rescued, so Ruby prints the raw message and backtrace.
- `lib/mutineer/cli.rb:582` `CLI.validate_paths!` checks only sources and tests. A missing `--boot` or `--require` file reaches the `require` and raises `LoadError`.
- `lib/mutineer/isolation.rb:69` `Isolation.run` child prints `[mutineer-child] #{e.class}: #{e.message}` to `STDERR`.
- `lib/mutineer/daemon_client.rb:354` `DaemonClient#spawn_daemon` drain thread runs `IO.copy_stream(@stderr, @errio)`. `lib/mutineer/daemon_server.rb:145` points the daemon's fd 1 at its stderr, so app output also goes through this copy.
- `lib/mutineer/external_backend.rb:143`, `:150` and `:154` `ExternalBackend.run` print `output` under `verbose`. `lib/mutineer/external_backend.rb:183` builds the `SmokeCheckError` message with the output tail.
- `lib/mutineer/worker_pool.rb:77` `WorkerPool` turns a worker crash into `Result.error("worker crashed: #{e.class}: #{e.message}")`; the reporter writes those details to the JSON report.
- `lib/mutineer/redaction.rb:39` `Redaction.text` ends with `secrets.reduce(out) { |acc, secret| acc.gsub(secret, REDACTED) }`. That is a plain substring replace.
- `Redaction.text` raises on text it cannot match. A probe on `main` shows `ArgumentError: invalid byte sequence in UTF-8` for a string with a stray byte, and `Encoding::CompatibilityError` for a binary string when the password has a non-ASCII character. Today every caller passes an exception message, so this has not shown up. The drain in U4 passes raw pipe bytes, so U1 must fix it first.

Reproduced on `main`: `bin/mutineer run a.rb --test a_test.rb --boot boot.rb` with `DATABASE_URL='postgres://u:s3cret@ho st/db'` and a boot file that runs `URI.parse(ENV.fetch("DATABASE_URL"))`. Stderr shows `bad URI (is not URI?): "postgres://u:s3cret@ho st/db" (URI::InvalidURIError)` and a backtrace.

---

## Requirements

- R1. A `StandardError`, `LoadError` or `SyntaxError` raised while the tool process requires the boot file, a source file, or a `--require` path ends the run with exit 1 and one redacted message: `mutineer: cannot load <path as given>: <Class>: <message>`. No backtrace prints by default. Under `--verbose`, the backtrace follows, one redacted line per frame, then one redacted `mutineer: caused by: <Class>: <message>` line for each exception in the original `cause` chain.
- R2. Every rescue in `CLI.run` prints its message through `Redaction.text`. No exit code changes.
- R3. The fork child line at `isolation.rb:69` prints a redacted `Class: message`.
- R4. Each line the daemon client drains from the daemon's stderr goes through `Redaction.text` before it reaches the tool's stderr.
- R5. The `--verbose` test command output in `ExternalBackend.run`, and the `worker crashed` text in `WorkerPool`, go through `Redaction.text`.
- R6. The blanket pass in `Redaction.text` replaces a password form of 3 characters or fewer only as a whole token, with no ASCII letter, digit or underscore touching either edge. Longer forms remain substring matches. It skips the blanket pass only when the raw password exactly equals the `DATABASE_URL` username. The URL-position passes (`redact_prefixes` and `URL_PASSWORD`) still hide every password, whatever its length or value.
- R7. `Redaction.text` never raises on its input. A valid UTF-8 or ASCII-only string stays as it is. A binary string, or one whose bytes are not valid in its own encoding, is read as UTF-8 with its invalid bytes replaced (`String#scrub`). A valid string in another encoding is converted to UTF-8, with any character that does not convert replaced. The `DATABASE_URL` value gets the same treatment. As a last guard, any internal error in `Redaction.text` returns the fixed text `[message hidden: redaction failed]`, never the input.
- R8. CHANGELOG `## [Unreleased]` gets one `### Fixed` entry for #288 that names the user-visible changes (see U5).

---

## Key Technical Decisions

- **Wrap the requires at the source, not in the CLI.** One private helper in `Runner` requires a project file and converts a `StandardError`, `LoadError` or `SyntaxError` to a new `Mutineer::ProjectLoadError`. All three require sites (runner.rb:95, :97, :99) call it. A rescue in `CLI.run` for every `StandardError` would also hide real bugs in mutineer as a one-line message. The helper keeps the rescue narrow.
- **The name is `ProjectLoadError`, not `BootError`.** The class covers the boot file, standalone sources and `--require` files. `BootError` would suggest the first only, and it sits close to `DaemonBootError`, which means something else. Define it in `lib/mutineer/runner.rb`, as `file_swap.rb` defines `ConcurrentRunError` and `daemon_client.rb` defines `DaemonBootError`.
- **Redacted message, original backtrace, no cause.** The helper raises with the redacted message, the original exception's backtrace, and `cause: nil`. Ruby's default handler prints the `cause` chain, so a library caller of `Runner.execute` that does not rescue would otherwise still see the raw message. Backtrace frames hold file paths and method names, not the password; `--verbose` still passes each frame through `Redaction.text`. The `cause` chain is the real reason for many Rails boot failures (for example a `PG::ConnectionBad` inside an ActiveRecord error), so the helper keeps it as a list of redacted `Class: message` strings on the `ProjectLoadError` (a reader method with a YARD doc), and `--verbose` prints them.
- **Exit 1 for `ProjectLoadError`.** A failed load is a runtime failure, the same class as `DaemonBootError` and `SyntaxError` today. `README.md` and `docs/fragments/contract.yml` define exit 1 as including "a runtime error" and exit 2 as usage. `CLI.run` rescues it next to `DaemonBootError`, prints the message, prints the redacted backtrace under `config.verbose`, and exits 1.
- **One helper for all three sites, so one exit code changes.** An `ArgumentError` or `SystemCallError` raised while the boot file, a source or a `--require` file loads was exit 2 (usage) and is now exit 1 (runtime). Every other load failure already exited 1 (as an uncaught exception or through the `SyntaxError` rescue). The CHANGELOG names the change. A missing source or test is still exit 2, because `validate_paths!` runs first. A missing `--boot` or `--require` file is checked before the load rescue and exits 2 with a missing-path message. A dependency missing inside an existing file remains a runtime load failure (exit 1). Extensionless Ruby and native-extension paths remain supported.
- **`SyntaxError` joins the helper.** Every load failure then has one message shape. `test_syntax_error_source_is_handled_cleanly` asserts only a non-zero exit and no `cli.rb:` frame, so it stays green. The `SyntaxError` rescue in `CLI.run` stays for any other path, redacted by R2. `NotImplementedError` and other `ScriptError` classes keep today's behaviour.
- **`LoadError` output repeats "cannot load".** The result reads `mutineer: cannot load boot.rb: LoadError: cannot load such file -- /abs/path/boot.rb`. This is accepted: one fixed shape is easier to grep than a special case.
- **Redact every `CLI.run` message (R2).** Eight one-call edits, plus the new `ProjectLoadError` rescue, which prints an already redacted message. `SmokeCheckError` really carries app output; the others are a cheap guard on a security path.
- **Drain line by line.** Replace `IO.copy_stream` with a private `DaemonClient` method that reads `each_line` and writes `Redaction.text(line)`. Keep the existing `rescue IOError, Errno::EBADF`. A line is the unit the daemon and the app write. See Risks for the cost.
- **Whole token means no ASCII word character on either side.** Build the pattern from `Regexp.escape(form)`. Add `(?<![A-Za-z0-9_])` only when the form starts with a word character, and `(?![A-Za-z0-9_])` only when it ends with one. A form like `!pw` still matches after a letter, since its edge is not a word character. This uses no `eval`.
- **Skip only the username, not every URL part.** This is the issue comment's default. The redacted URL already shows the username, so leaving it in plain text hides nothing new. The common dev and CI config (`postgres:postgres`, and `app:app@.../app` where the database name equals both) is covered. A password equal only to the host or the database name stays blanked; see Open Questions.
- **No minimum length.** Whole-token matching keeps `database` and `NoDatabaseError` intact for password `a`. A one-letter password still blanks the article `a`. The issue offered a minimum length as an alternative; see Open Questions.
- **`Redaction.text` fails closed.** A `rescue StandardError` around its body returns a fixed placeholder. Without it, a raise inside the fork child's `rescue Exception` would skip `exit!` and run the parent's `at_exit` hooks, and a raise in the drain would end the thread.
- **Keep `redaction.rb` free of Ruby 3.4-only syntax.** The app-side daemon loads it, and `daemon_server.rb` says the app's Ruby may be older than 3.4. Do not use the `it` block parameter there.
- **Normalise encoding inside `Redaction.text`, not at each caller.** One place protects the drain, the daemon, the child and the CLI. A raise in the drain thread would end the thread. The daemon would then block on a full stderr pipe and the run would hang until the boot or request timeout. So R7 is a precondition for R4.

---

## Implementation Units

Units are in dependency order.

### U1. Make `Redaction.text` safe on any input and token-aware

**Goal:** R6 and R7.

**Requirements:** R6, R7.

**Dependencies:** none.

**Files:**
- `lib/mutineer/redaction.rb`: `Redaction.text` (lines 31 to 40). Add two small private helpers with YARD docs: one that returns a UTF-8 copy of a string by the R7 rule, and one that replaces a form as a whole token.
- `test/redaction_test.rb`.

**Approach:**
- At the start of `text`, normalise the input and the `DATABASE_URL` value by the R7 rule. A prototype of the rule handled a binary UTF-8 string, a US-ASCII pipe string with a stray byte, and a non-ASCII password.
- Take the raw username from the `head` that `database_url_parts` already returns (`scheme://user:`): the part between `://` and the trailing colon. Compare it with the raw password; a shared decoded form is not enough to skip redaction.
- In the last pass, skip the blanket pass only when the raw password exactly equals the username. Replace forms of 3 characters or fewer with the whole-token pattern, including forms with punctuation edges. Replace longer forms as substrings. Keep the longest-first order.
- Do not change the prefix pass or the `URL_PASSWORD` pass.
- Wrap the body in `rescue StandardError` that returns `[message hidden: redaction failed]`.
- Update the module YARD text and the `text` docstring to describe the per-form length rule and the exact raw username match.

**Patterns to follow:** `Redaction.password_forms`; the existing `redact(text, url)` test helper.

**Test scenarios** (all in `test/redaction_test.rb`; the first six fail on `main`):
- `test_keeps_a_role_name_equal_to_the_password`: URL `postgres://postgres:postgres@localhost/db`, text `PG::ConnectionBad: FATAL: role "postgres" does not exist (postgres://postgres:postgres@localhost/db)`. Assert the result equals `PG::ConnectionBad: FATAL: role "postgres" does not exist (postgres://postgres:[REDACTED]@localhost/db)`. On `main` the role name is blanked.
- `test_keeps_words_that_contain_a_short_password`: URL `postgres://u:a@host/db`, text `ActiveRecord::NoDatabaseError: database "app" does not exist`. Assert the text comes back unchanged. On `main` every `a` is blanked.
- `test_redacts_text_with_invalid_bytes`: URL `postgres://u:s3cret@ho st/db`, text `"caf\xFF bad URI: postgres://u:s3cret@ho st/db"` as a UTF-8 string with an invalid byte. Assert no exception, the result includes `[REDACTED]`, and it does not include `s3cret`. On `main` it raises `ArgumentError`.
- `test_redacts_binary_text_with_a_non_ascii_password`: URL `postgres://u:pässword@h/db`, text `"auth failed: pässword".b` (the password outside a URL, so the prefix pass does not remove it first). Assert no exception, the result is UTF-8, it includes `[REDACTED]`, and it does not include `pässword`. On `main` it raises `Encoding::CompatibilityError`.
- `test_redacts_a_latin1_string_with_a_non_ascii_password`: URL `postgres://u:pässword@h/db`, text `"café pässword".encode("ISO-8859-1")`. Assert the result equals `café [REDACTED]` (an exact match, so a broken conversion cannot pass). On `main` it raises `Encoding::CompatibilityError`.
- `test_fails_closed_on_an_internal_error`: stub `Mutineer::Redaction.password_forms` to raise. Assert `Redaction.text` returns `[message hidden: redaction failed]` and does not raise. On `main` the error propagates.
- `test_still_hides_a_bare_password_token`: URL `postgres://u:s3cret@host/db`, text `password s3cret rejected`. Assert `password [REDACTED] rejected`. A guard; it passes before and after.
- `test_hides_a_password_next_to_punctuation`: URL `postgres://u:s3cret@host/db`, text `key="s3cret",`. Assert `key="[REDACTED]",`. A guard; it passes before and after.
- The seven existing tests in this file stay green with no change.

**Verification:** the new and existing redaction tests pass; `test/daemon_redaction_test.rb` stays green.

### U2. Turn a load failure in the tool process into a redacted `ProjectLoadError`

**Goal:** R1.

**Requirements:** R1.

**Dependencies:** U1.

**Files:**
- `lib/mutineer/runner.rb`: add `class ProjectLoadError < StandardError; end` with a YARD comment; add a private class method (suggested name `require_project_file(root, path)`) with YARD docs; call it at lines 95, 97 and 99. Add `require_relative "redaction"` to the requires at the top.
- `lib/mutineer/cli.rb`: add `rescue Mutineer::ProjectLoadError => e` to `CLI.run` after the `DaemonBootError` rescue (line 367). It prints `mutineer: <message>`, then under `config.verbose` each backtrace frame through `Redaction.text` and each stored cause as `mutineer: caused by: <cause>`, and exits 1.
- `test/cli_test.rb`: add an `env:` keyword (default `{}`) to the `mutineer` helper (line 16) and pass it as the first argument to `Open3.capture3`, as `test/runner_external_test.rb:18` does.

**Approach:**
- The helper expands the path against the project root and requires it. It rescues `StandardError`, `LoadError` and `SyntaxError`. It raises `ProjectLoadError` with `Redaction.text("cannot load #{path}: #{e.class}: #{e.message}")`, the original `e.backtrace`, the redacted `Class: message` of each exception in `e.cause` (walked to the end), and `cause: nil`. `path` is the path as the user gave it, so the message names `config/environment` and not an absolute path.
- `SystemExit` and `Interrupt` are not in the rescue list and pass through.
- The Coverage state after a failed boot does not matter: the process exits.

**Patterns to follow:** the `DaemonBootError` rescue in `CLI.run`; the `with_project` helper and the `mutineer(...)` subprocess helper in `test/cli_test.rb`; the boot file in `test/daemon_redaction_test.rb:41`.

**Test scenarios** (all in `test/cli_test.rb`, run as a subprocess):
- `test_boot_error_hides_the_database_password`: a temp dir with `boot.rb` (`require "uri"` then `URI.parse(ENV.fetch("DATABASE_URL"))`), a one-method `a.rb`, and a passing `a_test.rb`. Run `run a.rb --test a_test.rb --boot boot.rb` with `env: { "DATABASE_URL" => "postgres://u:s3cret@ho st/db" }`. Assert exit status 1; stderr includes `mutineer: cannot load boot.rb: URI::InvalidURIError`; stderr includes `[REDACTED]`; stderr does not include `s3cret`; no stderr line starts with whitespace and `from ` (no backtrace). On `main` stderr includes `s3cret` and a backtrace.
- `test_boot_error_prints_a_redacted_backtrace_under_verbose`: the same project and env with `--verbose`. Assert exit 1, stderr includes `boot.rb:2`, and stderr does not include `s3cret`. On `main` stderr includes `s3cret`.
- `test_boot_error_prints_a_redacted_cause_under_verbose`: `boot.rb` rescues the `URI.parse` error and raises `RuntimeError, "boot failed"` from inside the rescue (so the URI error is its `cause`). Run with `--verbose`. Assert stderr includes `mutineer: caused by: URI::InvalidURIError` and `[REDACTED]`, and not `s3cret`. On `main` Ruby prints the raw cause.
- `test_boot_load_error_exits_one_cleanly`: the same project, `boot.rb` is `require "no_such_gem_288"`. Assert exit 1, stderr includes `mutineer: cannot load boot.rb: LoadError`, and no backtrace line. On `main` Ruby prints a raw backtrace.
- `test_source_argument_error_at_load_exits_one`: a standalone run whose source raises `ArgumentError, "bad postgres://u:s3cret@ho st/db"` at load, with that `DATABASE_URL`. Assert exit 1 (was 2), stderr includes `cannot load`, and no `s3cret`. On `main` it exits 2 and shows `s3cret`.
- `test_syntax_error_source_is_handled_cleanly` stays green with no change. Run it first after the change to confirm.

**Verification:** the five new CLI tests pass; the existing CLI suite stays green.

### U3. Redact the `CLI.run` messages, the fork child line and the external verbose output

**Goal:** R2, R3 and R5.

**Requirements:** R2, R3, R5.

**Dependencies:** U1.

**Files:**
- `lib/mutineer/cli.rb`: wrap `e.message` in `Redaction.text` in every rescue of `CLI.run` (lines 337 to 371). Do not touch the `CLI.migrate` rescues or the flag-parse rescues in `CLI.start`: their text comes from mutineer and the user's own files.
- `lib/mutineer/isolation.rb`: line 69 prints `Redaction.text("#{e.class}: #{e.message}")`. Add `require_relative "redaction"` to the requires at the top. The module is stdlib-only and loads before the fork.
- `lib/mutineer/external_backend.rb`: lines 143, 150 and 154 print `Redaction.text(output)`. Add `require_relative "redaction"`.
- `lib/mutineer/worker_pool.rb:77`: the `worker crashed: #{e.class}: #{e.message}` text goes through `Redaction.text`. It reaches the JSON report (`Reporter` no-verdict details), which outlives the terminal. Line 144 is mutineer's own Marshal error; leave it.
- `test/isolation_test.rb`, `test/redaction_test.rb`, `test/runner_external_test.rb`, `test/worker_pool_test.rb`.

**Approach:** one call per site. Keep `STDERR.puts` in the child (the comment there explains why).

**Patterns to follow:** `test_error_diagnostic_reaches_stderr_after_block_swaps_streams` in `test/isolation_test.rb` (line 115); `test_coverage_warning_hides_the_password` in `test/redaction_test.rb` (in-process sink test with `ENV` save and restore in `ensure`).

**Test scenarios:**
- `test_error_diagnostic_hides_the_database_password` (`test/isolation_test.rb`): set `ENV["DATABASE_URL"]` to `postgres://u:s3cret@ho st/db` (restore it in `ensure`), run `Isolation.run { raise "no connection: postgres://u:s3cret@ho st/db" }` inside `capture_subprocess_io`. Assert the result is `error?`, stderr includes `[mutineer-child] RuntimeError: no connection: postgres://u:[REDACTED]@ho st/db`, and stderr does not include `s3cret`. On `main` stderr shows `s3cret`.
- `test_cli_run_error_hides_the_password` (`test/redaction_test.rb`, in process): set `ENV["DATABASE_URL"]` as above, stub `Mutineer::CLI.validate!` to do nothing and `Mutineer::CLI.execute` to raise `ArgumentError, "bad postgres://u:s3cret@ho st/db"`, and call `Mutineer::CLI.run` with a config that has one source. Assert `SystemExit` with status 2, and captured stderr includes `[REDACTED]` and not `s3cret`. On `main` stderr shows `s3cret`.
- `test_verbose_output_hides_the_password` (`test/runner_external_test.rb`): with that `DATABASE_URL`, run `ExternalBackend.run` with `verbose: true` and a command that prints the URL and exits 1. Assert captured stderr includes `[REDACTED]` and not `s3cret`. On `main` stderr shows `s3cret`.

- `test_worker_crash_details_hide_the_password` (`test/worker_pool_test.rb`): with that `DATABASE_URL`, run the pool with a block that raises `"boom #{url}"`. Assert the returned `Result` details include `[REDACTED]` and not `s3cret`. On `main` the details show `s3cret`.

**Verification:** the four tests pass; the existing isolation, external backend, worker pool and CLI tests stay green.

### U4. Redact the daemon stderr drain

**Goal:** R4.

**Requirements:** R4.

**Dependencies:** U1 (R7 must hold first, or a stray byte ends the drain thread).

**Files:**
- `lib/mutineer/daemon_client.rb`: replace `IO.copy_stream(@stderr, @errio)` at line 354 with a call to a new private method (suggested name `drain_stderr(io)`) with YARD docs. The method writes `Redaction.text(line)` for each line of `io` to `@errio`. Keep the `rescue IOError, Errno::EBADF` and the thread around it. Update the comment above the thread. Add `require_relative "redaction"`.
- `test/daemon_redaction_test.rb` (it is in the default zero-dep suite; `test/daemon_client_test.rb` is not).

**Approach:** the drain reads in the pipe's default encoding. R7 makes any bytes safe. The drain uses the tool's `ENV["DATABASE_URL"]`. `DaemonClient#app_env` starts from `ENV.to_h`, so a value set before the run is the daemon's value too. A value the app loads during boot (for example with dotenv) is not known to the tool; see Risks.

**Test scenarios:**
- `test_daemon_stderr_drain_hides_the_password` (`setup` already sets `DATABASE_URL` to `BAD_URL`): build `Mutineer::DaemonClient.new(boot: {}, app_root: Dir.tmpdir, errio: errio)` with a `StringIO` `errio`. Write `boot failed: #{BAD_URL}\n` and `second line\n` to an `IO.pipe`, close the write end, and call the drain method on the read end. Assert `errio.string` includes `postgres://u:[REDACTED]@ho st/db` and `second line`, and does not include `s3cret`. On `main` there is no such method; the `IO.copy_stream` copy shows `s3cret`.
- `test_daemon_stderr_drain_survives_invalid_bytes`: write `"bad \xFF byte #{BAD_URL}\n"` in binary to the pipe. Assert the drain returns, `errio.string` includes `[REDACTED]`, and does not include `s3cret`. This fails if R7 is missing.
- `test_daemon_stderr_drain_keeps_a_last_partial_line`: write `tail without newline` and close. Assert `errio.string` ends with it. A guard for EOF; it does not cover a thread killed by `close_io` (see Risks).

**Verification:** the three tests pass; `bundle exec rake test:daemon` (rails-integration CI job) stays green, since daemon boot errors still reach the tool's stderr.

### U5. CHANGELOG

**Goal:** R8.

**Requirements:** R8.

**Dependencies:** U1 to U4.

**Files:** `CHANGELOG.md`, `## [Unreleased]`: add a `### Fixed` subsection below `### Changed`, the order the 1.7.0, 1.6.0 and 1.5.0 sections use (Added, Changed, Fixed).

**Approach:** one entry in the repo's `- **Bold lead (#288).** prose` shape. It says:
- A load error in the tool process (an in-process `--boot` or `--rails` run, a source file, or a `--require` file) no longer prints the raw `DATABASE_URL` password or a backtrace. The run prints one `mutineer: cannot load <path>: ...` message and exits 1. `--verbose` adds a redacted backtrace.
- An `ArgumentError` or `SystemCallError` raised while the boot file, a source file or a `--require` file loads now exits 1, not 2.
- Error messages from the CLI, the fork child line, the worker crash text in the report, the daemon's stderr lines and the `--verbose` test command output are redacted too. `--verbose` also prints a redacted cause chain for a load failure. Daemon stderr is now copied line by line as UTF-8; an invalid byte shows as U+FFFD.
- A password equal to the username no longer blanks the same text elsewhere in the message (for example `role "postgres"`). A short password no longer blanks words that contain it, but it still blanks the same word when it stands alone (a one-letter password still blanks the word `a`). The password inside a URL is still hidden.

**Test expectation:** none. This is a docs change.

---

## Verification Contract

Run from the repo root, with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` set in this environment. These are the `AGENTS.md` local gate commands.

- `bundle exec rake test` (zero-dep suite; includes `test/redaction_test.rb`, `test/daemon_redaction_test.rb`, `test/cli_test.rb`, `test/isolation_test.rb`, `test/runner_external_test.rb`).
- `ruby -Ilib -e 'require "mutineer"'` (load smoke).
- `bundle exec rake yard:strict` (100% documented, private methods and constants included: `ProjectLoadError`, the runner helper, the drain method, and the two redaction helpers each need a docstring).
- `BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle exec rake test` (the CLI and isolation tests run Minitest children).
- `bundle exec rake test:daemon` when the fixture bundle is installed (U4 touches the daemon client). CI runs it in the rails-integration job.

Rules from `AGENTS.md` that apply: zero runtime dependencies (stdlib `uri` only), no `eval` (the token pattern uses `Regexp.escape`), least astonishment, and a CHANGELOG entry under Unreleased.

Manual check: repeat the reproduction from "Problem Frame". Stderr is exactly `mutineer: cannot load boot.rb: URI::InvalidURIError: bad URI (is not URI?): "postgres://u:[REDACTED]@ho st/db"`, the exit status is 1, and there is no backtrace.

---

## Definition of Done

- Every test named in U1 to U4 exists, failed on `main` where the plan says so, and passes.
- All commands in the Verification Contract pass.
- No tool-side path in the Problem Frame prints a raw `DATABASE_URL` password.
- The CHANGELOG entry from U5 is under `## [Unreleased]`.
- No new runtime dependency and no `eval`.

---

## Scope Boundaries

- No change to the daemon wire protocol or to `lib/mutineer/daemon_server.rb`. It already redacts what it sends.
- No change to `lib/mutineer/daemon_backend.rb:149`, `:171` and `:229`. Those warnings get text the daemon already redacted.
- No change to the `URL_PASSWORD` pattern or the prefix pass.
- No redaction of `CLI.migrate`, `CLI.start` flag-parse, `Triage` or `Init` messages. Their text comes from mutineer and the user's own files.
- Output that app code, tests or fork children write directly to the inherited stderr or stdout (for example a failing test that prints the URL, or `abort` in an initializer) is not intercepted.
- `lib/mutineer/daemon_server.rb` is not edited, but it calls the same `Redaction.text`, so its replies get the whole-token and encoding changes too.

### Deferred to Follow-Up Work

Issue #341 tracks every item below, the direct-stderr and app-only `DATABASE_URL` gaps in Scope Boundaries and Risks, and the last-resort handler in Open Questions.

- A password equal to the host or the database name, or a one-letter password, still blanks that word. See Open Questions.
- A password that is a common word (for example `password`) still blanks that word as a whole token, as in `FATAL: [REDACTED] authentication failed`. No option here fixes that without hiding less.

---

## Risks

- **Whole-token matching hides less for short forms.** A password form of 3 characters or fewer glued to an ASCII word character (`xab` for password `ab`) stays visible outside a URL. Longer forms still use substring matching, and URL passes still hide every password. Frequency is not measured: this repository has no representative sample of app error messages from which to estimate it. A rough bound: a password of 3 characters or fewer is rare outside local development setups, and #341 tracks the trade-off. This is the deliberate cost of keeping ordinary words readable when a password is short.
- **Exit code change for loads.** A CI script that expects exit 2 when the boot file, a source or a `--require` file raises `ArgumentError` or `SystemCallError` at load now sees exit 1. Exit 1 is the documented class for a runtime error, and the CHANGELOG names it.
- **Multi-line messages.** "One message" can span lines when the app's exception message has newlines. Each line is still redacted. The tests do not assert a line count.
- **Drain changes the bytes.** Daemon stderr is no longer copied byte for byte. Each line is read as UTF-8 and invalid bytes show as U+FFFD (R7). The CHANGELOG names it.
- **Drain buffering.** Output without a newline appears only at the next newline or EOF. This is deliberate: credentials can span writes, and a malformed URL password can contain spaces or an unescaped `@`. Redacting separate chunks could reveal part of the password. `close_io` joins `@drain` for up to 1 second after stopping the daemon and before stopping the drain, so EOF flushes a partial last line. The pipe tests check that final flush. A stream parser is outside this change; no immediate delivery of partial lines is promised.
- **Drain knows only the tool's `DATABASE_URL`.** When the app loads `DATABASE_URL` itself during boot, the drain still hides the password inside any URL, but not as a bare token. The daemon's own replies stay safe: `daemon_server.rb` redacts with its own environment.
- **Username-equal password next to a label.** A text like `PGPASSWORD=postgres` with user `postgres` keeps `postgres` visible. This is the deliberate cost of the username skip: the URL already shows that value.
- **Drain thread death.** If `Redaction.text` raised, the drain thread would end and the daemon could block on a full pipe. U1 (R7) and `test_daemon_stderr_drain_survives_invalid_bytes` guard this.
- **Overlaps with open PRs** (checked with `gh pr diff`):
  - #304 (redefine snippet beside the source): edits `lib/mutineer/runner.rb` near lines 60 to 68 (the orphan sweep) and `lib/mutineer/isolation.rb` near line 267. No shared hunk; a rebase may need a small manual merge near the sweep.
  - #308 (live mutant files and temp sweep): edits `lib/mutineer/isolation.rb` near lines 196 and 274, not line 69.
  - #305 (Bootsnap and `--test-command`): edits `test/runner_external_test.rb`. U3 adds a test to that file; expect a trivial merge.
  - #307 (#270, #281 output path checks): edits `lib/mutineer/cli.rb` near lines 1, 383 and 636 and adds tests to `test/cli_test.rb`. No shared hunk with the `CLI.run` rescues or the `mutineer` helper.
  - #244 (2.0 contract flip): edits `lib/mutineer/runner.rb` near line 31, `lib/mutineer/cli.rb` near the top and the usage text, and `lib/mutineer/daemon_client.rb` near lines 81 and 100. With #244, `--rails` uses the daemon by default, so U4 covers the default path and U2 covers `--no-daemon` and `--boot`. No shared hunk.
  - #245 (daemon by default for Minitest `--rails`): same effect as #244 on which path is default.
  - #306, #202, #301: no shared files except `CHANGELOG.md`.
  - Issue #292 (crash of `--test-command` scored killed) has a plan that changes `ExternalBackend.run`. U3 touches only the three `warn output` lines there. Whichever lands second keeps both changes.
  - Every open PR edits `CHANGELOG.md` under Unreleased. Expect a trivial merge there.

---

## Open Questions

None blocks implementation.

- **Skip more URL parts?** Default: skip only the username, as the issue comment recommends. Alternative: also skip a form that equals the host or the database name, since the redacted URL shows those too.
- **Length rule for the blanket pass.** The implementation uses whole-token matching for each form of 3 characters or fewer and substring matching for longer forms. It does not skip short forms completely, so a short password still disappears when printed as a separate token.
- **A last-resort handler?** Default: no. Alternative: a rescue in `CLI.start` for any unrescued exception that prints `Redaction.text(e.full_message)` and exits 1. It keeps the backtrace and the cause chain, and it would cover sinks this plan does not list. It also changes how every mutineer bug looks, so it is a separate decision.
- **Scope of the `ProjectLoadError` rescue.** Default: all three require sites, including standalone sources. Alternative: wrap only the boot file and `--require` paths, and keep today's exit 2 for an `ArgumentError` in a standalone source.

---

## Corrections to the issue comment

- The comment cites `cli.rb:328` for `CLI.run` and `cli.rb:337` for the `ArgumentError` rescue. Both are right on `main`. The other seven rescues in `CLI.run` also print raw messages, and `SmokeCheckError` carries the test command's output. R2 covers them all.
- The comment does not list `ExternalBackend.run`'s `--verbose` output (external_backend.rb:143, :150, :154). R5 covers it.
- The comment says to rescue `StandardError` and `LoadError` at `runner.rb:95-99`. That range also covers the standalone source require at line 97, and it changes an exit code from 2 to 1 for an `ArgumentError` or `SystemCallError` at load. The comment does not say so. This plan keeps line 97 in scope, adds `SyntaxError` for one message shape, and records the exit change.
- The comment names the class `Mutineer::BootError`. This plan uses `ProjectLoadError`, because the class covers sources and `--require` files too.
- The comment suggests a line-by-line drain redaction as optional. This plan makes it required (U4), because the issue names the daemon client path. It needs the encoding fix (R7) the comment does not mention: `Redaction.text` raises on invalid bytes and on non-UTF-8 text with a non-ASCII password.
- The comment does not say that a re-raise inside a rescue keeps the original exception as `cause`, which Ruby prints. U2 raises with `cause: nil`.
