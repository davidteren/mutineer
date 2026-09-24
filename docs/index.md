# Mutineer

Clean-room mutation testing for Ruby. Mutineer mutates your source one change at a
time, runs your test suite (Minitest or RSpec) against each mutant, and reports the
mutants your tests failed to catch — the gaps where a green suite is a lie.

Prism + stdlib only. Zero runtime dependencies. Ruby ≥ 3.4. Versioned JSON contract
for CI gates and AI coding agents.

This file is the Markdown twin of the [HTML landing page](https://davidteren.github.io/mutineer/).

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
mutineer run <source...> --test <test...> [options]
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
| `--jobs N` | Parallel worker count |
| `--rails` | Boot `config/environment` once (Rails apps) |
| `--daemon` | Persistent daemon + per-worker DB isolation (needs `--rails` / `--boot`) |
| `--dry-run` | List candidate mutations without executing |

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
`string_literal`, `regex`, `collection_method`, `safe_navigation`, `range`.

`mutineer --list-operators` prints the live set.

## More docs

- [Agent & CI guide](https://davidteren.github.io/mutineer/agentic-coding.html) · [Markdown](https://davidteren.github.io/mutineer/agentic-coding.md)
- [JSON report schema](https://davidteren.github.io/mutineer/json-schema.html) · [Markdown](https://davidteren.github.io/mutineer/json-schema.md)
- [Ruby API (YARD)](https://davidteren.github.io/mutineer/api/)
- [Sample HTML report](https://davidteren.github.io/mutineer/sample-report.html)
- [Full docs (`llms-full.txt`)](https://davidteren.github.io/mutineer/llms-full.txt)
- [Agent skill](https://davidteren.github.io/mutineer/skill.md)
- [Docs index (`llms.txt`)](https://davidteren.github.io/mutineer/llms.txt)
