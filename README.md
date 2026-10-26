# Mutineer

[![Gem Version](https://img.shields.io/gem/v/mutineer?logo=rubygems&color=e23b3b)](https://rubygems.org/gems/mutineer)
[![CI](https://github.com/davidteren/mutineer/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/davidteren/mutineer/actions/workflows/ci.yml)
[![mutation score at least 85%](https://img.shields.io/badge/mutation%20score-at%20least%2085%25-67286a)](https://github.com/davidteren/mutineer/actions/workflows/ci.yml)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Mutineer%20Ruby-2da44e?logo=githubactions&logoColor=white)](https://github.com/marketplace/actions/mutineer-ruby)
[![Socket](https://img.shields.io/badge/Socket-security%20report-0a66c2?logo=socket&logoColor=white)](https://socket.dev/rubygems/package/mutineer)

**Find bugs your tests would miss.** Mutineer changes your Ruby code and runs your Minitest or RSpec tests.
Changes that still pass reveal possible test gaps. This is **mutation testing**.

**Features**

- **Minitest and RSpec.** Detected from test filenames; override with `--framework`.
- **Rails support.** `--rails` boots once. With `--daemon`, each Minitest worker gets its own SQLite file, PostgreSQL, or MySQL 8 test database.
- **Focused tests.** Runs tests that reach each changed line, likely and fast tests first. Stops at the first failure.
- **PR checks.** `--since origin/main` checks changed lines; `--baseline` gates new survivors and score drops.
- **CI and agents.** GitHub Action, versioned JSON, stable mutant ids, clear exit codes, and zero runtime gem dependencies.

📖 **[davidteren.github.io/mutineer →](https://davidteren.github.io/mutineer/)**: overview, operators, and usage.

## Is it production-ready?

Check your database and framework before adding a CI gate.
Mutineer requires Ruby 3.4 or later. In-process runs require Linux or macOS for forks.
Plain Ruby projects without databases support parallel runs.
In the Status column, `supported` means parallel runs work and `serial only` runs one mutant at a time.

<!-- contract:support-matrix -->
| Ruby | Database | Framework | Parallelism | Status |
| --- | --- | --- | --- | --- |
| 3.4 or later | SQLite file | Minitest | supported with `--daemon` | supported |
| 3.4 or later | SQLite file | RSpec | not supported | serial only |
| 3.4 or later | PostgreSQL | Minitest | supported with `--daemon` | supported |
| 3.4 or later | PostgreSQL | RSpec | not supported | serial only |
| 3.4 or later | MySQL 8 | Minitest | supported with `--daemon` | supported |
| 3.4 or later | MySQL 8 | RSpec | not supported | serial only |
| 3.4 or later | MariaDB | Minitest | not tested | not tested |
| 3.4 or later | MySQL 9 or later | Minitest | not tested | not tested |
| 3.4 or later | SQLite in memory | Minitest | not supported | serial only |
| 3.4 or later | SQLite in memory | RSpec | not supported | serial only |
| 3.4 or later | more than one database | Minitest | one worker | serial only |
| 3.4 or later | more than one database | RSpec | not supported | serial only |

This matrix is for a Rails app on Ruby 3.4 or later. A plain Ruby project
with no database runs in parallel with either framework.
`not supported` means `--daemon` cannot run that cell; `not tested` means no CI
job runs it. SQLite file means a database file, not `:memory:`.

- `--rails` without `--daemon` is serial on every row. `--daemon` is Minitest only.
- MySQL older than 8.0 stops `--daemon`. MariaDB and MySQL 9 or later warn and run.
- An app with more than one database runs one worker: `--daemon` isolates only the primary connection.
- Postgres worker databases are copied once at the start; MySQL 8 worker databases are created then and the rows copied.
- A test that commits rows outside a transaction leaves them in that worker's
  database, and the next mutant on that worker sees them. Rails parallel tests have the same limit.
- RSpec: an example that fails with a database connection error scores
  `killed`, not `errored`, so the score can read too high
  ([#347](https://github.com/davidteren/mutineer/issues/347)).

Mutineer sets `PARALLEL_WORKERS=1`, so a `parallelize` call in `test_helper.rb` starts no Rails workers during a mutant run.
See [Rails parallel tests, Spring, Bootsnap, and Redis](https://github.com/davidteren/mutineer/blob/main/docs/rails-setup.md#rails-parallel-tests-spring-bootsnap-and-redis).

<!-- /contract:support-matrix -->

Older Ruby apps use `--test-command`; Mutineer still requires Ruby 3.4 or later.
This path runs serially without coverage-based test selection.

| Subprocess result | Score |
|---|---|
| Exit 1, normally | `killed` |
| SimpleCov gate exit with a failing test | `killed` |
| Other exit code | `error` |
| Crash before a test fails | Can score `error` |
| Only a SimpleCov gate fails, with its gate message and a passing summary | `survived` |

See [Apps on Ruby < 3.4](https://github.com/davidteren/mutineer/blob/main/docs/rails-setup.md#apps-on-ruby--34)
and release guarantees in [STABILITY.md](https://github.com/davidteren/mutineer/blob/main/STABILITY.md).

## What is mutation testing?

Mutation testing changes code to check whether your tests notice.
Each changed copy is a **mutant**, such as replacing `>=` with `>` or `&&` with `||`.

| Result | Meaning |
|---|---|
| **Killed** | A test failed and caught the change. |
| **Survived** | All tests passed. Inspect the change for a test gap. |

### A small example

```ruby
# lib/discount.rb
class Discount
  def rate(qty)
    return 0.1 if qty >= 10
    0
  end
end
```

Tests check quantities 1 and 50: 100% line coverage. Mutineer changes `>=` to `>`; both tests pass:

```text
lib/discount.rb
  Discount#rate (discount.rb:3)
  Operator: comparison  (>= -> >)
  -     return 0.1 if qty >= 10
  +     return 0.1 if qty > 10
```

No test checks exactly 10. Testing 10 kills the mutant. Run the example, tests and report in [Mutation testing, explained](https://davidteren.github.io/mutineer/learn.html).

### Coverage and mutation testing

| Check | What it shows |
|---|---|
| Line coverage | Which lines ran |
| Mutation testing | Whether tests detect changes to those lines |

Tests without assertions add coverage but kill mutants only when changes cause errors.
This gap is common in rushed tests and tests written by AI agents.

## How it works

1. **Parse.** [Prism](https://github.com/ruby/prism), included in Ruby 3.4, parses source files. Mutineer uses only Prism and the standard library.
2. **Mutate.** Operators make one change per mutant. Mutineer parses each result again and skips invalid Ruby.
3. **Map coverage and check unchanged tests.** Each test file runs with coverage to map lines to tests.
   `.mutineer/coverage.json` caches the map; source changes rebuild it. Tests must pass alone and
   together, including with a cached map. A failure stops the run.
4. **Run each mutant in a fork.** The parent loads code once, including the app with `--rails`.
   Children run in parallel on Linux and macOS.
   Each loads the changed file (`reload`) or replaces the changed method (`redefine`).
   Only covering test files run: paired tests first, then fastest to slowest. In-process runs stop at the first failure unless `--matrix` requests every covering test.
5. **Score.** A failing test kills the mutant; all tests passing means it survived.
   Score: `killed / (killed + survived)`.

| Alternative backend | Changes to step 4 |
|---|---|
| `--daemon` | Boots Rails once in a persistent process; isolates each worker's test database |
| `--test-command` | Runs tests in another Ruby subprocess; writes mutants to the real file, then restores it |

| At a glance | |
|---|---|
| Parser | Prism, with no runtime gem dependencies |
| Ruby | 3.4 or later; older apps use `--test-command` |
| Operators | 21 (5 by default, 16 opt-in) |
| Isolation | One fork per mutant on Linux and macOS |
| Report formats | human, JSON (versioned schema), HTML |

## Quick start

Plain Ruby:

```sh
gem install mutineer
mutineer run lib/discount.rb --test test/discount_test.rb
```

Rails: add to your `Gemfile` test group:

```ruby
gem "mutineer", group: :test, require: false
```

Install, create `.mutineer.yml`, and check one model:

```sh
bundle install
RAILS_ENV=test bundle exec mutineer init --rails
RAILS_ENV=test bundle exec mutineer run app/models/order.rb --rails
```

Without `--test`, `app/models/order.rb` pairs with `test/models/order_test.rb` or `spec/models/order_spec.rb`.
See [Quick start](https://github.com/davidteren/mutineer/blob/main/docs/quick-start.md).

## Usage

```sh
mutineer run <source...> [--test <test>...] [options]
mutineer init [--rails] [--force]
mutineer triage REPORT.json --reason TEXT (--id ID ... | --all)
mutineer migrate <source...> [--dry-run] [--operators LIST]
```

### Options

Full flags, defaults, and `.mutineer.yml` keys: [CLI reference](https://github.com/davidteren/mutineer/blob/main/docs/cli.md).

| Flag | Meaning |
|------|---------|
| `--test FILE` | Repeat per test file; omit to pair tests by convention |
| `--threshold FLOAT` | Exit 1 when the score is below FLOAT, or when nothing could be scored and something broke, or more than one mutant produced no verdict and they exceed 10% of those attempted (default: 0 = off) |
| `--since REF` | Mutate only lines changed since git `REF`, such as `origin/main` |
| `--baseline FILE` | Exit 1 for new survivors or score drops against a prior JSON report |
| `--rails` | Boot `config/environment` once; serial without `--daemon` |
| `--[no-]daemon` | Enable or disable daemon; isolated worker databases, Minitest only |
| `--jobs N` | Worker count; default: one per CPU |
| `--format human\|json\|html` | Report format; default: human |
| `--dry-run` | List mutants without running tests |

### Exit codes

<!-- contract:exit-codes -->
| Code | Meaning |
|------|---------|
| `0` | Score ≥ threshold (or no gate) **and** no baseline regression. |
| `1` | Score below `--threshold`, OR nothing could be scored and something broke, or more than one mutant produced no verdict and they exceed 10% of those attempted, OR a `--baseline` regression, OR a runtime error, including a boot, source or `require:` file that raises while loading. |
| `2` | Usage / invalid-flag error, including a mistyped flag, a bad path (such as a missing `--boot` or `require:` file), or an unreadable baseline. |
<!-- /contract:exit-codes -->

### Operators

List with `mutineer --list-operators`. Enable specific operators with `--operators`.

| Group | Operators |
|---|---|
| Tier 1 (default) | `arithmetic`, `comparison`, `boolean_connector`, `boolean_literal`, `statement_removal` |
| Tier 2 (opt-in) | `return_nil`, `literal_mutation`, `condition_negation`, `string_literal`, `regex`, `collection_method`, `safe_navigation`, `range`, `negation_removal`, `chain_link`, `call_to_receiver`, `operand_removal`, `array_literal`, `condition_true`, `condition_false`, `operator_assignment` |

## Documentation

| Guide | What it covers |
|-------|----------------|
| [Quick start](https://github.com/davidteren/mutineer/blob/main/docs/quick-start.md) | Install, run, fix a survivor |
| [First run to steady state](https://github.com/davidteren/mutineer/blob/main/docs/getting-started.md) | One file through changed-code CI |
| [Reading results](https://github.com/davidteren/mutineer/blob/main/docs/results.md) | Reports, survivors, suppression, mutant ids, kill matrix |
| [Rails setup](https://github.com/davidteren/mutineer/blob/main/docs/rails-setup.md) | Rails, daemon, databases, Spring, Bootsnap, Ruby < 3.4 |
| [Rails rollout](https://davidteren.github.io/mutineer/rails.html) | Four stages from model to CI gate |
| [CI: changed code and baselines](https://github.com/davidteren/mutineer/blob/main/docs/ci.md) | `--since`, `--baseline`, Action inputs, timeouts |
| [CLI reference](https://github.com/davidteren/mutineer/blob/main/docs/cli.md) | Flags, defaults, `.mutineer.yml` |
| [Comparison](https://github.com/davidteren/mutineer/blob/main/docs/comparison.md) | Mutineer, Mutant, other Ruby tools, fit-check prompt |
| [AI agents and CI](https://davidteren.github.io/mutineer/agentic-coding.html) | Agent loop and CI recipes |
| [JSON schema](https://davidteren.github.io/mutineer/json-schema.html) | Versioned report contract |
| [STABILITY.md](https://github.com/davidteren/mutineer/blob/main/STABILITY.md) | Release guarantees |

## For AI agents & pipelines

Use versioned JSON, structured exit codes, and runs scoped to changed lines.
[mutant ids](https://github.com/davidteren/mutineer/blob/main/docs/results.md#mutant-ids) survive unrelated edits.

| Resource | Links and use |
|---|---|
| AI agents & CI recipes | [rendered](https://davidteren.github.io/mutineer/agentic-coding.html) · [source](https://davidteren.github.io/mutineer/agentic-coding.md): agent loops, CI gates, avoiding equivalent-mutant loops |
| JSON schema reference | [rendered](https://davidteren.github.io/mutineer/json-schema.html) · [source](https://davidteren.github.io/mutineer/json-schema.md): `--format json` schema and versioning |
| Ruby API (YARD) | [https://davidteren.github.io/mutineer/api/](https://davidteren.github.io/mutineer/api/): shipped classes |
| Agent skill | [`skills/mutineer/SKILL.md`](https://github.com/davidteren/mutineer/blob/main/skills/mutineer/SKILL.md): installation, agent loop, exit codes |

Install the skill with either command:

- `gh skill install davidteren/mutineer mutineer`
- `npx skills add davidteren/mutineer --skill mutineer`

**Mutineer 1.8.0 and later** bundle the skill and offer
[ Rails Hyperdrive](https://github.com/rails-hyperdrive/rails-hyperdrive) companion installation.
For Rails apps bundling Mutineer, `bin/rails hyperdrive:init` installs it to `.claude/skills/mutineer/SKILL.md`.

## License

MIT. See [LICENSE](https://github.com/davidteren/mutineer/blob/main/LICENSE).

Editing only: commands and release claims were not checked; their current accuracy remains unverified.