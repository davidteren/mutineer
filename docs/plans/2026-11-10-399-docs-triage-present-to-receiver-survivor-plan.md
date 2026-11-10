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

- **What:** Help users classify `x.present?` to `x` survivors, then add a killing test or suppress one mutant with a reason.
- **Why:** Make triage faster and safer without a method-name skip that hides real test gaps.
- **How:** Add matching subsections, a suppression-guide link, and guard tests: U2 (tests), R1 (matching subsections), R9 (mutation guard).

| Item | Contract |
|---|---|
| Issue | #399: document `present?` to receiver triage without a name-based skip. |
| Authority | This plan, then `AGENTS.md`, then #399, the docs issue. “Corrections to the issue” below overrides differences. |
| Stop and ask | Ask the maintainer before changing `lib/` or adding `present?`, or any name, to `CallToReceiver::SKIPPED`. |
| Size | S (small): three docs files, three test files, no code change, one pull request. |
| Ships | Next batch release, with `documentation` and target-release label `v1.9.0`. No separate semver bump. Pages publishes on merge to `main` (`.github/workflows/pages.yml:3-5`). This is safe because the documented behaviour shipped in 1.7. |

---

## Product Contract

### Summary

Add “Triage a `present?` survivor” under “Call to receiver” in `docs/equivalent-skips.md` and `docs/equivalent-skips.html`. Explain equivalence, real gaps, killing tests, single-mutant suppression, and why `present?` stays off the skip list. Correct the scoped-marker claim. Link from the suppression guide in `docs/results.md`.

### Problem Frame

Vladimir's Fizzy report calls `x.present?` to `x` the most common equivalent mutant he suppressed (report line 37). He asks for a skip list.

Equivalence depends on the receiver. ActiveSupport's `present?` differs from truthiness for `""`, `" "`, `[]` and `{}` (P1, truthiness probe). The operator checks only method names (`lib/mutineer/mutators/call_to_receiver.rb:47`, `:128`). A name-based skip would hide real gaps, such as blank `params[:day]`.

The report asks for less triage noise (report line 37). Fizzy suppresses equivalent mutants by id (report line 412). Each equivalent `present?` site will still need one `ignore:` entry. Faster, safer decisions, without fewer decisions, are the accepted cost of R7 (keep `present?` off the skip list).

### Requirements

| ID | Requirement |
|---|---|
| R1 | Both twins contain “Triage a `present?` survivor” after the call-to-receiver table and before “Endless range”. |
| R2 | State that `call_to_receiver` is not a default operator, so the mutant appears only when the operator list selects it. Name all three selectors: CLI `--operators`, `.mutineer.yml` key `operators:`, and Action input `operators`. Cite `action.yml:51-52`, passed as `--operators` at `action.yml:386`. |
| R3 | Define equivalence: the receiver is always a non-blank object, such as a record, or `nil`/`false`. The result is used only as a condition. |
| R4 | List real gaps: strings and params (`""`, `" "`), arrays, hashes, empty relations, and methods returning the `present?` result. |
| R5 | Give each gap's killing test: pass a blank value, or assert exact `true` or `false`. |
| R6 | Show both suppression forms with reasons. An `ignore:` mapping with the survivor `id` suppresses one mutant. `# mutineer:disable-line call_to_receiver -- reason` suppresses every `call_to_receiver` mutant on that line. `mutineer triage REPORT.json --id ID --reason TEXT` prints one survivor's mapping. Repeat `--id` for each site judged equivalent. Do not use `--all`: it also maps and hides real gaps. An `ignore:` id changes after a file move or method or class rename; the survivor returns. Link to “Mutant ids” in `docs/results.md`. A disable marker moves with its line. |
| R7 | Record the final decision: `present?` stays off the skip list because name checks cannot inspect receivers. Promise no future rule. #399, this docs issue, records the decision. |
| R8 | Replace “does not hide other mutants on the line”. State that scoped markers preserve other operators' mutants but hide every `call_to_receiver` mutant on that line. |
| R9 | Test that `call_to_receiver` emits `x.present?` to `x`, so a future `present?` skip fails. |
| R10 | Link to the subsection from “Suppressing equivalent mutants” in `docs/results.md`. |

