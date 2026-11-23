# CLI reference

Flags and defaults for `mutineer run`. Flags override `.mutineer.yml`; configuration overrides defaults.
`--[no-]` flags accept `--no-` to override configuration.
Source of truth: `lib/mutineer/cli.rb` parses options; `lib/mutineer/config.rb` sets defaults.

| Flag | What it does | Default |
|------|--------------|---------|
| `--test PATH` | Test file, directory or quoted glob; repeat for more | Paired with each source by convention, plus any matching `tests:` map entries. A source at `app/<dir>/concerns/<rest>.rb` with no pairable test there also pairs with an unclaimed split test at its namespace path. A source at `packs/<pack path>/app/` or `packs/<pack path>/lib/` with no test by those rules pairs by the same rules inside its pack, such as `packs/catalog/test/models/item_test.rb` for `packs/catalog/app/models/item.rb`. In a real run, unmatched sources are skipped and counted in the report; a dry run keeps them in its listing and counts them as unpaired; `--test` replaces pairing and the map; `--dry-run` with `--rails` or `--boot` needs no `--test` |
| `--framework minitest\|rspec` | Test framework | `rspec` if most tests end in `_spec.rb`; otherwise `minitest` |
| `--operators LIST` | Comma-separated operator names | Tier-1 (default) set; see `mutineer --list-operators` |
| `--only NAME` | Mutate one subject, such as `Calculator#add` | All subjects |
| `--since REF` / `--no-since` | Mutate lines changed since git `REF` | Off |
| `--[no-]since-paired-tests` | With `--since`, an in-process or `--daemon` run uses only the tests paired with the sources that have a mutant on a changed line. Every source still loads. `--test`, `--test-command`, `--coverage-from` on an in-process `--rails` or `--boot` run, and `--dry-run` keep the full test list. See [Tests of the changed sources](#tests-of-the-changed-sources) | Off |
| `--threshold FLOAT` | Exit 1 below this score (0 to 100); see the README [options table](https://github.com/davidteren/mutineer#options) for every exit-1 case | `0` (off) |
| `--baseline FILE` | Exit 1 for new survivors, or score drops on full runs, against a prior `--format json` report from a full run | None |
| `--baseline-epsilon FLOAT` | Allowed baseline score drop (CLI only) | `0` |
| `--jobs N` | Parallel workers | One per CPU; `1` under `--rails` without `--daemon`, `--test-command`, or `--fail-fast` |
| `--rails` | Boot `config/environment` once; reconnect Active Record per fork | Off |
| `--boot FILE` | Require this file once before the sources, then fork. An app entry point, or a gem's `lib/<name>.rb` | None |
| `--[no-]daemon` | Boot once; separate worker test databases. Minitest only; requires `--rails` or `--boot` | Off |
| `--strategy reload\|redefine` | Reload file or redefine mutated method | `reload`; `redefine` under `--rails` without `--daemon` |
| `--test-command CMD` | Run tests in another Ruby subprocess; include `%{files}`. Forces one worker and sets `PARALLEL_WORKERS=1`; a wrapper can reset it. Run the tests in a fixed order: for Minitest, put `SEED=1` before the `mutineer` command (not inside `CMD`); for RSpec, add `--order defined` to `CMD` and keep `--order rand` out of `SPEC_OPTS` | None |
| `--timeout SECONDS` | Per-mutant limit, in-process | `10` |
| `--capture-timeout SECONDS` | In-process and `--daemon` coverage capture and clean-run limit; `--test-command` ignores it. The combined clean check gets the larger of this and 1.5 times the summed capture time of its files, rounded up | `120` |
| `--cache-dir DIR` | Coverage cache directory | `.mutineer` |
| `--coverage-from FILE` | Reuse previous `coverage.json` (CLI only) | None |
| `--format human\|json\|html` | Report format (CLI only) | `human` |
| `--output FILE` | Report file | stdout |
| `--dry-run` | List mutants without testing. With `--format json`, print them with their ids | Off |
| `--[no-]fail-fast` | Stop at first survivor | Off |
| `--[no-]matrix` | Run all covering tests; report blind and redundant tests. In-process only | Off |
| `--[no-]allow-empty` | Suppress warnings for runs without mutants | Off |
| `--verbose` (alias `--debug`) | Full error details. The human report also lists each errored mutant and its cause | Off |
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
A green clean check uses that seed.
When a mutant runs several files, its file order can still differ from the combined clean check.

Minitest uses seed `1`, or `SEED` when you set it.
A test helper can change `SEED` after it loads.
Those runs read it then.
To reproduce a failure, run the listed files with the same seed, for example `SEED=1 bundle exec ruby -Itest test/models/order_test.rb`.

A random RSpec order uses seed `1`.
A defined order is left as it is.
Set another seed with `--seed N` or `--order rand:N` on the command line, in `SPEC_OPTS`, or in `.rspec`, or with `config.seed = N` in a spec helper, a `--require` file, or the boot file.
RSpec reads `SPEC_OPTS` after the command line, so a seed there replaces `--seed` on the `rspec` command.
A spec helper that only reads `config.seed`, as the generated `Kernel.srand config.seed` does, does not set one.

Files run in the order that run was given.
For Minitest, class order inside one file depends only on the seed, not on the other files in the run.
RSpec's random order does the same: each example is ordered by a hash of the seed and its id.
A custom RSpec order that looks at the whole list can still change when another file is added.
A mutant run's files are the covering tests, paired files first, then the cheapest.
The combined clean check runs the covering tests in the order you passed them.
When one mutant runs several files, those two orders can differ.

`--test-command` is the exception.
Mutineer does not set its seed.
See that flag.

Other commands:

- `mutineer init [--rails] [--force]`
- `mutineer triage REPORT.json --reason TEXT (--id ID ... | --all)`. Prints one `ignore:` entry per survivor, and one per id in that survivor's `copies`. An id from `copies` selects that whole group. It writes nothing.
- `mutineer migrate <source...> [--dry-run] [--operators LIST]`: rewrite old `ignore:` ids. `--dry-run` lists each change and every entry that matches no mutant, writes nothing, and exits 1 when any entry matches nothing. `run` warns about those entries for its own sources and operators, lists them in `summary.unmatched_ignores`, and still exits 0. `--only` skips that warning and reports an empty list, which does not mean every entry matched. See [Mutant ids](https://github.com/davidteren/mutineer/blob/main/docs/results.md#mutant-ids).
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
| `require` | Extra file path or list. These files load after the boot file, or after the sources when no boot file is set, so a source cannot use them while it loads. `--test-command` does not load them |
| `boot` | File to require once before the sources. An app entry point, or a gem's entry file (`lib/<name>.rb`) |
| `rails` | Boolean; enables Rails boot defaults |
| `since` | Nonblank git ref; `false` disables diff scoping |
| `since_paired_tests` | Boolean; under `--since`, run only the tests paired with the changed sources (in-process and `--daemon`). See [Tests of the changed sources](#tests-of-the-changed-sources) |
| `framework` | `minitest` or `rspec`; preserved during test pairing |
| `tests` | File only. List of mappings with `sources` and `tests` patterns; adds those tests to the run when a matching source is in the run. See [Extra tests for a source](#extra-tests-for-a-source) |
| `verbose` | Boolean; shows capture diagnostics, and lists each errored mutant and its cause in the human report |
| `ignore` | Mutant ID or list, or mappings with an `id` and optional `reason`, to suppress |
| `baseline` | Prior JSON report path |
| `fail_fast` | Boolean; stops scheduling after first survivor |
| `test_command` | External Ruby test command containing `%{files}`; see [Apps on Ruby < 3.4](https://github.com/davidteren/mutineer/blob/main/docs/rails-setup.md#apps-on-ruby--34) |
| `daemon` | Boolean; persistent app daemon with separate worker databases |
| `timeout` | Positive integer; seconds per mutant (default 10) |
| `capture_timeout` | Positive integer; coverage capture and clean-run seconds (default 120); `--test-command` ignores it. The combined clean check gets the larger of this and 1.5 times its files' summed capture time, rounded up |
| `cache_dir` | Coverage cache directory (default `.mutineer`) |
| `matrix` | Boolean; runs every covering test per mutant; adds report kill matrix |
| `allow_empty` | Boolean; suppresses warnings for expected runs without mutants |
| `shared_databases` | File only. Test database names that parallel `--daemon` workers may share; needs Rails 7.1 or later (on Rails 7.0 every parallel mutant scores `error`). Listing the primary database exits 2. If the test environment registers a pool for a listed database, every parallel mutant scores `error`. See [More than one database](https://github.com/davidteren/mutineer/blob/main/docs/rails-setup.md#more-than-one-database) |

With no boot file, an in-process run requires each source, then each `require` file.
A source that raises `NameError` while it loads cannot take the missing name from `require`.
With a boot file, `require` files load after that file, and the parent does not require the sources.
Point `boot` at an app entry point or a gem's entry file (`lib/<name>.rb`), or pass `--boot`.
Listing that file as an earlier source also loads it first.
A dry run does not load the sources, so it does not report this.
`--daemon` loads the boot file, then the `require` files, in the daemon.
`--test-command` does not load `require` files.

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

Use a `tests:` map when convention cannot pair a source, such as a controller concern whose tests live with the controllers that include it.
A source at `app/<dir>/concerns/<rest>.rb` with no pairable test at its `concerns/` path already pairs with an exact or split name at its namespace path.
A source at `packs/<pack path>/app/` or `packs/<pack path>/lib/` with no test by the other rules already pairs by the same rules inside its pack, such as `packs/catalog/test/models/item_test.rb` for `packs/catalog/app/models/item.rb`. Other pack roots, such as `engines/`, need the map (#554).
The map is for tests that are not named that way:

```yaml
tests:
  - sources: app/controllers/concerns/**/*.rb
    tests: [test/controllers/**/*_test.rb, test/integration/**/*_test.rb]
```

An entry adds its tests to the whole run when the run holds one of its sources.
A run with `since_paired_tests` under `--since` keeps an entry's tests only when one of its sources has a mutant on a changed line.
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

Coverage uses a digest-keyed cache at `.mutineer/coverage.json`. A change inside a method body, with no
added or removed line and no change to a method that ran while the file loaded, recaptures the tests that
cover that source, plus any test file that was added or edited. The map matches a full capture. A class-body
edit, an added or removed source line, a load-time method, a change to which test pairs with a source, a
`--require` file, or another project file the tests load still recaptures every test (#421).

The test list is part of the cache key. A run with `since_paired_tests` under `--since` that narrows its
test list misses a full-run cache and saves its own map over it. The next full run captures again. Pass
`--cache-dir .mutineer/since` to the narrowed runs to keep both maps (#552).

Before the mutants run, Mutineer checks that the unchanged tests pass:

- **Fresh capture.** Every test file runs alone. A failure stops the run. The test files that cover a
  source line then run together. Mutineer prints how many files the together check left out.
- **Cache hit.** Only the test files that cover a source line run, alone and then together. A mutant runs
  only those files, so a red test outside them cannot change a result. Mutineer prints how many files it
  did not check. A test file whose last capture failed is captured again, which also runs it. When no test
  covers any source line, every test file runs. In a standalone run, a line that ran only while the sources
  loaded does not put every test file in this set (#426). The conventionally paired test for that source
  still covers the line. A `tests:` map entry does not count as that pair. When none of the run's tests are
  conventionally paired with the source, every test file stays in the set (#467). A line a test
  runs after the sources load covers that test, as on a boot or daemon run.
- **`--coverage-from`** (in-process `--rails` or `--boot` runs only; other runs ignore it). As on a cache hit: only the test files that cover a source line run, alone and then
  together, so a red test outside them does not stop the run. Mutineer prints how many files it did not check.
  The capture's test list must equal this run's, so `since_paired_tests` does not narrow a run with
  `--coverage-from`. A capture saved by a narrowed run does not fit a later full `--coverage-from` run (#552).
- **`--test-command`.** No coverage map is built. The clean run runs every `--test` file.

Add `.mutineer/` and any in-project `--cache-dir` directory to `.gitignore`:

```gitignore
.mutineer/
```

Keep `.mutineer/` ignored: `--test-command` writes locks there beside each source file.

### Tests of the changed sources

`since_paired_tests` (`--since-paired-tests`) is off by default. Turn it on for a `--since` run that passes
whole folders, such as a pull request check. An in-process or `--daemon` run then uses only the test files
paired with the sources that have a mutant on a changed line: their convention tests and the tests of each
`tests:` map entry that holds them. The list keeps the order of the full list. Every source still loads, so a
source that another source loads keeps working. Stderr prints one line with the counts:

```text
[mutineer] --since: running 14 of 281 test files, the ones paired with the 8 of 120 paired sources that have a mutant on a changed line. A mutant that only another test reaches shows as survived or no_coverage, so a kill or a survivor can be missed.
```

The run keeps its full test list when you give `--test` or `--test-command`, or `--coverage-from` on an
in-process `--rails` or `--boot` run, and stderr says the setting has no effect. A run that ignores
`--coverage-from` (no boot file, or `--daemon`) still narrows. A dry run runs no tests and prints nothing. When the tests of the sources
with a mutant on a changed line already make up the full list, no line prints: for example, every paired source
has such a mutant, or a `tests:` map entry adds every test. A library caller that builds
its own `Config` with no pairing rows also keeps the full list. When no changed line holds a mutant, the run
returns before it runs any test, with or without the setting.
Without `--since`, the setting does nothing, so the key can stay in a `.mutineer.yml` that full runs read.
A mutant that only a test of an unchanged source kills shows as `survived` or `no_coverage`. A mutant that
only such a test covers, and does not kill, shows as `no_coverage` instead of `survived`. `no_coverage` is
outside the score and the `--baseline` new-survivor check, so a narrowed gate can pass where a full run fails.
To check one, run the same command with `--no-since-paired-tests`. If the mutant is killed there, add that test
to the `tests:` map for the changed source. If it survives there, it is a real survivor. The limits are in #552.
