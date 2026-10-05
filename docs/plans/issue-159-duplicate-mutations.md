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
- R3. The fix covers every operator, including the two that override `mutations_for`
  (`return_nil`, `chain_link`).

## Key Technical Decisions

- **Compare the span from the earliest mutation start to the latest mutation end**
  (changed after plan review). The first draft compared the `def` text, but a heredoc
  body of an endless `def` lies past the `def` node, so a mutation can sit outside it.
  Text outside the span is the same for every mutation, so comparing the span is exact
  and avoids a full copy of the file per mutation.
- **One private `Base` helper,** run next to `drop_dangling_heredocs` in `Base` and in
  `ReturnNil`. `ChainLink` calls `super`, so it gets the fix from `Base`.
- **Id effect.** Ids count same-token twins in order. Dropping a duplicate removes its
  id, and a later twin of the same token can get a lower ordinal. This affects only
  opt-in operators with these duplicates. The CHANGELOG says so.

## Implementation Units

### U1. Drop same-result mutations in Base

**Files:** `lib/mutineer/mutators/base.rb`, `lib/mutineer/mutators/return_nil.rb`,
`test/mutators/literal_mutation_test.rb`, `test/mutators/negation_removal_test.rb`,
`test/mutators/chain_link_test.rb`, `CHANGELOG.md`

**Approach:** Add a `Base` helper that keeps the first mutation for each mutated span. Call it in `Base#mutations_for`
and `ReturnNil#mutations_for`.

**Test scenarios:**
- `x = 0` with `literal_mutation`: replacements are `["1"]`, one entry.
- `x = 5`: replacements stay `["0", "1", "6"]`.
- `!!x` with `negation_removal`: one mutation, applied source `!x`.
- `!x`: still one mutation.
- `a.b.b.c` with `chain_link` gives one mutation; `a.b.x.c` keeps both links.
- Existing mutator round-trip tests stay green.

**Verification:** The updated tests pass and the full suite stays green.
