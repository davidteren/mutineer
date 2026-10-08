# Mutineer

[![Gem Version](https://img.shields.io/gem/v/mutineer?logo=rubygems&color=e23b3b)](https://rubygems.org/gems/mutineer)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Mutineer%20Ruby-2da44e?logo=githubactions&logoColor=white)](https://github.com/marketplace/actions/mutineer-ruby)
[![Socket](https://img.shields.io/badge/Socket-security%20report-0a66c2?logo=socket&logoColor=white)](https://socket.dev/rubygems/package/mutineer)

A clean-room mutation-testing tool for Ruby. Mutineer mutates your source one
change at a time, runs your test suite (Minitest or RSpec) against each mutant, and reports the
ones your tests failed to catch — the gaps where your suite isn't actually
testing anything.

"Clean-room" means Mutineer was written from scratch. It contains no code from
[Mutant](https://github.com/mbj/mutant) or any other mutation-testing tool.
Mutineer's own code is licensed under MIT. See
[Mutineer and Mutant](https://github.com/davidteren/mutineer#mutineer-and-mutant)
for how the two tools differ.

- **Prism + stdlib only** — zero runtime dependencies (Ruby ≥ 3.4).
- **One mutation per mutant**, validity-checked by re-parsing.
- **Fork-isolated**, parallel execution (Linux + macOS).
- **Coverage-guided** — each mutant runs only the test files that cover its line.
- **Stops at the first failing test** — in-process runs (not `--daemon` or
  `--test-command`) stop a mutant's test run at the first failure, unless
  `--matrix` asks for every covering test. The source's paired test files run
  first, then the rest from fastest to slowest in doubling steps (under 1 s,
  1 to 3 s, 3 to 7 s, and so on); files in one step run in path order.

📖 **[mutineer.github.io →](https://davidteren.github.io/mutineer/)** — overview, operators, and usage.

## Install

```sh
gem install mutineer
```

Or in a Gemfile:

```ruby
gem "mutineer", group: :test
```

## Usage

```sh
mutineer run <source...> --test <test> [--test <test>...] [options]
```

Mutate `lib/calculator.rb`, checking it against its test, and fail CI if the
mutation score drops below 90%:

```sh
mutineer run lib/calculator.rb --test test/calculator_test.rb --threshold 90
```

### Options

| Flag | Meaning |
|------|---------|
| `--test FILE` | Test file covering the sources; one file per flag, so repeat it for each (`--test a_test.rb --test b_test.rb`) |
| `--operators LIST` | Comma-separated operator names (default: the Tier-1 set) |
| `--threshold FLOAT` | Exit 1 when the score is below FLOAT, or when nothing could be scored and something broke, or more than one mutant produced no verdict and they exceed 10% of those attempted (default: 0 = off) |
| `--only NAME` | Restrict to one fully-qualified subject, e.g. `Calculator#add` |
| `--framework NAME` | `minitest` (default) or `rspec`; auto-detected as rspec when most `--test` files end in `_spec.rb` |
| `--since REF` | Only mutate lines changed since git `REF` (e.g. `origin/main`). Untracked files are scored in full unless Git ignores them. |
| `--no-since` | Disable diff scoping; a typed no beats a `.mutineer.yml` `since:` key |
| `--baseline FILE` | Compare against a prior `--format json` run; exit 1 on new survivors / score drop (score drop is skipped under `--since`, whose score covers a different denominator; see [CI](https://github.com/davidteren/mutineer#ci-gating)) |
| `--baseline-epsilon FLOAT` | Score-drop tolerance for `--baseline` (default: 0) |
| `--jobs N` | Parallel worker count (default: processor count); forced to `1` by `--test-command`, `--fail-fast`, or `--rails` without `--daemon` |
| `--boot FILE` | Require an app entry point once before forking; select at least one test file |
| `--rails` | Boot `config/environment` and reconnect ActiveRecord per fork; without `--daemon`, defaults to `redefine` and runs serially |
| `--verbose` | Surface the real error when a fork capture fails (alias `--debug`) |
| `--strategy NAME` | Mutation application: `reload` whole-file (default) or `redefine` surgical (`7a`/`7b` accepted as deprecated aliases) |
| `--timeout SECONDS` | Per-mutant time limit for in-process runs, in whole seconds (default: 10). A mutant whose tests run longer is a `timeout`; see [Timeouts and the score](https://github.com/davidteren/mutineer#timeouts-and-the-score). `--daemon` and `--test-command` keep their own limits |
| `--capture-timeout SECONDS` | Time limit for each in-process coverage-capture subprocess and for the clean run of the unmutated tests, in whole seconds (default: 120). A suite slower than this stops the run as not green. `--daemon` uses it for its coverage capture; `--test-command` ignores it and says so |
| `--cache-dir DIR` | Directory for the coverage cache (default: `.mutineer`). Give two runs from the same project root different directories so they do not share `coverage.json`. `--test-command` builds no cache, so it ignores it and says so |
| `--test-command CMD` | Run the suite as a subprocess in the app's own runtime (for apps on Ruby < 3.4); `CMD` must contain `%{files}`. See [Apps on Ruby < 3.4](https://github.com/davidteren/mutineer#apps-on-ruby--34) |
| `--daemon` | Boot the app once in a persistent daemon and fork per mutant, with per-worker DB isolation so `--jobs N` is safe under Rails (needs `--rails`/`--boot`; not with `--test-command`). See [the daemon backend](https://github.com/davidteren/mutineer#faster-parallel-safe-rails-the---daemon-backend) |
| `--format human\|json\|html` | Report format (default: human; `html` is a self-contained file) |
| `--output FILE` | Write the report to FILE instead of stdout |
| `--dry-run` | List candidate mutations without executing (honors suppression) |
| `--fail-fast` | Stop at the first surviving mutant (`--no-fail-fast` beats a `.mutineer.yml` `fail_fast:` key) |
| `--allow-empty` | A run with no mutants is expected. Without it, an empty full scan warns that Mutineer 2.0 will fail it. An empty `--since` run never warns: it reports that the changes hold nothing to test. `--no-allow-empty` beats a `.mutineer.yml` `allow_empty:` key |
| `--matrix` | Run every covering test for each mutant and report the blind and redundant tests; the JSON report also lists each mutant's killers. In-process only; exits 2 with `--daemon`, `--test-command`, `--fail-fast` or `--dry-run`. RSpec needs 3.3 or later. `--no-matrix` beats a `.mutineer.yml` `matrix:` key. See [Kill matrix](https://github.com/davidteren/mutineer#kill-matrix) |
| `--list-operators` | List available operators (default vs optional) and exit |
| `--version`, `--help` | Print version / usage and exit |

### Exit codes

<!-- contract:exit-codes -->
| Code | Meaning |
|------|---------|
| `0` | Score ≥ threshold (or no gate) **and** no baseline regression. |
| `1` | Score below `--threshold`, OR nothing could be scored and something broke, or more than one mutant produced no verdict and they exceed 10% of those attempted, OR a `--baseline` regression, OR a runtime error. |
| `2` | Usage / invalid-flag error (mistyped flag, bad path, unreadable baseline). |
<!-- /contract:exit-codes -->

### Operators

Run `mutineer --list-operators` to see them. Default (Tier 1): `arithmetic`,
`comparison`, `boolean_connector`, `boolean_literal`, `statement_removal`.
Available but off by default (Tier 2, enable via `--operators`): `return_nil`,
`literal_mutation`, `condition_negation`, `string_literal`, `regex`,
`collection_method`, `safe_navigation`, `range`, `negation_removal`, `chain_link`,
`operand_removal`, `array_literal`, `condition_true`,
`condition_false`, `operator_assignment`.

## Rails apps

Rails code needs its environment booted before the suite runs, so point Mutineer
at your app with `--rails` and run it inside the project's bundle:

```sh
RAILS_ENV=test bundle exec mutineer run \
  app/models/order.rb --test test/models/order_test.rb --rails
```

`--rails` boots `config/environment` once in the parent process (every mutant
then forks and inherits it), defaults `--strategy` to `redefine` without `--daemon`
(surgical — it avoids reloading files into the app tree; `--daemon` keeps `reload`), and reconnects ActiveRecord in each
fork so the database connection is fork-safe. Use `--boot FILE` to boot a
different entry point. Boot mode requires at least one `--test` file and is
coverage-guided — each mutant runs only the test files that exercise its line
(coverage is captured by forking the booted app, then cached).

Some code runs while the app boots or a class loads, for example a class body
that calls a method to build a constant, a `to_prepare` initializer, or a
`--require` file that calls a source method. That run
happens before the mutant is applied, and the forked test does not repeat it.
A mutant on such a line is `ran_at_load`, not `survived` or `no_coverage`. It is
left out of the score and does not fail `--threshold`; a kill still counts.
This holds under both strategies: `reload` runs the mutated file's class body
again, but not an initializer or another file's code, so a survivor on such a
line is not trusted there either.
Run those mutants with `--test-command`, which boots a fresh process per mutant,
to get a verdict.

Add Mutineer to your Gemfile's test group:

```ruby
gem "mutineer", group: :test, require: false
```

### Faster, parallel-safe Rails (the `--daemon` backend)

`--rails` boots your app once but runs mutants **serially** — parallel `--jobs`
under Rails is unsafe, because every worker shares one test database and clobbers
the others' fixtures. `--daemon` fixes both: it boots the app once in a persistent
helper and forks per mutant, and gives **each parallel worker its own database**,
so `--jobs N` is safe and its verdicts are proven identical to a serial run.

```sh
RAILS_ENV=test bundle exec mutineer run \
  app/models/order.rb --test test/models/order_test.rb \
  --rails --daemon --jobs 4
```

- **One boot, forked per mutant** — restores the shared-boot speed.
- **Coverage-guided** — each mutant runs only its covering tests (like `--rails`);
  a mutant on an uncovered line is `no_coverage`, so the score stays comparable to
  the in-process `--rails` score.
- **Safe `--jobs N`** — each worker routes to its own copy of the test database, so
  parallel verdicts equal serial (no fixture cross-talk). On first use, a
  worker's database is a copy of the test database after the app boots, so rows
  written by initializers or `--require` files are there, as in-process. When
  the copy's schema differs from `db/schema.rb` (another schema version or
  `schema_sha1` checksum, or no stored checksum, as in an empty or out-of-date
  test database, or one set up with a plain `load "db/schema.rb"`), the
  worker loads `db/schema.rb` over it, which drops the copied rows of the
  tables it defines.
- **One backend at a time** — `--daemon` can't be combined with `--test-command`
  (choose one), and it needs an app to boot (`--rails` or `--boot`).

Status: **SQLite** only (hermetic, CI-proven). Per-worker provisioning for
**Postgres** and other adapters is not supported: on those, `--daemon` scores
every mutant as `error`. Use `--daemon` with a SQLite test database, or drop
`--daemon` to run serially on other adapters.

### Apps on Ruby < 3.4

Mutineer's own process needs Ruby ≥ 3.4 (it parses with stdlib Prism), and the
`--rails` path above boots your app *inside Mutineer's process* — so it can't run
against an app pinned to an older Ruby (`ruby "3.1.6"` in the Gemfile), where the
bundle rejects 3.4.

`--test-command` decouples the two: Mutineer stays on ≥ 3.4, but your suite runs
as a **subprocess in your app's own runtime** (whatever Ruby its bundle resolves
to). Run Mutineer with a 3.4+ Ruby and hand it the command that runs your tests:

```sh
RAILS_ENV=test mutineer run app/models/order.rb \
  --test test/models/order_test.rb \
  --test-command "bundle exec rails test %{files}"
```

- **`%{files}`** is required; it expands to the `--test` paths as separate
  arguments (a path with a space stays one argument — there is no shell).
- **Environment:** vars like `RAILS_ENV` / `DATABASE_URL` set on the Mutineer
  command are inherited. Mutineer **unsets** `BUNDLE_*`, `GEM_*`, `RUBY*`,
  `RBENV_VERSION`, `ASDF_RUBY_VERSION`, and `RBENV_DIR` in the child (so
  Mutineer's own Ruby cannot pin the suite), and drops version-manager
  **version bins** (e.g. `~/.rbenv/versions/3.4.x/bin`) from `PATH`, then
  prepends rbenv/asdf shims when a pin was scrubbed. Do not rely on
  `RBENV_VERSION=…` on the Mutineer command for the suite; use `.ruby-version`
  or a wrapper. Don't put `KEY=val` prefixes *inside* `--test-command` (no shell;
  that would be treated as the program name).

#### Under a version manager (rbenv / asdf / chruby)

Automatic scrub targets **rbenv** and **asdf** (shims + version bins). **chruby**
has no shims: Mutineer still strips `…/rubies/…/bin` so it cannot leave Mutineer's
Ruby pinned, but you need a wrapper that sources chruby and selects the app
version. If the smoke check still reports a **Ruby version mismatch**, wrap the
suite. Example rbenv wrapper (`bin/mutineer-test` in the app):

```sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
unset GEM_HOME GEM_PATH RUBYLIB RUBYOPT BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_VERSION
export RBENV_VERSION="$(cat .ruby-version 2>/dev/null || true)"
export RAILS_ENV="${RAILS_ENV:-test}"
export PATH="${HOME}/.rbenv/shims:${PATH}"
exec bundle exec rails test "$@"
```

```sh
# Mutineer on 3.4+; suite on the app's Ruby via the wrapper
mutineer run app/models/order.rb \
  --test test/models/order_test.rb \
  --test-command "bin/mutineer-test %{files}"
```

Mutineer also surfaces a targeted smoke-check message when Bundler prints
`RubyVersionMismatch`, instead of only blaming DB/migrations.

Tradeoffs — this path is correct but not free:

- **Slower:** your app re-boots for every mutant (no shared boot yet).
- **No coverage narrowing:** every mutant runs the *full* `--test` set, so the
  score is an **upper bound and not comparable to an in-process (`--rails`)
  score** — uncovered mutants count as survivors, and an infrastructure failure
  is scored as a kill. Mutineer prints this caveat on every run and aborts up
  front (a "smoke check") if your unmutated suite isn't green.
- **Reload strategy only** (`--strategy redefine` is rejected on this path) and
  **serial** (`--jobs` is forced to 1). For apps on Ruby ≥ 3.4, `--daemon` gives
  safe parallelism instead (see [the daemon backend](https://github.com/davidteren/mutineer#faster-parallel-safe-rails-the---daemon-backend)).

## Timeouts and the score

The mutation score is `killed / (killed + survived)`. A mutant whose tests run
past `--timeout` is a `timeout`. It is neither killed nor survived, so it is
left out of the score, like `no_coverage`, `uncapturable`, `unplaceable`, `ran_at_load`, `errored`, skipped
and ignored mutants. A timeout is not counted as a kill, because a hang the
mutant caused and a suite that is just slow look the same. The human report
shows the count in its `Timeout:` row, and the JSON report in `summary.timeout`.

Under `--threshold`, a timeout is a mutant with no verdict. The run exits 1 when
more than one mutant produced no verdict and they exceed 10% of those attempted,
or when nothing could be scored and something broke. If a slow suite times out
mutants that its tests would catch, raise `--timeout`. A limit set below what
the suite needs does not raise the score: it turns those mutants into timeouts,
and once they pass 10% of the attempted mutants the run fails.

## Suppressing equivalent mutants

Some mutants are equivalent (behaviour-identical) and survive forever — keeping a
file off 100%. Suppress them so the score and `--threshold` gate stay meaningful:

- **Inline:** `some_line # mutineer:disable-line` (or scope it: `# mutineer:disable-line comparison`). Put a reason after `--`: `# mutineer:disable-line comparison -- the test checks only 20`.
- **Config:** a `.mutineer.yml` `ignore:` list of mutant ids. Each survivor's
  `id` is printed in the JSON report, so copy it straight into `ignore:`.

Suppressed mutants are excluded from the score (so 100% becomes reachable).

## Mutant ids

A mutant id is 12 hex characters. It hashes the file path (relative to the
project root), the method's qualified name, the operator, the mutated code, and
the mutant's position among identical mutants in that method. When one file has
two methods with the same qualified name (for example two top-level `def index`
in two DSL blocks), the second and later ones also hash their position among
those methods, so their ids differ. The first one's id does not change. An edit
outside the method does not change the id. Moving or renaming the file,
renaming the method or its class, or adding an identical mutant earlier in the
method does. Adding a method with the same name earlier in the same file also
does.

- The project root is the directory mutineer runs from (in the Action, the
  `working-directory`). Run from the same root to get the same ids.
- A source outside the project root uses its absolute path, so its ids differ
  between machines.

**Migrating from ids without the file path.** Before 1.3, ids did not include
the file path, so two files could share an id (#126). Old-format ids keep
working until 2.0, with a warning:

- **`ignore:`** An old entry still suppresses its mutants. The run prints the
  new ids for each old entry, each with its file and method. When it names one
  mutant, replace the entry with that id. When it names several (in different
  files, or same-named methods in one file), the old entry over-matched: it also
  hid mutants you did not mean to ignore. The warning says so. Keep only the ids for the mutant you meant to
  ignore, not all of them. The list covers only the sources and operators in
  that run, so run over every source with every operator set you use (for
  example your Tier-2 `--operators`) for the full list.
- **`--baseline`** An old baseline still matches: a survivor matches a stored
  one with the same old id in the same file. A stored file that is an absolute
  path outside the project root (a baseline written on another machine)
  matches on the old id alone. The run tells you to
  regenerate it. Regenerate it with `--format json`, but only after every gate
  that reads it runs 1.3 or later (the Action's `version:` pin, your CI
  `Gemfile.lock`). An older version treats every new-format survivor as new.

The JSON report's `summary.id_format` is `2` for the new format.
`summary.legacy_id_matches.ignore` counts the old-format ignore entries a run
matched, and `summary.legacy_id_matches.baseline` counts the survivors matched
only through an old baseline id.

Ids are relative to the directory you run mutineer from. mutineer finds
`.mutineer.yml` by walking up. When the file it loads is in a parent directory
(other than your home directory), it warns that the ignore ids will not match
and tells you which directory to run from.

## Kill matrix

`--matrix` reports which tests kill each mutant, and from that, which tests
add nothing to the suite.

```sh
mutineer run lib/calculator.rb --test test/calculator_test.rb --matrix
```

For each mutant, Mutineer runs every test in its covering files instead of
stopping at the first failure, and records which tests failed. Coverage is
recorded per test file, so that set also holds tests that never reach the
mutated line; they pass and count as having run. A mutant's row is complete
when its whole covering set ran and the suite returned normally (under
Minitest, an `Interrupt` that cut the run short does not count as returning
normally). The report
names two kinds of test:

- **Blind:** the test ran in at least one complete row and killed no mutant
  in any row. It would still pass with this run's mutations of the code, so
  it guards none of them. It can still check behavior outside this run's
  mutants (code in other files, or edits no operator makes), so look at what
  it asserts before you delete it, or give it an assertion that can fail.
- **Redundant:** every mutant the test kills, another test kills too. That
  makes it a candidate for deletion, one test at a time: two redundant tests
  can be the only killers of one mutant, so re-run after each deletion.

The answers cover this run's mutants only. A test of code outside the sources
you passed kills nothing here, so mutate the code a test exercises before you
call the test blind.

The matrix changes no verdict, score or exit code: each mutant gets the
verdict a run without `--matrix` gives. That run skips every later test,
test class and example group after the first failure, so when a later one
exits the process, crashes or runs into the time limit, the mutant is still
`killed`. The run without `--matrix` still runs the code around the failing
test (the rest of its Minitest class `run` wrapper, the `after(:all)` hooks of
its RSpec groups) and the suite's own cleanup (RSpec's `after(:suite)`), so an
end there keeps the exit status. A failure in a Minitest `parallelize_me!`
class also keeps it: those run after every serial class and cannot be stopped
once queued, while a failure in a serial class still stops the run.

Under RSpec, `--matrix` needs RSpec 3.3 or later, whose example ids tell
apart examples on one line. With an older RSpec every row is incomplete.

The human report lists up to 20 blind and 20 redundant tests, and the HTML
report lists them all. `--format json` adds a `matrix` block with every test
and each mutant's killers (see the
[JSON schema](https://davidteren.github.io/mutineer/json-schema.html#matrix)).
A test is its file and its id. The name is `CalculatorTest#test_add` under
Minitest, or the example's full description under RSpec, where the example id
(`./spec/calc_spec.rb[1:2]`) tells apart examples that share a description
and keeps an example whose generated description changes with the mutant as
one test.

Each mutant runs its whole covering set, so every mutant costs what a survivor
costs. In 1.4, stopping at the first failure cut a full run of rack's
`lib/rack/utils.rb` from 86 to 89 seconds down to 35 to 41, so expect a matrix
run to take 2.1 to 2.5 times as long as a normal one. A mutant that reaches the
per-mutant time limit (`--timeout`, 10 seconds by default) after a test already failed stays `killed`
with its row marked incomplete. The report names each incomplete row and warns
that a blind test may have killed one of those mutants, so do not delete a
blind test until its rows are complete. Raise `--timeout` (or `timeout:` in
`.mutineer.yml`) to get complete rows.

`--matrix` runs on the in-process backend only. It exits 2 with `--daemon`,
`--test-command`, `--fail-fast` or `--dry-run`, and the message says whether
each setting came from the command line or `.mutineer.yml`. To run one of
those with `matrix: true` in the file, pass `--no-matrix`; to run `--matrix`
with `fail_fast: true` in the file, pass `--no-fail-fast`.

## CI gating

Store a JSON run as a baseline, then fail the build only when a PR makes things
worse:

```sh
mutineer run app/ --baseline .mutineer/baseline.json   # exit 1 on NEW survivors or a score drop
```

`--baseline` reports which survivors are new (by [mutant id](https://github.com/davidteren/mutineer#mutant-ids)) and any score drop. It
combines with `--threshold` (the worse of the two sets the exit code). Pass a
directory (or several sources) to audit a whole layer in one boot — tests are
auto-paired by convention and the report breaks down per source. A source
`app/foo/bar.rb` pairs with `test/foo/bar_test.rb` and with unclaimed
`test/foo/bar_*_test.rb` files in that directory, such as `bar_upsert_test.rb`.
It does not take `user_session_test.rb` when `user_session.rb` exists in the same directory.
It does not take `bar_upsert_guards_test.rb` when `bar_upsert.rb` exists.
A spec that already pairs is left as that one file.

### GitHub Action

This repo ships a composite action (`action.yml`) that wraps the CLI for CI:

```yaml
- uses: actions/checkout@v4
- uses: ruby/setup-ruby@v1
  with: { ruby-version: "3.4", bundler-cache: true }
- uses: davidteren/mutineer@v1
  with:
    sources: app/
    baseline: .mutineer/baseline.json
    threshold: "90"
```

**Default change:** on `pull_request` events (not `pull_request_target`) the
action scopes the run to the PR's changed lines, diffing against the PR's exact
base commit (fetched by the action itself when the checkout is shallow; falls
back to the base branch tip). Pass `since: none` for a full scan, or an
explicit `since:` ref (which needs `fetch-depth: 0` on checkout).

With the default JSON format the action also:

- writes a score summary to the job's step summary;
- annotates surviving mutants on the PR diff, up to 50 (`error` level when the
  gate failed, `warning` when it passed);
- exposes the report path via the `report` output for later steps (with
  `format: human`/`html` this needs the `output` input).

The CLI prints a progress line to the log at every 10% of the run, whatever
the format.

## For AI agents & pipelines

Mutineer is built for programmatic use — versioned JSON, [mutant ids](https://github.com/davidteren/mutineer#mutant-ids) that survive unrelated edits,
structured exit codes, and diff-scoped runs. See:

- **AI agents & CI recipes** — the agent inner-loop and CI-gate recipes (and how
  to avoid infinite loops on equivalent mutants):
  [rendered](https://davidteren.github.io/mutineer/agentic-coding.html) ·
  [source](https://davidteren.github.io/mutineer/agentic-coding.md)
- **JSON schema reference** — the `--format json` schema and its versioning
  contract:
  [rendered](https://davidteren.github.io/mutineer/json-schema.html) ·
  [source](https://davidteren.github.io/mutineer/json-schema.md)
- **Ruby API (YARD)** — class reference for the shipped gem:
  [https://davidteren.github.io/mutineer/api/](https://davidteren.github.io/mutineer/api/)
- **Agent skill** ([`skills/mutineer/SKILL.md`](https://github.com/davidteren/mutineer/blob/main/skills/mutineer/SKILL.md)): a short
  card for coding agents with install, the agent loop, and exit codes. Install it
  with `gh skill install davidteren/mutineer mutineer` or
  `npx skills add davidteren/mutineer --skill mutineer`.

## Configuration

Mutineer reads an optional `.mutineer.yml` from the project root (nearest one,
walking up). CLI flags override config; config overrides defaults.

Sources are positional CLI arguments and test files come from `--test`. The
config file accepts these keys:

| Key | Value and purpose |
|-----|-------------------|
| `operators` | An operator name or list of names; defaults to the Tier-1 set |
| `threshold` | A number from 0 to 100; 0 turns the score gate off |
| `jobs` | A positive integer; the default is the processor count. `test_command`, `fail_fast`, or `--rails` without `--daemon` forces 1. |
| `only` | A fully-qualified subject name, such as `Calculator#add` |
| `require` | A path or list of extra files to load before mutating |
| `boot` | The app entry point to require once before forking |
| `rails` | `true` or `false`; enables the Rails boot defaults |
| `since` | A nonblank git ref, or `false` to disable diff scoping |
| `framework` | `minitest` or `rspec`; an explicit value is kept during test pairing |
| `verbose` | `true` or `false`; shows capture diagnostics |
| `ignore` | A mutant id or list of ids to suppress |
| `baseline` | The path to a prior JSON report |
| `fail_fast` | `true` or `false`; stops scheduling after the first survivor |
| `test_command` | The external-runtime suite command, including `%{files}`; see [Apps on Ruby < 3.4](https://github.com/davidteren/mutineer#apps-on-ruby--34) |
| `daemon` | `true` or `false`; uses the persistent app daemon with worker DB isolation |
| `timeout` | A positive integer; the per-mutant time limit in seconds (default 10) |
| `capture_timeout` | A positive integer; the coverage-capture time limit in seconds (default 120) |
| `cache_dir` | The coverage cache directory (default `.mutineer`) |
| `matrix` | `true` or `false`; runs every covering test for each mutant and adds the kill matrix to the report |
| `allow_empty` | `true` or `false`; a run with no mutants is expected, so it does not warn |

Invalid values for known scalar keys, and a blank `operators` list, exit 2
with a message naming the file and key. An unknown operator name warns and
is skipped. If none of the names are known, the run exits 2. An empty
`require` or `ignore` list is valid. Boolean keys take `true` or `false` (quoted forms also work), not `"yes"`.
`jobs` must be positive; a string value contains digits only. String values for
`threshold` and the CLI-only `--baseline-epsilon` use plain decimals such as `90`
or `0.5`, not `+2`, `1e2`, or `1_0`. String options such as `only` and `baseline`
cannot be null or boolean. A blank `since` is invalid; use `since: false` to turn
scoping off. Unknown keys warn and are ignored. Unknown operator names warn and are skipped, and the run exits 2 when none remain. Both warnings suggest the closest valid name, and both become errors in Mutineer 2.0. `--operators` replaces a blank or unknown file list.

`format`, `strategy`, `output`, `baseline_epsilon`, and `dry_run` are CLI-only.
For JSON output, use `--format json`, not a `format:` config key. To select RSpec
in the file, add `framework: rspec`.

```yaml
# .mutineer.yml
operators: [arithmetic, comparison, boolean_connector, boolean_literal, statement_removal]
threshold: 90
jobs: 4
require:
  - config/environment
```

Coverage results are cached in `.mutineer/coverage.json` (digest-keyed; rebuilt
automatically when sources change). Add `.mutineer/` to your `.gitignore`, and
the directory you set with `--cache-dir` if it is inside the project. Keep
`.mutineer/` ignored even then: `--test-command` writes lock files to
`.mutineer/` beside each source file.

## Mutineer and Mutant

[Mutant](https://github.com/mbj/mutant), by Markus Schirp, is the established
mutation-testing tool for Ruby. It has been in development since 2012 and is
the subject of published research. Mutineer is a separate tool, and it shares
no code with Mutant.

| Aspect | Mutineer | Mutant |
|---|---|---|
| License | MIT, for every use | Free for open source (`--usage opensource`); commercial use needs a paid subscription |
| Runtime dependencies | None (Prism + stdlib) | `parser`, `unparser`, `regexp_parser`, `sorbet-runtime` and others |
| Ruby | 3.4 and later to run Mutineer; an app on an older Ruby works through `--test-command` (see [Apps on Ruby < 3.4](https://github.com/davidteren/mutineer#apps-on-ruby--34)) | 3.3 and later |
| Test frameworks | Minitest and RSpec, in one gem | RSpec, Minitest and Test::Unit, one integration gem each |
| What you mutate | Files (`mutineer run lib/foo.rb --test test/foo_test.rb`), narrowed to one method with `--only 'Foo#bar'` | Subjects named by expression (`mutant run 'Foo#bar'`, `'Foo*'`) |
| Which tests run | The test files whose coverage reaches the mutated line | The tests that declare the subject (an RSpec description or a Minitest `cover`), or the tests that ran it in a per-test coverage recording |
| Operators | 20 (5 by default, 15 opt-in) | A larger set; the default `light` set applies almost all of it (`full` adds `#==` to `#eql?`) |
| CI gating | `--threshold`, `--baseline` deltas, `--since`, and a GitHub Action | Incremental mode (`--since`) and a recorded session history |
| Machine-readable output | Versioned JSON report schema | Session JSON schema |

Choose Mutineer when you want an MIT-licensed tool with no extra gems in your
bundle, file-based runs, and a JSON contract built for CI gates and AI agents.
Choose Mutant when you need its deeper operator set, Test::Unit support, or
subject expressions that select whole namespaces. The two tools do not
conflict, so you can run both on one project.

This comparison describes Mutant 0.17 (checked on 2026-10-06). Check
[Mutant's README](https://github.com/mbj/mutant#readme) for its current
license terms and features.

## License

MIT — see [LICENSE](https://github.com/davidteren/mutineer/blob/main/LICENSE).
