---
title: Document how to triage a present? to receiver survivor - Plan
type: docs
date: 2026-11-10
issues: [399]
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Document how to triage a present? to receiver survivor - Plan

## Goal Capsule

- **Issue:** #399 (docs: how to triage a `present?` to receiver survivor, without a name-based skip).
- **Objective:** a user who sees a `x.present?` to `x` survivor can tell from the docs if it is a real test gap or an equivalent mutant. They can then write the killing test or suppress that one mutant with a reason.
- **Means:** a new subsection on the equivalent-skips page, in both twins, plus two small guard tests (KTD1, KTD3).
- **Authority:** this plan, then `AGENTS.md`, then the issue text. Where they differ, "Corrections to the issue" below wins.
- **Stop and ask when:** a change would touch `lib/`, or would add `present?` (or any name) to `CallToReceiver::SKIPPED`.
- **Size:** S. Two docs files and two test files. No code change. One pull request.
- **Ships:** in the next batch release. Labels `documentation` and `v1.9.0`. No semver bump of its own (docs only). The Pages site publishes on merge to `main` (`.github/workflows/pages.yml:3-5`), which is safe because the page describes behaviour that shipped in 1.7.

---

## Product Contract

### Summary

Add a subsection "Triage a `present?` survivor" under "Call to receiver" in `docs/equivalent-skips.md` and `docs/equivalent-skips.html`. It says when the mutant is equivalent, when it is a real gap, how to kill it, and how to suppress one site. It also says why `present?` is not on the skip list. Fix one sentence on the same page that overstates what a scoped disable marker keeps.

### Problem Frame

Vladimir Dementyev's Fizzy report (report line 37) calls `x.present?` to `x` the most common equivalent mutant he suppressed, and asks for a skip list for it. The mutant is equivalent only for some receivers. With ActiveSupport, `present?` and plain truthiness differ for `""`, `" "`, `[]` and `{}` (probe P1). The `call_to_receiver` operator skips by method name only (`lib/mutineer/mutators/call_to_receiver.rb:47`, `:128`), so a skip would also hide real gaps such as a blank `params[:day]`. Users need a triage rule, not a skip.

### Requirements

- R1. Both twin pages carry the same subsection "Triage a `present?` survivor", placed after the call-to-receiver table and before "Endless range".
- R2. The subsection says the mutant appears only when `--operators` (or `operators:`) selects `call_to_receiver`, which is not a default operator.
- R3. It names the equivalent case: the receiver is always a non-blank object (a record) or `nil`/`false`, and the call result is only used as a condition.
- R4. It names the real-gap cases: strings and params (`""`, `" "`), arrays, hashes, empty relations, and a method that returns the `present?` result as its value.
- R5. It gives the killing test for each gap: pass a blank value, or assert the exact `true` or `false`.
- R6. It shows both ways to suppress, each with a reason: an `ignore:` mapping with the survivor `id` (suppresses one mutant), and `# mutineer:disable-line call_to_receiver -- reason` (suppresses every `call_to_receiver` mutant on that line).
- R7. It says `present?` stays off the skip list, because the skip checks the name and cannot see the receiver.
- R8. The existing call-to-receiver paragraph no longer says a scoped marker "does not hide other mutants on the line". It says the marker keeps mutants of other operators and hides all `call_to_receiver` mutants on that line.
- R9. A test pins that `call_to_receiver` emits `x.present?` to `x`, so a future skip of `present?` fails a test.

### Acceptance Examples

- AE1. Covers R4, R5. Given `if params[:day].present?` with a test that passes only a valid date, the mutant survives. A test that passes `day: ""` and expects the fallback kills it (probe P2, P3).
- AE2. Covers R4, R5. Given `def has_tags?(tags) = tags.present?` with `assert has_tags?(["x"])`, the mutant survives. `assert_equal true, has_tags?(["x"])` kills it (probe P2, P3).
- AE3. Covers R6, R8. Given `account.name if account.present? # mutineer:disable-line call_to_receiver -- ...`, the marker also hides `account.name` to `account`. An `ignore:` mapping with the `present?` mutant id hides only that one (probe P3).

### Scope Boundaries

- No change to `lib/`. `present?` stays out of `CallToReceiver::SKIPPED`.
- No receiver-aware or type-aware skip rule. The issue says to file that separately if users ask again.
- No new content for other predicates (`blank?`, `any?`, `empty?`). They were not part of the report.
- `docs/results.md:41-45` already states the marker scope correctly. It needs no change.
- No CHANGELOG entry by default (see Open Questions).

#### Deferred to Follow-Up Work

- A receiver-aware rule for `present?`. It needs its own issue only if users ask again (issue "How" step 3). No issue is filed by this plan.

### Corrections to the issue

