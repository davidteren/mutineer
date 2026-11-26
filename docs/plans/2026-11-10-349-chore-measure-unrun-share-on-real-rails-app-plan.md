---
title: Measure the declined count and unrun share on a real concern-heavy Rails app - Plan
type: chore
date: 2026-11-10
issues: [349]
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Measure the declined count and unrun share on a real concern-heavy Rails app - Plan

## Goal Capsule

- **Issue:** #349 (measure the declined count and unrun share on a real concern-heavy Rails app; a follow-up to #291, the counts of mutants that were not scored).
- **Objective:** a maintainer can say, with numbers from a real Rails app, whether the 10% unrun-share warning is set right. Users then read that warning as a measured signal, not a guess.
- **Means:** one measurement runbook on Fizzy at a pinned public commit, a fixed decision rule for `Reporter::UNRUN_SHARE_LIMIT` (KTD3), and the numbers published in the CHANGELOG and beside the constant (KTD4).
- **Authority:** this plan, then `AGENTS.md`, then the text of #349. Where this plan differs from the issue, this plan wins (see "Corrections to the issue").
- **Stop and ask when:** the decision rule says to change the limit (U3 change branch); a measured share from today's two classes is above 10%; the in-process redefine run cannot boot Fizzy (U1 fail branch); or a run would need a second Fizzy run in the same checkout at the same time (#404).
- **Size:** S. One measurement session. Expected repo diff: 2 files (`CHANGELOG.md`, one comment in `lib/mutineer/reporter.rb`). With the change branch: 4 files.
- **Delivery:** one pull request from `main`, after #381 (count unpaired sources and their mutants) merges. Units in the order U1 to U4. A maintainer merges. This plan has no release step.

---

## Product Contract

### Summary

#334 (the pull request that shipped #291) measured the declined count and the unrun share only on Mutineer's own `lib/` and on `test/fixtures/rails_app`. The fixture app has no concerns, so its unrun share is 0 and it cannot tune the limit (`CHANGELOG.md:109-118`). This plan measures the same numbers on Fizzy, a concern-heavy Rails 8 app, under both strategies. It then applies a fixed rule to keep or change `UNRUN_SHARE_LIMIT` (`lib/mutineer/reporter.rb:31`). It also records the unpaired count that #381 adds.

### Problem Frame

The unrun-share warning fires when unplaceable plus skipped-invalid mutants are more than 1 and more than 10% of attempted plus unrun (`lib/mutineer/reporter.rb:896-899`). The 10% value has no measurement behind it. #381 plans to add unpaired mutants to the same share (sibling plan `docs/plans/2026-11-10-381-feat-count-unpaired-sources-and-mutants-plan.md`, R10 and Q2). Its Q2 waits on these numbers.

Probes in this run already answer most of the question (see "Probe results"). On Fizzy, today's two classes stay below 1% of all mutants, even with all 21 operators. The share that matters on Fizzy is the unpaired class. So the measurement must run after #381 merges.

### Requirements

- R1. Measure on Fizzy at one pinned public commit: `palkan/fizzy` `f220e4832bf40b6f4d4f944253d7a7731d366d37` (branch `vova/sfruby-mutation`). #402 (a pinned Fizzy sample before each release) probes the same commit.
- R2. Record, for each run: Mutineer commit, Fizzy commit, command, operators, strategy, daemon or in-process, wall time, `total`, `attempted`, `unplaceable`, `skipped_invalid`, `no_coverage`, `declined`, `declined_by_operator`, `unpaired_sources`, `unpaired_mutants`, and whether stderr printed the unrun-share warning.
- R3. Cover the siblings: reload and redefine, daemon and in-process, report and dry run. The Action needs no run (KTD5).
- R4. Compute each share from the JSON integers, unrounded. Report the share with and without `unpaired_mutants`.
- R5. Apply the decision rule (KTD3) and record which branch it took and why.
- R6. Publish the numbers in the `CHANGELOG.md` Unreleased section, in one sentence beside `UNRUN_SHARE_LIMIT`, and in the pull request body (KTD4).
- R7. File an issue for each new limitation the runs find. Do not fix one in this pull request.
- R8. Publish aggregate counts only. No survivor ids, no file names of security-relevant code, no link to the private report.

