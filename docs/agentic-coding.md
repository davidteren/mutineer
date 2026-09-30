# Mutineer for AI agents & CI pipelines

Line coverage tells you which code *ran* under test. It says nothing about whether your tests would
*notice if that code broke*. Mutation testing closes exactly that gap — and that gap is where
AI-generated code and AI-generated tests are weakest: tests that execute and pass, but assert nothing
meaningful ("coverage theater").

Mutineer is built for programmatic use: a **versioned JSON contract**
([schema](./json-schema.md)), **structured exit codes**, **diff-scoped runs** (`--since`), a **hard gate**
(`--threshold`), and **delta gating** (`--baseline`). This page shows how to wire it into an agent loop
and into CI.

## The agent inner loop

A coding agent that writes code *and* tests can use Mutineer as an objective "are these tests any good?"
oracle, closing the loop with a concrete stopping condition:

1. Agent edits code + tests on a branch.
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

Before running, set `fail_fast: false` in `.mutineer.yml`. A fail-fast run is partial,
and its score and exit code do not cover the full scope. If the score is null, stop
and report “no score”. Inspect the coverage gaps and harness failures, and fix them
before starting a new run. Do not treat an empty or fully suppressed scope as proof
of test quality.

Zero survivors alone is not success: an empty scope or a run with no usable verdicts
also has zero survivors. Treat a null score as “no score”. Check `no_coverage[]` for
test gaps and `no_verdict[]` for harness failures before accepting the result. A
positive threshold fails when nothing can be scored and something broke, or when
more than one mutant has no verdict and they exceed 10% of those attempted; it
does not require zero errors. Keep the threshold in the command equal to your target.

Progress lines go to **stderr**; do not merge streams (`2>&1`) when parsing JSON from
stdout — prefer `--output FILE` and read the file.

`--since` keeps each iteration fast by mutating only the lines the agent just touched. Genuinely
equivalent mutants (which can never be killed) should be suppressed so the loop terminates — see
**Avoiding infinite loops** below.

## CI gate: fail a PR only when it makes things worse

Store a JSON run as a baseline, then gate PRs on regressions rather than an absolute bar (which lets a
team adopt Mutineer on a legacy suite without fixing everything first):

```sh
# On main, refresh the baseline (e.g. nightly) and commit/cache it:
mutineer run app/ --no-since --format json --output .mutineer/baseline.json

# On a PR:
mutineer run app/ --since origin/main --baseline .mutineer/baseline.json --format json
```

`--baseline` exits `1` on any **new** survivor (matched by `id`, so it survives unrelated edits, but not a file move or rename) or
a **score drop** (`--baseline-epsilon` tolerates float jitter); under `--since` the score-drop half is
skipped, because a diff-scoped score covers a different denominator — new-survivor detection still gates.
Combine with `--threshold` to enforce an absolute floor too — the worse of the two gates wins.

Keep the full-scan baseline refresh on main as the backstop: a PR that changes only tests or docs has no
changed source lines, scores zero mutants, and passes the scoped gate vacuously — only the full scan
catches a weakened suite for untouched code.

### GitHub Action

This repo ships a composite action (`action.yml`). Minimal PR gate:

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
          # since: defaults to the PR's base commit SHA from the event
          # payload (falls back to fetching the base tip); `none` = full scan.
          baseline: .mutineer/baseline.json
          threshold: "90"
          output: .mutineer/pr.json
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: mutineer-report
          path: .mutineer/pr.json
```

For a Rails app, add `rails: true` and `use-bundler: true` (boot mode needs the app's own bundle):

```yaml
      - uses: davidteren/mutineer@v1
        with:
          sources: app/models/order.rb
          rails: true
          use-bundler: true
          # since: defaults to the PR's base commit SHA (falls back to
          # fetching the base tip); `none` = full scan.
```

See `action.yml` for all inputs (`operators`, `framework`, `strategy`, `jobs`, `extra-args`, …) and the
`exit-code` / `report` outputs.

## Avoiding infinite loops: equivalent mutants

Some mutants are semantically identical to the original and can **never** be killed by any test. In an
unattended agent loop these would never clear, so suppress them explicitly:

- **Inline:** `# mutineer:disable-line [operators]` on the offending source line.
- **Config:** add the survivor's `id` (printed in the JSON report; it includes the file path) to `.mutineer.yml`:

  ```yaml
  ignore:
    - 9f2a1c4b7e0d   # Calculator#scale — equivalent under `comparison`
  ```

Suppressed mutants leave the score entirely (so 100% stays reachable) and appear under the JSON `ignored[]`
key for auditing. An agent should treat a survivor it cannot kill after N attempts as a candidate for
human review / suppression rather than looping forever.

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
