# Mutineer

Your tests pass. Would they catch a bug? Mutineer makes small changes to your
Ruby code, runs your Minitest or RSpec tests, and shows you the changes they miss.
This is **mutation testing**.

Each changed version of the code is a **mutant**. A test that fails against it
has **killed** it. If the tests still pass, it **survived**. Read the survivor
to decide whether a better test is needed or the change leaves the behaviour unchanged.

For example, changing `qty >= 10` to `qty > 10` removes the discount at exactly
10 items. Tests for quantities 1 and 50 still pass. A test for quantity 10
catches it. Line coverage can be 100% and still miss this case.

The mutation score is `killed / (killed + survived)`. A run with 24 killed
changes and one survivor scores 96%. Other results are excluded. The score
is empty when nothing can be scored; even 100% does not prove the code has no bugs.

[New to mutation testing? Run the complete example](learn.html).
This is the Markdown twin of the [HTML landing page](https://davidteren.github.io/mutineer/).

## Start with one file

Use Ruby 3.4 or later on Linux or macOS. Pick a small file with passing tests.
Mutation testing repeats test runs, so it takes longer than a normal test run.

```sh
gem install mutineer
mutineer run lib/discount.rb --test test/discount_test.rb
```

Replace both paths with files in your project. For RSpec, pass a spec file to
`--test`. In a Bundler project, add `gem "mutineer", group: :test` to the Gemfile,
run `bundle install`, and use `bundle exec mutineer`. For Rails, follow the
[one-model guide](rails.html#one-model).

Read one entry under **Surviving Mutants**. Add a test that passes with the
original code and fails with the change, then run again. If the change leaves
the behaviour unchanged, record why you ignore it. The
[beginner guide](learn.html#what-to-do-with-a-survivor) explains this step.
Start without a score target. Add [CI checks](agentic-coding.html) once you
understand the results. Mutineer 1.7+ can create a starter configuration with
`mutineer init`.

Preview changes without running tests:

```sh
mutineer run --dry-run lib/discount.rb
```

<!-- site:production-ready -->
<!-- /site:production-ready -->

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
| `--timeout SECONDS` | Per-mutant time limit for in-process runs (default: 10); raise it for a slow suite |
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
`negation_removal`, `chain_link`, `call_to_receiver`, `operand_removal`,
`array_literal`, `condition_true`, `condition_false`, `operator_assignment`.

`mutineer --list-operators` prints the live set.

## Mutineer and Mutant

Mutineer was written from scratch. It contains no code from
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
