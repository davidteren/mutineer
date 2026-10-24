---
title: "Give call_to_receiver its own skip list - Plan"
type: feat
date: 2026-10-24
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
origin: GitHub issue #274 (davidteren/mutineer) and its Claude analysis comment
---

# Give call_to_receiver its own skip list - Plan

## Goal Capsule

- Issue: #274.
- Goal: the `call_to_receiver` operator replaces a last call to a scalar conversion (`to_s`, `to_i`, `to_f`, `to_sym`, `to_a`, `to_h` and the other conversions) with its receiver. It still skips `new`, `dup`, `clone`, `freeze`, `itself` and `to_set`. The `chain_link` operator does not change.
- Authority: this plan, then `AGENTS.md`, then the issue comment. Where the plan and the issue comment disagree, the plan wins (see "Corrections to the issue comment").
- Stop conditions: stop and ask if the change needs a new runtime gem, `eval`, a change to `ChainLink::SKIPPED`, or a change to an operator other than `call_to_receiver`. None of these is expected.
- Size: S. One new constant, one changed line, one removed `require`, comment edits in two mutator files, one new short section on two twin docs pages, one CHANGELOG entry, two new tests, three changed tests, and one measurement run before merge.

---

## Product Contract

### Summary

`CallToReceiver` uses the `chain_link` skip list (`ChainLink::SKIPPED`). That list exists because a conversion in the middle of a chain is most often a no-op. On the last call, the conversion decides the type of the value that the expression returns. So `m[1].to_i` to `m[1]` changes what a test can see, and the operator must make that mutant. The fix gives `CallToReceiver` its own short skip list.

### Problem Frame

- `lib/mutineer/mutators/call_to_receiver.rb` line 115, in the private method `CallToReceiver#replace`: `return if ChainLink::SKIPPED.include?(node.name)`.
- `lib/mutineer/mutators/chain_link.rb` lines 29 to 33, `ChainLink::SKIPPED`: 14 conversions (`to_s to_str to_sym to_i to_int to_f to_r to_c to_a to_ary to_h to_hash to_proc to_set`), the copies `dup clone freeze itself`, and `new`.
- The docs say both operators skip the same names: the `CallToReceiver` class comment (lines 26 to 28), the `replace` comment (lines 106 and 107), the `ChainLink::SKIPPED` comment (lines 27 and 28 in `chain_link.rb`), `docs/equivalent-skips.md` (lines 19 to 24) and its twin `docs/equivalent-skips.html` (line 57).
- Measured on `main` (`18ef483`) with `mutineer run --dry-run --operators call_to_receiver lib`: 3,103 mutants today, 3,216 with the new list (113 more, +3.6%). The new mutants by name: `to_s` 86, `to_i` 14, `to_a` 4, `to_h` 4, `to_sym` 3, `to_f` 2. Mutineer's own `lib/` has no last call to `to_str`, `to_int`, `to_ary`, `to_hash`, `to_proc`, `to_r` or `to_c`.

### Requirements

- R1. `CallToReceiver` skips a last call only when its name is one of `new dup clone freeze itself to_set`. Every other word-named dotted last call gets a mutant, as today.
- R2. The names that R1 no longer skips are the 13 conversions `to_s to_str to_sym to_i to_int to_f to_r to_c to_a to_ary to_h to_hash to_proc`. Each one now gives one mutant on the last call. For example, `x.to_s` gives `x`, `m[1].to_i` gives `m[1]`, and `a.b.to_s` gives `a.b`.
- R3. A conversion that is a link (not the last call) still gives no `call_to_receiver` mutant. `x.to_s.strip` still gives only `x.to_s`.
- R4. `ChainLink::SKIPPED` and the `chain_link` operator do not change.
- R5. The operator skips operator calls, setters and calls with no dot, as today.
- R6. The class comment, the `replace` comment, the `ChainLink::SKIPPED` comment, both equivalent-skips pages and the CHANGELOG say which names each operator skips.

### Acceptance Examples

- AE1. `def m; x.to_s; end` with `--operators call_to_receiver` gives one mutant, `x`. Before the fix it gives none.
- AE2. `def m; Foo.new; end`, `x.dup`, `x.clone`, `x.freeze`, `x.itself` and `x.to_set` give no `call_to_receiver` mutant.
- AE3. `def m; value.to_s.strip.downcase; end` with `--operators chain_link` gives only `value.to_s.downcase`. It never drops the `to_s` link. The `chain_link` result is the same before and after the fix.

### User-visible change

