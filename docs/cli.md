# CLI reference

Every `mutineer run` flag, what it does, and its default. Source of truth:
`lib/mutineer/cli.rb` (the option parser) and `lib/mutineer/config.rb`
(defaults). Typed flags beat `.mutineer.yml`; the file beats the defaults.
A `--[no-]` flag also takes the `--no-` form, which beats a key in the file.

| Flag | What it does | Default |
|------|--------------|---------|
| `--test FILE` | Test file for the sources; repeat it per file | Each source is paired with its test by convention |
| `--framework minitest\|rspec` | Test framework | `rspec` when most test files end in `_spec.rb`, else `minitest` |
| `--operators LIST` | Comma-separated operator names | The Tier-1 set (`mutineer --list-operators`) |
| `--only NAME` | Mutate one subject, such as `Calculator#add` | All subjects |
| `--since REF` / `--no-since` | Mutate only lines changed since git `REF` | Off |
| `--threshold FLOAT` | Exit 1 below this score (0–100), or when too many mutants could not be judged | `0` (off) |
| `--baseline FILE` | Exit 1 on new survivors or a score drop versus a prior `--format json` report | None |
| `--baseline-epsilon FLOAT` | Allowed score drop for `--baseline` (CLI only) | `0` |
| `--jobs N` | Parallel workers | One per CPU; `1` under `--rails` without `--daemon`, `--test-command`, or `--fail-fast` |
| `--rails` | Boot `config/environment` once and reconnect Active Record per fork | Off |
| `--boot FILE` | Require an app entry point once before forking | None |
| `--[no-]daemon` | Boot the app once in a daemon; each worker gets its own test database (Minitest only; needs `--rails` or `--boot`) | Off |
| `--strategy reload\|redefine` | Reload the whole file, or redefine only the mutated method | `reload`; `redefine` under `--rails` without `--daemon` |
| `--test-command CMD` | Run the tests as a subprocess in another Ruby; `CMD` contains `%{files}` | None |
| `--timeout SECONDS` | Per-mutant time limit (in-process runs) | `10` |
| `--capture-timeout SECONDS` | Limit for coverage capture and the clean run | `120` |
| `--cache-dir DIR` | Coverage cache directory | `.mutineer` |
| `--coverage-from FILE` | Reuse an earlier run's `coverage.json` (CLI only) | None |
| `--format human\|json\|html` | Report format (CLI only) | `human` |
| `--output FILE` | Write the report to a file | stdout |
| `--dry-run` | List the mutants; run no tests | Off |
| `--[no-]fail-fast` | Stop at the first survivor | Off |
| `--[no-]matrix` | Run every covering test; report blind and redundant tests (in-process only) | Off |
| `--[no-]allow-empty` | Do not warn when a run has no mutants | Off |
| `--verbose` (alias `--debug`) | Full error details | Off |
| `--list-operators`, `--version`, `--help` | Print and exit | |

Other commands: `mutineer init [--rails] [--force]`,
`mutineer triage REPORT.json --reason TEXT (--id ID ... | --all)`, and
`mutineer migrate <source...> [--dry-run] [--operators LIST]`.
Exit codes: see the [README](https://github.com/davidteren/mutineer#exit-codes).
