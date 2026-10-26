# Mutineer and other Ruby mutation-testing tools

Compare frameworks, Rails support, CI, and costs. Checked against project READMEs and RubyGems pages on 26 October 2026.

“Unknown” means the README does not say. Apart from mutant, the tools are new and have few users; their claims are self-reported. Prices and features change; check each project's page before you decide.

| Tool | Frameworks | Rails | Parallel | Changed code only | CI | Licence / cost | Maintenance |
|------|-----------|-------|----------|-------------------|----|----------------|-------------|
| [mutineer](https://github.com/davidteren/mutineer) 1.7.0 | Minitest, RSpec | `--rails`; `--daemon` isolates worker DBs (Minitest; SQLite, PostgreSQL, MySQL 8) | Yes; Rails requires `--daemon` | `--since`, `--baseline` | Official GitHub Action | MIT, free | Active (Oct 2026) |
| [mutant](https://github.com/mbj/mutant) 0.17.1 | RSpec, Minitest, Test::Unit | Yes; worker DBs for PostgreSQL, SQLite | Yes | Incremental mode | Documented | Open source: free; commercial: $30/month or $250/year per developer | Active (Oct 2026) |
| [evilution](https://github.com/marinazzio/evilution) 1.5.1 | RSpec, Minitest, Test::Unit | Fork and preload | `--jobs` (default 1) | `--incremental` cache | Unknown | MIT, free | Active (Oct 2026) |
| [kimera](https://github.com/giacope/kimera) 0.1.6 | Minitest, RSpec | Worker DBs, `--isolate-db` | Yes | `--since`, `kimera changed` | GitHub Actions recipe | MIT, free | Active, new |
| [henitai](https://github.com/martinotten/henitai) 0.6.0 | RSpec; partial Minitest | Worker DBs through config hook | `--jobs`, opt-in | `--since`, `--incremental` | GitHub Actions annotations | MIT, free | Active, new |
| [saboteur](https://github.com/vamsipavanmahesh/saboteur) 0.12.3 | RSpec only | Rails generator | Coverage builds | `--since`, `--incremental` | Installs GitHub workflows | MIT, free | Active, new |
| [mutation_tester](https://github.com/Oxyconit/mutation_tester) 1.7.0 | RSpec 3, Minitest 5/6 | Rake tasks | All cores | `--since` (files) | Unknown | MIT, free | Active (Sep 2026) |
| [mutaruby](https://github.com/Atlas-Authorization/mutaruby) 0.3.0 | Any test command | Through test command | Yes | `--since` (files) | GitHub Actions example | MIT, free | Active, new |
| [mutato](https://github.com/LQkkeN/mutato) 0.2.1 | RSpec, Minitest | Unknown | Unknown | Unknown | Unknown | MIT, free | Active, new |
| [mutateRB](https://github.com/MarceloM47/mutateRB) 0.3.1 | RSpec, Minitest | Unknown | Unknown | Unknown | Unknown | MIT, free | Small (Sep 2026) |
| [crispr](https://github.com/afstanton/crispr) 0.2.2 | Unknown | Unknown | Unknown | Unknown | Unknown | MIT, free | Last gem Jul 2025 |
| [mutest](https://github.com/backus/mutest) 0.0.10 | Unknown (mutant fork) | Unknown | Unknown | Unknown | Unknown | MIT | Archived; last gem 2019 |
| [heckle](https://github.com/seattlerb/heckle) 1.4.3 | Test::Unit era | No | No | No | No | None declared | Last gem 2009 |

## Mutineer and Mutant

[Mutant](https://github.com/mbj/mutant), by Markus Schirp, is Ruby's established mutation-testing tool, developed since 2012 and studied in published research. Mutineer was written from scratch under MIT and shares no code with other mutation-testing tools.

| Aspect | Mutineer | Mutant |
|---|---|---|
| License | MIT for all uses | Open source: free (`--usage opensource`); commercial: paid subscription |
| Runtime dependencies | None (Prism + stdlib) | `parser`, `unparser`, `regexp_parser`, `sorbet-runtime`, others |
| Ruby | 3.4+; older apps use `--test-command`: [Apps on Ruby < 3.4](https://github.com/davidteren/mutineer/blob/main/docs/rails-setup.md#apps-on-ruby--34) | 3.3+ |
| Test frameworks | Minitest, RSpec; one gem | RSpec, Minitest, Test::Unit; separate integration gems |
| What you mutate | Files: `mutineer run lib/foo.rb --test test/foo_test.rb`; methods: `--only 'Foo#bar'` | Subject expressions: `mutant run 'Foo#bar'`, `'Foo*'` |
| Which tests run | Files whose coverage reaches the mutated line | Tests declaring the subject through RSpec descriptions or Minitest `cover`, or selected through per-test coverage |
| Operators | 21 (5 by default, 16 opt-in) | A larger set; the default `light` set applies almost all of it (`full` adds `#==` to `#eql?`) |
| CI gating | `--threshold`, `--baseline` deltas, `--since`, GitHub Action | Incremental mode (`--since`), recorded session history |
| Machine-readable output | Versioned JSON report schema | Session JSON schema |

| Choose | When you need |
|---|---|
| Mutineer | MIT, no extra runtime gems, file-based runs, JSON contract for CI gates and AI agents |
| Mutant | More operators, Test::Unit, subject expressions selecting whole namespaces |
| Both | Both tools can run in one project without conflict |

This comparison covers Mutant 0.17.1, checked on 26 October 2026. See [Mutant's README](https://github.com/mbj/mutant#readme) for current licence terms and features.

## Why Mutineer

| Benefit or limit | Detail |
|---|---|
| Cost | MIT, free for every use; mutant charges private or commercial apps |
| Dependencies | No runtime gems |
| GitHub Action | Tests changed pull-request lines; with `baseline:` set, fails on new survivors. A full scan (`since: none`) also fails on score drops |
| Rails isolation | With `--daemon` (Minitest), each parallel worker gets its own test database, including MySQL 8 |
| Ruby | Requires 3.4+; older apps use serial `--test-command` |
| RSpec | No `--daemon`; Rails runs are serial |
| Mutant's strengths | Most mature tool; supports more frameworks |

## Does Mutineer fit my app?

Paste this prompt into your coding agent at your app's root:

```text
Check whether the Mutineer gem (https://github.com/davidteren/mutineer) suits this Ruby app. Read files only; install or change nothing. Answer each check with the evidence (file and line).

1. Ruby: read .ruby-version, Gemfile and Gemfile.lock. Mutineer needs Ruby 3.4 or later. On an older Ruby it can still run with --test-command, but serially and with no coverage narrowing.
2. OS for CI and development: Linux or macOS is required (it forks). Windows is not supported.
3. Test framework: Minitest or RSpec. Inspect the test files and Gemfile; paths such as test/**/*_test.rb, test/**/test_*.rb and spec/**/*_spec.rb are examples. Both work. With RSpec: no --daemon, so Rails runs are serial, and a spec that fails on a database connection error counts as killed (issue #347).
4. Rails: is it a Rails app (config/application.rb)? Note the Rails version. If config/database.yml has several databases, note that an app with more than one database runs one worker, so --daemon gives no parallelism.
5. Test database adapter (config/database.yml, test env):
   - sqlite3 with a file path, postgresql, or mysql2/trilogy on MySQL 8.0: parallel runs work with --daemon (Minitest only).
   - sqlite3 :memory:: serial only.
   - MySQL older than 8.0: --daemon refuses to run.
   - MariaDB or MySQL 9+: not tested; runs with a warning.
   - Any other adapter: --daemon is not supported.
6. Suite shape: does the full suite pass now? Mutineer stops if the unchanged code fails a test. Note slow tests; default limits are 10 s per mutant and 120 s for coverage capture (--timeout, --capture-timeout). Do test files mirror source paths (app/models/x.rb -> test/models/x_test.rb or spec/models/x_spec.rb)? Then --test can be left out. Note tests that commit rows outside a transaction; under --daemon those rows stay in that worker's database.
7. CI: GitHub Actions (.github/workflows)? Then davidteren/mutineer@v1 fits; a Rails app needs rails: true and use-bundler: true and the gem in the Gemfile. Other CI systems can run the CLI with --since origin/main and --baseline.

Then output:
- Verdict: FIT, FIT WITH LIMITS (list them), or NO FIT (give the reason).
- A first command, e.g. RAILS_ENV=test bundle exec mutineer run app/models/<small_file>.rb --rails --dry-run --test test/models/<small_file>_test.rb (a Rails dry run needs --test; add --daemon for Minitest with a supported database).
- Next steps: add gem "mutineer", group: :test, require: false; run mutineer init --rails; fix or ignore one file's survivors; save a full --format json baseline on main with --no-since --no-fail-fast, and with only:, baseline: and fail_fast unset in .mutineer.yml; keep only: and baseline: unset for the PR gate too, and pass the saved report as the Action's baseline input; add the GitHub Action so pull requests are checked on changed lines, and run a full scan (since: none) on any pull request that changes tests.
Do not guess. Mark anything you could not verify as UNKNOWN.
```