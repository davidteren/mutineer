---
title: "Issue #8 — Surface swallowed fork-capture errors; stop AR reconnect from dropping the fixture transaction"
issue: 8
status: ready
---

# Goal (one line)

Make boot-mode fork-capture failures diagnosable (`--verbose`) and stop `clear_all_connections!` from discarding the transactional-fixture transaction, so write-heavy Rails tests are no longer falsely reported `no_coverage`.

## Goal Capsule

- **Objective:** A failing fork-capture surfaces the real exception (class + message + first backtrace line) under `--verbose`, and `reconnect_active_record` no longer clears connections when a fixture transaction is already open — recovering the ~6/22 write-heavy interactors that currently come back as an empty coverage map.
- **Stop condition:** Gate green (`rake test` + library require), the two issue-specific acceptances pass (diagnostic surfaces under `--verbose` and is suppressed without it; the reconnect decision skips the clear when a transaction is open and still clears for non-fixture apps), and no regression to the v0.2 per-fork write-safety.

## Requirements

- **R1 — Surface the swallowed exception.** The `rescue Exception` in `CoverageMap#fork_capture` currently returns `nil`, collapsing every child failure into the generic "fork capture produced no result". Capture the child's `"#{class}: #{message} @ #{backtrace.first}"` and surface it via `fail_test` under a new `--verbose` flag. Without `--verbose`, keep a short message but point the user at `--verbose`.
- **R2 — Reconnect must not break fixture transactions.** `Runner.reconnect_active_record` calls `clear_all_connections!` inside the forked child. When a transactional-fixture transaction is already open on the connection, clearing it discards the transaction and the test then raises (missing fixture rows). Skip the clear when a transaction is open; otherwise clear as before.
- **R3 — Do not regress non-fixture write-safety (v0.2).** The reconnect was added so each fork drops the inherited DB socket (sharing one socket across processes corrupts it). For a non-fixture child (no open transaction at reconnect time) the behaviour must be unchanged: still `clear_all_connections!`.
- **R4 — Zero new runtime deps.** Prism + stdlib only. No ActiveRecord/Rails in the gemspec; the decision logic must be unit-testable without a Rails app.
- **R5 — Both fork paths fixed by one change.** `reconnect_active_record` is called by `fork_capture` (capture path) AND `Runner.run` (per-mutant path). The guard goes in the single shared method so both benefit.

## Key Technical Decisions

- **KTD-1 — Diagnostic is a String, not an Exception.** Marshalling an arbitrary `Exception` over the pipe is unreliable (not all exceptions marshal). The child stringifies `e` to `"#{e.class}: #{e.message} @ #{e.backtrace&.first}"` and returns that. `fork_capture`'s payload becomes a tri-state distinguishable by type: `Hash` = coverage, `String` = error diagnostic, `nil` = pipe gone / empty. `run_phase_a_via_fork` dispatches on type. (Marshal of a String is always safe.)
- **KTD-2 — Reconnect decision keys off open transactions, not "is this Rails".** A pure predicate `fixture_transaction_open?(base)` returns `true` when `base.connection_pool.active_connection? && base.connection.open_transactions.positive?`. This is timing-robust and correct for both cases: an open fixture transaction at reconnect time → skip the clear (preserve it); no open transaction → clear (v0.2 write-safety intact). It also degrades safe: any error in the probe → `false` → clear (existing behaviour).
- **KTD-3 — `--verbose` is a plain boolean Config field, plumbed CLI → Config → Runner.execute → CoverageMap.new.** No precedence subtlety (not in `PRECEDENCE_FLAGS`); mirrors how `rails`/`boot` already flow. `--debug` is accepted as an alias of `--verbose` (single field) to match the issue's "--verbose/--debug".
- **KTD-4 — Coordinate with #9, do not implement it.** #8 only *surfaces* the diagnostic (String payload + recorded `failed_test_files` + stderr). #9 will consume that String to mint a distinct `uncapturable` Result status. A one-line comment marks the seam; no status change here.
- **KTD-5 (ponytail) — Single guard, shared method.** No per-caller patching. The fix lives in `reconnect_active_record`; the capture path (`Runner.send(:reconnect_active_record)`) and the per-mutant path (`Runner.run`) both route through it.

## Implementation Units

### IU-1 — Surface the fork-capture diagnostic (R1, KTD-1)

