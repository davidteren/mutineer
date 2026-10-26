# First run to steady state

This guide takes a Rails app from its first Mutineer run to a CI check that
tests only new and changed code. For a plain Ruby project, drop `--rails` and
`RAILS_ENV=test`.

## 1. Install

Mutineer needs Ruby 3.4 or later on Linux or macOS. Add it to the Gemfile and
run `bundle install`:

```ruby
gem "mutineer", group: :test, require: false
```

Then write a starter `.mutineer.yml`:

```sh
RAILS_ENV=test bundle exec mutineer init --rails
```

Your suite must pass before you start. Mutineer checks the unchanged code
first and stops if a test fails.

## 2. First run on one file

Pick one small model with passing tests. See how many mutants it has first:

```sh
RAILS_ENV=test bundle exec mutineer run app/models/order.rb --rails --dry-run
RAILS_ENV=test bundle exec mutineer run app/models/order.rb --rails
```

You can leave out `--test`. Mutineer pairs `app/models/order.rb` with
`test/models/order_test.rb` or `spec/models/order_spec.rb`. Pass
`--test FILE` (once per file) to choose the tests yourself.

## 3. Read the report

The score is `killed / (killed + survived)`.

- **Killed:** a test failed against the change. Good.
- **Survived:** every test passed. Read the diff under Surviving Mutants.
- **No coverage:** no test runs that line. Write a test first.
- **Timeout, errored, ignored, skipped:** not in the score.

## 4. Fix survivors

For each survivor, ask what behaviour the change breaks. Write a test that
passes on the original code and fails on the change, then run again.

Sometimes no test can tell the difference (for example `x * 1` and `x / 1`).
That mutant is equivalent. Record it with a reason:

```sh
bundle exec mutineer run app/models/order.rb --rails --format json --output report.json
bundle exec mutineer triage report.json --reason "x / 1 equals x * 1 here" --id ID
```

`triage` prints `ignore:` entries. Paste them into `.mutineer.yml`.

## 5. Widen the run

Run a folder, such as `app/models`. With Minitest and a SQLite file,
PostgreSQL, or MySQL 8 test database, add `--daemon` to use every CPU:

```sh
RAILS_ENV=test bundle exec mutineer run app/models --rails --daemon
```

RSpec runs under `--rails` are serial, one mutant at a time.

## 6. Make a baseline

On `main`, run a full scan and save the JSON report:

```sh
RAILS_ENV=test bundle exec mutineer run app/models --rails --no-since --no-fail-fast \
  --format json --output .mutineer/baseline.json
```

Commit the file (keep the rest of `.mutineer/` ignored), or store it as a CI
artifact. Use the same sources, tests, and operators in the gate.

## 7. Check only new and changed code in CI

```yaml
- uses: actions/checkout@v4
  with: { fetch-depth: 0 }
- uses: ruby/setup-ruby@v1
  with: { bundler-cache: true }
- uses: davidteren/mutineer@v1
  env:
    RAILS_ENV: test
  with:
    sources: app/models
    rails: "true"
    use-bundler: "true"
    baseline: .mutineer/baseline.json
    extra-args: "--no-fail-fast"
```

On `pull_request` events the Action tests only the lines the PR changed. The job
fails only when the PR adds a new survivor.

## 8. Steady state

- A scheduled job on `main` with `since: none` refreshes the baseline.
- Raise `threshold` as the score climbs.
- Every flag and default: [CLI reference](cli.md).