### Acceptance Examples

| ID | Requirements | Example |
|---|---|---|
| AE1 | R4, R5 | `if params[:day].present?` survives a valid-date-only test. Passing `day: ""` and expecting the fallback kills it. See P2 (weak-test probe) and P3 (strong-test and suppression probe). |
| AE2 | R4, R5 | `def has_tags?(tags) = tags.present?` survives `assert has_tags?(["x"])`. `assert_equal true, has_tags?(["x"])` kills it (probe P2, P3). |
| AE3 | R6, R8 | `account.name if account.present? # mutineer:disable-line call_to_receiver -- ...` also suppresses `account.name` to `account`. An `ignore:` mapping with the `present?` mutant id suppresses only that mutant (probe P3). A file move or method rename changes the id; the survivor returns (`docs/results.md:88-97`, `lib/mutineer/mutant_id.rb:10-16`). |

### Scope Boundaries

- Keep `lib/` unchanged and `present?` out of `CallToReceiver::SKIPPED`.
- Add no receiver-aware or type-aware skip. R7 records rejection, not deferral.
- Add no content for `blank?`, `any?` or `empty?`; the report did not cover them.
- Leave `docs/results.md:41-45` unchanged; its marker scope is correct. Add only one sentence after `docs/results.md:74` (R10).
- Do not copy default operator names. #386, default mutants for bare `if` or `rescue` bodies, may change them; see Risks.
- Add no CHANGELOG entry by default; see Open Questions.

#### Deferred to Follow-Up Work

None. R7 rejects a receiver-aware rule. If a maintainer later wants one, they file a new issue, which the page then cites.

### Corrections to the issue

1. **Skip-list location.** `SKIPPED` is at `lib/mutineer/mutators/call_to_receiver.rb:47`. Lines 124-130 contain `replace`; line 128 calls `decline` with the list.
2. **Opt-in operator.** `call_to_receiver` is Tier-2 (opt-in), disabled by default (`lib/mutineer/mutator_registry.rb:28-32`, `docs/equivalent-skips.md:6-8`). Probe P2 produced 0 default mutants and 3 `present?` mutants with `--operators call_to_receiver`. State this (R2).
3. **Different reported operator.** Report line 272 changes `if params[:day].present?` to `if (false)` through `condition_false`. The concern also applies to `call_to_receiver`. Fizzy's `day` returns `Time.current` for `""`; the mutant returns `Time.zone.parse("")` (`fizzy-palkan/app/controllers/concerns/day_timelines_scoped.rb:15-20`). Probes P2 and P3 confirm survival with a valid date and death with a blank string. The Sol validation report agrees (A12, validation finding).
4. **Markers cover a line, not one site.** Parsing is per line and operator (`lib/mutineer/job_plan.rb:358-391`). Probe P3's marker also suppressed the killable `account.name` to `account` mutant. Only an `ignore:` id targets one mutant (`lib/mutineer/config.rb:55`, `:407`, `:465`). The current claim, “does not hide other mutants on the line”, applies only to other operators. R8 corrects it (`docs/equivalent-skips.md:61-64`, `docs/equivalent-skips.html:82`).
5. **Existing guard gap.** `test/mutators/call_to_receiver_test.rb:108` requires `call_to_receiver` skips to be a subset of `chain_link` skips. `test/site_docs_test.rb:90-96` requires both twins to list exactly `SKIPPED`. Adding `present?` only to `CallToReceiver::SKIPPED` fails both guards. Adding it to both lists and twin tables passes. R9 closes this gap.
6. **Unverified Fizzy data.** Commit `a8690df1d` is absent locally; `git log` fails. Validation counts differ: Sol reports 64 candidates; Opus reports 83 sites. This plan uses neither count.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Use a level-3 subsection within “Call to receiver”.** Readers look under the operator that creates the mutant. Reject a level-2 section: the page lists built-in skips, and `present?` is not one. The twin test reads table rows between `<h2 id="call-to-receiver">` and the next `<h2` (`test/site_docs_test.rb:92-95`). Use prose and a short list, with no table whose first cell is `<code>`.
- KTD2. **Use `triage-a-present-survivor` in both twins.** GitHub derives this slug from the Markdown heading (`test/site_links.py:18-20`). Give the HTML `<h3>` the same `id`.
- KTD3. **Recommend `ignore:` ids before markers.** Markers hide every `call_to_receiver` mutant on a line, including killable siblings (probe P3). Fizzy already uses ids to avoid tool comments in app code (report line 412). State that ids lapse after file moves or renames (R6).
- KTD4. **Keep the HTML twin hand-written.** No generator converts this `.md` to `.html`. `MutineerSiteDocs.stale_files` checks only `llms.txt` and contract files (`rake/site_docs.rb:156-161`). `equivalent-skips.md` is absent from `llms-full.txt` (`rake/docs_contract.rb:98`). Reject a new md-to-html check as outside scope.
- KTD5. **Treat R7 as final, not deferred.** “Track every limitation” requires issues for deferred trade-offs (`.expectation-fit/ways-of-working.yaml:11-13`). This design choice promises nothing; #399, the docs issue, records it. Do not file a receiver-aware-rule issue now. Nobody requested that rule beyond this report, and the issue says to wait.
- KTD6. **Add the entry link in `docs/results.md`.** Existing routes describe built-in skips (`docs/results.md:74`, `docs/llms.txt:27`). `skills/mutineer/SKILL.md:52` links only to the `results.md` suppression section. `results.md` appears in `llms-full.txt`; `equivalent-skips.md` does not (`rake/docs_contract.rb:98`). The suppression-guide link lets agents and readers find the advice. Do not also edit `docs/llms.txt:27`; one link is enough.

