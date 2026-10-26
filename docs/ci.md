# CI: changed code and baselines

Use changed lines for faster CI checks and a saved baseline to catch regressions.

| Check | Behaviour |
|-------|-----------|
| Changed code | `--since REF` mutates lines changed since a Git ref. The GitHub Action defaults to the PR base. |
| Baseline | `--baseline FILE` compares a saved JSON report and fails on new survivors. A full run (`--no-since` or `since: none`) also fails on a score drop. |

## Changed code only

```sh
bundle exec mutineer run lib --since origin/main
```

Untracked files are scored in full unless Git ignores them. Override `.mutineer.yml`’s `since:` for one run:

```sh
bundle exec mutineer run lib --no-since
```

## Baseline

Leave `only:` and `baseline:` unset in `.mutineer.yml` when you create or refresh the baseline; pass the baseline only to the PR gate. Create and refresh the saved JSON report with the [full-run baseline recipe](https://davidteren.github.io/mutineer/agentic-coding.html#ci-gate).
Use the gate’s sources, test files and operators.

```sh
mutineer run app/ --no-since --no-fail-fast --baseline .mutineer/baseline.json   # exit 1 on NEW survivors or a score drop
```

`--baseline` reports new survivors by [mutant id](https://github.com/davidteren/mutineer/blob/main/docs/results.md#mutant-ids). It checks score drops only on full runs; a `--since` run skips that check.
With `--threshold`, the worse result sets the exit code.

Directories or multiple sources run in one boot, with results per source. Tests pair by convention:

| Source or condition | Pairing |
|---------------------|---------|
| `app/foo/bar.rb` | `test/foo/bar_test.rb` and unclaimed `test/foo/bar_*_test.rb`, such as `bar_upsert_test.rb` |
| `user_session.rb` exists beside `user_session_test.rb` | The test stays with `user_session.rb` |
| `bar_upsert.rb` exists | `bar_upsert_guards_test.rb` stays with `bar_upsert.rb` |
| A spec already pairs | It stays as that one file |

### GitHub Action

The composite action (`action.yml`) runs the CLI:

```yaml
- uses: actions/checkout@v4
- uses: ruby/setup-ruby@v1
  with: { ruby-version: "3.4", bundler-cache: true }
- uses: davidteren/mutineer@v1
  with:
    sources: lib/
    baseline: .mutineer/baseline.json
    extra-args: "--no-fail-fast"
    threshold: "90"
```

On `pull_request` this checks changed lines only. A changed-lines run cannot see a weakened test on unchanged code, so set `since: none` for any pull request that changes tests.

Rails needs `mutineer` in the Gemfile, `rails: true` and `use-bundler: true`.
Without these inputs, the Action runs a standalone gem without booting your app.

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

**Default change:** `pull_request` events use changed lines against the exact PR base commit. This excludes `pull_request_target`.
The Action fetches the commit for shallow checkouts, falling back to the base branch tip.

| `since` | Scope |
|---------|-------|
| Default on `pull_request` | Changed lines |
| `none` | Full scan |
| Explicit ref | Changed lines against that ref; the ref must be in the checkout (fetch it, or use `fetch-depth: 0`) |

| Default JSON output | Result |
|---------------------|--------|
| Step summary | Score summary |
| PR diff annotations | Up to 50 survivors; `error` when the gate fails, `warning` when it passes |
| `report` output | Report path; `human` and `html` formats require the `output` input |

The CLI logs progress every 10%, in every format.

### Rails with PostgreSQL

Before Mutineer boots Rails, add a database service, set `DATABASE_URL` and prepare the schema:

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
```

### Action inputs

From [`action.yml`](https://github.com/davidteren/mutineer/blob/main/action.yml):

| Input | Default | What it does |
|-------|---------|--------------|
| `sources` | required | Space-separated files or directories |
| `test` | `""` | Test files; empty pairs by convention |
| `since` | `""` | Git ref; PR base on `pull_request`; `none` scans all |
| `threshold` | `""` | Fail below this score |
| `baseline` | `""` | Saved `--format json` report |
| `baseline-epsilon` | `""` | Allowed score drop; CLI default 0 |
| `operators` | `""` | Comma-separated operators; empty uses Tier-1 (default set) |
| `framework` | `""` | `minitest` or `rspec`; empty auto-detects |
| `strategy` | `""` | `reload` or `redefine` |
| `jobs` | `""` | Parallel workers; empty uses CPU count. `rails` without `--daemon`, `--fail-fast` and `--test-command` force one worker |
| `rails` | `"false"` | Boot `config/environment` |
| `format` | `"json"` | `human`, `json`, or `html`; JSON enables summaries and annotations |
| `output` | `""` | Report path; cannot be the baseline file |
| `extra-args` | `""` | Appended flags, such as `--daemon` |
| `working-directory` | `"."` | Project root |
| `use-bundler` | `"false"` | Run `bundle exec mutineer`; required for `rails: true` |
| `version` | `""` | Gem version without Bundler; empty uses latest |

## Refresh the baseline

Schedule a full scan on `main`. The PR gate reads the committed `.mutineer/baseline.json`, so the refresh ends with a manual step: download the artifact, check that `summary.score` is not null and `no_verdict` is empty, then commit it as `.mutineer/baseline.json` in a pull request.
Never overwrite the baseline read by the same step.

```yaml
name: Mutineer baseline
on:
  schedule:
    - cron: "0 3 * * 1"
  workflow_dispatch:

jobs:
  baseline:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { bundler-cache: true }
      # A database-backed app also needs the database service, DATABASE_URL and
      # `bin/rails db:prepare` steps from the PostgreSQL recipe above.
      - uses: davidteren/mutineer@v1
        env:
          RAILS_ENV: test
        with:
          sources: app/models
          since: none
          rails: "true"
          use-bundler: "true"
          extra-args: "--no-fail-fast"
          output: mutineer-baseline.json
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: mutineer-baseline
          path: mutineer-baseline.json
```

More recipes, including GitLab CI: [Rails rollout guide](rails.md) and [AI agents and CI](agentic-coding.md).

**Prompt for your coding agent**

```text
Set up Mutineer in CI for this repo. 1) On main, run a full scan with --no-since --no-fail-fast --format json --output .mutineer/baseline.json. Check that summary.score is not null and no_verdict is empty, then commit the file (git add -f if .mutineer/ is ignored). 2) Add a pull_request workflow using davidteren/mutineer@v1 with sources set to our main code folder, the baseline input pointing at .mutineer/baseline.json, and extra-args "--no-fail-fast" (for Rails also rails: "true" and use-bundler: "true", plus the database setup from our test workflow); use since: none when a pull request changes tests. 3) Add a scheduled workflow on main that runs a full scan with since: none and uploads the JSON report as an artifact. Never write the report onto the baseline file in the same step.
```

## Timeouts and the score

The score is `killed / (killed + survived)`.

| Rule | Behaviour |
|------|-----------|
| In-process tests exceed `--timeout` | The mutant receives `timeout`, neither killed nor survived. `--timeout` does not apply to `--daemon` or `--test-command` |
| Score exclusions | `timeout`, `no_coverage`, `uncapturable`, `unplaceable`, `ran_at_load`, `errored`, skipped and ignored mutants |
| Timeout counts | Human report: `Timeout:`; JSON: `summary.timeout` |
| `--threshold` failure | Exit 1 when multiple mutants lack verdicts and exceed 10% of attempted mutants |
| Nothing scored | Exit 1 under `--threshold` when something broke |

Timeouts cannot distinguish a mutant’s hang from a slow suite, so they never count as kills.
Raise `--timeout` if tests need longer to catch mutants.

A short timeout excludes mutants from the score and can fail the gate.