# CLI reference

Flags and defaults for `mutineer run`. Flags override `.mutineer.yml`; configuration overrides defaults.
`--[no-]` flags accept `--no-` to override configuration.
Source of truth: `lib/mutineer/cli.rb` parses options; `lib/mutineer/config.rb` sets defaults.

| Flag | What it does | Default |
|------|--------------|---------|
| `--test PATH` | Test file, directory or quoted glob; repeat for more | Paired with each source by convention, plus any matching `tests:` map entries; unmatched sources are skipped and counted in the report; `--test` replaces pairing and the map; `--dry-run` with `--rails` or `--boot` still needs `--test` |
| `--framework minitest\|rspec` | Test framework | `rspec` if most tests end in `_spec.rb`; otherwise `minitest` |
| `--operators LIST` | Comma-separated operator names | Tier-1 (default) set; see `mutineer --list-operators` |
| `--only NAME` | Mutate one subject, such as `Calculator#add` | All subjects |
| `--since REF` / `--no-since` | Mutate lines changed since git `REF` | Off |
| `--threshold FLOAT` | Exit 1 below this score (0 to 100); see the README [options table](https://github.com/davidteren/mutineer#options) for every exit-1 case | `0` (off) |
| `--baseline FILE` | Exit 1 for new survivors, or score drops on full runs, against a prior `--format json` report from a full run | None |
| `--baseline-epsilon FLOAT` | Allowed baseline score drop (CLI only) | `0` |
| `--jobs N` | Parallel workers | One per CPU; `1` under `--rails` without `--daemon`, `--test-command`, or `--fail-fast` |
| `--rails` | Boot `config/environment` once; reconnect Active Record per fork | Off |
| `--boot FILE` | Require app entry point before forking | None |
| `--[no-]daemon` | Boot once; separate worker test databases. Minitest only; requires `--rails` or `--boot` | Off |
| `--strategy reload\|redefine` | Reload file or redefine mutated method | `reload`; `redefine` under `--rails` without `--daemon` |
| `--test-command CMD` | Run tests in another Ruby subprocess; include `%{files}`. Forces one worker and sets `PARALLEL_WORKERS=1`; a wrapper can reset it. Run the tests in a fixed order: for Minitest, put `SEED=1` before the `mutineer` command (not inside `CMD`); for RSpec, add `--order defined` to `CMD` and keep `--order rand` out of `SPEC_OPTS` | None |
| `--timeout SECONDS` | Per-mutant limit, in-process | `10` |
| `--capture-timeout SECONDS` | Coverage capture and clean-run limit | `120` |
| `--cache-dir DIR` | Coverage cache directory | `.mutineer` |
| `--coverage-from FILE` | Reuse previous `coverage.json` (CLI only) | None |
| `--format human\|json\|html` | Report format (CLI only) | `human` |
| `--output FILE` | Report file | stdout |
| `--dry-run` | List mutants without testing | Off |
| `--[no-]fail-fast` | Stop at first survivor | Off |
| `--[no-]matrix` | Run all covering tests; report blind and redundant tests. In-process only | Off |
| `--[no-]allow-empty` | Suppress warnings for runs without mutants | Off |
| `--verbose` (alias `--debug`) | Full error details | Off |
| `--list-operators`, `--version`, `--help` | Print and exit | |

`--test` takes a file, a directory, or a quoted glob.
Repeat the flag to add another value.
A directory selects `*_test.rb`, `*_spec.rb`, and `test_*.rb` files.
It skips `test_helper.rb`.
It includes system tests and `test_` support files, such as `test/support/test_helpers.rb`.
Quote a glob, or the shell expands it first.
This selects the `*_test.rb` files under `test/models` and `test/controllers`: `--test 'test/{models,controllers}/**/*_test.rb'`.
With `--test-command`, a directory is passed as typed.
That run prints no count for the directory.
A glob still expands.
A blank value exits 2.
A directory or glob with no test file exits 2.
Each expanded directory or glob prints its file count on stderr.

## Test order

Coverage capture, the clean check and each mutant run share one seed (#282).
A green clean check is green in the order a mutant run of the same files uses.

Minitest uses seed `1`, or `SEED` when you set it.
A test helper can change `SEED` after it loads.
Those runs read it then.
To reproduce a failure, run the listed files with the same seed, for example `SEED=1 bundle exec ruby -Itest test/models/order_test.rb`.

A random RSpec order uses seed `1`.
A defined order is left as it is.
Set another seed with `--seed`, `--order rand:N`, `SPEC_OPTS`, `.rspec`, or `config.seed`.
A spec helper that only reads `config.seed`, as the generated `Kernel.srand config.seed` does, does not set one.

Files run in the order that run was given.
Inside one file, order depends only on the seed, not on the other files in the run.
A mutant run's files are the covering tests, paired files first, then the cheapest.
The combined clean check runs the covering tests in the order you passed them.
When one mutant runs several files, those two orders can differ.

`--test-command` is the exception.
Mutineer does not set its seed.
See that flag.

Other commands:

- `mutineer init [--rails] [--force]`
- `mutineer triage REPORT.json --reason TEXT (--id ID ... | --all)`
- `mutineer migrate <source...> [--dry-run] [--operators LIST]`
- `mutineer config cache_dir|baseline [run options]`: print the value `run` would use with these options and `.mutineer.yml`. An unset baseline prints nothing. It writes nothing. The GitHub Action uses it.

Exit codes: [README](https://github.com/davidteren/mutineer#exit-codes).

## Configuration

Mutineer searches upwards for the nearest `.mutineer.yml`.
Pass sources as positional arguments and tests with `--test`.

| Key | Value and purpose |
|-----|-------------------|
| `operators` | Operator name or list; defaults to Tier-1 |
| `threshold` | 0 to 100; 0 disables the score gate |
| `jobs` | Positive integer; defaults to CPU count. `test_command`, `fail_fast`, or `--rails` without `--daemon` forces 1 |
| `only` | Fully-qualified subject, such as `Calculator#add` |
| `require` | Extra file path or list to load before mutation |
| `boot` | App entry point to require before forking |
| `rails` | Boolean; enables Rails boot defaults |
| `since` | Nonblank git ref; `false` disables diff scoping |
| `framework` | `minitest` or `rspec`; preserved during test pairing |
| `tests` | File only. List of mappings with `sources` and `tests` patterns; adds those tests to the run when a matching source is in the run. See [Extra tests for a source](#extra-tests-for-a-source) |
| `verbose` | Boolean; shows capture diagnostics |
| `ignore` | Mutant ID or list, or mappings with an `id` and optional `reason`, to suppress |
| `baseline` | Prior JSON report path |
| `fail_fast` | Boolean; stops scheduling after first survivor |
| `test_command` | External Ruby test command containing `%{files}`; see [Apps on Ruby < 3.4](https://github.com/davidteren/mutineer/blob/main/docs/rails-setup.md#apps-on-ruby--34) |
| `daemon` | Boolean; persistent app daemon with separate worker databases |
| `timeout` | Positive integer; seconds per mutant (default 10) |
| `capture_timeout` | Positive integer; coverage capture seconds (default 120) |
| `cache_dir` | Coverage cache directory (default `.mutineer`) |
| `matrix` | Boolean; runs every covering test per mutant; adds report kill matrix |
| `allow_empty` | Boolean; suppresses warnings for expected runs without mutants |
| `shared_databases` | File only. Test database names that parallel `--daemon` workers may share; needs Rails 7.1 or later (on Rails 7.0 every parallel mutant scores `error`). Listing the primary database exits 2. If the test environment registers a pool for a listed database, every parallel mutant scores `error`. See [More than one database](https://github.com/davidteren/mutineer/blob/main/docs/rails-setup.md#more-than-one-database) |

| Validation | Rule |
|------------|------|
| Invalid scalar values or blank `operators` list | Exit 2; message names file and key |
| Unknown keys or operator names | Warn, suggest closest valid name, then ignore; errors in Mutineer 2.0 |
| No known operator names remain | Exit 2 |
| `--operators` | Replaces blank or unknown configuration lists |
| `require`, `ignore` | Empty lists allowed |
| Booleans | `true` or `false`, including quoted forms; not `"yes"` |
| `jobs` | Positive; strings contain digits only |
| `threshold`, CLI-only `--baseline-epsilon` | Strings use plain decimals: `90`, `0.5`; not `+2`, `1e2`, `1_0` |
| String options, including `only`, `baseline` | Cannot be null or boolean |
| `since` | Cannot be blank; use `since: false` to disable scoping |
| Malformed `tests:` map | Exit 2; message names file, entry number, and fault |
| `tests:` pattern that matches no file | Exit 2 on `mutineer run` and under `--dry-run`; not checked when `--test` is given |

CLI-only: `format`, `strategy`, `output`, `baseline_epsilon`, `dry_run`, `coverage_from`.
Use `--format json`, not `format:`. Select RSpec with `framework: rspec`.

```yaml
# .mutineer.yml
operators: [arithmetic, comparison, boolean_connector, boolean_literal, statement_removal]
threshold: 90
# A Rails app: use `rails: true` (boots config/environment and sets the Rails defaults)
# instead of `require: config/environment`.
rails: true
```

### Extra tests for a source

Use a `tests:` map when convention cannot pair a source, such as a controller concern whose tests live with the controllers that include it:

```yaml
tests:
  - sources: app/controllers/concerns/**/*.rb
    tests: [test/controllers/**/*_test.rb, test/integration/**/*_test.rb]
```

An entry adds its tests to the whole run when the run holds one of its sources.
A `tests:` glob that matches a directory expands that directory with the same
name filter as a typed `--test` directory (`*_test.rb`, `*_spec.rb`, `test_*.rb`).
A file the glob matches stays unfiltered. `--test` globs still drop directories.
Coverage picks the tests for each mutant.
A mapped test can thus also kill a mutant of another source in that run.
A `--baseline` gate therefore needs the sources of the run that wrote the baseline, as [CI](ci.md#baseline) already says.
Mutineer captures coverage for each test file in the run and checks it clean, also on a cache hit (#398).
A run of one mapped source loads every test of its entries.
`--test-command` runs every test in the run for every mutant.
A mutant that many test files cover can pass the time limit for one mutant.
The in-process limit is 10 seconds by default; `--daemon` uses a separate 60-second default, and `--daemon` and `--test-command` ignore `--timeout`.
Quote a pattern that starts with `*`.
Quote a pattern with braces inside a `[...]` list.
`--test` replaces pairing and the map.

Coverage uses a digest-keyed cache at `.mutineer/coverage.json`. Mutineer rebuilds it when a source, a test,
or a project file the tests load changes. The run then captures every test again (#421 tracks a per-test rebuild).

Before the mutants run, Mutineer checks that the unchanged tests pass:

- **Fresh capture.** Every test file runs alone. A failure stops the run. The test files that cover a
  source line then run together. Mutineer prints how many files the together check left out.
- **Cache hit.** Only the test files that cover a source line run, alone and then together. A mutant runs
  only those files, so a red test outside them cannot change a result. Mutineer prints how many files it
  did not check. A test file whose last capture failed is captured again, which also runs it. When no test
  covers any source line, every test file runs. In a standalone run (no boot file), each test loads every
  source and so covers it, and every test file runs (#426).
- **`--coverage-from`** (in-process `--rails` or `--boot` runs only; other runs ignore it). As on a cache hit: only the test files that cover a source line run, alone and then
  together, so a red test outside them does not stop the run. Mutineer prints how many files it did not check.
- **`--test-command`.** No coverage map is built. The clean run runs every `--test` file.

Add `.mutineer/` and any in-project `--cache-dir` directory to `.gitignore`:

```gitignore
.mutineer/
```

Keep `.mutineer/` ignored: `--test-command` writes locks there beside each source file.
