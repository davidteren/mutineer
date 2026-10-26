# Mutineer and other Ruby mutation-testing tools

Checked on 26 October 2026 against each project's README and RubyGems page.
"Unknown" means the project's README does not say. Apart from mutant, the
newer tools have few users so far, so their claims are self-reported.

| Tool | Frameworks | Rails | Parallel | Changed code only | CI | Licence / cost | Maintenance |
|------|-----------|-------|----------|-------------------|----|----------------|-------------|
| [mutineer](https://github.com/davidteren/mutineer) 1.7.0 | Minitest, RSpec | `--rails`; per-worker DB with `--daemon` (Minitest; SQLite, PostgreSQL, MySQL 8) | Yes; Rails needs `--daemon` | `--since`, `--baseline` | Official GitHub Action | MIT, free | Active (Oct 2026) |
| [mutant](https://github.com/mbj/mutant) 0.17.1 | RSpec, Minitest, Test::Unit | Yes; per-worker DB for PostgreSQL and SQLite | Yes | Incremental mode | Documented CI use | Free for open source; commercial $30/month or $250/year per developer | Active (Oct 2026) |
| [evilution](https://github.com/marinazzio/evilution) 1.5.1 | RSpec, Minitest, Test::Unit | Yes (fork and preload) | `--jobs` (default 1) | `--incremental` cache | Unknown | MIT, free | Active (Oct 2026) |
| [kimera](https://github.com/giacope/kimera) 0.1.6 | Minitest, RSpec | Yes; per-worker DBs, `--isolate-db` | Yes | `--since`, `kimera changed` | GitHub Actions recipe | MIT, free | Active, new |
| [henitai](https://github.com/martinotten/henitai) 0.6.0 | RSpec; Minitest partial | Per-worker DB via a config hook | `--jobs`, opt-in | `--since`, `--incremental` | GitHub Actions annotations | MIT, free | Active, new |
| [saboteur](https://github.com/vamsipavanmahesh/saboteur) 0.12.3 | RSpec only | Rails generator | Parallel coverage builds | `--since`, `--incremental` | Installs GitHub workflows | MIT, free | Active, new |
| [mutation_tester](https://github.com/Oxyconit/mutation_tester) 1.7.0 | RSpec 3, Minitest 5/6 | Rake tasks | Yes, all cores | `--since` (files) | Unknown | MIT, free | Active (Sep 2026) |
| [mutaruby](https://github.com/Atlas-Authorization/mutaruby) 0.3.0 | Any test command | Through the test command | Yes | `--since` (files) | GitHub Actions example | MIT, free | Active, new |
| [mutato](https://github.com/LQkkeN/mutato) 0.2.1 | RSpec, Minitest | Unknown | Unknown | Unknown | Unknown | MIT, free | Active, new |
| [mutateRB](https://github.com/MarceloM47/mutateRB) 0.3.1 | RSpec, Minitest | Unknown | Unknown | Unknown | Unknown | MIT, free | Small (Sep 2026) |
| [crispr](https://github.com/afstanton/crispr) 0.2.2 | Unknown | Unknown | Unknown | Unknown | Unknown | MIT, free | Last gem Jul 2025 |
| [mutest](https://github.com/backus/mutest) 0.0.10 | Unknown (mutant fork) | Unknown | Unknown | Unknown | Unknown | MIT | Archived; last gem 2019 |
| [heckle](https://github.com/seattlerb/heckle) 1.4.3 | Test::Unit era | No | No | No | No | None declared | Last gem 2009 |

## Why Mutineer

mutant is the most mature tool and covers more frameworks, but a private or
commercial app has to pay for it. Mutineer is MIT and free for every use, has
no runtime gem dependencies, and ships an official GitHub Action that tests
only a pull request's changed lines and fails only on new survivors. It gives
each parallel Rails worker its own test database, including MySQL 8. Its
limits: it needs Ruby 3.4 or later (older apps use the serial
`--test-command` path), and RSpec cannot use `--daemon`, so RSpec Rails runs
are serial.

## Does Mutineer fit my app?

Paste this prompt into your coding agent at the root of your app:

```text
Check whether the Mutineer gem (https://github.com/davidteren/mutineer) suits this Ruby app. Read files only; install or change nothing. Answer each check with the evidence (file and line).

1. Ruby: read .ruby-version, Gemfile and Gemfile.lock. Mutineer needs Ruby 3.4 or later. On an older Ruby it can still run with --test-command, but serially and with no coverage narrowing.
2. OS for CI and development: Linux or macOS is required (it forks). Windows is not supported.
3. Test framework: Minitest (test/**/*_test.rb) or RSpec (spec/**/*_spec.rb). Both work. With RSpec: no --daemon, so Rails runs are serial, and a spec that fails on a database connection error counts as killed (issue #347).
4. Rails: is it a Rails app (config/application.rb)? Note the Rails version. If config/database.yml has several databases, note that --daemon isolates only the primary.
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
- A first command, e.g. RAILS_ENV=test bundle exec mutineer run app/models/<small_file>.rb --rails --dry-run (add --daemon for Minitest with a supported database).
- Next steps: add gem "mutineer", group: :test, require: false; run mutineer init --rails; fix or ignore one file's survivors; save a full --format json baseline on main; add the GitHub Action so pull requests are checked only on changed lines.
Do not guess. Mark anything you could not verify as UNKNOWN.
```