- A run that names `call_to_receiver` gets more mutants. It can get new survivors, new mutant ids and a different score. The default operator set does not include `call_to_receiver`, so a default run does not change.
- No change to exit codes, CLI flags, config keys or JSON fields.
- CHANGELOG, under `## [Unreleased]` and the existing `### Changed` heading, add one entry with a bold lead, as the 1.7.0 entries have. Suggested text:
  "**`call_to_receiver` replaces a last conversion call.** `m[1].to_i` now gives the mutant `m[1]`. Before, the operator skipped the same names as `chain_link`. Now it skips only `new`, `dup`, `clone`, `freeze`, `itself` and `to_set`. `chain_link` does not change. A run that names `call_to_receiver` gets more mutants (113 more on Mutineer's own `lib/`). If you gate on it with `--threshold` or a baseline, expect new survivors and refresh the baseline. A `to_s` mutant on a value that is already a String is equivalent: suppress it with `# mutineer:disable-line` or an `ignore:` entry. (#274)"
- The released 1.7.0 CHANGELOG entry ("It skips the same names as `chain_link`") stays as it is. It was true for 1.7.0. The new entry says what changed.
- Commit type: `feat:`. AGENTS.md says a new feature is a minor bump, and the weekly release PR picks up `feat:` commits.

### Scope Boundaries

- No change to `chain_link` or `ChainLink::SKIPPED`.
- No receiver-type or context check (for example, "skip `to_s` inside string interpolation"). Skips stay name-only. The issue asks only for a new list, and a context check is a new kind of skip for this operator. See "Deferred to Follow-Up Work".
- No new config knob to choose the skip list.

### Deferred to Follow-Up Work

- Measure on a real Rails app how many of the new conversion mutants a good suite kills and how many are equivalent. The issue asks for this check. U1 measures only Mutineer's own `lib/` before merge. If a Rails app shows that most `to_s` mutants are equivalent, add `to_s` to the list in a later change, record the measured rate, and say in that CHANGELOG entry that users who gate on `call_to_receiver` must refresh their baseline again.
- Cross-operator duplicates are #275. This change adds no new duplicate with `chain_link` (the extended `test_never_gives_the_same_source_as_chain_link` in U1 proves this), so it does not depend on #275.
- A context skip for `to_s` inside string interpolation (`"#{a.to_s}"` to `"#{a}"` is always equivalent). It needs a parent check on the Prism node. File an issue if the measurement in U1 shows many such mutants.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Add a new constant `CallToReceiver::SKIPPED = %i[new dup clone freeze itself to_set].freeze` and use it at line 115. Rationale: the issue comment recommends this list, and a constant on the class is the pattern `ChainLink` already uses. A subtraction from `ChainLink::SKIPPED` would tie the two lists together again, which is the root cause.
- KTD2. The rule for the list: skip a name when its last-call mutant is most often equivalent, or when every test that runs the line kills it. Both kinds say nothing about the tests. `dup`, `clone`, `freeze`, `itself` and `to_set` are the first kind. `new` is the second kind. Keep `to_set` for this reason: an Array answers `include?`, `each`, `size` and `empty?` the same way as a Set, and Mutineer's own `to_set` last calls feed `include?` lookups (`lib/mutineer/job_plan.rb` line 58, `lib/mutineer/project.rb` line 98). So the mutant is most often equivalent, only slower. The other conversions differ: a String in place of an Integer, or nil in place of `""`, changes the value a test can check. The issue's first count had 15 `to_set` mutants.
- KTD3. Do not add the implicit conversions (`to_str to_int to_ary to_hash to_proc`) or `to_r`/`to_c` to the list. Rationale: the issue comment keeps them "out of scope". Some of them may meet the KTD2 rule (an object that defines `to_str` is often used where Ruby converts it anyway), but `lib/` has none on a last call, so there is no case to measure. With the proposed list they get mutants, which matches R1. See Open Questions.
- KTD4. Remove `require_relative "chain_link"` at `call_to_receiver.rb` line 4. After KTD1, no Ruby code in the file refers to `ChainLink`. The remaining `{ChainLink}` references are YARD links in comments, which need no `require`. `lib/mutineer/mutator_registry.rb` lines 18 and 19 and `lib/mutineer.rb` line 32 still load both files. `chain_link.rb` requires only `base` in the same way.
- KTD5. The equivalent-skips pages get a new short section, `## Call to receiver`, after the `chain_link` table, with its own six-row table. The `## Chain link` section then speaks only of `chain_link`. Rationale: the table reasons for `dup`, `clone` and `freeze` describe a middle link ("when the next call does not mutate the receiver"). On the last call there is no next call, so one shared table with a sentence beside it would give `call_to_receiver` users the wrong reasons. A "Skipped by" column was the other choice. It needs a cell in all 19 rows of both twin files, and it still leaves the reasons wrong for the last call.

