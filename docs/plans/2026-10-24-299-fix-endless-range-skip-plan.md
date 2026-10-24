---
title: "Skip endless ranges only when they are slice arguments - Plan"
type: fix
date: 2026-10-24
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
origin: GitHub issue #299 (davidteren/mutineer) and its Claude analysis comment
---

# Skip endless ranges only when they are slice arguments - Plan

## Goal Capsule

- Issue: #299.
- Goal: the `range` operator skips an endless range only when the range is a direct argument of a slice call (`[]`, `[]=`, `slice`, `slice!`, `byteslice`) or of an index write. It swaps `..` and `...` on every other endless range.
- Authority: this plan, then `AGENTS.md`, then the issue comment. Where the plan and the issue comment disagree, the plan wins (see "Corrections to the issue comment").
- Stop conditions: stop and ask if the change needs a new runtime gem, `eval`, a change to the default operator set, or a change to any operator other than `range`. None of these is expected.
- Size: S. One new constant, one new private helper, five small visitor methods, one changed condition, one class comment, two twin docs pages, one CHANGELOG entry, three new tests, two changed tests.

---

## Product Contract

### Summary

`RangeLiteral` skips every endless range (`1..`, `1..nil`). Its comment and the equivalent-skips page say the mutant is equivalent. That is true only where the range is used to slice. `(1..)` and `(1...)` differ on `==`, `eql?`, `hash`, `exclude_end?`, `to_s`, `inspect` and `cover?(1..)`, so a test that compares, stores or prints the range can kill the mutant. The fix keeps the skip for slice arguments and makes the mutant everywhere else.

### Problem Frame

- `lib/mutineer/mutators/range_literal.rb` line 25, `RangeLiteral#visit_range_node`: `emit(node) unless endless?(node)`.
- `lib/mutineer/mutators/range_literal.rb` lines 35 to 37, private `RangeLiteral#endless?`: true when `node.right` is nil or a `Prism::NilNode`.
- `lib/mutineer/mutators/range_literal.rb` lines 13 to 15: the class comment states the equivalence claim.
- `docs/equivalent-skips.md` line 5 ("Endless-range skips are equivalent.") and lines 48 to 50 (`## Endless range`). The twin `docs/equivalent-skips.html` has the same text at line 53 and lines 81 and 82, and the meta descriptions at lines 7, 14 and 22 say "why each is equivalent".
- Measured on Ruby 3.4.9: `arr[r]`, `str[r]`, `byteslice(r)`, `include?`, `===`, `size`, `count`, `first` and pattern matching give the same result for `(1..)` and `(1...)`. `==`, `eql?`, `hash`, `exclude_end?`, `to_s`, `inspect` and `cover?(1..)` differ. `step` gives the same elements, but the two `ArithmeticSequence` objects are not equal.
- Measured on `main` (`18ef483`): `lib/` has 12 endless ranges inside method bodies. All 12 are direct arguments of `[]` (10) or `byteslice` (2): `cli.rb` lines 114, 118, 210, 218, 226 and 230; `external_backend.rb` line 243; `isolation.rb` line 226; `migrate.rb` line 339; `mutation.rb` line 16; `redaction.rb` line 95; `statement_lines.rb` line 36. `ruby -Ilib bin/mutineer run --dry-run --operators range lib` gives 39 mutants.

### Requirements

- R1. An endless range that is a direct argument of a call named `[]`, `[]=`, `slice`, `slice!` or `byteslice` gets no `range` mutant. The receiver and the call operator do not matter: `list[1..]`, `list.[](1..)`, `list[1..] = x`, `s&.byteslice(1..)` and `byteslice(1..)` (no receiver) are all skipped. For `[]=`, only the index arguments count. The last argument is the assigned value, not a slice argument: `h[:k] = 1..nil` gets a mutant.
- R2. An endless range that is a direct argument of an index write or an index target gets no `range` mutant: `list[1..] += x`, `list[1..] ||= x`, `list[1..] &&= x` and `list[1..], b = x, y`. Prism does not represent these as calls, but Ruby runs them through `[]` and `[]=`.
- R3. Every other endless range gets one mutant that swaps `..` and `...`, as a range with an end does today. Examples: `(1..)`, `(1...nil)`, `r = (1..)`, `def r = (1..nil)`, `list.fetch(1..)`, `h[:k] = 1..nil` (the assigned value of `[]=`), and `list[(1..)]` (the parentheses make the range not a direct argument).
- R4. Ranges with an end, beginless ranges and flip-flops do not change. A range inside a skipped endless range is still visited, as today.
- R5. The class comment, both equivalent-skips pages and the CHANGELOG state the new rule and its limits.

