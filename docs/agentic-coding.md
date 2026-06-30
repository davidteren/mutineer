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
   mutineer run app/ --since origin/main --format json --output .mutineer/run.json
   ```

3. Parse `survivors[]`. Each entry carries a ready-made `diff` and a stable `id`. For each survivor, feed
   the agent a prompt like:

   > This change to `{subject}` (`{file}:{line}`) was **not** caught by any test:
   > ```diff
   > {diff}
   > ```
   > Write or strengthen a test so it fails under this change.

4. Re-run. Stop when `summary.survived == 0` (or `summary.score >= target`).

`--since` keeps each iteration fast by mutating only the lines the agent just touched. Genuinely
equivalent mutants (which can never be killed) should be suppressed so the loop terminates — see
**Avoiding infinite loops** below.

## CI gate: fail a PR only when it makes things worse

Store a JSON run as a baseline, then gate PRs on regressions rather than an absolute bar (which lets a
team adopt Mutineer on a legacy suite without fixing everything first):

```sh
# On main, refresh the baseline (e.g. nightly) and commit/cache it:
mutineer run app/ --format json --output .mutineer/baseline.json

# On a PR:
mutineer run app/ --since origin/main --baseline .mutineer/baseline.json --format json
```

`--baseline` exits `1` on any **new** survivor (matched by stable `id`, so it survives unrelated edits) or
a **score drop** (`--baseline-epsilon` tolerates float jitter). Combine with `--threshold` to enforce an
absolute floor too — the worse of the two gates wins.

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
        with:
          fetch-depth: 0          # --since needs full history
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"
          bundler-cache: true
      - uses: davidteren/mutineer@main
        with:
          sources: app/
          since: origin/${{ github.base_ref }}
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
      - uses: davidteren/mutineer@main
        with:
          sources: app/models/order.rb
          rails: true
          use-bundler: true
          since: origin/${{ github.base_ref }}
```

See `action.yml` for all inputs (`operators`, `framework`, `strategy`, `jobs`, `extra-args`, …) and the
`exit-code` / `report` outputs.

## Avoiding infinite loops: equivalent mutants

Some mutants are semantically identical to the original and can **never** be killed by any test. In an
unattended agent loop these would never clear, so suppress them explicitly:

- **Inline:** `# mutineer:disable-line [operators]` on the offending source line.
- **Config:** add the survivor's stable `id` (printed in the JSON report) to `.mutineer.yml`:

  ```yaml
  ignore:
    - 9f2a1c4b7e0d   # Calculator#scale — equivalent under `comparison`
  ```

Suppressed mutants leave the score entirely (so 100% stays reachable) and appear under the JSON `ignored[]`
key for auditing. An agent should treat a survivor it cannot kill after N attempts as a candidate for
human review / suppression rather than looping forever.

## Reading exit codes in a pipeline

| Code | Pipeline action |
|------|-----------------|
| `0` | Pass — score ≥ threshold and no baseline regression. |
| `1` | Fail the check — tests are too weak (below threshold) or a regression was introduced. |
| `2` | Fail the *job* differently — this is a misinvocation (bad flag/path), not a test-quality signal. |

Branch on these directly; never scrape the human report. The JSON `summary` and `baseline` blocks carry
the same facts for dashboards.
