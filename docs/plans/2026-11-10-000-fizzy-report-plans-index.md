---
title: Fizzy report plans - Index
type: index
date: 2026-11-10
issues: [349, 379, 380, 381, 382, 386, 388, 389, 397, 398, 399, 402, 404]
---

# Fizzy report plans - Index

## Summary

- **What this is:** 13 plans for the open issues from Vladimir Dementyev's report on Mutineer 1.8.0 and Fizzy.
- **What is ready:** All 13 plans passed their own review and gate, and a cross-check between plans.
- **What to do first:** Merge pull request #391 (the reload fix for Rails class bodies), step 1 below.

## Out of scope

Pull request #391 (the reload fix for Rails class bodies) fixes six issues from the same report.
They are not in this batch:

- #378: a reload declares an enum twice, so mutants score `error`.
- #383: a lazily loaded concern makes every mutant score `error`.
- #384: a reload skips a callback twice, so mutants score `error`.
- #385: migration checks with `shared_databases` make every mutant score `error`.
- #387: a deprecation warning prints on every reload under Rails 8.2.
- #390: a reload runs validators and block callbacks twice, so tests give false kills.

## Plans

"Ready" means the plan passed its gate. A condition after it names what must happen first.

| Issue | Plan | Release label and semver class | Size | Spikes | Depends on | Ready |
|---|---|---|---|---|---|---|
| #349 (measure the unrun share on a real Rails app) | [plan](2026-11-10-349-chore-measure-unrun-share-on-real-rails-app-plan.md) | `v1.9.0`. No bump: a code comment and CHANGELOG text. Minor if a maintainer changes the limit. | S | 1 (U1) | #381 merged. #391 merged, or near. | Ready after #381 merges |
| #379 (pair a concern with the test that mirrors its namespace) | [plan](2026-11-10-379-feat-pair-concern-with-namespace-test-plan.md) | `v1.9.0`, minor | S | 0 | None | Ready |
| #380 (`--test` takes a directory or a glob) | [plan](2026-11-10-380-feat-test-option-directory-or-glob-plan.md) | `v1.9.0`, minor | S | 0 | None. U3 (Action glob change) waits for its Q1. | Ready. U3 waits for Q1. |
| #381 (count unpaired sources and their mutants) | [plan](2026-11-10-381-feat-count-unpaired-sources-and-mutants-plan.md) | `v1.9.0`, minor (schema `1.10`) | M | 0 | PR #395 for U4 | Ready |
| #382 (`tests:` map in `.mutineer.yml`) | [plan](2026-11-10-382-feat-tests-map-in-config-plan.md) | `v1.9.0`, minor | M | 1 (U1) | #380 and #381 first (its Q6). #391 soft. | Ready. U4 waits for U1. |
| #386 (methods with a bare `if` or `rescue` body get no default mutants) | [plan](2026-11-10-386-feat-default-mutants-for-bare-if-and-rescue-bodies-plan.md) | PR1: `v1.9.0`, minor (schema `1.10`). PR2: `v2.0`, major, draft, `breaking change`. | PR1: about 16 files. PR2: about 25 files. | 1 (U1) | PR1: #381 for the shared summary text. PR2: a passing U1 and the PR #244 base. | PR1 ready. PR2 exists only if U1 passes. |
| #388 (cause of each errored mutant in JSON) | [plan](2026-11-10-388-feat-json-errored-mutant-list-plan.md) | `v1.9.0`, minor (schema `1.10`) | M | 1 (U5) | None blocking. #391 edits the same daemon method. | Ready. U3 waits for U5. |
| #389 (full-reload strategy for Rails daemon runs) | [plan](2026-11-10-389-feat-rails-full-reload-strategy-plan.md) | `v2.0`. Minor class (opt-in). Draft until its Q5. | L | 1 (U1, with checks S1 to S12) | #391, #398 Step A, #388 | Ready. U2 to U7 wait for U1. |
| #397 (mutate class-body macros) | [plan](2026-11-10-397-feat-class-body-macro-mutants-plan.md) | `v2.0`. Minor class (opt-in). PR1 and PR3 stay drafts until its Q1. | PR1: M. PR2: 1 file. PR3: M. | 2 (U1, U8) | PR1: U1 passes. PR2: #391. PR3: #389. | Ready. PR1 merge waits for U1. |
| #398 (a coverage cache hit still runs the full clean check) | [plan](2026-11-10-398-feat-coverage-cache-hit-clean-check-plan.md) | `v1.9.0`, minor. Steps B1 and B2 are tentative for `v1.9.0`. | Step A: S. B1: M. B2: M. | 2 (U1, U4) | Step B: a passing U4 | Step A ready. B1 and B2 wait for U4. |
| #399 (docs: triage a `present?` to receiver survivor) | [plan](2026-11-10-399-docs-triage-present-to-receiver-survivor-plan.md) | `v1.9.0`, `documentation`. No bump. | S | 0 | None | Ready |
| #402 (run a pinned Fizzy sample before each release) | [plan](2026-11-10-402-chore-pre-release-fizzy-sample-check-plan.md) | `v1.9.0`. No bump: no shipped file changes. | S | 1 (U1) | #391 before U3 records counts | Ready |
| #404 (a run lock for SQLite daemon runs) | [plan](2026-11-10-404-fix-sqlite-run-lock-plan.md) | `v1.9.0`, patch | S | 1 (U1) | None | Ready |

