---
name: mutineer
description: Clean-room mutation testing for Ruby (Prism + stdlib, zero deps). Mutates source one change at a time, runs the suite against each mutant, and reports the mutants tests fail to catch — with a versioned JSON contract and CI/agent gating.
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
mutineer run <source...> --test <test...> [options]
```

Example — mutate `lib/calculator.rb`, gate CI below 90%:

```sh
mutineer run lib/calculator.rb --test test/calculator_test.rb --threshold 90
```

## Agent loop

1. Edit code + tests on a branch.
2. Run diff-scoped, as JSON:
   ```sh
   mutineer run app/ --since origin/main --format json --output .mutineer/run.json
   ```
3. Parse `survivors[]` — each carries a `diff` and stable `id`. For each, write/strengthen a
   test that fails under that change.
4. Re-run. Stop when `summary.survived == 0` or `summary.score >= target`.

## Exit codes

<!-- contract:exit-codes -->
| Code | Meaning |
|------|---------|
| `0` | Score ≥ threshold (or no gate) **and** no baseline regression. |
| `1` | Score below `--threshold`, OR nothing could be scored and something broke, or more than one mutant produced no verdict and they exceed 10% of those attempted, OR a `--baseline` regression, OR a runtime error. |
| `2` | Usage / invalid-flag error (mistyped flag, bad path, unreadable baseline). |
<!-- /contract:exit-codes -->

## References

- Docs: https://davidteren.github.io/mutineer/
- Agent & CI guide: https://davidteren.github.io/mutineer/agentic-coding.html
- JSON schema: https://davidteren.github.io/mutineer/json-schema.html
- Ruby API: https://davidteren.github.io/mutineer/api/
- Source: https://github.com/davidteren/mutineer