### Assumptions

Probe P1 confirmed the killing-test advice's ActiveSupport semantics on Ruby 3.4.9. Validation reports and ActiveSupport docs support the empty-relation case. The probe had no Active Record, so it did not check that case.

### Probe results

Scripts and output are machine-local under `probes/399/` in the planning context folder. `README.md` lists every file. A missing folder does not block implementation.

| Probe | Result |
|---|---|
| P1 | `truthiness.rb`: `present?` agrees with truthiness for `nil`, `false`, `0`, `"x"` and an object. It differs for `""`, `" "`, `[]` and `{}`. |
| P2 | On `lib/day.rb`, default operators produced 0 mutants. `--operators call_to_receiver` produced 4 mutants, 0 declined. Weak tests left 3 survivors, all `present?` to receiver. |
| P3 | Blank-string and exact-`true` tests killed their mutants. The scoped marker reported `ignored: 2`, including `account.name` to `account`. The `ignore:` id reported `ignored: 1`. Both runs scored 100%. |
| P4 | `mutations_for` returns `["x"]` for `x.present?` and `["params[:day]"]` for `params[:day].present?`. U2's mutator assertions hold on `main` today. |
| P5 (review) | Fizzy's real `DayTimelinesScoped#day` is a `def` with a `rescue` clause. `call_to_receiver` emits `params[:day].present?` to `params[:day]` (`probes/399/refute/fizzy_day_ctr.out`). A dry run with one `ignore:` mapping reports `1 ignored (suppressed)` (`probes/399/refute/dryrun-ignore.out`). |

---

## Implementation Units

### U1. Add the subsection to both twins and fix the marker sentence

| Item | Detail |
|---|---|
| Goal | Explain whether a `present?` survivor is real and how to suppress one mutant. |
| Requirements | R1 to R8, R10. |
| Dependencies | None. |
| Files | `docs/equivalent-skips.md`, `docs/equivalent-skips.html`, `docs/results.md`. |