### Acceptance Examples

- AE1. `def m; list[1..]; end` with `--operators range` gives no mutant, before and after the fix.
- AE2. `def m; (1..); end` gives one mutant, `(1...)`. Before the fix it gives none.
- AE3. `def r = (1..nil)` gives one mutant, `(1...nil)`. Before the fix it gives none.
- AE4. The dry run on Mutineer's own `lib/` gives 39 `range` mutants before and after the fix (on a tree equal to `18ef483` plus this change).

### User-visible change

- A run that names `range` can get more mutants, new survivors, new mutant ids and a different score. The default operator set does not include `range` (`lib/mutineer/mutator_registry.rb` line 60, `DEFAULT_NAMES`), so a default run and the GitHub Action defaults do not change.
- No change to exit codes, CLI flags, config keys or JSON fields.
- CHANGELOG: under `## [Unreleased]`, add a `### Fixed` heading after the existing `### Changed` block (or use it if another merged change added it first). Suggested entry, with a bold lead as the 1.7.0 entries have:
  "**The `range` operator swaps endless ranges outside slices.** Before, it skipped every endless range (`1..`, `1..nil`) as equivalent. But `(1..)` and `(1...)` differ on `==`, `hash`, `exclude_end?` and `to_s`, so a test can kill that mutant. Now the operator skips an endless range only when it is a direct slice argument of `[]`, `[]=`, `slice`, `slice!`, `byteslice` or an index write. A run that names `range` can get new mutants and new survivors. If you gate on it with `--threshold` or `--baseline`, expect new survivors, and generate a new baseline file with `--format json`. Some new mutants are equivalent, for example a range used only with `include?`, or a range in an Active Record query such as `where(created_at: time..)`. Suppress them with `# mutineer:disable-line` or an `ignore:` entry. (#299)"
- The released 1.1.0 CHANGELOG line about endless ranges (`CHANGELOG.md` line 922) and the 1.7.0 "Equivalent-skip page" entry (line 42) stay as they are.
- Commit type: `fix:`. AGENTS.md says a fix is a patch bump.

### Scope Boundaries

- No change to `RangeLiteral#endless?` or to how a range with an end is mutated.
- No new skip for other consumers that are equivalent, such as `include?`, `===`, `case`/`when` or `in` patterns. The rule stays "direct argument of a slice call or of an index write", as R2 and KTD3 define it. See Open Questions.
- No new config knob and no new report field.

### Deferred to Follow-Up Work

- Reporting a count of skipped mutants is #291. This change narrows one silent exclusion. It does not add a count.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Use the record-then-check pattern from `CallToReceiver#mark` (`lib/mutineer/mutators/call_to_receiver.rb` lines 41 to 44 and 102 to 104). When the visitor enters a slice call or an index node, it records each direct `RangeNode` argument in an identity hash. `visit_range_node` then skips an endless range only when the hash holds it. Prism visits a call before its arguments, so the record is in place when the range is visited. Rationale: the issue comment suggests this, and it needs no parent pointers.
- KTD2. Add a constant `RangeLiteral::SLICE_CALLS = %i[[] []= slice slice! byteslice].freeze`, with a `#` comment for `yard:strict`. Rationale: a named list on the class is the pattern `ChainLink::SKIPPED` uses, and the docs test can read it.
- KTD3. Cover the index nodes (`IndexOperatorWriteNode`, `IndexOrWriteNode`, `IndexAndWriteNode`, `IndexTargetNode`) for any name. Rationale: Ruby runs them through `[]` and `[]=`, so their mutant is as equivalent as `list[1..] = x`. A call-only check would start to make a new equivalent mutant for `list[1..] += x`, which it skips today. That would surprise a user, because `list[1..] = x` stays skipped.
- KTD4. The check is direct and name-only. A range inside parentheses, a splat, a keyword hash or an expression is not a direct argument, and it gets a mutant. Rationale: the issue comment asks for direct arguments. A name-only rule matches the chain-link skips, and the docs page already says such skips are not always equivalent. The known gap is a Hash with range keys: `{(1..) => :a}[1..]` gives `:a`, and `[1...]` gives nil. The docs say so.
- KTD5. Set the identity hash in `mutations_for` before `super`, as `CallToReceiver#mutations_for` does. Rationale: the hash must exist before the first visit, and a fresh hash per subject keeps no nodes from an earlier subject. No separate test: the endless-range tests raise NoMethodError if the hash is not set.
- KTD6. For a call named `[]=`, record every argument except the last. Rationale: Prism puts the assigned value in the argument list (`h[:k] = 1..nil` is a `[]=` call with arguments `:k` and the range). That value is stored, not used to slice, so its mutant can be killed.
- KTD7. Rejected alternative: keep the full skip and only correct the class comment and the docs (option 2 in the issue comment; the issue allows it). It adds no new equivalent mutants and no score change. But it keeps hiding every killable endless-range mutant, such as a range a test compares, stores or prints. The issue comment recommends option 1. The narrower skip removes the false claim and keeps the skip where the mutant is equivalent for Arrays and Strings. Its cost (new equivalent mutants in Rails query code) is named in the docs and in Risks.