### Acceptance Examples

- AE1. Covers R2, R4. The default-operator daemon run reports `unplaceable: 1`, `skipped_invalid: 0`, `attempted: 800` and `unpaired_mutants: 149`. The record shows share without unpaired `1 / 801 = 0.12%` and with unpaired `150 / 950 = 15.79%`, and "warning fired: yes". (Illustrative numbers. The real ones come from U2.)
- AE2. Covers R5. Every share without unpaired is at or below 10%. The rule keeps `UNRUN_SHARE_LIMIT = 0.10`. U3 takes the no-change branch, and the diff touches only `CHANGELOG.md` and the comment above the constant.
- AE3. Covers R7. The all-operator dry run reports `6 skipped (invalid)` on parse-clean sources. An issue exists for the `literal_mutation` heredoc case before the pull request opens, and the pull request body names it.

### Scope Boundaries

- No change to the score, an exit code, `summary.total` or any JSON key.
- No new script, Rake task or fixture in the repo. The runbook lives in this plan.
- No change to how #381 counts unpaired mutants. This plan only measures them.
- No fix for a defect the runs find. Each one gets an issue (R7).

#### Deferred to Follow-Up Work

- The `literal_mutation` heredoc and interpolation mutants that do not re-parse (Probe 3). U4 files the issue. Its fix pull request adds the repro as a fixture.
- A count-based warning for skipped-invalid mutants on a parse-clean source (Q2).
- Re-measure when #389 (full reload for Rails daemon runs) or #375 (place a hook-block mutant before the rest of its file loads) merges. Both can change the reload `unplaceable` count.

### Corrections to the issue

