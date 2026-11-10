---
title: Full-reload strategy for Rails daemon runs - Plan
type: feat
date: 2026-11-10
issues: [389]
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Full-reload strategy for Rails daemon runs - Plan

Implement opt-in `full_reload` for Rails daemon runs. Complete U1, the mechanism spike, before starting implementation.

## Goal Capsule

- **What:** Issue #389 adds `--strategy full_reload` for `--daemon --rails` runs (KTD1, strategy selection).
- **Why:** Score mutants against fresh app classes without boot-file patches, repeated-class-body errors, or false verdicts. Stop clearly when reloading is unsafe.
- **How:** Substitute mutant text through a standard-library hook (KTD2), reload the app (KTD3), and follow its eager-load setting (KTD4).
- **Authority:** This plan, then `AGENTS.md`, then the text of #389. This plan overrides issue differences; see "Corrections to the issue".
- **Owners:** The implementer performs the implementation tasks. The maintainer answers open decisions.
- **Spike first:** U1 merges no code. Its outcomes determine whether implementation units U2 to U7 proceed as written.
- **Stop and ask when:** A U1 outcome says stop; work needs a runtime gem, `eval`, or string compilation; or another strategy's behaviour would change.
- **Size:** L (large). About 41 files: 11 under `lib/` (1 new), 14 tests (2 new), and 9 fixtures (7 new). Also `Rakefile`, `action.yml`, and 5 docs files. No new runtime dependency.
- **Delivery:** One pull request after the spike. Labels: `enhancement`, `priority: medium` (medium priority), `risk: high` (high risk), and `v2.0` (target release). Semver class: minor, because the strategy is opt-in and changes no default (KTD11, release classification). Keep the pull request **draft** until Q5, the 1.x release decision. A `main` merge ships in the next 1.x release (`AGENTS.md:167-169`), contrary to the `v2.0` label. A person merges it. This plan includes no release step.

---

## Product Contract

### Summary

Add `full_reload` as the third `--strategy` value, restricted to `--daemon --rails` and Minitest.

Each daemon enables class reloading and keeps the app's eager-load setting. Each clean-check fork reloads without a mutant. A red test stops the run and names the test.

Each mutant fork substitutes the mutant during compilation, reloads, conditionally eager loads, runs covering tests, and confirms substitution. Sources outside reloading autoloaders score `unplaceable` before any fork.

The #391 guards, which fix Rails class-body reloads, and `ConcernBlocks` remain exclusive to `reload`.

### Problem Frame

The daemon forces `reload` (`lib/mutineer/cli.rb:506-511`). It `load`s the mutated file over existing classes (`lib/mutineer/daemon_server.rb:479-493`). Repeated class bodies can reject or duplicate enums, `skip_before_action`, validators, and block callbacks.

Vladimir needed four boot-file patches for error-free Fizzy runs. #391 guards known macros, but each new macro needs another guard. Class-body macro mutants, tracked in #397, cannot work on reopened classes.

Vladimir's prototype reloads the app per fork. Its nine-file Fizzy sample produced 0 errors and the patched setup's survivors, without enum, callback, or concern patches. However, it prepends a private method, requires `require-hooks`, and needs a custom boot file. Mutineer's zero-runtime-dependency rule prevents shipping it unchanged.

### Requirements

**Selecting the strategy**

- R1. Accept `--strategy full_reload` through the CLI and Action `strategy` input. Keep all defaults and other runs unchanged.
- R2. Require `--daemon`, `--rails`, and Minitest. Other combinations exit 2 and name the missing requirement. Cover `--test-command`, `--no-daemon`, `--boot` without `--rails`, and RSpec.
- R3. Apply the same validation during `--dry-run`.

**Booting**

- R4. Enable class reloading in every daemon. Preserve `config.eager_load`; add no boot eager load. Boot load lines must equal `reload` runs (KTD4; KTD10, load-time scoring). Print one stderr line stating that reloading was enabled.
- R5. Refuse boot if reloading remains off. Exit 1 and name the cause, without `reload` fallback or a coverage-fallback warning (KTD12, boot refusal).
- R6. Refuse boot as R5 specifies if Ruby lacks the instruction-sequence hook or Zeitwerk lacks `Loader#cpath_expected_at`. Name the missing method and Ruby or Zeitwerk version. Cover non-MRI Ruby.

**Placing a mutant**

- R7. Substitute mutant text at the original file's real path. Preserve `require_relative`, `__dir__`, and the original path in `$LOADED_FEATURES`. As with `reload`, `__FILE__` and `source_location` name a hidden adjacent file (KTD2). Unlike `reload`, class-creation hooks such as `inherited` run again and record that hidden path. Check R-C of the adversarial probe (P5 in "Probe results") demonstrates this difference. Sidecar lookups, such as ViewComponent templates, then fail. S8, the verdict-parity spike, measures this. U7 documents it and files an issue.
- R8. Identify sources outside reloading autoloaders at boot. Score their mutants `unplaceable` without running them. List those files in one stderr line.
- R9. After covering tests, score the mutant `error` if its file was never compiled. Name the file. Check after tests because lazy apps compile only when tests reach the constant (KTD4).
- R10. Place concern methods in `included` or `prepended` blocks, including cases that `reload` marks `unplaceable`. Run the mutated block in every includer.
- R11. Keep every database pool and role on the worker's database after repeated `connects_to` calls. Cover more than `ActiveRecord::Base` (KTD7, worker routing).

**Safety and scoring**

- R12. Reload without a mutant before tests in every clean-check fork (KTD6, reload-safety check). Cover cache hits, misses, and single-file runs. Red tests stop through `JobPlan.abort_if_unclean!` with exit 1, a runtime error (`STABILITY.md:32-38`). Name every red test file. Explain that boot state outside `to_prepare` is the usual cause.
- R13. Keep the score formula, statuses, and JSON shape. Keep `unplaceable` counted in the unrun share (`lib/mutineer/result.rb:218`).
- R14. Document activation, prerequisites, and the `to_prepare` rule. State that zero errors do not prove a setup. Link issues for stale-reference false survival (KTD10), class-creation-hook paths (R7), and `ran_at_load` under `full_reload` (R15).
- R15. Keep one `ran_at_load` rule for both daemon strategies until S8 decides. Run `JobPlan.load_verdict` on unchanged boot load lines (R4). Under `full_reload`, the human "Ran at load" line and `docs/json-schema.md:140` stop saying that Mutineer cannot re-run the load. They say that a reload runs class bodies again, but not initializers. If S8 shows that every `ran_at_load` mutant of a reloaded file has the `--test-command` verdict `survived`, U5 skips `load_verdict` under `full_reload` for the files the reload compiled (KTD10). Exception: macro subjects from #397 PR3 (class-body macro mutants) never get `ran_at_load` under `full_reload`. Their mutated line is the class body, which the reload runs again (R-B). That exception does not wait for S8.
- R16. Disable the reloader's change check after the fork's reload. File changes during tests must not trigger another reload (KTD3).
- R17. Record forced reloading in the coverage cache digest. Prevent cross-strategy reuse without changing the `reload` digest (KTD13, cache separation).

### Acceptance Examples

- AE1. **Enum and concern parity; R1, R10, R13.** Run the fixture enum model and `included` concern with `--daemon --rails --strategy full_reload`. Require zero mutant errors and per-mutant verdicts equal to `--test-command`.
- AE2. **Unsafe initializer; R12.** With `MUTINEER_RELOAD_UNSAFE=1`, an `after_initialize` initializer sets a class attribute. Require exit 1 before mutants and the red test file's name, on cache misses and hits.
- AE3. **Unmanaged source; R8.** Mutants in an initializer-required `lib/` fixture source are `unplaceable`. Stderr names the file.
- AE4. **Missing daemon; R2.** `--rails --no-daemon --strategy full_reload` exits 2 and names `--daemon`.
- AE5. **Missing substitution; R9.** If reload and tests never compile the target, score `error` and name the file on stderr.
- AE6. **Boot refusal; R5, R6.** A boot that leaves reloading off exits 1 at `--jobs 1` and `--jobs 2`. Print the R5 message without a coverage-fallback warning.

