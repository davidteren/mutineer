# Deep review — Mutineer gem (pre-publish gate)

**Target:** full gem, branch `fix/dogfood-bugs` · **Date:** 2026-06-28
**Lenses:** correctness/security · convention/API/publish-readiness · test-quality (3 parallel reviewers)
**Verdict:** 🔴 **NOT publish-ready.** Code is clean and idiomatic, but there is one confirmed
silent-correctness defect, one structurally-unsound strategy, a leak introduced by the recent 7a fix,
and three hard packaging blockers. Fix the blocker set below before `gem push`.

---

## Confirmed (two or more lenses agree, or verified by a runnable check)

### 🔴 C1 — Multibyte byte-offset corruption (correctness H1 + test-quality H2)
Prism `start_offset`/`end_offset` are **byte** offsets; every consumer slices with **character**
indexing (`String#[]`, `count("\n")`). Any non-ASCII char *before* a mutation point (a `# café`
comment, a UTF-8 literal) shifts char index off the byte offset → wrong splice.
- `mutation.rb:11` `apply` → corrupted mutant (mis-mutates, or false `skipped` on reparse).
- `runner.rb:75`, `cli.rb:200`, `reporter.rb:126` line math → wrong line → **wrong coverage lookup →
  false `no_coverage`**, mutations silently never tested.
- `isolation.rb:87-89` (7b snippet), `condition_negation.rb:30`, `literal_mutation.rb:23` original-text reads.
All fixtures are pure ASCII (byte==char), so the suite can't see it. Verified: `"é=1\nb".length==5`
vs `.bytesize==6`.
**Fix:** read sources as binary and slice on bytes (`File.read(p, encoding: BINARY)` + `byteslice`/
`bytesplice`), write bytes. Highest-impact bug — a published gem editing real Ruby will corrupt mutants.

### 🔴 C2 — Strategy 7b is structurally unsound (correctness H2 + test-quality H1)
`isolation.rb:83-95` `apply_surgical`:
- **Scope collapse:** 7a `load`s the whole file (full `Module.nesting`); 7b `owner.class_eval(string)`
  gives nesting `[owner]` only. Any unqualified enclosing-namespace constant resolves under 7a, raises
  `NameError` under 7b → false kills/errors. Verified directly.
- **Silent false-SURVIVED (`isolation.rb:90`):** on snippet reparse failure the method `return`s but the
  caller (`runner.rb:81-88`) *still runs the tests against the original unmutated method* → reported
  `survived`. This is the mechanism behind the dogfood "7b leaves statement_removal survivors 7a kills."
- **Visibility loss:** `class_eval "def …"` redefines as public; 7a re-runs `private`/`protected`.
**Fix:** build the full namespace-nesting wrapper and eval that; never fall through to running the original
method on parse failure (return a skip/error sentinel); restore original visibility. Until fixed, 7b should
not be offered as a public option (or default-block it).

### 🟠 C3 — Mutant tempfile leaks into the user's source tree on timeout (correctness H3)
`isolation.rb:66-72`. **Introduced by the Bug-1 fix this branch** (tempfile now in the source dir so
`require_relative` resolves). On timeout the child is SIGKILL'd mid-block → the `Tempfile.create` `ensure`
never runs → `mutineer_mutantXXXX.rb` orphaned inside `lib/`, where it matches source globs / Zeitwerk / the
next run. `ensure` is fundamentally unreliable against SIGKILL.
**Fix:** parent-side sweep of `mutineer_mutant*.rb` per source dir at start/teardown, OR write to a temp dir
and prepend it to `$LOAD_PATH` so `require_relative` still resolves without polluting `lib/`.

### 🟠 C4 — `bin/mutineer` not shipped → installed CLI is broken (convention H1) — PUBLISH BLOCKER
`mutineer.gemspec:16` `spec.files = Dir.glob("lib/**/*.rb") + ["README.md","mutineer.gemspec"]` never matches
`bin/mutineer`, yet `spec.executables = ["mutineer"]`. After `gem install`, the binstub points at a file not in
the gem → `mutineer` fails to run.
**Fix:** `+ Dir.glob("bin/*")` (and `LICENSE`) in `spec.files`.

