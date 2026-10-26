# First run to steady state

Set up Rails mutation testing, then check new and changed code in CI.
For plain Ruby, omit `--rails` and `RAILS_ENV=test`.

## 1. Install

Requires Ruby 3.4 or later on Linux or macOS. Add to your `Gemfile` test group:

```ruby
gem "mutineer", group: :test, require: false
```

Install and create `.mutineer.yml`:

```sh
bundle install
RAILS_ENV=test bundle exec mutineer init --rails
```

Exclude the coverage cache in `.gitignore`, but keep the baseline you add in step 6:

```gitignore
.mutineer/*
!.mutineer/baseline.json
```

Tests must pass. Mutineer checks unchanged code first and stops on failure:

```sh
bin/rails test        # Minitest
bundle exec rspec     # RSpec
```

**Prompt for your coding agent**

```text
Set up Mutineer in this Rails app. Add gem "mutineer", group: :test, require: false to the Gemfile test group, run bundle install, then RAILS_ENV=test bundle exec mutineer init --rails. Add .mutineer/* and !.mutineer/baseline.json to .gitignore. Run the full test suite and report any failures; do not change application code.
```

## 2. First run on one file

Choose a small model with passing tests. Count mutants. With `--rails`, dry runs skip test pairing and require `--test`:

```sh
RAILS_ENV=test bundle exec mutineer run app/models/order.rb --rails --dry-run \
  --test test/models/order_test.rb
```

Run:

```sh
RAILS_ENV=test bundle exec mutineer run app/models/order.rb --rails
```

Mutineer pairs `app/models/order.rb` with `test/models/order_test.rb` or `spec/models/order_spec.rb`.
Override with `--test` per file:

```sh
RAILS_ENV=test bundle exec mutineer run app/models/order.rb --rails \
  --test test/models/order_test.rb --test test/integration/checkout_test.rb
```

## 3. Read the report

Score: `killed / (killed + survived)`.

| Result | Meaning | In the score? |
|--------|---------|---------------|
| Killed | A test failed against the change. | Yes |
| Survived | All tests passed. Read the diff. | Yes |
| No coverage | No test runs this line. Add one. | No |
| Timeout, Errored, Ignored, Skipped | No verdict or deliberately excluded. | No |

See [Reading results](results.md).

## 4. Fix survivors

Add tests that pass on the original code and fail on the mutant. Run again.

Equivalent mutants, such as `x * 1` and `x / 1`, cannot be distinguished by tests.
Generate `ignore:` entries:

```sh
RAILS_ENV=test bundle exec mutineer run app/models/order.rb --rails --format json --output report.json
bundle exec mutineer triage report.json --reason "x / 1 equals x * 1 for numbers" --id ID
```

`triage` edits nothing. Paste its output into `.mutineer.yml`:

```yaml
ignore:
  - id: ID
    reason: x / 1 equals x * 1 for numbers
```

**Prompt for your coding agent**

```text
Run RAILS_ENV=test bundle exec mutineer run app/models/order.rb --rails --format json --output report.json. For each entry in survivors[], read the diff and write a test that passes on the original code and fails on the mutant. Do not edit the source file. If you believe a mutant is equivalent, do not write a test: explain why and propose an ignore: entry with a reason. Re-run Mutineer and report the new score.
```

## 5. Widen the run

Run a folder:

```sh
RAILS_ENV=test bundle exec mutineer run app/models --rails
```

For Minitest with one database (SQLite file, PostgreSQL, or MySQL 8), `--daemon` runs one worker per CPU. An app with more than one database runs one worker. MySQL older than 8.0 stops; MariaDB, MySQL 9 or later, and an unreadable version warn and continue:

```sh
RAILS_ENV=test bundle exec mutineer run app/models --rails --daemon
```

RSpec with `--rails` runs serially. See the [support matrix](https://github.com/davidteren/mutineer#is-it-production-ready).

## 6. Make a baseline

On `main`, with `only:` and `baseline:` unset in `.mutineer.yml`, save a full scan as a candidate:

```sh
RAILS_ENV=test bundle exec mutineer run app/models --rails --no-since --no-fail-fast \
  --format json --output .mutineer/baseline.candidate.json
```

Check the candidate: exit 0, non-null score and empty `no_verdict`. Then copy it to the baseline:

```sh
ruby -rjson -e 'r = JSON.parse(File.read(".mutineer/baseline.candidate.json")); abort("score is null") if r["summary"]["score"].nil?; abort("no_verdict is not empty") unless r["no_verdict"].empty?; puts "baseline ok"'
cp .mutineer/baseline.candidate.json .mutineer/baseline.json
```

Commit the baseline:

```sh
git add .mutineer/baseline.json
git commit -m "Add Mutineer baseline"
```

Use matching sources, tests, and operators in CI.

## 7. Check only new and changed code in CI

Add `.github/workflows/mutineer.yml`:

```yaml
name: Mutineer
on: pull_request

jobs:
  mutineer:
    runs-on: ubuntu-latest
    steps:
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

On `pull_request`, the Action tests changed lines. With `baseline:` set, only new survivors fail.

Changed-lines runs miss weakened tests for unchanged code.
For any PR that changes tests, including one that also changes source, scan fully with `since: none`
(see [Rails rollout: report-only CI](rails.md#report-only-in-ci)).

For PostgreSQL, add a database service and prepare the schema before the Mutineer step.
Match names and versions to your test workflow:

```yaml
jobs:
  mutineer:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: postgres
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready --health-interval 10s
          --health-timeout 5s --health-retries 5
    env:
      RAILS_ENV: test
      DATABASE_URL: postgres://postgres:postgres@localhost:5432/app_test
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: ruby/setup-ruby@v1
        with: { bundler-cache: true }
      - run: bin/rails db:prepare
      - uses: davidteren/mutineer@v1
        with:
          sources: app/models
          rails: "true"
          use-bundler: "true"
          baseline: .mutineer/baseline.json
          extra-args: "--no-fail-fast"
```

More options: [CI guide](ci.md).

**Prompt for your coding agent**

```text
Add a GitHub Actions workflow at .github/workflows/mutineer.yml that runs davidteren/mutineer@v1 on pull_request with sources: app/models, rails: "true", use-bundler: "true", baseline: .mutineer/baseline.json and extra-args: "--no-fail-fast". Check out with fetch-depth: 0. Copy the database service and setup steps from the existing test workflow so RAILS_ENV=test can reach the test database. Do not change other workflows.
```

## 8. Steady state

Refresh the baseline on `main` regularly. Raise the threshold as scores improve.
See [CI guide: refresh the baseline](ci.md#refresh-the-baseline).

Flags and defaults: [CLI reference](cli.md).
