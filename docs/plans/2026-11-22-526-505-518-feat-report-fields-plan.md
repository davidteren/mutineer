---
title: JSON report fields, round 2 (diff on no_verdict, callback growth list, exact patch bytes) - Plan
type: feat
date: 2026-11-22
issues: [526, 505, 518]
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# JSON report fields, round 2 (diff on no_verdict, callback growth list, exact patch bytes) - Plan

Suggested model and effort for the build: Opus 5.5, `medium`. The plan settles the design, and the tests are named.

## Goal Capsule

- **Issues:** #526 (`diff` on `no_verdict[]` entries, asked by an outside user), #505 (a JSON key that lists the classes whose callback count grew after a reload), #518 (the JSON `diff` does not apply for three kinds of non-UTF-8 source).
- **Objective:** a tool that reads only `--format json` can take the change of every mutant that got no verdict, can see which kills a reload may have made false, and can apply every mutant's change to the file's real bytes.
- **Means:** three additive keys in schema `1.11`, with no version bump (KTD1): `no_verdict[].diff`, `summary.callback_growth`, and `diff_base64`.
- **Authority:** this plan, then `AGENTS.md`, then the issue text. Where this plan differs from an issue, this plan wins (see "Corrections to the issues").
- **Leave a commit out when:** its change would alter a verdict, the score, a count in `summary`, an exit code, the text of a stderr warning, or `Reporter::SCHEMA_VERSION`. The builder drops that issue's commit, ships the other commits, and names the reason in the pull request body and in its report.
- **Execution profile:** one pull request, three commits, one for each issue, in the KTD8 order. Any one commit can leave the pull request. Labels: `enhancement`, `v1.10.0`, `priority: low`, `risk: low`. Body: `Closes #526`, `Closes #505`, `Closes #518`.
- **Who ships:** the builder opens the pull request. A maintainer merges. No agent tags or publishes a release.
- **Size:** medium. About 80 lines in `lib/`, about 220 lines of tests, and doc rows.

---

## Product Contract

### Summary

Each `no_verdict[]` entry carries the same `diff` (and `diff_encoding`) as a `survivors[]` entry.
`summary.callback_growth` lists each class and file that the stderr callback warning names.
Each entry that carries `diff` also carries `diff_base64` when the text of `diff` is not the exact patch for the file's bytes.

### Problem Frame

**#526.** After #498 (pull request #509), `killed[]`, `unplaceable[]` and `ran_at_load[]` carry `diff`. `no_verdict[]` does not: `no_verdict_json` (`lib/mutineer/reporter.rb:1081`) has `token` and no `diff`. The reporter of #526 runs errored mutants again in their own process, because their container kills a child at its memory limit. For that they prepend a module to `Mutineer::Reporter` and read `@agg`. This is the last reason they patch private methods.

**#505.** Pull request #514 added a stderr warning that names each class whose callback count grew after a reload (#479). A test that counts callback runs can then kill mutants of that file falsely. The JSON report has no matching key, so a JSON-only tool cannot see which kills to doubt. `CHANGELOG.md` says so and names #505.

**#518.** `diff_encoding` (#510, pull request #519) lets a consumer transcode the diff for a valid non-UTF-8 source. Three cases stay broken: bytes that are not valid in the source's encoding, a `# encoding: binary` source with bytes that are not UTF-8, and a line that does not convert back to its own bytes. `git apply` rejects the diff there, and the docs tell the consumer to edit the file by hand. The report has no byte offsets, so that edit has no exact input.

### Requirements

**#526: the change on every no-verdict mutant**

- R1. Each `no_verdict[]` entry has a `diff` key. Its value is the text that `survivors[]` gives for the same mutant.
- R2. An entry with no subject or no mutation has `diff: null`, as its `file` and `line` are `null` today.
- R3. A `no_verdict[]` entry has `diff_encoding` under the rule that a `survivors[]` entry has it.
- R4. `uncapturable[]`, `no_coverage[]`, `ignored[]`, `baseline.new_survivors[]` and the dry-run `mutants[]` gain no key. The human `--verbose` errored list and the HTML errored cards print what they print today. No existing key of any row moves.

**#505: the callback growth list**

- R5. `summary.callback_growth` is in every completed-run report. It is an array of `{ class, file }` rows, sorted by `(file, class)`. Each row is one class whose own callback count grew, and the file whose reload grew it. The rows hold the same pairs as the lines of the stderr warning.
- R6. The value is `[]` when the run logged no growth. It is `null` when the run made no log to read (KTD4). The docs say that `[]` is not proof that no class grew.
- R7. The key changes no verdict, score, count, exit code or stderr text. The dry-run document has no such key.

**#518: the exact bytes of the patch**

- R8. Each entry that carries `diff` also carries `diff_base64` when the bytes of `diff` are not the exact patch for the file's bytes. The key is absent in every other case.
- R9. `diff_base64` is the base64 text (standard alphabet, one line) of that exact patch. `git apply --unidiff-zero` accepts the decoded bytes, and the file it writes equals the mutant's bytes.
- R10. `diff` and `diff_encoding` keep their value and their presence rule.
- R11. The docs give the consumer one numbered recipe that says which field to apply (KTD6).

**Contract and docs**

- R12. `Reporter::SCHEMA_VERSION` stays `"1.11"`. Each new key is documented as "Additive key (schema `1.11`, #N)".
- R13. Each text that the change makes false is corrected in the same commit. The list is in "Places that compare reports or expect fixed text".

### Acceptance Examples

