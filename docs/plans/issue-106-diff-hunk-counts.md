---
title: "Issue #106: correct unified diff hunk counts for multi-line mutations"
type: fix
date: 2026-10-05
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# Issue #106: correct unified diff hunk counts for multi-line mutations

**Goal:** The JSON `survivors[].diff` header states the real number of removed and
added lines, so `git apply --check --unidiff-zero` accepts every survivor diff.

**Closes:** #106 · **Depth:** Lightweight

## Problem Frame

`Reporter#survivor_json` always writes `@@ -N +N @@`. That header means "one line
removed, one line added". A statement-removal mutant of a two-line call removes two
lines and adds one, so the header is wrong and `git apply` rejects the patch as corrupt.

## Requirements

- R1. The hunk header carries the line counts of the original block and the mutated block.
- R2. A mutated block that is empty is one empty line (the block stops before its
  final newline), so it emits one empty `+` line. Before, it emitted no `+` line.
  (Found during implementation: a block never has zero lines.)
- R3. Single-line diffs stay byte-identical (`@@ -3 +3 @@`), so current consumers see no change.
- R4. The regression test checks the patch with `git apply`, not only a header string,
  and checks that the applied result equals `Mutation#apply`.

## Key Technical Decisions

- **Count lines from the blocks `diff_for` already returns.** `diff_for` slices whole
  lines without the final newline, so the block's lines are those of `block + "\n"`.
  The same list builds the `-`/`+` body, so header and body always agree.
- **Write `,N` only when N is not 1.** `-3 +3` and `-3,1 +3,1` mean the same. Keeping
  the short form for the common case keeps existing reports identical (R3).
- **No change to `diff_for`, the HTML report, or the human report.** They show the blocks,
  not a hunk header.

## Implementation Units

### U1. Hunk header from real line counts

**Files:** `lib/mutineer/reporter.rb`, `test/json_reporter_test.rb`, `docs/json-schema.md`

**Approach:** In `survivor_json`, compute old and new line counts from the two blocks.
Build each header range as `start` or `start,count`. Update the `diff` row in
`docs/json-schema.md` to say the header carries line counts.

**Test scenarios:**
- A two-line call removed by `statement_removal`: the header is `@@ -N,2 +N @@`, and
  `git apply --check --unidiff-zero` in a temp git repo with the original file succeeds.
- Applying that diff produces the same file content as `Mutation#apply`.
- A single-line comparison mutant keeps `@@ -3 +3 @@` (existing assertion stays).
- A mutation that empties a line: one empty `+` line, and `git apply` accepts it.
- A replacement that ends in a newline: the `+` side counts the extra line.
- A UTF-8 source line keeps the correct line number and content.

**Verification:** The new tests pass and `git apply` accepts every generated diff.

## Scope Boundaries

- In scope after plan review: a mutant on the last line of a file with no final newline
  (for example an endless `def`) adds `\ No newline at end of file` after both sides.
- No change to the JSON schema version: the `diff` key and its meaning stay the same.
