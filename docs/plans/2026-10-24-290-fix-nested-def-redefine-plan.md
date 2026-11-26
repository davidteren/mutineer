---
title: "fix: Kill a nested method's mutant under --strategy redefine - Plan"
type: fix
date: 2026-10-24
issue: 290
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
depth: standard
base: fix/279-surgical-beside-source
---

# fix: Kill a nested method's mutant under --strategy redefine - Plan

**Issue:** #290. **Goal:** under `--strategy redefine`, a mutant in a `def` nested only in other `def`s (no block between them) gets the same verdict as under `reload` when a test calls an enclosing method by its own name.

---

## Goal Capsule

- **Objective:** redefine loads the mutated text into the nested method and into every method that encloses it. A call to the outer method then defines the mutated inner method, not the original.
- **Authority:** this plan, then `AGENTS.md`, then the issue comment on #290.
- **Stop conditions:** stop and ask if the fix needs a change to `Isolation.apply_surgical`'s slicing, to mutant ids, or to the daemon or `--test-command` paths. None of them should change.
- **Base:** branch from `fix/279-surgical-beside-source` (draft PR #304). Rebase onto `main` after #304 merges.
- **Size:** M (about 15 changed lines in `lib/`, 3 new fixture files, 5 tests (one replaces the old pin; the fifth came from code review), 1 CHANGELOG entry, 1 README sentence).

---

## Product Contract

### Summary

A `def` inside another method is its own subject. Since #157 (v1.5.0), its mutants exist only on that inner subject. Redefine loads only the inner method. The outer method's body still holds the original inner `def`. So each call to the outer method defines the original inner method again, after the mutant was loaded, and the mutant falsely survives. This plan makes redefine also load the mutated text into each enclosing method.

### Problem Frame

Redefine is the default under `--rails` without `--daemon`. A false survivor there lowers the score and asks the user to write a test that already exists. `test/nested_redefine_test.rb:29-32` pins the wrong verdict (`[0, 1]` killed and survived) as a known limit. Reload gives `[1, 0]` for the same fixture. The 1.5.0 CHANGELOG entry (`CHANGELOG.md:733-737`) documents the limit. No tracking issue or warning existed before #290.

### Requirements

Verdicts

- R1. Under redefine, a mutant in a nested `def` is killed when a test kills it under reload, if every level between the `def` and the outermost `def` is a `def` (no block between them). This holds when the test calls the outer method by its own name (not through an alias).
- R2. This holds at any nesting depth. A `def c` in `def b` in `def a` is covered when a test calls `b` directly and `b` already exists.
- R3. A test that calls the inner method directly still kills the mutant, as today. KTD4 keeps this path. `test_redefine_and_reload_agree_when_the_test_calls_the_inner_method` covers R3 (the innermost load runs first, as today).

Contract

- R4. No change to mutant ids, JSON fields, exit codes, or the reload, `--daemon` and `--test-command` paths.
- R5. A CHANGELOG entry under `## [Unreleased]` / `### Fixed` names the fix and #290.

### Scope Boundaries

- Mutant ids stay as they are. The id-remap warning from the issue body is deferred. OQ1 recommends a separate issue for it.
- The issue body's other options (mark nested mutants `unplaceable`, or run them under reload) are not used. The comment's prototype shows redefine can give the right verdict, which is better than skipping the mutant. Reload per nested mutant is not used either: under `--rails`, reload runs the whole file's class body again, which redefine exists to avoid, and a strategy that changes per subject would surprise users.

#### Deferred to Follow-Up Work

- A `def` inside a non-builder block (`define_method`, a stored proc, a lambda) can still falsely survive, with or without an enclosing `def`. If the block ran before the fork and a test calls the method the block defined, the original block defines the original `def` again. Example: `def self.a; define_method(:x) { def b; 1 + 1; end; b }; end` with a load-time `K.a`. The chain loads `b` and `a`, but not the block. See OQ2.
- A `def` nested in a `module_function` method or in `class << self` inside a method has a wrong owner in discovery (see Risks). Not in scope.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **`Subject#enclosing_subject` holds the immediate enclosing subject, not the outermost one.** The runner walks the chain up to the outermost `def`. The issue comment proposed the outermost `def` only. That fails at depth 3: with `def a; def b; def c; 1 + 1; end; c; end; :a; end` and a load-time `Deep.new.a`, a test that calls `Deep.new.b` sees the original `b`, which defines the original `c`. A prototype gave `[0, 1]` (survived) with outermost-only and `[1, 0]` (killed) with the chain. The chain costs no extra code: one `while` loop instead of a "find the top" loop. Outermost-only is rejected: it drops R2 and saves no code.
- KTD2. **Store the same `Subject` object, not a copy.** `promote_module_functions!` (`lib/mutineer/project.rb:95-100`) sets `singleton` after the walk. A shared reference sees that change.
- KTD3. **Keep the walk in `Runner.run`, not in `Isolation.apply_surgical`.** `apply_surgical` stays "load one method". `Runner.run` (`lib/mutineer/runner.rb:339-343`) is its only caller in `lib/`. Each call slices its own subject's `def_node`, and the mutation offsets fall inside every enclosing `def`, so the slicing works unchanged.
- KTD4. **Load innermost first.** The order does not change the result, because loading a `def` does not run its body. Innermost first keeps the R3 case the same as today.
- KTD5. **No new unplaceable rule.** A nested `def` is never more placeable than its enclosing `def`. `visit_def_node` does not reset owner state, so the inner `def` inherits `owner_unknown` and `hook_block`. A block between them can only add unknowns: in `def a; Class.new do def b; end end; end`, `K#b` has `owner_unknown: true` and is unplaceable under redefine, so `Runner.run` returns before the walk (checked with `Project.discover` on this branch). If an enclosing load ever fails, `apply_surgical` raises, and the result is `error`, never a false `survived`.

### High-Level Technical Design

Directional sketch of the child under redefine:

```text
Isolation.apply_surgical(mutation, subject, source)   # the inner def, as today
s = subject.enclosing_subject
while s
  Isolation.apply_surgical(mutation, s, source)         # then each enclosing def
  s = s.enclosing_subject
end
run the covering tests
```

---

## Implementation Units

### U1. Record the enclosing subject during discovery

**Goal:** each nested subject knows the subject of the `def` that encloses it.

**Requirements:** R1, R2.

**Dependencies:** none.

**Files:**
- `lib/mutineer/subject.rb` (Struct members at lines 20-21, class comment at lines 4-19)
- `lib/mutineer/project.rb` (`SubjectVisitor#initialize` at lines 64-87, `#visit_def_node` at lines 242-266)
- `test/project_test.rb`

**Approach:**
- Add `:enclosing_subject` as the last `Subject` member. The name says it holds a `Subject`. It defaults to `nil` (keyword_init), so the `Subject.new` calls in `lib/` and in the tests (for example `test/runner_test.rb:207`, `test/subject_test.rb`, `test/parallel_strategy_test.rb`) need no change.
- Document the member in the class comment: "`enclosing_subject` is the subject of the `def` whose body holds this one, or nil."
- In the visitor, initialize `@enclosing_subject = nil` with a trailing comment, as for the other ivars. In `visit_def_node`, build the subject with `enclosing_subject: @enclosing_subject`, set `@enclosing_subject` to the new subject for the `super` call, and restore it after.
- Do not add `@enclosing_subject` to `SCOPE_STATE` (`lib/mutineer/project.rb:362-364`). A class or module body cannot open inside a method body. A builder block inside a method body goes through `preserving_scope`, so the value passes through it unchanged, which is correct: the block runs when the method runs. `visit_def_node` restores the value itself.

**Patterns to follow:** the `saved_active` and `saved_self` save-and-restore in the same method.

**Test scenarios:**
- `test_discover_links_a_nested_def_to_its_enclosing_def` in `test/project_test.rb`. Source: `class K; def a; def b; def c; end; end; def d; end; end; def e; end; end`. Assert `c.enclosing_subject` is the same object as `b` (`assert_same`), `b.enclosing_subject` and `d.enclosing_subject` are `a`, and `a.enclosing_subject` and `e.enclosing_subject` are nil. `d` proves the restore after `b`. `e` proves the restore after `a`. Fails before the fix with `NoMethodError` on `enclosing_subject`.
- `test_discover_links_a_def_in_a_builder_block_to_its_enclosing_def` in `test/project_test.rb`. Source: `class K; def a; Class.new do; def b; end; end; end; end`. Assert `b.enclosing_subject` is `a` and `b.unplaceable?("redefine")` is true. This pins KTD5. It fails before the fix with `NoMethodError`.

**Verification:** both new tests pass. `bundle exec rake yard:strict` stays at 100%.

### U2. Load each enclosing method under redefine

**Goal:** the redefine child loads the mutated text into the subject and every enclosing subject.

**Requirements:** R1, R2, R3, R4.

**Dependencies:** U1.

**Files:**
- `lib/mutineer/runner.rb` (`Runner.run` at line 316, redefine branch at lines 339-343, and the `@param subject` line in its doc comment)
- `test/nested_redefine_test.rb`
- `test/fixtures/nested_deep.rb` (new)
- `test/fixtures/nested_deep_test.rb` (new)
- `test/fixtures/nested_deep_outer_test.rb` (new)
- `test/fixtures/nested_deep_inner_test.rb` (new)

**Approach:**
- Replace the single `Isolation.apply_surgical` call with the walk in the High-Level Technical Design. Add a short comment that names #290 and the reason: the outer body holds the original inner `def`.
- Do not change `Isolation.apply_surgical`. Under #304 each load writes its own hidden `.mutineer_mutant*.rb` beside the source. Under #308 each load goes through `Isolation.write_beside`.
- Update the header comment of `test/nested_redefine_test.rb` (lines 6-9). It describes the fix now, not a known limit.

**Test scenarios:**
- `test_redefine_kills_the_nested_mutant` replaces `test_redefine_lets_the_nested_mutant_survive` (`test/nested_redefine_test.rb:29-32`). It asserts `[1, 0]` for `test/fixtures/nested.rb`, the same as `test_reload_kills_the_nested_mutant`. It fails before the fix with `[0, 1]`. Verified by a prototype on this branch.
- `test_redefine_and_reload_agree_on_a_deeply_nested_mutant` in the same file. Fixture `test/fixtures/nested_deep.rb`: `class NestedRedefineDepthFixture` with `def a` holding `def b` holding `def c` with `1 + 1`. `b` calls `c`, and `a` returns `:a`. The file ends with `NestedRedefineDepthFixture.new.a`, so `b` exists before the fork. `test/fixtures/nested_deep_test.rb` asserts `NestedRedefineDepthFixture.new.b == 2` and does not call `a`. The test asserts `[1, 0]` for both strategies. It fails before the fix with `[0, 1]` under redefine. It also fails with the outermost-only variant (KTD1). Verified by a prototype.
- `test_redefine_and_reload_agree_when_the_test_calls_the_outermost_method`. `test/fixtures/nested_deep_outer_test.rb` calls `a` first, which defines `b` again from `a`'s body, then asserts `b == 2`. Both strategies give `[1, 0]`. It fails when only the immediate enclosing level loads.
- `test_redefine_and_reload_agree_when_the_test_calls_the_inner_method`. `test/fixtures/nested_deep_inner_test.rb` calls `b` once at load, so `c` exists, then asserts `c == 2` without calling `a` or `b`. Both strategies give `[1, 0]` (R3).

**Verification:** both tests pass. The rest of `test/nested_redefine_test.rb` and `test/parallel_strategy_test.rb` stay green.

### U3. CHANGELOG

**Goal:** users learn that the 1.5.0 limit is gone.

**Requirements:** R5.

**Dependencies:** U2.

**Files:** `CHANGELOG.md`, `README.md`

**Approach:** add under `## [Unreleased]` / `### Fixed`, after the #279 entry (the shipped text in `CHANGELOG.md` adds the review findings: the upgrade note, the alias and wrapped-method limits, and the reload workaround):

```text
- **A nested method's mutant under `--strategy redefine`.** Redefine now
  also loads the mutated method into each method that encloses it. Before,
  a call to the outer method defined the original inner method again, so
  the mutant could falsely survive (#290). For a method nested directly
  in another method, redefine now gives the same verdict as reload when a
  test calls the outer method by its own name. Mutant ids do not change,
  so baselines and `ignore:` entries stay valid. Scores under redefine can
  rise, and an `ignore:` entry added only to hide such a survivor can now
  be removed. A method defined inside a non-builder block (for example
  inside `define_method`), inside a `module_function` method, inside
  `class << self` in a method, or called through an alias of the outer
  method can still falsely survive under redefine. Use
  `--strategy reload` for those cases.
```

In `README.md:346` (the `--rails` paragraph, as #304 left it), change "it reloads only the mutated method, not the whole file" to "it reloads only the mutated method and each method that directly encloses it, not the whole file; a method nested in a block such as `define_method` can still falsely survive, so use `--strategy reload` for it".

Do not edit the 1.5.0 entry. Released entries stay as they were.

**Test expectation:** none. Documentation only. The site checks read `README.md` (`rake/site_build.rb`, `rake/docs_contract.rb`), so run them.

**Verification:** the entry sits under `[Unreleased]` and follows the style of the entries around it.

---

## Verification Contract

Prefix every ruby, rake and bundle command with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`. From `AGENTS.md`:

```sh
bundle exec rake test                          # zero-dep suite
ruby -Ilib -e 'require "mutineer"'             # load smoke
bundle exec rake yard:strict                    # 100% documented
```

Also run the Minitest 6 suite, because the fixtures run through the Minitest integration:

```sh
BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle exec rake test
```

`AGENTS.md` rules that apply:
- Zero runtime dependencies. The fix uses no gem.
- No `eval`. The fix reuses the existing `load` of a file.
- 100% YARD docs, including the new Struct member and the visitor ivar comment.
- CHANGELOG entry under `## [Unreleased]`.
- Score model unchanged: the fix moves nested-case verdicts from `survived` to `killed`. The earlier-definition and wrapped-method risks (see Risks) can change other verdicts. Treat any other verdict change in the exact-survivor integration oracle as a bug.

`rake test:daemon` is not needed. The daemon always reloads the whole file (`lib/mutineer/daemon_backend.rb:383`).

---

## Definition of Done

- U1 to U3 are in, and every test named above passes and failed before its unit.
- All Verification Contract commands pass.
- The diff in `lib/` touches only `subject.rb`, `project.rb` and `runner.rb`.
- The fix pull request includes this plan file (maintainer decision, 2026-10-24). PR #309 keeps `docs/plans/` off the website.
- No prototype or debug code is left in the diff.

---

## Risks and Overlaps

- **#304 (draft, base of this plan).** It moves the surgical file beside the source (`lib/mutineer/isolation.rb:265-283`). This fix calls that code more than once per mutant. Land #304 first so every load writes beside the source.
- **#308 (draft, stacks on #304).** It adds `Isolation.write_beside` with an exclusive file lock and routes `apply_surgical` through it. Each enclosing load takes its own file and its own lock, one after the other, in the same child. The orphan sweep handles more than one file per child. There is no textual conflict: this plan does not touch `isolation.rb`. If #308 lands first, rebase only.
- **#244 (feat: flip the 2.0 contract).** It changes a doc comment in `lib/mutineer/runner.rb` near line 31, not the redefine branch. A rebase may need a trivial merge.
- **#202, #245, #301, #302, #305, #306, #307.** No shared lines with this plan.
- **Wrong owner for some nested `def`s.** The visitor marks a `def` nested in a `module_function` method as singleton, but Ruby defines it as an instance method of the module. A `def` in `class << self` inside a method lands on the receiver's singleton class, not the class. In both cases the first load (the inner subject) targets the wrong method, as it does today. The chain does not fix the `module_function` case: `apply_surgical` wraps the reloaded outer method in `class << self` (`lib/mutineer/isolation.rb:243-247`), so a call to it defines the inner method on the module's singleton class, not as an instance method. The CHANGELOG says these cases can still falsely survive. Not in scope.
- **Earlier definition of nested methods.** The walk loads each enclosing level at class level. In the depth-3 case the mutated `b` and `c` exist before any test calls `a`. Under reload, `c` exists only after `b` runs. Redefine already does this for the innermost level today. A test that checks that a nested method does not exist yet can get different verdicts. Rare; no change.
- **#304 also edits `README.md:346`.** U3 edits the same sentence. Base on #304 so the edit applies to its text.
- **Wrapped enclosing methods.** Each enclosing load redefines the outer method from its source, so a wrapper installed over it after the `def` (a memoizer or decorator that captured the original) is replaced. Redefine already does this for the outer method's own mutants. The walk extends it to nested mutants, and a verdict can move from survived to killed where reload keeps survived. Rare; no change. A follow-up could skip the enclosing load when the live method's source location does not point at its `def`.
- **Aliased enclosing methods.** `alias_method :old, :outer` keeps the original body, so a test that calls `old` still sees a false survivor. This is a general redefine limit; the CHANGELOG names it.
- **Cost.** One extra file write and `load` per enclosing level, only for nested subjects. Nested `def`s are rare.
- **Struct equality and inspect.** `Subject#==`, `#hash` and `#inspect` now include the enclosing chain. No code in `lib/` uses subjects as hash keys or prints `inspect`. Subjects do not cross a process boundary (WorkerPool sends only `Result`s).

---

## Open Questions

- OQ1 (deferred). **Id-remap warning.** The issue body asks for a warning when an `ignore:` or baseline id now names another mutant. Since #157, `MutantId` hashes the path, the qualified name, the operator, the token and an ordinal. A stored entry cannot show that its ordinal now names another mutant. A warning needs extra data per entry, for example the mutated line text. Recommendation: file it as its own issue. This plan does not file it.
- OQ2 (deferred). **`def` inside a non-builder block.** For example `define_method(:x) { def inner; ...; end }`, alone or inside a `def`. A call to `x` defines the original `inner` again. Options: mark such a subject unplaceable under redefine, or record the block so the child can reach it. Needs its own issue if it matters in practice.
- OQ3 (deferred, default chosen). **Outermost-only.** The issue comment proposed loading only the outermost enclosing `def`. KTD1 chooses every level, because outermost-only fails R2 in a prototype and saves no code. Reopen only if a reviewer wants to drop R2.
- OQ4 (deferred). **The 1.5.0 entry says "survive or error".** The prototype saw no error: both nested tests give `[1, 0]`, so the one mutant is killed, not errored. If the implementer sees an `errored` result in either test, report it on #290 instead of hiding it.

---

## Sources

- Prototype on this branch (U1 and U2 code, no test edits; the depth-3 fixture ran in a scratch project, outside the suite): the full `bundle exec rake test` run gave 1411 runs and 1 failure, the old pin `test_redefine_lets_the_nested_mutant_survive` (`[1, 0]` instead of `[0, 1]`). No other test changed. The suite takes about 17 minutes on this machine.
- Issue #290 and its `**Claude:**` comment (verified on this branch; the line references hold).
- `lib/mutineer/mutators/base.rb:29-37`: operators skip a nested `def` on the outer subject (#157).
- `test/runner_test.rb:166-180`: a nested mutant is emitted once, on the inner subject.
- `lib/mutineer/isolation.rb:206-284` (`apply_surgical`), `lib/mutineer/runner.rb:279-290` (`preload_owners`).
