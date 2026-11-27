---
title: "Group 11-E: Known limits - Plan"
type: feat
date: 2026-11-27
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
target_release: v1.11.0
issues: [552, 554, 501, 467]
---

# Group 11-E: Known limits - Plan

Planned by: Fable 5.2, effort high, 2026-11-27

- **What:** A triage of the 21 limits in #501, #552, #554 and #467. Three limits get a small build. One gets a docs sentence. The others stay as documented or move.
- **Why:** Each issue is a list of limits that an earlier pull request left on purpose. One of them gives a wrong result with no message today (see "Reproductions", P5, P6, P9 and P10).
- **How:** One pull request with three commits. The JSON report marks a run that `since_paired_tests` narrowed (#552). A folder source leaves out test files and says so (#554). The docs name one limit they did not name (#501). #467 moves to 2.0 with no build.

Build settings: Opus 5.5, effort `medium` (as in `WORKLIST.md`). The `lib/` code of units U1, U3 and U4 is written and was run in planning (`11-E-known-limits-prototype.patch`, 64 added and 10 removed lines in 5 files). The builder adds the tests and the docs.

Planned against `main` at `6c71ccba` (after #586 and #592).

**Verdict: `go without #467`.** Three limits are reproduced and their fixes ran green in a prototype, and #467 moves to 2.0 because its full fix puts `ran_at_load` mutants into the score.

---

## Triage: one decision for each limit

"Keep" means: the limit stays as the docs describe it, and its issue stays open.

| Issue | Item | Decision | Reason in one sentence |
|---|---|---|---|
| #552 | 1. `--test-command` does not narrow | Keep (unit U2 is ready, not built) | No user asked, it changes a run that 1.10.0 users already have, and the rate of lost kills is not measured (decision D3). |
| #552 | 2. An explicit `--test` list does not narrow | Not planned here | It depends on #421 (group 11-F). |
| #552 | 3. A narrowed run misses a kill by another source's test | Keep | It is what narrowing means, and `--baseline` already keeps every test (#557). |
| #552 | 4. The JSON report does not mark a narrowed run | **Build (U1)** | A saved report cannot tell a narrowed `--since` run from a full `--since` run, and #553 (2.0) names this as a condition. |
| #552 | 5. A narrowed run replaces the full-run cache | Keep | `--cache-dir` is the documented way out, and 11-F (#558) changes this code next. |
| #552 | 6. A narrowed capture does not fit `--coverage-from` | Keep | The test lists must match by design. |
| #552 | 7. A custom RSpec order can change | Keep | The seed contract in `.expectation-fit/ways-of-working.yaml` already says so. |
| #552 | 8. No measured rate of lost kills | Move to #553 | Step 1 of #553 is this measurement. |
| #554 | 1. Pack roots other than `packs/` | Keep | The `tests:` map works, and an engine's tests often need the engine's own boot. |
| #554 | 2. No `{path}` placeholder in the `tests:` map | Keep | It is a new map syntax, which is a design task. |
| #554 | 3. A folder source lists pack test files as sources | **Build (U3)** | With `--test`, the run scores a test file and prints a broken JSON report (P5). |
| #554 | 4. The guard misses a `test_*.rb` file in a pack | **Build (U4)** | It uses the rule of U3 in one more line. |
| #554 | 5. Failed-test blame across packs | Done | Fixed in pull request #557. |
| #501 | 1. A lazy enumerator from outside the method | Keep | The operator reads the syntax tree and cannot see the class. |
| #501 | 2, 3. Truthiness reads | Done | Shipped in 1.10.0 (pull request #550). |
| #501 | 4. `first` / `last` on a Hash, a Set or an endless Range | Keep | 0 cases in 18,517 methods (P8), and a new skip rule shifts mutant ids (#508). |
| #501 | 5. An `each` that returns `nil` or `false` | Keep | 0 cases in the same sample. |
| #501 | 6. `min` / `max` under a `<=>` with a side effect | **Docs (U5)** | The docs do not name this limit yet. |
| #467 | 1. A kill by an unpaired test is lost | **Move to 2.0** | See decision D1. |
| #467 | 2. No paired test: every test keeps the lines | **Move to 2.0** | It is a speed limit of the same rule. |

After the build: #552, #554 and #501 move from `v1.11.0` to `backlog` and stay open. #467 moves to `v2.0`.

---

## Goal Capsule

- **Objective:** Each limit in the four issues has a decision that David can read in one table. The three built limits are closed with tests. No verdict of a run that works today changes, except the cases named in "Public contract changes".
- **Authority:** `AGENTS.md`, then `.expectation-fit/ways-of-working.yaml` and the decision files `coverage-and-test-selection.md`, `pairing-of-sources-and-tests.md`, `json-schema-and-baseline.md` and `mutators-and-equivalent-skips.md`, then this plan, then the issue texts.
- **Execution profile:** One branch `feat/552-554-known-limits`, one worktree, one pull request, three commits (see "Commit order").
- **Who ships:** The builder opens the pull request. David merges. No release step.
- **Size:** Small. 5 `lib/` files (64 added lines, 10 removed) and one comment in a sixth, 5 test files, 8 docs files, 1 decision file, the plan copy.
- **Stop conditions.** Stop that unit, ship the others, and report:
  - A test of the exact-survivor oracle (`test/integration_test.rb`, `test/rspec_integration_test.rb`) changes a verdict.
  - U3 changes the source list of a run that names no folder with a test file under it. Check with the dogfood commands in `.github/workflows/ci.yml`.
  - A unit seems to need a change in `lib/mutineer/coverage_map.rb` or `lib/mutineer/coverage_map/`. Group 11-F owns that code.
- **Do not build U2.** It is in this plan so that David can say yes to it later.

**Public contract changes:**

1. JSON: new key `summary.tests_narrowed` (boolean). `schema_version` goes from `1.11` to `1.12`.
2. In `mutineer run` (also with `--dry-run`), a folder source no longer yields a file of a test folder below it, or a file that is in the `--test` list. `summary.unpaired_sources` and `summary.unpaired_mutants` fall for a run that named such a folder. A run whose folder sources hold only such files now exits 2 with `run requires at least one source file`. Before, it exited 0 with a wrong report.
3. New stderr line when a folder source left files out: `[mutineer] folder sources: left out N files, such as <path> (a file in a test or spec folder beside app or lib, or in the --test list, is not a source)`.
4. With `--test`, a typed `test_*.rb` file inside such a test folder now exits 2 with the existing "looks like a test file" message.

---

## Reproductions (done by the planner, on `main` at `6c71ccba`)

Each probe ran in a temp project with `ruby -Ilib bin/mutineer` from an export of `origin/main`. Nothing in the repository changed.

| # | Limit | Command | Result on `main` | With the prototype |
|---|---|---|---|---|
| P1 | #552 item 1 | `run lib --since HEAD --since-paired-tests --test-command "ruby run.rb %{files}"`, 2 sources, 1 changed | Each run gets both test files. Stderr: `--since-paired-tests has no effect when --test-command is given` | Not built. With the optional patch of U2: each run gets `calc_test.rb` only |
| P2 | #552 item 4 | The same run in process, `--format json` | No key marks the run | `summary.tests_narrowed` is `true`. `false` without the flag |
| P3 | #554 item 3 | `run packs --format json` (one pack with `app/` and `test/`, 2 test files) | 2 test files in `unpaired_sources[]`, `unpaired_mutants` is 1 (a mutant of a test file) | `unpaired_sources[]` is empty, `unpaired_mutants` is 0. Stderr: `left out 2 files` |
| P4 | #554 item 4 | `run packs/catalog/test/models/test_item_extra.rb --test packs/catalog/test/models/item_test.rb` | Exit 0, the file is taken as a source | Exit 2, "looks like a test file, not a source" |
| P5 | #554 item 3 with `--test` | `run packs --test packs/catalog/test --format json` | **Wrong result, no message.** `per_source[]` holds `item_test.rb`. `total` is 2, both `no_coverage`, `score` is `null`. Minitest output follows the JSON on stdout, so the document does not parse. The same run with `packs/catalog/app` kills 1 of 1 | `per_source[]` holds `item.rb` only. 1 of 1 killed. Stdout is one JSON document |
| P6 | The same defect outside `packs/` | `run gems --test gems/calc/test --format json` (`gems/calc/lib` and `gems/calc/test`) | The same wrong result as P5 | 1 of 1 killed |
| P7 | #467 case 1 | `run lib/catalog.rb --test test/catalog_test.rb --test test/report_test.rb --strategy reload`. `report_test.rb` alone checks a constant that a method builds at load | The mutant of that method is `ran_at_load`. With `--test test/report_test.rb` alone it is `killed`. A `tests:` map entry for `report_test.rb` gives `ran_at_load` too | Not built |
| P8 | #501 frequency | A probe subclass of `CollectionMethod` counts each skip by name over 1,868 files (RuboCop 1.92.3, Sidekiq 8.1.6, Active Record, Active Support and Action Pack 8.1.4.1) | 18,517 methods. 450 skipped `each` / `map` statements. 0 skipped `first`, `last`, `min` or `max` statements. 0 truthiness-only skips. 5 `lazy` calls | Not built |
| P9 | A test beside its source | `run lib --test lib --format json` with `lib/calc.rb` and `lib/calc_test.rb` | The same wrong result as P5 | 1 of 1 killed (the `--test` list rule, KTD9) |
| P10 | The project root | `run . --test test --format json` in a gem with `lib/` and `test/` | The same wrong result as P5 | 1 of 1 killed. The same for the absolute root path, for `lib/..` and through a symlink to the root |
| P11 | Frequency of the U3 rule | `Pairing.expand_sources(["."])` on each of the 746 installed gem folders, as project roots | Not applicable | 47,513 files kept, 844 left out. 840 are under a top-level `test/` or `spec/`. 4 are tests of example apps (`examples/rails5/test/`). 0 are real sources |
| P12 | Limit L10 | `run lib --test-command "ruby args.rb --files=%{files}"` | Accepted. The command gets the text `--files=%{files}` unchanged | No change |

**P11 changed the rule.** The first form of the rule ("a `test` or `spec` folder beside an `app` or `lib` folder") left out two real sources in that sample: `lib/rails/commands/test/test_command.rb` in Railties (beside `lib/rails/commands/app/`) and `lib/opentelemetry/semconv/incubating/test/attributes.rb`. The rule now also says: not inside an `app` or `lib` folder (KTD6). After that change the count of real sources left out is 0.

Two limits are also pinned by tests that pass on `main`: `test_packs_directory_source_lists_the_pack_test_as_unpaired` in `test/cli_test.rb` and, for the JSON summary, `test_since_paired_tests_narrows_a_since_run`.

The prototype ran the whole default suite (`bundle exec rake test`): 2,551 runs, 4 failures. The 4 are the two tests above and the two schema version checks in `test/docs_contract_test.rb`. All 4 are expected, and units U1 and U3 change them. An earlier run with the optional patch of U2 added one expected failure (`test_since_paired_tests_has_no_effect_with_test_command`) and no other.

---

## Product Contract

### Summary

Three limits get a fix. The JSON report says when a run used a narrowed test list. A folder source such as `packs` gives sources only, and says how many files it left out. The test-file guard knows test folders outside the project root's own.

### Problem Frame

1. **JSON mark (#552 item 4).** A narrowed run can show a mutant as `no_coverage` where a full `--since` run shows `survived`. `summary.scoped` is `true` for both runs. Only stderr says that the run was narrowed.
2. **Test files in a folder source (#554 item 3).** `Pairing.expand_sources` gives every `.rb` file under a typed folder. For `packs` that includes `packs/<pack>/test/`. Without `--test`, each test file is listed as an unpaired source and its mutants count as unrun. With `--test`, the test file is loaded as a source in the parent process. Minitest then runs it at exit, on stdout, after the report (P5). The same holds for any folder that holds tests (P6, P9, P10).
3. **The guard (#554 item 4).** `Pairing.test_given_as_source?` flags a `test_*.rb` file only under the project's top-level `test/` or `spec/`.

### Requirements

- R1. `summary.tests_narrowed` is `true` when `since_paired_tests` gave the run fewer test files than pairing found. It is `false` in every other run, also when the setting is on and has no effect.
- R2. The key is in the JSON report of every backend. An in-process run and a `--daemon` run can set it to `true`. A `--test-command` run never narrows, so it reports `false`. The dry-run JSON document does not get the key.
- R3. `schema_version` is `1.12` in the reporter, in `docs/json-schema.md` and in `STABILITY.md`.
- R4, R5, R6. Only if U2 is built. See U2.
- R7. In `mutineer run`, a folder source does not yield a file inside a test folder below it. A test folder is a `test` or `spec` folder that sits beside an `app` or `lib` folder and is not inside an `app` or `lib` folder. The project root is a folder source too. A folder typed through a symlink follows the same rule.
- R8. A file the user typed is kept as typed. A folder the user typed that is itself inside a test folder keeps its files (but see R9).
- R9. With an explicit `--test` list, a folder source does not yield a file that is in that list.
- R10. When R7 or R9 left out one file or more, the run prints one stderr line with the count and the first path. The count is the number of different files that are not in the final source list. A run that left out nothing prints no line.
- R11. With `--test`, a typed `test_*.rb` file inside a test folder (R7) exits 2 with the existing guard message. The guard asks the disk only for a path inside the project root.
- R12. No mutant id changes. No verdict changes for a run that names no folder with a test file below it. `mutineer migrate` and the `sources:` folder of a `tests:` map read folders as on `main`.
- R13. `docs/equivalent-skips.md`, `docs/equivalent-skips.html` and the class comment of `CollectionMethod` name the `min` / `max` comparator limit with #501.
- R14. Each limit that stays open is named in an open issue (see "Limits left open").

### Acceptance Examples

- AE1. **Covers R1, R2.** Given the fixture of `with_since_autopair_project`. When `run lib --since HEAD --since-paired-tests --format json` runs. Then `summary.tests_narrowed` is `true`. When the same run has no flag, then it is `false`.
- AE2. **Covers R1.** Given the same project and `--baseline base.json`. When the run has the flag. Then the run keeps every test and `summary.tests_narrowed` is `false`.
- AE3, AE4, AE5. Only if U2 is built. See U2.
- AE6. **Covers R7, R10.** Given the fixture `test/fixtures/packs_layout`. When `run packs --format json` runs. Then `unpaired_sources[]` holds `packs/billing/app/models/invoice.rb` only, stderr holds "no test found by convention" once, and stderr holds `left out 1 file, such as packs/catalog/test/models/item_test.rb` once.
- AE7. **Covers R7 (P5).** Given the same fixture. When `run packs --test packs/catalog/test --format json` runs. Then `JSON.parse` reads the whole of stdout, no `per_source[]` row is under `packs/catalog/test`, and the row of `packs/catalog/app/models/item.rb` has all its mutants killed. (The fixture has a second pack, `billing`, with no test. Its source is in the run and is `no_coverage`. Do not assert on `summary.total`.)
- AE8. **Covers R8.** `Pairing.expand_sources(["packs/catalog/test"], project_root:, left_out: out)` on that fixture gives `packs/catalog/test/models/item_test.rb`, and `out` stays empty.
- AE9. **Covers R11.** Given a file `packs/catalog/test/models/test_item_extra.rb` written into the temp copy. When it is typed as a source with `--test packs/catalog/test/models/item_test.rb`. Then the run exits 2 and stderr holds "looks like a test file, not a source".
- AE10. **Covers R7, rule table.** `Pairing.test_folder_path?` gives the value in the table of U3 for each row.
- AE11. **Covers R7 (P6, P10).** Given a temp tree with `gems/calc/lib/calc.rb` and `gems/calc/test/calc_test.rb`. When `run gems --test gems/calc/test --format json` runs. Then stdout parses and `per_source[]` holds `gems/calc/lib/calc.rb` only. Given that gem folder as the project root. When `run . --test test --format json` runs. Then the same holds for `lib/calc.rb`.
- AE12. **Covers R9, R10 (P9).** Given `lib/calc.rb` and `lib/calc_test.rb`. When `run lib --test lib --format json` runs. Then stdout parses, `per_source[]` holds `lib/calc.rb` only, and stderr holds `left out 1 file, such as lib/calc_test.rb`.
- AE13. **Covers R10.** A run of `lib` in a project with no test under `lib` prints no `left out` line.
- AE14. **Covers R10, the count.** On `test/fixtures/packs_layout`: `run packs packs/catalog/test` prints no `left out` line, and `expand_sources(["packs", "packs/catalog/test"], left_out: out)` leaves `out` empty. `run packs packs/catalog` prints `left out 1 file`.
- AE15. **Covers public contract change 2.** On the same fixture: `run packs/catalog/test --test packs/catalog/test` exits 2. Stderr holds the `left out 1 file` line and then `run requires at least one source file`.
- AE16. **Covers R12.** `Pairing.expand_sources(["packs"], project_root:)` with no `left_out:` gives the same list as on `main`, with the pack test file in it.

### Scope Boundaries

Not in this group:

1. Any change to the code of `lib/mutineer/mutators/collection_method.rb` (#501). A new or removed skip shifts mutant ids in that method until #508 (2.0). U5 changes one comment there.
2. Any change to `lib/mutineer/coverage_map.rb` or `lib/mutineer/coverage_map/` (#467, #552 items 5 and 6). Group 11-F owns that code.
3. #552 item 1 (unit U2, not built) and item 2 (it depends on #421).
4. A mark for a narrowed run in the HTML report, the human report or the GitHub Action step summary. `action.yml` does not change.
5. Pack roots by name (`engines/`, `pack_paths`) and a `{path}` placeholder (#554 items 1 and 2).
6. The cases of limits L1 and L10.
7. A `--no-baseline` flag (#552 item 3).

### Decisions for David

The run takes each recommendation. David can change any of them before the merge.

| # | Choice | Recommended | Other option | Why |
|---|---|---|---|---|
| D1 | #467 | Move to `v2.0`, build nothing | Build the one safe part now: a `tests:` map entry keeps a source's load-only lines (`Refs #467`, unit U3 of `wip/2026-11-22-v1.10.0-round2/plans/group-R-load-time-redefine-plan.md`) | The full fix needs a rule for which tests judge code that runs at load. Every such rule moves `ran_at_load` mutants into the score, as #286 and #507 do, and both are 2.0. The safe part reverses a recorded decision ("Load-Only Line Pairing") and changes cache code one group before 11-F, for a case the report already counts as `ran_at_load` (P7). |
| D2 | #501 | No code. One docs sentence (U5). Label to `backlog`, issue stays open | Close #501 as not planned | Each open item needs the class of the receiver. P8 found 0 cases for items 4, 5 and 6. The issue stays open because the docs cite it for limits that can hide a killable mutant. |
| D3 | #552 item 1 (`--test-command` narrows) | Do not build it in 1.11.0. Keep it as documented | Build unit U2 now, as a second commit (`Refs #552`). The unit and its patch are in this plan | Gain: that backend has no coverage map, so each mutant runs every test (P1: 2 test files become 1). Against: no user asked. A user who set `since_paired_tests` with `--test-command` gets a full run in 1.10.0, and would get new survivors after the upgrade, because a kill by another source's test shows as `survived` there. The rate of such lost kills is not measured (#553, step 1). The first draft of this plan built it. The simplicity lens and the Codex review both questioned it, and Codex found a defect in it (L10). |
| D4 | The JSON key | `summary.tests_narrowed`, a boolean | An object with the two counts, or the name `since_paired_tests` | `summary.scoped` is the model: a boolean that states a fact of the run. The setting can be on and have no effect, so its name would mislead. Counts can be added later as a new key. |
| D5 | The rule of U3 | A `test` or `spec` folder beside an `app` or `lib` folder, in any place | `packs/<pack>/test` and `packs/<pack>/spec` only | P6 and P10 show the same wrong result outside `packs/`. The two rules have about the same size. P11 found 0 real sources left out in 746 gem folders. |
| D6 | A message for the files a folder source leaves out | One stderr line with the count and the first path (R10) | No message | "Count what you exclude" in `.expectation-fit/ways-of-working.yaml`. The line also tells a user with a real source in such a folder what happened. It prints on each run that names such a folder. |
| D7 | Where the rule of U3 applies | `mutineer run` only (with and without `--dry-run`) | Also `mutineer migrate` and the `sources:` folder of a `tests:` map | A map entry such as `sources: tools` can pair a typed file in `tools/test/` today. With the rule there, that entry could stop matching and exit 2. Those two callers do not load files, so they do not have the defect. |
| D8 | Labels after the build | #552, #554, #501 to `backlog`. #467 to `v2.0` | Keep `v1.11.0` until the release, or close them | What is left in them is not planned for 1.11.0. `gh issue edit <N> --add-label v1.11.0 --remove-label backlog` undoes it. |
| D9 | A pack or a namespace folder that is itself named `test` or `spec` and sits beside `app` or `lib` (for example `packs/a/test/app/` with `packs/a/app/` present) | It is read as a test folder. The stderr line shows it. Typing the folder keeps it (limit L1) | A rule that reads a `test` folder with its own `app` and `test` folders as a pack | The name is rare, and the second rule would also read a dummy app inside a test folder (`test/dummy/app`) as a pack. |
| D10 | A test beside its source (P9) | Fix it here with the `--test` list rule (R9, about 9 lines in `CLI.start`) | File it as a new issue | It is the same wrong result as P5, the fix is small, and it has no false match: a file that the run uses as a test cannot be a useful source. |

**Uncertain:**

- D1: this plan does not show that nothing in #467 can be fixed in 1.x. One part can (see "Other option"). The plan says it is not worth the change now.
- D3: the gain of U2 was not measured on a real suite. P1 shows only that the test list gets shorter.
- D5: no real Packwerk app was run. The rule was run on the repository fixture, on four temp projects, on 746 gem folders (P11) and through the whole test suite.
- D6: the line prints on every `run packs`. If that is noise in CI logs, the other option is one deleted `warn`.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. The mark is set where the list is narrowed.** `JobPlan.narrow_tests_for_since` returns `config` itself when nothing narrows. `Runner.execute` and `DaemonBackend.execute` compare the result with `equal?`, as `DaemonBackend.execute` already does, and write `extras[:tests_narrowed]`. `CLI.execute` passes `extras.fetch(:tests_narrowed, false)` to `Reporter#report`. A `--test-command` run and a library caller send no value and get `false`.
- **KTD2. The reporter keeps the value as `@tests_narrowed`**, as it keeps `@callback_growth`. `json_report` writes `tests_narrowed: @tests_narrowed == true` after `scoped`.
- **KTD3, KTD4, KTD5.** Only if U2 is built. See U2.
- **KTD6. `Pairing.test_folder_path?(rel, root, below: "")` is the one folder rule** for U3 and U4. A segment `test` or `spec` counts when (a) no earlier segment of the path is `app` or `lib`, and (b) an `app` or `lib` folder exists beside it on disk. Segments at or above `below` do not count (R8). Part (a) comes from P11.
- **KTD7. `Pairing.expand_sources` filters the folder branch only, and only when the caller passes `left_out:`.** With no `left_out:`, the result is the list of `main` (AE16). `below` is the typed folder as the files are named: `root_relative(abs)`, or `existing_relative(abs)` for a symlinked parent, or `root_relative(File.realpath(abs))` for a symlink to a folder. For the project root (typed, or its real path), `below` is `""`. A folder outside the root is not filtered. The file branch does not change.
- **KTD8. `left_out:` is an Array that the caller owns.** When the method returns, it holds each left-out path once, and no path that the returned list holds (a second argument can keep a file that the first one left out). The method prints nothing. The prototype does the second part in `CLI.start` and does not remove repeats: move both into `expand_sources`. AE14 fails on the bare prototype for `run packs packs/catalog`.
- **KTD9. The `--test` list rule lives in `CLI.start`**, after `expand_sources`, only when `config.explicit?(:tests)`. It removes from `config.sources` each file that is in `config.tests` and was not typed as an argument. Compare absolute paths. It adds the removed files to the same `left_out` list. Then one `warn` prints the line of R10.
- **KTD10. No change to `PACK_SOURCE`, `pack_split` or `pack_tests`.** Pairing does not change.

### Sequencing

U1 first. U3 and U4 are one commit and do not depend on U1. U5 is docs and one comment. U6 has no commit, but its step 1 comes before the commit of U3.

### Assumptions

- A1. No user relies on a test file being listed as an unpaired source. The list is a warning, not an input.
- A2. `main` gets no other JSON key before this pull request merges. If group 11-F adds one in 1.11.0, it also uses schema `1.12`.

### Risks

| Risk | Effect | Check |
|---|---|---|
| U3: a real source in a `test` or `spec` folder beside `app` or `lib`, at the project root, in a pack or in a gem folder | A folder source in `mutineer run` no longer yields it | The stderr line of R10 shows the count and one path. Type that folder to keep it (R8). 0 cases in P11. Named in the docs and in limit L1 |
| U3: a run whose only sources were test files | It now exits 2 where it exited 0 with a wrong report | AE15. Named in the CHANGELOG |
| U1: a doc copy keeps `1.11` | A stale contract | `test_json_schema_page_and_source_name_the_reporter_schema_version` and `test_stability_names_the_reporter_schema_version` fail until both files say `1.12` |

---

## Implementation Units

The prototype patch holds the `lib/` code of U1, U3 and U4. Hunks by unit: U1 is `reporter.rb`, `daemon_backend.rb`, `runner.rb` and the `reporter.report` hunk of `cli.rb`. U3 and U4 are `pairing.rb` and the `CLI.start` hunk of `cli.rb`. The plan text wins if the two differ (KTD8 is one such place).

### U1. The JSON report marks a narrowed run (commit 1, #552 item 4)

- **Goal:** `summary.tests_narrowed` and schema `1.12`.
- **Requirements:** R1, R2, R3. **Dependencies:** none.
- **Files, code:**
  - `lib/mutineer/runner.rb`, `Runner.execute`: keep the result of `JobPlan.narrow_tests_for_since` in a local, set `since_extras[:tests_narrowed]`, then assign `config`.
  - `lib/mutineer/daemon_backend.rb`, `DaemonBackend.execute`: `extras[:tests_narrowed] = narrowed` after the existing `narrowed =` line.
  - `lib/mutineer/cli.rb`, `CLI.execute`: add `tests_narrowed: extras.fetch(:tests_narrowed, false)` to the `reporter.report` call.
  - `lib/mutineer/reporter.rb`: `SCHEMA_VERSION = "1.12"`. `Reporter#report` gets `tests_narrowed: false` and a paragraph in its comment. `json_report` writes the key (KTD2).
- **Files, tests:**
  - `test/json_reporter_test.rb`: a new test beside `test_scoped_run_records_scoped_true`. The key is `false` with no argument and `true` with `tests_narrowed: true`. Update the comment at the `SCHEMA_VERSION` assertion ("1.12 = tests_narrowed").
  - `test/baseline_test.rb`: the same comment.
  - `test/cli_test.rb`, `test_since_paired_tests_narrows_a_since_run`: assert `true` for the narrowed run and `false` for the full run. Compare the two summaries with `.except("seconds", "tests_narrowed")` (AE1). This test is the end-to-end check of the path from the backend to the JSON text.
  - `test/cli_test.rb`, `test_since_paired_tests_keeps_every_test_under_baseline`: assert `false` under `--baseline` (AE2).
  - `test/daemon_backend_contract_test.rb`, `assert_daemon_since_tests`: this test stops the run before the backend returns, so it cannot read the report. It checks the value that the daemon backend sets: the `keep_a` stub of `scope_since` gets `extras:` as a keyword, and that Hash is the one the backend writes to. Keep it. After the run stops, assert that its `:tests_narrowed` is `true` with no baseline and `false` with one.
- **Files, docs:**
  - `docs/json-schema.md`: the version in the "Versioning contract" example, in the top-level shape block and in the dry-run block. The dry-run sentence becomes "reports schema `1.12` and gained no key in it". A new `summary` row after `scoped`:
    `tests_narrowed` | bool | `true` when `since_paired_tests` gave this run fewer test files than pairing found (see "Tests of the changed sources" in `cli.md`). A mutant that only a dropped test reaches shows as `survived` or `no_coverage`, so do not compare the score with a full run's. It marks only this cut of the test file list. It is `false` for an explicit `--test` list, for `--only`, for `--test-command`, and for the choice of covering tests for each mutant. It is `true` only in a run where `scoped` is also `true`. Absent in older reports: treat absent as `false`. Additive key (schema `1.12`, #552).
  - `STABILITY.md`: both version lines ("1.11.0 reports `1.12`", "1.11.0 adds `summary.tests_narrowed` as `1.12`").
  - `docs/cli.md`, "Tests of the changed sources": one sentence after the stderr example: "In a JSON report, `summary.tests_narrowed` is `true` for such a run."
  - `CHANGELOG.md`, "Added".
  - The plan copy: `docs/plans/2026-11-27-552-554-feat-known-limits-plan.md`.
- **Siblings ("Cover the siblings"):** in process and `--daemon` set the value. `--test-command` never narrows (R2). Minitest and RSpec share the code. The dry-run JSON has no test run, so no key. The HTML report, the human report and the Action step summary get no mark (limit L2).
- **Verification:** the two docs contract tests pass. `bundle exec rake site:build` and `node --test test/site_test.js` pass. `_site/llms-full.txt` holds the `tests_narrowed` row.

### U2. Not built: `since_paired_tests` narrows a `--test-command` run (#552 item 1)

**Do not build this unit in this run** (decision D3). It stays here so that a later yes needs no new plan. Patch: `11-E-known-limits-optional-u2.patch` (it applies on top of the prototype patch).

- **Requirements, if built:** R4: a `--test-command` run under `--since` with `since_paired_tests` and no `--test` passes only the narrowed list to the command, for the clean run and for each mutant run. R5: `--test`, `--baseline` and a dry run keep the full list. R6: the run prints one stderr line that does not name `no_coverage` and names `--no-since-paired-tests`.
- **Key decisions:** KTD3: `JobPlan.since_narrowing_line` gets `test_command: false`. Build the first sentence once and append one of two tails. With `true`, the tail is "A mutant that only another test kills shows as survived, so a --threshold gate can fail where a full run passes: gate on a full run (--no-since-paired-tests), or add --baseline, which keeps every test." KTD4: `Runner.execute_external` narrows after the empty-jobs return and before `ExternalBackend.smoke_check!`, and sets `extras[:tests_narrowed]`. KTD5: `CLI.warn_unused_since_paired_tests` loses the `--test-command` reason.
- **A guard that the patch does not have (limit L10):** narrow only when `Shellwords.split(config.test_command)` holds the word `%{files}` on its own. With the token inside a word, the command never gets the list, so the run must keep the full list and print "has no effect". Put the check in `JobPlan.since_tests`. This guard was not run in planning: write its test first.
- **Acceptance examples, if built:** AE3: with `--test-command "<ruby> run.rb %{files}"` on `with_since_autopair_project`, each logged line holds `calc_test.rb` only, stderr holds the new line once and no "has no effect", and `summary.tests_narrowed` is `true`. AE4: with `--test`, or with `--baseline`, each logged line holds both files and stderr names the reason. AE5: a project where `test/price_test.rb` does not kill a mutant of `Price#total` and `test/cart_test.rb` does (it must assert on the result: the `cart_test.rb` of `with_hidden_survivor_project` calls `total` and asserts nothing about it). Narrowed: `survived`. Not narrowed: `killed`.
- **Tests:** `test_since_paired_tests_has_no_effect_with_test_command` in `test/cli_test.rb` becomes a narrowing test. `test/since_test_scope_test.rb` gets a table row and a test of the new line.
- **Docs copies (10 edits in 6 files):** `README.md` (the flag row). `docs/cli.md` (the option row, the config row, "Tests of the changed sources", and the bullet "`--test-command`. No coverage map is built. The clean run runs every `--test` file."). `docs/ci.md` (two places). `STABILITY.md` (after "`since_paired_tests` is new in 1.10.0"). `.expectation-fit/decisions/coverage-and-test-selection.md` ("Scope of since_paired_tests"). `CHANGELOG.md`, "Changed", with the words "Behavior change" and `--no-since-paired-tests` as the way back. Also the help text in `lib/mutineer/cli.rb` and two comments (`config.rb`, `job_plan.rb`).

### U3. A folder source leaves out test files (commit 2, #554 item 3)

- **Goal:** R7, R8, R9, R10, R12. **Dependencies:** U6 step 1 (the number of the new issue).
- **Files, code:**
  - `lib/mutineer/pairing.rb`: the new `test_folder_path?` (KTD6, with a YARD comment), the filter and `left_out:` in `expand_sources` (KTD7, KTD8) with a `@param` line, one sentence in the comment of `expand_sources`, and one line in the list at the top of the file.
  - `lib/mutineer/cli.rb`, `CLI.start`, the `run` branch: pass `left_out:`, KTD9, and the `warn` of R10. The `migrate` branch does not change.
- **Rule table for AE10.** Tree: `lib/`, `test/`, `packs/catalog/app/`, `packs/catalog/test/`, `packs/catalog/spec/`, `packs/a/test/app/` (no `packs/a/app`, no `packs/a/lib`), `packs/b/app/`, `packs/b/test/app/`, `gems/calc/lib/`, `gems/calc/test/`, `lib/foo/test/`, `lib/foo/lib/`, `lib/cmd/app/`, `lib/cmd/test/`, `app/`, `app/lib/`, `app/test/`, `app/models/test/`.

  | Path | `below` | Result | Why |
  |---|---|---|---|
  | `test/a_test.rb` | `""` | true | The project root |
  | `test/a_test.rb` | `"test"` | false | The typed folder |
  | `packs/catalog/test/models/item_test.rb` | `"packs"` | true | |
  | `packs/catalog/spec/support/x.rb` | `"packs/catalog"` | true | A helper, not only a test name |
  | `packs/catalog/test/lib/x_test.rb` | `"packs"` | true | The first test folder decides |
  | `packs/catalog/test/models/item_test.rb` | `"packs/catalog/test"` | false | The typed folder |
  | `packs/catalog/app/models/item.rb` | `"packs"` | false | |
  | `packs/a/test/app/models/x.rb` | `"packs"` | false | A nested pack named `test`, nothing beside it |
  | `packs/b/test/app/models/x.rb` | `"packs"` | true | Decision D9: `packs/b/app` is beside it |
  | `gems/calc/test/calc_test.rb` | `"gems"` | true | |
  | `lib/foo/test/test_app.rb` | `"lib"` | false | Inside `lib` |
  | `lib/cmd/test/test_command.rb` | `"lib"` | false | Inside `lib`, beside `lib/cmd/app` (the Railties case of P11) |
  | `app/test/runner.rb` | `"app"` | false | Inside `app`, beside `app/lib` |
  | `app/models/test/result.rb` | `"app"` | false | |
  | `test.rb` | `""` | false | A file, not a folder |

- **Files, tests:**
  - `test/pairing_test.rb`: AE10 as one table test. `expand_sources` tests with `left_out:`: `packs` gives the `app` files only and fills the list; `.`, the absolute root path, `lib/..` and a symlink to the root give no file of the top-level `test/`; a folder typed through a symlinked parent is filtered; AE8; AE14; a typed file inside a test folder stays; a folder outside the root is not filtered. AE16 with no `left_out:`. One test of the rule over every tree in `test/fixtures` that has an `app` or `lib` folder at its top: `expand_sources(["."], left_out: out)` loses only files whose path has a `test` or `spec` segment, and keeps no file under the top-level `test/` or `spec/` ("Test the rule, not the example").
  - `test/cli_test.rb`: `test_packs_directory_source_lists_the_pack_test_as_unpaired` becomes `test_packs_directory_source_leaves_out_the_pack_test_folder` (AE6). New tests for AE7, AE11, AE12, AE13, AE14 and AE15. Parse stdout with `JSON.parse(out)` on the whole string, so a second document or Minitest output fails the test.
- **Files, docs:**
  - `docs/ci.md`: replace "Pass pack source folders, such as `packs/*/app`, not `packs`. A source folder that holds test files lists each test file as an unpaired source." with the two rules (R7 with one example, R9), the stderr line, and the way out: type the folder to keep its files. Then one sentence on what stays, with the number of the new issue (L1).
  - `docs/getting-started.md`, the `packs/` paragraph: one sentence that `mutineer run packs` leaves out each pack's `test/` and `spec/` folder.
  - `.expectation-fit/decisions/pairing-of-sources-and-tests.md`: a new line by hand, "Test Files In A Folder Source", with R7, R8, R9 and D7, the Railties example for "not inside `app` or `lib`", and "(#554)".
  - `CHANGELOG.md`, "Fixed": name P5 (a test file scored as a source, Minitest output after the JSON report), the new stderr line, the fall of `unpaired_sources` and `unpaired_mutants`, and the exit 2 of public contract change 2. Claim the fix only for a test folder below the typed folder and for a file in the `--test` list.
- **Siblings:** `run` and `run --dry-run` get R7, R9 and the line of R10. `migrate` and the `sources:` folder of a `tests:` map do not (D7, AE16). A glob or a file argument is not a folder and does not change. In process, `--daemon` and `--test-command` share `CLI.start`. Under `--test-command`, a `--test` folder stays a folder in the test list, so R9 does not see its files (limit L1).
- **Verification:** the dogfood commands in `.github/workflows/ci.yml` name `lib` and `app`. `bundle exec mutineer run lib --dry-run` gives the same count on the branch and on `main`, and prints no `left out` line.

### U4. The test-file guard reads test folders (commit 2, #554 item 4)

- **Goal:** R11. **Dependencies:** U3.
- **Files, code:** `lib/mutineer/pairing.rb`, `test_given_as_source?`: for a `test_*.rb` name, return true under the top-level `test/` or `spec/` (as on `main`), or when the path is inside the root and `test_folder_path?` is true. Update the comment of the method: it now reads the disk for that name form, inside the root only.
- **Files, tests:** `test/pairing_test.rb`: `packs/catalog/test/models/test_item.rb` is flagged. `lib/foo/test/test_app.rb` is not (already pinned, keep it). An absolute path outside the root and `../other/test/test_a.rb` with `../other/lib` on disk are not flagged, as on `main`. `packs/b/test/app/models/test_runner.rb` is flagged (D9). `test/cli_test.rb`: AE9.
- **Files, docs:** the CHANGELOG entry of U3 gets one sentence.

### U5. The docs name the `min` / `max` comparator limit (commit 3, #501 item 6)

- **Goal:** R13. **Dependencies:** none.
- **Files:**
  - `docs/equivalent-skips.md` and its twin `docs/equivalent-skips.html`, in the "Collection method" paragraph that starts "`select`, `reject`, `first`, `last`, `min`, and `max` are skipped when the call is a statement of its own". Add after the sentence about a `min` or `max` with a block:
    "A `min` or `max` with no block compares elements with `<=>`, and the swap changes which pairs `<=>` sees. A `<=>` with a side effect, such as a counter or a log line, can show that difference. The skip does not look at the comparator (#501). Measured on 2026-11-27: in 18,517 methods of five gems, the operator skipped no `first`, `last`, `min` or `max` statement."
  - `lib/mutineer/mutators/collection_method.rb`, the class comment: after "No test can tell such a mutant from the original.", add "A `<=>` with a side effect can, for a `min` or `max` with no block (#501)." Comment only. No code line changes.
  - `CHANGELOG.md`, "Changed": one line, no behaviour change.
- **Verification:** the website checks in `AGENTS.md`. `bundle exec mutineer run lib/mutineer/mutators/collection_method.rb --dry-run` gives the same mutant count on the branch and on `main`.

### U6. Issues: two new issues, comments, labels (no commit)

Start each comment with `**Claude:**`.

1. **Before the commit of U3:** file the issue of limit L1 with `gh issue create` and the labels `bug`, `priority: low`, `risk: medium`, `backlog`. Title: "A folder source still reads some test files as sources". Body in What, Why, How form, from the L1 row. Put its number in `docs/ci.md` and in the CHANGELOG entry (U3), and in the #554 comment below in place of `<L1>`.
2. File the issue of limit L10 with the labels `bug`, `priority: low`, `risk: low`, `backlog`. Title: "`--test-command` accepts `%{files}` inside a word and then passes the text unchanged". Body from the L10 row and probe P12.
3. **When the pull request is marked ready:** post the four comments of "Issue comments". Put the pull request number in place of `<PR>`.
4. **Then the labels:** #552, #554 and #501: `gh issue edit <N> --add-label backlog --remove-label v1.11.0`. #467: `gh issue edit 467 --add-label v2.0 --remove-label v1.11.0`.
5. Add to #553 one comment: item 8 of #552 (the measured rate of lost kills) is its step 1, and item 1 of #552 (`--test-command`) waits for that measurement.

---

## Commit order

1. `feat: the JSON report marks a run that since_paired_tests narrowed (Refs #552)` - U1 and the plan copy.
2. `fix: a folder source leaves out test files, and the test-file guard reads test folders (Refs #554)` - U3 and U4.
3. `docs: name the min and max comparator limit of collection_method (Refs #501)` - U5.

Pull request title: `feat: the JSON report marks a narrowed run, and a folder source leaves out test files (Refs #552, #554, #501)`. Labels: `enhancement`, `v1.11.0`, `priority: low`, `risk: low`. No `Closes` line: each issue stays open.

## Verification Contract

Before each push (`AGENTS.md`, "Before every commit"):

```sh
bundle exec rake test
ruby -Ilib -e 'require "mutineer"'
bundle exec rake yard:strict
bundle exec rake test:daemon        # U1 changes daemon_backend.rb
bundle exec rake site:build && node --test test/site_test.js
npm ci --prefix test/browser && npx --prefix test/browser playwright install chromium && npm test --prefix test/browser
```

The Minitest 6 and Prism 2 runs are not needed: no unit changes the Minitest integration or parsing.

## Definition of Done

- AE1, AE2 and AE6 to AE16 pass. The four tests that fail with the bare prototype pass in their new form.
- The exact-survivor oracle passes with no edit.
- Each doc copy in U1, U3 and U5 is updated, and the author self-check skill is clean.
- The pull request body has What, Why, How, "Decisions for David" (D1 to D10 with the option taken), "Planned by" and "Built by", and the probe table P1 to P12.
- U6 is done, and the number of the L1 issue is in `docs/ci.md`.
- `reports/11-E.md` and one line in `runs.jsonl` are written.

---

## Limits left open

| # | Limit | Issue |
|---|---|---|
| L1 | A folder source still yields some files that are not sources. (a) With no `--test`, a test beside its source, or in a test folder the rule does not know (`tests/`, `features/`, a `test` folder with no `app` or `lib` beside it, a test folder inside `app` or `lib` such as `app/packs/x/test/` or `lib/my_gem/spec/`), is listed as an unpaired source. (b) With `--test`, a helper in such a folder is still loaded as a source, and if it requires `minitest/autorun`, the JSON report breaks as in P5. (c) Under `--test-command`, a `--test` folder stays a folder in the test list, so the `--test` list rule does not see its files. (d) A real source in a `test` or `spec` folder beside `app` or `lib` is left out unless that folder is typed. That includes a nested pack whose own folder is named `test` (D9) | **New issue, filed by the builder (U6 step 1):** "A folder source still reads some test files as sources". Labels `bug`, `priority: low`, `risk: medium`, `backlog` |
| L2 | The HTML report, the human report and the GitHub Action step summary do not mark a narrowed run | #552 (comment, item 4) |
| L3 | #552 item 1: `--test-command` does not narrow. Unit U2 of this plan is ready | #552 (comment, item 1). It waits for the measurement of #553 |
| L4 | #552 item 2 (an explicit `--test` list) | #552, waits for #421 |
| L5 | #552 items 3, 5, 6, 7 as documented | #552 |
| L6 | #552 item 8, no measured rate of lost kills | #553 (2.0), step 1 |
| L7 | #554 items 1 and 2: other pack roots, `{path}` placeholder | #554 |
| L8 | #501 items 1, 4, 5, 6 | #501. A change waits for #508 |
| L9 | #467, both cases | #467 (`v2.0`) |
| L10 | `--test-command` is accepted when `%{files}` is inside a word, such as `--files=%{files}`. `ExternalBackend.build_argv` replaces only a word that is exactly `%{files}`, so the command gets the text unchanged and no test list (P12). Older than this plan | **New issue, filed by the builder (U6 step 2):** "`--test-command` accepts `%{files}` inside a word and then passes the text unchanged". Labels `bug`, `priority: low`, `risk: low`, `backlog` |

## Files this group changes

- Code: `lib/mutineer/runner.rb`, `lib/mutineer/daemon_backend.rb`, `lib/mutineer/cli.rb`, `lib/mutineer/reporter.rb`, `lib/mutineer/pairing.rb`, `lib/mutineer/mutators/collection_method.rb` (comment only).
- Tests: `test/cli_test.rb`, `test/json_reporter_test.rb`, `test/baseline_test.rb` (comment only), `test/daemon_backend_contract_test.rb`, `test/pairing_test.rb`.
- Docs: `STABILITY.md`, `CHANGELOG.md`, `docs/cli.md`, `docs/ci.md`, `docs/json-schema.md`, `docs/getting-started.md`, `docs/equivalent-skips.md`, `docs/equivalent-skips.html`, `docs/plans/2026-11-27-552-554-feat-known-limits-plan.md`.
- Decision file: `.expectation-fit/decisions/pairing-of-sources-and-tests.md`.

Not changed: `lib/mutineer/coverage_map.rb`, `lib/mutineer/coverage_map/`, `lib/mutineer/job_plan.rb`, `lib/mutineer/external_backend.rb`, `action.yml`, `lib/mutineer/version.rb`.

Shared with group 11-F (not planned yet): `CHANGELOG.md`, and `runner.rb`, `cli.rb` and `reporter.rb` if 11-F adds a report key. Build 11-E before 11-F, as the worklist says.

---

## Issue comments (ready to paste)

Replace `<PR>` with the pull request number and `<L1>` with the number of the new issue.

**#552**

```text
**Claude:** Pull request #<PR> (open, not merged yet) takes one item of this list for 1.11.0.

- Item 4: summary.tests_narrowed in the JSON report (schema 1.12). The HTML report, the human report and the Action step summary still have no mark.
- Item 1: open. A --test-command run still keeps every test. A plan for it is ready (unit U2 in docs/plans/2026-11-27-552-554-feat-known-limits-plan.md, in that pull request). It was not built: a kill by a test of another source would show as survived there, a user who already set since_paired_tests would see that after an upgrade, and the rate of such lost kills is not measured (#553, step 1).
- Item 2: open. It waits for #421.
- Items 3, 5, 6, 7: open, as documented. --baseline guards item 3 since #557.
- Item 8: the measurement is step 1 of #553.

The label moves from v1.11.0 to backlog, because what is left is not planned for 1.11.0.
```

**#554**

```text
**Claude:** Pull request #<PR> (open, not merged yet) takes two items of this list for 1.11.0.

- Item 3: in `mutineer run`, a folder source leaves out a test or spec folder that sits beside an app or lib folder, and each file of the --test list. So `mutineer run packs` gives sources only, and one stderr line gives the count. Before, with --test, the run scored the pack test file as a source and printed Minitest output after the JSON report.
- Item 4: the test-file guard flags a test_*.rb file inside such a folder.
- Items 1 and 2: open. A tests: map covers other pack roots today.
- The cases that stay for a test file in another place are in #<L1>.

The label moves from v1.11.0 to backlog, because what is left is not planned for 1.11.0.
```

**#501**

```text
**Claude:** Triage for 1.11.0. Items 2 and 3 shipped in 1.10.0 (#550). Items 1, 4, 5 and 6 stay as documented. Pull request #<PR> (open, not merged yet) adds item 6 to the docs.

- Each open item needs the class of the receiver. The operator reads the syntax tree only.
- Measured on 2026-11-27 with the operator's own check, over 18,517 methods in 1,868 files (RuboCop 1.92.3, Sidekiq 8.1.6, Active Record, Active Support and Action Pack 8.1.4.1): 0 skipped first, last, min or max statements (items 4 and 6), 0 truthiness-only skips (item 5), and 450 skipped each or map statements (the upper limit for item 1). The same files hold 5 lazy calls.
- A new skip rule shifts mutant ids in that method (#508, planned for 2.0). A change here waits for #508. One option for then: remove the skip of a first, last, min or max statement, which fired 0 times in the sample. That closes items 4 and 6.

The label moves from v1.11.0 to backlog. A report of a real case changes this.
```

**#467**

```text
**Claude:** The label moves from v1.11.0 to v2.0, where #507 and #286 already are.

- Reproduced on main at 6c71ccba: with the paired test and one other test in the run, a mutant of a method that builds a constant at load is ran_at_load. With the other test alone it is killed. A tests: map entry for that test does not change the result.
- Correction to case 1: the lost kill shows as ran_at_load, which the report counts. It does not show as survived.
- Why 2.0: a full fix needs a rule for which tests judge code that runs at load. Each such rule moves ran_at_load mutants into the score, as #286 and #507 do.
- One part is safe in 1.x and is not built: a tests: map entry could keep a source's load-only lines. It reverses the rule that only a convention pair keeps those lines, and it changes the coverage cache code, so it waits for a maintainer's yes.
```

---

## Plan review

- **`/fit-validate-plan`, round 1**, on the first text of this plan (four lenses): report `reports/11-E-plan-fit-validate-round1.md`. After the merge: 1 P1, 6 P2 and 11 P3 findings (4 of the P3 are below the confidence gate). All are applied. The main changes:
  - P1: the first prototype did not filter the project root (`run .`). Fixed in KTD7, P10 and AE11.
  - P2: no count for the files a folder source leaves out, and no frequency estimate. D6 was reversed (one stderr line), and P11 is the estimate. P11 found two real sources that the first rule left out, so the rule changed (KTD6).
  - P2: the new issue was filed after the commit that cites it. U6 step 1 now comes first.
  - P2: the wrong result of P9 stayed with no message. The `--test` list rule (R9, D10) fixes it.
  - AE7 and AE8 could not pass on the fixture they named. Both are rewritten.
- **Round 2**, predictability lens only, on the revised text: all six of its round 1 gaps are closed. Two new findings, both applied: the count in the stderr line (P2: KTD8, R10, AE14) and the new exit 2 (P3: public contract change 2, AE15). Scores: 8, 9, 8 and 7 of 10 (round 1: 6, 9, 6 and 6).
- **Codex second opinion** (`gpt-6.2-sol`, read only, on the round 2 text and patch). It agrees with `go without #467`. Seven findings:
  - Applied: the rule no longer changes `migrate` or the `tests:` map (D7, KTD7, AE16). A folder typed through a symlink is filtered (KTD7). The daemon test and the AE5 fixture are corrected (U1, U2). The class comment of `CollectionMethod` names the limit (U5). A `%{files}` token inside a word is limit L10, with a guard in U2.
  - Applied as a changed decision: Codex asked to move the `--test-command` narrowing out of 1.11.0. D3 now recommends that, and U2 is not built.
  - Declined: a rule that gives a nested pack named `test` its own source root (D9). The case is named in L1 and in the rule table.
- After the last change, the prototype ran the whole default suite again: 2,551 runs, the 4 expected failures.

## Sources

- Issues #501, #552, #554, #467, #507, #553, #494 and #508, and pull request #550, read with `gh` on 2026-11-27. #552 has one comment (the `--baseline` guard of #557). The others have none.
- `AGENTS.md`, `.expectation-fit/ways-of-working.yaml`, and the four decision files named in "Goal Capsule".
- The earlier plan for #507 and #467: `wip/2026-11-22-v1.10.0-round2/plans/group-R-load-time-redefine-plan.md` in the main checkout (verdict no-go).
- Code read on `origin/main` at `6c71ccba`: `lib/mutineer/mutators/collection_method.rb`, `Pairing.expand_sources`, `expand_map_source_pattern`, `root_relative`, `existing_relative`, `infer_tests`, `pack_split`, `pack_tests` and `test_given_as_source?`, `JobPlan.since_tests`, `narrow_tests_for_since` and `since_narrowing_line`, `Runner.execute` and `execute_external`, `DaemonBackend.execute`, `CLI.start`, `CLI.execute`, `autopair!`, `expand_tests!`, `validate_test_command_shape!` and `warn_unused_since_paired_tests`, `Reporter#report` and `json_report`, `ExternalBackend.build_argv`, and `credit_load_only_line?` and `paired_tests_in_run` in `lib/mutineer/coverage_map/recording.rb`.
- Source age: all of the above is current (read or run on 2026-11-27).

## Verdict

**`go without #467`.** Units U1, U3, U4 and U5 are small, reproduced and run in a prototype, and #467 moves to 2.0 because its full fix changes which mutants get a score.
