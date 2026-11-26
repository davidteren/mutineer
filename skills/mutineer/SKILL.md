---
name: mutineer
description: Mutation testing for Ruby (Prism + stdlib, zero deps). Mutates source one change at a time, runs the suite against each mutant, and reports the mutants tests fail to catch, with a versioned JSON contract and CI/agent gating. Use when checking whether a Ruby test suite would catch a change, finding weak or missing tests, gating CI on a mutation score, or acting on mutineer's JSON report.
---

# Mutineer

Mutation testing for Ruby, built for CI gates and AI coding agents. Line coverage tells
you which code *ran*; mutation testing tells you whether your tests would *notice if it
broke*.

## Install

```sh
gem install mutineer
```

## Run

```sh
mutineer run <source...> [--test <test>...] [options]   # no --test: pairs each source with its test by convention; unmatched sources are skipped and counted in the report; --dry-run needs no --test, also with --rails/--boot
```

Example — mutate `lib/calculator.rb`, gate CI below 90%:

```sh
mutineer run lib/calculator.rb --test test/calculator_test.rb --threshold 90
```

A source that raises `NameError` (including `NoMethodError`) while it loads, with no boot file, needs `--boot` or `boot:` pointed at an app entry point or a gem's `lib/<name>.rb`.
That file loads before the sources.
Without a boot file, `require:` files load after the sources, so a source cannot use them while it loads.
Listing the entry file as an earlier source also loads it first.

## Agent loop

1. Edit code and tests on a branch. Fetch `origin/main` before using it below.
2. Run diff-scoped, as JSON:
   ```sh
   mutineer run app/ --since origin/main --threshold 90 --format json --output .mutineer/run.json
   ```
3. Parse `survivors[]` — each carries a `diff` and an `id`. File moves, renames,
   project-root changes, and changes to repeated-name or repeated-mutation order can
   change ids; see [Mutant ids](https://github.com/davidteren/mutineer/blob/main/docs/results.md#mutant-ids). Review each change
   against the intended behaviour. If review finds a test gap, write or strengthen
   a test that fails under that change.
4. Re-run. Accept the result only when this run exits `0`, `summary.score` is not `null`,
   and `summary.score >= 90`. If every scored mutant must be killed, also require `summary.survived == 0`.
   Mutineer 1.7.0 and earlier gate on the rounded score, so a run just below the threshold can
   still exit `0`. On those versions, also require
   `summary.killed * 100 >= 90 * (summary.killed + summary.survived)`.

Stop after a few unsuccessful attempts and ask a person to review the survivor.
Failed attempts do not prove that a mutant is equivalent. To
suppress it, `mutineer triage .mutineer/run.json --reason TEXT --id ID` prints an
`ignore:` entry for `.mutineer.yml`, and one entry for each id in that
survivor's `copies`. Paste every entry. An entry ignores only its own id
(Mutineer 1.7 or later reads it; `copies` is on reports from the version that
lists them). See
[Suppressing equivalent mutants](https://github.com/davidteren/mutineer/blob/main/docs/results.md#suppressing-equivalent-mutants).

Keep `fail_fast` disabled (the default). If the active `.mutineer.yml` sets it to
`true`, temporarily change that value to `false` for the loop. Restore the original
value when the loop ends, before committing. A fail-fast run is partial,
and its score and exit code do not cover the full scope.

Zero survivors alone is not success: an empty or fully suppressed scope, or a run
with no usable verdicts, also has zero survivors. If the score is null, stop and
report “no score”. Check `no_coverage[]` for test gaps and `no_verdict[]` for
harness failures, and fix them before starting a new run. Also check `summary.unpaired_mutants` (Mutineer 1.9.0 or later). Above 0, a source with no paired test was skipped. Its mutants are not in the score or in `no_verdict[]`, so they cannot fail `--threshold`. They count in the unrun-share warning on stderr, except under `--fail-fast`. `unpaired_sources[]` names each skipped source. Add a test for each entry whose `mutants` is above 0, then run again. `--test` replaces pairing, so if you pass it, list every test file, the new ones included. Under `--since`, an entry with `mutants` 0 has no mutant on a changed line. Also look for an entry whose `mutants` is `null`. That count failed, and `summary.unpaired_mutants` leaves it out. Report that run as incomplete. Do not accept it. Also check `summary.ran_at_load_tested` (Mutineer 2.0 or later). Above 0, that many mutants survived their tests and are not in the score. Each one has `tested: true` in `ran_at_load[]`. Check each one before you write a test: run its method with `--test-command` and `--only`. Add a test only if the mutant survives there. All `ran_at_load` mutants count in the unrun-share warning on stderr. A positive threshold fails when nothing can be scored and something
broke, or when more than one mutant has no verdict and they exceed 10% of those
attempted; it does not require zero errors. Set the threshold to your target.
`--baseline` applies the same no-verdict completeness rule without a threshold. It does not cover a failed `unpaired_sources[].mutants` count: check that yourself, as above. When it
exits 1, `baseline.regressed` means new survivors or a score drop, and
`baseline.incomplete` means the run failed completeness: nothing could be scored and something broke, or more than one mutant produced no verdict and they exceed 10% of those attempted. Read `no_verdict[]` and fix
the harness, not the tests. `baseline.unverified_survivors[]` are baseline
survivors this run did not decide (see each `status`); they are not fixed.

An empty run (`summary.total` is 0) exits 0 in 1.x and prints a warning on stderr. Treat it as "no score". Pass `--allow-empty` only when an empty run is expected. A `--since` run whose changes hold no mutable code says "nothing to test in the changes since REF"; that is a valid success. Warnings that start with `mutineer:` or `[mutineer]` also go to stderr: the empty-run warning, "did you mean" hints, notes about Mutineer 2.0, the count of errored mutants, and a notice that a `PARALLEL_WORKERS` value you set was replaced with 1.

## Exit codes

<!-- contract:exit-codes -->
| Code | Meaning |
|------|---------|
| `0` | Score ≥ threshold (or no gate) **and** no baseline regression, **and** no incomplete run under an active `--threshold` or `--baseline` gate. |
| `1` | Score below `--threshold`, OR nothing could be scored and something broke, or more than one mutant produced no verdict and they exceed 10% of those attempted (under `--threshold` or `--baseline`), OR a `--baseline` regression, OR a runtime error, including a boot, source or `require:` file that raises while loading (except an in-process `--since` run with no mutant on a changed line, which checks that those files exist but does not load them). |
| `2` | Usage / invalid-flag error, including a mistyped flag, a bad path (such as a missing `--boot` or `require:` file), or an unreadable baseline. |
<!-- /contract:exit-codes -->

## References

- Docs: https://davidteren.github.io/mutineer/
- Agent & CI guide: https://davidteren.github.io/mutineer/agentic-coding.html
- JSON schema: https://davidteren.github.io/mutineer/json-schema.html
- Ruby API: https://davidteren.github.io/mutineer/api/
- Source: https://github.com/davidteren/mutineer
