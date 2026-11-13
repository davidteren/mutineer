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

`init` leaves an existing `.mutineer.yml` unchanged unless you pass `--force`. Generated config:

```yaml
# Mutineer config. Command-line flags override this file.
# These operators are the default set.
operators:
  - arithmetic
  - comparison
  - boolean_connector
  - boolean_literal
  - statement_removal

# since: origin/main
# Leave this commented so the first run is a full scan.

rails: true

# daemon: true
# Leave this commented until the support matrix says the daemon fits.
# The matrix is on https://davidteren.github.io/mutineer/rails.html#daemon
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

`triage` edits nothing. Paste its output into `.mutineer.yml`.
When the survivor has `copies` in the report, the output includes those ids too.
Paste every entry. An entry ignores only its own id.

```yaml
ignore:
  - id: ID
    reason: x / 1 equals x * 1 for numbers
```

For a coding-agent prompt that fixes each survivor in `report.json`, see [Reading results: what to do with a survivor](results.md#what-to-do-with-a-survivor).

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
ruby -rjson -e 'r = JSON.parse(File.read(".mutineer/baseline.candidate.json")); abort("score is null") if r["summary"]["score"].nil?; abort("no_verdict is not empty") unless r["no_verdict"].empty?; puts "baseline ok"' \
  && cp .mutineer/baseline.candidate.json .mutineer/baseline.json
```

Commit the baseline:

```sh
git add .mutineer/baseline.json
git commit -m "Add Mutineer baseline"
```

Use matching sources, tests, and operators in CI.

## 7. Check only new and changed code in CI

Add `.github/workflows/mutineer.yml` from the [CI guide: Rails workflow](ci.md#rails-workflow).
For PostgreSQL, add the database service, `DATABASE_URL` and the `bin/rails db:prepare` step from [Rails with PostgreSQL](ci.md#rails-with-postgresql).

On `pull_request`, the Action tests changed lines. With `baseline:` set, only new survivors fail.

Changed-lines runs miss weakened tests for unchanged code.
For any PR that changes tests, including one that also changes source, scan fully with `since: none`
(see [Rails rollout: report-only CI](rails.md#report-only-in-ci)).

**Prompt for your coding agent**

```text
Add a GitHub Actions workflow at .github/workflows/mutineer.yml that runs davidteren/mutineer@v1 on pull_request with sources: app/models, rails: "true", use-bundler: "true", baseline: .mutineer/baseline.json and extra-args: "--no-fail-fast". Check out with fetch-depth: 0. Copy the database service and setup steps from the existing test workflow so RAILS_ENV=test can reach the test database. Do not change other workflows.
```

## 8. Steady state

Refresh the baseline on `main` regularly. Raise the threshold as scores improve.
See [CI guide: refresh the baseline](ci.md#refresh-the-baseline).

Flags and defaults: [CLI reference](cli.md).
