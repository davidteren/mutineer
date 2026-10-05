---
title: "Issue #104: normalize source paths before test pairing"
type: fix
date: 2026-10-05
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# Issue #104: normalize source paths before test pairing

**Goal:** `lib/calc.rb`, `./lib/calc.rb`, and the absolute path of the same file all
pair with the same test and schedule the same work once.

**Closes:** #104 · **Depth:** Lightweight

## Problem Frame

`Pairing.expand_sources` makes directory arguments root-relative, but passes a file
argument through as typed. `Pairing.logical_path` then looks for an `app/` or `lib/`
prefix. `./lib/calc.rb` and `/abs/project/lib/calc.rb` do not have that prefix, so the
CLI reports "no test found by convention" and exits 2.

## Requirements

- R1. Relative, `./relative`, absolute-inside-project, and `..`-containing spellings
  of one file infer the same test.
- R2. Two spellings of one file given together run that file once.
- R3. Directory expansion and an explicit `--test` keep working.
- R4. A source outside the project root keeps the path the user typed. It is not
  remapped into the project.

## Key Technical Decisions

- **Text-based normalization, not `ProjectPath.relative`** (changed after code review).
  `ProjectPath.relative` follows a symlinked source to its target, which renamed
  `lib/calc.rb` to its target and paired the wrong test. `File.expand_path` resolves
  `./` and `..` as text. The root's real path, and then the file's real directory
  with its own name kept, are tried so the macOS `/var` vs `/private/var` alias matches.
- **Normalize file arguments in `expand_sources`, before `uniq`.** All later steps
  (existence check, pairing, the run) then see one spelling, and `uniq` removes
  duplicates (R2).
- **Keep the typed path when the file is missing or outside the root** (R4), so the
  "no such file" message shows what the user typed.
- **The directory branch uses the same helper,** so a directory run and a file
  argument always agree on one name.

## Implementation Units

### U1. Root-relative file arguments

**Files:** `lib/mutineer/pairing.rb`, `test/pairing_test.rb`, `test/cli_test.rb`, `CHANGELOG.md`

**Approach:** Add a text-based `root_relative` helper and use it in both branches of
`expand_sources`. A file argument that exists inside the root becomes its root-relative
path; otherwise the original argument stays. `..` resolves as text, the same way
`FileSwap` and the daemon read paths. Update the docstrings.

**Test scenarios:**
- `./lib/calc.rb` expands to `lib/calc.rb`, and `infer_tests` finds `test/calc_test.rb`.
- The absolute path inside the root expands to `lib/calc.rb`.
- `lib/../lib/calc.rb` expands to `lib/calc.rb`.
- `lib/calc.rb` and `./lib/calc.rb` together expand to one entry.
- A path outside the root (`../other/x.rb`) comes back unchanged.
- A missing file keeps the typed path (under a symlinked temp root such as macOS
  `/var`, the missing file cannot resolve), and the CLI still reports it as missing.
- Directory expansion results stay the same (existing tests).

**Verification:** The new pairing tests pass, and the existing CLI auto-pair tests stay green.

## Scope Boundaries

- Visible effect (from plan review): the JSON `file` value and the diff `a/<file>`
  header show the root-relative path, not the typed spelling. The CHANGELOG says so.

- A symlinked source keeps its own name (tested).