### Corrections to the issue comment

- The comment lists the docstring at lines 26 to 28 but not two more comments that state the shared list: the `replace` comment at `call_to_receiver.rb` lines 106 and 107 ("or in {ChainLink::SKIPPED}") and the `ChainLink::SKIPPED` comment at `chain_link.rb` lines 27 and 28 ("{CallToReceiver} uses the same list for the last call"). Both must change.
- The comment names only `docs/equivalent-skips.md`. The committed twin `docs/equivalent-skips.html` (line 57) has the same text and must change too.
- The comment reads Symbol receivers (`node.name.to_s`) as killable. Some are equivalent: a Symbol also answers `match?`, `start_with?` and `end_with?`, so `name = node.name.to_s` followed by `name.match?(WORD_NAME)` (`call_to_receiver.rb` lines 112 and 113) gives an equivalent mutant. The U1 measurement gate exists for this reason.
- The count of 113 is correct. A re-run on `18ef483` gave 3,103 before and 3,216 after.

### Sequencing

U1 (code and its unit tests) first. U2 (docs, docs test and CHANGELOG) next. Both can land in one commit or two. One pull request.

---

## Implementation Units

### U1. Own skip list in CallToReceiver

**Goal:** `CallToReceiver` uses its own six-name skip list.

**Requirements:** R1, R2, R3, R4, R5, R6 (code comments).

**Dependencies:** none.

**Files:**
- `lib/mutineer/mutators/call_to_receiver.rb`
- `lib/mutineer/mutators/chain_link.rb` (comment only, lines 27 and 28)
- `test/mutators/call_to_receiver_test.rb`

**Approach:**
- Add `SKIPPED` after `WORD_NAME` (line 34), with a `#` comment for `yard:strict`. The comment says what the list holds and why. It states the KTD2 rule. `new` gives a mutant that any test that runs the line kills (the class in place of an instance). `dup`, `clone`, `freeze` and `itself` return the receiver or an equal copy, and an Array answers `include?` and `each` as a Set does, so those mutants are most often equivalent.
- Line 115: use `SKIPPED` instead of `ChainLink::SKIPPED`.
- Lines 26 to 28 (class comment): say that calls in {SKIPPED} are never replaced, and that a conversion such as `to_s` is replaced because on the last call it decides the type of the returned value. Keep the `Foo.new` sentence.
- Lines 106 and 107 (`replace` comment): `{ChainLink::SKIPPED}` becomes `{SKIPPED}`.
- Line 4: remove `require_relative "chain_link"` (KTD4).
- `chain_link.rb` lines 27 and 28: replace "{CallToReceiver} uses the same list for the last call." with "{CallToReceiver} has its own shorter list for the last call." Do not change the list.

**Patterns to follow:** `ChainLink::SKIPPED` (constant with a comment, `%i[...].freeze`).

**Test scenarios** (all in `test/mutators/call_to_receiver_test.rb`):
- Change `test_skipped_names_yield_none` (lines 97 to 102). Today its list is `x.to_s x.dup Foo.new x.freeze x.itself x.to_a`. Remove `x.to_s` and `x.to_a`, and add `x.clone` and `x.to_set`. The test then asserts that `x.dup`, `x.clone`, `Foo.new`, `x.freeze`, `x.itself` and `x.to_set` give no mutant, and that `x.to_s.strip` still gives `["x.to_s"]`. Covers AE2 and R3. It passes before and after the fix.
- New `test_conversions_on_the_last_call_are_replaced`. For each of the 13 names of R2, `x.<name>` gives `["x"]`. Also `m[1].to_i` gives `["m[1]"]` and `a.b.to_s` gives `["a.b"]`. Covers AE1 and R2. It fails before the fix, because today each of these gives no mutant.
- In the same test, `'"#{a.to_s}"'` gives `['"#{a}"']`. Add a one-line comment: this mutant is a known equivalent (interpolation calls `to_s` anyway), and the assertion pins that skips stay name-only. It is not a goal.
- R4 needs no new test: `test/mutators/chain_link_test.rb` `test_skipped_links_are_kept` (line 66) already pins the `chain_link` skips. The U2 docs test pins the exact `CallToReceiver::SKIPPED` set.
- Extend `test_never_gives_the_same_source_as_chain_link` (lines 124 to 132): add `"a.b.to_s"` and `"a.to_s.to_i"` to its list. Proves the new mutants do not repeat a `chain_link` mutant. It passes before the fix (no mutant), and it must still pass after.