## Merge order

This order covers the whole batch. Each step names one reason.

1. **PR #391 (the reload fix for Rails class bodies).** The spikes for #402, #349 and #382 need it. The Rails gate in #386 needs it. #389 builds on it. If a maintainer wants it released as 1.8.2, cut that release before step 3. After any `feat:` commit lands on `main`, `release-pr.yml` makes the next release a minor (`.github/workflows/release-pr.yml:320`).
2. **PR #395 (the Action asks the CLI for `cache_dir` and baseline).** #381 U4 (the Action summary line) starts from its new `action.yml` layout. #380 overlaps only in the `test` input description.
3. **#399 (docs: triage a `present?` survivor).** It is docs only and independent. The #397 plan now puts its new section after "Endless range", so this order is no longer required.
4. **#404 (SQLite run lock).** It is an independent patch-class fix. If it lands early, overlapping runs cannot spoil later Fizzy measurements.
5. **#380 (`--test` takes a directory or a glob).** It adds `Pairing.expand_test`, which #382 reuses. It also owns the final `--test` docs text. Its tests remove `test/models` from the temporary fixture copy, so #379 cannot break them.
6. **#379 (pair a concern with its namespace test).** It is small and changes pairing only. It lands before #381, so the first unpaired counts include namespace pairing. Its fixture is in `test/fixtures/concern_namespace/`, so the #380 tests need no change.
7. **#381 (count unpaired sources and mutants).** It sets schema `1.10` and adds the rule to compare versions as two integers. U4 needs #395. It lands before #382 (the #382 Q6 order) and before #349. Its U5 files the one issue for the dry-run limit.
8. **#388 (cause of each errored mutant in JSON).** It keeps `1.10` and adds `operator` and `token` to `no_verdict[]`. It changes daemon `run_mutant` before #389 rebases on that method.
9. **#386 PR1 (count methods with no mutants).** It keeps `1.10`. It follows #381, so it adds its dry-run clause and empty-run text to the #381 text. See "Shared decisions".
10. **#382 (`tests:` map).** It lands after #380 and #381, as its Q6 says. It updates the #381 hints, the #381 term "unpaired source" and its own dry-run test.
11. **#398 Step A (narrow the cache-hit clean check).** It lands after the pairing and report changes. If #382 is on the base, Step A also fixes the #382 cache note in `docs/cli.md`. Steps B1 and B2 follow only after the U4 spike passes. #389 must rebase on Step A.
12. **#402 (pinned Fizzy sample before each release).** Its first `rake fizzy:record` runs after steps 1 to 11. Then the stored counts include the new keys from #381, #386 and #388. It is the last `v1.9.0` merge before release step 1.
13. **#349 (measure the unrun share on Fizzy).** It needs #381 on `main`. It may reuse the #402 cache clone, under the rules in "Shared decisions". It changes only a code comment and the CHANGELOG, so it can land after #402 or with it.
14. **The 2.0 line, all drafts.** #389 (full reload) comes after #391 and #398 Step A. Then #397 PR1 as a draft, PR2 after #391, and PR3 after #389. Then #386 PR2, on the PR #244 base, only if its U1 spike passes.

