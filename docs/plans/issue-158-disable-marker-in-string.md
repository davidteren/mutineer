---
title: "Issue #158: recognize the disable-line marker only in a comment"
type: fix
date: 2026-10-05
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# Issue #158: recognize the disable-line marker only in a comment

**Goal:** The text `# mutineer:disable-line` inside a string no longer silences that line.
A real comment marker keeps working.

**Closes:** #158 · **Depth:** Lightweight

## Problem Frame

`Runner.suppress_map` runs a regex over each source line. A string such as
`"# mutineer:disable-line"` matches, so every mutant on that line is ignored and drops
out of the score.

## Requirements

- R1. A marker inside a string, heredoc, or regex does not suppress the line.
- R2. A marker in a `#` comment still suppresses its line, with or without an operator list.
- R3. The unknown-operator warning and its line number stay the same.

## Key Technical Decisions

- **Read comments from `Parser.parse_string`** (the repo's Prism boundary; changed from `Prism.parse_comments` after code review). Prism ships with Ruby 3.4 (the gem has zero runtime
  dependencies) and already parses this source. It returns each comment with its line, so a string never counts.
- **Only inline (`#`) comments.** An `=begin`/`=end` block spans many lines, and the
  marker is documented as a line comment.
- **Keep the existing regex,** applied to the comment text instead of the whole line.
  The parsing of the operator list does not change.

## Implementation Units

### U1. Comment-only marker detection

**Files:** `lib/mutineer/runner.rb`, `test/equivalent_mutant_test.rb` (where the
existing `suppress_map` tests live), `CHANGELOG.md`

**Approach:** In `suppress_map`, iterate the inline comments from `Prism.parse_comments`
instead of the source lines. Use each comment's start line as the key. Update the docstring.

**Test scenarios:**
- The issue's example (`value == "# mutineer:disable-line"`) gives an empty map.
- `x == 1 # mutineer:disable-line` gives `{line => :all}`.
- `x == 1 # mutineer:disable-line comparison` gives `{line => Set[:comparison]}`.
- A heredoc body line with the marker text gives no entry.
- An unknown operator in a real comment still warns with the right line.

**Verification:** New tests pass and the existing suppress tests stay green.