- AE1. **Covers R1, R3.** Given an errored, a timed-out and an uncapturable result of one mutant, when the report renders, then each `no_verdict[]` entry has the `diff` that the mutant has as a survivor.
- AE2. **Covers R2.** Given `Result.error("boot failed")` with no subject, then its `no_verdict[]` entry has a `diff` key with `null`, and the render does not raise.
- AE3. **Covers R5.** Given an in-process `--strategy reload --jobs 2` run where every child logs `Calculator`, then stderr has one line for the class, and `summary.callback_growth` is `[{"class":"Calculator","file":"calculator.rb"}]`.
- AE4. **Covers R6.** Given a `--strategy redefine` run, the value is `[]`. Given a reload run whose temp directory refuses the log, the value is `null`. Given `Reporter#report` called without the rows, the value is `null`.
- AE5. **Covers R8, R9.** Given a UTF-8 source with a changed line that ends in `# caf\xE9` (an invalid byte in a comment), then the entry has `diff_base64`, and the decoded patch applies with `git apply --unidiff-zero`.
- AE6. **Covers R8.** Given a UTF-8 source, or an EUC-JP source whose changed line is ASCII, then the entry has no `diff_base64`, and `diff` applies as it is.

### Scope Boundaries

Considered and not built:

- **`diff` on `uncapturable[]`.** The same mutant's `no_verdict[]` entry has it after this change. #526 asks for `no_verdict[]` only.
- **`diff` on `no_coverage[]`, `ignored[]`, `baseline.new_survivors[]` and dry-run `mutants[]`.** Nobody asked, and each adds size. A request names the list that needs it.
- **A count such as `summary.callback_growth_classes`.** A consumer counts the rows. A separate number would differ from the row count when one class is logged from two files.
- **A callback growth line in the HTML report or the Action step summary.** The stderr warning prints on every format, and the Action log shows it. Tracked as a follow-up in #531.
- **Byte offsets in the report** (`start_offset`, `end_offset`, `replacement`). The replacement can hold non-UTF-8 bytes too, so it would need base64 as well, and the consumer would have to write its own splice.
- **Raw path bytes in the patch header.** The header keeps the text that `diff` has. See "Limits left open".
- **`extras[:callback_growth]` on every `Runner.execute` return.** A `--test-command` run and a run that ends before any mutant leave the key out today, and `Runner.execute` documents `fetch(:callback_growth, [])` for that. Group P edits the `--test-command` path in this round, so this plan does not touch those returns.

### Corrections to the issues

1. **#526 says an entry with no subject or mutation may leave the field out.** This plan writes `diff: null` there. `killed[]` does that since #498, so one rule covers every list.
2. **#505 names schema `1.11` and "waits until Group E merges".** Group E merged as pull request #509, and 1.10.0 is not released. The key joins `1.11` with no bump (KTD1).
3. **#518 offers "document that the consumer edits the file with the byte offsets".** The report has no byte offsets. The document-only option is what pull request #519 already shipped.
4. **#518 says "only for these sources".** The plan's rule is wider and simpler: the key is present whenever the bytes of `diff` are not the exact patch (KTD6). That covers the three cases, and also a valid EUC-JP line, which `diff_encoding` already serves.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **No schema bump. All three keys are schema `1.11`.** `lib/mutineer/version.rb` is `1.9.0`, no `v1.10.0` tag exists, and `STABILITY.md:16` says "1.10.0 reports `1.11`". Pull request #519 added `diff_encoding` to `1.11` after the bump in #509, so one schema version for each gem release is the practice. No file that pins the version changes.
- KTD2. **One helper adds the optional diff keys to a row.** Add a private `attach_diff(row, result)` in `lib/mutineer/reporter.rb`, beside `attach_copies`. Each caller sets `row[:diff]` itself, as it does today. The helper adds only the keys that depend on the source: `diff_encoding` now, and `diff_base64` in U3. The two existing row kinds have different key orders today, and the helper keeps both:
  - `survivors[]`: `diff`, `seconds`, `diff_encoding`, `copies` (`lib/mutineer/reporter.rb:818-826`). `survivor_json` calls the helper after its hash literal, where its two encoding lines are now.
  - `killed[]`, `unplaceable[]`, `ran_at_load[]`: `diff`, `diff_encoding`, `seconds`, `copies` (`reporter.rb:840-844`). `mutant_with_diff_json` calls the helper right after it sets `row[:diff]`.
  - `no_verdict[]` (new): `details`, `diff`, `diff_encoding`, `seconds`, `copies`.

  Today two callers repeat the encoding lines, and #526 would add a third copy. Governs R1, R3, R4, R8.