### High-Level Technical Design

Directional sketch, not final code:

```text
mutations_for(subject, source):  @slice_args = {} compare_by_identity; super
visit_call_node(node):           record_slice_args(node) if SLICE_CALLS has node.name; super
visit_index_*_node(node) x4:     record_slice_args(node); super
visit_range_node(node):          emit(node) unless endless?(node) && @slice_args has node; super
record_slice_args(node):         each RangeNode in node.arguments&.arguments (for []=: all but the last) -> @slice_args[it] = true
```

### Corrections to the issue comment

- Line numbers moved after #302 merged. On `18ef483` the `## Endless range` section of `docs/equivalent-skips.md` is lines 48 to 50, not 44 to 46. Line 5 of the same page ("Endless-range skips are equivalent.") must change too. The comment does not name the twin `docs/equivalent-skips.html` (lines 7, 14, 22, 53, 81 and 82).
- The comment does not name `test/mutators/range_literal_test.rb` `test_endless_range_still_visits_its_begin` (lines 52 to 58). It asserts one mutant for `((1..2)..)`. After the fix that body gives two, so the test must change (U1).
- The suggested slice rule is not fully equivalent either. `Hash#[]` and `Hash#slice` compare keys with `eql?` and `hash`, so a Hash with range keys tells `h[1..]` from `h[1...]`. Rare, but the docs must not call the remaining skip "equivalent" without that limit.
- The comment lists only `[]`, `[]=`, `slice`, `slice!` and `byteslice`. `list[1..] += x`, `||=`, `&&=` and multiple assignment to `list[1..]` are separate Prism node types, not calls. KTD3 covers them.
- The comment lists `step` as giving the same result. Only the elements match: `(1..).step(2) == (1...).step(2)` is false on Ruby 3.4.9.
- The other claims are correct: the seven methods that differ, the 12 endless ranges in `lib/`, and that all 12 are slice arguments.

### Sequencing

U1 (code and its unit tests) first. U2 (docs, docs test and CHANGELOG) next. Both can land in one commit or two. One pull request.

---

## Implementation Units

### U1. Narrow the skip in RangeLiteral

**Goal:** `RangeLiteral` skips an endless range only when it is a direct slice or index argument.

**Requirements:** R1, R2, R3, R4, R5 (code comment).

**Dependencies:** none.

**Files:**
- `lib/mutineer/mutators/range_literal.rb`
- `test/mutators/range_literal_test.rb`

