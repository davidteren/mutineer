---
title: "Issue #163: escape control characters in the human report"
type: fix
date: 2026-10-05
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# Issue #163: escape control characters in the human report

**Goal:** The human report never writes a raw terminal control byte from the source.

**Closes:** #163 · **Depth:** Lightweight

## Problem Frame

`Reporter#survivor` prints the token, the replacement, and the diff lines as they are
in the source. A control byte (for example ESC) in a surviving line reaches the terminal
and can change what it shows. The JSON and HTML reports already escape text.

## Requirements

- R1. Control characters in the survivor token, replacement, and diff lines print as
  visible escapes (ESC prints as `\e`).
- R2. Tab stays as it is. Newlines never reach these strings (lines are chomped).
- R3. JSON and HTML output do not change.
- R4. A survivor line with an invalid UTF-8 byte after the token does not crash the report.

## Key Technical Decisions

- **One private helper in `Reporter`** that replaces each control character except tab
  with its `String#dump` escape. Ruby's `[[:cntrl:]]` covers C0, DEL, and C1 controls.
- **Scrub invalid bytes first.** Plan review said Prism rejects invalid UTF-8, but code
  review showed Prism accepts it inside a comment, so a Latin-1 byte after the token
  crashed the new regex. `scrub` keeps the report working.
- **Apply it to source text and file paths in the human report** (paths added after
  code review: a file name can hold a control byte too).
- **Read the text as UTF-8 before scrubbing** (code review): under `LANG=C`, `File.read`
  tags source US-ASCII, and `scrub` alone would turn valid UTF-8 into `?`.

## Implementation Units

### U1. Escape source text in human survivor entries

**Files:** `lib/mutineer/reporter.rb`, `test/reporter_test.rb`, `CHANGELOG.md`

**Approach:** Add the helper with a YARD docstring. Wrap the token, the replacement, and
each diff line in `survivor` with it.

**Test scenarios:**
- A survivor line that contains `"\e[2J"` in a string: the human output has no ESC byte
  and shows `\e[2J`.
- A tab in a survivor line prints as a tab; DEL, CR and a C1 control print as escapes.
- A control character in the token and replacement is escaped on the Operator line.
- A Latin-1 byte in a comment after the token does not crash the report.
- The JSON report for the same run keeps the raw character, JSON-escaped as before.
- Existing human report tests stay green.

**Verification:** The new test passes, and no human output line contains a control byte.
