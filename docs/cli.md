# CLI reference

Flags and defaults for `mutineer run`. Flags override `.mutineer.yml`; configuration overrides defaults.
`--[no-]` flags accept `--no-` to override configuration.
Source of truth: `lib/mutineer/cli.rb` parses options; `lib/mutineer/config.rb` sets defaults.

| Flag | What it does | Default |
|------|--------------|---------|
| `--test FILE` | Test file; repeat for each file | Paired with each source by convention; unmatched sources are skipped; `--dry-run` with `--rails` or `--boot` still needs `--test` |
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
| `--test-command CMD` | Run tests in another Ruby subprocess; include `%{files}`. Forces one worker and sets `PARALLEL_WORKERS=1`; a wrapper can reset it | None |
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

Other commands:

- `mutineer init [--rails] [--force]`
- `mutineer triage REPORT.json --reason TEXT (--id ID ... | --all)`
- `mutineer migrate <source...> [--dry-run] [--operators LIST]`

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

Coverage uses a digest-keyed cache at `.mutineer/coverage.json`, rebuilt automatically when sources change.

Add `.mutineer/` and any in-project `--cache-dir` directory to `.gitignore`:

```gitignore
.mutineer/
```

Keep `.mutineer/` ignored: `--test-command` writes locks there beside each source file.