### 🟠 C5 — README describes a different, unbuilt gem (convention H2) — PUBLISH BLOCKER
`README.md:14,26` still say "M0 skeleton only — no mutation logic yet" and `mutineer run <path>`. Real usage
is `mutineer run <source...> --test <test...>`; none of the real flags/exit-codes/config/operators are
documented. A stranger concludes the tool does nothing.
**Fix:** rewrite from `cli.rb` BANNER + exit-code taxonomy + `.mutineer.yml` keys + operator list.

### 🟠 C6 — No LICENSE file (convention H3) — PUBLISH BLOCKER
`gemspec:12` declares MIT but no `LICENSE` exists. MIT requires the text be distributed.
**Fix:** add `LICENSE` (MIT, David Teren), include in `spec.files`.

### 🟡 C7 — Exit-code taxonomy inconsistent (correctness L1 + convention M5) [severity disputed]
`cli.rb:142-157`: bad `--jobs`/`--format`/`--strategy`/`--output` exit **1**; bad `--threshold` exits **2**.
Doc (`cli.rb:17-21`) says usage errors = 2. CI can't tell "mistyped flag" from "tests weak."
*Disputed:* correctness lens rated LOW, convention lens MEDIUM. **Fix:** all flag-validation → exit 2.

### 🟡 C8 — JSON reintroduces the nil-vs-0.0 score ambiguity (convention M7)
`reporter.rb:80` emits `score: 0.0` for an empty denominator; `result.rb:38-41` mandates nil/"N/A" there,
"never 0.0". Also human path rounds 1dp, JSON 2dp — same run, two scores by `--format`.
**Fix:** emit JSON `null` on empty denominator; align rounding.

---

## Confirmed single-lens (correctness/reliability)

- 🟠 **R1 — worker `at_exit` runs on the exception path** (`worker_pool.rb:41-47`). `exit!` only on success;
  if `Runner.run` raises, the child unwinds normally → host Minitest autorun re-runs the parent suite
  inside the worker; real error lost. **Fix:** rescue → marshal error Result → `exit!` in `ensure`.
- 🟠 **R2 — monitor thread can SIGKILL a recycled PID** (`isolation.rb:47-55`). `monitor.kill` races
  `Process.wait2`; a reused pid kill *succeeds* on an unrelated process; ×`--jobs`. `timed_out` shared
  unsynchronized. **Fix:** poll `waitpid(WNOHANG)` to a deadline, or kill the process group; never kill a
  reaped pid.
- 🟠 **R3 — Phase A coverage capture has no timeout** (`coverage_map.rb:77`). A hanging test file wedges the
  whole run before any per-mutant timeout. **Fix:** bound the subprocess; on expiry treat as failed file.
- 🟠 **R4 — cache digest collision/staleness** (`coverage_map.rb:129-132`). SHA256 of concatenated content,
  no separators, no paths: `("ab","c")`==`("a","bc")`; swapping source/test roles doesn't change the
  digest → stale map accepted silently. **Fix:** include relative path + `\0`/length delimiter (+ load_paths).
- 🟠 **R5 — missing path → raw backtrace** (`coverage_map.rb:130`, `runner.rb:33,69`). `Errno::ENOENT` not in
  the CLI rescue (`cli.rb:124-131`). **Fix:** validate existence in `validate!` / rescue `SystemCallError` → exit 2.
- 🟠 **R6 — `wait2(-1)` steals foreign children; `Marshal.load` unguarded** (`worker_pool.rb:66-73`). Reaps
  any child of the process; a partial Marshal stream from a dead worker crashes the whole pool.
  **Fix:** wait on known pids; rescue `Marshal.load` → `Result.error`.
- 🟠 **R7 — sources outside `project_root` silently `no_coverage`** (`coverage_map.rb:114-118`). `../lib/foo.rb`
  / symlinked root stays absolute → coverage dropped, no warning. **Fix:** realpath + warn.
- 🟡 **R8 — `Config.from_file` calls `exit 1` from the lib layer** (`config.rb:84`). A data class killing the
  host process can't be embedded/tested. **Fix:** raise a typed `Mutineer::` error; CLI maps to exit 2.