- **"`--operators <all>`".** No `all` value exists. `--operators all` exits 2 with `Unknown operator: "all"` (Probe 2; `lib/mutineer/cli.rb:155-156`, `:358-360`). The runbook passes the 21 names from `MutatorRegistry::ALL`.
- **"`mutineer run app --dry-run`".** On Fizzy this exits 2 with `--boot/--rails requires at least one --test file` (Probe 2). Fizzy's `.mutineer.yml` sets `rails: true`. The dry run skips pairing (`lib/mutineer/cli.rb:429`), but boot mode still needs a `--test` (`lib/mutineer/cli.rb:438-441`). The runbook passes one `--test`. The dry run still lists every source.
- **The dry run cannot give the unplaceable count.** It prints mutations, skipped (invalid), ignored and declined only (`lib/mutineer/cli.rb:907-928`). Unplaceable depends on coverage (`lib/mutineer/runner.rb:377`, `lib/mutineer/daemon_backend.rb:432-434`). Only a real run measures it.
- **"a full `--strategy redefine --rails` run".** Fizzy's config sets `daemon: true`. The daemon always reloads and overrides `--strategy redefine` with a warning (`lib/mutineer/cli.rb:508-510`). A redefine run needs `--no-daemon`, which runs serially (`lib/mutineer/cli.rb:64-66`). KTD2 replaces the full serial run with a targeted one.
- **"A redefine run on concern-heavy Rails code is the likely worst case".** Not on Fizzy. The static upper bound under redefine is 59 unplaceable of 7,798 valid jobs (0.76%) with all operators, plus 6 invalid (Probe 1). Fizzy's concerns sit beside their models (for example `app/models/board/accessible.rb`). The `concerns/` folders hold 0 statically unplaceable jobs. The class that moves the share on Fizzy is unpaired mutants, which the issue does not list (next item).
- **The list of counts to record is not complete.** It leaves out unpaired mutants. #381 adds them to the same share. At Fizzy `f220e4832` they put the share at 14.0% or more with the default operators (Probe 4).
- **"add the numbers to the CHANGELOG entry for the release that ships #334".** #334 shipped in 1.8.0 (`CHANGELOG.md:53`, `:102-118`). The issue's own note says not to edit released sections. The numbers go to the Unreleased section (KTD4).
- **The issue comment links Vladimir's private report.** This plan and its outputs do not repeat that link (R8).

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Measure after #381 merges, on its `main`.** The unpaired count is the only class that can move the share on Fizzy (Probe 1, Probe 4). Rejected: measure now on `8d9905c4`. That answers only the part the probes already answer.
- KTD2. **Full daemon run with default operators, plus targeted in-process runs with all operators.** The daemon run is the run Fizzy's config gives users. The static probe shows that only 4 paired files hold any unplaceable or invalid job (Probe 1, Probe 5). A targeted run on those 4 files gives the exact real count under each strategy. Rejected: a full serial redefine run with all 21 operators. It covers 7,778 mutants one at a time and adds no number the decision needs. Rejected: a full daemon run with all operators as the default. It costs about 7 times the default run (7,778 against 1,061 mutations, Probe 2). Q3 keeps it optional.
- KTD3. **The decision rule.** Use unrounded shares, `u / (attempted + u)`.
  - Keep `0.10` when each share from unplaceable plus skipped-invalid is at or below 10% (expected).
  - Raise the limit only when a run fires from those two classes and every unrun mutant is an expected, documented cause (`docs/json-schema.md:60`), not a Mutineer bug. Raise it to the smallest whole percent above the highest such share. Ask before going above 25% (Q4).
  - Never lower the limit to catch a few bug-signal mutants. File an issue instead (R7, Q2).
  - Do not tune the limit for unpaired mutants. A share above 10% from unpaired mutants is a true disclosure (#381 KTD3). Record it and hand it to #381 Q2.
  - Rejected: a per-class limit decided here. #381 Q2 owns that choice.
- KTD4. **Publish in three places.** A sentence in the Unreleased `CHANGELOG.md` entry for #381, as the 1.8.0 entry did for #291 (`CHANGELOG.md:109-118`). One comment line above `UNRUN_SHARE_LIMIT` (`lib/mutineer/reporter.rb:28-31`), so the next reader sees why 10%. The full table in the pull request body and in a `**Claude:**` comment on #349. Rejected: a new results file under `docs/`. Nothing reads it, and #402 owns stored Fizzy counts.
- KTD5. **No Action run.** The Action calls the same CLI and reporter. `action.yml` has no unrun-share handling of its own (no match for `unrun` or `unplaceable`). The warning reaches the job log on stderr unchanged.
- KTD6. **A fresh Fizzy clone, not the local one.** The local clone at `/Users/davidteren/Projects/OSS/fizzy-palkan` has uncommitted edits to `Gemfile`, `Gemfile.lock` and `test/mutineer_boot.rb` (an experiment copy with `MUT_SKIP` switches). The runbook clones `f220e4832` fresh and edits nothing in it. It keeps Fizzy's committed boot file, because users run with it. (#402 drops that file on purpose, to see the reload bugs.)
- KTD7. **Run the checkout's Mutineer, not Fizzy's binstub.** Fizzy's lock pins `mutineer (1.8.0)` (`Gemfile.lock:321` at `f220e4832`), and its `bin/mutineer` runs that copy, which has no #381 counts. Daemon runs use `MUT="<absolute ruby> <checkout>/bin/mutineer"`, as #402 KTD5 does: the daemon still starts the app with `bundle exec ruby` in Fizzy (`lib/mutineer/daemon_client.rb:334`). In-process runs boot Rails inside the Mutineer process, so they need Fizzy's bundle: `MUT_IN="bundle exec ruby -I<checkout>/lib <checkout>/bin/mutineer"`. The `-I` puts the checkout ahead of the bundled 1.8.0 gem. U1 proves both load the checkout. Rejected: a `path:` edit to Fizzy's `Gemfile`, which rewrites the lock that #402 keeps unchanged.

### Assumptions

- #381 merges with `summary.unpaired_sources` and `summary.unpaired_mutants` as its R6 states. If the names differ, use the merged names.
- The pinned commit installs with the public `Gemfile`. `Gemfile.saas` names private gems (`queenbee`, `rails_structured_logging`), and the runbook does not use it.
- Fizzy runs on Ruby 3.4.8 (`.ruby-version`), which meets Mutineer's 3.4 floor.

### Probe results

Scripts and output are in the context folder `probes/349/` (see Sources). All probes are read-only. None boots Fizzy or installs a gem. They ran Mutineer from this worktree (`origin/main` `8d9905c4`).

| Probe | Question | Result |
|---|---|---|
| 1. `static_unrun.rb` on a copy of Fizzy `f220e4832` `app/` and `test/` | What is the most that unplaceable and invalid can be? | Default operators, `app/models app/controllers`: 1,071 jobs, 10 declined (all `statement_removal`), 0 invalid, redefine 4 unplaceable, reload 1. All 21 operators: 7,804 jobs, 105 declined (`call_to_receiver` 66, `chain_link` 23, `statement_removal` 10, `return_nil` 4, `range` 2), 6 invalid, redefine 59 (0.76%), reload 20 (0.26%). The `concerns/` folders hold 646 jobs and 0 of either. Whole `app/`: 9,231 jobs, 109 declined, the same 6 and 59 and 20. |
| 1. Code reading and Fizzy's saved `tmp/fullscope.json` | Is the static count an upper bound? | Yes. A run marks a mutant unplaceable only when `subject.unplaceable?(strategy)` is true, and turns a `:maybe` one into `no_coverage` (`lib/mutineer/runner.rb:377`, `lib/mutineer/daemon_backend.rb:432-434`). Skipped (invalid) is checked before coverage, so that count is exact (`lib/mutineer/runner.rb:368`). Fizzy's saved full-scope report `tmp/fullscope.json` (default operators, every test passed) has `unplaceable: 1`, the same as the static reload bound. That report's command and Mutineer version were not checked. |
| 2. `dry_run_all_ops.sh` in the Fizzy clone | Does the runbook's dry run work, and what does it say? | With one `--test`: `7778 mutations; 6 skipped (invalid); 20 ignored (suppressed); 105 declined` in 1.6 s, exit 0. 7,778 + 6 + 20 = 7,804, as Probe 1. Default operators: `1061 mutations; 0 skipped (invalid); 10 ignored; 10 declined`. With no `--test`: exit 2. `--operators all`: exit 2, `Unknown operator: "all"`. |
| 3. `invalid_detail.rb` | What are the 6 invalid mutants? | All are `literal_mutation` on a parse-clean source. Four empty a heredoc line (`account/seeder.rb:95`, three `*/promptable.rb`): `unterminated heredoc`. Two empty a part of an interpolated string (`event/description.rb:98`). The warning text calls this case a Mutineer bug (`lib/mutineer/reporter.rb:139-143`). |
| 4. Arithmetic from the #381 probe | What share would unpaired mutants add? | At `f220e4832` with default operators: 149 unpaired, 912 paired jobs. `u / (attempted + u)` falls as `attempted` grows, and `attempted` is at most 912, so the share is at least 149 / 1,061 = 14.0%. Before Vladimir's tests (Fizzy `d5b7b749d`): at least 312 / 1,071 = 29.1%. |
| 5. `pairing_of_targets.rb` | Which of the 13 files with a static candidate does a normal run pair? | 4: `board/accessible.rb` (18 jobs unplaceable under each strategy), `user/role.rb` (4, redefine only), `user/mentionable.rb` (3, redefine only), `event/description.rb` (2 invalid). The other 9 are unpaired, so a normal run counts their mutants as unpaired. Paired static bound: redefine 27, reload 20. The share stays under 10% while `attempted` is at least 243 (redefine) or 180 (reload). |

---

## Implementation Units

### U1. Spike: does an in-process redefine run boot Fizzy?

- **Goal:** prove the KTD2 in-process runs work before the long run starts.
- **Requirements:** R3.
- **Dependencies:** #381 merged to `main`.
- **Files:** none in the repo. Outputs go to the Fizzy clone's `tmp/`.
- **Question:** does `--no-daemon --strategy redefine` boot Fizzy `f220e4832` and score at least one mutant, with the checkout's code and not the bundled 1.8.0 gem (KTD7)?
- **Method (directional):**
  1. Fetch `f220e4832bf40b6f4d4f944253d7a7731d366d37` from `https://github.com/palkan/fizzy.git` into a fresh folder. Reuse #402's clone and bootstrap when that plan has landed. Otherwise `bundle install` and prepare the test database by Fizzy's own setup steps.
  2. `$MUT_IN run --no-daemon --strategy redefine app/models/user/role.rb --format json --output tmp/349-u1.json 2> tmp/349-u1.err`.
  3. `$MUT run app/models/user/role.rb --format json --output tmp/349-u1d.json 2> tmp/349-u1d.err` (daemon, reload).
- **Time box:** 30 minutes, setup included.
- **Pass:** both runs exit 0 or 1, `summary.attempted` is above 0, `summary.errored` is 0, and both JSON files hold `summary.unpaired_mutants`. That key proves #381's code ran, not 1.8.0. Continue to U2.
- **Fail:** record the first error line. File an issue (R7). In U2, run only the reload runs, and use the static redefine bound (Probe 1, Probe 5) in place of run R3. The rule in KTD3 still applies.
- **Test expectation:** none. This is a measurement spike. It merges no code.

### U2. Run the measurement and record the numbers

- **Goal:** one table that holds every R2 field for each run.
- **Requirements:** R1, R2, R3, R4.
- **Dependencies:** U1.
- **Execution note:** smoke-first. Stop a run that passes 3 hours, and record the partial state.
- **Files:** none in the repo.
- **Runbook (directional).** Run from the Fizzy clone root. Run one command at a time: two runs in one checkout share worker databases (#404). Let `OPS` be the 21 names, comma-separated, from `ruby -I<mutineer>/lib -rmutineer -e 'print Mutineer::MutatorRegistry::ALL.keys.join(",")'`.

| Run | Command (directional) | Measures |
|---|---|---|
| D1 dry run | `$MUT run --dry-run --operators "$OPS" --test test/models/card_test.rb app/models app/controllers`, then the same without `--operators` | declined per operator, skipped (invalid), total, for all and for default operators |
| R1 daemon, reload | `$MUT run app/models app/controllers --format json --output tmp/349-r1.json 2> tmp/349-r1.err` | every R2 field, default operators, Fizzy's own config |
| R3 in-process, redefine | `$MUT_IN run --no-daemon --strategy redefine --operators "$OPS" app/models/board/accessible.rb app/models/user/role.rb app/models/user/mentionable.rb app/models/event/description.rb --format json --output tmp/349-r3.json 2> tmp/349-r3.err` | exact redefine unplaceable and invalid, all operators |
| R4 in-process, reload | R3 with `--strategy reload` and output `tmp/349-r4.*` | exact reload unplaceable and invalid, all operators |
| R2 daemon, all operators (optional, Q3) | R1 with `--operators "$OPS"` and output `tmp/349-r2.*` | every R2 field, all operators |

- **Approach:**
  1. Run D1, then R1, R3, R4. Note the wall time of each.
  2. "Warning fired" is whether `tmp/349-rN.err` contains `were not run`.
  3. Read the integers from `summary` in each JSON file. Compute both shares unrounded (R4).
  4. Check the mechanism. Run D1 a second time with the default operators. The dry run does not pair sources (`lib/mutineer/cli.rb:429`), but a real run drops unpaired sources before it collects jobs (`lib/mutineer/cli.rb:641-651`). So the dry run's mutations plus skipped (invalid) plus ignored must equal R1's `summary.total` plus `summary.unpaired_mutants` (1,071 at this commit, Probe 2 and Probe 4). R1's `summary.declined` counts paired sources only, so it can be lower than the dry run's declined count. Record both.
  5. For all operators without R2, derive the bound: `(R3 or R4 unplaceable + skipped_invalid) / (R1 attempted + that sum)`. The default operators come first in the registry, so their jobs survive the cross-operator dedupe (#275). So R1's `attempted` is a lower bound for the all-operator `attempted`, within 3 mutants: with the default operators, redefine cannot place 4 jobs and reload 1 (Probe 1). Label this row "derived".
- **Test expectation:** none. This unit produces numbers only.
- **Verification:** the table has one row per run, each R2 field filled, and both shares per row.

### U3. Apply the decision rule and publish

- **Goal:** the limit is kept or changed by KTD3, and the numbers are where KTD4 puts them.
- **Requirements:** R5, R6, R8.
- **Dependencies:** U2.
- **Files (no-change branch, expected):**
  - `CHANGELOG.md`: one sentence in the Unreleased entry for #381, like `CHANGELOG.md:109-118`. It names Fizzy, both commits, the operators and the shares.
  - `lib/mutineer/reporter.rb`: one comment line above `UNRUN_SHARE_LIMIT` (lines 28-31) that cites #349 and the measured share.
- **Files (change branch, only after the maintainer agrees, see Goal Capsule):**
  - `lib/mutineer/reporter.rb:31`: the new value.
  - `test/reporter_test.rb`: `test_warns_when_the_unplaceable_share_is_over_the_limit` (line 544) asserts the new `limit N%` text. `test_no_unrun_warning_under_the_limit_or_the_floor` (line 575) keeps its two cases under the new limit. A new boundary test asserts that a share exactly at the limit does not warn and one mutant more does, so the gate stays on unrounded values.
  - `docs/json-schema.md:60` and `:62`: the new percent.
  - `CHANGELOG.md`: a `### Changed` bullet that says the warning now fires above N% and why.
- **Approach:** write the rule branch and its reason into the pull request body. Do not paste survivor ids or file names (R8).
- **Test scenarios:** no-change branch: none, the change is a comment and a CHANGELOG line. Change branch: the three reporter tests above.
- **Verification:** see the Verification Contract.

### U4. File the limitations the runs found

- **Goal:** each new limitation has an issue before the pull request opens.
- **Requirements:** R7.
- **Dependencies:** U2.
- **Files:** none.
- **Approach:** search open issues first. File only what is missing, with a `**Claude:**` prefix and the existing labels.
  - `literal_mutation` makes non-parsing mutants from heredoc lines and interpolated-string parts on parse-clean sources (Probe 3). The repro is a source with a heredoc and an interpolated string. Its fix pull request turns the repro into a fixture.
  - Any U1 boot failure, and any run whose `errored` count is above 0.
  - Q2, if the maintainer wants a count-based warning for skipped-invalid mutants.
- **Test expectation:** none.

---

## Verification Contract

For the pull request head, from the worktree root:

```sh
bundle exec rake test
ruby -Ilib -e 'require "mutineer"'
bundle exec rake yard:strict
```

Change branch only, as a quick check before the full suite:

```sh
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bundle exec ruby -Ilib -Itest test/reporter_test.rb
```

The measurement itself is verified by U2: one row per run, the mechanism check in step 4, and the derived rows labeled.

## Definition of Done

- The U2 table exists in the pull request body and in a `**Claude:**` comment on #349, with both Mutineer and Fizzy commits.
- The KTD3 branch is stated with its reason. The limit is unchanged, or it changed with the maintainer's yes and the change-branch tests.
- `CHANGELOG.md` Unreleased and the `UNRUN_SHARE_LIMIT` comment carry the numbers. No released section changed.
- U4 issues exist, and the pull request body names them.
- No survivor id, security-relevant file name or private report link appears in any output (R8).
- The pull request body says `Closes #349`. Labels: `documentation` for the no-change branch, `enhancement` for the change branch; `priority: low`; `v1.9.0` (tentative, it rides with #381).
- No scratch file from the runs is in the diff.

## Release and semver

- No-change branch: no version bump of its own. A comment and a CHANGELOG sentence ride with the next release (v1.9.0, tentative).
- Change branch: minor. It changes when a warning prints and changes no exit code, score or JSON key. It does not touch the Action's defaults, so it is not major.
- This plan never tags, publishes or merges a release (`AGENTS.md`, "Releasing").

## Risks and Overlaps

| Item | Overlap | Handling |
|---|---|---|
| #381 (count unpaired sources and their mutants) | Hard dependency (KTD1). Its Q2 waits on these numbers. | Wait for its merge. Hand the unpaired share to its Q2 (KTD3). |
| #402 (pinned Fizzy sample before each release) | Pins the same commit. Owns stored per-release Fizzy counts. | Reuse its clone and setup steps if it merges first. Store nothing here (KTD4). |
| #404 (two SQLite runs in one checkout share worker databases) | Parallel runs in one Fizzy clone would corrupt each other. | One run at a time (U2). |
| #391 (the reload fix for Rails class bodies) | Changes `errored` on Fizzy, and may make the boot file's workarounds redundant. | Measure on a `main` that has it. Keep Fizzy's committed boot file. |
| #375 (place a hook-block mutant before the rest of its file loads), #389 (full reload) | Can change reload `unplaceable` for `board/accessible.rb`. | Record the Mutineer commit. Re-measure after either merges (Deferred). |
| #393 (a mutant is invalid only when it adds a parse error) | Can change `skipped_invalid`. The 6 Probe 3 mutants add new errors on clean sources, so they stay invalid. | Not checked on that branch. Record the Mutineer commit. |
| #360 (a not-green clean run names no failing test), #282 and #338 (test order and seed) | R1 can fail its clean check, as Vladimir's full-scope run did with every test passed. | R1 uses pairing, not every test. If the clean check fails, record it, file it under R7, and stop R1. |
| #322 (count `ran_at_load` mutants, 2.0) | Adds another excluded status on the 2.0 line. | Out of scope. The 1.x share does not include it. |
| Sibling plan for #381 | Its R10 adds unpaired mutants to the same share. Its noise row expects the warning on every Fizzy run. | This plan's numbers confirm or refute that row. |

## Open Questions

- Q1. May the CHANGELOG name Vladimir's public fork (`palkan/fizzy`) and its commit? Default: yes, it is public (#402 probe), with aggregate counts only (R8). The maintainer decides. If no, write "Fizzy" and the commit sha only.
- Q2. Should a skipped-invalid mutant on a parse-clean source warn at any count above the floor? The warning text already calls it a bug, but the 10% share hides 6 of 7,804. Default: no change here; U4 files the question as an issue. The maintainer decides.
- Q3. Run R2 (daemon, all 21 operators, full scope)? Default: only when R1 took under 45 minutes. The derived row covers the decision otherwise. The implementer decides from R1's wall time.
- Q4. If KTD3's raise branch fires, may the limit go above 25%? Default: no, stop and ask. The maintainer decides.
- Q5. Should the CHANGELOG carry the numbers when the limit does not change? Default: yes. The issue asks for it, and the 1.8.0 entry set the precedent (`CHANGELOG.md:109-118`). The maintainer decides.

## Sources

- Issue text: context folder `issues/349.md`; sibling issues `issues/381.md`, `issues/402.md`.
- Probes: context folder `probes/349/` (`static_unrun.rb` and `.out`, `static_detail.rb` and `.out`, `invalid_detail.rb` and `.out`, `dry_run_all_ops.sh` and `.out`, `pairing_of_targets.rb` and `.out`). Unpaired counts: `probes/381/count_unpaired.out`. Commit choice: `probes/402/p1_remotes.out`.
- Code: `lib/mutineer/reporter.rb:28-31`, `:116-145`, `:883-899`; `lib/mutineer/result.rb:203`, `:214-218`; `lib/mutineer/subject.rb:44-55`; `lib/mutineer/runner.rb:368-377`; `lib/mutineer/daemon_backend.rb:426-434`; `lib/mutineer/cli.rb:417-444`, `:508-510`, `:641-660`, `:898-943`.
- Tests: `test/reporter_test.rb:544-582`.
- Docs: `docs/json-schema.md:60`, `:62`; `CHANGELOG.md:53`, `:102-118`.
- Validation reports of 2026-11-09 (Sol A7, A9, A20; grok-cursor A7, A8; opus A7), for the unpaired arithmetic and the private-link concern.
- Plan format: `docs/plans/2026-10-24-291-feat-excluded-mutant-counts-plan.md`.
- Sibling plans: `docs/plans/2026-11-10-381-feat-count-unpaired-sources-and-mutants-plan.md` (R10, Q2), `docs/plans/2026-11-10-402-chore-pre-release-fizzy-sample-check-plan.md` (KTD5, the clone and bootstrap).
- Fizzy at `f220e4832`: `.mutineer.yml`, `Gemfile` line 64, `Gemfile.lock:321`, `bin/mutineer`, `.ruby-version`.

## Review notes

- Document review ran as a lite pass (coherence, feasibility and scope in one reviewer). The host had no subagent tool, so the plan's author ran it inline. It was not independent.
- Applied: the Probe 1 row had its columns swapped; the U2 lower-bound sentence now states its 3-mutant margin; KTD7 replaces the `Gemfile` edit, because Fizzy's binstub would run the locked 1.8.0 gem.
- Open after review: none beyond Q1 to Q5.