**Verification:** the new and changed tests pass. `chain_link_test.rb` and `test/integration_test.rb` `test_call_to_receiver_survivor` (line 91, fixture `test/fixtures/slug.rb` has no conversion) pass unchanged. `yard:strict` reports 100%.

**Execution note (measurement gate for `to_s`):** `to_s` gives 86 of the 113 new mutants, and the only evidence for allowing it is the issue comment's sample of 25. After U1 passes its tests, run a real (not dry) `call_to_receiver` run on `lib/mutineer/reporter.rb` (23 new `to_s` mutants), `lib/mutineer/project.rb` (6) and `lib/mutineer/config.rb` (5) with `--test` pointing at their test files (for example `test/reporter_test.rb`, `test/project_test.rb`, `test/config_test.rb`) and `--format json`. Do not use `lib/mutineer/rails_worker_db.rb` (36), because its tests need Rails. Sort each new `to_s` mutant as killed, survived as a real test gap, or survived as equivalent (for example `node.name.to_s` where the next call is one that a Symbol also answers, or a value that `join` converts anyway). Put the three counts in the pull request description. If the equivalents are more than half of these `to_s` mutants, add `to_s` to `CallToReceiver::SKIPPED` (the Open Questions alternative), and change the docs, the CHANGELOG entry and the U1 tests to match. Otherwise keep the default.

### U2. Docs, docs test and CHANGELOG

**Goal:** the user docs and the CHANGELOG state the new skip lists.

**Requirements:** R6.

**Dependencies:** U1 (the docs test reads `CallToReceiver::SKIPPED`).

**Files:**
- `docs/equivalent-skips.md` (section `## Chain link`, lines 17 to 46)
- `docs/equivalent-skips.html` (section `<h2 id="chain-link">`, lines 56 to 79)
- `test/site_docs_test.rb` (lines 80 to 86, and a new test after them)
- `CHANGELOG.md` (`## [Unreleased]`, `### Changed`)

**Approach:**
- `## Chain link` section: it speaks only of `chain_link`. Remove "The `call_to_receiver` operator removes the last call.", change "Both skip the names below" to "It skips the names below", and remove "Removing a final `new` leaves the class in place of an instance." Keep its table as it is.
- New `## Call to receiver` section between the `chain_link` table and `## Endless range` (HTML id `call-to-receiver`). Content, in short sentences:
  - The `call_to_receiver` operator replaces the last call of a chain with its receiver. It skips only the names below, by name only.
  - It replaces the other conversions, such as `to_s` and `to_i`. On the last call, a conversion decides the type of the value that the expression returns, so a test can check it.
  - Some of those mutants are equivalent, for example `to_s` on a value that is already a String, or inside string interpolation. Suppress them as the top of the page says.
  - A table with six rows in the `KTD1` order, with last-call reasons: `new` (the class takes the place of an instance, so almost any use raises), `dup` and `clone` (the copy is equal to the receiver), `freeze` (returns the receiver; only a later write shows the difference), `itself` (returns the receiver), `to_set` (an Array answers `include?`, `each` and `size` as a Set does, so the mutant is most often equivalent).
- Keep the two files in step: the same words, with `<code>`, `<table>` and `<tr><td>` markup in the HTML as in the `chain_link` table.
- CHANGELOG: add the entry from "User-visible change" under the existing `### Changed` heading in `## [Unreleased]`.

**Test scenarios** (in `test/site_docs_test.rb`):
- New `test_equivalent_skips_page_lists_exactly_the_call_to_receiver_skips`. For `docs/equivalent-skips.html`, take the text from `<h2 id="call-to-receiver">` to the next `<h2`, collect the names in `<tr><td><code>NAME</code>`, and assert that the sorted names equal `Mutineer::Mutators::CallToReceiver::SKIPPED.map(&:to_s).sort`. Do the same for `docs/equivalent-skips.md`: the text from `## Call to receiver` to the next `## `, with names from table rows that start with `` | `NAME` ``. The equality fails when a name is added to the list, removed from it, or left off a page. It fails before the fix, because the section does not exist and the constant does not exist.
- Narrow `test_equivalent_skips_page_names_every_chain_link_skip` (lines 80 to 86) to the text from `<h2 id="chain-link">` to the next `<h2`. Today it searches the whole page for `>NAME<`. After U2, `new` or `dup` also appears in the new table, so a name removed from the `chain_link` table would still pass. Keep its `endless` assertion on the whole page. It passes before and after the fix (R4).