### Scope Boundaries

**Non-goals, considered and not built:**

- No `.mutineer.yml` key. `strategy` remains CLI-only (`lib/mutineer/config.rb:69`, `docs/cli.md:86`, `STABILITY.md:63`). Q1 asks about a key.
- No optional `require-hooks` integration. Keep one placement mechanism to test (KTD2).
- No eager-load option. Follow `config.eager_load` (KTD4). S5 checks whether lazy forks need forced eager loading.
- No JSON key for the `unplaceable` cause. Use stderr (R8) and docs. Revisit if a CI user needs the cause without stderr.
- No `load` fallback for unmanaged sources (KTD5, placement guards). Q9 revisits this.
- No `ran_at_load` change beyond R15. Repeated class bodies can make `JobPlan.load_verdict` exclude real survivors (KTD10). U7 files unresolved cases.
- No macro mutants. #397, class-body macro mutation, depends on this plan.
- No default change. Keep the 2.0 default described in `STABILITY.md:115-120` until #284 decides daemon and reload default preconditions.

### Deferred to Follow-Up Work

- In-process `--rails --strategy full_reload`: the implementer files an issue under Q7. R2 rejects this combination.
- RSpec daemon support: the daemon remains Minitest-only (`lib/mutineer/cli.rb:500-504`).

### Corrections to the issue

