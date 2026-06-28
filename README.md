# Mutineer

A clean-room mutation-testing tool for Ruby. Mutineer mutates your source one
change at a time, runs your Minitest suite against each mutant, and reports the
ones your tests failed to catch — the gaps where your suite isn't actually
testing anything.

- **Prism + stdlib only** — zero runtime dependencies (Ruby ≥ 3.4).
- **One mutation per mutant**, validity-checked by re-parsing.
- **Fork-isolated**, parallel execution (Linux + macOS).
- **Coverage-guided** — each mutant runs only the test files that cover its line.

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
mutineer run <source...> --test <test...> [options]
```

Mutate `lib/calculator.rb`, checking it against its test, and fail CI if the
mutation score drops below 90%:

```sh
mutineer run lib/calculator.rb --test test/calculator_test.rb --threshold 90
```

### Options

| Flag | Meaning |
|------|---------|
| `--test FILE` | Test file covering the sources (repeatable) |
| `--operators LIST` | Comma-separated operator names (default: the Tier-1 set) |
| `--threshold FLOAT` | Exit 1 when the score is below FLOAT (default: 0 = off) |
| `--only NAME` | Restrict to one fully-qualified subject, e.g. `Calculator#add` |
| `--jobs N` | Parallel worker count (default: processor count) |
| `--strategy NAME` | Mutation application: `reload` whole-file (default) or `redefine` surgical (`7a`/`7b` accepted as deprecated aliases) |
| `--format human\|json` | Report format (default: human) |
| `--output FILE` | Write the report to FILE instead of stdout |
| `--dry-run` | List candidate mutations without executing |
| `--list-operators` | List available operators (default vs optional) and exit |
| `--version`, `--help` | Print version / usage and exit |

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Score ≥ threshold (or no threshold set) |
| `1` | Survivors below threshold, or a runtime error |
| `2` | Usage / invalid-flag error |

### Operators

Run `mutineer --list-operators` to see them. Default (Tier 1): `arithmetic`,
`comparison`, `boolean_connector`, `boolean_literal`, `statement_removal`.
Available but off by default (Tier 2, enable via `--operators`): `return_nil`,
`literal_mutation`, `condition_negation`.

## Configuration

Mutineer reads an optional `.mutineer.yml` from the project root (nearest one,
walking up). CLI flags override config; config overrides defaults.

Sources are positional CLI arguments and test files come from `--test`; the
config file accepts these keys: `operators`, `threshold`, `jobs`, `only`, and
`require` (extra files to load before mutating).

```yaml
# .mutineer.yml
operators: [arithmetic, comparison, boolean_connector, boolean_literal, statement_removal]
threshold: 90
jobs: 4
require:
  - config/environment
```

Coverage results are cached in `.mutineer/coverage.json` (digest-keyed; rebuilt
automatically when sources change). Add `.mutineer/` to your `.gitignore`.

## License

MIT — see [LICENSE](LICENSE).