**Approach:**
- Add `SLICE_CALLS` after `SWAPS` (line 18), with a comment that says what the list holds and why: these calls select the same elements for `(1..)` and `(1...)`.
- Add `mutations_for(subject, source)` that resets `@slice_args` to an identity hash and calls `super` (KTD5). YARD docs as in `CallToReceiver#mutations_for`.
- Add public `visit_call_node`, `visit_index_operator_write_node`, `visit_index_or_write_node`, `visit_index_and_write_node` and `visit_index_target_node`. Each records the direct range arguments and calls `super`. `visit_call_node` records only when `SLICE_CALLS` includes `node.name`. Each method gets a one-line YARD comment with `@param` and `@return [void]`, as in `CallToReceiver`.
- Add a private helper (name it in the style of `CallToReceiver#mark`, for example `record_slice_args`) that walks `node.arguments&.arguments` and records each `Prism::RangeNode`. For a `CallNode` named `[]=`, it leaves out the last argument (KTD6). Index write nodes keep their value outside `arguments`, so they need no such rule. Document it.
- Line 25: `emit(node) unless endless?(node) && @slice_args.key?(node)`. Keep the `super` and its comment on line 26.
- Lines 13 to 15 (class comment): say that an endless range is skipped only as a direct argument of {SLICE_CALLS} or of an index write, because slicing gives the same result for `(1..)` and `(1...)`. Say that every other endless range is swapped, because the two ranges differ on `==`, `hash`, `exclude_end?` and `to_s`.
- Update the `endless?` comment (line 31) only if its wording no longer fits. Its logic does not change.

**Patterns to follow:** `CallToReceiver#mutations_for`, `#mark` and its visitor methods (`lib/mutineer/mutators/call_to_receiver.rb` lines 36 to 104). `ChainLink::SKIPPED` for the constant.

**Test scenarios** (all in `test/mutators/range_literal_test.rb`; the existing `run_mutator` wraps a body in `def m`):
- Change `test_endless_ranges_yield_none` (lines 45 to 50) and rename it `test_endless_slice_arguments_yield_none`. Bodies: `list[1..]`, `list[1...]`, `list[1..nil]`, `list[1..] = x`, `list.[](1..)`, `s.slice(1..)`, `s.slice!(1..)`, `s.byteslice(1..)`, `s&.byteslice(1...)`, `byteslice(1..)`, `list[1..] += x`, `list[1..] ||= x`, `list[1..] &&= x`, `list[1..], b = x, y`. Assert no mutant for each. Covers AE1, R1 and R2. It passes before the fix (every endless range is skipped today) and must pass after it.
- New `test_endless_ranges_outside_a_slice_are_swapped`. Bodies and expected replacement: `(1..)` gives `...`, `(1...)` gives `..`, `(1..nil)` gives `...`, `(1...nil)` gives `..`, `r = (1..)` gives `...`, `list.fetch(1..)` gives `...`, `h[:k] = 1..nil` gives `...` (KTD6), `list[(1..)]` gives `...`. For each, assert one mutant, that its source slice is the original operator, the replacement, `operator == :range`, and `valid?(source)`. Covers AE2, R3 and KTD6. It fails before the fix, because today each body gives no mutant.
- New `test_endless_def_body_is_swapped`. Build the subject from the source `def r = (1..nil)\n` with the existing `subject_for` helper (not `run_mutator`). Assert one mutant with replacement `...` that re-parses. Covers AE3. It fails before the fix.
- Change `test_endless_range_still_visits_its_begin` (lines 52 to 58). Change the body from `((1..2)..)` to `list[(1..2)..]`, so the outer endless range stays skipped. Keep the assertions: one mutant, on the inner `..`, 2 bytes after `(1`, and it re-parses. Covers R4. It passes before and after the fix. Without this change the old body gives two mutants after the fix and the test fails.
- `test_inclusive_to_exclusive`, `test_exclusive_to_inclusive`, `test_beginless_ranges_round_trip`, `test_nested_ranges_yield_one_per_operator` and `test_flip_flop_yields_none` stay as they are and must pass (R4).

**Execution note:** if a Rails app with endless ranges is at hand, run the `range` dry run on it before and after the fix. Put the number of new mutants, and how many are Active Record query values, in the pull request description. This is information for the Open Question on query values, not a merge gate.

**Verification:** the new and changed tests pass. `test/integration_test.rb` (the range survivor at line 67, fixture without endless ranges) and `test/mutator_registry_test.rb` pass unchanged. `yard:strict` reports 100%. The dry run gives 39 `range` mutants on `lib/` (AE4).

### U2. Docs, docs test and CHANGELOG

**Goal:** the docs and the CHANGELOG state the narrower skip and its limits.

**Requirements:** R5.

**Dependencies:** U1 (the docs test reads `RangeLiteral::SLICE_CALLS`).

**Files:**
- `docs/equivalent-skips.md` (line 5 and lines 48 to 50)
- `docs/equivalent-skips.html` (lines 7, 14, 22, 53, 81 and 82)
- `test/site_docs_test.rb` (a new test after line 86)
- `CHANGELOG.md` (`## [Unreleased]`)