- **Goal:** Stop discarding the child's real error; show it under `--verbose`.
- **Files:** `lib/mutineer/coverage_map.rb`.
- **Approach:**
  - Add `verbose: false` to `CoverageMap#initialize` → `@verbose`.
  - In `fork_capture`, change the inner `rescue Exception` to return a diagnostic String instead of `nil`:
    `"#{e.class}: #{e.message}#{e.backtrace&.first ? " @ #{e.backtrace.first}" : ""}"`.
    Keep the `# rubocop:disable Lint/RescueException` comment. The pipe-write/`exit!` discipline is unchanged (a String marshals fine).
  - In `run_phase_a_via_fork`, replace `next fail_test(...) unless coverage` with a type dispatch:
    - `Hash` → `record(coverage, test_path)`
    - `String` → `fail_test(test_path, @verbose ? "fork capture failed: #{coverage}" : "fork capture produced no result (re-run with --verbose for the error)")`
    - `nil` → `fail_test(test_path, "fork capture produced no result")`
  - `fork_capture`'s outer `rescue StandardError => nil` (parent-side Marshal/IO) stays `nil`.
  - Leave a `# ponytail/#9: this String diagnostic is what #9 turns into an :uncapturable status` comment at the dispatch.
- **Test scenarios:**
  - `fork_capture` of a test file that raises returns a String containing the message (run with `Coverage.start` so the child reaches the test, not a coverage-not-running error).
  - `build_via_fork` with `verbose: true` over a raising test → stderr includes the real class/message; `failed_test_files` includes the file.
  - same with `verbose: false` → stderr has the generic "produced no result (re-run with --verbose…)" and NOT the raised message.
  - a normal (Hash) capture still records coverage (existing boot_mode tests cover this).
- **Verification:** `bundle exec ruby -Itest test/coverage_map_test.rb` green; new assertions pass.

### IU-2 — Reconnect decision: skip the clear when a transaction is open (R2, R3, R5, KTD-2)

- **Goal:** Preserve the fixture transaction; keep clearing for non-fixture children.
- **Files:** `lib/mutineer/runner.rb`.
- **Approach:**
  - Add a pure predicate (kept private, tested via `send` like existing private-method tests):
    ```ruby
    def self.fixture_transaction_open?(base)
      pool = base.connection_pool
      pool.active_connection? && base.connection.open_transactions.positive?
    rescue StandardError
      false
    end
    private_class_method :fixture_transaction_open?
    ```
  - In `reconnect_active_record`, after the `defined?(ActiveRecord::Base)` guard:
    ```ruby
    base = ActiveRecord::Base
    return if fixture_transaction_open?(base) # #8: clearing here drops the fixture txn
    base.connection_handler.clear_all_connections!
    ```
    Keep the outer `rescue StandardError; nil`.
  - No change needed at the two call sites — both already route through `reconnect_active_record`.
- **Test scenarios (no Rails — inject a double):**
  - `open_transactions == 1`, active → predicate `true` (skip clear).
  - `open_transactions == 0`, active → predicate `false` (clear; v0.2 path).
  - `active_connection? == false` → `false` (nothing to preserve; clear).
  - probe raises → `false` (safe default = clear).
  - existing `test_reconnect_active_record_is_noop_without_active_record` still green.
- **Verification:** `bundle exec ruby -Itest test/runner_test.rb` green.

### IU-3 — Plumb `--verbose` (R1, KTD-3)

- **Goal:** Wire the flag end to end.
- **Files:** `lib/mutineer/config.rb`, `lib/mutineer/cli.rb`, `lib/mutineer/runner.rb`.
- **Approach:**
  - `config.rb`: add `:verbose` to the `Config` struct; default `self.verbose = false if verbose.nil?` in `initialize`. Add `"verbose"` to `KNOWN_KEYS` and a `when "verbose"` boolean coerce (mirror `rails`) so `.mutineer.yml` accepts it.
  - `cli.rb`: `o.on("--verbose")  { opts[:verbose] = true }` and `o.on("--debug") { opts[:verbose] = true }`; add a `--verbose` line to `BANNER`.
  - `runner.rb`: pass `verbose: config.verbose` into the boot-mode `CoverageMap.new` (the `build_via_fork` branch). Standalone path needs nothing (its `capture` already reports real subprocess reasons).
- **Test scenarios:** `cli_test` — `--verbose` and `--debug` both set `config.verbose`; default is `false`. `config_test` — `verbose: true` parsed from a YAML hash.
- **Verification:** `bundle exec ruby -Itest test/cli_test.rb test/config_test.rb` green.

## Verification Contract