## Shared decisions

These decisions span more than one plan. A plan that disagrees with this list must follow it.

### Schema version `1.10`

- #381, #386 PR1 and #388 share one bump, from `1.9` to `1.10`. The first plan to land sets it. The others keep it.
- The first plan to land also adds the rule to `docs/json-schema.md`: compare `schema_version` as two integers, major then minor.
- `STABILITY.md:16` becomes "`schema_version` `1.10` (1.8.1 reports `1.9`)". Line 114 states a past fact and stays as it is.
- PR #244 (the 2.0 contract flip) can merge first and set the base to `2.0`. Then all three plans stop and ask a maintainer.
- #381 passes its data through `Reporter.new`. #386 passes its data as `report(...)` keywords. Each plan keeps its choice for its own values.

### Dry-run summary and empty-run message (#381 and #386)

- The dry-run summary order is: mutations, skipped, ignored, declined, the #381 unpaired clause, then the #386 "no mutants in N of M methods" clause.
- The #386 plan text still says its clause goes before the unpaired clause. That text is stale. The #381 tests now use `assert_includes`, so the order above passes in both merge orders. The #386 implementer follows the order above.
- In `CLI.warn_empty_run`, the #381 unpaired branch comes first and replaces the "no mutants were generated" message. The #386 method count then does not print. This matches #381 U2 and its test `test_empty_run_names_unpaired_mutants`. The #381 Risks row that says "follows when both apply" is stale.

### The unrun-share limit (#381 and #349)

- One 10% limit covers unplaceable, skipped-invalid and unpaired mutants (`Reporter::UNRUN_SHARE_LIMIT`).
- #349 measures Fizzy and recommends an answer to #381 Q2. A raise also changes the unpaired limit.
- In the CHANGELOG, #349 names its share by its denominator: "unrun share (of attempted plus unrun)". #381 writes the separate scope share.

### Test expansion and pairing (#379, #380, #381, #382)

- #380 owns `Pairing.expand_test` and its directory and glob rules. #382 reuses it. If #382 lands first, it adds the function with the same rules.
- `expand_test` returns an existing file as typed. #382 cleans those paths, so `./test/a_test.rb` and `test/a_test.rb` give one entry.
- #381 adds one shared pairing helper for real runs and dry runs. #382 puts mapped tests inside it, so a mapped source counts as paired in both.
- After #382 lands, an unpaired source has no convention-paired test and no `tests:` entry. The plan that lands second updates the #381 hints to name `tests:`.
- `--test` docs text: #380 writes the final row in `docs/cli.md:9` and `README.md:194`. #381 appends "and counted in the report". #382 appends one clause about the `tests:` map.
- #379 keeps its fixture in `test/fixtures/concern_namespace/`. Nothing adds test files under `test/fixtures/autopair/test`.

### Clean-check test set (#389, #397, #398)

- After #398 Step A, `clean_check_test_paths` is the only source of the clean-check set.
- #389 keeps its one-file combined check and per-file fallback as `full_reload` branches inside the #398 helpers. After Step B, it adds its forced-reloading flag to `run_inputs`.
- When a #397 macro operator is selected, the clean-check set is the whole `--test` set. Its survivor re-run uses that set.

### Strategy name and reload guards (#389, #397, #404)

- The new strategy is `full_reload`. It is opt-in and needs `--daemon --rails` and Minitest. Defaults stay unchanged.
- The three #391 guards stay unchanged and apply only to `reload`.
- Macro mutants from #397 never run on `reload`. PR3 permits them only under `full_reload` with the daemon.
- Under `full_reload`, a macro subject never gets `ran_at_load`. `def` subjects keep the #389 rule until its S8 check decides.
- #389 forks and reloads inside the daemon. The #404 lock stays held, and a second close in one fork does nothing.

### Draft rule for the `v2.0` label

