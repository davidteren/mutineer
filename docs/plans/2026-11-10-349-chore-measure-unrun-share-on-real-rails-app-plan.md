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

Measure Fizzy, assess the warning limit, and recommend how to handle unpaired mutants.

## Goal Capsule

- **What:** Measure declined counts and unrun shares for #349, following #291's counts of mutants excluded from scoring.
- **Why:** Give the maintainer evidence for the 10% warning, so users can trust its signal.
- **How:** Use a pinned public Fizzy commit. Apply the decision rule for `Reporter::UNRUN_SHARE_LIMIT` (KTD3), recommend an unpaired limit (R9), and publish the numbers (KTD4).
- **Owners:** The implementer runs the plan. The implementer decides Q3 (the optional run). The maintainer decides the other open questions and merges.
- **Recommendation:** Answer #381 Q2: one shared limit or a separate limit for unpaired mutants.
- **Authority:** This plan, then `AGENTS.md`, then #349. This plan controls differences; see "Corrections to the issue".
- **Stop and ask:** The rule requires a limit change in U3; the measured share from unplaceable plus skipped-invalid exceeds 10%; or U1 cannot boot Fizzy on Ruby 3.4.8. Also stop before concurrent Fizzy runs in one checkout (#404, shared worker databases).
- **Size:** S (small), one measurement session. Expected diff: 2 files, `CHANGELOG.md` and a comment in `lib/mutineer/reporter.rb`. Change branch: 5 files.
- **Delivery:** One pull request from `main`, after #381 (unpaired counts) merges. Wait for #391 (Rails class-body reload fix) if it is near; U1 allows a start without it. Complete setup (U1), measurement (U2), publication (U3), and limitation filing (U4), in that order. No release step.

---

## Product Contract

### Summary

Pull request #334 shipped #291's unscored-mutant counts. It measured only Mutineer's `lib/` and `test/fixtures/rails_app`. The fixture has no concerns and an unrun share of 0, so it cannot tune the limit (`CHANGELOG.md:109-118`).

Measure Fizzy, a concern-heavy Rails 8 app. Apply the rule for `UNRUN_SHARE_LIMIT` (`lib/mutineer/reporter.rb:31`), record #381's unpaired count, and recommend an answer to its Q2.

### Problem Frame

The warning fires when unplaceable plus skipped-invalid mutants exceed 1 and 10% of attempted plus unrun (`lib/mutineer/reporter.rb:896-899`). The 10% limit has no supporting measurement.

#381 adds unpaired mutants to this share. Its sibling plan is `docs/plans/2026-11-10-381-feat-count-unpaired-sources-and-mutants-plan.md`: requirement R10 (`:66`), limit question Q2 (`:492`), and #349 overlap row (`:478`).

Existing probes place today's two classes below 1%, even with all 21 operators. Their KTD3 result is nearly certain. Unpaired mutants raise Fizzy's share to at least 14.0% (the `count_unpaired.out` probe). Measure after #381 merges; the main output is R9's recommendation.

### Requirements

- R1. Use `palkan/fizzy` at public commit `f220e4832bf40b6f4d4f944253d7a7731d366d37`, branch `vova/sfruby-mutation`. #402 (a pinned Fizzy sample before each release) uses the same commit.
- R2. Record each run's Mutineer commit, Fizzy commit, Ruby version, command, operators, strategy, daemon or in-process mode, and wall time. Record `total`, `attempted`, `unplaceable`, `skipped_invalid`, `no_coverage`, `declined`, `declined_by_operator`, `unpaired_sources`, and `unpaired_mutants`. Record whether stderr warned, its named clauses, and whether it would warn without unpaired mutants (U2 step 2).
- R3. Cover reload, daemon and report output with the daemon run. Cover the dry-run sibling with the dry run. Cover redefine with the static bound (the `static_unrun.rb` and `pairing_of_targets.rb` probes). Use the redefine and reload runs when KTD8 triggers them. Use in-process runs only under KTD8. No Action run is needed (KTD5).
- R4. Calculate unrounded shares from JSON integers, with and without `unpaired_mutants`.
- R5. Apply KTD3. Record its branch and reason.
- R6. Publish numbers under Unreleased in `CHANGELOG.md` and in the pull request body. Add one comment beside `UNRUN_SHARE_LIMIT`, citing #349 and the CHANGELOG version, without a number (KTD4).
- R7. File each new limitation as an issue. Do not fix it in this pull request.
- R8. Publish aggregate counts only. Exclude survivor ids, security-relevant file names, and links to the private report.
- R9. Use the daemon run's numbers to recommend one shared limit or a separate unpaired limit for #381 Q2 (KTD3). Put the recommendation and reason in the pull request body and #349 comment. Name the maintainer as decider. Do not change the unpaired limit here.
- R10. Pin Ruby 3.4.8 by absolute path and `RBENV_VERSION`. Set `SAAS=false`, `DATABASE_ADAPTER=sqlite`, and `RAILS_ENV=test`. Unset `CI` and `SEED` (KTD7).

### Acceptance Examples

- AE1. R2, R4: The default-operator daemon run reports `unplaceable: 1`, `skipped_invalid: 0`, `attempted: 800`, and `unpaired_mutants: 149`. Record `1 / 801 = 0.12%` without unpaired and `150 / 950 = 15.79%` with unpaired. Record "warning fired: yes" and "would fire without unpaired: no". These numbers are illustrative; U2 supplies the measurements.
- AE2. R5: Every share without unpaired is at or below 10%. Keep `UNRUN_SHARE_LIMIT = 0.10`. U3 changes only `CHANGELOG.md` and the constant's comment.
- AE3. R7: The all-operator dry run reports `6 skipped (invalid)` on parse-clean sources. File the `literal_mutation` heredoc issue before opening the pull request. Name it in the body.
- AE4. R9: With AE1's numbers, the pull request body states: "Recommendation for #381 Q2: keep one 10% limit. Fizzy warns at 15.79%, all of it from sources with no paired test. The maintainer decides."

### Scope Boundaries

- Do not change scores, exit codes, `summary.total`, or JSON keys.
- Add no script, Rake task, or fixture. Keep the runbook in this plan.
- Do not change #381's unpaired counting or limit. Measure and recommend only (R9).
- File defects as issues; do not fix them here (R7).

#### Deferred to Follow-Up Work

- `literal_mutation` heredoc and interpolation mutants that fail to re-parse (the `invalid_detail.rb` probe). U4 files the issue; its fix pull request adds the repro fixture.
- A count-based warning for skipped-invalid mutants on parse-clean sources (Q2).
- Re-measure if `full_reload` from #389 (full reload for Rails daemon runs) becomes the default under #284 (2.0 default preconditions). Today it is opt-in, and the default `reload` counts stay the same. Under `full_reload`, hook-block defs get placed (389 R10). Sources that no reloading autoloader manages score `unplaceable` (389 R8). #375 (place hook-block mutants before the remaining file loads) does not change that count (`refute/branches_static.out`). It can change survived and `ran_at_load` counts, which this plan does not assess.

### Corrections to the issue

- **"`--operators <all>`".** No `all` value exists. `--operators all` exits 2 with `Unknown operator: "all"` (the `dry_run_all_ops.sh` probe; `lib/mutineer/cli.rb:155-156`, `:358-360`). Pass the 21 names from `MutatorRegistry::ALL`.
- **"`mutineer run app --dry-run`".** Fizzy exits 2 with `--boot/--rails requires at least one --test file` (the `dry_run_all_ops.sh` probe). Its `.mutineer.yml` sets `rails: true`. On `8d9905c4`, dry run skips pairing (`lib/mutineer/cli.rb:429`), but boot mode needs `--test` (`lib/mutineer/cli.rb:438-441`). Pass one `--test`; dry run still lists every source.
- **The dry run cannot give the unplaceable count.** It prints mutations, skipped (invalid), ignored, and declined only (`lib/mutineer/cli.rb:907-928`). Unplaceable depends on coverage and needs a real run (`lib/mutineer/runner.rb:377`, `lib/mutineer/daemon_backend.rb:432-434`).
- **"a full `--strategy redefine --rails` run".** Fizzy sets `daemon: true`. The daemon reloads and overrides `--strategy redefine` with a warning (`lib/mutineer/cli.rb:508-510`). Redefine needs serial `--no-daemon` (`lib/mutineer/cli.rb:64-66`). KTD8 uses a static bound, with targeted runs only near the limit.
- **"A redefine run on concern-heavy Rails code is the likely worst case".** Not on Fizzy. The all-operator redefine bound is 59 unplaceable of 7,798 valid jobs (0.76%), plus 6 invalid (the `static_unrun.rb` probe). Concerns sit beside models, such as `app/models/board/accessible.rb`. The `concerns/` folders contain 0 statically unplaceable jobs. Unpaired mutants drive the share.
- **The list of counts to record is not complete.** #381 adds unpaired mutants to the share. At Fizzy `f220e4832`, they produce at least 14.0% with default operators (the `count_unpaired.out` probe).
- **"add the numbers to the CHANGELOG entry for the release that ships #334".** #334 shipped in 1.8.0 (`CHANGELOG.md:53`, `:102-118`). The issue prohibits changes to released sections. Use Unreleased (KTD4).
- **The issue comment links Vladimir's private report.** Do not repeat that link (R8).

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Measure after #381 merges, on its `main`.** Only unpaired mutants can move Fizzy's share substantially (the `static_unrun.rb` and `count_unpaired.out` probes). Rejected: measuring on `8d9905c4`, which answers only what the probes already establish.
- KTD2. **Run the daemon with default operators; use the static bound for all operators.** This matches Fizzy's configuration. Only 4 paired files contain unplaceable or invalid jobs (the `static_unrun.rb` and `pairing_of_targets.rb` probes). KTD8 controls their real runs. Rejected: a full serial redefine run with all 21 operators. It processes 7,778 mutants individually without adding decision evidence. Also rejected as the default: a full all-operator daemon run. Its 7,778 mutations cost about 7 times the default run's 1,061 (the `dry_run_all_ops.sh` probe). Q3 keeps it optional.
- KTD3. **The decision rule.** Use unrounded shares: `u / (attempted + u)`.
  - Keep `0.10` when every unplaceable-plus-skipped-invalid share is at or below 10% (expected).
  - Raise it only if those classes trigger a warning and every unrun mutant has an expected, documented cause (`docs/json-schema.md:60`). None may be a Mutineer bug. Use the smallest whole percent above the highest share. Ask before exceeding 25% (Q4). After #381 (unpaired counts) lands, `UNRUN_SHARE_LIMIT` also limits unpaired mutants (381 plan KTD3, R10). A raise changes that limit too. Ask the maintainer to choose: raise the shared limit, or split the constant (#381 Q2).
  - Never lower the limit to catch a few bug-signal mutants. File an issue (R7, Q2).
  - Do not tune for unpaired mutants here. Their share above 10% is a valid disclosure (#381 KTD3).
  - **Branch for the share with unpaired mutants (R9).** Use the daemon run's `attempted`, `unplaceable`, `skipped_invalid`, `unpaired_mutants`, and "would fire without unpaired" field (U2 step 2). Recommend one 10% limit for all three classes. #381's warning names unpaired mutants and gives a remedy: add a test or use `--test` (381 plan `:196`). Users can act on it. A separate limit needs another unmeasured value. A value below Fizzy's share still warns; one above it hides the test gap. Recommend a separate clause or limit only if the daemon run's stderr does not distinguish the unpaired clause. Also file that as an #381 defect (R7).
  - This matches #381 Q2's default (381 plan `:492`). The maintainer makes the final decision on #381.
  - Rejected: returning the question to #381 Q2 without a recommendation. That plan already waits here (381 plan `:478`, `:492`), which would leave the decision without an owner.
- KTD4. **Publish in three places.**
  - Add a sentence to #381's Unreleased `CHANGELOG.md` entry, following #291's 1.8.0 entry (`CHANGELOG.md:109-118`). If #381's entry is released, add a separate Unreleased bullet. Do not edit released sections. Name each share by its denominator: "unrun share (of attempted plus unrun)". Keep it apart from the scope share that #381 writes in the same entry, and do not restate that share.
  - Add one comment above `UNRUN_SHARE_LIMIT` (`lib/mutineer/reporter.rb:28-31`), citing #349 and the CHANGELOG version. Include no percent; it would become stale after re-measurement (Deferred).
  - Put the full table and R9 recommendation in the pull request body and a `**Claude:**` comment on #349.
  - Rejected: a new results file under `docs/`. Nothing reads it, and #402 owns stored Fizzy counts. Also rejected: a measured share in the comment, which could drift after a later re-measurement.
- KTD5. **No Action run.** The Action uses the same CLI and reporter. `action.yml` contains no `unrun` or `unplaceable` handling. Stderr reaches the job log unchanged.
- KTD6. **Use a fresh Fizzy clone.** `/Users/davidteren/Projects/OSS/fizzy-palkan` has uncommitted `Gemfile`, `Gemfile.lock`, and `test/mutineer_boot.rb` edits. The boot file is an experiment with `MUT_SKIP` switches. Clone `f220e4832` and edit nothing. Keep the committed boot file that users run. #402 removes it to expose reload bugs.
- KTD7. **Use the checkout's Mutineer with pinned Ruby and environment.**
  - Fizzy's `Gemfile.lock:321` at `f220e4832` pins `mutineer (1.8.0)`. Its `bin/mutineer` runs that version, without #381 counts.
  - The checkout's `bin/mutineer:4` uses `require_relative "../lib/mutineer"`; `lib/mutineer.rb:3-7` also uses `require_relative`. The daemon starts by absolute path (`lib/mutineer/daemon_client.rb:37`) and uses `require_relative` (`lib/mutineer/daemon_server.rb:5-9`). No Fizzy file requires `mutineer` (`git grep` at `f220e4832`, reviewer probe); `Gemfile:64` sets `require: false`.
  - The daemon inherits the parent environment (`lib/mutineer/daemon_client.rb:177-182`). Existing `RBENV_VERSION` takes precedence over `.ruby-version` (`lib/mutineer/daemon_client.rb:336-339`). A probe observed tool-side `RBENV_VERSION=3.4.9` reaching a Fizzy child (`probes/402/r1_rbenv_pin.out`). Fizzy selects its Gemfile and adapter through `SAAS` and `DATABASE_ADAPTER` (`lib/fizzy.rb:3-10` at `f220e4832`). Pin these as #402 KTD6 does.
  - Use this environment for every run from the Fizzy clone root:

    ```sh
    export RBENV_VERSION=3.4.8 SAAS=false DATABASE_ADAPTER=sqlite RAILS_ENV=test
    unset CI SEED
    RUBY="$(rbenv prefix 3.4.8)/bin/ruby"
    MUT="$RUBY <checkout>/bin/mutineer"
    MUT_IN="bundle exec ruby -I<checkout>/lib <checkout>/bin/mutineer"
    ```

  - Use `$MUT` for daemon runs, as #402 KTD5 does. The daemon boots Fizzy with `bundle exec ruby` (`lib/mutineer/daemon_client.rb:334`). Conditional in-process runs need Fizzy's bundle: `$MUT_IN`. Its `-I` places the checkout before bundled 1.8.0.
  - Rejected: a `path:` change in Fizzy's `Gemfile`, which rewrites the lock preserved by #402.
- KTD8. **Use the static bound instead of in-process runs by default.** Both reviewers found that the redefine and reload runs cannot change KTD3's result. The all-operator redefine bound is 59 of 7,798 valid jobs (0.76%). Paired bounds are redefine 27 and reload 20 (the `static_unrun.rb` and `pairing_of_targets.rb` probes). Both backends mark mutants unplaceable only when the static check is true, never for `:maybe` (`lib/mutineer/runner.rb:377`, `lib/mutineer/daemon_backend.rb:432-434`). Thus, the bound covers daemon and in-process runs. Do the redefine and reload runs only when a derived row (U2 step 6) exceeds 5%. Also do them when the daemon run's share without unpaired exceeds 5%. This is half the limit. Rejected: always using `$MUT_IN` and a 30-minute spike for results that cannot change the decision.

### Assumptions

- #381 merges `summary.unpaired_sources` and `summary.unpaired_mutants` as specified in its R6. Use merged names if different.
- #381's warning retains `were not run` and names each class in parentheses (381 plan `:196`). Use merged text in U2 step 2 if different.
- The pinned commit installs through the public `Gemfile`. `Gemfile.saas` requires private `queenbee` and `rails_structured_logging` gems; `SAAS=false` excludes it (KTD7).
- Fizzy uses Ruby 3.4.8 (`.ruby-version`), above Mutineer's 3.4 floor. U1 checks the daemon's Ruby selection.

### Probe results

Read-only scripts and outputs are in `probes/349/` (Sources). They neither booted Fizzy nor installed gems. They used this worktree's Mutineer, `origin/main` `8d9905c4`.

| Probe | Question | Result |
|---|---|---|
| `static_unrun.rb` on Fizzy `f220e4832` copies of `app/` and `test/` | Maximum unplaceable and invalid counts? | Default operators, `app/models app/controllers`: 1,071 jobs; 10 declined, all `statement_removal`; 0 invalid; redefine 4 unplaceable; reload 1. All 21 operators: 7,804 jobs; 105 declined (`call_to_receiver` 66, `chain_link` 23, `statement_removal` 10, `return_nil` 4, `range` 2); 6 invalid; redefine 59 (0.76%); reload 20 (0.26%). `concerns/`: 646 jobs, 0 unplaceable or invalid. Whole `app/`: 9,231 jobs, 109 declined; unchanged counts of 6, 59 and 20. |
| Code reading and Fizzy's saved `tmp/fullscope.json` | Is the static count an upper bound? | Yes. Unplaceable requires `subject.unplaceable?(strategy)` to be true; `:maybe` becomes `no_coverage` (`lib/mutineer/runner.rb:377`, `lib/mutineer/daemon_backend.rb:432-434`). Invalid is checked before coverage, so its count is exact (`lib/mutineer/runner.rb:368`). Saved `tmp/fullscope.json`, with default operators and every test passed, reports `unplaceable: 1`, matching the reload bound. Its command and Mutineer version were not checked. |
| `refute/branches_static.out`: all operators on `lib/` trees of `main`, #393 (invalid only when a mutant adds a parse error), #375 and #391 | Do pending pull requests change static counts? | No. All four: 7,804 jobs, 105 declined, 6 invalid, redefine 59, reload 20. |
| `dry_run_all_ops.sh` in Fizzy | Does the dry run work? | With one `--test`: `7778 mutations; 6 skipped (invalid); 20 ignored (suppressed); 105 declined`; 1.6 s, exit 0. 7,778 + 6 + 20 = 7,804, matching `static_unrun.rb`. Defaults: `1061 mutations; 0 skipped (invalid); 10 ignored; 10 declined`. Without `--test`: exit 2. `--operators all`: exit 2, `Unknown operator: "all"`. |
| `invalid_detail.rb` | Which 6 mutants are invalid? | All use `literal_mutation` on parse-clean sources. Four empty heredoc lines (`account/seeder.rb:95`, three `*/promptable.rb`), producing `unterminated heredoc`. Two empty interpolated-string parts (`event/description.rb:98`). The warning calls this a Mutineer bug (`lib/mutineer/reporter.rb:139-143`). |
| `count_unpaired.out`, arithmetic from #381's probe | What share do unpaired mutants add? | `f220e4832`, default operators: 149 unpaired, 912 paired jobs. `u / (attempted + u)` decreases as `attempted` increases. Since `attempted` cannot exceed 912, the share is at least 149 / 1,061 = 14.0%. Before Vladimir's tests, Fizzy `d5b7b749d`: at least 312 / 1,071 = 29.1%. |
| `pairing_of_targets.rb` | Which of 13 candidate files pair normally? | 4: `board/accessible.rb`, 18 unplaceable under either strategy; `user/role.rb`, 4 redefine only; `user/mentionable.rb`, 3 redefine only; `event/description.rb`, 2 invalid. The other 9 contribute unpaired mutants. Paired bounds: redefine 27, reload 20. Shares stay under 10% with `attempted` at least 243 for redefine or 180 for reload. |

---

## Implementation Units

### U1. Spike: does the checkout's Mutineer run Fizzy on the pinned Ruby?

- **Goal:** Prove the daemon run's setup before the long run.
- **Requirements:** R3, R10.
- **Dependencies:** #381 and #391 merged to `main`. The spike may start after #381 if #391 remains open. Accept `errored` above 0 only for #391's reload bugs: #378, #383, #384, #385, #387, #390.
- **Files:** No repo files. Write outputs to a folder outside the clone, such as `$HOME/349-out/`. Create it first with `mkdir -p`. A #402 clean deletes the clone's `tmp/`.
- **Question:** Can the checkout's daemon boot Fizzy `f220e4832` on Ruby 3.4.8 and score at least one mutant?
- **Method (directional):**
  1. Fetch `f220e4832bf40b6f4d4f944253d7a7731d366d37` from `https://github.com/palkan/fizzy.git` into a fresh folder. If #402 (pinned Fizzy sample) has merged, you may reuse its cache clone and installed gems. The clone is `$XDG_CACHE_HOME/mutineer/fizzy-sample/fizzy`, or `~/.cache/mutineer/fizzy-sample/fizzy`. First run `git checkout -- .mutineer.yml` there. This restores Fizzy's committed config with `require:` and `ignore:` (KTD6), because `rake fizzy:sample` overwrites it. Do not run `rake fizzy:sample` from any worktree while a #349 run is active. Its `git clean -fdx` deletes the clone's databases and `tmp/`. Otherwise, use KTD7's environment, run `bundle install`, and prepare the test database through Fizzy's setup.
  2. From Fizzy's root in KTD7's environment, `bundle exec ruby -e 'print RUBY_VERSION'` must print `3.4.8`. The daemon uses the same `bundle exec ruby` and `RBENV_VERSION` (`lib/mutineer/daemon_client.rb:177-182`, `:348`). Its ready message includes `RUBY_VERSION` (`lib/mutineer/daemon_server.rb:93`), but the client does not print it (`lib/mutineer/daemon_client.rb:368-378`). Use this preflight as the check.
  3. `$MUT run app/models/user/role.rb --format json --output $HOME/349-out/349-u1d.json 2> $HOME/349-out/349-u1d.err` (daemon, reload).
  4. Only when KTD8 triggers the redefine run: `$MUT_IN run --no-daemon --strategy redefine app/models/user/role.rb --format json --output $HOME/349-out/349-u1.json 2> $HOME/349-out/349-u1.err`.
- **Time box:** 30 minutes after setup. Exclude cloning, `bundle install` with Rails from git, and database preparation.
- **Pass:** Step 2 prints `3.4.8`; runs exit 0 or 1; `summary.attempted` exceeds 0. `summary.errored` is 0, except for the #391 allowance. Each JSON includes `summary.unpaired_mutants`, absent from 1.8.0. With KTD7's load path, this confirms the checkout ran. Continue to U2.
- **Fail:** Record the first error and file an issue (R7). Fix a wrong Ruby version and retry first. If only step 4 fails, use and note U2's static redefine bound. KTD3 still applies.
- **Test expectation:** None. This spike merges no code.

### U2. Run the measurement and record the numbers

- **Goal:** One table containing every R2 field for each run.
- **Requirements:** R1, R2, R3, R4, R10.
- **Dependencies:** U1.
- **Execution note:** Run the smoke check first. Stop runs exceeding 3 hours and record their partial state.
- **Files:** No repo files.
- **Runbook (directional).** Use the Fizzy clone root and KTD7 environment. Run one command at a time; concurrent runs share worker databases (#404). Set `OPS` to the 21 comma-separated names from `ruby -I<mutineer>/lib -rmutineer -e 'print Mutineer::MutatorRegistry::ALL.keys.join(",")'`.

| Run | Command (directional) | Measures |
|---|---|---|
| Dry run | `$MUT run --dry-run --operators "$OPS" --test test/models/card_test.rb app/models app/controllers`, then without `--operators` | Declined per operator, skipped (invalid), total; all and default operators. |
| Daemon run (reload) | `$MUT run app/models app/controllers --format json --output $HOME/349-out/349-daemon.json 2> $HOME/349-out/349-daemon.err` | Every R2 field; default operators; Fizzy's configuration. |
| Redefine run, in-process (only under KTD8) | `$MUT_IN run --no-daemon --strategy redefine --operators "$OPS" app/models/board/accessible.rb app/models/user/role.rb app/models/user/mentionable.rb app/models/event/description.rb --format json --output $HOME/349-out/349-redefine.json 2> $HOME/349-out/349-redefine.err` | Exact redefine unplaceable and invalid counts; all operators. |
| Reload run, in-process (only under KTD8) | The redefine run's command with `--strategy reload` and output `$HOME/349-out/349-reload.*` | Exact reload unplaceable and invalid counts; all operators. |
| All-operator daemon run (optional, Q3) | The daemon run's command with `--operators "$OPS"` and output `$HOME/349-out/349-all-ops.*` | Every R2 field; all operators. |

- **Approach:**
  1. Do the dry run, then the daemon run. Record each wall time. Do the redefine and reload runs only under KTD8.
  2. Record three warning fields:
     - **"fired":** The run's `.err` file contains `were not run`.
     - **"clauses":** Parenthesised text, such as `1 unplaceable, 149 in sources with no paired test`.
     - **"would fire without unpaired":** Set `u2 = unplaceable + skipped_invalid`. True when `u2 > 1` and `10 * u2 > attempted + u2`. This integer check preserves the unrounded old rule (`lib/mutineer/reporter.rb:896-899`). After #381, "fired" can reflect unpaired mutants alone. Use this field for KTD3's two-class decision.
  3. Read JSON `summary` integers and calculate both unrounded shares (R4).
  4. Check the mechanism. The dry run's `--test` bypasses pairing and lists every source. On `8d9905c4`, dry run never pairs (`lib/mutineer/cli.rb:429`); #381 R13 pairs only without `--test`. Real runs remove unpaired sources before collecting jobs (`lib/mutineer/cli.rb:641-651`). The dry run's default mutations plus skipped (invalid) plus ignored must equal the daemon run's `summary.total` plus `summary.unpaired_mutants` plus the ignored mutants in unpaired sources. #381 KTD4 leaves suppressed mutants out of `unpaired_mutants`. That last term is 0 at `f220e4832`, so expect 1,071 (the `dry_run_all_ops.sh` and `count_unpaired.out` probes). The daemon run's `summary.declined` covers paired sources only. It may be lower than the dry run's. Record both.
  5. Cross-check #381's dry run: repeat the dry run with default operators and no `--test`. Its unpaired count must equal the daemon run's `summary.unpaired_mutants` (381 plan R13). If boot mode requires `--test` and exits 2 (`lib/mutineer/cli.rb:438-441`), record this and skip the check.
  6. Without the all-operator daemon run, derive the all-operator bound. If the redefine and reload runs ran, use each run's `(unplaceable + skipped_invalid) / (daemon attempted + that sum)`. Otherwise, substitute the `pairing_of_targets.rb` probe's paired bounds: redefine 27, reload 20. Default operators appear first and survive cross-operator dedupe (#275, duplicate-mutant removal). Evidence: the five defaults lead `MutatorRegistry::ALL` (`lib/mutineer/mutator_registry.rb:35-40`, `:60`), and the registry-first copy is kept (`lib/mutineer/job_plan.rb:66-72`). Thus, the daemon run's `attempted` bounds all-operator `attempted` from below, within 3 mutants. Defaults have 4 unplaceable under redefine and 1 under reload (the `static_unrun.rb` probe). Lower `attempted` and higher unrun counts increase the share. Label the upper-bound row "derived".
- **Test expectation:** None; this unit produces measurements.
- **Verification:** Include one row per run, every R2 field, both shares, and all three warning fields.

### U3. Apply the decision rule and publish

- **Goal:** Apply KTD3, write R9's recommendation, and publish through KTD4.
- **Requirements:** R5, R6, R8, R9.
- **Dependencies:** U2.
- **Files (no-change branch, expected):**
  - `CHANGELOG.md`: One sentence in #381's Unreleased entry, following `CHANGELOG.md:109-118`. If released, add a separate Unreleased bullet (KTD4). Name Fizzy, both commits, operators, and shares. Name each share by its denominator: "unrun share (of attempted plus unrun)". Keep it apart from #381's scope share in the same entry, and do not restate that share.
  - `lib/mutineer/reporter.rb`: One comment above `UNRUN_SHARE_LIMIT` (lines 28-31), citing #349 and the CHANGELOG version. No percent (KTD4).
- **Files (change branch, only after the maintainer agrees, see Goal Capsule):**
  - `lib/mutineer/reporter.rb:31`: Set the new value.
  - `test/reporter_test.rb`: Update `test_warns_when_the_unplaceable_share_is_over_the_limit` (line 544) to assert the new `limit N%` text. Keep both `test_no_unrun_warning_under_the_limit_or_the_floor` cases (line 575) below the new limit. Add a boundary test: exactly at the limit does not warn; one more mutant does. Keep the gate unrounded. Also update the #381 tests that pin the limit: `test_unpaired_mutants_join_the_unrun_share`, `test_unrun_share_adds_unpaired_to_unplaceable` and `test_no_unrun_warning_for_unpaired_under_the_limit_or_the_floor`. Keep that last test's 20 killed and 2 unpaired case below the new limit.
  - `docs/json-schema.md`: Update `unplaceable` and `skipped_invalid`, lines 60 and 62 on `8d9905c4`. Find them by text after #381 rewrites them.
  - `AGENTS.md`: Update "the stderr warning above 10%", line 325 on `8d9905c4`.
  - `CHANGELOG.md`: Add a `### Changed` bullet stating the new N% threshold and reason.
  - Search all limit references instead of relying on line numbers: `grep -rn --exclude-dir=plans "unrun share\|UNRUN_SHARE_LIMIT\|unplaceable + skipped_invalid" lib test docs AGENTS.md STABILITY.md README.md`. Plans under `docs/plans/` are history; leave them unchanged. Change only unrun-share references. Other "10%" references in `README.md`, `STABILITY.md`, `docs/`, and `action.yml` describe `BROKEN_SHARE_LIMIT` (`lib/mutineer/reporter.rb:21`). Leave them unchanged.
- **Approach:** Put the rule branch, reason, R9 recommendation, and supporting daemon-run numbers in the pull request body. Name the maintainer as decider. Exclude survivor ids and file names (R8).
- **Test scenarios:** No-change branch: none, because only a comment and CHANGELOG line change. Change branch: the three reporter tests above.
- **Verification:** Use the Verification Contract.

### U4. File the limitations the runs found

- **Goal:** File each new limitation before opening the pull request.
- **Requirements:** R7.
- **Dependencies:** U2.
- **Files:** None.
- **Approach:** Search open issues first. File missing issues with a `**Claude:**` prefix and existing labels:
  - `literal_mutation` creates invalid mutants from heredoc lines and interpolated-string parts on parse-clean sources (the `invalid_detail.rb` probe). Include a repro with both constructs. The fix pull request turns it into a fixture.
  - Any U1 boot failure or `errored` count above 0 outside U1's #391 allowance.
  - A daemon-run stderr line that does not distinguish the unpaired clause (KTD3).
  - Q2, if the maintainer wants a count-based skipped-invalid warning.
- **Test expectation:** None.

---

## Verification Contract

Run from the worktree root on the pull request head:

```sh
bundle exec rake test
ruby -Ilib -e 'require "mutineer"'
bundle exec rake yard:strict
```

For the change branch, run this quick check before the full suite:

```sh
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bundle exec ruby -Ilib -Itest test/reporter_test.rb
```

Verify measurements through U2: one row per run, step 4's mechanism check, step 5's cross-check, and labelled derived rows.

## Definition of Done

- The pull request body and `**Claude:**` comment on #349 contain U2's table, both commits, and Ruby version.
- KTD3's branch and reason are stated. Any limit change has maintainer approval and passing change-branch tests.
- Both outputs contain R9's recommendation for #381 Q2 and name the maintainer as decider.
- `CHANGELOG.md` Unreleased contains the numbers. The `UNRUN_SHARE_LIMIT` comment cites #349 and the CHANGELOG version, without a number. Released sections remain unchanged.
- U4 issues exist and appear in the pull request body.
- Outputs contain no survivor ids, security-relevant file names, or private report links (R8).
- The body states `Closes #349`. Labels: `documentation` for unchanged behaviour or `enhancement` for a changed limit; `priority: low` (low priority); `v1.9.0` (tentative release with #381).
- The diff contains no scratch files.

## Release and semver

- No-change branch: no separate version bump. The comment and CHANGELOG sentence join the next release, tentatively v1.9.0.
- Change branch: minor version. Warning behaviour changes; exit codes, scores, JSON keys, and Action defaults do not. No major version is needed.
- This plan does not tag, publish, or merge a release (`AGENTS.md`, "Releasing").

## Risks and Overlaps

| Item | Overlap | Handling |
|---|---|---|
| #381 (count unpaired sources and their mutants) | Required dependency (KTD1). Q2 (`:492`) and its #349 row (`:478`) await these numbers. | Wait for merge. Answer Q2 through R9 (KTD3). |
| #402 (pinned Fizzy sample before each release) | Same commit and environment (its KTD6). Owns stored per-release counts. | Reuse its clone and gems if merged first, after restoring `.mutineer.yml` (U1 step 1). Never run both at once. Store no results here (KTD4). |
| #404 (two SQLite runs in one checkout share worker databases) | Concurrent runs corrupt each other. | Run one at a time (U2). |
| #391 (the reload fix for Rails class bodies) | Changes Fizzy's `errored` count; may remove the need for boot workarounds. Static counts remain unchanged (the `refute/branches_static.out` probe). | Apply U1's dependency and error allowance if #381 merges first. Keep the committed boot file. |
| #375 (place a hook-block mutant before the rest of its file loads) | Changes hook-def placement, survived, and `ran_at_load`. The `refute/branches_static.out` probe keeps reload 20 and redefine 59 on its `lib/`, matching `main`. `Subject#unplaceable?` reads only the owner and hook block (`lib/mutineer/subject.rb:53-55`). | Record the Mutineer commit. No unplaceable re-measurement needed. |
| #389 (full reload for Rails daemon runs) | Changes `unplaceable` only for runs that pass `--strategy full_reload`. | Record the Mutineer commit. Re-measure if it becomes the default (Deferred). |
| #393 (a mutant is invalid only when it adds a parse error) | Could change `skipped_invalid`. | The `refute/branches_static.out` probe found unchanged static counts on #393 and #391. Record the Mutineer commit. |
| #379 (pair a concern with the test that mirrors its namespace), #382 (a `tests:` map in `.mutineer.yml`) | Change pairing, unpaired counts, and KTD2's target list. | No effect at `f220e4832`: #379 pairs no concern (379 plan `:134`, `:176`); Fizzy's `.mutineer.yml` has no `tests:` key. If either changes pairing after merge, repeat the `pairing_of_targets.rb` probe and update the four targets. |
| #360 (a not-green clean run names no failing test), #282 and #338 (test order and seed) | The daemon run's clean check can fail despite all tests passing, as Vladimir's full-scope run did. | The daemon run uses pairing, not every test. On clean-check failure, record it, file under R7, and stop the run. |
| #322 (count `ran_at_load` mutants, 2.0) | Adds an excluded status on the 2.0 line. | Out of scope; the 1.x share excludes it. |
| Sibling plan for #381 | R10 adds unpaired mutants to the share. Its noise row (`:479`) expects every Fizzy run to warn. | Confirm or refute that expectation; answer Q2 through R9. |

## Open Questions

- Q1. May the CHANGELOG name Vladimir's public fork, `palkan/fizzy`, and commit? Default: yes, because it is public (#402 probe); publish aggregates only (R8). The maintainer decides. If declined, use "Fizzy" and the commit sha.
- Q2. Should skipped-invalid mutants on parse-clean sources warn at any count above the floor? The warning calls them bugs, but 10% hides 6 of 7,804. Default: no change here; U4 files an issue. The maintainer decides.
- Q3. Do the all-operator daemon run (full scope, all 21 operators)? Default: only if the daemon run takes under 45 minutes. Otherwise, use the derived row. The implementer decides from the daemon run's wall time.
- Q4. May KTD3 raise the limit above 25%? Default: no; stop and ask the maintainer.
- Q5. Publish CHANGELOG numbers if the limit stays unchanged? Default: yes, as requested by the issue and established in 1.8.0 (`CHANGELOG.md:109-118`). The maintainer decides.
- Q6. For #381 Q2, use one 10% limit or a separate unpaired limit? Default: one limit (KTD3, R9). This plan recommends; the maintainer decides on #381. Its plan agrees (`:478`, `:492`) and needs editing only if the maintainer chooses a separate limit.

## Sources

- Issue text: `issues/349.md`, `issues/381.md`, `issues/402.md` in the context folder.
- Probes: `probes/349/`: `static_unrun.rb` and `.out`, `static_detail.rb` and `.out`, `invalid_detail.rb` and `.out`, `dry_run_all_ops.sh` and `.out`, `pairing_of_targets.rb` and `.out`, `refute/branches_static.out`. Unpaired counts: `probes/381/count_unpaired.out`. Commit choice: `probes/402/p1_remotes.out`. Ruby pin leak: `probes/402/r1_rbenv_pin.out`.
- Code: `lib/mutineer/reporter.rb:21`, `:28-31`, `:116-145`, `:883-899`; `lib/mutineer/result.rb:203`, `:214-218`; `lib/mutineer/subject.rb:44-55`; `lib/mutineer/runner.rb:368-377`; `lib/mutineer/daemon_backend.rb:426-434`; `lib/mutineer/cli.rb:417-444`, `:508-510`, `:641-660`, `:898-943`; `lib/mutineer/daemon_client.rb:37`, `:177-182`, `:334-348`, `:368-378`; `lib/mutineer/daemon_server.rb:5-9`, `:93`; `bin/mutineer:4`; `lib/mutineer.rb:3-7`.
- Tests: `test/reporter_test.rb:544-582`.
- Docs: `docs/json-schema.md:60`, `:62`; `CHANGELOG.md:53`, `:102-118`; `AGENTS.md:325`.
- Validation reports, 2026-11-09: Sol A7, A9, A20; grok-cursor A7, A8; opus A7. These reports cover unpaired arithmetic and the private-link concern.
- Plan format: `docs/plans/2026-10-24-291-feat-excluded-mutant-counts-plan.md`.
- Sibling plans: `docs/plans/2026-11-10-381-feat-count-unpaired-sources-and-mutants-plan.md` (R10 `:66`, R13 `:72`, report text `:196`, #349 row `:478`, noise row `:479`, Q2 `:492`); `docs/plans/2026-11-10-402-chore-pre-release-fizzy-sample-check-plan.md` (KTD5, KTD6, clone and bootstrap); `docs/plans/2026-11-10-379-feat-pair-concern-with-namespace-test-plan.md` (`:134`, `:176`).
- Fizzy `f220e4832`: `.mutineer.yml`, `Gemfile` line 64, `Gemfile.lock:321`, `bin/mutineer`, `.ruby-version`, `lib/fizzy.rb:3-10`.

## Review notes

- The author ran one inline lite review for coherence, feasibility, and scope. The host lacked a subagent tool; the review was not independent.
- Applied: corrected the `static_unrun.rb` probe's swapped columns; stated U2's 3-mutant margin; replaced the `Gemfile` edit with KTD7. Fizzy's binstub would otherwise run locked version 1.8.0.
- Round 2, adversarial review and fit-validate-plan: added R9 and KTD3's unpaired recommendation and owner; added R10 and KTD7's environment pin. Added KTD8's conditional in-process runs and three warning fields. Removed numbers from the code comment. Added #391 to U1, the CHANGELOG fallback, `AGENTS.md` and search coverage, and risk rows for #379, #382, #375, #393.
- Open after review: Q1 to Q6.