# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **`--timeout SECONDS` and `--capture-timeout SECONDS`**, also `timeout:` and
  `capture_timeout:` in `.mutineer.yml`. They set the in-process per-mutant
  time limit (default 10s) and the coverage-capture time limit (default 120s),
  which were fixed. On a large Rails suite the clean run of the unmutated
  tests took longer than 120s, so every run that offered the whole suite
  stopped as not green, and a mutant on a line many tests cover took longer
  than 10s and was scored `timeout`. `--daemon` and `--test-command` keep
  their own limits.
- **The README states how timeouts affect the score** (#62): a timed-out
  mutant is left out of the score, and counts as a mutant with no verdict
  under `--threshold`.

### Changed
- **The human report has a `Timeout:` row**, and the score line lists timeouts
  apart from errored mutants. Before, the `Errored:` row and the score line
  added the two together, while the JSON report kept them apart.

### Fixed
- **A bare `public`, `private` or `protected` ends `module_function` mode**,
  so later `def`s in the module body are named as instance methods, not
  singleton methods (#144).
- **Turning on reduced motion mid-visit finishes the landing page count-ups**,
  so no number keeps changing after the visitor asks for less motion (#176).
- **`rake site:build` can no longer delete a directory such as `lib/` or
  `.git`** (#162). The task removed the destination it was given, and only
  refused the checkout, its parents and `docs/`. It now always builds into
  `_site/` at the checkout root, and `rake "site:build[DEST]"` and
  `SITE_BUILD_DEST` are gone.
- **Documentation matches the 1.4 behavior.** Config examples use supported keys,
  agent loops check the exit code and a real score, and report totals explain
  partial `--fail-fast` runs. The README lists every config key and its validation
  rules. API README links work outside GitHub, repeated changelog headings have
  unique anchors, and the website checks validate built links and anchors.
  Mutant-id wording and the gem's Minitest/RSpec description are also corrected.

## [1.4.0] - 2026-09-30

### Added
- **Condition-forcing operators** (Tier-2, opt-in via `--operators`):
  `condition_true` and `condition_false` replace an `if`/`elsif`/`unless`,
  ternary, modifier or `case`/`in` guard condition with `(true)` or `(false)`, so
  its branch always runs or never runs. A surviving mutant means no selected
  test detected the forced condition. A literal condition, also in
  parentheses, makes no mutant: forcing it changes nothing or repeats the
  `boolean_literal` flip. A condition that holds a heredoc makes no mutant.
  A condition that assigns a variable keeps its code, and only its value
  is forced (`(m = x; true)`), so later code still sees the variable.
  The never-runs side of an else-less conditional can
  be the same program as the `nil` that `statement_removal` or `return_nil`
  puts in its place; it is still made, so these mutants and their ids do not
  depend on which other operators run.
- **Operator-assignment operator** (Tier-2, opt-in via `--operators`):
  `operator_assignment` swaps the operator of a compound assignment:
  `+=` <-> `-=`, `*=` <-> `/=`, and `%=` and `**=` -> `*=`. It covers local,
  instance, class and global variables, constants, calls (`a.b += 1`) and
  index calls (`a[i] += 1`). The `arithmetic` operator never sees these
  forms, because Prism does not parse them as calls. The operator does not
  change `||=`, `&&=`, or the bitwise and shift forms (`|=`, `<<=`).

### Fixed
- **A typed `--rails`, `--verbose` or `--debug` beats `rails: false` and
  `verbose: false` in `.mutineer.yml`** (#103). The flag was dropped, so the
  run went on without Rails boot or verbose output. The config layers now keep
  only the keys the user wrote, and "did the user write this" comes from those
  keys, not from a hand-kept list.
- **`framework: rspec` in `.mutineer.yml` survives test pairing** (#103).
  Pairing re-detected the framework from the test file names, so an RSpec
  suite in `test/calc_test.rb` ran under Minitest.
- **A bad number is an error, not a rounded value** (#105). `--jobs 1.9` and
  `--baseline-epsilon abc` no longer become `1` and `0.0`. One option schema
  parses each value once, where it enters, for both the command line and
  `.mutineer.yml`.
- **`--since` keeps a source file that git does not track yet** (#156). Before,
  such a file counted as unchanged. The run scored no mutants, and a positive
  `--threshold` still exited 0. The file is now new in full, so all its
  mutants run.

### Changed
- **These now exit 2 with a message that names the option**: `jobs: 1.9` or
  `jobs: true` in `.mutineer.yml` (before: `1`, or a crash); a bad, negative
  or non-finite `--baseline-epsilon` (before: `0.0`); a boolean key in
  `.mutineer.yml` that is not `true` or `false`, such as the string `"yes"`
  (before: `false`).
- **`--jobs` takes plain digits only.** `0x2`, `+2`, `" 2"` and `1_0` exit 2.
  Before, `Integer()` read them as 2, 2, 2 and 10. `--threshold` and
  `--baseline-epsilon` take a plain decimal, such as `2` or `2.5`, from a
  string. `0x10`, `+2`, `1_0` and `1e2` exit 2. Before, `Float()` read them
  as 16.0, 2.0, 10.0 and 100.0.
- **A string option that gets `true`, `false` or no value exits 2**, such as
  `only: false` or `baseline:` in `.mutineer.yml`. A blank `since` also exits 2,
  in the file and on the command line, so an unset shell variable does not
  turn scoping off. `since: false` still means no scoping.
- **Config file errors start with the file and key**, for example
  `.mutineer.yml: threshold must be a number between 0 and 100`, where they
  started with `--threshold`.
- **The docs site is built in CI** — a Pages workflow runs `rake site:build`
  and deploys the result, so the YARD HTML under `/api/`, `llms-full.txt`,
  `json-schema.html` and `sitemap.xml` are no longer committed. CI checks
  that the site builds, in place of `rake yard:pages:check`. The site keeps
  its URLs (#153).

## [1.3.0] - 2026-09-29

### Changed
- **Mutant ids now include the project-relative file path** (#126). Before, two
  mutants with the same method name, operator and token in different files got
  the same id. That happened with a top-level `def` or block in two files, and
  with a class reopened in another file. One `ignore:` entry then suppressed
  both mutants, and `--baseline` could hide a new survivor behind an old one.
  - Every survivor id changes once in this release. This affects any external
    tool that tracks survivors by id.
  - Moving or renaming a file now changes its ids.
  - Ids follow the project root: the directory mutineer runs from, or the
    Action's `working-directory`. A run from a different root gives different ids.
    mutineer finds `.mutineer.yml` by walking up, so a run from a subdirectory
    prints one `[mutineer]` warning that the loaded ignore ids will not match.
  - A source outside the project root uses its absolute path, so its ids differ
    between machines.
  - Two methods with the same qualified name in one file (for example two
    top-level `def index` in two DSL blocks) now get different ids. The second
    and later ones hash their position among those methods; the first keeps its
    id.
- **The JSON report marks its id format** (schema `1.4`, additive).
  `summary.id_format` is `2` for ids that include the file path.
  `summary.legacy_id_matches` counts old-format `ignore:` entries (`ignore`) and
  survivors matched only through an old-format baseline id (`baseline`). The
  GitHub Action shows one warning annotation when either count is not zero.

### Deprecated
- **Old-format ids in `ignore:` and in baselines.** Matching on them is removed
  in 2.0. Replace each old `ignore:` entry with the new ids from the warning
  (only the intended ones when it over-matched several mutants).
  Regenerate a baseline (`--format json`) only after every gate that reads it
  runs this version or later (the Action's `version:` pin, your CI
  `Gemfile.lock`). An older version treats every new-format survivor as new.

### Fixed
- **`module_function :name` and `module_function def name` promote only
  their own module's methods** — a class or module in the same file with a
  method of the same name kept an instance method in Ruby, but mutineer
  named it as a class method. `--strategy redefine` then mutated a method the
  tests never call, so a killable mutant falsely survived, and
  `--only Class#name` selected nothing (#98). The affected methods now get
  their correct names, so their mutant ids change: regenerate any ignore
  entries or baseline survivors that pointed at them.
- **A root-anchored reopening names the top-level constant** — a
  `module ::Root` or `class ::Solo` written inside another module now gives
  `Root` and `Solo`, not `Outer::Root` and `Outer::Solo`. This applies to every
  method in such a body, with or without `module_function`, so their mutant
  ids change too. `--strategy redefine` rebuilds such a body's scope as
  written (`module Outer` then `class ::Solo`), so a constant from `Outer`
  still resolves in the mutated method, as it does under `reload`. Before,
  the method raised NameError in the test, which counted as a false kill
  (#145).
- **Old-format ids keep working, with a warning** (#126). An old-format
  `ignore:` entry still suppresses the mutants it matched before. The run prints
  one `[mutineer]` warning per entry with each new id, its file and its method.
  When the entry matched several mutants (in different files, or same-named
  methods in one file), the warning says it
  over-matched and to keep only the ids for the mutant you meant to ignore. A
  `--baseline` file without `summary.id_format` matches on new ids, or on old
  ids from the same file, so no survivor reads as new or fixed only because its
  id changed. A stored file outside the project root (a baseline written on
  another machine) matches on the old id alone. The run prints one
  `[mutineer]` warning to regenerate the baseline.

## [1.2.0] - 2026-09-28

### Added
- **Operand-removal operator** (Tier-2, opt-in via `--operators`):
  `operand_removal` replaces `a && b` with `(a)` and with `(b)`, and does the
  same for `||`, `and` and `or`. The mutant survives when no test needs the
  operand that the mutant removes. The operator never keeps a jump operand
  (`return`, `break`, `next`, `redo`, `retry`) alone, because a jump does not
  parse in a value context. It never removes an operand that holds a heredoc,
  because the heredoc body stays behind as code. It skips nested method
  definitions, because mutineer mutates each one as its own method.
- **Array-literal operator** (Tier-2, opt-in via `--operators`):
  `array_literal` replaces a non-empty array literal, such as `[a, b]` or
  `%i[a b]`, with `[]`. The mutant survives when no test checks the contents
  of the array. The operator skips an implicit array (`x = 1, 2`), an array
  that holds a heredoc, and nested method definitions.
- **Sources also pair with Minitest's `test/**/test_*.rb` files** — after the
  `_test.rb` forms, so existing projects pair as before. `lib/helper.rb` does
  not pair with the `test/test_helper.rb` support file. A failed capture of a
  `test_<name>.rb` file now marks `<name>.rb` uncapturable, as `<name>_test.rb`
  does (#120). Without `framework:` set, a source with `spec/<name>_spec.rb`
  and `test/test_<name>.rb` but no `<name>_test.rb` now pairs with the
  Minitest file, as the "Minitest first" order says.

### Fixed
- **`reload` loads the mutant by an absolute path** — a relative source path
  gave the mutant relative backtrace paths, so code that checks its own frames
  by absolute path failed for every mutant, a false kill (#123).
- **`require "test_helper"` works without `RUBYOPT`** — a standalone run puts
  `lib`, then each test file's `test_helper.rb` directory, on the load path,
  as boot mode and `rake test` do. A run where no test records coverage because
  captures failed now exits 1 instead of reporting N/A (#119).
- **A disable-line marker warns about an operator it does not know** — a
  reason written without `--` became part of the operator name, so the marker
  suppressed nothing and said nothing (#124). A marker followed only by spaces
  or commas, such as `disable-line  -- why`, now disables the whole line.
- **Coverage capture and the clean check run each source once** — they read
  sources with `load`, so a test's own `require` ran them again: a `Struct`
  superclass raised `superclass mismatch`, and load-time code ran twice (#122).
  A mutant of such a class still errors under `--strategy reload`, which loads
  the mutated file again; `--strategy redefine` runs it.
  Code that guards itself to run once (`unless defined?(X)`) can now show as
  covered, so its mutants run where they were `no_coverage` before.
- **A red unmutated suite now shows why it failed** — in a standalone run, the
  Minitest summary or RSpec output of the failing test, with its failure
  message, goes to stderr before the "not green" error. A passing run prints
  nothing extra. Boot mode (`--rails`, `--boot`) is unchanged (#121).

## [1.1.0] - 2026-09-28

### Added
- **Safe-navigation operator** (Tier-2, opt-in via `--operators`):
  `safe_navigation` replaces `&.` with `.`. The mutant survives when no test
  passes `nil` to the call.
- **Range operator** (Tier-2, opt-in via `--operators`): `range` replaces
  `..` with `...` and `...` with `..`. The `..` -> `...` mutant survives when
  no test checks the last element of the range. Endless ranges (`1..`) are
  skipped, because `(1..)` and `(1...)` give the same result for slicing,
  `include?`, `===` and pattern matching.
- **Negation-removal operator** (Tier-2, opt-in via `--operators`):
  `negation_removal` removes the `!` from `!x` and the `not` from `not x`.
  The mutant survives when no test depends on the negated value. The
  explicit form `x.!` is skipped, because `x.` does not parse.

### Changed
- **Stderr of tests and specs is visible** in the in-process and `--daemon`
  runs. Mutineer silences stdout once per child process and no longer hides
  stderr, so its own child diagnostics always reach you. `--test-command`
  runs still capture stderr with stdout and show it under `--verbose`.
- **A mutant's test run stops at the first failing test** — one failure
  already kills the mutant, so the forked child does not run the tests that
  remain. Killed mutants cost less time, and survived mutants cost the same.
  Under Minitest, when the outer reporter of the run records a failure or an
  error (a skip does not count), each remaining test and each remaining test
  class returns before it starts. A skipped class does not start its
  class-level hooks. The run does not unwind: a class that is running
  finishes normally, so its `after_all` hooks and a class-level
  `transaction { super; raise ActiveRecord::Rollback }` still run. RSpec runs
  with `--fail-fast`. This applies to the in-process backend only: coverage
  capture and the clean checks still run every test, and the `--daemon` and
  `--test-command` backends do not change. The CLI `--fail-fast` flag keeps
  its meaning. On rack's `lib/rack/utils.rb` (`--jobs 1`), a full run takes
  about 35–41 s instead of about 86–89 s. With the same coverage map, the
  verdicts are the same.
- **The mutant run uses a fixed Minitest seed** — with the stop, the test
  order can decide the verdict, so the child runs Minitest with seed `1`
  unless the environment sets `SEED`. The same code then gives the same
  verdict on each run. Coverage capture and the clean checks keep the random
  seed, so the clean check runs the tests in a random order while each mutant
  run uses the fixed order. RSpec keeps its configured order: a suite configured with
  `config.order = :random` can still get a different verdict on each run for
  the case below. In an order-dependent Minitest suite, the fixed seed makes
  a false `killed` happen on every run or on no run, not on some runs.
- **A mutant whose failing test runs before a hanging test is now `killed`,
  not `timeout`** — the run stops at the failure, before the hang. The tests
  did detect the mutation, so `killed` is the correct verdict. If the hanging
  test runs first in the fixed order, the verdict stays `timeout`. Compared
  with a baseline from an earlier version, the score usually goes up. In an
  order-dependent suite it can also go down: a mutant that a random order
  killed on some runs can survive on every run in the fixed order. A change
  to the tests can change the fixed order, so a later run can move such a
  mutant from `killed` to `timeout`, and a `--baseline` gate then reports a
  score drop.
- **Some runs still run most tests** — Minitest `parallelize_me!`, and Rails
  `parallelize` above its threshold (by default more than 50 tests in the
  child, or at any test count when `PARALLEL_WORKERS` is 2 or more in the
  environment), queue their tests before the first result comes back, so the
  queued tests still run. The verdict is the same as before. Below the
  Rails threshold, the tests run one after the other in the child, and the
  stop works.

### Fixed
- **Tests that reopen `$stdout`** (Minitest's `capture_subprocess_io`,
  RSpec's `to_stdout_from_any_process`) no longer make a green suite
  "not green" or count as false kills.
- **Test or source files that print while they load** no longer make coverage
  capture fail with `invalid coverage output`. The capture subprocess now
  sends its result over a separate pipe, not over stdout.
- **Chain-link operator** (Tier-2, opt-in via `--operators`):
  `chain_link` drops one call from a chain, with its arguments and block
  (`user.account.name` -> `user.name`). The mutant survives when no test tells
  the chain apart from the same chain without that step. Conversions and copies
  (`to_s`, `to_a`, `dup`, `freeze`, ...) and `new` are never dropped.

## [1.0.2] - 2026-09-21

### Added
- **AI-readable docs wiring**: HTML pages with Markdown twins now advertise
  `rel="alternate" type="text/markdown"`, `index.md` is the landing/CLI
  essentials twin, `skill.md` is listed under Optional in `llms.txt`, and
  `sitemap.xml` is generated from the same catalog as `llms.txt` (#91).
- **Single-source CLI contract**: exit codes and `--threshold` live in
  `docs/fragments/contract.yml`; `rake docs:generate` writes `llms-full.txt`,
  `json-schema.html`, and the marked copies so they cannot drift (#82).
- **YARD API on Pages**: the current gem's YARD HTML is published at
  `/api/`, linked from the docs site, and `rake yard:pages:check` keeps it
  from lagging the shipped sources. `documentation_uri` stays the Pages
  root (#92).

## [1.0.1] - 2026-09-18

### Added
- **RubyGems `documentation_uri`**: the published gem now points at the docs
  site (`https://davidteren.github.io/mutineer/`) so gem-page discovery
  reaches the Pages docs (#90).

### Fixed
- **A red unmutated suite can no longer pass a mutation gate** — coverage
  capture now keeps the original Minitest/RSpec result, and a failing clean run
  aborts with the existing smoke-check error (exit 1) instead of scoring those
  assertion failures as killed mutants. A warm coverage cache re-checks the
  current suite and cannot bypass this (#96).
- **Concurrent external runs no longer restore each other's source files** —
  swap and orphan recovery share one exclusive OS lock per source, acquired
  before reading or healing. A live owner's mutant and backup stay intact; a
  dead owner's backup still restores the original bytes (#99).
- **Coverage cache now invalidates when a required test helper changes** —
  a successful map records fingerprints of project-local loaded Ruby files,
  old cache entries without that data rebuild, and a helper-only edit no
  longer hides a new survivor behind a stale 100% score (#97).
- **Release version calculation ignores floating major tags** — `release-pr.yml`
  selects the newest complete `vMAJOR.MINOR.PATCH` ancestor and validates the
  next version before writing files, so a later `v1` tag can no longer produce
  `v1..1` (#95).

## [1.0.0] - 2026-09-08

The GitHub Action's PR default changes in this release, which is why it is a
new major: workflows pinned to `davidteren/mutineer@v0` keep the old full-scan
behavior; upgrading to `@v1` opts into diff-scoped PR runs (details under
Changed).

### Added
- **The Action reports where CI readers look**: with the default JSON format it
  writes a score/pass-fail table (plus the baseline delta, when `baseline` is
  set) to the job step summary, and emits one `file=…,line=…` annotation per
  surviving mutant (up to 50; the summary lists the first 20, the full set
  stays in the JSON report) so results land on the PR diff instead of only in a
  collapsed log group — `error` level when the gate failed, `warning` when it
  passed. When `output` is unset the JSON report is routed to a temp file and
  still printed to the log, and the `report` output now exposes the report
  path in both cases so a later step can consume the JSON without scraping
  the log (#86).
- **Progress during the run**: every backend prints `[mutineer] N/M mutants
  (P%)` to stderr at each 10% step, so a long run is never silent between
  config resolution and the report. Stdout stays byte-exact for `--format json`
  and `--output`. `WorkerPool#run` gains an optional `on_result:` callback for
  this (called in the parent per reaped result) (#86).

### Changed
- **PR runs scope themselves in the GitHub Action**: on `pull_request` events
  the `since` input now defaults to the PR base, so the action grades just the
  diff out of the box. **Migration note (the reason for the major bump)**: a
  PR gate that previously full-scanned now scores only the PR's changed lines,
  so `threshold` applies to fewer mutants. Stay on `@v0` to keep the old
  default, or pass `since: none` on `@v1` for full scans. Workflows that
  already pass a non-empty `since` are unchanged (an explicit empty string is
  indistinguishable from unset and picks up the new default). A PR with no
  changed source lines (docs- or test-only) scores zero mutants and passes the
  scoped gate vacuously; keep a full-scan baseline refresh on main as the
  backstop. With `use-bundler: true` the caller's Gemfile picks the gem, and
  the new default needs mutineer >= 1.0.0 (the action enforces the floor with
  a clear error). The action scopes to the PR's exact base commit from the
  event payload (immune to the
  base branch advancing mid-job), falling back to a fresh fetch of the base
  branch tip; when neither can be resolved it warns and runs without an
  action-provided `--since` (a `.mutineer.yml` `since:` key, if any, still
  applies). The default deliberately does NOT fire on `pull_request_target`:
  checkout there defaults to the base branch, so auto-scoping would diff the
  base against itself and green the gate on an empty run (#86).
- **`--baseline` on a diff-scoped run gates on new survivors only**: a
  `--since` run's score covers only the changed-line mutants, a different
  denominator from a full-run baseline, so comparing the two scores
  manufactured false regressions (a 3/4-mutant PR at 75% "dropped" from a
  92% whole-repo baseline with zero new survivors). With `--since`, the
  score-drop half of the baseline gate is skipped; new-survivor detection by
  stable id (and the reported before/after scores) are unchanged. The JSON
  report records the scope in a new additive `summary.scoped` key
  (`schema_version` 1.3), and the `baseline` block records `score_comparable`
  so a consumer knows when not to render the two scores as a comparison
  (`fixed_survivors` is likewise empty under a scoped side: an out-of-scope
  survivor was never re-tested, so absence does not mean fixed). The reverse
  direction is a hard guard: a scoped report is refused as a baseline (exit 2
  with a regenerate hint), because survivors outside its diff would all read
  as new regressions. A new `--no-since` flag disables diff scoping explicitly: a
  typed no beats a `.mutineer.yml` `since:` key, and the action's
  `since: none` passes it through (#86).

## [0.11.4] - 2026-07-29

### Fixed
- **`--threshold` now gates on the run being complete, not just its score** — a
  score is `killed / (killed + survived)`, so mutants that error, time out or come
  back uncapturable are excluded from the denominator: a broken harness *raised*
  the score instead of lowering it. Ninety errored mutants and ten that ran (nine
  killed) reported 90% and exited 0, so CI could not tell a complete run from a
  mostly-broken one. Past 10% of attempted mutants producing no verdict, a positive
  `--threshold` now exits 1 whatever the score, and the report says which states
  broke, on every `--format`. A single bad mutant never trips it, however small the
  run, so a `--since` PR with a handful of mutants keeps its flake tolerance (#78).

### Added
- **`no_verdict[]` in the JSON report** (`schema_version` 1.2) — every attempted
  mutant that produced no verdict, with its `status` and, where there is one, the
  `details` explaining the cause. `Result#details` was built and rendered in no
  format at all, so a daemon crash reached the user as nothing but a larger errored
  count. `summary` gains `attempted` and `no_verdict`, the two figures the
  completeness gate is computed from (#78).

## [0.11.3] - 2026-07-29

### Fixed
- **Nothing to mutate now costs nothing** — `--since` matching no changed line (a
  docs-only PR, which README documents `--since origin/<base>` for) still did the
  expensive part before discovering there was no work: `--daemon` booted the app
  once for the coverage map and again for every `--jobs` worker, and
  `--test-command` ran the whole suite for a smoke check that calibrates a timeout
  no mutant would use. Both backends now return as soon as the job list is empty.
  The in-process path is unchanged: it boots before collecting jobs, so it cannot
  know the list is empty yet. One consequence worth stating: a zero-job `--daemon`
  run no longer boots the app, so an app that fails to boot now exits 0 (nothing
  to do) instead of exit 1 (#76).
- **A dead daemon ends the run instead of scoring the rest against it** — a
  daemon that dies while running one mutant was already handled: `DaemonClient`
  respawns and answers `error` for that mutant. But a daemon that could not come
  back was not. `restart!` closes the pipes before respawning, so if the respawn
  failed at the OS level (`EMFILE` or `ENOMEM` under `--jobs N`, `ENOENT` when
  `bundle` does not resolve) the client was left permanently dead while raising
  errors that read as ordinary per-mutant failures. Every remaining mutant scored
  `error` against nothing, and Mutineer printed a mutation score built on the
  fraction of mutants that ran before the daemon died. `DaemonClient` now raises
  `DaemonBootError` whenever it is gone for good — a refused spawn, a failed boot
  handshake on respawn, closed pipes, or `MAX_RESTARTS` crashes — and the CLI
  reports it as a message and exit 1 rather than a backtrace. Under `--jobs N`
  the remaining queue is dropped so sibling workers stop too. Errored mutants
  still cannot fail the `--threshold` gate once any mutant is scored (#78).

### Changed
- **Daemon orchestration split out of `Runner`** — the persistent-daemon backend
  (job fan-out, worker DBs, coverage-map build, boot config, verdict mapping) now
  lives in `Mutineer::DaemonBackend`. `Runner` keeps job collection, coverage
  selection and the single in-process mutant run, and drops from 662 to 439 lines.
  The external backend's orchestration stays on `Runner` for now, so the two
  backends are not yet symmetrical. No CLI or behaviour change (#58).
  Internal-only removals: `Runner.execute_daemon`, `Runner.daemon_coverage_map`
  and `Runner::DAEMON_TIMEOUT` no longer exist. They were never documented —
  the supported programmatic contract is the JSON report, the stable mutant ids
  and the exit codes — so only code calling `Runner` internals directly is
  affected.
- **Comment diet on orchestration files** — present-tense YARD contracts; drop
  ticket/phase/KTD history tags from runner, CLI, daemon pair, coverage map,
  reporter, result, and related modules. Safety and score invariants kept (#57).

## [0.11.2] - 2026-07-24

### Fixed
- **`--test-command` under version managers** — scrub Mutineer's rbenv/asdf
  version bins and bundler/gem env from the child so the suite can resolve the
  app's Ruby via shims / `.ruby-version`. Smoke check prints a targeted hint on
  `Bundler::RubyVersionMismatch` instead of only blaming DB/migrations. Docs
  cover a wrapper recipe for stubborn setups (#32).

## [0.11.1] - 2026-07-23

### Fixed
- **`--daemon` score disclosure** — stop claiming “no coverage narrowing / lower
  bound” on every run (narrowing already ships). Warn only when the coverage map
  is unavailable and the run falls back to the full `--test` set (#48).
- **`--threshold` CI fidelity** — exit 1 when a positive threshold is set but the
  run produced only errors/timeouts/uncapturable (nil score with a broken harness)
  instead of silently green; pure no_coverage / all-ignored still skips the gate
  (#49). Non-numeric `--threshold` / YAML `threshold` is a usage error (exit 2),
  not a silent gate-off (#51).
- **`--daemon` contracts** — reject `--framework rspec` (exit 2); force
  `--strategy reload` with a clear warning when redefine was requested (daemon
  whole-file only) (#50). **In-process `--rails` always serial** unless
  `--daemon` (only daemon has per-worker DB isolation) (#55).
- **Isolation timeout** — kill the child process group and honor a clean exit
  that races the deadline (not always timeout) (#52). **External backend** —
  signal death is `error`, not `killed` (#53).
- **`--fail-fast` is serial** on the in-process path (matches daemon) so the
  survivor set is deterministic under any `--jobs` (#54).
- **Dry-run uses `collect_jobs`** so candidates match a real run (#59).
- **Daemon schema load once per worker** (not every mutant fork) (#56).
- **Nested `statement_removal`** visits inner statement lists (#62).
- Dead seams: remove unused `RailsWorkerDb.provision`, simplify parallel daemon
  fail-fast branch, drop unused `validate_daemon!` arg (#60).
- Archive historical implementation spec under `docs/archive/` (#61).

## [0.11.0] - 2026-07-02

### Added
- **`--daemon` backend — fast, parallel-safe Rails mutation testing** (#26/#27
  Phase 2). Boots the app **once** in a persistent daemon and forks per mutant
  (restoring shared-boot speed), and gives **each parallel worker its own
  database** so `--jobs N` is safe under Rails for the first time — parallel
  verdicts are proven identical to serial (no fixture cross-talk). Coverage
  narrowing is restored on this path (each mutant runs only its covering tests;
  a mutant on an uncovered line is `no_coverage`), so the daemon score is
  comparable to the in-process `--rails` score. Opt in with `--rails --daemon`
  (also `daemon: true` in `.mutineer.yml`); `--daemon` can't be combined with
  `--test-command`. **SQLite** today (hermetic, CI-proven); **Postgres**
  per-worker provisioning is in progress (#34/#35). The gem core stays Prism +
  stdlib, zero runtime dependencies — worker-DB routing uses the app's own
  ActiveRecord.

## [0.10.0] - 2026-07-02

### Added
- **`--test-command` external backend** (#27) — mutation-test apps pinned to Ruby
  < 3.4. Mutineer stays on ≥ 3.4 but runs your suite as a subprocess in the app's
  own runtime via `--test-command "bundle exec rails test %{files}"` (`%{files}`
  expands to the `--test` paths; env is inherited). The mutant is applied on disk
  with crash-safe backup/restore (self-heals a hard-killed run on next startup); a
  smoke check aborts before scoring if the unmutated suite isn't green. This path
  is reload-only, serial (`--jobs` forced to 1), and does no coverage narrowing —
  so its score is an upper bound, not comparable to an in-process `--rails` score
  (Mutineer prints this caveat). Also settable as `test_command:` in `.mutineer.yml`.
  Safe parallelism for this path is tracked in #26.

## [0.9.1] - 2026-07-01

### Fixed
- **Per-method uncapturable granularity** (#25) — the `:uncapturable` taint was
  whole-file, so a method reachable only by a *failed* capture in an otherwise-
  covered file was mislabeled `no_coverage`. It's now attributed per method (by
  the method's body coverage), so only the affected method is tainted. Fully-
  failed files are unchanged.

## [0.9.0] - 2026-06-30

### Added
- **`--fail-fast`** (#21) — stop at the first surviving mutant; in-flight workers
  drain, the rest are skipped. Fast red signal for PR gates.
- **`--format html`** (#23) — a single self-contained HTML report (inline CSS, no
  external assets) with the score, per-source table, and a card per survivor
  (subject, file:line, operator, stable id, diff).
- **String, regex, and collection-method operators** (#24, Tier-2, opt-in via
  `--operators`): `string_literal`, `regex`, `collection_method`
  (`map`↔`each`, `all?`↔`any?`, `first`↔`last`, `min`↔`max`, `select`↔`reject`).

### Changed
- **`--dry-run` now honors suppression** (#22) — inline `# mutineer:disable-line`
  and `.mutineer.yml` `ignore:` entries are omitted from the preview and counted
  as "ignored (suppressed)", matching a real run.

## [0.8.0] - 2026-06-30

### Fixed
- **Singleton methods are now mutated** (#20) — `class << self` and
  `module_function` methods were discovered but applied to the instance scope, so
  the mutant never ran on the singleton the caller dispatches to; every such
  mutant falsely survived and the file read a false 0%. `module_function` methods
  are now discovered as singletons, and the redefine strategy re-opens
  `class << self` so the mutation lands on the called method. (Scores for
  singleton-heavy files will rise to their true values.)
- **Write-heavy Rails tests are capturable again** (#19) — capture/worker pipes
  are `binmode`: a binary Marshal payload over a text-mode pipe could raise an
  encoding error the child then swallowed → empty pipe → false `:uncapturable`.
  That was the root cause of the residual write-heavy failures too. A child that
  dies without writing now also reports how it died (exit status / signal), and
  `--verbose` always surfaces a real reason. Verified on a real Rails app: all 6
  previously-uncapturable interactors (incl. caxlsx + Google-client) now capture
  with real scores, 0 uncapturable.

## [0.7.1] - 2026-06-30

### Added
- **GitHub Action** (`action.yml`, composite) wrapping the CLI for CI — gate a PR
  on new survivors / score drop with `sources`, `since`, `baseline`, `threshold`,
  etc. Inputs are passed via `env` (no `${{ }}` interpolation into the run script)
  for command-injection safety.
- Docs site (GitHub Pages) with Open Graph / Twitter Card share image; YARD doc
  comments across the library.

## [0.7.0] - 2026-06-30

Rails hardening + CI batch (issues #8–#13), all verified Rails-free.

### Added
- **Equivalent-mutant suppression** (#10) — inline `# mutineer:disable-line [ops]`
  and a `.mutineer.yml` `ignore:` list keyed on a stable, offset-free mutant id;
  suppressed mutants are excluded from the score (100% reachable). The stable id
  (and readable token) is emitted per survivor in JSON.
- **Source→test auto-pairing + multi-source runs** (#11) — pass a directory or
  several sources with `--test` omitted; tests are inferred by convention
  (`app/`,`lib/` → `test/…_test.rb` / `spec/…_spec.rb`) and run under one boot,
  with per-source results (human + JSON `per_source`).
- **`--baseline <file.json>` CI gating** (#13) — diff against a prior run by stable
  id; exit 1 on new survivors or a score drop (with `--baseline-epsilon`), naming
  what regressed. Combines with `--threshold` via max exit code.
- **`--verbose`/`--debug`** (#8) — surface the real error when a fork capture fails.
- **`:uncapturable` status** (#9) — distinct from `no_coverage`; reported separately
  ("tests failed to run" vs "genuinely uncovered"). Both excluded from the score.

### Fixed
- **Fork capture no longer drops fixture transactions** (#8) — `reconnect` skips
  `clear_all_connections!` when a fixture transaction is open, and stops swallowing
  the child error; write-heavy Rails tests are mutation-testable again.

### Changed
- JSON `schema_version` → `1.1` (additive: survivor `id`/`token`, `ignored`,
  `uncapturable`, `per_source`).

## [0.6.2] - 2026-06-29

### Fixed
- **`--rails` defaults `RAILS_ENV` to `test`** (#7) — an unset `RAILS_ENV` booted
  development, where the suite isn't loaded, so every mutant was falsely reported
  `no_coverage` (score N/A, exit 0). An explicit `RAILS_ENV` is respected.
- **`--rails` defaults to `--jobs 1`** (#12) — parallel mutant forks share one
  database and deadlock on transactional fixtures; explicit `--jobs N` opts back
  into parallelism.

### Added
- **Tier-2 operator discoverability** (#14) — the human-format run summary now
  lists the available opt-in tier-2 operators and how to enable them.

## [0.6.1] - 2026-06-29

### Changed
- **Removed `eval` entirely** — the redefine strategy now `load`s the wrapped
  method snippet from a tempfile instead of evaluating a string. Behavior is
  identical (top-level load rebuilds the same `Module.nesting`), but the gem no
  longer uses dynamic string execution, clearing supply-chain scanner flags.
  Zero runtime dependencies unchanged.

## [0.6.0] - 2026-06-28

### Added
- **RSpec support** (#6) — `--framework rspec` (or auto-detected when most
  `--test` files end in `_spec.rb`) runs RSpec suites instead of Minitest, via a
  pluggable test-runner abstraction. Both frameworks are loaded lazily, so
  Mutineer keeps zero runtime gem dependencies and works in an rspec-only
  project; coverage selection works for both. `.mutineer.yml` accepts `framework:`.

### Fixed
- **Redefine strategy keeps compact `class A::B` as a single nesting wrapper**
  (#5) — avoids a constant-resolution disagreement with the reload strategy.

## [0.5.0] - 2026-06-28

### Fixed
- **`class << self` methods are now discovered and mutated** (#3) — previously
  they were treated as instance methods, so the redefine strategy mis-targeted
  them. `class << other_obj` blocks are skipped (not representable).
- **Worker pool no longer deadlocks on large results** (#4) — pipes are drained
  with `IO.select` and children reaped on EOF, so a result bigger than the OS
  pipe buffer (~64KB) can't wedge the run.

## [0.4.0] - 2026-06-28

### Added
- **`--since <git-ref>`** (#2) — mutate only the lines changed since a git ref
  (e.g. `--since origin/main`), so CI on a pull request mutation-tests just the
  new/changed code. Composes with coverage selection; `--dry-run --since`
  narrows the preview too. Unknown ref / not-a-git-repo exits 2.

## [0.3.0] - 2026-06-28

### Added
- **Coverage-guided test selection in boot mode** (#1) — `--rails`/`--boot` now
  captures coverage by forking the booted app and runs only the test files that
  cover each mutant's line (uncovered lines report `no_coverage`), instead of
  running every `--test` file for every mutant. Cached like standalone mode.

## [0.2.0] - 2026-06-28

### Added
- **Boot mode for Rails (and any app needing its environment booted)** —
  `--rails` boots `config/environment` once in the parent and forks per mutant
  (children inherit the booted app), defaults the strategy to `redefine`, and
  reconnects ActiveRecord in each fork for DB fork-safety. `--boot FILE` boots a
  custom entry point. Boot mode requires `--test` files and runs them for every
  mutant (coverage-guided selection in boot mode is future work). `.mutineer.yml`
  accepts `boot:` and `rails:`.
- GitHub Actions CI (test suite + gem build on Ruby 3.4, ubuntu + macos).

### Changed
- `--strategy` values are now `reload` / `redefine` (canonical); `7a` / `7b`
  remain accepted as deprecated aliases.

## [0.1.0] - 2026-06-28

### Added
- Initial release of Mutineer — a clean-room, Prism-based mutation-testing tool
  for Ruby with zero runtime dependencies (Ruby ≥ 3.4).
- Mutation operators: arithmetic, comparison, boolean-connector, boolean-literal,
  statement-removal (Tier 1, default); return-nil, literal-mutation,
  condition-negation (Tier 2, opt-in via `--operators`).
- Coverage-guided test selection with a digest-keyed, auto-invalidating cache.
- Fork-isolated, parallel execution (`--jobs`) with per-mutant timeouts.
- Two application strategies: `reload` (whole-file, default) and `redefine`
  (surgical), verified to agree on namespaced multi-statement methods. (`7a`/`7b`
  accepted as deprecated aliases.)
- `run`, `--dry-run`, `--threshold`, `--only`, `--operators`, `--strategy`,
  `--format human|json`, `--output`, `--list-operators`.
- `.mutineer.yml` configuration (CLI > config > default precedence).
- Byte-correct source handling for multibyte (UTF-8) sources.

[1.4.0]: https://github.com/davidteren/mutineer/releases/tag/v1.4.0
[1.3.0]: https://github.com/davidteren/mutineer/releases/tag/v1.3.0
[1.2.0]: https://github.com/davidteren/mutineer/releases/tag/v1.2.0
[1.1.0]: https://github.com/davidteren/mutineer/releases/tag/v1.1.0
[1.0.2]: https://github.com/davidteren/mutineer/releases/tag/v1.0.2
[1.0.1]: https://github.com/davidteren/mutineer/releases/tag/v1.0.1
[1.0.0]: https://github.com/davidteren/mutineer/releases/tag/v1.0.0
[0.11.4]: https://github.com/davidteren/mutineer/releases/tag/v0.11.4
[0.11.3]: https://github.com/davidteren/mutineer/releases/tag/v0.11.3
[0.11.2]: https://github.com/davidteren/mutineer/releases/tag/v0.11.2
[0.11.1]: https://github.com/davidteren/mutineer/releases/tag/v0.11.1
[0.11.0]: https://github.com/davidteren/mutineer/releases/tag/v0.11.0
[0.10.0]: https://github.com/davidteren/mutineer/releases/tag/v0.10.0
[0.9.1]: https://github.com/davidteren/mutineer/releases/tag/v0.9.1
[0.9.0]: https://github.com/davidteren/mutineer/releases/tag/v0.9.0
[0.8.0]: https://github.com/davidteren/mutineer/releases/tag/v0.8.0
[0.7.1]: https://github.com/davidteren/mutineer/releases/tag/v0.7.1
[0.7.0]: https://github.com/davidteren/mutineer/releases/tag/v0.7.0
[0.6.2]: https://github.com/davidteren/mutineer/releases/tag/v0.6.2
[0.6.1]: https://github.com/davidteren/mutineer/releases/tag/v0.6.1
[0.6.0]: https://github.com/davidteren/mutineer/releases/tag/v0.6.0
[0.5.0]: https://github.com/davidteren/mutineer/releases/tag/v0.5.0
[0.4.0]: https://github.com/davidteren/mutineer/releases/tag/v0.4.0
[0.3.0]: https://github.com/davidteren/mutineer/releases/tag/v0.3.0
[0.2.0]: https://github.com/davidteren/mutineer/releases/tag/v0.2.0
[0.1.0]: https://github.com/davidteren/mutineer/releases/tag/v0.1.0