- A merge to `main` ships in the next 1.x release. A pull request with a `v2.0` label therefore stays a draft.
- This covers #389, #397 PR1 and PR3, and #386 PR2. If a maintainer picks a 1.x minor, relabel and mark it ready.
- Under PR #244, boot refusals and the #404 lock stop are provisioning failures. They move from exit 1 to exit 3.

### The Fizzy pin and runs (#349, #382, #389, #398, #402)

- Every Fizzy run uses `palkan/fizzy` at `f220e4832bf40b6f4d4f944253d7a7731d366d37`, in a fresh clone.
- Never use `/Users/davidteren/Projects/OSS/fizzy-palkan`. It has local Gemfile and boot-file edits.
- Use Ruby 3.4.8 and `SAAS=false DATABASE_ADAPTER=sqlite RAILS_ENV=test`, with `CI` and `SEED` unset.
- Run the checkout as `<absolute ruby> <checkout>/bin/mutineer`. Fizzy's own `bin/mutineer` runs the locked gem 1.8.0.
- After #402 merges, other plans may reuse its cache clone and gems. `rake fizzy:sample` takes a lock on the cache.
- `rake fizzy:sample` replaces `.mutineer.yml` and runs `git clean -fdx`. #349 restores the config with `git checkout -- .mutineer.yml` and writes outputs outside the clone.
- Run one Fizzy measurement at a time in one clone.

### Other shared decisions

- **One dry-run issue.** The #381 U5 issue covers the dry-run limit and the text at `lib/mutineer/cli.rb:734`. #402 cites it.
- **Equivalent-skips page.** #399 puts its subsection between "Call to receiver" and "Endless range". #397 puts its section after "Endless range". #386 PR2 finds sections by heading, not by line.
- **Operator counts.** #397 derives the README counts from `ALL.size` and `DEFAULT_NAMES.size`. #386 PR2 then updates only the numbers.
- **Subject count.** #386 counts methods only. Whichever of #386 and #397 lands second skips subjects without `def_node`.

## Spikes to run first

No spike merges code. The list starts with short spikes that block nothing else.

| Spike | Plan | Question | Time box |
|---|---|---|---|
| U1 | #404 | Do the `flock` facts hold on Linux, in all 17 probe cases? A Docker image pull needs approval first. | 15 minutes |
| U5 | #388 | Can a cause pass through daemon `run_mutant` without a change to the reply loop (`daemon_server.rb:126`)? | 1 hour |
| U1 | #402 | Does the pinned sample install, repeat with equal counts, and detect a regression? Needs #391 for the regression check. | 2 hours, with the first `bundle install` |
| U1 | #397 | Do strong tests kill a removed `validates` or `dependent:` in a real Rails process, and weak tests not? | 2 hours. It blocks the PR1 merge. |
| U1 | #398 | How long does a cache hit take on Fizzy, and what share of tests covers one model? | 2 hours. Step A ships either way. |
| U1 | #382 | What does the run-wide union rule cost on Fizzy, in time and verdicts? | 3 hours. It gates U4. |
| U1 | #386 | Does `condition_true`, `condition_false` or a two-branch form meet the noise limits for a 2.0 default? | 6 hours |
| U1 | #349 | Does the checkout's daemon boot Fizzy on Ruby 3.4.8 and score a mutant? Needs #381 on `main`. | 30 minutes after setup |
| U4 | #398 | Is per-test cache invalidation exact enough and cheap enough? | 1 day. It gates B1 and B2. |
| U1 | #389 | Does `full_reload` work on real apps? Checks S1 to S12 cover substitution, reloading, safety, cost, verdicts and Ruby versions. | 2 working days |
| U8 | #397 | Does full-reload test selection find the tests that kill each macro mutant? Needs the #389 branch. | 4 hours |

## Open questions for a maintainer

Each question has a default. Work goes on with the default until a maintainer answers.

### #349 (measure the unrun share)

