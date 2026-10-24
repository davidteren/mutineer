# Mutineer for AI agents & CI pipelines

Line coverage shows which code ran. Mutation testing checks whether tests catch
a change to that code. Use Mutineer to give an AI coding agent concrete test gaps
to review, or to check test quality in CI.

Mutineer provides [JSON reports](./json-schema.md), exit codes, checks on changed
lines (`--since`), a minimum score (`--threshold`), and comparison with a saved
report (`--baseline`). This guide shows how to use them with agents and CI.

## The agent inner loop

An agent can use surviving mutants to find tests that need work. Review each
change against the intended behaviour before asking the agent to add a test:

1. Edit code and tests on a branch. Fetch `origin/main` before using it below.
2. Run Mutineer on the diff, as JSON:

   ```sh
   mutineer run app/ --since origin/main --threshold 90 --format json --output .mutineer/run.json
   ```

3. Parse `survivors[]`. Each entry carries a ready-made `diff` and an `id`. Unrelated edits can preserve the id; file moves, renames, project-root changes, and changes to repeated-name or repeated-mutation order can change it. See [Mutant ids](https://github.com/davidteren/mutineer#mutant-ids). For each survivor, feed
   the agent a prompt like:

   > This change to `{subject}` (`{file}:{line}`) was **not** caught by any test:
   > ```diff
   > {diff}
   > ```
   > Write or strengthen a test so it fails under this change.

4. Re-run. Accept the result only when this run exits `0`, `summary.score` is not `null`,
   and `summary.score >= 90`. If every scored mutant must be killed, also require `summary.survived == 0`;
   the score is rounded, so `--threshold 100` alone can still pass with a survivor.

Keep `fail_fast` disabled (the default). If the active `.mutineer.yml` sets it to
`true`, temporarily change that value to `false` for the loop. Restore the original
value when the loop ends, before committing. A fail-fast run is partial,
and its score and exit code do not cover the full scope.

Zero survivors alone is not success: an empty or fully suppressed scope, or a run
with no usable verdicts, also has zero survivors. If the score is null, stop and
report “no score”. Check `no_coverage[]` for test gaps and `no_verdict[]` for
harness failures, and fix them before starting a new run. A
positive threshold fails when nothing can be scored and something broke, or when
more than one mutant has no verdict and they exceed 10% of those attempted; it
does not require zero errors. Keep the threshold in the command equal to your target.

An empty run (`summary.total` is 0) exits 0 in 1.x and prints a warning on stderr. Treat it as "no score". Pass `--allow-empty` only when an empty run is expected. A `--since` run whose changes hold no mutable code says "nothing to test in the changes since REF"; that is a valid success. Warnings that start with `mutineer:` or `[mutineer]` also go to stderr: the empty-run warning, "did you mean" hints, notes about Mutineer 2.0, the count of errored mutants, and a notice that a `PARALLEL_WORKERS` value you set was replaced with 1.

Progress lines go to **stderr**; do not merge streams (`2>&1`) when parsing JSON from
stdout — prefer `--output FILE` and read the file.

`--since` limits each run to changed lines. Review equivalent mutants as described
in **Avoiding infinite loops** below.

## CI gate: fail a PR only when it makes things worse

Save a full JSON report from the default branch as a baseline. Compare pull
requests with that report to catch new survivors while you improve existing tests.
For both the first baseline and each refresh, temporarily remove `baseline:` from
`.mutineer.yml` before this command. Keep the source, test, and operator settings.
The refresh must describe main without comparing it with the old baseline:

```sh
# On main, write a candidate without replacing the saved baseline:
mutineer run app/ --no-since --format json --output .mutineer/baseline-candidate.json
```

Use a separate output path to preserve the saved report for review. An output
path that names a baseline being compared exits `2` before a real run.

Keep the saved baseline if the command exits `1` or `2`. Before replacing it,
require exit `0`, a non-null `summary.score`, and no `no_verdict[]` entries.
Confirm the full intended scope ran, with `fail_fast` disabled and neither
`--only` nor an `only:` configuration filter. Review the candidate's survivors, then copy it and commit or cache the
saved baseline:

```sh
cp .mutineer/baseline-candidate.json .mutineer/baseline.json
```

Restore any `baseline:` setting after the saved report is in place. On a pull
request, compare against that file:

```sh
mutineer run app/ --since origin/main --baseline .mutineer/baseline.json --format json
```

`--baseline` exits `1` if it finds a new survivor or a lower score.
It matches survivors by `id`; file moves and renames can change ids.
`--baseline-epsilon` allows a small score difference. With `--since`, only new
survivors fail the baseline check: a score for changed lines is not comparable
to a full-run score. Add `--threshold` to enforce a minimum score as well.

Run a full scan on the pull request whenever tests change, including when source
code changes too. A scoped check cannot detect weaker tests for unchanged source
lines. Compare the PR's full run with the full baseline:

```sh
mutineer run app/ --no-since --baseline .mutineer/baseline.json --format json
```

Keep a full scan on the default branch to refresh the baseline. That scan does
not check a pull request's changed tests before merge.

### GitHub Action

The GitHub Action runs Mutineer and reports the result. This example requires
`.mutineer/baseline.json` from a full run on the default branch. Commit that file
or restore it before the Mutineer step. Omit `baseline` until it exists.

```yaml
# .github/workflows/mutation.yml
name: Mutation testing
on: pull_request

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
          sources: app/
          since: none
          baseline: .mutineer/baseline.json
          threshold: "90"
          output: .mutineer/pr.json
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: mutineer-report
          path: .mutineer/pr.json
```

This workflow runs a full scan on every pull request, so it checks test changes
without a workflow edit for each PR. A full scan can take longer than a scan of
changed source lines.

For a Rails app, add `rails: true` and `use-bundler: true` (boot mode needs the app's own bundle):

```yaml
      - uses: davidteren/mutineer@v1
        with:
          sources: app/models/order.rb
          rails: true
          use-bundler: true
          since: none
```

See `action.yml` for all inputs (`operators`, `framework`, `strategy`, `jobs`, `extra-args`, …) and the
`exit-code` / `report` outputs.

## Avoiding infinite loops: equivalent mutants

An equivalent mutant has the same behaviour as the original for all valid inputs.
No test can catch it. After review, ignore it and record the reason:

- **Inline:** `# mutineer:disable-line arithmetic -- count is an integer` suppresses every arithmetic mutant on that source line. Review all of them before adding the marker. To ignore only one reviewed mutant, use its `id` in the configuration instead.
- **Config:** add the survivor's `id` (printed in the JSON report; it includes the file path) to `.mutineer.yml`:

  ```yaml
  ignore:
    - id: 9f2a1c4b7e0d
      reason: "count * 1 and count / 1 are equal for integer counts"
  ```

Replace the required `id` with the survivor's id from your report. The `reason`
is optional; write your own explanation or omit that field. Ignore mappings and
`mutineer triage` require Mutineer 1.7 or later in every environment that reads
the configuration. For the GitHub Action, check the resolved gem version selected
by `version:`. With `use-bundler: true`, check Mutineer in `Gemfile.lock` instead.
Older versions do not apply mapping entries and do not warn, so the named mutant
is not ignored. Ignored mutants are excluded from the score and listed in
`ignored[]`. Set an attempt limit for the agent, then ask a person to review
unresolved survivors. Failed attempts alone do not prove that a mutant is equivalent.

## Reading exit codes in a pipeline

<!-- contract:exit-codes -->
| Code | Meaning |
|------|---------|
| `0` | Score ≥ threshold (or no gate) **and** no baseline regression. |
| `1` | Score below `--threshold`, OR nothing could be scored and something broke, or more than one mutant produced no verdict and they exceed 10% of those attempted, OR a `--baseline` regression, OR a runtime error. |
| `2` | Usage / invalid-flag error (mistyped flag, bad path, unreadable baseline). |
<!-- /contract:exit-codes -->

Branch on these directly; never scrape the human report. The JSON `summary` and `baseline` blocks carry
the same facts for dashboards.