- **Sample counts differ by source.** The issue reports 53 mutants and 16 survivors for nine models, plus 30 mutants and 7 survivors for controllers. Saved Fizzy reports match these counts (P3, saved-report probe). Vladimir's 1.8.0 report gives 89 mutants and 23 survivors for the same nine files. See its "Full reload per mutant" section, Results. The cause is unknown; running Mutineer in the Fizzy clone was outside this job.
- **Saved patched and full-reload reports are byte-identical.** `tmp/nine_patched.json` and `tmp/nine_reload.json` share a SHA-1. Both controller files also match (P3). This does not prove independent runs. The survivor-digest probe raised `NoMethodError` and printed one value for all four files, so that digest proves nothing. JSON has no time field. The issue's 36.1 s, 39.5 s, 30.6 s, and 36.8 s wall times remain unchecked. Its 0.6 to 0.9 s per-mutant cost is also absent and unchecked. U1 measures cost again.
- **`strategy: full_reload` does not fit `.mutineer.yml`.** `strategy` has no YAML key (`lib/mutineer/config.rb:69-70`) and is documented as CLI-only (`docs/cli.md:86`). Use `--strategy` and the Action input. Q1 asks about a key.
- **A require hook is unnecessary.** The issue proposes path-limited `Kernel#load`, `require`, or optional `require-hooks`. The report's custom require hook failed with `NameError`. The string-compilation probe P1 and the file-compilation probe P2 demonstrate stdlib substitution through `RubyVM::InstructionSequence.load_iseq`. P1 covers Bootsnap on and off, eager and lazy loading, and symlinked paths. P2's KTD2 `compile_file` form ran only with Bootsnap 1.26.1. S1 repeats it with `WITHOUT_BOOTSNAP=1`.
- **The prototype places hook-block mutants.** The issue says `included do` mutants remain unplaced. For placeable defs, payloads already contain the mutated block (`lib/mutineer/daemon_backend.rb:436-440`, `lib/mutineer/job_plan.rb:222-227`). Full reload runs it in every includer; probe P1 confirms the changed method. Defs that `reload` cannot place never reach the prototype. They become `unplaceable` before payload creation (`lib/mutineer/daemon_backend.rb:432`, `lib/mutineer/subject.rb:53-55`).
- **Reload safety includes false survival.** P1 loses `after_initialize` state (`after_initialize_check=FAIL`), causing false kills. A boot registry also retains the old class (`real_killer_stale_registry=PASS` with the mutant applied). Tests through that registry run original code and can falsely survive. A clean reload cannot detect this direction.
- **Unreloaded sources silently survive.** P1 records zero substitutions with reloading off, yet original code runs without error. Sources outside reloading autoload paths behave the same way. R8 and R9 address this omitted risk.
- **Repeated `connects_to` risks database routing on every adapter.** The fork first routes `ActiveRecord::Base` to its worker database (`lib/mutineer/rails_worker_db.rb:400-416`). Reloaded class bodies can reconnect to the configured database. In `redesign/route_and_middleware_probe.out`, SQLite with `CONNECTS_TO=1` returns to `shared.sqlite3`; a create writes one row there. Fizzy's test setup is not a concrete example. Its `ApplicationRecord` calls `connects_to` only with a replica (`lib/rails_ext/active_record_replica_support.rb:22-25` in the Fizzy clone). Its MySQL test config contains only `primary` and `cable` (`config/database.mysql.yml:20-27` there). R11 and S6, the database-routing spike, cover this risk.
- **Forced reloading adds request-time reloading.** Rails inserts `ActionDispatch::Reloader` (`railties-7.2.4/lib/rails/application/default_middleware_stack.rb:64-66`). With `TOUCH=1`, a changed file triggers another reload during a fork's request. It recompiles the deleted tempfile and returns status 500, causing a false kill. R16 addresses this.
- **Rails class-body defects #378, #383, #384, and #385 already have a fix.** #391 closes them on `reload`, plus #390, duplicate validators and block callbacks. Full reload provides another solution.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Add `full_reload` to `--strategy`.** It selects placement, like `reload` and `redefine`. Preserve it in `validate_daemon!`, which currently rewrites other values to `reload` with a warning (`lib/mutineer/cli.rb:506-511`). Reject a separate `rails_reload: full` boolean: two settings would describe one choice. Reject the prototype's `rails_reload` name: `full_reload` pairs with `reload` and matches the issue title.
- KTD2. **Use `RubyVM::InstructionSequence.load_iseq` and `compile_file` on a hidden tempfile.** Prepend to the instruction-sequence singleton class only in mutant forks. `apply_payload` already writes an adjacent hidden tempfile. For the target's real path, return `compile_file` of that tempfile and increment a counter. Keep reload and eager load inside the tempfile block, which deletes the file on exit (`lib/mutineer/daemon_server.rb:481-488`). For other paths, call available `super` or return `nil` for normal compilation. P2 verifies Rails 7.2.4 with Bootsnap 1.26.1. Reject `RubyVM::InstructionSequence.compile` of mutant strings. It preserves `__FILE__` (P1), but restores dynamic string execution removed in 0.6.1 for scanner flags (`CHANGELOG.md:1796-1799`). Q2 keeps that decision open. Reject the runtime gem `require-hooks`. Reject symlinked autoload roots: Zeitwerk refuses duplicate directory management (`symlink-zeitwerk.txt`). Reject real-file writes like `FileSwap`: workers share that file.
- KTD3. **Enable reloading inside the daemon before boot.** Watch for `Rails::Application::Configuration`, following `install_zeitwerk_ignore!` and its `Zeitwerk::Loader` watch (`lib/mutineer/daemon_server.rb:392-415`). Prepend a `cache_classes=` writer that always stores `false`. Rails routes `enable_reloading=` through it (`railties-7.2.4/lib/rails/application/configuration.rb:349-355`), covering both settings in `config/environments/test.rb`. After boot, check `Rails.application.config.reloading_enabled?` and the main autoloader (R5). After each fork's reload, set `Rails.application.reloader.check` to a lambda returning `false` (R16). This prevents request-triggered reloads through `ActionDispatch::Reloader`; S12 verifies it. Reject user-written boot files, which every user would copy. Reject middleware removal, which changes the app's test stack.
- KTD4. **Follow the app's eager-load setting.** Add no boot `eager_load!` (R4). After reload, call `eager_load!` only if `config.eager_load` is true. Covering tests already reached the mutated line (`lib/mutineer/daemon_backend.rb:425-446`). After reload, they autoload its constant through the hook (P1 with `LAZY=1`). Thus R9 checks after tests. Reject forced boot eager loading. Coverage starts before boot (`lib/mutineer/daemon_server.rb:160-163`); the later peek records load lines (`lib/mutineer/coverage_map.rb:143-144`). Forced eager loading adds class-body calls to those lines. Probe R-A records no lazy boot hits and one with `EAGER=1`. `JobPlan.load_verdict` then excludes more survivors as `ran_at_load`, raising the score relative to `reload`. Reject forced fork eager loading unless S5 finds missed mutants.
- KTD5. **Use a boot list and a fork counter.** Ask each reloading Zeitwerk loader whether it manages each source through `Loader#cpath_expected_at`. Installed gems confirm availability in Zeitwerk 2.6.17 and 2.8.x, but not 2.6.0. Rails permits `zeitwerk ~> 2.6` (`test/fixtures/rails_app/Gemfile.lock:181`); R6 rejects loaders without the method. Missing paths raise `Zeitwerk::Error` (`zeitwerk-2.8.3/lib/zeitwerk/loader.rb:293`). Check existence first and treat that exception as unmanaged. Return unmanaged files in the ready reply and score their mutants `unplaceable` (R8). The KTD2 counter catches missed cases (R9). Reject counter-only checks: whole unmanaged files would score `error` and fail `--threshold`. Reject observation during a clean reload: lazy loading would falsely classify unreached managed files. Reject `load` fallback after reload (`lib/mutineer/daemon_server.rb:479-488`). It would mix placement rules and restore #391 class-body guards. S8 measures exclusions per app; Q9 revisits fallback with those counts.
- KTD6. **Reuse the clean check for reload safety.** After the existing fork hook, each `full_reload` clean fork reloads and conditionally eager loads before tests. Clean checks already run on cache hits through `verify_cached_clean` and `verify_combined_clean` (`lib/mutineer/coverage_map.rb:404-405`), and misses (`:411`). Their forks call the daemon hook (`lib/mutineer/daemon_server.rb:323-330`). Red results reach `JobPlan.abort_if_unclean!` (`lib/mutineer/daemon_backend.rb:250`), raise `SmokeCheckError`, and exit 1 (`lib/mutineer/cli.rb:380-384`). Give `CoverageMap` a separate clean-fork hook. Capture forks keep today's hook and do not reload, preserving the `reload` coverage map. `verify_combined_clean` skips fewer than two test files (`lib/mutineer/coverage_map.rb:821`), leaving single-file cache misses without a clean fork. Run it for one file under `full_reload`; S11 verifies this. If #398 Step A (the narrowed clean check) has merged, take `runnable` from `clean_check_test_paths` minus failed captures. Keep the one-file exception for `full_reload` only. Run the per-file fallback over that same set. Under #398 R14, retried captures skip the alone check. So under `full_reload` they still need the reloading combined fork. On a cache miss, only that combined fork reloads. A failure there records the literal "combined suite" (`lib/mutineer/coverage_map.rb:829`), not file names. Capture forks do not reload, so they record no red file (`:760-761`). Under `full_reload`, when the combined fork fails, call `verify_cached_clean(after_fork: <clean hook>)` with each runnable file. Replace "combined suite" with the red file names. This extra cost applies only on failure. The `reload` strategy still records "combined suite". Reject the earlier `reload_check` command unless S11 fails. That draft wrongly claimed cache hits skip clean checks, contradicted by `lib/mutineer/coverage_map.rb:404-405`. A new command adds another full test run, protocol message, and serial/parallel wiring. Reject per-worker checks because cost scales with workers. Reject docs-only handling because false kills would reach scores.
- KTD7. **Route, reload, then verify every pool.** Keep routing before mutant application (`lib/mutineer/daemon_server.rb:357-360`), protecting queries from reloaded class bodies. After reload and eager load, route again unconditionally. Check `connection_handler.connection_pool_list(:all)` against worker and shared database names. #335, SQLite copies per parallel worker, adds `recheck_routing!` and `verify_routing!` (`origin/feat/332-suffix-all-sqlite-databases:lib/mutineer/rails_worker_db.rb:453`, `:622`). U4 reuses it after merge. That check covers only SQLite pools (`rails_worker_db.rb:622-646` on #335). For Postgres and MySQL, U4 adds a pool-list check. It compares each pool's `db_config.database` with the worker database name from `per_worker_config` and with the shared names. A mismatch scores `error`. Otherwise, add the equivalent check in `lib/mutineer/rails_worker_db.rb` and retain one copy after merging. Failed checks score `error`. Reject `ActiveRecord::Base`-only checks: reading roles and other abstract-class pools could escape. Reject routing only after reload: class-body queries could reach shared databases.
- KTD8. **Bypass `ConcernBlocks` and #391 guards under `full_reload`.** Fresh classes run their bodies once, so neither mechanism is needed. Send the raw mutated file without `hook_def`. `Subject#unplaceable?("full_reload")` returns `false` (R10). Keep #391's `maintain_test_schema` skip in `run_mutant` for every strategy.
- KTD9. **Support daemon and Minitest only.** The proposed 2.0 default uses the daemon (`STABILITY.md:115-120`). In-process runs fork from the tool and share its boot, requiring another design. R2 rejects them; Q7 tracks follow-up.
- KTD10. **Keep statuses and the existing `ran_at_load` rule until S8 decides (R15).** `JobPlan.load_verdict` changes only survivors to `ran_at_load` (`lib/mutineer/job_plan.rb:353-356`). Excluding them from the denominator raises scores (`lib/mutineer/result.rb:228`), contrary to an earlier draft. Reloaded class bodies run with the mutant (R-B: `Widget.flags=[:mutant]`), so some excluded survivors are real. Initializers do not rerun. The boot peek cannot distinguish them. R4 preserves equal boot load lines and `ran_at_load` sets across strategies. S8 checks each mutant against `--test-command`. Reject immediate removal of `load_verdict`: S8 has not established initializer frequency. Reject unchanged "cannot re-run" text because it is false under `full_reload`. Stale class references can still falsely survive. R14 documents this; U7 files issues for both limitations. This rule covers `def` subjects. #397 PR3 exempts macro subjects (its KTD9).
- KTD11. **Classify as minor; retain `v2.0` and draft status until Q5.** Adding an opt-in value is not breaking. However, `main` ships in the next 1.x release (`AGENTS.md:167-169`), while labels name target releases (`AGENTS.md:94`). Reject a non-draft `v2.0` pull request because merging would contradict its label. Reject immediate retargeting to 1.x because the maintainer selected the issue's `v2.0` label.
- KTD12. **End `full_reload` runs on boot refusal.** Today, initial `DaemonBootError` failures warn about coverage fallback and continue without a map (`lib/mutineer/daemon_backend.rb:149-152`, `:171-178`). R5 and R6 refusals would follow that path, then recur in every worker. Make `prepare_run` re-raise under `full_reload`; the CLI prints the error and exits 1 (`lib/mutineer/cli.rb:393-397`). `execute` uses `prepare_run` for `--jobs 1` and `--jobs N` (`:84-91`). `build_coverage_map` is test-only (`lib/mutineer/daemon_backend.rb:513-516`). Reject fallback because its warning hides the cause.
- KTD13. **Include forced reloading in the coverage digest.** `compute_digest` lacks strategy input (`lib/mutineer/coverage_map.rb:1415-1433`), while cache hits reuse maps (`:390-393`). Add one forced-reloading group only under `full_reload`, preserving existing `reload` caches. Pass the strategy to `CoverageMap.new` (`lib/mutineer/daemon_server.rb:281-287`). Reject strategy hashing for every run because it invalidates all caches once. Cross-strategy `--coverage-from` captures can still fail `load_mismatch` with the existing message (`lib/mutineer/coverage_map.rb:500-505`). R4 makes this rare. If #398 Step B (per-test cache invalidation) has merged, also add the forced-reloading flag to `run_inputs` (#398 R8). Then a cache from another strategy forces full capture.

### How this meets the #284 checklist

#284 tracks daemon and reload preconditions for the 2.0 default. Its text was not checked: it is absent from the context folder, and this job avoids `gh`.

The three validation reports request these gates. This plan supplies evidence without changing defaults. "Sol", "Grok" and "Opus" name these reports, and A13 and A15 are their sections:

- Sol: `/Users/davidteren/Projects/DT/mutineer/wip/vlad/Sol/2026-11-09-deep-validation-report.md`
- Grok: `/Users/davidteren/Projects/DT/mutineer/wip/vlad/grok-cursor/2026-11-09-deep-validation-report.md`
- Opus: `/Users/davidteren/Projects/DT/mutineer/wip/vlad/opus/2026-11-09-deep-validation-report.md`

| Gate the reports ask for | What this plan supplies |
|---|---|
| Verdicts equal a fresh process (Sol A13, Grok A13) | S8 compares `full_reload` with `--test-command` on the fixture and Fizzy sample. |
| Lazy and eager load (Sol A13) | S5 covers both loading modes. |
| Worker counts 1 and N (Sol A13) | S8 uses `--jobs 1` and `--jobs 4`. |
| Three apps, one on Postgres (Sol A13) | This plan covers the fixture and Fizzy. S6 tests SQLite, MySQL, and Postgres on the fixture. S9's second app moves to a follow-up issue linked from #284. |
| Unplaceable count per strategy (Opus A13) | S8 records `unplaceable` for `reload` and `full_reload`. Expected #284 parity differences: `full_reload` places previously unplaceable hook-block defs (R10), but excludes unmanaged sources (R8). |
| Reload-unsafe initializers (Opus A15) | R12 and S3 cover detection. |

### Assumptions

No user has confirmed these assumptions.

- Hidden-tempfile `__FILE__` values are acceptable for call-time reads because `reload` already uses them (KTD2, Q2). Class-creation hooks differ: `inherited` records the tempfile, breaking sidecar lookup (R-C: `template_found=false`). S8 measures verdict changes; U7 documents and files the limitation.
- Rails 7.1 is the floor. Rails 7.0 remains unchecked; it lacks `enable_reloading` but has `cache_classes=`, so it might work. U7 files Rails and Zeitwerk floor issues.
- One reload per clean fork is acceptable. It adds no second test run (KTD6, Q3).
- The #389 `v2.0` label remains the target (Q5).

### High-Level Technical Design

Change the first daemon's boot and clean check, then add a mutant-fork path.

```mermaid
sequenceDiagram
  participant T as Tool (DaemonBackend)
  participant D0 as First daemon
  participant W as Worker daemon
  participant F as Mutant fork
  T->>D0: boot (strategy full_reload)
  Note over D0: reloading forced on, boot, require files (app's own eager_load)
  D0-->>T: ready + unreloadable sources (or refusal: run ends, exit 1)
  T->>D0: coverage map (cache or capture)
  Note over D0: capture forks as today; each clean-check fork reloads first
  D0-->>T: map + red clean tests (abort_if_unclean!, exit 1 when any)
  T->>W: run mutant (raw mutated file, no hook_def)
  W->>F: fork
  Note over F: route worker db, arm load_iseq hook for the target
  Note over F: reloader.reload!, eager_load! when the app does, reloader check off
  Note over F: route again, verify every pool
  Note over F: run covering tests, check counter, exit 0, 1 or 2
  W-->>T: verdict
```

| Strategy | Daemon allowed | Hook-block def with no `reload_hook_call` | Payload |
|---|---|---|---|
| `reload` | Yes | `unplaceable` | Mutated file; `hook_def` when present |
| `redefine` | No; currently rewritten to `reload` | `unplaceable` (`owner_unknown`) | Not sent |
| `full_reload` | Required | Placeable | Raw mutated file |

### Probe results

Scripts and output are in `CTX/probes/389/`. `CTX` is this planning job's context folder. All probes used MRI 3.4.9, Rails 7.2.4, Bootsnap 1.26.1, and an earlier validation probe's Gemfile.

- P1. **String-compilation probe:** `iseq_reload_probe.rb` and `.out` rerun Sol's validation. A fork prepends `load_iseq`, compiles mutant text at the real path, then calls `reloader.reload!` and `eager_load!`. With reloading enabled, the mutant applies (`changed`); `source_location`, `__dir__`, and `require_relative` match; one validator remains one. A macro mutant applies (`macro_probe_amount_1_valid=false`). `LAZY=1` and `WITHOUT_BOOTSNAP=1` also pass. A symlinked target matches by real path. With reloading off, zero hook hits leave original code running without error. Every reloading case loses `after_initialize` state and retains old classes in a boot registry.
- P2. **File-compilation probe:** `iseq_compile_file_probe.rb` and `.out` repeat P1 using an adjacent hidden tempfile and `compile_file`. The mutant applies; `__dir__` and `require_relative` match; `$LOADED_FEATURES` holds the real path. `__FILE__` and `source_location` name the tempfile. Eager and lazy cases pass, and the tempfile is removed. Every output block says `bootsnap=1.26.1`; Bootsnap-free execution remains untested.
- P3. **Saved reports:** `fizzy_saved_reports.out` shows byte-identical patched and full-reload JSON for both samples. Models: 53 mutants, 30 killed, 16 survived, 0 errored. Controllers: 30, 22, 7, 0. An initial `NoMethodError` and identical survivor digests across four files invalidate that digest evidence. Only file hashes support equivalence.
- P4. **Fizzy configuration reads:** `config/environments/test.rb:12` sets `enable_reloading = false`; `:18` sets `eager_load` from `CI`. `config/initializers/multi_tenant.rb` now sets `Account.multi_tenant` in `to_prepare`.
- P5. **Adversarial probe:** `refute_probe.rb` and `.out` use the fixture bundle, Rails 7.2.4, and Zeitwerk 2.8.3. R-A finds no lazy boot hits for a class-body method call, versus one with `EAGER=1`. R-B confirms the class body runs with the mutant after full reload. R-C finds that `inherited` records the tempfile path and loses its sidecar template. Loading over the existing class preserves the real path.
- P6. **Routing and middleware probe:** `redesign/route_and_middleware_probe.rb` and `.out` were run by the second designer on SQLite. Reloading adds `ActionDispatch::Reloader`. With `CONNECTS_TO=1`, the post-reload pool is `shared.sqlite3`, and a create writes one row there. With `TOUCH=1`, a request triggers another reload and returns 500.

Unchecked: Rails 8.x, Zeitwerk 2.6.x behaviour, Ruby below 3.4.9, MySQL, Postgres, and time cost. U1 covers these.

---

## Implementation Units

### U1. Spike: prove the mechanism on real apps (no merge)

**Goal:** Resolve central questions before U2. Merge no code to `main`; report evidence under `CTX/reports/` or in the pull request body.

**Time box:** Two working days. Stop then and report known results.

**Method:** Implement KTD2, KTD3, and KTD4 on a throwaway branch in `lib/mutineer/daemon_server.rb`. Use a fresh scratch clone of `palkan/fizzy` at commit `f220e4832bf40b6f4d4f944253d7a7731d366d37`, the pin that #402 and #349 use. Never use the shared clone. Set up as #402 KTD2, KTD5 and KTD6 do. Write a `.mutineer.yml` with `rails: true`, `daemon: true`, `shared_databases: [cable]` and no `require:` key. Use Ruby 3.4.8, with `RBENV_VERSION` and the rbenv version bins dropped. Set `SAAS=false DATABASE_ADAPTER=sqlite RAILS_ENV=test`, with `CI` and `SEED` unset. Run the spike build as `<absolute ruby> <spike checkout>/bin/mutineer`. Never use Fizzy's `bin/mutineer`: it runs the locked gem 1.8.0. If #402 (the pinned Fizzy sample check) has merged, reuse its cache clone and bootstrap. Include the eight #402 sample files. Then the `reload` run can be checked against `rake/fizzy_sample.json` when it exists. Prefix every command with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`.