## Convention / publish (single-lens)
- 🟡 gemspec missing `homepage`/`metadata`(`source_code_uri`,`rubygems_mfa_required`)/`email` → `gem build`
  warns, bare rubygems page. 🟡 `--strategy 7a|7b` leaks internal spec numbers (use `whole-file|surgical`).
  🟢 redundant `require "set"` (core ≥3.2), redundant `.freeze` on a magic-comment-frozen string, no
  CHANGELOG, gemspec shipped inside the gem, un-overridable `load_paths` hardcoded to `["lib"]`.

## Test gaps (single-lens, test-quality)
- 🟠 `statement_removal` (a DEFAULT op) and Tier-2 ops never run end-to-end (all fixtures single-statement;
  `statement_removal.rb:18` needs ≥2). 7b parity tested only on single-statement defs → C2 invisible.
- 🟠 No multibyte/UTF-8 source test (→ C1 invisible). 🟠 CLI happy-path/`--dry-run`/`--format json`/
  `--strategy 7b` never driven through `bin/mutineer`. 🟡 signal-death decode, coverage non-JSON/Hash-format/
  cache-hit-with-failures, worker EAGAIN, syntax-error source file all untested. 🟢 `test_parallel_is_faster_
  than_serial` wall-clock assertion is flaky on CI.

---

## What's solid (don't re-audit)
`Result`/`AggregateResult` six-state taxonomy + nil-vs-0.0 discipline; uniform `Prism::Visitor` mutators
with frozen `REPLACEMENTS`; `Mutation` immutable `Data.define`; registry tier/default split + `--list-
operators`; zombie reaping asserted; `--jobs 1`==`4` determinism; coverage subprocess interpolation is
injection-safe (`String#inspect` escapes `#{`); `exit!` on the success paths is correct.

## Tools used / unavailable
Used: 3 parallel review sub-agents (correctness, convention, test-quality) + runnable checks. Not run:
cubic `/run-review` `/scan`, majestic rails review (N/A — plain Ruby gem, no Rails). Augment not invoked
(small codebase read directly).

## Recommended publish-blocker set (minimum before `gem push`)
1. **C1** multibyte byte-slicing (silent wrong results).
2. **C2** 7b unsound — fix or hide the strategy.
3. **C3** tempfile leak from the 7a fix.
4. **C4/C5/C6** packaging: ship `bin/`, rewrite README, add LICENSE.
5. **C7/C8** exit-code consistency + JSON nil score (cheap, high least-astonishment value).
R1–R8 are reliability hardening — strongly recommended, not all strict blockers.

---

# Re-review (2026-06-28, post-hardening, branch main)

Two lenses re-ran after the hardening pass + rename: fix-verification/regression, and publish-readiness.

## Fix verification — all 16 FIXED
C1–C8 and R1–R8 are each confirmed fixed in code with a backing test (verified, not just claimed);
full suite **183 runs / 0 failures**. No regressions. New-code scrutiny found only LOW, effectively
unreachable edge cases:
- **7b compact `class A::B` nesting** expands to `module A; class B` (nesting `[A::B, A]`) vs 7a's `[A::B]`.
  Only diverges for code that references an outer-only constant unqualified — which already `NameError`s under
  normal `require`, i.e. already-broken code. Noted, not fixed.
- Benign ≤5ms poll-window race (conservative: mis-classifies as timeout, never false-survived).
- Pre-existing (not from this pass): >64KB worker pipe payload could block; `class << self` singletons not
  discovered. Both LOW, unrelated to the findings.

## Publish-readiness — GO
Packaging blockers C4/C5/C6 resolved (gem builds, ships bin+LICENSE+README+CHANGELOG, installed binary runs).
Should-fixes applied post-re-review: README `.mutineer.yml` example corrected to the real `KNOWN_KEYS`
(removed unsupported `sources:`/`tests:`, documented `require:`); removed unused `require "set"`; dropped
redundant `VERSION.freeze`; bounded dev deps (`~>`); CHANGELOG `[0.1.0]` section; removed duplicate
`homepage_uri` → **gem build is now warning-free**.

Deferred (your call, non-blocking): `--strategy 7a|7b` still exposes internal spec-section numbers as the
public flag value — rename to semantic names (e.g. `reload|redefine`) before 1.0 if desired.

**Verdict: GO for `gem push mutineer`.**