1. **Line reference.** The skip list is `SKIPPED` at `lib/mutineer/mutators/call_to_receiver.rb:47`. Lines 124-130 are the `replace` method. Line 128 is the `decline` call that uses the list.
2. **The operator is opt-in.** `call_to_receiver` is a Tier-2 operator and is off by default (`lib/mutineer/mutator_registry.rb:28-32`, `docs/equivalent-skips.md:6-8`). Probe P2: the default operators made 0 mutants on the probe file. With `--operators call_to_receiver` it made 3 `present?` mutants. The docs must say this (R2).
3. **The `params[:day]` finding came from another operator.** The report (line 272) found `if params[:day].present?` to `if (false)`, a `condition_false` mutant. The issue's point still holds for `call_to_receiver`: in Fizzy, `day` returns `Time.current` for `""` and the mutant returns `Time.zone.parse("")` (`fizzy-palkan/app/controllers/concerns/day_timelines_scoped.rb:15-20`). Probe P2 and P3 show the same shape survives a valid-date test and dies on a blank-string test. The Sol validation report (A12) agrees.
4. **"A disable comment on the line" is not one site.** The marker is parsed per line and per operator (`lib/mutineer/job_plan.rb:358-391`). Probe P3: the scoped marker also hid `account.name` to `account`, a killable mutant. Only an `ignore:` id hides one mutant (`lib/mutineer/config.rb:55`, `:407`, `:465`). The page today says the scoped marker "does not hide other mutants on the line" (`docs/equivalent-skips.md:61-64`, `docs/equivalent-skips.html:82`). That is true only for other operators. R8 fixes it.
5. **A guard already exists.** `test/mutators/call_to_receiver_test.rb:108` requires the `call_to_receiver` list to be a subset of the `chain_link` list. `test/site_docs_test.rb:90-96` requires both twins to list exactly `SKIPPED`. Adding `present?` would fail both. R9 adds a direct test of the mutant itself.
6. **Not checked:** Fizzy commit a8690df1d is not in the local clone (`git log` fails). The validation reports disagree on how many `present?` sites Fizzy has (Sol: 64 candidates, Opus: 83 sites). This plan uses neither number.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Put the text in a level-3 subsection inside "Call to receiver".** The mutant comes from that operator, so readers look there. Rejected: a new level-2 section, because the page lists built-in skips and `present?` is not one. The existing twin test scans from `<h2 id="call-to-receiver">` to the next `<h2` for table rows (`test/site_docs_test.rb:92-95`). So the subsection must have no table whose first cell is `<code>`. Use prose and a short list.
- KTD2. **Use the anchor `triage-a-present-survivor` in both twins.** GitHub makes that slug from the Markdown heading. The HTML `<h3>` gets the same `id`, so one fragment works on both.
- KTD3. **Recommend the `ignore:` id first, the marker second.** Probe P3 shows the marker hides every `call_to_receiver` mutant on the line. Fizzy already chose ids to keep tool comments out of app code (report line 412). Rejected: marker first, because it can hide a killable sibling.
- KTD4. **Keep the HTML twin hand-written.** No generator turns this `.md` into `.html`. `MutineerSiteDocs.stale_files` (`rake/site_docs.rb:156-161`) checks only `llms.txt` and the contract files. `equivalent-skips.md` is not in `llms-full.txt` (`rake/docs_contract.rb:98`). Rejected: a new md-to-html check, as scope creep.

### Assumptions

- The killing-test advice uses ActiveSupport semantics, which probe P1 confirmed on Ruby 3.4.9. The "empty relation" case comes from the validation reports and ActiveSupport docs. It was not probed here, because the probe has no Active Record.

### Probe results

Scripts and output are machine-local, in the planning context folder under `probes/399/` (`README.md` lists every file). A missing folder does not block the work.

- P1. `truthiness.rb`: `present?` and truthiness agree for `nil`, `false`, `0`, `"x"` and an object. They differ for `""`, `" "`, `[]` and `{}`.
- P2. Dry run and weak-test run on `lib/day.rb`: default operators made 0 mutants. `--operators call_to_receiver` made 4 mutants, 0 declined. Weak tests left 3 survivors, all `present?` to receiver.
- P3. Strong tests plus suppression: the blank-string test and the exact-`true` test killed their mutants. The scoped marker gave `ignored: 2` (it also hid `account.name` to `account`). The `ignore:` id gave `ignored: 1`. Both runs scored 100%.
- P4. `mutations_for` on the bodies `x.present?` and `params[:day].present?` returns `["x"]` and `["params[:day]"]`. The U2 mutator assertions hold on `main` today.

---

## Implementation Units

### U1. Add the subsection to both twins and fix the marker sentence