**Approach:**
- Intro sentence (md line 5, html line 53): replace "Chain-call skips use the method name only, so they are not always equivalent. Endless-range skips are equivalent." with "Chain-call skips and the endless-range skip use the method name only, so they are not always equivalent."
- HTML meta descriptions (lines 7, 14, 22, all three the same): replace "and endless ranges Mutineer does not mutate, and why each is equivalent." with "and endless-range slice arguments that Mutineer does not mutate, and why."
- `## Endless range` section, in short sentences, the same words in both files (`<code>` and `<p>` markup in the HTML, as in the current section):
  - The `range` operator swaps `..` and `...`. It skips an endless range (`1..` or `1..nil`) only when the range is a direct argument of `[]`, `[]=`, `slice`, `slice!` or `byteslice`, as in `argv[1..]` or `text.byteslice(offset..)`. Index writes such as `list[1..] += x` count too.
  - There, `(1..)` and `(1...)` select the same elements, so the mutant is equivalent. The check uses the method name only. A Hash with range keys tells `h[1..]` from `h[1...]`, and a class of your own can define `[]` or `slice` to treat the two ranges differently. In those cases the skip hides a mutant a test can kill.
  - Every other endless range is swapped. This includes the assigned value in `h[:k] = 1..nil` and a range in parentheses, as in `list[(1..)]`. `(1..)` and `(1...)` differ on `==`, `eql?`, `hash`, `exclude_end?`, `to_s`, `inspect` and `cover?(1..)`, so a test that compares, stores or prints the range can kill the mutant.
  - Some of these mutants are equivalent: a range in parentheses inside a slice, or a range used only with `include?`, `===`, `case`/`when` or `clamp`. In a Rails app, a range in an Active Record query, as in `where(created_at: time..)`, also gives an equivalent mutant, because both ranges become the same `>=` SQL condition. So does `validates :age, inclusion: { in: 18.. }`. Suppress such a mutant with `# mutineer:disable-line` or an `ignore:` entry, as described at the top of the page.
- Do not put the count of endless ranges in Mutineer's own `lib/` (12) on the page. It goes stale. Put it in the pull request description.
- CHANGELOG: add the entry from "User-visible change".

**Test scenarios** (in `test/site_docs_test.rb`):
- New `test_equivalent_skips_page_names_every_range_slice_call`. For each name in `Mutineer::Mutators::RangeLiteral::SLICE_CALLS`, assert that `docs/equivalent-skips.html` includes `<code>NAME</code>` and `docs/equivalent-skips.md` includes `` `NAME` ``. It fails before the fix, because the constant does not exist. It fails later when a name is added to the list but not to the pages.
- Do not edit `test_equivalent_skips_page_names_every_chain_link_skip` (lines 80 to 86). Its `assert_includes page, "endless"` still holds. A separate test keeps this change away from the lines that the #274 plan edits.

**Verification:** both pages read the same. `test_stale_files_is_empty_at_head` and the website checks pass.

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

Count check (AE4):

```sh
ruby -Ilib bin/mutineer run --dry-run --operators range lib | tail -1
```

Expect `range: 39` before and after the fix on a tree equal to `18ef483` plus this change. Later merges to `lib/` can move the number. A higher number after the fix means a slice argument is not recognized.

AGENTS.md rules that apply: zero runtime dependencies (none added), no `eval` (none added), 100% YARD docs including the new constant, the new public visitor methods and the private helper, and a CHANGELOG entry under `## [Unreleased]`. The score model does not change: new mutants are killed or survived like any other. The Minitest 6 run is not needed, because the change does not touch the Minitest integration.

## Definition of Done

- `RangeLiteral::SLICE_CALLS` exists with a comment. `visit_range_node` skips an endless range only when it is a recorded direct argument.
- The four index node types are handled, the assigned value of `[]=` is not recorded, and the record resets per subject.
- The class comment, both equivalent-skips pages and the meta descriptions state the new rule and the Hash-key limit.
- The CHANGELOG entry is under `## [Unreleased]` / `### Fixed`.
- The three new tests fail on `main` (the docs test with a NameError) and pass with the change. The changed tests pass.
- The dry run gives 39 `range` mutants on `lib/`.
- The local gate and the website checks pass.