**Approach:**

1. Correct the marker sentence at `docs/equivalent-skips.md:61-64` and `docs/equivalent-skips.html:82` per R8.
2. Add the subsection after the call-to-receiver table, following KTD1 and KTD2. Order: opt-in note (R2), equivalence (R3), gaps and killing tests (R4, R5), suppression (R6), no-skip decision (R7). Put `ignore:` first (KTD3).
3. Include one Ruby gap example (`if params[:day].present?`) and one YAML `ignore:` mapping. Reuse `docs/results.md:59-65`. Do not copy the five default operator names. Refer to “Endless range”: `--operators` replaces the default set (`docs/equivalent-skips.md:77`).
4. Include the same facts and both examples in HTML. Current twins differ: HTML omits “Endless range” code blocks and rewords the introduction (`docs/equivalent-skips.html:53`, `:93-98`). This page has no `<pre>` or `<h3>`. Copy `<pre><code>` from `docs/rails.html:76`. Copy `<h3 id="...">` within `.prose` from `docs/agentic-coding.html:110`, using KTD2's `id`.
5. Keep fenced-code lines from starting with `## `. The twin test ends the section at that prefix (`test/site_docs_test.rb:94`).
6. After `docs/results.md` line 74, link to `https://davidteren.github.io/mutineer/equivalent-skips.html#triage-a-present-survivor` for `present?` to receiver survivors (R10, KTD6). Use line 74's absolute URL form.

**Patterns:** Follow “Endless range” (`docs/equivalent-skips.md:94-100`) for equivalent and non-equivalent cases. Use ASD-STE100 and no em dash.

**Tests:** U2 contains this unit's tests.

**Verification:** Keep existing twin tests green. After `bundle exec rake site:build`, open `_site/equivalent-skips.html` at 390 px width. Check subsection placement under “Call to receiver”, readable `<code>present?</code>` in `<h3>`, and scrolling within `<pre>` boxes. `docs/assets/mutineer.css:183` sizes `.prose h2 code` but has no `h3 code` rule. Add CSS only if the heading or a block overflows.

### U2. Guard tests

| Item | Detail |
|---|---|
| Goal | Guard subsection presence, the entry link, phone-width layout, and continued mutation of `present?`. |
| Requirements | R1, R9, R10. |
| Dependencies | U1. |
| Files | `test/site_docs_test.rb`, `test/mutators/call_to_receiver_test.rb`, `test/browser/site.spec.js`. |
| Approach | Add one test beside each Ruby file's equivalent-skips or skipped-names tests. Add one browser-loop path. |
| Patterns | Follow `test_equivalent_skips_page_names_every_range_slice_call` (`test/site_docs_test.rb:99-106`) and `mutated` (`test/mutators/call_to_receiver_test.rb:18-25`). |

**Test scenarios:**

| File | Checks and limits |
|---|---|
| `test/site_docs_test.rb` | Require `<h3 id="triage-a-present-survivor">` between `<h2 id="call-to-receiver">` and `<h2 id="endless-range">`. Require ``### Triage a `present?` survivor`` within Markdown's “## Call to receiver” section. Check heading text because GitHub derives its anchor. |
| `test/site_docs_test.rb` | Slice HTML from `<h3 id="triage-a-present-survivor">` to the next `<h2`. Slice Markdown from `### Triage a` to the next `^## `. Require `present?`, `""`, `ignore:` and `mutineer:disable-line call_to_receiver` in each slice. Do not slice from `h2`: existing content already contains suppression tokens (`docs/equivalent-skips.md:60-63`, `docs/equivalent-skips.html:82`). This catches missing or moved subsections, but not wording differences. |
| `test/site_docs_test.rb` | Require `equivalent-skips.html#triage-a-present-survivor` in `docs/results.md` (R10). |
| `test/mutators/call_to_receiver_test.rb` | Require `mutated("x.present?")` to equal `["x"]` and `mutated("params[:day].present?")` to equal `["params[:day]"]`. This covers AE1 at operator level and catches name skips. Probe P3, not this test, proves killability. |
| `test/browser/site.spec.js` | Add `'/equivalent-skips.html'` to the phone-width path list at line 25. The loop checks theme, primary navigation and no page-wide horizontal scroll at 390 px. Navigation and script match `docs/rails.html` (`docs/equivalent-skips.html:26`, `:35-44`). This check covers the page's first `<pre>` blocks. |

