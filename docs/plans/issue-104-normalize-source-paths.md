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

- **Reuse `ProjectPath.relative`.** It already resolves `./`, `..`, absolute paths, and
  the macOS `/var` vs `/private/var` alias for mutant ids and the coverage cache. One
  path rule for pairing and ids is least surprise.
- **Normalize file arguments in `expand_sources`, before `uniq`.** All later steps
  (existence check, pairing, the run) then see one spelling, and `uniq` removes
  duplicates (R2).
- **Keep the typed path when the result is outside the root** (R4). `ProjectPath.relative`
  returns an absolute path in that case; `expand_sources` uses the original argument instead.
- **Leave the directory branch unchanged.** It already produces root-relative paths.

## Implementation Units

### U1. Root-relative file arguments

**Files:** `lib/mutineer/pairing.rb`, `test/pairing_test.rb`, `test/cli_test.rb`, `CHANGELOG.md`

**Approach:** In the non-directory branch of `expand_sources`, map the argument through
`ProjectPath.relative`. Use the result when it is relative, else the original argument.
Update the method docstring.

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

- A symlinked source inside the project resolves to its target's path, as mutant ids
  already do. No special handling.
