# Reading results and fixing survivors

Read report rows, fix survivors, suppress equivalent mutants, and check which tests kill mutants.

## What each result means

| Report row | What happened | In the score? |
| --- | --- | --- |
| Killed | A test failed against the mutant. | Yes |
| Survived | Every test passed. Inspect the change. | Yes |
| No coverage | No test runs that line. Add one first. | No |
| Timeout | Tests exceeded `--timeout`. | No |
| Errored | Tests crashed, or the first failed Minitest test had a database connection or lock error. No verdict. | No |
| Ignored | You marked the mutant as equivalent. | No |
| Skipped | The change produced invalid Ruby and did not run. | No |

The [JSON schema](https://davidteren.github.io/mutineer/json-schema.html#summary) explains the rarer Uncapturable, Unplaceable, and Ran at load results.

**Mutation score:** `killed / (killed + survived)`. All other rows are excluded. An empty denominator produces an empty score (`null` in JSON), not 0.

With `--threshold`, excessive Timeout or Errored results still fail the run. See [Timeouts and the score](https://github.com/davidteren/mutineer/blob/main/docs/ci.md#timeouts-and-the-score).

## What to do with a survivor

1. Read the diff. Identify the behaviour it breaks.
2. Add or strengthen a test that fails against the mutant. Run again.
3. If behaviour stays identical, suppress the **equivalent** mutant with a reason. No test can kill it.

For example, replacing `x * 1` with `x / 1` gives the same result when `x` is a number. See [Suppressing equivalent mutants](https://github.com/davidteren/mutineer/blob/main/docs/results.md#suppressing-equivalent-mutants).

> **Prompt for your coding agent**
>
> ```text
> Read report.json from Mutineer (--format json). For each survivor, show the source line, the mutant diff, and the behaviour the change breaks. Write one test per survivor that passes on the original code and fails on the mutant. Do not edit the source. If a mutant cannot be killed because it does not change behaviour, explain why and propose an ignore: entry with a reason instead of a test.
> ```

## Suppressing equivalent mutants

Equivalent mutants survive without changing behaviour. Suppression excludes them from the score, makes 100% reachable, and keeps `--threshold` meaningful.

| Method | Usage |
| --- | --- |
| Inline | Add `# mutineer:disable-line`. Scope it with an operator: `# mutineer:disable-line comparison`. |
| Inline reason | Add a reason after `--`: `# mutineer:disable-line comparison -- the test checks only 20`. |
| Config | Add a bare mutant id or an `id` mapping with an optional `reason` under `.mutineer.yml` `ignore:`. |
| Reports | JSON lists each survivor's `id`. JSON and HTML show suppression reasons. Markers without reasons store none. |

**Mappings require Mutineer 1.7 or later in every gate reading the config.** Older versions silently ignore mappings, leaving their mutants unsuppressed.

| Gate | Version control |
| --- | --- |
| Action | `version:`, or `Gemfile.lock` with `use-bundler: true` |
| Your CI job | `Gemfile.lock` |

```ruby
return 0.1 if qty >= 10 # mutineer:disable-line comparison -- the test checks only 20
```

```yaml
# .mutineer.yml
ignore:
  - ID_FROM_THE_JSON_REPORT
  - id: ID_FROM_THE_JSON_REPORT
    reason: x / 1 equals x * 1 for numbers
```

| Command | Output |
| --- | --- |
| `mutineer triage REPORT.json --reason TEXT --all` | One mapping per survivor |
| `mutineer triage REPORT.json --reason TEXT --id ID` | One mapping for the selected mutant; repeat `--id` for several |

`triage` edits no files. Paste its mappings under `ignore:` after every gate uses 1.7 or later.

[Equivalent skips](https://davidteren.github.io/mutineer/equivalent-skips.html) lists built-in skips. You cannot disable them.

## Mutant ids

A mutant id contains 12 hex characters. Its hash uses:

| Input | Detail |
| --- | --- |
| File path | Relative to the project root |
| Method | Qualified name |
| Mutation | Operator, mutated code, and position among identical mutants in the method |
| Duplicate method | Second and later same-named methods also include their position within the file; the first method's id stays unchanged. |

Duplicate names can occur with two top-level `def index` definitions in separate DSL blocks.

| Change | Effect on ids |
| --- | --- |
| Edit outside the method | None, unless it changes a listed input |
| Move or rename the file | Ids change |
| Rename the method or its class | Ids change |
| Add an identical mutant earlier in the method | Later identical mutants' ids change |
| Add a same-named method earlier in the file | Affected methods' ids change |
| Change the run directory | Relative paths can change ids |
| Use sources outside the project root | Absolute paths make ids differ between machines |

The project root is the run directory, or the Action's `working-directory`. Use the same root for stable ids.

**Migrating from ids without the file path.** Before 1.3, ids omitted file paths, allowing collisions between files (issue #126). Old ids work until 2.0, with warnings.

| Setting | Compatibility and action |
| --- | --- |
| `ignore:` | Old entries still suppress mutants. Warnings list new ids, files, and methods for each entry. |
| One match | Replace the old entry with the new id. |
| Multiple matches | The old entry also hid unintended mutants. Keep only intended ids, including across same-named methods or different files. |
| Full migration list | Run every source and operator set you use, including Tier-2 (additional operators) `--operators`. Warnings cover only that run. |
| `mutineer migrate` | Writes every matching new id. Delete unintended ids. See [Migrate old ignore ids](https://github.com/davidteren/mutineer/blob/main/docs/results.md#migrate-old-ignore-ids). |
| `--baseline` | Matches survivors by old id and file. Stored absolute paths outside the project root match by old id alone. |
| Baseline replacement | Generate with `--format json` when prompted. `migrate` does not rewrite baselines. |

Generate a new baseline only after every reader uses 1.3 or later. Older versions treat every new-format survivor as new. The Action uses `version:`, or `Gemfile.lock` with `use-bundler: true`. Your CI job uses `Gemfile.lock`.

| JSON field | Meaning |
| --- | --- |
| `summary.id_format` | `2` identifies the new format |
| `summary.legacy_id_matches.ignore` | Count of matched old-format ignore entries |
| `summary.legacy_id_matches.baseline` | Count of survivors matched only through an old baseline id |

Mutineer searches parent directories for `.mutineer.yml`. A config above the run directory triggers an ignore-id warning, except in your home directory. The warning names the correct run directory.

## Migrate old ignore ids

```sh
mutineer migrate <source...> [--dry-run] [--operators LIST]
```

`migrate` updates old ids under `.mutineer.yml` `ignore:`. It preserves comments and all other lines.

| Case | Result |
| --- | --- |
| Bare id matches several mutants | Writes every new id, preserving the 1.x match |
| Id matches nothing | Keeps the entry; exits 1 |
| `{ id:, reason: }` matches one mutant | Updates the id; preserves the reason |
| Mapping matches several mutants | Keeps the entry, lists new ids, exits 1; split it manually |
| Block scalar under `ignore:` | Changes nothing; exits 2 |
| `--dry-run` | Prints changes; writes nothing |

Use the same sources and `--operators` as `run`. Migration runs no tests and changes no baseline. Generate a new baseline with `--format json`.

## Kill matrix

`--matrix` shows which tests kill each mutant and identifies tests that add no kills.

```sh
mutineer run lib/calculator.rb --test test/calculator_test.rb --matrix
```

Mutineer runs every test in each mutant's covering files and records failures. Coverage is per file, so tests that never reach the mutated line also count as run.

| Row state | Meaning |
| --- | --- |
| Complete | Every covering test ran, and the suite returned normally |
| Incomplete | The covering set did not finish normally, including a Minitest `Interrupt` |
| Minitest database connection or lock failure | Leaves the row incomplete and adds no kill, even after an earlier assertion killed the mutant |

| Test label | Meaning | Before deleting |
| --- | --- | --- |
| Blind | Ran in at least one complete row; killed no mutant in any row | Check its assertions. It may cover other files or changes no operator makes. Consider adding an assertion that can fail. |
| Redundant | Another test kills every mutant it kills | Delete one test at a time and rerun. Two redundant tests can be a mutant's only killers. |

These labels apply only to this run's mutants. Mutate the code a test exercises before calling it blind.

**The matrix changes no verdict, score, or exit code.** Each mutant receives the verdict from a run without `--matrix`.

| Execution case | Verdict behaviour |
| --- | --- |
| First failure in a normal run | Skips later tests, classes, and example groups |
| Later skipped test exits, crashes, or times out | First failure decides: `killed` for ordinary failures; `error` for Minitest database connection or lock failures |
| Minitest class `run` wrapper, RSpec `after(:all)`, or `after(:suite)` ends abnormally | These still run after failure; their exit status remains effective |
| Minitest `parallelize_me!` failure | Exit status remains effective. Parallel classes run after serial classes and cannot stop once queued. Serial failures still stop the run. |

| Requirement or output | Detail |
| --- | --- |
| RSpec version | Requires RSpec 3.3 or later to distinguish examples on one line. Older versions produce only incomplete rows. |
| Human report | Lists up to 20 blind and 20 redundant tests |
| HTML report | Lists all blind and redundant tests |
| JSON | `--format json` adds every test and each mutant's killers in `matrix`; see [JSON schema](https://davidteren.github.io/mutineer/json-schema.html#matrix) |
| Test identity | File plus id |
| Minitest name | For example, `CalculatorTest#test_add` |
| RSpec name | Full description. Example ids such as `./spec/calc_spec.rb[1:2]` distinguish shared descriptions and preserve identity when generated descriptions change. |

Every mutant runs its full covering set, costing as much as a survivor. Expect matrix runs to take 2.1 to 2.5 times as long. In 1.4, stopping at first failure reduced rack's `lib/rack/utils.rb` run from 86 to 89 seconds to 35 to 41.

| Limit | Behaviour or action |
| --- | --- |
| Per-mutant `--timeout` | Defaults to 10 seconds |
| Timeout after a test failure | Preserves the first failure's verdict; marks the row incomplete |
| Incomplete rows | Report lists each row and warns that blind tests might have killed those mutants |
| Complete the rows | Raise `--timeout`, or `.mutineer.yml` `timeout:` |
| Backend | In-process only |
| Incompatible settings | Exits 2 with `--daemon`, `--test-command`, `--fail-fast`, or `--dry-run`. The message identifies command-line or `.mutineer.yml` origins. |
| Config has `matrix: true` | Pass `--no-matrix` to use incompatible settings |
| Config has `fail_fast: true` | Pass `--no-fail-fast` with `--matrix` |

The matrix checks only this run's mutants. Blind tests may protect other behaviour.
Do not delete a blind test until its rows are complete.