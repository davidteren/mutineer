# Rolling out Mutineer on a Rails app

A Rails team can go from install to a first report with one command.
This page is the path from that report to a CI gate.
Stop at any stage. The next stage can wait.

`mutineer init --rails` writes `.mutineer.yml` and prints the first run command.
It does not replace a file you already wrote.
Pass `--force` to replace one.

The full Action recipes stay in the [README](https://github.com/davidteren/mutineer#github-action)
and in the [agent and CI guide](https://davidteren.github.io/mutineer/agentic-coding.html#action).
This page links to them. It does not copy them.

## One model locally

Add Mutineer to the test group. Run init. Then run the printed command on one model.

```sh
RAILS_ENV=test bundle exec mutineer init --rails
RAILS_ENV=test bundle exec mutineer run app/models/order.rb --test test/models/order_test.rb
```

Read the report. Fix or suppress the survivors you accept.
Do not turn on a failing gate yet.

## Report-only in CI

Run Mutineer in CI and keep the report.
Leave the score gate off (`threshold` stays 0).
A red test suite still fails. A surviving mutant does not.

## A pull request gate

Scope the run to the pull request and fail when it adds a survivor.
Use `--since origin/main` and `--baseline`.

`--since` checks the lines the pull request changed.
`--baseline` fails the job when a new survivor appears, or when the score drops.
Keep a full scan on the default branch so a test-only change cannot hide a weaker suite.

## A threshold on chosen folders

Set `--threshold` on the folders whose score you trust, such as `app/models`.
Leave a new folder at report-only until its score is stable.
Raise the threshold only after the report stays green.

## GitHub Actions

Use the Mutineer Action. The steps below are the Rails shape.
The README and the agent guide hold the rest of the inputs.

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
          rails: true
          use-bundler: true
```

For the report-only stage, omit `threshold` and `baseline`.
For the pull request gate, set `since: origin/main` and `baseline: .mutineer/baseline.json`.
For the threshold stage, set `threshold` on the folders you chose.

## GitLab CI

GitLab runs the gem directly. There is no Mutineer Action in this recipe.

```yaml
mutineer:
  stage: test
  script:
    - bundle exec mutineer run app/models lib --since origin/main --baseline .mutineer/baseline.json --format json
```

Drop `--since` and `--baseline` for a report-only job.
Add `--threshold 90` when a folder is ready for a hard gate.

## Daemon

`--daemon` gives each worker its own test database.
SQLite test databases are supported.
Postgres and other adapters are not supported in this version.
On those adapters, `--daemon` scores every mutant as an error.
Leave `daemon` commented in `.mutineer.yml` until this matrix says it fits.
Run without the daemon to stay serial on other adapters.