| Spike | Question | Command or method | Pass | Fail, and what the plan does |
|---|---|---|---|---|
| S1 | Does KTD2 work on Rails 8.2.0.alpha with and without Bootsnap? | Rerun P2 under Fizzy's Gemfile, normally and with `WITHOUT_BOOTSNAP=1`. Run `<absolute ruby> <spike checkout>/bin/mutineer` twice on the nine-file sample using the same spike build. First use `--daemon --rails --strategy reload --jobs 8 --format json`, then `--strategy full_reload`. | Counter 1 per fork, 0 errors, identical survivor ids. Saved 1.8.x reports are unsuitable oracles because 2.0 mutant ids differ. | Stop and report to the maintainer. Present Q2's string compilation as a possible fallback. |
| S2 | Does KTD3 enable reloading? | Boot fixture and Fizzy daemons. Print `reloading_enabled?` for app config and `Rails.autoloaders.main`; run the clean suite. | Both values are `true`; the clean suite passes. | Stop and ask the maintainer. KTD3 rejects user boot files, so the prototype's boot-file approach needs a maintainer decision. If approved, make R4 a check with a clear error. |
| S3 | Does R12 catch unsafe initializers? | In scratch Fizzy, move `Account.multi_tenant` to `after_initialize`. Run with an empty cache and a cache hit, then restore it. | Both runs exit 1 before mutants and name the bundle test. Restored code runs. | Keep R12, document the failing pattern, and report what the check missed. |
| S4 | Are hook-block defs placed? | Test a fixture concern whose `included` def is `unplaceable` under `reload`. | Its mutants run and are killed under `full_reload`. | Keep these mutants `unplaceable` and document the cause. |
| S5 | Do lazy forks miss mutants, and what does forced eager loading cost? | Run Fizzy with `eager_load` off, its default without `CI`. Compare KTD4 with forced `eager_load!` per fork. Record time, counters, and verdicts. | Every lazy-fork counter is 1; verdicts equal the forced run. | Force `eager_load!` per fork, never at boot. Move R9's counter check before tests. |
| S6 | Does worker routing survive reload on SQLite, MySQL, and Postgres? | Apply patterns from `test/rails_dogfood_daemon_test.rb`, `test/daemon_mysql_test.rb`, and `test/daemon_postgres_test.rb` with `full_reload`. Add env-controlled `connects_to` to fixture `ApplicationRecord`, including a replica `reading` role. Log every `connection_pool_list(:all)` pool's database file or name before and after reload. | KTD7 keeps every pool and both roles on worker databases. | Try routing only after reload, KTD7's rejected order, and measure again. |
| S7 | What does one mutant cost? | On Fizzy, measure median `reload!` time, plus `eager_load!` when enabled. Compare median mutant test time and total wall time with `--strategy reload` using #391 guards. | Median reload is at most 1.0 s per fork. Test time stays within 10% of `reload`. | Over 2.0 s: stop and ask. Between the limits: document cost. Test time over 10% above `reload`: document cost and ask the maintainer. |
| S8 | Do verdicts equal fresh-process verdicts? | Compare fixture and Fizzy `full_reload` runs with `--test-command` at `--jobs 1` and `--jobs 4`. Record `unplaceable`, unmanaged files, and `ran_at_load` per strategy. Compare each `ran_at_load` verdict with `--test-command`. Add the `inherited` sidecar fixture from R-C. | Verdicts match per mutant id. `reload` and `full_reload` have equal `ran_at_load` sets. Explain and file every difference. | Unexplained differences block work: stop and ask. If every reloaded-file `ran_at_load` mutant survives under `--test-command`, U5 skips `load_verdict` for those files. Otherwise retain R15's rule and file the evidence in U7. |
| S9 | Does a second app work? This is not a gate. | Test two models and one concern in `rubygems/rubygems.org`, which uses Minitest and Postgres. Q4 permits another app. Run outside the time box. | S1, S2, and S8 pass. | U7 files the result in a follow-up issue linked from #284. No implementation unit changes. |
| S10 | Which Ruby and Zeitwerk versions support the hook and loader method? | Run `ruby -e 'p RubyVM::InstructionSequence.respond_to?(:compile_file)'` and P2 on installed 3.2, 3.3, 3.4, and 4.0 versions. Run `ruby -e 'require "zeitwerk"; p Zeitwerk::Loader.method_defined?(:cpath_expected_at)'` under installed Zeitwerk 2.6.x versions. Find the first supporting 2.6.x release. | All MRI versions pass; the first supporting Zeitwerk version is known. | R6 names unsupported Ruby and Zeitwerk versions. |
| S11 | Can the clean check provide reload safety (KTD6)? | Add a clean-fork hook after the existing fork hook. Test fixture cache misses and hits, one and several test files, and `MUTINEER_RELOAD_UNSAFE=1`. Compare maps with `reload`. | Unsafe runs exit 1 on both cache paths, including a single-file cache miss. The message names the red test file. Safe runs pass; maps equal `reload`. | Use the earlier `reload_check` daemon command, still exiting 1 through `SmokeCheckError`. Correct KTD6. |
| S12 | Does disabling the check prevent another reload (R16)? | Repeat P6 with `TOUCH=1`. After the fork's reload, set `Rails.application.reloader.check` to `-> { false }`. | `hits=1`, `status=200`, body `mutant`. | Remove `ActionDispatch::Reloader` inside the fork and measure again. |

**Verification:** Record every row's result, pass status, and resulting plan changes.

### U2. The strategy value, its validation, and the subject rule

**Goal:** Parse and validate `--strategy full_reload`; make hook-block subjects placeable.

**Requirements:** R1, R2, R3, R10.

**Dependencies:** U1.

**Files:**

- `lib/mutineer/config.rb`: add `full_reload` to `strategy` values (`:69-70`).
- `lib/mutineer/cli.rb`: update usage (`:67`), `validate_test_command!` (`:470-474`), and `validate_daemon!` (`:491-512`) for R2 and KTD1. Reject `full_reload` without `--daemon`.
- `lib/mutineer/subject.rb`: return `false` from `unplaceable?` for `full_reload` (`:53-55`); document the third value.
- `test/config_test.rb`, `test/cli_test.rb`, `test/cli_daemon_test.rb`, `test/subject_test.rb`.

**Approach:** Use existing usage errors: `warn` and `exit 2`. Keep `Config.resolve`'s in-process `--rails` default as `redefine` (`lib/mutineer/config.rb:250-252`). Explicit `full_reload` already bypasses it through `explicit?(:strategy)`.

**Patterns to follow:** `validate_test_command!`'s `redefine` rejection and its tests in `test/cli_test.rb`.

**Test scenarios:**

- `test_strategy_accepts_full_reload` (`test/config_test.rb`): `Config.parse(:strategy, "full_reload")` returns `"full_reload"`.
- `test_full_reload_with_daemon_is_kept` (`test/cli_daemon_test.rb`): `--rails --daemon --strategy full_reload` preserves the value without a forced-`reload` warning.
- `test_full_reload_without_daemon_exits_2`: cover AE4; stderr names `--daemon`.
- `test_full_reload_with_test_command_exits_2`.
- `test_full_reload_with_boot_but_no_rails_exits_2`.
- `test_full_reload_with_rspec_exits_2`: assert that the existing RSpec rejection runs first.
- `test_dry_run_validates_full_reload`: cover R3; `--dry-run --rails --strategy full_reload` without `--daemon` exits 2.
- `test_redefine_with_daemon_still_rewrites_to_reload`: preserve current behaviour.
- `test_hook_block_subject_is_placeable_under_full_reload` (`test/subject_test.rb`): use `hook_block: true` and `reload_hook_call: nil`. Require `unplaceable?("reload")` but not `unplaceable?("full_reload")`.

**Verification:** All four test files pass in the zero-dependency suite.

### U3. The app-side full reload module

**Goal:** Use stdlib only to force reloading, substitute mutant text, and count substitutions.

**Requirements:** R4, R5, R6, R7, R9, R16.

**Dependencies:** U1.

**Files:**

- `lib/mutineer/full_reload.rb` (new): define `Mutineer::FullReload`. Like `concern_blocks.rb`, load without Prism or the remaining gem.
- `test/full_reload_test.rb` (new): run in the zero-dependency suite.

**Approach:**

1. Install KTD3's writer through a `TracePoint`, following `install_zeitwerk_ignore!`. Verify reloading after boot (R5). Check the hook and `Zeitwerk::Loader#cpath_expected_at`; name unsupported versions (R6).
2. In each fork, accept the target's real path and tempfile path. Prepend KTD2's module once and reset the counter.
3. Call `Rails.application.reloader.reload!`, then `Rails.application.eager_load!` only when `config.eager_load` is true (KTD4). Set `Rails.application.reloader.check` to `-> { false }` (R16).
4. After tests, raise with the filename if the counter is zero (R9).
5. Report sources unmanaged by reloading loaders (KTD5). Check existence before `cpath_expected_at`; treat `Zeitwerk::Error` as unmanaged.