---

## Risks and Overlaps

- The #274 plan (branch `plan/274-call-to-receiver-skip-list`, file `docs/plans/2026-10-24-274-feat-call-to-receiver-skip-list-plan.md`) edits the same files: `docs/equivalent-skips.md`, `docs/equivalent-skips.html`, `test/site_docs_test.rb` and `CHANGELOG.md`. It rewrites the `## Chain link` section and inserts a new `## Call to receiver` section directly before `## Endless range`. That hunk sits next to this plan's edit of the `## Endless range` section, so expect a text conflict in both docs files. Resolve it by keeping both sections, with `## Call to receiver` before `## Endless range`. #274 also narrows `test_equivalent_skips_page_names_every_chain_link_skip` and keeps its `endless` assertion. This plan adds a separate test, so that test does not conflict. The intro sentence (md line 5, html line 53) and the meta descriptions are not in #274's hunks. Whichever change merges second rebases and re-reads the page as a whole.
- CHANGELOG conflicts. Open PRs #304, #305, #306, #307, #308, #244 and #245 all add lines under `## [Unreleased]`. Resolve by keeping every entry. If another change has added `### Fixed`, put this entry under it.
- `lib/`: no open PR in the list (#304 to #308, #202, #244, #245, #301) touches `range_literal.rb`, its test or the equivalent-skips pages. #304 and #308 edit `lib/mutineer/isolation.rb`, which holds one of the 12 endless ranges (line 226, `snippet.byteslice(rel_e..)`). If they move or remove it, the counts of 12 and 39 can change. The dry-run check names `18ef483` for this reason.
- New equivalent mutants. Some newly swapped endless ranges are equivalent: a range used only with `include?`, `===`, `clamp`, `case`/`when` or an `in` pattern, or inside parentheses in a slice call. In Rails apps the most common case is likely an Active Record query value: Arel (`activerecord` 8.1.4, `Arel::Predications#between`) turns any endless range into `>= begin` and ignores `exclude_end?`, so `where(created_at: t..)` and `where(created_at: t...)` give the same SQL. Inclusion validations use `include?`. `lib/` and `test/fixtures/rails_app` have none of these today, so no measurement in this repo shows how many such mutants a Rails app gets. This is the main cost of the change, and the docs and CHANGELOG name it. Users suppress them with `# mutineer:disable-line` or an `ignore:` entry. The docs page says so.
- Hidden killable mutants. The name-only check still hides a killable mutant on a Hash with range keys, or on a user class whose `[]` or `slice` treats the two ranges differently. The docs page says so.
- Score change for users who run `--operators range` with `--threshold` or a baseline. The CHANGELOG entry says so. The default operator set does not change, so this is not a major bump.
- This plan file. `rake site:build` copies `docs/` to `_site/` and leaves out only `UNPUBLISHED = %w[release-review]` (`rake/site_build.rb` line 30). Do not include this plan file in the implementation pull request, unless a separate change has added `plans` to `UNPUBLISHED` first.
- #291 (count silently excluded mutants) is related. This change narrows one exclusion and does not block it.

## Open Questions

- Deferred, not blocking: should index writes count as slice arguments? Default (KTD3): yes, so `list[1..] += x` stays skipped as today. Alternative: handle only `CallNode`, as the issue comment literally says. That makes a new equivalent mutant for each index write with an endless range. `lib/` has none.
- Deferred, not blocking: should a range in parentheses (`list[(1..)]`) count as a direct argument? Default (KTD4): no, it gets a mutant. Alternative: unwrap one `ParenthesesNode` with one statement. `lib/` has none.
- Deferred, not blocking: should an endless range that is a keyword-hash value of an Active Record query method (`where`, `rewhere`, `where.not`) be skipped like a slice argument? Default: no. A name-only check on `where` would also match non-Rails methods, and the gem keeps its mutators free of Rails knowledge. Alternative: skip it, after a real-app count shows that these mutants are common.
- Deferred, not blocking: should the skip extend to other consumers that give the same result, such as the argument of `include?` or `===`, a `when` clause or an `in` pattern? Default: no, those get mutants. Alternative: add them after #291 or a real-app count shows they are common. The receiver case (`(1..).include?(x)`) needs a receiver check, which is a new kind of record.