**Primary gate (must pass):**
```
bundle exec rake test && bundle exec ruby -Ilib -e 'require "mutineer"'
```
Expected: all tests pass (0 failures, 0 errors); the `require` prints nothing and exits 0.

**Issue-specific acceptance (designed to run WITHOUT a full Rails app):**

A1 — *A fork-capture failure surfaces a real diagnostic under `--verbose` and is not swallowed.*
- Build a `CoverageMap` over a tiny test file that raises (`raise "boom from child"`), `Coverage.start(lines:true) unless Coverage.running?` first so the child reaches the test body.
- `build_via_fork(rails: false)` with `verbose: true` → assert stderr matches `/boom from child/` and `failed_test_files` includes the file.
- Same with `verbose: false` → assert stderr matches `/re-run with --verbose/` and does NOT match `/boom from child/`.
- Direct: `map.send(:fork_capture, raising_test, [CALC], false)` returns a `String` matching `/RuntimeError: boom from child/`.

A2 — *A transactional-fixture write-heavy test is no longer falsely `no_coverage` — proven at the decision boundary.*
- Unit-test `Runner.send(:fixture_transaction_open?, double)` across the four states in IU-2. The `open_transactions == 1` case returning `true` (→ reconnect skips the clear) is the exact decision that keeps the fixture transaction alive, so the child's writes see their fixture rows, the test passes in the fork, coverage is recorded, and the mutant is scored instead of `no_coverage`.
- The `open_transactions == 0` case returning `false` (→ clear runs) proves the v0.2 non-fixture write-safety is intact.
- Double shape: a `Struct`/`OpenStruct`-free plain object exposing `connection_pool` (responds to `active_connection?`) and `connection` (responds to `open_transactions`). No Rails, no DB.
- Full end-to-end Rails reproduction is out of CI scope (no Rails in the gemspec, R4); it is the manual check on the affected app: the ~6 write-heavy interactors report a real mutation score instead of an empty map.

## Definition of Done

- `rescue Exception` in `fork_capture` returns a diagnostic String; `run_phase_a_via_fork` dispatches Hash/String/nil; `--verbose` surfaces the String, default suppresses it with a pointer to `--verbose`.
- `reconnect_active_record` skips `clear_all_connections!` iff a transaction is open; clears otherwise; safe-defaults to clear on any probe error.
- `--verbose`/`--debug` plumbed CLI → Config (+ YAML key) → boot-mode `CoverageMap.new`.
- A1 + A2 acceptances pass; primary gate green.
- No new runtime dependency; no change to standalone-mode behaviour; existing boot_mode/coverage/runner/cli/config tests stay green.
- A `# #9` seam comment marks where the String diagnostic will become an `:uncapturable` status (not implemented here).

## Validation

- **Predictability (9):** Tri-state payload is explicit and type-dispatched; `--verbose` gates only verbosity, never behaviour. Reconnect change is a single early-return guard. Minor surprise (the String-vs-Hash payload) is contained to one private method and commented.
- **Simplicity (9):** No new classes, no new deps. ~1 guard method + 1 rescue change + 1 dispatch + flag plumbing. Root cause fixed once in the shared `reconnect_active_record`, so both fork paths are covered by one diff (no per-caller patching).
- **Convention (9):** Mirrors existing patterns — `fail_test` for skips, `defined?(ActiveRecord::Base)` guard, boolean Config field like `rails`, private-method tests via `send`, fork/Marshal/`exit!` discipline unchanged.
- **Experience (8):** Diagnosable failures are the whole point of the ticket; the default path nudges to `--verbose`. Gap resolved: default message explicitly names `--verbose` so the affected user isn't left at the original dead end.
- **Resolved gaps:** (a) Exception marshalling unreliability → stringify in child (KTD-1). (b) Reconnect timing ambiguity → key off `open_transactions` so the guard is correct whenever the transaction exists, regardless of when it opened (KTD-2). (c) No Rails in CI → decision logic extracted to a pure injectable predicate so A2 runs dep-free (R4).

### Critical Files for Implementation
- /Users/davidteren/Projects/DT/brutus/lib/mutineer/coverage_map.rb
- /Users/davidteren/Projects/DT/brutus/lib/mutineer/runner.rb
- /Users/davidteren/Projects/DT/brutus/lib/mutineer/config.rb
- /Users/davidteren/Projects/DT/brutus/lib/mutineer/cli.rb
- /Users/davidteren/Projects/DT/brutus/test/boot_mode_test.rb