Document every method and constant with YARD.

**Patterns to follow:** Use `lib/mutineer/concern_blocks.rb` for stdlib-only loading and `lib/mutineer/daemon_server.rb:392-415` for the `TracePoint` watch.

**Test scenarios:** Each initially fails with `LoadError` for the new file. Isolate Rails stand-ins and `RubyVM::InstructionSequence` prepends in forks or subprocesses.

- `test_armed_hook_substitutes_on_require`: a temporary `widget.rb` returns `:original`. Arm its real path with a mutant returning `:mutant`. Require `:mutant` and counter 1.
- `test_armed_hook_substitutes_on_load`: repeat through `load`.
- `test_substitution_keeps_dir_and_require_relative`: mutant `require_relative "sibling"` and `__dir__` resolve against the original directory.
- `test_loaded_features_holds_the_real_path`: after `require`, `$LOADED_FEATURES` contains the original path, not the tempfile.
- `test_other_files_compile_normally`: another file loads its own text; counter remains 1.
- `test_target_reached_through_a_symlink_matches`: match a target reached through a symlinked directory.
- `test_hook_composes_with_an_existing_load_iseq`: an existing stand-in `load_iseq` counts calls. Non-target files reach it; the target does not.
- `test_parent_stays_unhooked`: after fork exit, parent `require` loads original text.
- `test_zero_substitutions_raises_with_the_file_name`: cover AE5; raise and name the file.
- `test_forced_writer_keeps_cache_classes_false`: define stand-in `Rails::Application::Configuration` after installing the watch. Both `cache_classes = true` and `enable_reloading = false` leave `cache_classes` `false`.
- `test_missing_cpath_expected_at_refuses_with_the_zeitwerk_version`: cover R6 with a method-free stand-in `Zeitwerk::Loader` and `Zeitwerk::VERSION` of `2.6.0`. Raise and name both the method and `2.6.0`.
- `test_unmanaged_check_survives_a_missing_path`: a stand-in loader raises `Zeitwerk::Error` from `cpath_expected_at`. Report the path as unmanaged without propagating the exception.
- `test_eager_load_follows_the_app_setting`: false `eager_load` causes no `eager_load!` call after reload; true causes one.
- `test_reloader_check_is_off_after_the_reload`: the stand-in reloader's `check` returns `false`.
- `test_loads_without_prism`: a fresh Ruby requires `lib/mutineer/daemon_server.rb` and `lib/mutineer/full_reload.rb`; `Prism` remains undefined.

These tests cover the hook and writer. U6 covers actual Rails and Zeitwerk behaviour.

**Verification:** The new test file passes. `bundle exec rake yard:strict` remains at 100%.

### U4. Wire the daemon server and the protocol

**Goal:** Boot, place mutants, and reload every clean-check fork under `full_reload`.

**Requirements:** R4, R5, R8, R9, R11, R12, R16, R17.

**Dependencies:** U3. #335 (a SQLite copy per parallel daemon worker) when it has merged, for its all-pool routing check (KTD7).

**Files:**

- `lib/mutineer/daemon_server.rb`: update the protocol comment (`:29-41`). In `boot!` (`:151-190`), install the writer for `full_reload`, add no eager load, and return unmanaged sources. In `build_coverage_map` (`:278-298`), pass strategy to `CoverageMap.new` (KTD13). Add a clean-check hook that reloads after `coverage_after_fork` (KTD6). In `run_mutant` (`:341-383`), reroute and verify all pools after reload (KTD7); check substitution after tests (R9). Add the `full_reload` branch to `apply_payload` (`:479-493`) (KTD8).
- `lib/mutineer/coverage_map.rb`: add `clean_after_fork:` for `fork_clean_pass?` (`:958-970`), replacing `after_fork` when supplied. Keep `after_fork` in capture forks (`fork_capture`, `:626-645`). Run `verify_combined_clean` (`:819-830`) for one file under `full_reload`. Under `full_reload`, a failed combined fork calls `verify_cached_clean` per runnable file and records those names (KTD6). Add the forced-reloading digest group only under `full_reload` in `compute_digest` (`:1415-1433`).
- `lib/mutineer/daemon_client.rb`: retain unmanaged files from the ready reply for backend access.
- `lib/mutineer/rails_worker_db.rb`: reuse #335's `recheck_routing!` and `verify_routing!` after merge. Otherwise add the equivalent pool-list check from `origin/feat/332-suffix-all-sqlite-databases:lib/mutineer/rails_worker_db.rb:453` and `:622`. Reuse `after_fork` configuration (`:400-416`). That check covers only SQLite pools (`rails_worker_db.rb:622-646` on #335). For Postgres and MySQL, U4 adds a pool-list check. It compares each pool's `db_config.database` with the worker database name from `per_worker_config` and with the shared names. A mismatch scores `error`.
- `test/daemon_client_test.rb`, `test/daemon_server_hook_def_test.rb`, `test/coverage_map_test.rb`.

**Approach:** Preserve `apply_payload`'s tempfile, `flock`, and sweep rules. Write the mutant, arm `FullReload`, reload, and run tests inside the tempfile block (KTD2, R16). Never call `ConcernBlocks.load_mutant`. Reject `hook_def` in a `full_reload` payload as a defect.

**Patterns to follow:** Use `coverage_after_fork` for daemon-built hooks. Preserve `run_mutant`'s fork, process group, and deadline.

**Test scenarios:**

- `test_ready_reply_lists_unreloadable_sources` (`test/daemon_client_test.rb`, daemon suite): list an unmanaged `lib/` fixture source, but not a model.
- `test_boot_refuses_when_reloading_stays_off`: cover R5 with the fixture switch that disables reloading after the forced writer. Require `DaemonBootError` naming reloading.
- `test_full_reload_clean_check_passes_on_a_safe_app`: `failed_clean_tests` is empty.
- `test_full_reload_clean_check_names_the_red_file`: cover AE2. With `MUTINEER_RELOAD_UNSAFE=1`, `failed_clean_tests` names the file on cache misses and hits.
- `test_reload_strategy_clean_check_does_not_reload` (`test/daemon_client_test.rb`): `MUTINEER_RELOAD_UNSAFE=1` stays green under `reload`, confirming strategy-specific reloads.
- `test_full_reload_payload_with_hook_def_errors` (`test/daemon_server_hook_def_test.rb`): require `error` and stderr naming the key.
- `test_clean_after_fork_is_used_only_by_clean_forks` (`test/coverage_map_test.rb`): call the counting `clean_after_fork` lambda once per clean fork, never during capture.
- `test_combined_clean_runs_for_one_file_under_full_reload` (`test/coverage_map_test.rb`): `verify_combined_clean` forks for one file under `full_reload`, but skips under `reload`.
- `test_failed_combined_clean_names_files_under_full_reload` (`test/coverage_map_test.rb`): a stubbed combined fork fails, and one file fails alone. Under `full_reload`, `failed_clean_tests` holds that file name, not "combined suite". Under `reload`, it still holds "combined suite".
- `test_digest_changes_only_under_full_reload` (`test/coverage_map_test.rb`): preserve today's `reload` digest; require a different `full_reload` digest.

**Verification:** `bundle exec rake test` passes, including `test/daemon_server_hook_def_test.rb` and `test/coverage_map_test.rb` (`Rakefile:7-16`, `:23`). `bundle exec rake test:daemon` passes with the new `test/daemon_client_test.rb` cases.

### U5. The tool side: boot config, payload, unplaceable, and the check

**Goal:** Send strategy and raw payloads, stop on boot refusal, and score unreloadable sources.

**Requirements:** R5, R8, R10, R12, R13, R15.

**Dependencies:** U2, U4.

**Files:**