**Verification:** All new tests pass. Ruby guards fail if `present?` enters `SKIPPED`, either twin loses its subsection, or `results.md` loses its link.

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

| Check | Reason |
|---|---|
| Site checks | `AGENTS.md`, “Website checks”, requires them for Pages changes. The browser run includes `/equivalent-skips.html` at phone width. |
| U1 manual check | At 390 px, inspect `<h3>` code style; automated checks do not inspect it. |
| Siblings rule | `.expectation-fit/ways-of-working.yaml`: reload/redefine and daemon/in-process do not apply because no code path changes. |
| Action and CLI | The Action calls the CLI, which reads the same `ignore:` mappings and markers. Its `operators` input becomes `--operators` (`action.yml:386`). R2 names all three selectors. |
| Report and dry run | Both already show ignored counts (probe P2 dry-run line, probe P5). No change is needed. |

## Definition of Done

- R1 to R10 hold, and AE1 to AE3 match the page.
- Both twins contain the same subsection facts and examples.
- Every Verification Contract command and U1's manual 390 px check passes.
- `lib/` remains unchanged; `CallToReceiver::SKIPPED` excludes `present?`.
- The pull request has `documentation` and `v1.9.0` labels. Its body includes `Closes #399`.
- No probe files remain in the repo.

---

## Risks and Overlaps

| Risk or overlap | Effect and control |
|---|---|
| #244, the 2.0 contract flip; #245, the parallel Rails default | Both touch `test/site_docs_test.rb`. #245 also adds older `docs/equivalent-skips.*` and `rake/site_docs.rb` copies, dated 2026-10-09, before the page on `main`. Those 2.0 branches already conflict with `main`. This plan adds one small hunk to resolve during rebase. |
| #274, scalar-conversion skips for `call_to_receiver` | It established the current skip list. This plan preserves it. |
| #386, default mutants for bare `if` or `rescue` bodies | This batch's sibling plan edits the "Endless range" section of `docs/equivalent-skips.md` and its HTML twin. See its U5 files table (PR2, the 2.0 draft), "Default-set docs" row: `docs/plans/2026-11-10-386-feat-default-mutants-for-bare-if-and-rescue-bodies-plan.md:512`. PR2 also moves one operator into `DEFAULT_NAMES` (same plan, line 517). PR2 exists only after the #386 spike passes. Only #386 PR2, a 2.0 draft, edits this page. #386 PR1 (v1.9.0) does not touch it, so this plan merges with no conflict in 1.x. PR2 finds the section by heading, so U1's insertion does not break it. U1 step 3 avoids conflicting default-name lists. |
| #397, class-body macro mutants | Its U6 adds a "Macro option removal" section to both twins (`docs/plans/2026-11-10-397-feat-class-body-macro-mutants-plan.md:453`). That plan gives no position for the section. Place it after "Endless range", not between "Call to receiver" and "Endless range". Else the U2 guard test fails. With that placement, expect a text conflict only. |
| Marker wording | Readers could think markers are safe for one mutant. KTD3 and R8 state their full scope. |
| Id wording | Readers could think `ignore:` ids are permanent. R6 and AE3 state when they change. |

## Open Questions

| Question | Default | Owner and revisit condition |
|---|---|---|
| Add a CHANGELOG entry? | No. This docs-only change alters no behaviour. | The maintainer decides at review. |
| File a receiver-aware-rule issue? | No. R7 and KTD5 record the final choice in #399, the docs decision record. | The maintainer decides if users ask again. A new issue would then change the page. |
