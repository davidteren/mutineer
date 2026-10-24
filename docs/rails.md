# Rolling out Mutineer on a Rails app

Start with one Rails model, then add checks to CI when you understand the results.
This guide covers four stages. Stop at the stage that fits your team.

`mutineer init --rails` writes `.mutineer.yml` and prints the first run command.
It does not replace a file you already wrote.
Pass `--force` to replace one.

See the [README](https://github.com/davidteren/mutineer#github-action) and
[agent and CI guide](https://davidteren.github.io/mutineer/agentic-coding.html#action) for all Action inputs.

## One model locally

Add `gem "mutineer", group: :test` to your Gemfile and run `bundle install`.
Create the configuration, then run Mutineer on one model and its test:

```sh
RAILS_ENV=test bundle exec mutineer init --rails
RAILS_ENV=test bundle exec mutineer run app/models/order.rb --test test/models/order_test.rb
```

Review each survivor. Add a test for a missed behaviour, or record why the change
is equivalent before ignoring it. Start without a score threshold.

## Report-only in CI

Run Mutineer in CI and keep the report.
Leave the score gate off (`threshold` stays 0).
A red test suite still fails. A surviving mutant does not.

## A pull request gate

Scope the run to the pull request and fail when it adds a survivor.
Use `--since origin/main` and `--baseline`.

`--since` checks the lines the pull request changed.
With `--since`, `--baseline` fails the job only when a new survivor appears.
That run does not check a score drop.
The score drop check is for a full run.
When a pull request changes tests, run a full scan of the chosen sources on that
pull request's commit before merging. Use `--no-since` with `--baseline` to check
for new survivors and a score drop, including in code whose source did not change.
A scheduled scan on the default branch refreshes the baseline; it does not check
the pull request's tests before merge.
For the first baseline and each refresh, follow the [baseline recipe](agentic-coding.md#ci-gate-fail-a-pr-only-when-it-makes-things-worse).
Temporarily remove `baseline:` and `only:` from `.mutineer.yml`, disable
`fail_fast`, write a separate candidate, and review it before replacing the saved
report. Use the same sources as your CI gate (`app/models` in the workflow below),
with the same test files, operators, Rails mode, strategy, daemon setting, and environment. Run the Rails
refresh with `RAILS_ENV=test bundle exec mutineer run app/models --rails` plus
the recipe's remaining flags for the workflow shown below. Pass the same
strategy or daemon options if your workflow changes those defaults. The recipe uses the default cache path;
replace `.mutineer` if your `cache_dir` differs. Restore the settings afterward.

## A threshold on chosen folders

Set `--threshold` on the folders whose score you trust, such as `app/models`.
Leave a new folder at report-only until its score is stable.
Raise the threshold only after the report stays green.

## GitHub Actions

This workflow runs Mutineer on a Rails app. It uses the app’s bundle and
scans all chosen sources on every pull request.

```yaml
name: Mutation testing
"on": pull_request
jobs:
  mutineer:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"
          bundler-cache: true
      - uses: davidteren/mutineer@v1
        with:
          sources: app/models
          since: none
          rails: true
          use-bundler: true
```

For report-only CI, leave `threshold` at 0 and `baseline` unset in both the workflow
and `.mutineer.yml`. To reject new survivors, first save a full run from the default
branch as `.mutineer/baseline.json` and make that file available in CI. Then set
`baseline: .mutineer/baseline.json`. Keep `since: none` to scan all chosen sources
on every pull request, including when only tests change. This avoids a workflow
edit for each PR, but can take longer than a scan of changed source lines. Add a
`threshold` when the chosen folders are ready.

## GitLab CI

This GitLab job reports on Rails models paired with conventionally named tests.
Use a Linux or macOS runner with Ruby 3.4 or later, and prepare the test database
as you do for the test suite.

```yaml
mutineer:
  stage: test
  script:
    - RAILS_ENV=test bundle exec mutineer run app/models --rails --no-since --threshold 0 --format json
```

Models without a conventionally named test are skipped with a warning, even if
other tests cover them. To include a model covered by differently named tests,
pass the relevant test files explicitly. For example:

```sh
RAILS_ENV=test bundle exec mutineer run app/models/order.rb --test test/integration/checkout_test.rb --test test/integration/refunds_test.rb --rails --no-since --threshold 0 --format json
```

Replace these paths with the model and tests in your app.

Leave `baseline` unset in `.mutineer.yml` for report-only CI. For a pull request
check, fetch the target branch before adding `--since origin/main` (replace `main`
with that branch’s name), and supply a baseline from a full run on that branch.
When tests change, keep `--no-since` to check the pull request's full source scope.
Add `--threshold 90` when the chosen folders are ready.

## Parallel tests

Mutineer sets `PARALLEL_WORKERS=1`, so `parallelize` in `test_helper.rb` starts no Rails workers during a mutant run.
A `--test-command` script that sets `PARALLEL_WORKERS` again turns the workers back on.
Details: [Rails parallel tests, Spring, Bootsnap, and Redis](https://github.com/davidteren/mutineer#rails-parallel-tests-spring-bootsnap-and-redis).

## Daemon

`--daemon` gives each worker its own test database.
It works with Minitest on a SQLite file, PostgreSQL, or MySQL 8 (`mysql2` or `trilogy`).
MariaDB is not tested. MySQL 5.7 is not supported.
An app with more than one database runs one worker.
On another adapter, `--daemon` stops the run with an error before it scores any mutant.
The [support matrix](https://github.com/davidteren/mutineer#is-it-production-ready) lists each case.
Leave `daemon` commented in `.mutineer.yml` until that matrix says your app fits.
Run without the daemon to stay serial on other adapters.
