---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
issue: 27
title: "feat: run mutation tests against Ruby < 3.4 apps (decouple tool runtime from target bundle)"
depth: deep
created: 2026-07-01
---

# feat: Mutation-test projects pinned to Ruby < 3.4

**Issue:** #27 · **Related:** #26 (DB-isolated parallel workers), #11 (one-boot multi-source), #12 (why jobs=1), #19 (fork + AR)

---

## What / Why / How (plain language)

**What.** Right now the tool cannot be run at all against a Rails app that is
pinned to an older Ruby (3.1, 3.2, 3.3). A large share of production Rails apps
are exactly that — and those mature, high-stakes codebases are where mutation
testing pays off most. So the users who would benefit most are the ones locked
out.

**Why it's locked out.** The tool's documented Rails workflow boots the target
app *inside the tool's own Ruby process*. That forces the tool's Ruby and the
app's Ruby to be one and the same. Because the tool needs Ruby 3.4+ (it uses a
parser that only ships with 3.4) and the app's `Gemfile` says "use Ruby 3.1",
there is no single Ruby where both are happy. The 3.4 floor is effectively a
demand on the *customer's app*, not just on our tool.

**How we fix it.** Stop making the tool's Ruby be the app's Ruby. The tool
keeps running on 3.4+, but the app's tests run in a *separate process* under the
app's own Ruby and bundle. We ship this in two steps:

- **Phase 1 — quick unblock.** Let the user hand us the exact command that runs
  their tests (e.g. `bundle exec rails test <files>`). We apply one mutation to
  the file on disk, run that command in the app's runtime, read pass/fail, put
  the file back. Slower (the app re-boots per mutant) but it works on any Ruby
  today.
- **Phase 2 — fast version.** A long-lived helper process runs *inside the app's
  bundle*, boots the app once, and answers "run the tests for this mutant"
  requests from the tool over a pipe. This restores today's one-boot speed, and
  it is the same machinery issue #26 needs to run workers in parallel safely, so
  the two efforts converge.

**Glossary.** *Mutant* = one small deliberate change to the source (e.g. flip
`>` to `>=`). *Killed* = the test suite failed on the mutant (good — the tests
caught it). *Survived* = the suite still passed (a gap in the tests).

---

## Problem Frame

Two distinct couplings force tool-Ruby == app-Ruby today:

1. **Prism-stdlib floor.** `mutineer.gemspec:17` sets `required_ruby_version
   ">= 3.4"` because the tool parses with stdlib Prism, bundled only from Ruby
   3.4. This pins the *tool source* to 3.4+.
2. **In-process app boot (the real blocker).** `Runner.execute` (`lib/mutineer/runner.rb:47-61`)
   does `require config.boot` (e.g. `config/environment`) in the tool's own VM,
   then forks per mutant and runs the covering tests in-process via
   `TestRunners.for(framework).run` (`runner.rb:287`). Booting the app in the
   tool's VM means Bundler enforces the app's `Gemfile` ruby pin on the tool
   process — so `ruby '3.1.6'` and the tool's ≥3.4 requirement can never both be
   satisfied at once.

Coupling (2) is the blocker: even if Prism were available on 3.1, the tool
*source* would still have to load under the app's 3.1 bundle. The fix is to run
the target suite in a **separate process** under the app's own runtime, and keep
the tool on 3.4+ where Prism lives. Coupling (1) then stops mattering because the
tool never enters the app's bundle.

**Non-goal (this issue):** lowering the tool's own Ruby floor below 3.4 via the
`prism` gem (issue direction 3). Once the runtime is decoupled it buys nothing —
the tool stays on 3.4 by choice, not necessity. Recorded under Deferred.

---

## Requirements

- **R1.** A user on a Rails app pinned to Ruby 3.1–3.3 can run a full mutation
  audit and get correct kill/survive verdicts. *(Phase 1)*
- **R2.** The tool process itself continues to require Ruby ≥ 3.4; the app's
  suite runs under whatever Ruby the user's test command resolves to. *(Phase 1)*
- **R3.** A user-supplied `--test-command` (and `.mutineer.yml` key) runs the
  target suite as a subprocess, with an explicit placeholder for the test files
  to run. Framework-agnostic — the command is opaque to the tool. *(Phase 1)*