- `lib/mutineer/daemon_backend.rb`: add `strategy` to `boot_config` (`:467-494`). In `job_result` (`:416-447`), use `subject.unplaceable?(config.strategy)` and omit `hook_def` under `full_reload`. Score unreloadable-source subjects `unplaceable`. When S8 selects it under R15, skip `JobPlan.load_verdict` under `full_reload` for files the reload compiled. In `prepare_run` (`:165-178`), re-raise `DaemonBootError` under `full_reload` instead of falling back (KTD12). `execute` uses this production path for `--jobs 1` and `--jobs N` (`:84-91`). Leave test-only `build_coverage_map` (`:513-516`) unchanged. Print R8's stderr line once.
- `lib/mutineer/job_plan.rb`: append the `to_prepare` hint in `abort_if_unclean!` (`:177-190`) only under `full_reload`.
- `lib/mutineer/reporter.rb`: add the third cause to the comment and human "Unplaceable" line (`:806-809`). Remove "cannot re-run that" from the `full_reload` "Ran at load" line (`:812-813`) (R15).
- `test/daemon_backend_contract_test.rb`, `test/runner_test.rb` (already tests `abort_if_unclean!`), `test/reporter_test.rb`.

**Approach:** Keep `--jobs 1` and `--jobs N` on shared `job_result`, as its comment requires (`:400-403`). Obtain unreloadable files from the first daemon's ready reply, like database names.

**Test scenarios** (stubbed client, zero-dependency suite):

- `test_full_reload_payload_is_the_raw_mutated_file`: a hook-block subject with `reload_hook_call` sends unchanged mutated text without `hook_def`.
- `test_full_reload_places_a_subject_reload_cannot`: `hook_block: true` without `reload_hook_call` sends a request instead of scoring `unplaceable`.
- `test_reload_strategy_payload_is_unchanged`: preserve `reload` payloads and `hook_def`.
- `test_unreloadable_source_scores_unplaceable`: cover AE3; send no request and increment `unplaceable_count`.
- `test_unreloadable_sources_warn_once`: list every unreloadable file in one stderr line.
- `test_red_clean_check_under_full_reload_stops_the_run`: return a red clean test from the stubbed coverage reply. Require `SmokeCheckError` (exit 1), each filename, and the `to_prepare` hint. Test `--jobs 1` and `--jobs 2` through `prepare_run`.
- `test_unclean_message_has_no_to_prepare_hint_under_reload` (`test/runner_test.rb`): preserve today's message.
- `test_boot_refusal_ends_the_run_under_full_reload`: cover AE6 with a stubbed `DaemonBootError` carrying R5's message. Re-raise it without a coverage-fallback warning at `--jobs 1` and `--jobs 2`.
- `test_boot_error_still_falls_back_under_reload`: preserve today's fallback.
- `test_ran_at_load_line_under_full_reload` (`test/reporter_test.rb`): omit "cannot re-run" under `full_reload`; preserve `reload` wording.
- `test_boot_config_carries_the_strategy`.

**Verification:** The zero-dependency suite passes. New `unplaceable` results enter the unrun-share warning without changes to `lib/mutineer/result.rb`.

### U6. Fixture app and daemon integration tests

**Goal:** Prove AE1 to AE6 in Rails and convert each spike reproduction into a fixture.

**Requirements:** R4, R5, R7, R8, R9, R10, R11, R12, R15, R16.

**Dependencies:** U4, U5.

**Files:**

- `test/fixtures/rails_app/config/initializers/reload_unsafe.rb` (new): set a class attribute in `after_initialize` only with `MUTINEER_RELOAD_UNSAFE=1`.
- `test/fixtures/rails_app/lib/fixture_rounding.rb` (new) and its requiring initializer: provide an unmanaged source.
- `test/fixtures/rails_app/app/models/concerns/`: add a concern and test with an `included` def that `reload` marks `unplaceable`. Reuse #391's `Trackable` after merge.
- `test/fixtures/rails_app/app/models/application_record.rb`: add env-controlled `connects_to` with a `reading` role for S6.
- `test/fixtures/rails_app/config/database.yml`: add a replica configuration read only with that env switch.
- Add a fixture class that records its source path through `inherited` and reads a sidecar file. Cover S8 and R7's limitation.
- `test/rails_full_reload_daemon_test.rb` (new).
- `Rakefile`: add the new test file to `DAEMON_TESTS`.

**Approach:** Run the CLI under the fixture bundle, following `test/rails_dogfood_daemon_test.rb`. Assert exact per-mutant-id verdicts against `--test-command`; error counts alone cannot prove the setup (R14).

**Execution note:** Start with AE2. It fails before U4 and U5 and proves initializer detection.

**Test scenarios:**

- `test_full_reload_matches_test_command_on_enum_and_concern`: cover AE1 with identical per-id verdicts at `--jobs 1` and `--jobs 2`.
- `test_full_reload_kills_an_included_block_mutant`: cover R10. Require `killed`, the concern's named killing test file, and substitution count 1.
- `test_unsafe_initializer_stops_the_run`: cover AE2 with exit 1 on cache misses and hits.
- `test_lib_source_is_unplaceable`: cover AE3.
- `test_boot_refusal_exits_1_without_fallback`: cover AE6 at `--jobs 1` and `--jobs 2`.
- `test_worker_route_survives_connects_to`: cover R11 with `connects_to` enabled. Record every pool and role's database file or name before and after reload. Require worker databases afterward and unchanged shared-test-database row counts.
- `test_source_change_mid_run_starts_no_second_reload`: cover R16 by touching a source during the fork. Verdicts must equal the untouched run.
- `test_full_reload_and_reload_have_equal_ran_at_load`: cover R15 before S8's outcome. A fixture method called from a class body is `ran_at_load` under both strategies.
- `test_postgres_and_mysql_full_reload`: add one `full_reload` run each in `test/daemon_postgres_test.rb` and `test/daemon_mysql_test.rb`. Keep existing local skips when servers are unavailable. Assert every pool and role is on the worker database after reload with `connects_to` enabled.
- `test_existing_reload_runs_are_unchanged`: existing dogfood tests pass without edits.

**Verification:** `bundle exec rake test:daemon` passes. Postgres and MySQL tests pass in the rails-integration CI job.

### U7. Docs, Action and CHANGELOG

**Goal:** Explain activation, prerequisites, and limitations.

**Requirements:** R1, R13, R14, R15.

**Dependencies:** U5.

**First step: file the limitation issues.** "Track every limitation" requires one issue per documented limit (`.expectation-fit/ways-of-working.yaml:11-13`). Before editing docs, the implementer files these issues using labels from `gh label list`:

1. "full_reload: a stale reference to an old class can make a mutant falsely survive" (KTD10, R14).
2. "full_reload: decide whether ran_at_load applies to reloaded files", with S8 data, only if R15 retains the rule.
3. "full_reload: a class-creation hook such as inherited records the tempfile path" (R7, R-C).
4. "full_reload: Rails 7.0 and Zeitwerk floors", with S10 versions.
5. "full_reload: place sources no reloading autoloader manages", with S8 counts (Q9).
6. "In-process --rails --strategy full_reload" (Q7).
7. "full_reload on a second app", with S9 results, linked from #284's daemon and reload default preconditions.

**Files:**

- `docs/rails-setup.md`: add "Full reload (opt-in)". Cover activation, forced reloading, app-controlled eager loading, and the `to_prepare` rule with Fizzy's example. Explain the clean-check safety test, validation against known survivors, S7 cost, and daemon/Minitest limits. Link each limitation's issue. Explain that Action users enable the daemon through `extra-args: --daemon` or `daemon: true` in `.mutineer.yml`. The Action has no daemon input (`action.yml:67-72`). Update the daemon table (`:267`).
- `docs/cli.md`: update the `--strategy` row (`:21`).
- `docs/ci.md`: update the Action `strategy` row (`:145`) with the same daemon note.
- `action.yml`: update the `strategy` description (`:59-62`). Existing pass-through (`:388`) needs no behaviour change.
- `docs/json-schema.md`: add the new `unplaceable` cause (`:60`, `:94-102`) and explain hook-block placement under `full_reload`. Update `ran_at_load` (`:140`): reload repeats class bodies, not initializers (R15).
- `CHANGELOG.md`: add an `### Added` entry under Unreleased naming #389.

**Test expectation:** Only docs and website checks.

