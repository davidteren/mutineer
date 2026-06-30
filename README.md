# Mutineer

[![Gem Version](https://img.shields.io/gem/v/mutineer?logo=rubygems&color=e23b3b)](https://rubygems.org/gems/mutineer)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Mutineer%20Ruby-2da44e?logo=githubactions&logoColor=white)](https://github.com/marketplace/actions/mutineer-ruby)
[![Socket Badge](https://badge.socket.dev/rubygems/package/mutineer/0.7.0?platform=ruby)](https://socket.dev/rubygems/package/mutineer/overview/0.7.0?platform=ruby)

A clean-room mutation-testing tool for Ruby. Mutineer mutates your source one
change at a time, runs your test suite (Minitest or RSpec) against each mutant, and reports the
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
| `--framework NAME` | `minitest` (default) or `rspec`; auto-detected as rspec when most `--test` files end in `_spec.rb` |
| `--since REF` | Only mutate lines changed since git `REF` (e.g. `origin/main`) — ideal for PR CI |
| `--baseline FILE` | Compare against a prior `--format json` run; exit 1 on new survivors / score drop (see [CI](#ci-gating)) |
| `--baseline-epsilon FLOAT` | Score-drop tolerance for `--baseline` (default: 0) |
| `--jobs N` | Parallel worker count (default: processor count; `1` under `--rails`) |
| `--verbose` | Surface the real error when a fork capture fails (alias `--debug`) |
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

## Rails apps

Rails code needs its environment booted before the suite runs, so point Mutineer
at your app with `--rails` and run it inside the project's bundle:

```sh
RAILS_ENV=test bundle exec mutineer run \
  app/models/order.rb --test test/models/order_test.rb --rails
```

`--rails` boots `config/environment` once in the parent process (every mutant
then forks and inherits it), defaults `--strategy` to `redefine` (surgical — it
avoids reloading files into the app tree), and reconnects ActiveRecord in each
fork so the database connection is fork-safe. Use `--boot FILE` to boot a
different entry point. Boot mode requires at least one `--test` file and is
coverage-guided — each mutant runs only the test files that exercise its line
(coverage is captured by forking the booted app, then cached).

Add Mutineer to your Gemfile's test group:

```ruby
gem "mutineer", group: :test, require: false
```

## Suppressing equivalent mutants

Some mutants are equivalent (behaviour-identical) and survive forever — keeping a
file off 100%. Suppress them so the score and `--threshold` gate stay meaningful:

- **Inline:** `some_line # mutineer:disable-line` (or scope it: `# mutineer:disable-line comparison`).
- **Config:** a `.mutineer.yml` `ignore:` list of stable mutant ids. Each survivor's
  `id` is printed in the JSON report, so copy it straight into `ignore:`.

Suppressed mutants are excluded from the score (so 100% becomes reachable).

## CI gating

Store a JSON run as a baseline, then fail the build only when a PR makes things
worse:

```sh
mutineer run app/ --baseline .mutineer/baseline.json   # exit 1 on NEW survivors or a score drop
```

`--baseline` reports which survivors are new (by stable id) and any score drop. It
combines with `--threshold` (the worse of the two sets the exit code). Pass a
directory (or several sources) to audit a whole layer in one boot — tests are
auto-paired by convention and the report breaks down per source.

### GitHub Action

This repo ships a composite action (`action.yml`) that wraps the CLI for CI:

```yaml
- uses: actions/checkout@v4
  with: { fetch-depth: 0 }        # --since needs full history
- uses: ruby/setup-ruby@v1
  with: { ruby-version: "3.4", bundler-cache: true }
- uses: davidteren/mutineer@v0
  with:
    sources: app/
    since: origin/${{ github.base_ref }}
    baseline: .mutineer/baseline.json
    threshold: "90"
```

## For AI agents & pipelines

Mutineer is built for programmatic use — versioned JSON, stable mutant ids,
structured exit codes, and diff-scoped runs. See:

- **AI agents & CI recipes** — the agent inner-loop and CI-gate recipes (and how
  to avoid infinite loops on equivalent mutants):
  [rendered](https://davidteren.github.io/mutineer/agentic-coding.html) ·
  [source](docs/agentic-coding.md)
- **JSON schema reference** — the `--format json` schema and its versioning
  contract:
  [rendered](https://davidteren.github.io/mutineer/json-schema.html) ·
  [source](docs/json-schema.md)

## Configuration

Mutineer reads an optional `.mutineer.yml` from the project root (nearest one,
walking up). CLI flags override config; config overrides defaults.

Sources are positional CLI arguments and test files come from `--test`; the
config file accepts these keys: `operators`, `threshold`, `jobs`, `only`,
`require` (extra files to load before mutating), and `boot`/`rails`.

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