**Verification:** both pages read the same. The site tests pass.

---

## Verification Contract

Prefix every ruby, rake and bundle command with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` when the shell has no locale.

Local gate from `AGENTS.md` ("Before every commit"):

```sh
bundle exec rake test
ruby -Ilib -e 'require "mutineer"'
bundle exec rake yard:strict
```

The change touches `docs/`, so also run the website checks from `AGENTS.md`:

```sh
bundle exec rake site:build
node --test test/site_test.js
npm ci --prefix test/browser
npx --prefix test/browser playwright install chromium
npm test --prefix test/browser
```

Count check (optional, confirms the size of the change):

```sh
ruby -Ilib bin/mutineer run --dry-run --operators call_to_receiver lib | tail -1
```

Expect 3,216 on a tree equal to `18ef483` plus this change. Later merges to `lib/` can move the number.

AGENTS.md rules that apply: zero runtime dependencies (none added), no `eval` (none added), 100% YARD docs including the new constant, CHANGELOG entry under `## [Unreleased]`. The Minitest 6 run is not needed: the change does not touch the Minitest integration.

## Definition of Done

- `CallToReceiver::SKIPPED` exists with a comment, and line 115 uses it.
- `ChainLink::SKIPPED` is byte-for-byte the same as on `main`.
- `require_relative "chain_link"` is gone from `call_to_receiver.rb`, and the load smoke passes.
- The four comments state the two lists. Both equivalent-skips pages have the `## Call to receiver` section, and the `## Chain link` section speaks only of `chain_link`.
- The CHANGELOG entry is under `## [Unreleased]`.
- The two new tests fail on `main` and pass with the change. The changed tests pass.
- The pull request description has the `to_s` counts from the U1 measurement gate, and the skip list matches its decision rule.
- The local gate and the website checks pass.

---

## Risks and Overlaps

- CHANGELOG conflicts. Open PRs #304, #305, #306, #307, #308, #244 and #245 all add lines under `## [Unreleased]`. Expect a text conflict there. Resolve it by keeping every entry.
- `docs/equivalent-skips.*`: #302 (merged) last changed both pages, and this plan starts from that state. No open PR in the list (#304 to #308, #202, #244, #245, #301) touches these pages. #299 (endless range, an open issue with no PR) may later change the "Endless range" section of the same pages. That is a different section, so a conflict is unlikely.
- This plan file. `rake site:build` copies `docs/` to `_site/` and leaves out only `UNPUBLISHED = %w[release-review]` (`rake/site_build.rb` line 30). So a `docs/plans/` file that reaches `main` is published on the website. Do not include this plan file in the implementation pull request, unless a separate change has added `plans` to `UNPUBLISHED` first.
- `lib/mutineer/mutators/`: no open PR in the list touches `call_to_receiver.rb` or `chain_link.rb`.
- #275 (cross-operator duplicates) and #291 (count the silently excluded mutants) are related open issues. This change makes fewer mutants silently excluded, and it adds no duplicate with `chain_link`. It does not block either issue.
- Score change for users. A user who runs `--operators call_to_receiver` with `--threshold` or a baseline can see new survivors after upgrade. The CHANGELOG entry says so. The default operator set does not change, so the GitHub Action defaults do not change, and this is not a major bump.
- Equivalent mutants. Some new `to_s` mutants are equivalent (the receiver is already a String, or the call is inside interpolation). The issue comment's sample of 25 suggests most are killable, but there is no measured kill rate. Users can suppress an equivalent mutant with `# mutineer:disable-line` or an `ignore:` entry.

## Open Questions

- Deferred, not blocking: should the implicit conversions `to_str`, `to_int`, `to_ary`, `to_hash` and `to_proc` stay skipped on the last call? Default (from the issue comment): no, they get mutants. Alternative: add them to `CallToReceiver::SKIPPED`, because an object that defines `to_str` is often used where Ruby converts it anyway, so the mutant can be equivalent. `lib/` has no such last call, so the choice changes no count today.
- Deferred, not blocking: is `to_s` mostly useful or mostly equivalent on a real app? Default: allow it. Alternative: keep `to_s` skipped and allow the other 12 conversions of R2. The U1 measurement decides this before merge. The Rails-app measurement in "Deferred to Follow-Up Work" can revisit it.
