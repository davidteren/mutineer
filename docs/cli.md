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
| `--[no-]since-paired-tests` | With `--since`, an in-process or `--daemon` run uses only the tests paired with the sources that have a mutant on a changed line. Every source still loads. `--test`, `--test-command`, `--baseline`, `--coverage-from` on an in-process `--rails` or `--boot` run, and `--dry-run` keep the full test list. See [Tests of the changed sources](#tests-of-the-changed-sources) | Off |
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
| `--load-path DIR`, `-I DIR` | Put `DIR` on `$LOAD_PATH` before the boot file, the sources and the tests; repeat for more. Replaces `load_path:` in `.mutineer.yml` (unlike `ruby -I`, which adds). See the `load_path` key | None |
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
| `since_paired_tests` | Boolean, default `false`. Under `--since`, an in-process or `--daemon` run uses only the tests paired with the sources that have a mutant on a changed line. It narrows the tests, not the sources. `--test`, `--test-command`, `--baseline`, `--coverage-from` on an in-process `--rails` or `--boot` run, and `--dry-run` keep the full test list. See [Tests of the changed sources](#tests-of-the-changed-sources) |
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
| `load_path` | Directory or list of directories, relative to the project root or absolute. Mutineer puts them on `$LOAD_PATH` before it loads the boot file, the sources, the `require` files and the tests, in-process and under `--daemon` (the daemon does not pass `RUBYOPT` or `RUBYLIB` to the app), and passes them to `--test-command`. Ruby searches them in the written order, after the test-helper directories Mutineer finds itself; with no boot file, `lib` comes first. `--load-path DIR` or `-I DIR` replaces the list. With `--test-command`, Mutineer sets `RUBYLIB` for the command to these directories (1.11.0, [#535](https://github.com/davidteren/mutineer/issues/535)), in place of your own `RUBYLIB`; it does not pass your `RUBYOPT` either (#100). It skips an entry that is not a directory, that cannot be resolved (such as `~nosuchuser/lib`), or that has the path separator in its path, with a warning; Mutineer 2.0 exits 2 there ([#581](https://github.com/davidteren/mutineer/issues/581)). Ruby searches them after any `-I` the command passes and after a path the app puts in front itself, and before its gems. A wrapper that unsets `RUBYLIB`, or a command that starts Ruby in a container, does not get them: pass `-I` inside the command there ([#580](https://github.com/davidteren/mutineer/issues/580)). The coverage cache key holds these directories in order and every `.rb` file under them (not the run's sources and tests), so a reorder, a new file or an edit there captures every test again. Mutineer reads and hashes those files on every run, also on a cache hit, so a large directory adds read time. A change to another file there, such as YAML or JSON data, captures every test again when git lists it and the directory is below the project root; a `load_path` directory outside the project root is not checked for such files. See [Coverage cache: what captures every test again](#coverage-cache-what-captures-every-test-again) ([#548](https://github.com/davidteren/mutineer/issues/548), [#602](https://github.com/davidteren/mutineer/issues/602)) |
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
| `load_path` | Each entry must be a directory, or the run exits 2 with `mutineer: not a directory: <path> (<origin>)`, every bad path on one line. A blank entry, or a value that is not a string or a list of strings, exits 2. `load_path: []` is allowed. With `--test-command`, an entry that is not a directory, or that has the path separator (`:` on Linux and macOS) in its path, is skipped with the warning `[mutineer] --test-command skips these load_path entries: ...`, and the run goes on; Mutineer 2.0 exits 2 there ([#581](https://github.com/davidteren/mutineer/issues/581)). A blank entry or a wrong shape still exits 2 there |
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
A source at `packs/<pack path>/app/` or `packs/<pack path>/lib/` with no test by the other rules already pairs by the same rules inside its pack, such as `packs/catalog/test/models/item_test.rb` for `packs/catalog/app/models/item.rb`. Other pack roots, such as `engines/`, need the map (#554). A map entry adds its tests to the convention tests, for a pack source too.
The map is for tests that are not named that way:

```yaml
tests:
  - sources: app/controllers/concerns/**/*.rb
    tests: [test/controllers/**/*_test.rb, test/integration/**/*_test.rb]
```

An entry adds its tests to the whole run when the run holds one of its sources.
When a run with `since_paired_tests` under `--since` narrows its tests, it keeps an entry's tests only when one of its sources has a mutant on a changed line.
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

### Coverage cache: what captures every test again

Coverage uses a digest-keyed cache at `.mutineer/coverage.json`. A change inside a method body, with no
added or removed line and no change to a method that ran while the file loaded, recaptures the tests that
cover that source, plus any test file that was added or edited. The map matches a full capture. A class-body
edit, an added or removed source line, a load-time method, a change to which test pairs with a source, a
`--require` file, or another project file the tests load still recaptures every test (#421).

The cache key holds, among other inputs, the sources, the tests, the boot file, the `--require` files, the project's Ruby files
that the tests load, and the Ruby files under each `load_path` directory. It also holds the test seed: the
Minitest seed, or for RSpec the pinned seed, `SPEC_OPTS`, and the project's `.rspec` and `.rspec-local` files.

A run does not reuse the saved map, in full or in part, and captures every test, when one of these changed
since the run that saved it:

- a source, other than the method-body edit above (an added or edited test recaptures only that test);
- the boot file, a `--require` file, or a Ruby file that the tests loaded;
- a Ruby file under a `load_path` directory, or the order of those directories;
- the test seed;
- any other file below the project root that git lists: a tracked file that differs from the commit, or an
  untracked file that git does not ignore. Examples are a view, a fixture, a data file and a lock file
  (1.11.0, [#595](https://github.com/davidteren/mutineer/issues/595)).

Git compares each file with the commit of the run that saved the map. An edit that was already there when
the map was saved does not capture every test again when you commit it. A file that changes while a run is in
progress counts as changed for the next run.

When a file of the last item, a file that changed during the last run, or a git problem captures every test,
Mutineer prints one line on stderr that says why. With more than three paths, the line names three and counts the rest; `--verbose` then adds one
line for each path (not for a `--coverage-from` refusal). Each line starts with `[mutineer] coverage cache: ` (an accepted `--coverage-from`
capture uses `[mutineer] --coverage-from: ` for the no-git line, which says `capture it again`).

| Line you see | What it means | What to do |
|---|---|---|
| `<path> changed since the saved map, and Mutineer cannot tell which tests it affects; capturing every test.` | A file changed that no other cache check covers. | Nothing. If a test or a tool writes this file on every run, add it to `.gitignore`, or every run captures every test ([#603](https://github.com/davidteren/mutineer/issues/603)). |
| `<path> changed while the last run was in progress; capturing every test.` | A source, a test or a loaded Ruby file changed while the last run captured coverage, so the saved map may hold its old text ([#604](https://github.com/davidteren/mutineer/issues/604)). | Nothing. The run captures it again. |
| `<path> cannot be fingerprinted (a folder, a nested repository, a changed submodule, an unreadable file or a name that is not UTF-8): add it to .gitignore or remove it; capturing every test.` | Mutineer cannot compare this path with the saved map. | Add it to `.gitignore` or remove it. Until then every run captures every test. |
| `the commit of the saved map is not in this clone (a shallow clone, or a commit that no branch holds now; fetch the full history, in GitHub Actions with fetch-depth: 0); capturing every test.` | Git cannot compare the files with the commit of the saved map. | Fetch the full history. |
| `git could not list the changed files (run git status in the project to see why; the check needs git 2.24 or later); capturing every test.` | A git command failed, or git is older than 2.24, which this check needs. | Run `git status` in the project. |
| `the saved map records no git commit, and the project has one now; capturing every test.` | The map was saved before the first commit, or where git gave no answer. | Nothing. The next run reuses the new map. |
| `git gives no commit for this project (it has no commit yet, or git failed), so the changed files cannot be listed; capturing every test.` | The repository has no commit yet. | Make the first commit. Until then every run captures every test. |
| `git gives no answer for this project (no repository, git is not installed, or git ignores or refuses the folder), so an edit to a view, a fixture or a lock file is not seen; after such an edit, delete .mutineer/coverage.json (https://github.com/davidteren/mutineer/issues/602).` | The map is reused, but only the other checks ran. This line prints on each run that reuses a map. | After an edit to a file that is not Ruby, delete `coverage.json` in the cache directory once. |

A map saved by a Mutineer older than 1.11.0 holds no git record. The first run after the upgrade captures
every test once, with no line. A changed Ruby file that the tests loaded also captures every test with no line.

For an in-process `--rails` or `--boot` run, `--coverage-from` applies the same checks to the capture.
Instead of a capture of every test, the run exits 2
with `mutineer: --coverage-from <file> cannot be reused: <reason>; capture it again`, where the reason is
one of the texts above with `the capture` in place of `the saved map`. A capture from a Mutineer older than
1.11.0 is refused with `it records no git state: an older Mutineer made it; capture it again with this version`.
While the project holds a path that cannot be fingerprinted, every capture is refused: ignore or remove the
path.

These changes are not seen, and the map is reused ([#602](https://github.com/davidteren/mutineer/issues/602)):

- a file that git ignores, such as `.env`, built assets or an ignored `Gemfile.lock`;
- a file outside the project root, such as a data file in a `load_path` directory outside it
  ([#548](https://github.com/davidteren/mutineer/issues/548));
- a change that git does not report: line endings or a clean filter, a rename that changes only letter case,
  or a submodule that `git submodule deinit` empties;
- any change to a file that is not Ruby, in a project where git gives no answer;
- Mutineer's own files: `.mutineer.yml` in the project root, any file below the `.mutineer/` folder in the
  project root (the cache, the baseline), the cache file in another `--cache-dir`, the `--output` report, the
  `--baseline` file, the `--coverage-from` file, and the file-swap locks beside each source. A project whose
  tests read one of these files keeps the gap for it.

After such a change, if it changes which source lines a test reaches, delete `coverage.json` in the cache
directory once. The next run captures every test again.

The test list is part of the cache key, so a run with `since_paired_tests` under `--since` that narrows its
test list never gets a full cache hit on a full-run map. Partial recapture can still reuse the entries of the
tests it kept, when the tests it dropped pair with no source by convention. The dropped tests leave every entry,
so the map equals a capture of the narrowed list. Either way, the narrowed run saves its map over the full-run
one, and the next full run captures the dropped tests again. Pass `--cache-dir .mutineer/since` to the narrowed
runs to keep both maps (#552). A run with `--baseline` does not narrow, so it uses the full-run cache key.

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
  A capture from a Mutineer older than 1.11.0, or one whose project files changed since, is refused with a
  reason (exit 2; see the coverage cache section above, #595).
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
[mutineer] --since: running 14 of 281 test files, the ones paired with the 8 of 120 paired sources that have a mutant on a changed line. A mutant that only another test reaches shows as survived or no_coverage, so a kill or a survivor can be missed. no_coverage is outside the score, so a --threshold gate can pass where a full run fails: gate on a full run, or add --baseline, which keeps every test.
```

In a JSON report, `summary.tests_narrowed` is `true` for such a run.

The run keeps its full test list when you give `--test`, `--test-command`, `--coverage-from` on an in-process
`--rails` or `--boot` run, or `--baseline` (flag or `baseline` key), and stderr says the setting has no
effect, naming the first of these that applies. With the flags:

```text
[mutineer] --since-paired-tests has no effect when --baseline is given
```

When `since_paired_tests` or `baseline` comes from `.mutineer.yml`, the line names that key and the file
instead of the flag, for example `baseline in .mutineer.yml`. The other reasons always name the flag.

A run that ignores `--coverage-from` (no boot file, or `--daemon`) still narrows. A dry run runs no tests and prints nothing. When the tests of the sources
with a mutant on a changed line already make up the full list, no line prints: for example, every paired source
has such a mutant, or a `tests:` map entry adds every test. A library caller that builds
its own `Config` with no pairing rows also keeps the full list. When no changed line holds a mutant, the run
returns before it runs any test, with or without the setting.
Without `--since`, the setting does nothing, so the key can stay in a `.mutineer.yml` that full runs read.
A mutant that only a test of an unchanged source kills shows as `survived` or `no_coverage`. A mutant that
only such a test covers, and does not kill, shows as `no_coverage` instead of `survived`. `no_coverage` is
outside the score, so a narrowed `--threshold` gate can pass where a full run fails. Use a full run (without
the setting) for a `--threshold` gate you rely on. A `--baseline` run keeps every test, so its new-survivor
check sees that mutant as `survived`.
When the kept tests cover no source line at all, a `--daemon` run says so on stderr.
To check one, run the same command with `--no-since-paired-tests`. If the mutant is killed there, add that test
to the `tests:` map for the changed source. If it survives there, it is a real survivor. The limits are in #552.