- **Goal:** the page answers "is this `present?` survivor real?" and "how do I suppress one?".
- **Requirements:** R1 to R8.
- **Dependencies:** none.
- **Files:** `docs/equivalent-skips.md`, `docs/equivalent-skips.html`.
- **Approach:**
  1. In both files, change the sentence at `docs/equivalent-skips.md:61-64` and its twin at `docs/equivalent-skips.html:82` per R8.
  2. After the call-to-receiver table, add the subsection per KTD1 and KTD2. Order: opt-in note (R2), equivalent case (R3), gap cases with the killing test (R4, R5), suppression with `ignore:` first (R6, KTD3), why no skip (R7).
  3. Use one Ruby example of a gap (`if params[:day].present?`) and one YAML `ignore:` mapping. Reuse the YAML shape from `docs/results.md:59-65`.
  4. Give the HTML twin the same facts and both examples. The twins are not word-for-word equal today: the HTML drops the "Endless range" code blocks and rewords the intro (`docs/equivalent-skips.html:53`, `:93-98`). This page has no `<pre>` or `<h3>` yet, so copy `<pre><code>` from `docs/rails.html:76` and the plain `<h3>` from `docs/index.html:116`, adding the `id` per KTD2.
  5. In the Markdown, keep every line inside a fenced code block from starting with `## `. The twin test cuts the section at the first line that starts with `## ` (`test/site_docs_test.rb:94`).
- **Patterns to follow:** the "Endless range" section (`docs/equivalent-skips.md:94-100`) explains when a mutant is equivalent and when it is not. Write in ASD-STE100, no em dash.
- **Test scenarios:** U2 holds the tests for this unit.
- **Verification:** both twins render the subsection under "Call to receiver", and the existing twin tests still pass.

### U2. Guard tests

- **Goal:** the twins cannot drift on this subsection, and a future `present?` skip fails a test.
- **Requirements:** R1, R9.
- **Dependencies:** U1.
- **Files:** `test/site_docs_test.rb`, `test/mutators/call_to_receiver_test.rb`.
- **Approach:** add one test to each file, next to the existing equivalent-skips and skipped-names tests.
- **Patterns to follow:** `test_equivalent_skips_page_names_every_range_slice_call` (`test/site_docs_test.rb:99-106`) and the `mutated` helper (`test/mutators/call_to_receiver_test.rb:18-25`).
- **Test scenarios:**
  - `test/site_docs_test.rb`: the HTML contains `<h3 id="triage-a-present-survivor">` between `<h2 id="call-to-receiver">` and `<h2 id="endless-range">`. The Markdown contains the heading line ``### Triage a `present?` survivor`` inside its "## Call to receiver" section. GitHub derives the Markdown anchor, so the test checks the heading text there. Each subsection contains `ignore:` and `mutineer:disable-line call_to_receiver`. This catches a twin that lost or moved the subsection. It does not catch a wording drift between the twins.
  - `test/mutators/call_to_receiver_test.rb`: `mutated("x.present?")` equals `["x"]`, and `mutated("params[:day].present?")` equals `["params[:day]"]`. Covers AE1 at the operator level. This catches a name skip. It does not prove the mutant is killable, which probe P3 showed.
- **Verification:** both new tests pass, and they fail when `present?` is added to `SKIPPED` or the subsection is removed from one twin.

---

## Verification Contract

Run from the worktree root:

```sh
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bundle exec ruby -Ilib -Itest test/site_docs_test.rb
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bundle exec ruby -Ilib -Itest test/mutators/call_to_receiver_test.rb
bundle exec rake test
ruby -Ilib -e 'require "mutineer"'
bundle exec rake yard:strict
bundle exec rake site:build
node --test test/site_test.js
npm ci --prefix test/browser
npx --prefix test/browser playwright install chromium
npm test --prefix test/browser
```

The site checks are required because the change touches the Pages site (`AGENTS.md`, "Website checks").

Siblings rule (`.expectation-fit/ways-of-working.yaml`): reload and redefine, daemon and in-process do not apply, because no code path changes. Action and CLI: the Action runs the CLI, which reads the same `ignore:` and markers, so the docs hold for both. Report and dry run: both already show the ignored count (probe P2 dry-run line), so nothing changes there.

## Definition of Done

- R1 to R9 hold, and AE1 to AE3 match the text on the page.
- Both twins carry the same facts and examples in the subsection.
- Every command in the Verification Contract passes.
- `present?` is not in `CallToReceiver::SKIPPED`, and `lib/` is unchanged.
- The pull request has labels `documentation` and `v1.9.0`, and its body says `Closes #399`.
- No leftover probe files in the repo.

---

## Risks and Overlaps

- #244 (the 2.0 contract flip) and #245 (the parallel Rails default) touch `test/site_docs_test.rb`. #245 also adds an older copy of `docs/equivalent-skips.*` and `rake/site_docs.rb`, dated 2026-10-09, before the page on `main`. Those 2.0 branches conflict with `main` already. This plan adds one more small hunk to resolve when they rebase.
- #274 (the `call_to_receiver` skip list for scalar conversions) set today's list. This plan keeps that list as it is.
- No sibling plan in this batch edits these four files. #386 (default mutants for a bare `if` or `rescue` body) touches the same Fizzy method, `DayTimelinesScoped#day`, but only operator code.
- Wording risk: the page could imply the marker is safe. KTD3 and R8 address it.

## Open Questions

- Add a CHANGELOG entry? Default: no. The change is docs only and changes no behaviour. The maintainer decides at review.
- File the receiver-aware rule issue now? Default: no, per the issue. The maintainer decides if users ask again.