- KTD3. **The key is `summary.callback_growth`, an array of `{ class, file }` rows.** This is the name and shape the issue gives. `summary.unmatched_ignores` (schema `1.10`, #377) is the precedent: a stderr warning that the JSON summary repeats as an array, with no effect on the exit code. A top-level list would need a new heading in `docs/json-schema.md`, a `HEADING_IDS` entry in `rake/docs_contract.rb`, and a `CATALOG` change in `rake/site_docs.rb`, for the same facts. `rake/fizzy_sample.rb` `counts` reads only integer `summary` keys, so an array there does not touch the Fizzy check. Governs R5.
- KTD4. **`null` means the run made no log. `[]` means the log has no row.** Three cases:
  - `[]`: the run logged no growth. Also a run that never reloads (`--strategy redefine` without `--daemon`, `--test-command`, a run that ends before any mutant). No reload means no growth.
  - `null`: a reload or `--daemon` run could not create its log. `JobPlan.create_callback_growth_log` (`lib/mutineer/job_plan.rb:390`) then returns `nil` and prints "this run does not check callback counts". Today `callback_growth_rows(nil, root)` gives `[]` for it, which a JSON reader would take as "none".
  - `null`: a program calls `Reporter#report` without the rows, as `timing` and `subjects` work. A CLI report never has this case.

  In `Runner.execute`, name the condition once: `checks_growth = config.daemon || config.strategy == "reload"` (`lib/mutineer/runner.rb:115`), and use it to create the log. Add a private `Runner.callback_growth(growth_log, checks_growth, project_root)`. It returns `nil` when `checks_growth` is true and `growth_log` is `nil`. Otherwise it returns `JobPlan.callback_growth_rows(growth_log, project_root)`. Both places that set `extras[:callback_growth]` call it (`runner.rb:124` and `:288`). Governs R6.
- KTD5. **The reporter takes the rows as one keyword and sorts them.** `Reporter#report` gains `callback_growth: nil`. It stores the value in `@callback_growth`, as it stores `@timing` (`reporter.rb:103`). `initialize` sets the ivar to `nil`. A private `callback_growth_json` maps each `[name, file]` pair to `{ class:, file: }` and sorts by `[file, class]`. `json_safe` already makes every string of the document UTF-8 (`reporter.rb:399`), so the method adds no encoding step. The runner returns rows in first-logged order, which depends on worker finish order under `--jobs`, so the reporter must sort to keep the byte-identical promise. `nil` stays `nil`. Governs R5.
- KTD6. **`diff_base64` is present whenever `diff.b` differs from the exact patch.** Chosen over three options:
  - Document only: already shipped in #519, and the consumer has no exact input for the edit.
  - Byte offsets: see "Scope Boundaries".
  - Present only when `diff_encoding` is absent: a smaller report, but a consumer that reads only `diff_base64` fails on an EUC-JP row.

  The presence rule has no special case in the code, so one test checks it for every source kind (U3). The consumer gets one recipe with one exception, and the docs state it as a numbered list (R11):
  1. If `git check-attr working-tree-encoding -- <file>` names an encoding, apply `diff` as it is. Git converts that file itself.
  2. Else, if `diff_base64` is present, decode it and apply the bytes.
  3. Else apply `diff` as it is.
  4. `diff: null` means that the entry has no change to apply.

  `diff_encoding` stays for a consumer that prefers text: transcode the hunk lines, as the row says today. A consumer that follows the recipe does not need it.

  Two scratch probes on 2026-11-22 back this (see "Sources"). In nine sources, "`diff.b` differs from the exact patch" was true exactly when `git apply` rejected `diff` as it is, and the exact patch applied in all nine. In a repository with `*.rb working-tree-encoding=EUC-JP`, Git accepted the UTF-8 `diff` and rejected the byte patch, so step 1 is needed. The size cost is 4/3 of the patch for rows of a non-UTF-8 source with a non-ASCII changed line. A UTF-8 project gets no new byte. Governs R8, R9, R11.
- KTD7. **One builder makes both patches.** Move the body of `unified_diff` (`reporter.rb:854`) into one private builder that takes the transform for each piece: the shown path, the hunk header and each side line. `unified_diff` passes `utf8_text`, and its output must not change. A new private `exact_patch(result)` passes `String#b`. The end-of-file rule, the header and the hunk ranges then exist once, so the two patches cannot drift. That matters because R8 compares them. Three facts for the builder:
  - Every piece of the exact patch is bytes, the header included. A UTF-8 path with a non-ASCII character and a binary hunk with a high byte raise `Encoding::CompatibilityError` when joined as they are (a probe confirmed it).
  - Encode with `[bytes].pack("m0")`. Do not `require "base64"`: since Ruby 3.4 it is a bundled gem, so it would be a runtime dependency.
  - `String#lines` on bytes equals the text split for every encoding a Ruby source can have, because none of them uses `0x0A` inside a character.

  Run the U3 table test first. If the shared builder cannot pass it, fall back to a separate `exact_patch` that reuses `hunk_range` and `diff_body`, and say so in the pull request body. Governs R9.
- KTD8. **Three commits, in this order: #526, #505, #518.** #526 adds `attach_diff` (KTD2). #505 touches other functions. #518 adds one line to `attach_diff`, so it goes last and is the easiest to drop. If #526 leaves the pull request, the #518 commit adds `attach_diff` for the two existing callers, and its test loop and doc rows leave `no_verdict[]` out. Each commit has its own `CHANGELOG.md` lines and doc rows, and passes the local gate alone.

### Assumptions

- The in-process and `--daemon` paths share `Runner.execute`, `CLI.execute` and the reporter, so one CLI test through the real binary proves the JSON key for both. `test/rails_dogfood_daemon_test.rb:233` already checks the daemon's `extras[:callback_growth]` rows.
- No pull request from the reporter of #526 is open (checked with `gh pr list` on 2026-11-22). The builder checks again before the first commit. If one exists, the builder drops the U1 commit, ships U2 and U3 (KTD8), and names that pull request in the body.
- A row's `file` in `summary.callback_growth` has the form of `file` in `killed[]` for a source inside the project root. `JobPlan.callback_growth_rows` uses `ProjectPath.relative`. A U2 test confirms it.

### Places that compare reports or expect fixed text

Each was checked on 2026-11-22 against `main` at `f6f4efe6`.

| Place | What it expects | Change needed |
|---|---|---|
| `test/json_reporter_test.rb:272` `test_other_lean_lists_have_no_diff` | `no_verdict` entries have no `diff` | Take `no_verdict` out of this test (U1). |
| `test/json_reporter_test.rb:197`, `:291` | Key order of a `killed[]` row | None. A UTF-8 row gains no key. |
| `test/runner_test.rb:1930` to `:1946` `test_a_log_the_temp_directory_refuses_warns_and_the_run_goes_on` | `assert_equal [], extras[:callback_growth]` for a refused log | Change to `assert_nil` (U2). |
| `test/cli_test.rb:3346` to `:3360` | `refute_includes out, "callback_growth"` and a comment "the JSON report has no new key" | Assert the rows instead (U2). |
| `lib/mutineer/cli.rb:1244` to `:1253` | Comment "no verdict, score, JSON field or exit code changes" | Reword (U2). |
| `lib/mutineer/runner.rb:68` to `:71` | Comment on `extras[:callback_growth]` | Add the `nil` case (U2). |
| `.expectation-fit/decisions/reload-and-redefine-strategies.md:15` | "keep verdicts, the score, the JSON report and the exit code unchanged" | Reword (U2). |
| `CHANGELOG.md:15`, `:17` (the unreleased #479 entry) | "no JSON field", and "`--format json` does not list these classes yet (#505)" | Reword in place (U2). |
| `docs/rails-setup.md:69` | The warning row, with no JSON pointer | Add one sentence (U2). |
| `CHANGELOG.md:36` and `docs/json-schema.md:105` | "edit the file by hand", "tracked in #518" | Point to `diff_base64` (U3). |
| `docs/results.md:13`, `docs/agentic-coding.md:23` and `:56`, `docs/agentic-coding.html:91` and `:101`, `skills/mutineer/SKILL.md:42` and `:69`, `docs/llms.txt:29`, `README.md`, `docs/ci.md`, `docs/index.md` | They name `no_verdict[]`, `no_verdict[].details` and the `diff` of `survivors[]` | None. Searched with `grep` for `no_verdict`, `diff`, `diff_encoding` and `callback`. No sentence becomes false. |
| `rake/fizzy_sample.rb` `counts` | Integer `summary` keys | None. An array is skipped. |
| `--baseline` (`lib/mutineer/baseline.rb`) | Survivor ids, files, score | None. |
| `rake/docs_contract.rb` `HEADING_IDS`, `test/docs_contract_test.rb:223` | Each heading of `docs/json-schema.md` has an id | None. No new heading. |
| `rake/site_docs.rb` `CATALOG`, `docs/llms.txt` | The list of top-level keys | None. No new top-level key. `bundle exec rake docs:check` confirms. |
| `STABILITY.md:16`, `:118` | Schema `1.11` for 1.10.0 | None. |
| `action.yml` | Reads `summary` counts and `survivors[]` | None. |

If the builder finds another sentence that the change makes false, it corrects it in the same commit (R13).

---

## Implementation Units

### U1. #526: diff on no_verdict entries

- **Goal:** each `no_verdict[]` entry carries `diff`, and `diff_encoding` when its source qualifies.
- **Requirements:** R1, R2, R3, R4, R12.
- **Dependencies:** none.
- **Files:**
  - `lib/mutineer/reporter.rb`
  - `test/json_reporter_test.rb`
  - `test/cli_test.rb`
  - `docs/json-schema.md`
  - `CHANGELOG.md`
- **Approach:**
  1. Add `attach_diff(row, result)` with a YARD comment (KTD2). Call it from `survivor_json` and `mutant_with_diff_json` in place of their encoding lines. Each row keeps the key order that KTD2 lists for it.
  2. In `no_verdict_json`, set `row[:diff] = unified_diff(result)` after `details`, call `attach_diff`, then set `seconds`. `unified_diff` already returns `nil` for a result with no subject or mutation, so R2 needs no new guard.
  3. Update the comments that name the lists with a diff: the `json_report` comment above `no_verdict:` (line 360) and the YARD text of `mutant_json` and `no_verdict_json`.
  4. `errored_rows` (line 1526) reuses `no_verdict_json` for the human and HTML reports. Those renderers read named keys, so the new key changes no output there. Do not add a second row builder.
  5. In `docs/json-schema.md`:
     - `no_verdict[]` section (line 235): add `diff` to the shape line, and one sentence. It says: the same text as in `survivors[]`, `diff_encoding` when the source qualifies, and "Additive key (schema `1.11`, #526)".
     - The paragraph on a failure before the fork (line 281): add `diff` to the `null` fields, and say that such an entry has no change to apply or to run again.
     - Line 130: say that an uncapturable mutant's `no_verdict[]` entry has the diff that its `uncapturable[]` entry lacks.
     - The `diff_encoding` row (line 105): add `no_verdict[]` to the lists that carry the key.
     - The shape block (line 51): add "with the diff (#526)".
  6. Add an "Added" entry under `## [Unreleased]` in `CHANGELOG.md`. Name #526, the three statuses, the `null` case, and the size: about 224 bytes for each entry, from the #498 measure (52,242 bytes for 233 diffs).
- **Patterns to follow:** `attach_copies` (`reporter.rb:1107`), and the #498 tests (`test/json_reporter_test.rb:200` to `:223`).
- **Test scenarios:**
  - Covers AE1. Extend `test_diff_lists_match_the_survivor_diff_of_the_same_mutant` (line 202): for `Result.error("boom")`, `Result.timeout` and `Result.uncapturable`, and for each of its three mutations, the `no_verdict[]` entry's `diff` equals the survivor's. The test iterates a hash by list name today, so change it to pairs of list and base result.
  - Covers AE2. Extend `test_no_verdict_entry_without_a_subject_still_appears` (line 357): the entry has the `diff` key, and the value is `nil`.
  - Covers R3. Extend `test_killed_unplaceable_and_ran_at_load_rows_have_diff_encoding` (line 114) with an errored result: its `no_verdict[]` entry has `diff_encoding` `"EUC-JP"`.
  - Covers R4. Pin the key order of an EUC-JP `survivors[]` row: its keys end in `diff`, `seconds`, `diff_encoding`. No test pins that order today, so a reorder would pass unseen. Write this test before the refactor.
  - Covers R4. In `test_other_lean_lists_have_no_diff` (line 272), remove `no_verdict` and the errored row. `no_coverage`, `uncapturable` and `ignored` stay. Give the reason in the pull request body, because the author self-check flags a test that loses an assertion.
  - Covers R4. An uncapturable mutant: its `uncapturable[]` entry has no `diff`, and its `no_verdict[]` entry has one.
  - A `no_verdict[]` row with a dropped copy keeps `copies` as its last key.
  - `test/html_reporter_test.rb:204` and `:214` (the errored list) pass unchanged.
  - Covers AE1 end to end, in `test/cli_test.rb`: a real run where one mutant's child dies gives a `no_verdict[]` entry with `status` `"error"` whose `diff` `git apply --unidiff-zero --check` accepts. `test/child_cause_test.rb` shows how to make a child exit. This is the reporter's own use: apply the change of an errored mutant.
- **Verification:** the zero-dependency suite and `rake yard:strict` pass. The website checks pass.

### U2. #505: the callback growth list in the JSON summary

- **Goal:** `summary.callback_growth` holds the rows of the stderr warning.
- **Requirements:** R5, R6, R7, R12, R13.
- **Dependencies:** none. It does not use `attach_diff`.
- **Files:**
  - `lib/mutineer/reporter.rb`
  - `lib/mutineer/cli.rb`
  - `lib/mutineer/runner.rb`
  - `test/json_reporter_test.rb`
  - `test/cli_test.rb`
  - `test/runner_test.rb`
  - `docs/json-schema.md`
  - `docs/rails-setup.md`
  - `CHANGELOG.md`
  - `.expectation-fit/decisions/reload-and-redefine-strategies.md`
- **Approach:**
  1. Runner: add the `checks_growth` local and `Runner.callback_growth` (KTD4), and call the helper at both places. Mark it as the other private helpers of `Runner` are marked (`@api private` and `private_class_method`, `runner.rb:610-659`), with a YARD comment. Update the comment of `Runner.execute` (lines 68 to 71): an absent key means that the run did not reload, and `nil` means that the run made no log.
  2. CLI (`CLI.execute`, `lib/mutineer/cli.rb:1058` to `:1068`): read `rows = extras.fetch(:callback_growth, [])` once. Pass `callback_growth: rows` to `reporter.report`. Call `warn_callback_growth(rows || [])`, so a `nil` prints no header. The log failure already has its own stderr line.
  3. Reporter: add the keyword and the ivar (KTD5), and extend the comment above `report` (lines 73 to 97). In `json_report`, add `callback_growth: callback_growth_json` to `summary`, with an "Additive (1.11, #505)" comment.
  4. Reword the comment of `CLI.warn_callback_growth` (line 1244): it changes no verdict, score or exit code, and `--format json` lists the same rows in `summary.callback_growth`.
  5. In `docs/json-schema.md`, add a `callback_growth` row at the end of the `summary` table. The row says:
     - Type `array of object | null`, the row shape `{ class, file }`, and the sort order.
     - `file` is the file whose reload grew the count. It has the form of `file` in `killed[]` and `survivors[]`, so a consumer matches on equal `file`. A test that counts callback runs or errors can kill mutants of that file falsely (#479).
     - `[]` means that no growth was logged. It is not proof that no class grew: a check that fails in a mutant's child prints a stderr line and logs nothing. Name the follow-up issue from "Limits left open" (#531).
     - `[]` also for a run that never reloads: `--strategy redefine` without `--daemon`, and `--test-command`.
     - `null` means that the run could not create its log, so it checked nothing. A stderr line says so.
     - To check the kills: `--no-daemon --strategy redefine`, or `--test-command`.
     - It changes no verdict, score or exit code. "Additive key (schema `1.11`, #505)".

     In "Dry-run JSON", say that the dry-run document has no `callback_growth`.
  6. In `docs/rails-setup.md:69`, add one sentence: `--format json` lists the same classes in `summary.callback_growth`.
  7. In `CHANGELOG.md`, add an "Added" entry that names #505. In the unreleased #479 entry, change "no JSON field" (line 15) and remove "does not list these classes yet (#505)" (line 17). The entry stays under `## [Unreleased]`.
  8. Reword the "Callback Growth Warning Is Report-Only" line in `.expectation-fit/decisions/reload-and-redefine-strategies.md`: verdicts, the score and the exit code stay unchanged, and the JSON report only lists the same rows in `summary.callback_growth` (#505).
- **Patterns to follow:** `timing` in `Reporter#report` and `json_report`. `summary.unmatched_ignores` for a warning list in `summary`.
- **Test scenarios:**
  - Covers AE3. In `test_an_in_process_reload_run_prints_the_callback_growth_warning_once` (`test/cli_test.rb:3346`): replace `refute_includes out, "callback_growth"` with an assertion that `doc["summary"]["callback_growth"]` equals `[{ "class" => "Calculator", "file" => "calculator.rb" }]`. Keep the stderr and score assertions. Update the comment above the test.
  - Covers R5. In the same test, parse the stderr lines that start with `[mutineer]   ` into name and file pairs, and assert that they equal the JSON rows. This ties the two outputs together, so they cannot drift apart unseen.
  - Covers R5. In the same test, the row's `file` equals the `file` of a `killed[]` entry of that run.
  - Covers AE4. A `--strategy redefine` CLI run gives `[]`.
  - Covers AE4. In `test/json_reporter_test.rb`: `Reporter#report` with no `callback_growth:` gives `summary.callback_growth` `nil`, and the key is present.
  - Covers R5. Rows given as `[["B", "z.rb"], ["A", "z.rb"], ["C", "a.rb"]]` render sorted by file, then class. The same rows in reverse order render the same bytes.
  - Covers R5. One class logged from two files gives two rows.
  - Covers R5. A class name with a control character (`"Once\e[2J"`) and a name with a byte that is not UTF-8 each render as valid JSON. The first parses back to the same name. This confirms that `json_safe` covers the key.
  - Covers R6. A table test of `Runner.callback_growth` over `checks_growth` true or false and the log `nil` or a real file. Expected: `nil` only for true with `nil`. `[]` for false with `nil`. The file's rows for a real file.
  - Covers R6, AE4. In `test_a_log_the_temp_directory_refuses_warns_and_the_run_goes_on` (`test/runner_test.rb:1930`), change `assert_equal []` to `assert_nil`. `test_a_redefine_run_has_no_callback_growth_log` (line 1875) still gets `[]`.
  - Covers R6. `CLI.warn_callback_growth([])` still prints nothing. A CLI run with `nil` rows prints no header, does not raise, and writes `"callback_growth":null`.
  - Covers R7. The exit code and `summary.score` of the AE3 run equal those of the same fixture run with `--strategy redefine`.
- **Verification:** the zero-dependency suite, `rake test:daemon` and `rake yard:strict` pass. The website checks pass.

### U3. #518: diff_base64, the exact bytes of the patch

- **Goal:** every row with a `diff` that cannot apply as text carries the exact patch.
- **Requirements:** R8, R9, R10, R11, R12, R13.
- **Dependencies:** U1 (`attach_diff`). Without U1, this commit adds the helper for the two existing callers (KTD8).
- **Files:**
  - `lib/mutineer/reporter.rb`
  - `test/json_reporter_test.rb`
  - `docs/json-schema.md`
  - `CHANGELOG.md`
- **Approach:**
  1. Make the shared builder and `exact_patch(result)`, each with a YARD comment (KTD7). `exact_patch` returns the patch as a binary string, or `nil` when the result has no subject or mutation.
  2. In `attach_diff`, after `diff_encoding`: when `row[:diff]` is not `nil` and `row[:diff].b != exact_patch(result)`, set `row[:diff_base64] = [patch].pack("m0")`. `diff_base64` then follows `diff_encoding` in each row's order. Add a one-line comment that says why `pack` and not the `base64` library.
  3. Update the YARD text of `diff_encoding` (line 887): the cases with no `diff_encoding` now have `diff_base64`.
  4. In `docs/json-schema.md`:
     - Add a `diff_base64` row after `diff_encoding` in the `survivors[]` table. It says when the key is present (R8), and what it holds (R9: the header lines and the hunk header as in `diff`, each `-` and `+` line in the file's own bytes). It says how to use it: decode standard base64, write the bytes, run `git apply --unidiff-zero` (in Ruby, `row["diff_base64"].unpack1("m")`). It names the lists that carry it, and "Additive key (schema `1.11`, #518)".
     - In the same row, state the limit: a source path that is not valid UTF-8 prints as `\xNN` in the patch header, so `git apply` cannot find the file, and the report has no workaround today. Name the follow-up issue from "Limits left open" (#532).
     - In the `diff` row, add the numbered recipe of KTD6, with the `git check-attr` step first. Say that `diff_encoding` is for a consumer that prefers the text route.
     - In the `diff_encoding` row, replace the text from "In those last three cases" to "tracked in #518" with a pointer to `diff_base64`. Keep the `working-tree-encoding` sentence, and point it to the recipe.
     - In the `no_verdict[]` section, the `killed[]` section and the line 130 note, add `diff_base64` where `diff` is named, with one pointer to the recipe.
  5. In `CHANGELOG.md`, add an "Added" entry that names #518 and gives the recipe in one sentence. In the unreleased #510 entry (line 36), replace "so edit the file by hand" and "Those cases are tracked in #518" with a pointer to `diff_base64`.
- **Patterns to follow:** `test_diff_applies_with_git_after_transcoding_to_diff_encoding` and `survivor_row_for` (`test/json_reporter_test.rb:81` to `:111`).
- **Test scenarios:**
  - Covers R8, R9, R11, AE5, AE6. One rule test over a table of sources. For each source, take `patch = row["diff_base64"]&.unpack1("m") || row["diff"].b`, write the source and the patch as bytes, run `git apply --unidiff-zero`, and assert that the file equals `mutation.apply(src).b`. This is steps 2 and 3 of the recipe. The table holds: a UTF-8 source with an ASCII line; a UTF-8 source with a non-ASCII line; the four `NON_UTF8_SOURCES`; an EUC-JP source whose changed line is ASCII; the Windows-31J `0xFA4A` source; a binary-tagged source with UTF-8 bytes; a binary-tagged source with `\xFF\xFE`; a UTF-8 source with `# caf\xE9` on the changed line; the same with CRLF line ends and no newline at the end of the file.
  - Covers R8. The presence rule over the same table: `diff_base64` is present for the EUC-JP and Shift_JIS non-ASCII lines, the ISO-8859-1 `café` line, the Windows-31J source, the `\xFF\xFE` source and both `caf\xE9` sources. It is absent for the others. The ISO-8859-1 `cafe` row and the EUC-JP ASCII row have `diff_encoding` and no `diff_base64`, and the first test proves that their `diff` applies as it is.
  - Covers R9. A source at the path `café.rb` with `# caf\xE9` on the changed line: the render does not raise, and the decoded patch applies. This pins the bytes rule for the header (KTD7).
  - Covers R9. `diff_base64` has no newline, and `unpack1("m")` then `pack("m0")` returns the same text.
  - Covers R10. `unified_diff` gives the same text as before the refactor: the existing diff tests (lines 543 to 626) and `test_utf8_source_has_no_diff_encoding`, `test_lossy_roundtrip_source_has_no_diff_encoding` and `test_binary_source_has_no_diff_encoding` pass unchanged.
  - Covers R8. A `killed[]`, an `unplaceable[]`, a `ran_at_load[]` and a `no_verdict[]` entry of the `caf\xE9` source each have `diff_base64` (one loop, as line 114 does for `diff_encoding`).
  - Covers R4. The EUC-JP `survivors[]` row from U1 now ends in `diff`, `seconds`, `diff_encoding`, `diff_base64`.
  - A result with no subject has `diff: null` and no `diff_base64`.
- **Verification:** the zero-dependency suite and `rake yard:strict` pass. The website checks pass.

---

## Verification Contract

Set `LANG=en_US.UTF-8` and `LC_ALL=en_US.UTF-8` for every command.

| Check | Command | Proves |
|---|---|---|
| Zero-dependency suite | `bundle exec rake test` | R1 to R13, unit and CLI scenarios |
| Load smoke | `ruby -Ilib -e 'require "mutineer"'` | The gem loads, with no `base64` require |
| Docs coverage | `bundle exec rake yard:strict` | Each new method has a comment |
| Daemon tests | `bundle exec rake test:daemon` | The `Runner.execute` change keeps the daemon rows (U2) |
| Generated docs | `bundle exec rake docs:check` | `docs/llms.txt` and the contract splices are not stale |
| Website checks | The commands in `AGENTS.md` "Website checks" | `docs/json-schema.md` builds into `_site/json-schema.html` and `_site/llms-full.txt`, and the browser tests pass |
| Each commit alone | The zero-dependency suite and `rake yard:strict` on each of the three commits | One issue can leave the pull request (KTD8) |
| No runtime dependency | `git grep -n 'require "base64"' lib` prints nothing | The zero-dependency rule |

Not needed: the Minitest 6 run and the Prism 2 run. No Minitest integration, parsing or parse-error code changes.

## Definition of Done

- R1 to R13 hold, and each acceptance example has its test.
- All Verification Contract checks pass on the pull request head.
- The pull request has three commits in the KTD8 order, the labels in the Goal Capsule, and `Closes #526`, `Closes #505`, `Closes #518`. An issue whose commit was dropped gets no `Closes` line.
- The pull request body names the maintainer questions below, with the default the build took for each.
- The two follow-up issues in "Limits left open" exist (#531, #532), and the docs and `CHANGELOG.md` name them where they state the limit.
- The author self-check skill (`.claude/skills/author-self-check/SKILL.md`) ran before the first push.
- No debug output or abandoned attempt is left in the diff.

---

## Risks

- **The held 2.0 pull requests #244, #314 and #322** change `lib/mutineer/reporter.rb` and `docs/json-schema.md`. The reporter diff stays small: one helper, one keyword, one builder in place of the `unified_diff` body, and no reorder of existing keys. Expect text conflicts in the `survivors[]` table when they rebase.
- **Other round 2 groups.** Group O (#503, #512, #504) works on reload and may touch `lib/mutineer/runner.rb` and the #479 entry in `CHANGELOG.md`. Group P works on the `--test-command` path. The later pull request rebases. Group N and Group Q are the pair planned to run together, and Q touches the daemon load path, not these functions.
- **The `unified_diff` refactor.** Every diff of every list goes through it. The existing diff tests guard the text, and the new key-order test guards the rows. KTD7 names the fallback.
- **A consumer that asserts "no `diff` on `no_verdict[]`".** Unlikely, and the schema says consumers must ignore unknown keys.
- **Report time.** Each row with a diff builds the patch twice (text and bytes). On the self-check run that is 233 short string builds. No measurable cost. Do not add a guard unless a measure shows one is needed.
- **`git` in tests.** The new tests run `git apply`, as the #510 tests do. CI runs on Ubuntu and macOS. The path `café.rb` is valid UTF-8, so both file systems accept it.
- **A second reviewer may ask for `1.12`.** KTD1 gives the answer and the precedent.

## Open Questions

Only a maintainer can answer these. None blocks the build: the builder takes the default and says so in the pull request body.

1. **#518: ship `diff_base64` in 1.10.0, or keep the document-only state?** Default: ship it as commit 3. It is small (one builder, one line in the helper, doc rows), and a UTF-8 project sees no change. If the answer is no, drop commit 3. #518 then stays open with its `v1.10.0` label for the maintainer to move.
2. **#518: is `diff_base64` also present on a row that has `diff_encoding`?** Default: yes, whenever the bytes differ (KTD6). The other choice is "only when `diff_encoding` is absent", which is one more condition in `attach_diff` and a longer recipe for the consumer.
3. **#505: where does the list go?** Default: `summary.callback_growth` as rows, which is what the issue says (KTD3). The other choice is a top-level `callback_growth[]` with a count in `summary`, as `unpaired_sources` has. It costs a new doc section, a `HEADING_IDS` entry and a `CATALOG` change.
4. **Schema version: stay on `1.11`?** Default: yes (KTD1). `1.12` would need `Reporter::SCHEMA_VERSION`, both shape blocks of `docs/json-schema.md`, `STABILITY.md` and the test comments to change.
5. **#526: should `uncapturable[]` entries carry `diff` too?** Default: no. The same mutant's `no_verdict[]` entry has it, and the issue asks for `no_verdict[]`.

## Limits left open

| Limit | Tracked by |
|---|---|
| A callback check that fails inside a mutant's child prints a stderr line and logs nothing (`ReloadGuards.growth_check`, `ReloadGuards.log_callback_growth`). The JSON list then misses that class, and `[]` does not prove that no class grew. How often: the check fails only when one of those two methods raises. The builder reads stderr of the `rake test:daemon` run and writes the count, or "not seen in the dogfood run", into the issue. | #531, filed by the builder before the first push. Title: "Callback growth list: a check that fails in the child is not in the JSON report". No version label. The `callback_growth` doc row names it. |
| The HTML report and the Action step summary have no callback growth line. The stderr warning covers every format, and the Action log shows it. | The same new issue, as a second point. |
| A source path that is not valid UTF-8 prints as `\xNN` in `file` and in the header of `diff` and of the `diff_base64` patch, so no patch names the real file (#346 made it print, and is closed). | #532, filed by the builder before the first push. Title: "JSON diff: a source path that is not UTF-8 cannot be applied". No version label. The `diff_base64` doc row names it. |
| A file with a `working-tree-encoding` Git attribute and a changed line that `diff` cannot hold as text (an invalid byte) has no patch that applies: Git wants the UTF-8 form, and `diff` prints the byte as `\xNN`. The report also does not say which files have the attribute, so the consumer runs `git check-attr`. | The same new issue, as a second point. |
| The six reload cases where a class keeps both copies of a callback. | #479 (open). |
| A class body that calls `define_callbacks` can lose a concern's callback on reload, and the warning and the list do not see it. | #504 (open, Group O). |
| `no_coverage[]`, `ignored[]`, `uncapturable[]`, `baseline.new_survivors[]` and dry-run `mutants[]` have no `diff`. | No issue. It is a scope choice, not a defect, and `docs/json-schema.md` states each shape. Open Question 5 covers `uncapturable[]`. |

If the builder cannot file an issue, it keeps the limit sentence in the docs without an issue number, and reports that in the pull request body. The maintainer then files the issue. The sentence must stay: without it the docs would claim more than the code does.

## Sources

- Issues #526, #505 and #518 with comments (`gh issue view`, 2026-11-22). The #518 comment gives the lossy frequency: 398 of 21,828 one- and two-byte Windows-31J codes (1.8%) do not round-trip, and Shift_JIS, EUC-JP, ISO-8859-1 and Windows-1252 have none.
- `AGENTS.md`, `.expectation-fit/ways-of-working.yaml`, `.expectation-fit/decisions/json-schema-and-baseline.md`, `.expectation-fit/decisions/reload-and-redefine-strategies.md`, `.expectation-fit/decisions/docs-and-changelog.md`.
- The earlier plan `docs/plans/2026-11-21-498-495-481-feat-report-fields-plan.md` (pull request #509), and the merged commits `c86f0f12` (#519) and `62861080` (#514).
- Code read on `main` at `f6f4efe6`: `lib/mutineer/reporter.rb`, `lib/mutineer/cli.rb:1013-1265`, `lib/mutineer/runner.rb:60-295`, `lib/mutineer/job_plan.rb:386-421`, `lib/mutineer/reload_guards.rb:100-175`, `rake/fizzy_sample.rb`, `rake/docs_contract.rb`, `rake/site_docs.rb`.
- Scratch probes, 2026-11-22, not committed, Git 2.50.1 and Ruby 3.4.9 on macOS:
  - Nine sources through the reporter's own `diff_for` and `hunk_range`, then `git apply --unidiff-zero`. The exact patch applied in all nine. `diff` as text applied in four (UTF-8 ASCII, UTF-8 non-ASCII, EUC-JP with an ASCII line, binary-tagged with UTF-8 bytes) and was rejected in five.
  - The path `café.rb` with an invalid byte on the changed line: a plain join of the header and the byte hunk raised `Encoding::CompatibilityError`. With the header as bytes, the patch applied.
  - A repository with `*.rb working-tree-encoding=EUC-JP` and an EUC-JP file: `git apply --unidiff-zero --check` accepted the UTF-8 text patch and rejected the byte patch. `git check-attr working-tree-encoding -- foo.rb` printed the encoding.
  - An invalid byte in a string literal is a syntax error, and an invalid byte in a comment loads. So the "invalid bytes" case of #518 is, in practice, a comment on a changed line, for example a Latin-1 comment in a file with no magic comment.
- `expectation-fit:fit-validate-plan`, round 1, 2026-11-22, four lenses (predictability, simplicity, convention, experience) on the first draft. Verdict: revise first. Lowest score 7 of 10. One P1 and four P2 passed the confidence gate. This text fixes each:
  - P1: `[]` was documented as "checked, none" while a failed check in a child logs nothing (R6, KTD4, U2 step 5, the last paragraph of "Limits left open").
  - P2: the draft gave one key order for `survivors[]` and `killed[]` rows, and the code has two (KTD2, U1 step 1, the key-order test).
  - P2: `diff_base64` was documented only in the `survivors[]` table (U3 step 4).
  - P2: the consumer recipe was not written, and the role of `diff_encoding` was unclear (R11, KTD6, U3 step 4).
  - P2: the consumer could not tell which files have `working-tree-encoding` (KTD6 step 1, the third probe).
  - Lower findings also applied: one shared patch builder (KTD7), the `checks_growth` local (KTD4), no second UTF-8 pass (KTD5), the existing runner test that asserted `[]` (the table and U2), the default action in place of "stop and ask" (Goal Capsule, Assumptions), the tests that tie stderr to the JSON rows, and the list of docs that were searched.
  - Declined: set `extras[:callback_growth]` on every `Runner.execute` return. Reason in "Scope Boundaries".
  - No second round was run on this text.
