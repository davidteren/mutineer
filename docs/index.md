# Mutineer

Clean-room mutation testing for Ruby. Mutineer mutates your source one change at a
time, runs your test suite (Minitest or RSpec) against each mutant, and reports the
mutants your tests failed to catch — the gaps where a green suite is a lie.

Prism + stdlib only. Zero runtime dependencies. Ruby ≥ 3.4. Versioned JSON contract
for CI gates and AI coding agents.

This file is the Markdown twin of the [HTML landing page](https://davidteren.github.io/mutineer/).

## Watch it in one minute

[A 63-second explainer](https://davidteren.github.io/mutineer/assets/mutineer-explainer.mp4)
(MP4, music and on-screen text, no narration): a discount method passes its tests with
100% line coverage. Mutineer makes two mutants. The tests kill `*` → `/` but miss
`>=` → `>`, because no test checks an order of exactly 100. The video ends with the
test that closes that gap.

## Install

```sh
gem install mutineer
```

Or in a Gemfile:

```ruby
gem "mutineer", group: :test
```

## Run

```sh
mutineer run <source...> --test <test> [--test <test>...] [options]
```

Example — mutate a file against its test and fail CI below 90%:

```sh
mutineer run lib/calculator.rb --test test/calculator_test.rb --threshold 90
```

Diff-scoped PR gate against a baseline:

```sh
mutineer run app/ --since origin/main --baseline .mutineer/baseline.json
```

Preview mutations without running tests:

```sh
mutineer run --dry-run lib/foo.rb
```

## CLI essentials

| Flag | Meaning |
|------|---------|
| `--test FILE` | Test file covering the sources (repeatable) |
| `--threshold FLOAT` | Exit 1 when the score is below FLOAT, or when the run is incomplete (default: 0 = off) |
| `--since REF` | Only mutate lines changed since git `REF` |
| `--baseline FILE` | Exit 1 on new survivors / score drop versus a prior JSON run |
| `--format human\|json\|html` | Report format (default: human) |
| `--output FILE` | Write the report to FILE instead of stdout |
| `--jobs N` | Parallel worker count; forced to 1 by `--test-command`, `--fail-fast`, or `--rails` without `--daemon` |
| `--rails` | Boot `config/environment` once; without `--daemon`, defaults to `redefine` and runs serially |
| `--daemon` | Persistent daemon + per-worker DB isolation (needs `--rails` / `--boot`) |
| `--dry-run` | List candidate mutations without executing |
| `--matrix` | Run every covering test for each mutant and name the blind and redundant tests; the JSON report also lists each mutant's killers (in-process only; RSpec 3.3+) |

Typed flags override `.mutineer.yml`. Full flag list: `mutineer --help` or the [README](https://github.com/davidteren/mutineer/blob/main/README.md).

## Exit codes

<!-- contract:exit-codes -->
| Code | Meaning |
|------|---------|
| `0` | Score ≥ threshold (or no gate) **and** no baseline regression. |
| `1` | Score below `--threshold`, OR nothing could be scored and something broke, or more than one mutant produced no verdict and they exceed 10% of those attempted, OR a `--baseline` regression, OR a runtime error. |
| `2` | Usage / invalid-flag error (mistyped flag, bad path, unreadable baseline). |
<!-- /contract:exit-codes -->

## Operators

Default (Tier 1): `arithmetic`, `comparison`, `boolean_connector`, `boolean_literal`,
`statement_removal`.

Tier 2 (off until `--operators`): `return_nil`, `literal_mutation`, `condition_negation`,
`string_literal`, `regex`, `collection_method`, `safe_navigation`, `range`,
`negation_removal`, `chain_link`, `operand_removal`,
`array_literal`, `condition_true`, `condition_false`, `operator_assignment`.

`mutineer --list-operators` prints the live set.

## Mutineer and Mutant

"Clean-room" means Mutineer was written from scratch. It contains no code from
[Mutant](https://github.com/mbj/mutant) or any other mutation-testing tool.
Mutineer's own code is licensed under MIT.

| Aspect | Mutineer | Mutant 0.17 |
|---|---|---|
| License | MIT, for every use | Free for open source; commercial use needs a paid subscription |
| Runtime dependencies | None (Prism + stdlib) | `parser`, `unparser`, `sorbet-runtime` and others |
| Ruby | 3.4 and later (older app Rubies via `--test-command`) | 3.3 and later |
| Test frameworks | Minitest and RSpec | RSpec, Minitest and Test::Unit |
| What you mutate | Files, or one method with `--only` | Subjects named by expression |

Mutant is the established tool, with a deeper operator set. Mutineer trades
that depth for an MIT license, an empty dependency list, and a JSON contract
built for CI gates and AI agents. Checked against Mutant 0.17 on 2026-10-06.
Full comparison:
[README](https://github.com/davidteren/mutineer#mutineer-and-mutant).

## More docs

- [Agent & CI guide](https://davidteren.github.io/mutineer/agentic-coding.html) · [Markdown](https://davidteren.github.io/mutineer/agentic-coding.md)
- [JSON report schema](https://davidteren.github.io/mutineer/json-schema.html) · [Markdown](https://davidteren.github.io/mutineer/json-schema.md)
- [Ruby API (YARD)](https://davidteren.github.io/mutineer/api/)
- [Sample HTML report](https://davidteren.github.io/mutineer/sample-report.html)
- [Full docs (`llms-full.txt`)](https://davidteren.github.io/mutineer/llms-full.txt)
- [Agent skill](https://davidteren.github.io/mutineer/skill.md)
- [Docs index (`llms.txt`)](https://davidteren.github.io/mutineer/llms.txt)
