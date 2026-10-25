# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **The gem ships the agent skill.** `skills/mutineer/SKILL.md` is now
  packaged in the gem, and the gemspec opts in as a
  [Rails Hyperdrive](https://github.com/rails-hyperdrive/rails-hyperdrive)
  companion (`hyperdrive_targets: "*"`, `hyperdrive_artifacts: "skill"`). In a
  Rails app that bundles mutineer, `bin/rails hyperdrive:init` installs the
  skill to `.claude/skills/mutineer/SKILL.md`. A test in the default suite
  fails if the gemspec stops shipping the skill or drops the opt-in (#315).

### Fixed

- **An in-test database error scores `error`, not `killed` (#296).** When
  the first failing test of a Minitest mutant run failed with an Active
  Record connection or lock error (`ConnectionNotEstablished`, including pool
  timeouts, `ConnectionFailed`, `Deadlocked`, `LockWaitTimeout`), the mutant
  now scores `error` on `--daemon` and in-process. This includes an error in
  `setup`. Errors are out of the score, so a lost database connection during
  a run no longer raises the score. A stderr line names the error. A mutant
  that really causes a deadlock, or that breaks connection-handling code, now
  also scores `error`. More `error` verdicts can fail a `--threshold` run
  through the existing no-verdict gate. Other database errors, such as a bad
  SQL statement, still score `killed`. So does `ConnectionNotDefined`, which
  Rails 8 raises for an unknown role or shard. Rails 7.2 raises a plain
  `ConnectionNotEstablished` there, so such a mutant scores `error` on 7.2.
  With `--matrix`, a database-failed test is never a killer and leaves its
  row incomplete, even if an earlier assertion already killed the mutant.
- **An old temp file of the other mode no longer stops the boot (#287).**
  Before the app boots, each mode sweeps the source directories. In 1.7.0
  an in-process run removed only old `mutineer_mutant*.rb` files and the
  daemon removed only old `mutineer_daemon*.rb` files, so a file the other
  mode left made Zeitwerk raise. Now both boot sweeps remove an orphan of
  either mode, and the daemon tells Zeitwerk to skip both names. You no
  longer delete such a file by hand. A file of your own whose name only
  starts with `mutineer_mutant` or `mutineer_daemon`, such as
  `mutineer_mutant_helper.rb`, is no longer removed: a sweep now matches
  only the temp file shape. An unlocked old file is removed even when its
  creator's pid has been reused; a held file lock still protects it.
  Do not run Mutineer older than 1.7.0
  at the same time in the same checkout: it still writes temp files
  without the dot, and a newer run's mutants error when Zeitwerk finds
  one.
- **A second in-process run no longer deletes a live mutant file (#295).**
  Each in-process run sweeps the source directories before its boot and
  after its run. That sweep treated every `.mutineer_mutant*.rb` file as an
  orphan, so it could delete another run's file between the write and the
  load, and that mutant scored `errored`. Now the file is locked while it
  loads, as the daemon's file is, and a sweep keeps a file whose creating
  process still runs.
- **The `range` operator swaps endless ranges outside slices.** Before, it
  skipped every endless range (`1..`, `1..nil`) as equivalent. But `(1..)`
  and `(1...)` differ on `==`, `hash`, `exclude_end?` and `to_s`, so a test
  can kill that mutant. Now the operator skips an endless range only when it
  is a direct index argument of `[]`, `[]=`, `slice`, `slice!`, `byteslice`,
  `bytesplice`, `values_at` or an index write, and the receiver is not a
  class (`Array[1..]` is swapped). A Hash, Proc, or custom `[]`/`slice` can
  still tell `1..` from `1...`, so those skips can hide a killable mutant. See
  [Equivalent skips](https://davidteren.github.io/mutineer/equivalent-skips.html#endless-range).
  A run that names `range` can get new mutants, new survivors and new mutant
  ids. A new mutant can take the id of an older `range` mutant in the same
  method, so an old `ignore:` id can name a different mutant. If you use
  `range`:
  - Delete the `ignore:` entries for `range` mutants.
  - Save a new report with the same operators you gate with:
    `mutineer run <paths> --operators <list> --no-since --format json --output <file>`.
    Use it as your new baseline.
  - Print new entries with
    `mutineer triage <file> --reason TEXT (--id ID ... | --all)` and paste
    them under `ignore:`. The command does not edit files.

  Some new mutants are equivalent, for example a range used only with
  `include?`, or a range in an Active Record query such as
  `where(created_at: time..)`. Suppress them with `# mutineer:disable-line`
  or an `ignore:` entry. (#299)
- **A test file given as a source after `--test` now exits 2 in more layouts
  (#293).** The check missed Minitest `test_*.rb` files under `test/` or
  `spec/`, and `*_test.rb` or `*_spec.rb` files in the same directory as a
  `--test` file, such as the project root. Mutineer then mutated that file as
  a source and never ran it as a test. With `--format json`, the stray file's
  Minitest output also made the report invalid JSON. A support file with a
  `test_` name under the top-level `test/` or `spec/` (other than
  `test_helper.rb`) now also exits 2 when given as a source with `--test`.
- **A mutant on a later line of a call inside a one-line block can be killed
  (#289).** A call can span several lines, such as
  `users.map { |u| format("%s",` with arguments on the next lines. Mutineer
  used to pick no tests for a mutant on a later line, so it was always
  `no_coverage`. Now, when the lines of the statement give no tests, Mutineer
  retries. It runs the tests that ran the first or last line of the
  statement, never the `def` line. A kill counts. A survivor stays
  `no_coverage` (or `ran_at_load`), because those tests may not have run it. A
  score can rise with no test change. Such a mutant can now also end as
  `error` or `timeout`. That counts toward the `--threshold` completeness
  check.
- Mutineer reads its files and pipes as UTF-8 when `LANG` and `LC_ALL` are
  unset (#303). Before, a non-ASCII character in a source file, a baseline, a
  coverage cache, a triage report, `.mutineer.yml` (for `migrate`),
  `db/schema.rb`, a `--since` diff, test-command output, or a daemon message
  stopped the run with "invalid byte sequence in US-ASCII" (exit 2) or a
  backtrace (exit 1). An invalid byte in test-command output now shows as
  `\xNN`. Non-ASCII file and folder names are not covered yet (#346).
- **Upgrade note for `--test-command` with a custom failure exit code (#292).**
  An RSpec setup with `--failure-exit-code 3` now scores every kill as
  `error`. Use the default exit code, or a wrapper that maps a failure to
  exit 1. An `error` verdict leaves the score, so the score can drop, and more
  `error` verdicts can fail a `--threshold` run through the existing no-verdict
  check. A mutant that only trips a SimpleCov `minimum_coverage` gate now
  scores `survived` when the output has SimpleCov's gate message and a
  passing Minitest or RSpec summary line. Without a summary line that
  Mutineer recognizes, the gate's exit scores `error`, which leaves the
  score. Either way the old false kill is gone, so the score can drop. A `--baseline` made before
  this change can report new survivors and errors: make a new baseline after
  the upgrade.
- **A `--test-command` exit other than 1 no longer counts as a kill (#292).**
  Only exit 1 scores `killed`, the same rule as the in-process backend. One
  exception: a SimpleCov gate exit whose summary reports a failing test also
  scores `killed`. Any other non-zero exit scores `error`, such as a wrapper's
  137 after an out-of-memory kill.
- **A load crash under `--test-command` scores `error` (#292).** When the clean
  run prints a Minitest or RSpec summary line, an exit 1 also needs a failing
  test in that line. Code under test that calls `exit 1` or `abort` while the
  default Minitest reporter runs its tests still scores `killed`, as in
  process. Under RSpec or minitest-reporters, that case now scores `error`.
  When a SimpleCov `minimum_coverage` gate replaces the exit code, the summary
  line decides: a failing test is a kill, and a passing run is `survived`, as
  in process. When the clean run
  prints no summary line, Mutineer warns once and keeps the exit-code rule.

- **`--output .mutineer/run.json` on a fresh checkout.** The documented
  report path no longer exits 2 when `.mutineer/` does not exist yet. The
  output check now creates the cache directory (`cache_dir`) when it is the
  missing parent. Any other missing directory still exits 2. This is a CLI
  fix: the GitHub Action's `output` input still needs an existing directory
  (#270, #340).

- **`--output` can no longer replace its own baseline.** When `--output`
  and `--baseline` or `baseline:` in `.mutineer.yml` name the same file
  (also through a symlink or hard link), a real `mutineer run` exits 2
  before the run, with the GitHub Action's error adapted for the CLI. A dry run
  still works because it writes no report. Before, a
  failing run wrote its report over the baseline, and the next run passed
  against it (#281).

- **`--threshold` compares the exact score, not the rounded one (#280).** The
  score is rounded to one decimal for display, and the gate used to compare that
  rounded value. A run with 1999 of 2000 mutants killed showed 100.0% and passed
  `--threshold 100` with a survivor. The exit code, the Action, and the PASSED or
  FAILED line now use the exact counts. When the rounded score points the other
  way, the PASSED or FAILED line gives the counts and says that the score is
  rounded.

- **The Minitest clean check now runs the tests in the order the mutant runs
  use (#282).** Since 1.1.0, each mutant run used seed `1`, but coverage
  capture, the clean checks and the `--daemon` mutant runs used a random
  seed. An order-dependent suite could pass the clean check and then fail in
  every mutant run, so each mutant scored a false `killed`. Every Minitest
  run that Mutineer starts itself (not `--test-command`, see #338) now uses seed `1`,
  or `SEED` when the environment sets it. Such a suite now stops the run
  with "the unmutated suite is not green". The message names the configured
  seed or default and notes that test helpers can change it. Capture, clean
  checks and mutant runs all read `SEED` after loading the tests and helpers.
  Check the listed test files with the same seed and helpers to investigate
  the order-dependent test. A coverage cache from another
  `SEED` in Mutineer's environment or an older version is captured again. A
  `--coverage-from` capture from another `SEED` or an older version is
  rejected with exit 2: capture it again with this version. The internal constant
  `MinitestIntegration::STOP_AT_FIRST_FAILURE_SEED` is now `PINNED_SEED`.
  One gap stays: when a mutant runs several covering test files, their test
  classes can still run in a different order than in the combined clean
  check. RSpec does not change.

- **`--daemon` SQLite workers load the schema file the app names (#317).**
  The daemon always loaded `db/schema.rb` over an out-of-date worker copy,
  even when `config/database.yml` sets `schema_dump:` to another file. An
  app that keeps its SQLite schema in `db/schema_sqlite.rb` beside a MySQL
  `db/schema.rb` errored every mutant. The booted daemon now asks Rails for
  the file: `SCHEMA` when it is set, else `schema_dump:`, else
  `db/schema.rb`. With `structure.sql`, a missing file, or
  `schema_dump: false` (unless `SCHEMA` is set) it loads no schema, even
  when a `db/schema.rb` exists: the worker keeps its copy of the test
  database. A Postgres worker is a copy of the test database, so it was not
  affected. MySQL already asked Rails for the file. It now also reads the
  database's own `schema_format:` (Rails 8.1) and a string format such as
  `"sql"`, the same as SQLite.

- **`--strategy redefine` and path-relative methods.** Redefine now loads
  the mutated method from a hidden file beside the source, as reload does.
  It used the system temp directory before, so `__dir__` and
  `require_relative` in the method pointed there, and every mutant of such
  a method was falsely killed (#279). Redefine is also the default under
  `--rails` without `--daemon`. When a source directory is not writable,
  redefine still uses the system temp directory there, as before, and
  the run warns that path-relative methods there can be falsely killed
  (tracked in #339).

- `--test-command` now sets `DISABLE_BOOTSNAP_COMPILE_CACHE=1` for the test
  command. Mutineer writes each mutant over the source file, and Bootsnap keys
  its compile cache on path, size and whole-second mtime. Two same-size mutants
  written in the same second could load the first one's cached code, so a
  mutant could be scored on code that was not the mutant. Each mutant boot now
  compiles the app again, which is slower. The variable works through
  `require "bootsnap/setup"` on Bootsnap 1.7.0 or later; an app that calls
  `Bootsnap.setup` itself must pass
  `compile_cache_iseq: ENV["DISABLE_BOOTSNAP_COMPILE_CACHE"].nil?`, so only
  mutant runs lose the cache. The `--daemon` path is unchanged (#285).

- **A nested method's mutant under `--strategy redefine`.** Redefine now
  also loads the mutated method into each method that encloses it. Before,
  a call to the outer method defined the original inner method again, so
  the mutant could falsely survive (#290). For a method nested in other
  methods, redefine now gives the same verdict as reload when a test calls
  an enclosing method by its own name. Mutant ids do not change, so
  baselines and `ignore:` entries stay valid. Scores under redefine can
  rise, and an `ignore:` entry added only to hide such a survivor can now
  be removed. A method defined inside a non-builder block (for example
  inside `define_method`), inside a `module_function` method, inside
  `class << self` in a method, or called through an alias of the outer
  method can still falsely survive under redefine. An enclosing method
  that a memoizer or decorator wraps after its `def` loses that wrapper
  when redefine loads it, so its verdict can differ from reload. Use
  `--strategy reload` for those cases.

### Changed

- **`call_to_receiver` now mutates last-call conversions such as `to_s` and
  `to_i`.** `m[1].to_i` now gives the mutant `m[1]`. Before, the operator skipped the
  same names as `chain_link`. Now it skips only `new`, `dup`, `clone`,
  `freeze`, `itself` and `to_set`. `chain_link` does not change. Only runs
  that list `call_to_receiver` in `--operators` (or `operators:`) change: they
  get more mutants (113 more on Mutineer's own `lib/`). If you gate such a run
  with `--threshold` or `--baseline`, expect new survivors: write a new
  full-scope baseline with `mutineer run ... --no-since --no-fail-fast
  --format json`, with no `--only`. A `to_s` mutant on a value that is already
  a String is equivalent: suppress it with
  `# mutineer:disable-line call_to_receiver` or an `ignore:` entry. (#274)
- Explain mutation testing before setup, with a runnable beginner guide and a
  first run on one file. Simplify wording across the website and clarify Rails
  setup, CI baselines, and reasons for ignoring a mutant.

## [1.7.0] - 2026-10-23

### Added

- **Call-to-receiver operator** (Tier-2, opt-in via `--operators`):
  `call_to_receiver` replaces the last call of a chain with its receiver, with
  the arguments and block of that call (`user.full_name` -> `user`). The mutant
  survives when no test checks what that last call does. It does not overlap
  with `chain_link`: `chain_link` drops a call in the middle of a chain, and
  `call_to_receiver` drops only the last call. The two give the same source
  only when the last call repeats the call before it (`node.name.name`). It
  skips the same names as `chain_link`, and it skips operator calls and
  setters.
- **Reasons on ignored mutants.** Text after `--` on
  `# mutineer:disable-line`, and a `.mutineer.yml` `ignore:` mapping
  (`id` plus `reason`), is stored on the ignored mutant. The JSON report
  (`schema_version` 1.8) and the HTML report show it. A mapping with no
  `id`, or with an unknown key, warns. Mutineer 1.7 is the first version
  that reads a mapping. An older version matches no mutant to a mapping
  and does not warn, so the mutant it names is not ignored. Upgrade
  every gate that reads the file before you add a mapping.
  `mutineer migrate` rewrites the old id inside a mapping and keeps its
  reason.
- **`mutineer triage`.** It prints `ignore:` mapping entries for survivors
  in a JSON report. `--reason` is required. Pass `--all` or `--id`. It
  does not edit files.
- **Equivalent-skip page.** The docs list every built-in chain-link skip
  and the endless-range skip, and why each one is equivalent.
- **Postgres worker databases for `--rails --daemon`.** Each worker gets
  `<base>-mutineer-<N>`, copied from the test database before mutants run.
  A second run cannot drop a database another live run holds. An app with
  more than one database config runs one worker and says so once.
  The worker databases stay after the run.
- **MySQL 8 worker databases for Minitest on `--rails --daemon`.** Each worker gets
  `<base>-mutineer-<N>` on `mysql2` or `trilogy`, with the base shortened to fit
  MySQL's 64-byte name limit. Mutineer creates the
  database, loads `schema.rb` or `structure.sql`, and copies rows once at
  the start. Triggers from the schema do not fire on the copied rows.
  Mutineer creates them again after the copy.
  A second run cannot drop a database another live run holds.
  That work uses the TLS and timeout settings from the database config.
  MariaDB is not tested. MySQL 5.7 is not supported. The worker databases
  stay after the run.
- **`mutineer migrate`.** It rewrites old-format ids in `.mutineer.yml`
  `ignore:` to the current ids. It keeps comments and every other line.
  One old id that matches several mutants becomes every new id. An id that
  matches nothing stays, and the command exits 1. A block scalar under
  `ignore:` is not supported: the command exits 2 and does not change the
  file. `--dry-run` prints each change and writes nothing. It does not
  rewrite a baseline. Generate a new baseline with `--format json`. An
  old-id warning names `mutineer migrate` and says that this becomes an
  error in Mutineer 2.0. The baseline warning says to generate a new
  baseline with `--format json`.
- **`mutineer init`.** It writes a commented `.mutineer.yml` with the default
  operators. `since` stays commented, so the first run is a full scan.
  `init --rails` also sets `rails: true` and prints the first run command.
  An existing file is kept unless you pass `--force`.
- **Rails rollout guide.** The page walks from one model, to a report-only CI
  job, to a `--since` and `--baseline` pull request gate, to `--threshold`
  on chosen folders. It has a GitHub Actions recipe and a GitLab CI recipe.
- **A mutation-testing primer in the README.** "What is mutation testing?"
  walks through one small example, from a surviving mutant to the test that
  kills it, and says what each report row means and what to do with a
  survivor. The usage block lists all four commands.
- **A production-ready section and a stability contract.** The README opens
  with a support matrix for Ruby, database, framework, and parallelism.
  `STABILITY.md` lists what a release keeps and what 2.0 will change.
  `SECURITY.md`, `CONTRIBUTING.md`, and GitHub issue forms are new.
  The docs home page takes the same section from the README at site build.
- **`--allow-empty` and `allow_empty:`.** A run with no mutants now warns
  that Mutineer 2.0 will fail it, unless `--allow-empty` marks it as expected.
  A `--since` run whose changes hold no mutants does not warn: it says the
  changes hold nothing to test. A `--since` run with no mutants even before
  scoping still warns. The exit code does not change in 1.x.
- **`--no-daemon`.** It beats a `.mutineer.yml` `daemon: true` for one run,
  like `--no-fail-fast`. A Minitest `--rails` run without a `daemon` value now
  prints a notice that 2.0 uses `--daemon` by default for `--rails`;
  `--no-daemon` (or `daemon: false`) keeps the run serial and stops the
  notice.
- **"Did you mean" hints.** Unknown names in `--operators`, in
  `.mutineer.yml` `operators:` and keys, and in `# mutineer:disable-line`
  markers get the closest valid name. The `.mutineer.yml` warnings also say
  that 2.0 makes them errors.
- **`--coverage-from FILE` lets parallel shards share one coverage capture.**
  A `--rails`/`--boot` run reads the `coverage.json` of an earlier run with
  the same tests over these sources or more. It skips the capture. Each test
  that covers one of its sources still runs alone, as on a cache hit, because
  a mutant runs only those tests. A test that covers none of them does not,
  so a shard runs far fewer tests alone than a full suite. All tests then run
  once together, and the run saves its own cache.
  Boot-mode caches now also record each source's fingerprint, the ownership
  list and a digest of the other inputs. A capture that does not fit is an
  error (exit 2), never a silent recapture. So is one where loading its other
  sources ran these sources' code, which happens under lazy loading with
  `--strategy redefine`. Without boot mode, and with `--daemon`,
  `--test-command` or `--dry-run`, the flag warns that it has no effect.

### Changed

- **Rails test workers stay off during a mutant run.** Mutineer sets
  `PARALLEL_WORKERS` to `1` for in-process, `--daemon`, and `--test-command`
  runs. A value you already set is replaced, and Mutineer prints one line.
  The coverage cache stores the `PARALLEL_WORKERS` value, so a cache from an
  older version rebuilds once. `--test-command` also sets `DISABLE_SPRING=1`.
  The README explains `parallelize`, Bootsnap, and Redis after a fork.
- **`--test-command` exit codes 126 and 127 are scored `error`, not
  `killed`.** A wrapper that could not start the suite ran no test. Under
  `--threshold`, such a run can now score lower or fail the no-verdict limit,
  where before it passed on false kills.
- **A run with errored mutants and no `--threshold` says so.** Errors are not
  in the score, so they do not fail the run; the message says what
  `--threshold` would enforce.
- **`--since` also narrows suppressed mutants.** A scoped report lists only
  `ignored` mutants on changed lines, as `--dry-run --since` already did.
- **The empty-run message moved from the human report to one stderr warning
  for every format.** "No mutations generated" is gone. An empty `--since`
  run prints "nothing to test in the changes since REF" instead.

### Fixed

- **Daemon errors no longer show the database password.** Rails parses
  `DATABASE_URL` itself, and a malformed URL makes it raise an error that
  quotes the whole URL. The daemon sent that error to the terminal when
  the app failed to boot, and the same could happen when it set up worker
  databases or the coverage map, and in a `--verbose` coverage warning.
  Mutineer now replaces the password in any URL, and the `DATABASE_URL`
  password anywhere else (escaped or cut short included), with
  `[REDACTED]` before it reports the error.
- **`--strategy reload` runs concern files with an `included` or `prepended`
  block (#256).** Every mutant in such a file was `errored`: ActiveSupport
  raised `MultipleIncludedBlocks` (or `MultiplePrependBlocks`) because the
  mutant loads from a temp file with another path. Before each reload mutant
  loads, in-process and on the daemon, the forked child now forgets the blocks
  that the source file stored, so methods in the concern body and in
  `class_methods` are killed or survive as usual. A block the mutant's load
  does not store again (a concern under an `unless defined?` guard) is put
  back. A method inside an
  `included` or `prepended` block is `unplaceable` under reload too: the block
  does not run again in a class that already includes or prepends the
  concern, so the mutant would falsely survive. That includes a method of a
  class defined inside the block. Use `--test-command` to run those mutants.
- **No heredoc opener without its body.** A mutation that kept a heredoc
  opener but replaced the lines of its body gave source that does not parse,
  such as `operand_removal` on `foo(<<~EOS) ||` with the body and `bar` on
  the next lines. The mutant showed only as `skipped (invalid)`. Now the
  operator does not emit it.
- **An RSpec run that fails only on an error outside examples scores the
  mutant `errored`, not `killed`.** A spec file that raised while loading, or
  a failing `before(:suite)` hook, made RSpec exit 1, and every mutant was
  scored `killed`. On a Rails app, `rails_helper` called `SimpleCov.start`
  after `--rails` had suspended Coverage (#228), so each spec file raised as
  it loaded, and 18 of 18 mutants were scored `killed`; 3 of them survive.
  Now the runner returns 2 when RSpec recorded an error outside examples and
  no example failed, so the mutant is `errored`: out of the score and in
  `no_verdict`, so that run now fails `--threshold` instead of passing at
  100%. A failed example still kills.
  Minitest and `--daemon` already score a test file that raises at load as
  `errored`. `--test-command` sees only the exit status and still scores it
  `killed`.
- **A Rails daemon boots again while a mutant file is still open.**
  The file stays when another process holds it. The next boot skips
  that file name instead of stopping.
- **A daemon crash no longer leaves a mutant file in your source folder
  (#250).** When a daemon dies during a mutant, its child dies a moment
  later. The new daemon cleaned up before that, so the child's file stayed.
  The next Rails boot then failed on the file name. Each daemon run now
  cleans up again when it ends or stops early. It waits up to 1.5 seconds
  for the child to go. A file whose owner still runs after that stays
  until the next daemon run removes it. On Linux, a file whose owner is a
  zombie (in a container whose pid 1 does not reap it) is now removed.
  With `--jobs N`, an error in one worker stops the others after their
  current mutant, and a Ctrl-C quits every worker daemon before the run
  ends.
- **SimpleCov in a test helper no longer breaks every mutant under
  `--rails` or `--boot` (#248).** After the coverage map is built, mutineer
  pauses Ruby's coverage (#228). SimpleCov saw the paused coverage as off and
  tried to start it. Ruby refuses that while coverage is paused, so the test
  helper raised in every mutant. Now a start in a mutant first stops the
  paused coverage. A mutant whose tests start nothing keeps it paused and pays
  nothing. This applies to `--daemon` too.
- **Methods in an ActiveSupport::Concern `class_methods` block are mutated
  under `--strategy redefine` (#252).** ActiveSupport puts these methods in
  the concern's `ClassMethods` module, and each includer gets them as class
  methods. Mutineer named them as instance methods of the concern itself.
  Redefine (the `--rails` default) then loaded each mutant onto the concern.
  The tests called the includer's method, so every mutant falsely survived.
  A concern with an instance method of the same name failed the other way:
  the mutant replaced that instance method, so tests calling it ran the
  wrong method and failed (an ArgumentError, when the arities differ), and
  the mutant counted as killed whatever it changed. Both false survivors
  and false kills are gone. An earlier redefine score is unreliable for
  any file with a `class_methods` block: too low from false survivors, or
  too high from false kills. Re-run those files.
  These methods are now named `Concern::ClassMethods#name`, and redefine
  loads the mutant onto that module. This applies to a module that ran
  `extend ActiveSupport::Concern` earlier in the same file. The mutant ids of
  these methods change, because an id contains the qualified name (owner and
  method). An instance
  method with the same name, later in the same file, can get a new id too.
  An `ignore:` entry or a `--baseline` survivor for one of these methods no
  longer matches. Replace it with the new id from a new run.
- **Methods in other `class_methods`, `included` and `prepended` blocks are
  `unplaceable` under `--strategy redefine` (#252).** ActiveSupport runs an
  `included` or `prepended` block in each includer, so no constant names the
  class that owns its methods. A `class_methods` block that Mutineer cannot
  tie to a concern has the same problem: one in a def, in Rails'
  `concerning`, in an unassigned `Module.new`, or in a module that does not
  run `extend ActiveSupport::Concern` earlier in the file. Redefine loaded each
  mutant onto the enclosing module, and the mutant could falsely survive. Now
  redefine reports these mutants as `unplaceable` and does not run them. Like
  every `unplaceable` mutant, they leave the score and do not count toward
  `--threshold`, so a gate that failed on these false survivors can now pass.
  Their names and mutant ids do not change. `--strategy reload` runs them, except a
  method in an `included` or `prepended` block (see #256 above). Another library's
  method with one of these names is `unplaceable` under redefine too, even
  when that library runs the block in the module itself and redefine used to
  run it correctly. Mutineer cannot tell that library from ActiveSupport, so it
  does not guess. For that other library's mutants, use `--strategy reload`.
- **A file in a namespace directory scores under `--rails --strategy reload`
  and `--rails --daemon` (#253).** Mutineer writes each mutant to a temp file
  next to the source and loads it. With lazy loading, loading it can be the
  first time Zeitwerk scans that directory, such as `app/models/billing/`.
  Zeitwerk then raised `Zeitwerk::NameError` on the temp file's name, and the
  mutants of the file errored. Parallel daemon workers hit the same error on
  each other's files. Now the temp files are hidden: `.mutineer_mutant*.rb`
  and `.mutineer_daemon*.rb`. Zeitwerk skips hidden files, in every loader.
  The cleanup sweeps still remove a file an older version left without the
  dot. Each mode sweeps its own files before the app boots: an in-process run
  now removes an old `mutineer_mutant*.rb` first, and the daemon removes an
  old `mutineer_daemon*.rb`. An old file of the other mode still stops the
  boot, so delete it by hand. Eager loading, the default on CI, scans every
  directory at boot, so it never hit the error.
- **A mutant on a later line of a multi-line `&&` or `||` can be killed
  (#254).** Ruby counts only the first line of a statement. For code that runs
  only sometimes on a later line, such as the right side of `verified &&` on
  its own line, Mutineer picked no tests, so the mutant was always
  `no_coverage`, however good the tests were. Now it runs the tests that ran
  the statement. A kill counts. A survivor stays `no_coverage`, because the
  run cannot tell whether those tests reached it, so no survivor is added and
  a score can rise with no test change. Such a mutant can now also end as
  `errored` or `timeout`; like any mutant with no verdict, that counts toward
  the `--threshold` completeness check, so a failure is reported, not hidden.
  This also applies to a later `when` condition, the value of `x rescue y`,
  `&.` arguments and an `||=` value on a later line, and to `--daemon`. A
  branch of a ternary or `if`, and the body of `x if c`, keep the verdict they
  had before.

## [1.6.0] - 2026-10-08

### Added

- **An `unplaceable` mutant status.** Under `--strategy redefine`, a mutant in
  a method whose class or module has no constant name is not run. It is left
  out of the score and, unlike `uncapturable`, out of `no_verdict`, so it does
  not fail `--threshold`. The human report gives it an `Unplaceable:` row, the
  HTML report a count, and the JSON report `summary.unplaceable` and an
  `unplaceable[]` list; `schema_version` is `1.7`.
- **The agent skill installs with `gh skill` and `npx skills` (#125).** It
  moved from `docs/skill.md` to `skills/mutineer/SKILL.md`, the layout of the
  Agent Skills specification, so `gh skill install davidteren/mutineer
  mutineer` finds it and `npx skills add davidteren/mutineer --skill mutineer`
  installs one `SKILL.md` instead of the whole `docs/` site. The site build
  copies that file to `skill.md`, so its URL still works. The skill's
  description now says when to use it, and the README shows how to install it.
- **A `ran_at_load` mutant status** (#187). A mutant on a method-body line
  that ran while the app booted or its class loaded gets this status when it
  survives, or when only the load ran the line. A kill stays a kill. It is
  left out of the score and out of `no_verdict`, so it does not fail
  `--threshold`. The human report gives it a `Ran at load:` row that points
  to `--test-command` to verify these mutants, the HTML report a count, and
  the JSON report `summary.ran_at_load` and a `ran_at_load[]` list, within
  schema `1.7`.

### Changed

- **Mutants no longer run under Coverage with `--boot` or `--rails` (#228).** Coverage
  starts before the app boots so the coverage map can be built, and it used to
  keep running in every mutant fork after that, though nothing read it. It is
  now suspended once the map is built, from a fresh capture or from the cache.
  Coverage that a host process started before the run is left running.
  On a small app whose test calls tiny methods in a loop, the CPU time of a
  whole in-process `--boot` run fell from 0.76s to 0.57s (median of five). On
  the Rails fixture app the run is mostly boot, and the change is within noise
  (1.61s before, 1.60s after). `--daemon` runs its mutants in worker daemons
  that never start Coverage, so its time does not change (3.48s before, 3.44s
  after); the map-building daemon now suspends Coverage after the map too.
- **A mutant runs its paired test files first, then the cheapest (#203).** The
  covering test files used to run in the order the coverage map stored them,
  so a mutant that one fast file kills could still score `timeout` when slow
  files ran first. Now the files that pairing finds for the source run first,
  then the rest from fastest to slowest by the time each file took during
  coverage capture, less the fastest file's time (the startup cost each
  capture pays). The order is fixed for a given cache. Costs compare in
  doubling buckets, so files of close cost keep their path order when a
  rebuilt cache measures them again; a file near a bucket edge can still move,
  so keep `.mutineer/` between CI runs for the most stable `--baseline`. The
  order applies to Minitest (after the seeded class shuffle, with
  `parallelize_me!` classes still last) and to RSpec. `--daemon` runs every
  covering test with no stop, so the order does not change its verdicts. The
  coverage cache now saves these timings, so a cache from an earlier version
  rebuilds once. A complete run gives the same verdicts and `--matrix` rows,
  but the new order can change which mutants time out, so a `--baseline` gate
  can see a one-time change on upgrade.
- **Job selection moved from `Mutineer::Runner` to a new `Mutineer::JobPlan`
  module (#75).** The in-process runner, the `--daemon` backend and
  `--dry-run` share it, so each file now requires what it uses and no
  `require_relative` cycle exists in `lib/mutineer`. The moved methods are
  `collect_jobs`, `filter_since`, `coverage_selection`, `ran_at_load?`,
  `load_verdict`, `abort_if_unclean!`, `test_load_roots`, `source_dirs`,
  `sweep_orphans`, `suppress_map`, `suppressed?` and `result_keys`. These were
  internal methods, so `Runner` keeps no copies. Runs, reports and caches do
  not change.

### Fixed

- **An endless method that only the tests call is no longer `no_coverage`
  under `--rails`, `--boot` or `--daemon` (#209).** Ruby counts no line when
  an endless method such as `def half(x) = x / 2` runs, only its `def` line
  when it is defined. The boot defines it before any test runs, so the forked
  coverage capture never saw that line run. Coverage now also
  counts methods (`Coverage.start(lines: true, methods: true)`), and a test
  that calls such a method covers its `def` line. Coverage caches from earlier
  versions rebuild once.
- **`module_function :name` in a reopened module inside `class << self`
  promotes the method from the earlier opening (#216).** Ruby treats both
  openings as one module, but Mutineer matched them only within one body, so
  it named the method `#<Class:App>::M#c` instead of `#<Class:App>::M.c`.
  The two openings now match by the module's full name. A module whose name
  Mutineer cannot be sure of still matches only within its own body: a path
  such as `self::X` or `Foo::X` written directly inside `class << self`, a
  name under an anonymous class, or a module in a `class << self` inside a
  method or a `class_eval` block. A `module self::X` in a block, or a
  `self::X = ...` in a `class_eval` block, matches only openings in the same
  block. A `self::X` like these now also stays apart from a
  module of the same name outside `class << self`, where a `module_function`
  in that module used to promote its methods.
- **A `module self::X` or `class self::X` in a block is `unplaceable` under
  `--strategy redefine` (#229).** In a block, `self` is not always the
  enclosing class: in `Other.class_eval do` it is `Other`, and in
  `Foo = Class.new do` it is the new class. Mutineer gave these modules a
  known owner on the enclosing namespace, so redefine loaded the mutant onto
  a module the tests never use, and the mutant could falsely survive or
  score `error`. Such a module, everything nested in it, and a
  `self::X = ...` in a block that does not build a class now have
  their owner unknown: redefine reports their mutants as `unplaceable`, and
  `--strategy reload` still runs them. In a `Data.define`, `Struct.new`,
  `Class.new` or `Module.new` block, the module is now named under the
  builder's constant (`Outer::Foo::X#c`, was `Outer::X#c`), so the subject
  names and mutant ids of those methods change. `self::X` directly in a class
  or module body is unchanged.

- **`--daemon` worker databases start as a copy of the test database
  (#222).** Each worker slot's SQLite database used to start from
  `db/schema.rb` alone. Rows the daemon wrote while it booted, in
  initializers or `--require` files, were only in the base test database, so
  a test that read them passed in-process but failed under `--daemon`. On its
  first use, a worker database is now a copy of the base test database (schema
  and rows, made with the SQLite online backup API). The worker still loads
  `db/schema.rb` when the copy's schema differs from it (another schema
  version, or another or no `schema_sha1` checksum in `ar_internal_metadata`),
  for example when the test database is empty, out of date, or set up with a
  plain `load "db/schema.rb"`. That load drops the
  copied rows of the tables it defines.
- **Standalone coverage capture loads the `--require` files (#217).** A run
  without `--boot` requires the sources and then each `--require` (or
  `require:`) file before it forks the mutants, but the coverage capture
  loaded only the sources. A source method that a `--require` file called
  while it loaded was then not seen as run at load, so its mutant was a false
  `survived` instead of `ran_at_load`. The capture and the clean-suite check
  now load the `--require` files after the sources. With or without
  `--boot`, the coverage cache rebuilds when one of them changes, is added,
  is removed, or moves in the load order.
- **`--daemon` loads the `--require` files (#220).** The daemon booted the app
  but never loaded the `--require` (or `require:`) files, so a test that
  needs one failed under `--daemon` and passed in-process. A source method
  that such a file called while it loaded was also not seen as run at load,
  so its mutant could be a false `survived` instead of `ran_at_load`. The
  daemon now loads the files after the app boots, as an in-process run does,
  and the daemon's coverage cache rebuilds when one of them changes.
- **The release workflow publishes only stable tags** (#161). Its trigger,
  `v*.*.*`, also matches a prerelease tag such as `v1.3.1-rc1`, and the only
  guard checked that the tag matched `Mutineer::VERSION`. A prerelease tag
  could then publish the gem and move the floating major tag (`v1`) that
  Action users pin. The workflow now stops with a clear error before any
  publish step unless the tag is a stable `vMAJOR.MINOR.PATCH`.
- **Coverage capture keeps to `capture_timeout` from start to finish.** Under
  `--boot` and `--daemon`, a hung test file ignored the timeout and blocked
  the run; it is now skipped as "timed out", like a standalone capture. A
  process that a test started and left running could keep the result pipe
  open and make a boot-mode capture wait for it to exit. Each capture now runs
  in its own process group, and a timeout stops the whole group, not only the
  test process. A capture whose test finished just before the deadline could
  also lose its valid result and report "invalid coverage output"; it now
  gets a short grace period to read the result. (#101, #129)
- **`--daemon` no longer waits forever on a daemon that stops answering**
  (#101). A mutant whose verdict has not arrived 30 seconds after its own
  timeout is scored `error`, and the daemon is killed and respawned, as after
  a crash. A boot that has not finished after 600 seconds ends the run with a
  message that says so (it is not retried by a second daemon), and shutdown no longer waits on a stuck daemon.

- **A method in a `Data.define`, `Struct.new`, `Class.new` or `Module.new`
  block belongs to the class or module the block builds.** In
  `class App; Argo = Data.define(:url) do def self.load = ...; end; end` the
  subject is now `App::Argo.load`, not `App.load`; at the top level it was
  `.load`, with no owner. Under `--strategy redefine` (the `--rails` default)
  the mutated method was loaded into the wrong class, so the real method never
  changed and every such mutant falsely survived. The class or module is
  named after the constant it is assigned to with `=`, `||=` or `&&=`, through
  parentheses or `begin`, resolved as Ruby resolves the assignment: `X` in the
  current namespace, `::X` and any path at the top level from `Object`,
  `self::X` under the current class. When it cannot be named statically (no
  constant, a relative path such as `User::Permission` inside a namespace, or
  a constant assigned in `class << self`), redefine reports its mutants with
  a new status, `unplaceable`, rather than load them onto the wrong class;
  reload still runs them. `module_function :name` in a `Module.new` block
  promotes that module's method. Mutant ids for these subjects change:
  regenerate `ignore:` entries and baselines that name them.
- **The automated release PR gets its required CI checks without a token
  secret (#85).** `release-pr.yml` pushes the release branch with the default
  `GITHUB_TOKEN`, which starts no other workflow, so the four required checks
  never ran and the PR stayed blocked until a person closed and reopened it.
  The job now dispatches `ci.yml` on the release branch (CI gained a
  `workflow_dispatch` trigger), and those runs report the required checks on
  the PR's head commit. With a `RELEASE_PR_TOKEN` secret set, the push
  triggers CI as before and no dispatch is made.
- **Code that runs while the app boots or a class loads no longer gives a false
  `survived` or `no_coverage`** (#187). A class body such as
  `ALL = [price(3)].freeze` runs `price` before any mutant is applied. Under
  `--strategy redefine` (the `--rails` default) the load never runs again, so
  a test that checks `ALL` saw the original value and the mutant falsely
  survived. Under `--rails` or `--boot` no test was credited with lines that
  ran during boot, so those mutants were falsely `no_coverage`. Mutineer now
  reads the lines that ran at load (from the boot, or from requiring the
  sources in standalone capture) and reports these mutants as `ran_at_load`,
  under both strategies and with `--daemon`: reload runs the file's class body
  again but not an initializer or another file's code, so a survivor there is
  not trusted either. Under `--boot` with redefine, a
  lazily loaded class (Zeitwerk, `autoload`) is loaded before the boot lines
  are read, so its class body counts as load too. A baseline survivor that is
  now `ran_at_load` is listed as fixed, not as a regression. Standalone
  coverage caches from earlier versions rebuild once. A one-line or endless
  `def` keeps its body on the `def` line, which Ruby counts when the method is
  defined, so Mutineer reads the method's call count at load for it instead
  (#209).
- **A boot file that prints to stdout no longer breaks the daemon handshake
  (#102).** Output from `puts`, `STDOUT`, `$stdout`, a direct fd 1 write, or a
  subprocess reached the JSON channel before the ready message, so the daemon
  failed with "daemon exited before the handshake". The daemon now keeps a
  private copy of its original stdout for the protocol and points the app's
  stdout at stderr, where that output stays visible.
- **A class or module opened inside `class << self` belongs to the singleton
  class (#208).** In `class App; class << self; class Q; def q1 ...` the
  subject was `App::Q.q1`, a class method of a constant Ruby never defines:
  `Q` is `App.singleton_class::Q`, and `q1` is an instance method. It is now
  `#<Class:App>::Q#q1` with no known owner, as is a class or module opened in
  a builder block there, and anything nested in either. Inside a builder
  block, `class << self` opens the built class's singleton class, so a class
  or constant there is named under it, for example `#<Class:App::P>::W`. Under
  `--strategy redefine` loading the mutant raised `NameError` and scored
  `error`; redefine now reports these mutants as `unplaceable`, and reload
  still runs them. A compact `class Foo::X` and a top-level `class ::X` or
  `::X = Class.new do` there are named as written (`::X` as `X`, now with
  instance methods) and are owner-unknown too: redefine reopens them without
  the singleton class, so constants their bodies look up through it would not
  resolve. `module_function :name` in a body whose owner is unknown now
  promotes that body's own methods, wherever it is: a `Foo::X = Module.new`
  block's `c` is `Foo::X.c`, not `Foo::X#c`, and a def in an anonymous
  `Class.new` block is no longer promoted by a `module_function` of the module
  around it. Mutant ids for these subjects change: regenerate `ignore:`
  entries and baselines that name them.

## [1.5.0] - 2026-10-06

### Added
- **`--timeout SECONDS` and `--capture-timeout SECONDS`**, also `timeout:` and
  `capture_timeout:` in `.mutineer.yml`. They set the in-process per-mutant
  time limit (default 10s) and the coverage-capture time limit (default 120s),
  which were fixed. On a large Rails suite the clean run of the unmutated
  tests took longer than 120s, so every run that offered the whole suite
  stopped as not green, and a mutant on a line many tests cover took longer
  than 10s and was scored `timeout`. `--daemon` keeps its own per-mutant
  limit but uses `--capture-timeout` for its coverage capture;
  `--test-command` uses neither. Either backend warns about a limit it was
  given and does not use.
- **`--cache-dir DIR`**, also `cache_dir:` in `.mutineer.yml`, sets where the
  coverage cache is written (default `.mutineer`, as before). Two runs from the
  same project root shared `.mutineer/coverage.json` and could overwrite each
  other's map; each can now have its own directory. `--daemon` uses it too.
  A blank value (an unset CI variable) exits 2 rather than writing the cache
  into the project root.
- **The README states how timeouts affect the score** (#62): a timed-out
  mutant is left out of the score, and counts as a mutant with no verdict
  under `--threshold`.
- **`--matrix` reports which tests kill each mutant** (`matrix: true` in
  `.mutineer.yml`). Each mutant runs every test in its covering files instead
  of stopping at the first failure, and the child sends each test's outcome to
  the parent as it is recorded. The report names blind tests, which ran in a
  complete row and killed no mutant, and redundant tests, whose every kill
  another test also makes. Redundancy is judged one test at a time, so delete
  redundant tests one at a time. The human report lists up to 20 of each, the
  HTML report all of them, and the JSON report moves to schema `1.5` with a
  `matrix` block that appears only with the flag. A test is its file and its
  id (the example id under RSpec), so examples that share a description stay
  apart and an example whose generated description changes with the mutant
  stays one test. Verdicts, the score and the exit code do not change: each
  mutant gets the verdict a run without the flag gives. After a serial test
  fails, an exit, a crash or the timeout in a later test, class or group
  leaves it `killed`; an end in the code that run still reaches (the failing
  test's class wrapper or group hooks, the suite's own cleanup) and a failure
  in a `parallelize_me!` class keep the exit status. A row is complete only
  when the child's stream arrived in order and every test reported (under
  Minitest the recorder saw every test, under RSpec every planned example),
  so a caught `Interrupt` leaves it incomplete. The human report names up
  to 20 incomplete rows and the HTML and JSON reports all of them; the human
  and HTML reports warn not to delete a blind test until its rows are
  complete.
  Minitest and RSpec 3.3+ are supported, on the in-process backend only;
  `--daemon`, `--test-command`, `--fail-fast` and `--dry-run` exit 2 with it.
  `--no-matrix` and `--no-fail-fast` beat the matching `.mutineer.yml` key,
  so a file that sets one can still run with a flag that conflicts with it.
- **`no_coverage[]` and `uncapturable[]` name each mutant.** Every entry in
  the JSON report now has `operator`, `token` and `id`, as `ignored[]` has, so
  mutants on one line can be told apart and an `id` can go in `ignore:`. The
  entries are sorted by `(file, line, operator, id)`. `schema_version` is `1.6`.

- **The site and README explain "clean-room" and compare Mutineer with
  Mutant**, and the landing page hero has a one-minute explainer video. It
  plays at 55% volume while in view (not with reduced motion; muted until
  the first click or key where the browser requires it), pauses when it scrolls
  away or the tab is hidden, and has an Enlarge button.

### Changed
- **The human report has a `Timeout:` row**, and the score line lists timeouts
  apart from errored mutants. Before, the `Errored:` row and the score line
  added the two together, while the JSON report kept them apart. The HTML
  summary now shows a `timeout` count apart from `errored` too.
- **A test file given as a source after `--test` exits 2.** `--test` takes one
  file, so in `mutineer run app/x.rb --test spec/a_spec.rb spec/b_spec.rb` the
  second spec became a source to mutate, and the run tested with one spec file
  without a word. Now a source named `*_test.rb` or `*_spec.rb` inside a
  `test/` or `spec/` directory, given with `--test`, is a usage error that says
  to repeat `--test`. The usage line now reads `--test <test> [--test <test>...]`.

### Fixed
- **The RSpec runner keeps what gems configured before the run.** It called
  `RSpec.reset`, which drops the whole configuration. Under `rails: true`, a
  `--boot` file or `require:`, the app's gems load first, so a setting such as
  rspec-retry's `verbose_retry` was gone, and a support file that set it
  raised `NoMethodError`. The run stopped with "the unmutated suite is not
  green". The runner now calls `RSpec.clear_examples`, which keeps the
  configuration. Hooks that gems added now apply too: an example with
  rspec-retry's `retry: 3` runs up to 3 times per mutant, as under `rspec`.
- **`--since` no longer scores a file that Git ignores** (#168). A file
  outside the index is scored in full, so a new file is not missed. That
  check also caught files that Git ignores on purpose (`.gitignore`,
  `.git/info/exclude` or the global excludes file), such as generated code
  inside a directory run. Those files now get no mutants under `--since`,
  and a warning names each one. Other untracked files are still scored in
  full, and so is a file when Git cannot tell, such as one beyond a symlink or
  inside a submodule.
- **The human report escapes control characters from the source** (#163).
  A surviving line that held a terminal control byte (for example ESC) was
  printed as that byte, so it could change what the terminal showed. The
  token, the replacement, the diff lines, method names, file paths and the
  kill matrix's test names now print each control character except tab as
  its Ruby escape (`\e`), and a byte that is not valid UTF-8 (a Latin-1
  source) as `\xNN`. The JSON and HTML
  reports already escaped text and do not change.
- **One edit on a line is scored once** (#159). Some opt-in operators emitted
  two mutants that give the same source: `literal_mutation` on `0` (the
  "change to 1" and "add 1" rules), `negation_removal` on `!!x` (either `!`
  removed), and `chain_link` or `operand_removal` on a repeated part such as
  `a.b.b.c` or `x || x`. Each copy had its own id, so one surviving edit
  counted twice. Now only the first copy on a line runs. Copies that start
  on different lines (a multi-line chain) both stay, so `--since` never
  loses the edit. Ids are assigned before the copy is dropped, so every kept
  mutant keeps its id, and the dropped copy's id simply stops appearing.
  Default runs do not change. If you use these operators with `--baseline`,
  regenerate the baseline after upgrading: the score can move with no code
  change, and in a full (unscoped) comparison a dropped copy that survived
  is listed as fixed. An ignore entry for one copy's id still ignores only
  that copy; the other copy still runs.
- **`# mutineer:disable-line` inside a string no longer silences a line**
  (#158). The marker was found with a text search, so a string such as
  `"# mutineer:disable-line"` ignored every mutant on its line and left
  them out of the score. Only a real `#` comment counts now. A heredoc or
  regex that holds the text is ignored too.
- **`./lib/x.rb` and an absolute path pair with a test** (#104). Auto-pairing
  found the test for `lib/calc.rb` but not for `./lib/calc.rb` or the
  absolute path to the same file. It reported "no test found by convention"
  and exited 2. A file argument inside the project is now made relative to
  the project root first, so equivalent spellings (`./`, `..`, absolute)
  pair with the same test and run once. A symlink keeps its own name, so it
  stays a separate source from its target. Reports show that root-relative
  path. A path outside the project stays as typed.
- **A mutant on another line of a multi-line statement runs its tests**
  instead of being reported as `no_coverage`. Ruby counts one line of a
  statement only. When the mutant's own line has no count, the runner now uses
  the tests that ran the statement that holds the mutation. A heredoc body
  belongs to its statement. This fallback skips a first or last line that also
  holds other code, such as the `def` line, and the body of `x while c` and
  `x until c`. It also gives no tests to a mutant in code of the statement
  that runs only sometimes: a `when` or `in` condition, a `rescue` class
  list, a parameter default, the rescue side of `x rescue y`, the value of
  `||=` or `&&=`, the operand of `defined?`, the right side of `a ||` or
  `a &&`, a branch of `x if c`, `x unless c`, a ternary or `else`, the
  pattern of `v in p` or `v => p`, an
  argument or block of `x&.m(...)`, and the value of `x&.m += v`. Those
  mutants stay `no_coverage`, as before.
- **A survivor diff for a multi-line mutant applies with `git apply`** (#106).
  The JSON `diff` header always read `@@ -N +N @@`, even when the mutant
  removed two lines and added one, so `git apply` rejected the patch as
  corrupt. The header now carries each side's line count (`@@ -3,2 +3 @@`).
  A one-line diff keeps its old header. A mutant that empties a line now
  shows that empty line as a `+` line. A side whose last line has no final
  newline gets `\ No newline at end of file`. Lines of a CRLF file now keep
  their `\r`, so the patch applies to that file.
- **Split test files pair with their source** (#87). A source such as
  `app/foo/bar.rb` now also uses `test/foo/bar_upsert_test.rb` and
  `test/foo/bar_guards_test.rb`, together with `test/foo/bar_test.rb` when
  that file exists. The same names under `test/lib/` pair with a `lib/`
  source. Before, only the exact `bar_test.rb` name was tried, so a suite
  split across `bar_*_test.rb` files was skipped and a gate could pass with
  no mutants run. A spec the old rules already find is unchanged. The
  split name is left for `user_session.rb` when that file exists, so
  `user.rb` does not run `user_session_test.rb`. The same rule holds outside
  `app/` and `lib/`: `src/user.rb` does not take `test/src/user_session_test.rb`
  when `src/user_session.rb` exists. A longer source claims a split file
  only when that source itself searches the directory the file is in.
  A failed capture of `test/foo/bar_upsert_test.rb` can mark `app/foo/bar.rb`
  uncapturable only when no successful capture covered that source and
  `bar_upsert.rb` does not exist. A test outside that directory does not,
  and neither does a source that only shares the test basename.
  `user_session__test.rb` stays with `user.rb` when `user_session.rb`
  exists, because that name is not the exact test or a split test for
  `user_session`. A failed exact spec in the mirrored `spec/` or `spec/lib/` directory
  marks an `app/` or `lib/` source the same way. A failed spec in another
  directory does not. A project rooted at `/` still finds split tests
  inside that root. A stored failure keeps the pairing from the moment it
  was checked. Adding or deleting a longer source rebuilds the coverage
  map, so that failure is not moved onto the shorter source.
- **A blank `operators` key no longer runs zero mutants and exits 0** (#167).
  `operators:` with no value became an empty list. The run made no mutants
  and the gate passed. A blank operator list is now an error, and so is a
  list of only unknown operator names. An empty `require` or `ignore` list
  is still valid. `--operators` on the command line still replaces the
  file list, including a blank or unknown file list.
- **The daemon no longer runs the tool's Ruby settings inside the app** (#100).
  Open3 keeps a variable when the spawn hash omits it, so a parent `RUBYOPT`
  ran inside the app. The child now gets the environment Bundler saved before
  it activated, passed with `unsetenv_others`. The app keeps its gem home,
  excluded groups, Bundler config, and chruby path. An `RBENV_VERSION` or
  `ASDF_RUBY_VERSION` already in the environment stays. That pin is often
  the Ruby that started the tool. `.ruby-version` applies only when no pin
  is set. The tool's `RUBYOPT` and `RUBYLIB` do not reach the child, including
  a value Bundler had saved. A gem home, `BUNDLE_PATH`, or `BUNDLE_WITHOUT`
  reaches the child only when Bundler saved the app's value. The same
  rule covers `GEM_PATH` and `BUNDLER_VERSION`. An rbenv version
  bin under `RBENV_ROOT`, or under `~/.rbenv` when that variable is unset,
  leaves `PATH` only when that root has a shim directory. An asdf version
  bin leaves only when an asdf shim directory exists, including
  `ASDF_DATA_DIR/shims`. Without that shim, the bin stays and `bundle` can
  still be found. The app Gemfile, an explicit Ruby pin, and Rails env are
  applied after that.
- **The Action refuses to run when `output` and `baseline` are the same file** (#160).
  That setup used to work, and a failing run copied its report onto the
  baseline. The next run then treated the failed report as the baseline, so
  the gate could pass. The Action now stops before the run and exits 2.
  The baseline may come from the `baseline` input, from `--baseline` in
  `extra-args`, or from `.mutineer.yml`. A numeric path such as `123` is
  read the same way as the CLI. Write the report to a separate path. Copy
  that file onto the baseline in a later step, and only when this step
  exits 0. You can also refresh the baseline with the CLI, and keep the
  file only when the run exits 0. The next release moves the `v1` tag, so
  workflows on `@v1` get this refusal then.
- **A mutation no longer leaves a heredoc body behind as Ruby** (#134).
  Replacing a node deletes the heredoc opener and not the body. The body
  then parses as code, raises, and counts as a kill. A mutation that drops
  the opener is skipped. A replacement that still contains the opener stays.
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
- **A mutant in a nested method counts once** (#157). A `def` inside
  another method is a subject of its own, but most operators also mutated
  its code on the outer method. The same edit then counted twice in the
  score, with two ids. Every operator now skips a nested `def` when it
  mutates the outer method. A `def` inside `class << obj`, where `obj` is
  not `self`, is not a subject, so the outer method still mutates its code.
  `array_literal`, `chain_link`, `condition_true`, `condition_false`,
  `operand_removal`, `operator_assignment` and `return_nil` skipped that
  code before. Their new mutants there can show as new survivors against a
  baseline.

  A mutant id includes an ordinal among the mutants with the same operator
  and token in a subject. When the duplicates leave the outer method, the
  ordinals of its own mutants change. An old duplicate id can then name a
  different mutant on the outer method, and an `ignore:` entry or a
  baseline entry with that id applies to that mutant with no warning. If
  your code has nested methods, regenerate the `ignore:` entries and the
  baseline for the outer methods.

  Under `--strategy redefine` (the `--rails` default), a mutant in a nested
  method can survive or error even when a test would catch it. `redefine`
  loads only the inner method, and a call to the outer method defines the
  original inner method again. Before, the copy of the edit on the outer
  method was killed. Now each edit has one verdict, from the inner method.

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

[1.7.0]: https://github.com/davidteren/mutineer/releases/tag/v1.7.0
[1.6.0]: https://github.com/davidteren/mutineer/releases/tag/v1.6.0
[1.5.0]: https://github.com/davidteren/mutineer/releases/tag/v1.5.0
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