**Verification:** `bundle exec rake docs:check` passes (`Rakefile:66-70`). `bundle exec rake site:build`, `node --test test/site_test.js`, and browser tests pass.

---

## Verification Contract

Prefix every ruby, rake, and bundle command with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`.

| Command | Why |
|---|---|
| `bundle exec rake test` | Run U2, U3, and U5 tests, plus U4's `test/daemon_server_hook_def_test.rb` and `test/coverage_map_test.rb`, without runtime dependencies. |
| `ruby -Ilib -e 'require "mutineer"'` | Check loading. |
| `bundle exec rake yard:strict` | Require 100% documentation, including the new module and constants. |
| `bundle exec rake test:daemon` | Verify U4 and U6 using the `test/fixtures/rails_app` bundle. |
| `BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle install`, then `BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle exec rake test` | Verify the reload-safety check's Minitest clean forks. |
| `bundle exec rake docs:check` | Check U7 docs rendered by `rake docs:generate`. |
| `bundle exec rake site:build`, then `node --test test/site_test.js` | Check U7's published docs. |
| `npm ci --prefix test/browser`, `npx --prefix test/browser playwright install chromium`, `npm test --prefix test/browser` | Run `AGENTS.md` website checks. |
| `bundle exec ruby -Ilib -Itest test/full_reload_test.rb` | Run the focused test file. |

Apply `AGENTS.md`: no runtime dependencies or `eval`; 100% YARD documentation; Rails tests only in `test:daemon`. Use plain `bundle exec` in subprocesses. Include the CHANGELOG entry and pull request labels.

## Definition of Done

- U1's report records every row's outcome. Update the plan to match chosen outcomes.
- Every U2 to U6 test exists and passes. Each failed before its unit, except tests preserving existing behaviour.
- Tests prove AE1 to AE6.
- Runs without `--strategy full_reload` retain behaviour and coverage digests (R17). Existing tests pass unchanged except explicitly planned edits.
- No new status, JSON key, or score formula exists (R13). `ran_at_load` follows R15's recorded S8 outcome.
- Cover related paths: preserve `reload` and `redefine` payloads and rules (U2, U5). Support daemon; reject in-process use and file its issue (R2, Q7). Accept the same value in CLI and Action (U7). Count new `unplaceable` results and validate dry runs identically (R3, U5).
- The pull request names every U7 issue by number and title. Include stale-reference false survival, conditional `ran_at_load`, class-creation paths, version floors, unmanaged sources, in-process support, and the second app. Cite the same numbers in `docs/rails-setup.md`. Apply Goal Capsule labels and `Closes #389`; remain draft until Q5 is answered.
- Remove dead code and abandoned spike code from the diff.

---

## Risks and Overlaps

| Item | Overlap or risk | Handling |
|---|---|---|
| #391 (Rails class-body reload fixes, branch `fix/1.8.2-rails-reload`) | Changes `run_mutant`, `ConcernBlocks.load_mutant`, and adds `ReloadGuards`. | Build on the merged change. Bypass guards under `full_reload` (KTD8); retain its `maintain_test_schema` skip. |
| #375 (place hook-block mutants before loading the remaining file) | Changes `apply_payload` and hook-block placement. | Resolve text conflicts. Its rules remain `reload`-only. |
| #388 plan (report errored-mutant causes in JSON) | Adds daemon-child cause lines. | If merged first, use its cause line for R9 and KTD7 errors. Otherwise make no related change. |
| #397 (mutate class-body macros) | Depends on this plan for daemon macro mutants. | Its plan cites this one. Macros never reach `reload`: #397 refuses macro operators on `reload` and the daemon before `ConcernBlocks.load_mutant` (its KTD4). Keep the three #391 guards (EnumRedeclaration, CallbackReskipping, RepeatedCallbacks) unchanged. Its PR3 permits macro mutants only under `full_reload`, which bypasses those guards (KTD8). PR3 also adds a macro branch that never reports `ran_at_load`. That is an exception to R15 for macro subjects only. |
| #402 (test a pinned Fizzy sample before releases) | Stored counts change with `full_reload`. | Change counts only when sample configuration selects `full_reload`. Update counts in the same pull request. |
| #284 (2.0 daemon and reload default preconditions) | Receives evidence, not a default change. | See "How this meets the #284 checklist". |
| 2.0 strategy and worker changes: #244, #245, #314, #322, #335 | Change `validate_daemon!`, strategy defaults, `run_mutant`, and worker databases. | Resolve text conflicts. R15 and KTD10 cover #322's `ran_at_load` counts. #335 suffixes every SQLite database; KTD7 uses its all-pool routing check. R5 and R6 boot refusals are provisioning failures. Under #244 (the 2.0 breaking flip) they move from exit 1 to exit 3 with every other provisioning failure (`STABILITY.md:121-126`). R12 red clean checks stay exit 1. |
| #332 and #337 (SQLite worker copies and mixed adapters) | Define worker routing rules. | KTD7 checks every pool using `after_fork` configuration. |
| #398 (full clean checks on cache hits) | R12 adds one reload per clean fork, not another test run (KTD6). | Shared code: `verify_combined_clean`, the hit branch of `cached_or`, and the digest. Rebase on #398 Step A, which merges first (v1.9.0). Keep the `full_reload` one-file rule and per-file fallback as strategy branches inside #398 helpers. Narrowing cache-hit clean checks also narrows reload-safety checks. Q3 asks whether coverage remains sufficient. |
| #393 (invalidate mutants only for added parse errors) | Changes `job_result`. | Resolve text conflicts. |
| #404 (concurrent SQLite runs share worker databases) | Adds a run lock. | Keep independent. |
| #286 (`ran_at_load` mutants) | Full reload repeats class bodies. | Apply KTD10 and measure in S8. |
| Supply-chain scanners | `RubyVM::InstructionSequence.compile_file` could trigger flags without string compilation. | U1 runs the project's scanner on the spike branch. Send flags to Q2. |
| Ruby internals | Ruby releases can change MRI's `load_iseq` hook, also used by Bootsnap. | Check at boot (R6); record versions in S10. |
| Exclusion frequency | KTD5 adds an `unplaceable` cause. | Count per app in S8, and in S9 when it runs. Fizzy autoloads `app/`; files such as `lib/rails_ext/` can qualify. |
| Request-time reloading | Forced reloading adds `ActionDispatch::Reloader` request checks (P6). | Disable the fork's check (R16). Measure test time in S7 and verify prevention in S12. |
| Coverage cache | One strategy could reuse another's map. | Separate digests through KTD13 and R17. |

## Open Questions

None blocks U1. Each question has a default and owner.

| Question | Default and decision condition | Owner |
|---|---|---|
| Q1. Should `strategy` have a `.mutineer.yml` key? | No. Keep it CLI-only. | Maintainer |
| Q2. Should string compilation preserve the real `__FILE__`? | No. Use `compile_file` (KTD2). Revisit after U1's scanner check and S8's class-creation-hook counts. String compilation fixes `inherited` paths (R7), but restores dynamic string execution. | Maintainer |
| Q3. Is the clean-check test set sufficient for reload safety? | Yes. Use the same set (KTD6). Revisit with #398's cache-hit clean-check changes. | Maintainer |
| Q4. Which second app should S9 use? | Use `rubygems/rubygems.org` unless the maintainer selects another. Booting its test environment with reloading remains unchecked. | Maintainer |
| Q5. Can this ship in a 1.x minor without a default change? | Keep `v2.0` and draft status (KTD11). If approved, use the next 1.x minor label and mark ready. | Maintainer |
| Q6. Should an eager-load option exist? | No. Follow the app's setting unless S5 fails. | Maintainer |
| Q7. How should in-process `full_reload` proceed? | File a follow-up issue; let the maintainer set priority. | Implementer files; maintainer prioritises |
| Q8. Does #284 need additional items? | Draft a comment proposing the gates in "How this meets the #284 checklist". The maintainer edits #284. | Implementer drafts; maintainer edits |
| Q9. Should unmanaged sources use `load` after reload, as under `reload`? | No. Keep them `unplaceable` (KTD5). U7 files an issue with S8's per-app counts. | Implementer files; maintainer decides |