- Q1. May the CHANGELOG name `palkan/fizzy` and its commit? Default: yes, with aggregate counts only.
- Q2. Should skipped-invalid mutants on parse-clean sources warn at any count? Default: no change. U4 files an issue.
- Q3. Run the all-operator daemon run? Default: only if the daemon run takes under 45 minutes. The implementer decides.
- Q4. May the limit go above 25%? Default: no. Stop and ask.
- Q5. Publish the numbers when the limit stays the same? Default: yes.
- Q6. One limit, or a separate limit for unpaired mutants (#381 Q2)? Default: one limit.

### #379 (namespace test pairing)

- Q1. Run tests at both paths? Default: no. The `concerns/` path wins.
- Q2. Pair split test names now? Default: no. U5 files a follow-up issue.
- Q3. Is a minor release right when score gates can change? Default: yes, `v1.9.0`.
- Q4. Should a concern take its namespace test from a shorter model? Default: no. They share it.

### #380 (`--test` directory or glob)

- Q1. Should the Action stop bash from expanding globs in `test`? Default: not in a minor. Put U3 in a draft 2.0 pull request. A maintainer files one issue for one-level `**`.
- Q2. Should `--test-command` get expanded directory files? Default: no.
- Q3. Should a directory skip `fixtures/`, `dummy/` and `system/`? Default: no.
- Q4. Should a positional source accept a quoted glob? Default: not in this pull request.

### #381 (unpaired counts)

- Q1. Join the unrun-share warning, or print a separate warning? Default: join.
- Q2. A separate limit for unpaired mutants? Default: one limit. Decide after #349.
- Q3. List each mutant id in `unpaired_sources[]`? Default: no, counts per source.
- Q4. Is one new Action summary line a minor change? Default: yes. If not, drop U4.
- Q5. Fold skip lines above a count? Default: no.
- Q6. Allow `--rails` or `--boot` dry runs without `--test`? Default: out of scope. U5 files the issue.
- Q7. Show the scope share in HTML and Action summaries? Default: no.

### #382 (`tests:` map)

- Q1. Do mapped tests run against every source? Default: yes. Decide from the U1 count.
- Q2. Exit 2 for a `tests` pattern that matches nothing, a warning for `sources`? Default: yes.
- Q3. Key name `tests`, or `test_map`? Default: `tests`.
- Q4. Who files the eight follow-up issues? Default: the implementing pull request, before merge. Else a maintainer.
- Q5. Print the override line on every `--test` run? Default: yes.
- Q6. Merge order? Default: #380, then #381, then #382.

### #386 (no-mutant methods and default operators)

- Q1. Are the noise limits right (50%, 50%, 20%, 50% cost cap)? Default: yes. Decide before U1.
- Q2. Should `--since` narrow the method count? Default: no.
- Q3. Where does a passing 2.0 change live? Default: close #386 after U1 and open a new `v2.0` issue linked from #284 (2.0 default preconditions).
- Q4. Base branch for PR2? Default: PR #244, rebased on `main` after PR1 and #391.
- Q5. Should `STABILITY.md` promise no default operator change in a minor? Default: yes. Confirm before PR1 merges.
- Q6. Who files the deferred-limit issues? Default: the implementer, before PR1 opens. Else a maintainer.
- Q7. Run the candidates on Fizzy's 13 controller concerns? Default: yes, when a setup exists.
- Q8. Name of the two-branch operator? Default: `condition_false_two_branch`.
- Q9. Must `@v1` Action installs use `~> 1` before 2.0.0? Default: yes. Decide before PR2 leaves draft.

### #388 (errored mutant causes)

- Q1. Is `1.10` the right schema version? Default: yes.
- Q2. Add a top-level `errored` array? Default: no. `no_verdict[]` already lists them.
- Q3. Show causes in human and HTML reports? Default: defer to a follow-up.
- Q4. Put the last command line in `--test-command` details? Default: defer.
- Q5. Add an `error_class` key? Default: no.
- Q6. Does #347 cover part of this? Default: the implementer reads it and states the relation.
- Q7. Is 500 characters enough? Default: yes.
- Q8. Who files the deferred-limit issues? Default: the implementer. Else a maintainer.

### #389 (full reload)

- Q1. A `.mutineer.yml` key for `strategy`? Default: no.
- Q2. Compile mutant text as a string to keep the real `__FILE__`? Default: no.
- Q3. Is the clean-check set enough for reload safety? Default: yes. Revisit with #398.
- Q4. Second app for check S9? Default: `rubygems/rubygems.org`.
- Q5. Ship in a 1.x minor? Default: keep `v2.0` and the draft.
- Q6. An eager-load option? Default: no, unless check S5 fails.
- Q7. In-process `full_reload`? Default: the implementer files a follow-up issue.
- Q8. New items for #284? Default: the implementer drafts a comment. A maintainer edits #284.
- Q9. Load unmanaged sources after a reload? Default: no. They stay `unplaceable`.

### #397 (class-body macros)

- Q1. Ship in 2.0 or a 1.x minor? Default: keep `v2.0`. PR1 stays a draft until answered.
- Q2. Base branch for PR1? Default: `main`.
- Q3. Should dry runs refuse macro operators without `--test-command`? Default: no. List them with a note.
- Q4. File the follow-up issues? Default: yes, before PR1 merges.
- Q5. Add a macro run to the #402 sample? Default: not in its first version.
- Q6. Include `validates_*_of`, `validates_with` and `validates_associated`? Default: yes.
- Q7. How does JSON mark a macro subject? Default: document that a name ending in `)` is a macro.
- Q8. Track the eager-load effect on verdicts? Default: document it in PR1. A maintainer files an issue.
- Q9. Stable ids for same-name block callbacks? Default: document the limit. A maintainer files an issue.

### #398 (cache-hit clean check)

- Q1. Print the skipped-tests line on every hit? Default: yes.
- Q2. Narrow further after #396 (an in-process `--since` run builds the full map)? Default: yes, as a #396 follow-up.
- Q3. Is B1 enough if U4 part 2 fails? Default: yes. Track B2 on its own.
- Q4. B1 and B2 in `v1.9.0`? Default: yes, if U4 passes before the batch.
- Q5. A red non-covering test stops a miss but not a hit. Is that a minor change? Default: yes. Decide before Step A merges.

### #399 (`present?` triage docs)

- Add a CHANGELOG entry? Default: no.
- File an issue for a receiver-aware rule? Default: no.

### #402 (Fizzy sample check)

- Q1. Which repository holds the pin? Default: `palkan/fizzy` at `f220e4832`.
- Q2. May an urgent security patch skip the check? Default: no.
- Q3. Mention the check in the CHANGELOG? Default: no.
- Q4. File the dry-run issue? Default: no. Cite the #381 issue.
- Q5. Pin Ruby for `mise` or `chruby`? Default: no.

### #404 (SQLite run lock)

- Q1. How to track the `file:` URI limit? Default: no lock for `file:` names, and one tracking issue.
- Q2. Should the stop message name the lock file? Default: no. The docs carry the hint.
- Q3. Which issue tracks the other gaps? Default: a maintainer files one umbrella issue before the pull request opens.

## Cross-check findings a fixer rejected or changed

The cross-check between plans gave 49 findings. The fixers rejected one and applied the rest. This table lists the rejection and the findings applied with changes.

| Finding | Plan | What the fixer did | Reason |
|---|---|---|---|
| The #379 fixture breaks the #380 test lists. Update the #380 tests, or note it in #379. | #379 | Rejected | #379 moved its fixture to `test/fixtures/concern_namespace/`. The conflict is gone, so #380 needs no change. |
| The same conflict, from the #380 side. Say that #379 uses a separate directory. | #380 | Applied with other text | When #380 was edited, #379 still used the shared fixture. #380 now removes `test/models` from its temporary copy. That text is now stale but harmless. |
| Put the #386 dry-run clause after the #381 clause. | #386 | Applied with the opposite order | The fixer thought the #381 tests needed the unpaired clause last. #381 now uses `assert_includes`, so "Shared decisions" sets the order. |
| Print the #381 empty-run text first, then the #386 text. | #386 | Changed | The #381 branch replaces the message. Both texts never print together. |
| Name a #397 section placed after "Endless range". | #399 | Applied with other text | The #397 plan gave no position at that time. It now places the section after "Endless range". |
| Change the #382 docs note on cache hits. | #398 | Partly stale | #382 had already used the covering-only rule. #398 adds a fix for the case where #382 lands first. |
| A suggested text had a stray backtick. | #349 | Applied with a fix | The fixer removed the backtick. |