- **R4.** Subprocess exit status maps to a verdict without silently
  misclassifying infrastructure failures as "killed". *(Phase 1)*
- **R5.** A mutation applied on disk is **always restored**, including after
  SIGKILL/timeout/crash — the user's working tree is never left mutated. *(Phase 1)*
- **R6.** Phase 1 is opt-in and safe-by-default: absent `--test-command`, current
  in-process behavior is unchanged. A clear error fires when the flag is set but
  malformed. *(Phase 1)*
- **R7.** The external path documents its known tradeoffs (per-mutant boot cost;
  no coverage-narrowing; **score not comparable to the in-process score**; reload
  strategy only; serial until #26). *(Phase 1)*
- **R8.** *Spike:* prove the tool (3.4) can drive a persistent worker process
  under the app's bundle (3.1) that boots the app once, runs one mutant's covering
  test, and returns the correct verdict over IPC. *(Phase 2 gate)*
- **R9.** The daemon backend restores one-boot speed and preserves coverage-based
  test selection, and its design is compatible with #26's per-worker DB isolation
  (one design serves both). *(Phase 2)*
- **R10.** All parsing/mutation/Prism work stays on the 3.4 tool side; the app-side
  worker receives ready-to-`load` text and never needs Prism. *(Phase 2)*

Repo constraints (all phases): zero runtime dependencies, no `eval`, Prism +
stdlib only. See `MEMORY.md` conventions.

---

## Key Technical Decisions

**KTD-1 — Materialize the mutant on disk for the external path (not in-process `load`).**
The current model applies a mutant by `load`-ing mutated text into the *tool's*
running VM inside a fork (`Isolation.apply_whole_file`, `runner.rb:285`). A
separate `bundle exec` subprocess has its own VM and cannot see that `load`. So
the external path must write the mutated source to the **real file path**, run
the command, then restore the original. This is the reload (whole-file) strategy
expressed on disk instead of via in-process `load`.

**KTD-2 — Backup-and-restore with defense in depth (R5).** On-disk mutation is
the one genuinely dangerous new behavior: a crash mid-run could leave a user's
source file mutated. Mirror the existing orphan-sweep discipline
(`Runner.sweep_orphans`, `runner.rb:230`):
- Before mutating file `F`, copy original bytes to a sibling backup
  (`F` + a mutineer suffix) *and* hold them in memory.
- Restore in an `ensure` around each mutant.
- Parent sweeps/normalizes any leftover backups before and after the whole run
  (SIGKILL skips `ensure`, exactly as it does for tempfiles today).
- On startup, if a backup exists for a source file, restore it before doing
  anything (self-heal from a prior hard kill).
- Only one mutant is in flight per file at a time on this path (serial — see
  KTD-5), so backup collisions cannot occur.

**KTD-3 — Exit-status → verdict mapping (same as in-process, coarser), with a
smoke-check guard (R4).** In-process today: child exit `0=survived, 1=killed,
2=error`, timeout via the parent monitor (`Isolation.decode`, `isolation.rb:205-212`).
A normal test command uses the **same** direction — the suite exits `0` when it
**passes** and non-zero when it **fails** — so suite-passes ⇒ **survived**,
suite-fails ⇒ **killed**, exactly like the in-process backend
(`TestRunners.run` returns `0=all-passed`; `isolation.rb:207` maps `0→survived`).
This is **not an inversion**; it is the same mapping at **coarser granularity** —
the external path loses the `error`/`timeout` distinction a dedicated exit 2 gives
in-process.

| Subprocess outcome | Verdict |
|---|---|
| exit 0 (suite passed) | **survived** |
| stable "suite failed to run" code (where the framework emits one) | **error** (excluded) |
| other exit non-zero (suite failed) | **killed** |
| exceeds timeout (parent kills it) | **killed (timeout)** |

Two failure-transparency gaps this coarseness opens, and how the plan closes them:
- **Infra failure scored as "killed" (score inflates *upward*).** A DB drop,
  LoadError, OOM (137), or wrong `RAILS_ENV` also exits non-zero and is
  indistinguishable from a real kill. Mitigations: (a) a **smoke check** (KTD-3a)
  runs the command once against the unmutated file at startup and aborts if the
  clean suite is not green — env broken, not tests strong; (b) where the framework
  emits a stable "suite failed to run" code distinct from "tests failed", map it to
  `Result.error` (excluded from the denominator) not `killed`; (c) the run header
  states the external score is an **upper bound**. Residual intermittent per-mutant
  infra failure is an accepted Phase-1 limit (R7); Phase 2's structured IPC
  distinguishes error from failure natively.
- **Invalid mutants** must stay `skipped`, not fall into `killed` — see KTD-8.

**KTD-3a — Smoke check, not "baseline".** The startup clean-run guard is named
**smoke check** (or clean-run guard), deliberately *not* "baseline" — `--baseline`
/ `lib/mutineer/baseline.rb` already means the CI regression-delta gate, an
unrelated concept. The smoke check lives on the external backend, not in
`baseline.rb`.

**KTD-4 — `--test-command` surface and `%{files}` substitution (R3).** Add a
CLI flag and `.mutineer.yml` key (snake_case `test_command`, following the existing
explicit-tracking pattern in `cli.rb`, e.g. `--baseline`). The command string is a
template turned into an **argv array** (no shell → no `eval`, no injection):
- Tokenize the template into argv elements first.
- The `%{files}` token expands **in place to N separate argv elements**, one per
  test path, unescaped — there is no shell to un-quote, so a path containing a
  space stays a single argument. It is **not** a space-joined string (the earlier
  "space-joined, shell-safe" framing was wrong: "shell-safe" is meaningless with no
  shell, and joining breaks a runner that expects N file args).
- `%{files}` is **required**; if absent, error at `validate!` — do not silently
  append, so the user always sees where the files land.
- **Environment:** a spawned subprocess already inherits the tool's env, so
  `RAILS_ENV=test mutineer …` reaches the child with no parsing on our side. The
  command string is *just the command* — no leading `KEY=val` sugar to half-emulate
  a shell. A workflow needing env scoped to only the suite gets a dedicated
  repeatable `--env KEY=VAL` flag, deferred until a real need appears.

Example: `RAILS_ENV=test mutineer run … --test-command "bundle exec rails test %{files}"`.

**KTD-5 — External path is serial in Phase 1; parallel is #26's job.** Each
subprocess boots the app and opens its own fixture transaction against the *same*
database — the exact corruption #26 documents for `--jobs > 1`. So under
`--test-command`, force `jobs = 1` (with a one-line notice if the user asked for
more), same rationale as #12. Phase 2 + #26 lift this together. This keeps Phase
1 correct-by-construction.

**KTD-6 — No coverage-narrowing on the external path; reload only; score is NOT
cross-backend-comparable (R7).** Coverage selection is built by forking the
*booted-in-process* app and measuring each test's coverage delta
(`CoverageMap#build_via_fork`, driven from `runner.rb:74`). The external path never
boots in-process, so there is no coverage map: every mutant runs the **full
`--test` set** passed as `%{files}`.

This is not only a perf tradeoff — it changes the **score's meaning**. In-process,
a mutant on a line no test exercises is `no_coverage` and **excluded** from the
denominator (`runner.rb:267-274`); on the external path that same mutant runs the
full suite, nothing covers it, the suite passes, and it scores **`survived`**
(included). So identical code + tests reports a **lower** score under
`--test-command` than in-process. Handle it honestly:
- The run header and docs (U6) state the external score is **not comparable** to
  the in-process score — uncovered mutants count as survivors here.
- Report the count of mutants that ran without narrowing, so the user can reason
  about the gap.
- Best-effort/optional: where tool-side static analysis can prove a line
  unreachable, still emit `no_coverage`.

`--strategy redefine` (surgical in-VM `load`, `isolation.rb:107`) also cannot
apply to a separate process — the external path is reload/whole-file only; a
`redefine` request on this path errors clearly rather than silently degrading.

**KTD-8 — Preserve the tool-side per-mutant skips on the external path (R4).**
Two classifications currently live inside `Runner.run` (`runner.rb:255,267-274`),
which U4 bypasses — re-apply them tool-side *before* the subprocess runs, or their
`Result` states go unreachable and those mutants skew the score:
- **Invalid mutant → `skipped`.** If `Parser.parse_string(mutated).errors.any?`
  (Prism, tool-side, already computed), classify `Result.skipped` and **never write
  the file** — otherwise the app fails to load, exits non-zero, and scores a false
  `killed`.
- **No-coverage → per KTD-6** (best-effort static proof; otherwise runs the full set).

**KTD-7 — Phase 2 keeps Prism on the tool side (R10).** The daemon (app Ruby)
must never need Prism. The tool (3.4) does *all* parsing, mutation, subject
discovery, and — critically — the surgical-snippet reparse validation
(`isolation.rb:142`), then ships the daemon either whole mutated file text or a
ready-to-`load` wrapped snippet plus the covering test paths. The daemon only
`load`s text and runs tests. This is what makes the decoupling total: Prism-3.4
stays home; the app side runs on 3.1 with no new gem.

---

## High-Level Technical Design

### Execution model: today vs Phase 1 vs Phase 2

```
TODAY (in-process, blocked on <3.4)
┌─ tool VM (MUST be app Ruby) ─────────────────┐
│ require config/environment  (boots Rails)    │
│ Coverage.start; build coverage map via fork  │
│ per mutant: fork → load(mutated) → run tests │  ← app Ruby == tool Ruby == 3.4+ required
└──────────────────────────────────────────────┘

PHASE 1 (external subprocess — unblocks <3.4, slower)
┌─ tool VM (3.4+) ─────────────┐        ┌─ subprocess (app Ruby 3.1) ─┐
│ parse + build mutant (Prism) │        │ bundle exec rails test <f>  │
│ smoke check once             │        │ boots app EACH mutant       │
│ per mutant:                  │  spawn │ exit 0 = pass, non-0 = fail │
│   skip if invalid (KTD-8)    │───────▶│                             │
│   swap file on disk          │◀───────┤ (verdict from exit status)  │
│   run test-command, read exit│        └─────────────────────────────┘
│   restore file (ensure)      │         serial (jobs=1)
└──────────────────────────────┘         full --test set — no coverage narrowing

PHASE 2 (persistent daemon — restores speed, converges with #26)
┌─ tool VM (3.4+) ─────────────┐   IPC   ┌─ daemon (app Ruby 3.1, bundle) ─┐
│ parse + build mutant (Prism) │ (pipe,  │ boots app ONCE                  │
│ ship mutated text + tests ───┼────────▶│ Coverage map in-process         │
│ read structured verdict ◀────┼─────────┤ per request: fork → load → test │
│ (killed/survived/error/TO)   │  JSON   │ #26: fork routed to worker DB-N │
└──────────────────────────────┘         └─────────────────────────────────┘
```

### Phase 1 per-mutant sequence

```
tool                              app subprocess (app Ruby)
 │ skip if mutant invalid (reparse, tool-side) → Result.skipped, no write
 │ backup original bytes of F
 │ write mutated bytes to F
 │ spawn [test-command, %{files}=ALL --test files] ─▶ boot app, run tests
 │ wait (with wall-clock timeout, kill on breach)  ◀─ exit status
 │ restore F from backup   (ensure — always runs)
 │ map exit → survived / error / killed / timeout (KTD-3)
 ▼ next mutant
```

---

## Phased Delivery

### Phase 1 — External test-command backend (ships independently, unblocks #27)

Delivers R1–R7. A new execution backend selected when `--test-command` is set;
the in-process backend is untouched when it is not.

### Gate — Spike before Phase 2 (R8)

A throwaway spike proving one forked worker, launched by the 3.4 tool but running
under the app's 3.1 bundle, can: boot the app once, receive one mutant spec over
a pipe, `load` the mutated text, run its covering test against an isolated DB, and
return the correct kill/survive — with N=2 deterministic and matching serial.
**Do not start Phase 2 build until the spike passes.** This spike is the natural
merge point with #26's existing spike plan
(`docs/plans/issue-26-db-isolated-parallel-spike.md`); run them as one.

### Phase 2 — Persistent app-side worker daemon (converges with #26)

Delivers R9–R10. Supersedes #26's standalone daemon design. Only planned at unit
level after the spike gate passes — units below are directional, not yet
implementation-ready, and will be re-planned post-spike.

---

## Implementation Units

> Phase 1 units (U1–U6) are implementation-ready. Phase 2 units (U7–U9) are
> directional and gated on the spike (R8); re-plan them after the spike passes.

### U1. `--test-command` CLI flag, config key, and validation

**Goal:** Accept an external test command from CLI and `.mutineer.yml`, validated
and mutually consistent with existing flags.
**Requirements:** R3, R6.
**Dependencies:** none.
**Files:** `lib/mutineer/cli.rb`, `lib/mutineer/config.rb`, `test/` (new
`test/cli_test_command_test.rb` or nearest existing CLI test file).
**Approach:** Add `o.on("--test-command CMD")` following the explicit-tracking
pattern used for `--baseline` (`cli.rb:106`); the `.mutineer.yml` key is snake_case
`test_command` (update `KNOWN_KEYS`/`field_for`/`coerce` in `config.rb` to match the
existing key convention). Add a `test_command` reader on `Config` and merge
precedence CLI > `.mutineer.yml` (mirror `--baseline`). In `validate!`: (a) reject
an empty command; (b) reject a command missing the `%{files}` placeholder (KTD-4 —
no silent append); (c) if `--test-command` and `--strategy redefine` are both set,
error clearly (KTD-6); (d) if `--jobs > 1` with `--test-command`, force `1` with a
one-line notice (KTD-5). Update the `banner`/usage text (`cli.rb:32-58`).
**Note on (d) vs `--rails`:** `--rails` honors an explicit `--jobs N`
(`config.rb:117-122`) because #26 gives it per-worker DB isolation to opt into. The
external path has **no** such isolation yet, so an explicit `--jobs N` here would be
silently corrupt — hence forced to 1, not honored. Documented so the divergence is
a reasoned exception, not drift; revisit when #26 lands.
**Patterns to follow:** `--baseline` explicit tracking; existing `validate!`
warnings (`cli.rb:203-246`).
**Test scenarios:**
- Flag sets `config.test_command`; `.mutineer.yml` key does too; CLI overrides file.
- Empty/whitespace command → clear error, non-zero exit, no backtrace.
- Command without `%{files}` → clear error naming the missing placeholder.
- `--test-command` + `--strategy redefine` → clear error naming the conflict.
- `--test-command` + `--jobs 4` → forced to 1 with a one-line notice.
- Absent `--test-command` → config unchanged, in-process path selected (no regression).

### U2. Mutant file-swap with crash-safe backup/restore

**Goal:** Apply one whole-file mutant to the real source path and guarantee
restoration on every exit path.
**Requirements:** R5.
**Dependencies:** U1.
**Files:** new `lib/mutineer/file_swap.rb` (or extend `lib/mutineer/isolation.rb`),
`test/file_swap_test.rb`.
**Approach:** `FileSwap.with(source_file, mutated_bytes) { ... }` — write backup
sibling + keep original in memory, write mutated bytes, `yield`, restore from
memory in `ensure`, delete backup. Add a `restore_orphans(source_dirs)` sweep
(parallel to `Runner.sweep_orphans`, `runner.rb:230`) that restores any leftover
backup at startup and after the run. Backup filename uses a fixed
`.mutineer-backup` suffix so the sweeper can find it deterministically.
**Patterns to follow:** `Runner.sweep_orphans` / the tempfile-orphan discipline
(`runner.rb:118-124`, `isolation.rb:85-91`).
**Execution note:** Start with a failing test that asserts the file is restored
after the block raises, and after a simulated hard-kill (leftover backup on disk →
`restore_orphans` heals it).
**Test scenarios:**
- Block runs → file holds mutated bytes during, original bytes after; backup gone.
- Block raises → original bytes restored; exception propagates.
- Leftover backup present at startup → `restore_orphans` restores original, removes backup.
- Byte-exact restoration (frozen-string / encoding / trailing-newline preserved).
- Covers R5. Integration: mutated content is what the subprocess actually reads (write-then-read round trip).

### U3. External backend: subprocess spawn + exit-status → verdict mapping

**Goal:** Run the user's command in the app runtime for one mutant and decode the
result into a `Result`.
**Requirements:** R3, R4.
**Dependencies:** U1, U2.
**Files:** new `lib/mutineer/external_backend.rb` — a distinct execution backend,
deliberately **not** under `test_runners/`: it does spawn + timeout + verdict
mapping, unlike the thin `.run(files)->Integer` framework adapters
(`test_runners/minitest.rb`, `rspec.rb`). Also `lib/mutineer/result.rb` (reuse
existing states), `test/external_backend_test.rb`.
**Approach:** Build argv from the template (KTD-4): tokenize, then expand `%{files}`
to **N separate argv elements** (one per path, unescaped). Spawn via the array form
with the same wall-clock timeout + SIGKILL discipline the parent already uses
(`Isolation.run`, `isolation.rb:57-68`) — factor that monitor so timeout handling
is not re-implemented. Map per KTD-3: exit 0 → `Result.survived`; a stable "suite
failed to run" code (where the framework emits one) → `Result.error`; other
non-zero → `Result.killed`; timeout → `Result.timeout`. Capture child
stdout/stderr; on any non-zero exit print a **one-line stderr notice by default**
(what happened + "re-run with --verbose for output"), and surface the full captured
output under `--verbose`.
**Patterns to follow:** `Isolation.run` timeout/kill loop. This backend does **not**
implement the `TestRunners.for` adapter contract (Integer 0/1, fork-only) — it is
selected by U4's backend branch, not by framework name.
**Test scenarios:**
- Command exits 0 → survived; exits 1 → killed; exits 137/other non-zero → killed.
- A path containing a space → `%{files}` yields N argv tokens, each one intact arg (not split, not joined).
- `%{files}` absent from the template → `validate!` error (not silent append) — asserted in U1.
- Env inheritance: `RAILS_ENV=test` set in the tool's env reaches the child; the command string carries no `KEY=val` parsing of our own.
- Framework's stable "suite failed to run" code → `Result.error` (excluded); a genuine test failure → `Result.killed`.
- Runaway command exceeding timeout → killed(timeout), process reaped, no zombie.
- No `eval`, no shell string built from the file list (argv array asserted).
- A first non-zero exit prints the one-line default notice; full output only under `--verbose`.

### U4. Wire the external backend into the runner (backend selection)

**Goal:** Route the run through the external backend when `--test-command` is set,
leaving the in-process path byte-for-byte unchanged otherwise.
**Requirements:** R1, R6.
**Dependencies:** U2, U3.
**Files:** `lib/mutineer/runner.rb`, `test/runner_external_test.rb`.
**Approach:** In `Runner.execute`, branch early on `config.test_command`: skip the
in-process boot/require and coverage-map build (`runner.rb:47-87`); build the job
list exactly as today (subject discovery is a static Prism parse needing nothing
loaded — see `runner.rb:100-114`). For each job, **first apply the tool-side skips
of KTD-8** — reparse the mutated source and classify `Result.skipped` (never
writing the file) if it fails — then run every `--test` file (full set, KTD-6)
through U2+U3 instead of the fork+`load` path. Aggregate identically
(`AggregateResult`). Keep `--since`, `--only`, suppression, `--fail-fast`,
`--baseline` working — they operate on the job list, above the execution backend.
**Patterns to follow:** the existing standalone-vs-boot branch in `Runner.execute`;
the `Parser.parse_string(mutated).errors.any? → Result.skipped` guard at
`runner.rb:255`; `AggregateResult` assembly (`runner.rb:145`).
**Test scenarios:**
- `--test-command` set → no in-process boot; verdicts match a known killed/survived fixture.
- Invalid (non-reparsing) mutant → `Result.skipped`, file never written, excluded from the denominator (not a false `killed`).
- `--fail-fast`, `--only`, `--since`, suppression comments still filter jobs on this path.
- Absent `--test-command` → in-process path unchanged (regression guard on an existing boot-mode test).
- End-to-end on a tiny fixture: 1 killed + 1 survived mutant → correct score and exit code.

### U5. Smoke-check pre-flight (clean-run guard)

**Goal:** Fail fast with a clear message when the unmutated suite is not green, so
infra breakage is never scored as strong tests.
**Requirements:** R4.
**Dependencies:** U3, U4.
**Files:** `lib/mutineer/external_backend.rb` (or `lib/mutineer/runner.rb`).
Deliberately **not** `lib/mutineer/baseline.rb` — that module owns the unrelated
`--baseline` CI delta-gate concept (KTD-3a). `test/smoke_check_test.rb`.
**Approach:** Before running any mutant on the external path, run the command once
against the untouched file(s). If it does not exit 0, abort with a message that (a)
names the likely cause (env, DB, RAILS_ENV) and (b) **includes the failing
command's captured stdout/stderr tail** — nothing else has run yet, so this is the
best diagnostic moment. Do **not** report a score. Gated inside `execute` so
`--dry-run` never triggers it. Always-on (no opt-out flag until a real need
appears).
**Test scenarios:**
- Clean suite exits 0 → proceeds to mutants.
- Clean suite exits non-zero → abort, clear message with captured output tail, non-zero exit, zero mutants run.
- Message names the diagnostic direction (broken environment, not weak tests).
- `--dry-run --test-command` → smoke check never runs (no app boot).
- Covers R4.

### U6. Docs + tradeoff disclosure

**Goal:** Document the cross-runtime workflow and its Phase-1 limits so users on
older Rubies aren't guessing (issue direction 4).
**Requirements:** R7.
**Dependencies:** U1–U5.
**Files:** `README.md`, site docs (per the repo's docs/site setup), `CHANGELOG`.
**Approach:** Add a "Ruby < 3.4 / older Rails apps" section: the `--test-command`
recipe, the exact `%{files}` semantics (required; expands to N argv tokens), env
via inheritance (`RAILS_ENV=test mutineer …`), and the honest tradeoffs —
per-mutant boot cost, no coverage-narrowing (full `--test` set per mutant), the
resulting **score is not comparable to the in-process score** (uncovered mutants
count as survivors), reload-only, serial until #26.
**Test scenarios:** `Test expectation: none — documentation only.`

---

### U7. (Phase 2, gated) Spike: tool-3.4 → app-3.1 worker over IPC

**Goal:** Prove per-worker app boot + `load` + isolated-DB test under the app's
bundle, driven by the 3.4 tool. **This is the R8 gate.**
**Requirements:** R8.
**Dependencies:** U1–U5 (reuse mutant generation + verdict types); merges with
`docs/plans/issue-26-db-isolated-parallel-spike.md`.
**Files:** throwaway spike dir (not shipped).
**Approach:** Tool spawns a small worker script under the app bundle; worker boots
the app once, reads one mutant spec (mutated text + covering test paths) from a
pipe, forks, `load`s the text, routes AR to an isolated worker DB (#26), runs the
test, writes a structured verdict back. Prove N=2 deterministic == serial.
**Execution note:** Spike — optimize for a yes/no answer, not production shape.
**Test scenarios:** Manual/spike: correct kill and survive on a known fixture;
N=2 verdicts identical to serial; no cross-talk deadlocks.

### U8. (Phase 2, gated) IPC protocol + daemon lifecycle

**Goal:** Define the tool↔daemon message contract and spawn/health/shutdown
lifecycle.
**Requirements:** R9, R10.
**Dependencies:** U7 passes.
**Files:** TBD post-spike.
**Approach (directional):** Newline-delimited JSON or Marshal over a pipe;
messages carry mutated text (or ready-to-`load` wrapped snippet — KTD-7), covering
test paths, timeout, worker-DB index. Tool owns lifecycle; daemon is stateless per
request beyond the one-time boot. Structured verdict distinguishes
survived/killed/error/timeout natively (fixes KTD-3's Phase-1 limitation).
**Test scenarios:** Re-planned post-spike.

### U9. (Phase 2, gated) Daemon backend + coverage selection + #26 convergence

**Goal:** Production daemon backend restoring one-boot speed and coverage
narrowing, with #26's per-worker DB isolation.
**Requirements:** R9, R10.
**Dependencies:** U8.
**Files:** TBD post-spike.
**Approach (directional):** Daemon boots once, builds the coverage map in-process
(restores KTD-6's lost narrowing), forks per request routed to worker DB-N.
Supersedes #26's standalone daemon. Tool stays Prism-3.4; daemon needs no Prism
(KTD-7).
**Test scenarios:** Re-planned post-spike.

---

## Scope Boundaries

**In scope (Phase 1):** external `--test-command` backend, on-disk crash-safe
mutation, exit-status verdict mapping, smoke-check guard, docs.

**In scope (Phase 2, gated):** spike, IPC protocol, persistent daemon backend
converging with #26.

### Deferred to Follow-Up Work

- **Coverage-narrowing on the external path.** Restored properly by the Phase 2
  daemon (in-process coverage). Not worth reintroducing for the subprocess path.
- **Per-mutant infra-error vs test-fail distinction on the external path.**
  Accepted Phase-1 limitation (mitigated by the smoke-check guard); solved
  natively by Phase 2's structured IPC verdict.
- **`--strategy redefine` over a subprocess.** Not meaningful without a shared VM;
  Phase 2 daemon can support surgical `load` again (KTD-7).

### Outside this issue's identity

- **Lowering the tool's own Ruby floor below 3.4 via the `prism` gem** (issue
  direction 3). Runtime decoupling makes it unnecessary; the tool stays 3.4 by
  choice. Revisit only if a concrete need appears.

---

## Risks & Dependencies

- **R (data safety): on-disk mutation could leave a user's source mutated after a
  hard kill.** *Mitigation:* KTD-2 defense in depth (in-memory + backup + `ensure`
  + startup self-heal + serial-per-file). This is the highest-severity new risk;
  U2 is test-first.
- **R (correctness): infra failure scored as "killed" (score inflates up).**
  *Mitigation:* KTD-3 smoke-check guard (U5) + `error`-code mapping + upper-bound
  header; KTD-8 keeps invalid mutants `skipped`; documented residual (R7).
- **R (correctness): external score reads lower than in-process** because uncovered
  mutants score `survived` not `no_coverage` (KTD-6). *Mitigation:* documented
  non-comparability + no-coverage count in the run header (U6).
- **R (security): command injection via `--test-command`.** *Mitigation:* argv
  array form, no shell string built from file lists, no `eval` (KTD-4, repo
  constraint). U3 asserts argv construction.
- **R (perf): per-mutant boot makes large audits slow.** *Accepted* for Phase 1
  (the whole point is correctness + reach on old Ruby); Phase 2 fixes it.
- **Dependency:** Phase 2 spike is shared with #26 — coordinate so one spike
  answers both (`docs/plans/issue-26-db-isolated-parallel-spike.md`).

---

## Definition of Done

**Phase 1 (shippable on its own):**
- A Ruby 3.1–3.3 Rails app produces correct kill/survive verdicts via
  `--test-command` (R1), with the tool process still on ≥3.4 (R2).
- `--test-command` works from CLI and `.mutineer.yml`, validated, with clear
  errors on conflicts (R3, R6).
- Exit-status mapping is correct: invalid mutants stay `skipped`, a "suite failed
  to run" code maps to `error`, and a non-green smoke check aborts before scoring
  (R4).
- The working tree is provably never left mutated, including after a simulated
  hard kill (R5) — asserted by tests.
- Tradeoffs documented (R7).
- In-process behavior is unchanged when `--test-command` is absent (regression
  guard green).

**Phase 2 (gated on spike):**
- Spike proves tool-3.4 → app-3.1 isolated-DB worker verdict parity with serial
  (R8) before any build.
- Daemon backend restores one-boot speed and coverage narrowing, no Prism on the
  app side, converged with #26 (R9, R10).

---

## Verification Contract

- **Unit:** U1–U5 each have the test scenarios above; feature-bearing units
  (U2–U5) test happy path + error/edge + the data-safety/infra-error paths.
- **Integration:** a tiny in-repo fixture (a source with one killed + one survived
  mutant and a trivial `--test-command`) proves the external backend end-to-end
  without needing a real Rails app in CI.
- **Regression:** an existing boot-mode test runs unchanged with `--test-command`
  absent, proving the in-process path is untouched.
- **Manual (Phase 1 acceptance):** run against a real Ruby 3.1.x Rails app (the
  issue author offered to help) and confirm verdicts match expectation.
- **Gate:** Phase 2 build does not begin until the R8 spike passes.
