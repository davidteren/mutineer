---
title: "Issue #159: drop a mutation that repeats an earlier result"
type: fix
date: 2026-10-05
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# Issue #159: drop a mutation that repeats an earlier result

**Goal:** One operator never emits two mutations on one subject that produce the same
source, so one edit is never scored twice.

**Closes:** #159 · **Depth:** Lightweight

## Problem Frame

`literal_mutation` on `0` emits `"1"` twice (the "change to 1" rule and the "add 1"
rule). `negation_removal` on `!!x` removes each `!`, and both give `!x`. `chain_link`
does the same on `a.b.b.c`: dropping either `.b` gives `a.b.c`. Each copy gets its own id, so a survivor counts twice.

## Requirements

- R1. Within one operator and one subject, a mutation whose result equals an earlier
  mutation's result is dropped. The first one is kept.
- R2. Mutations that give different results all stay.
- R3. The fix covers every operator.
- R4. Every kept mutant keeps the id it had before the fix. A dropped copy's id is
  never handed to another mutant (found in code review: dropping before ids are
  assigned let the next same-token twin take the dropped copy's id, so an old ignore
  entry would silently hide a different mutant).

## Key Technical Decisions

- **Compare the span from the earliest mutation start to the latest mutation end**
  (changed after plan review). The first draft compared the `def` text, but a heredoc
  body of an endless `def` lies past the `def` node, so a mutation can sit outside it.
  Text outside the span is the same for every mutation, so comparing the span is exact
  and avoids a full copy of the file per mutation.
- **Drop in `Runner.collect_jobs`, after ids are assigned** (changed after code review;
  the first version dropped in `Mutators::Base`). `collect_jobs` is the only caller of
  `mutations_for`, and ids count same-token twins over the full list, so dropping after
  that keeps every id stable (R4). The key is `[operator, span text]`, so the drop stays
  per operator.
- **Mutator unit tests keep pinning both emissions,** because the mutators still emit
  them. A runner test pins the drop and the ids.

## Implementation Units

### U1. Drop same-result mutations after ids are assigned

**Files:** `lib/mutineer/runner.rb`, `test/runner_test.rb`, `CHANGELOG.md`

**Approach:** Add `Runner.repeated_results`, which returns the indexes of mutations
that repeat an earlier mutation of the same operator. `collect_jobs` skips those
indexes after it computes ids.

**Test scenarios:**
- A subject with `x = 0`, `y = 0` and `!!x`, run with `literal_mutation` and
  `negation_removal`: three jobs (`x = 1`, `y = 1`, `!x`), no two with the same
  operator and mutated source.
- Every kept job's id equals the id that mutant had over the full, undeduplicated list.
- The test fails when the drop is disabled.
- Existing mutator tests (which still pin both emissions) stay green.

**Verification:** The new runner test passes and the full suite stays green.
