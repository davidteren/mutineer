# Intent Engineering Review — feat/action-ci-consumer-loop

## Header

- **Scope:** branch `feat/action-ci-consumer-loop` vs merge-base with `main` (`625a130`); reviewed head `2dd9252`; fixes committed as `8b1c632`.
- **Intent:** close the CI-consumer loop on the GitHub Action (auto `--since` on PRs, step summary, survivor annotations, `report` output, progress lines) plus the prior review-hardening commit.
- **Context:** review. **Run id:** `20260816-055742-c63853c9`. **Completed:** 2026-08-16.
- **Config:** defaults (no `.intense/` found, walk-up from repo root). Confidence gate 75. Auto-sources: `ci.yml` (curated; `release*.yml` excluded). No severity_align promotions.
- **Lens team:** predictability + simplicity (always on, session model); convention (ruby stack + AGENTS.md, mid-tier); experience (CLI/Action surfaces in the diff, mid-tier); architecture skipped (`ruby` has no arch pack).
- **Plugin source:** local checkout (latest), not the 0.8.0 cache.

## Applied (committed as `fix(ie-review):` 8b1c632; all gates re-run green)

| # | File | Fix | Lens |
|---|------|-----|------|
| 1 | `action.yml` | Uniform pre-run `rm -f` of the resolved report path: the stale-report hazard existed identically for a caller-set `output` shared across steps, and one unconditional clear is simpler than the auto-only special case | simplicity + predictability (promoted to 100 by cross-lens agreement) |
| 2 | `action.yml` | Scoped-aware baseline line in the step summary: "score-drop check skipped (diff-scoped run … not comparable)" instead of juxtaposing the cross-denominator scores the gem's `scoped:` gate refuses to compare | predictability (P2/75) |
| 3 | `action.yml` | One-line summary fallback when the run dies before writing a report, so the documented surface is never silently blank | experience (P2/75) |
| 4 | `action.yml` | Auto-scope message is now `::notice::` (same Checks-tab visibility as the fallback `::warning::`); ">20 more" pointer names the `report` output; annotation copy reuses the docs' "no test caught this change" (the copy reword was anchor 50, below gate: adopted as an author's choice while editing the same line, not forced by the gate) | experience |
| 5 | `action.yml` | `WORKDIR` renamed `WORKING_DIRECTORY`: the env block mirrors input names exactly; this was the one exception | convention |
| 6 | `CHANGELOG.md` | `### Added` before `### Changed` (file precedent + Keep-a-Changelog example order); "workflows that already pass a **non-empty** `since` are unchanged" (an explicit empty string is indistinguishable from unset) | convention + experience observation |
| 7 | `docs/agentic-coding.md`, `README.md` | Rails example gets the same `since:` explanatory comment as its twin; README splits the migration-relevant default change from the three additive features (mirrors the CHANGELOG's own two-tier shape) | convention, experience |
| 8 | `test/runner_daemon_parallel_test.rb` | Serial run wrapped in `capture_io` so progress lines stop leaking into suite output | predictability observation |

## Findings (open)

### P3 — Minor

| # | File | Issue | Principle | Lens | Conf |
|---|------|-------|-----------|------|------|
| 9 | `CHANGELOG.md` | New entries omit the `(#NN)` issue/PR reference recent entries carry | convention-over-configuration | convention | 75 |

- **#9**: Resolved post-open: the PR opened as #86 and the references were added in commit `bc4ebe4` (all four entries now carry `(#86)`). Kept here because this artifact records the review as it stood at its run id.

## Observations

- Resolved by this PR: the JSON report records `summary.scoped`, and a scoped report is refused as a baseline (exit 2 with a regenerate hint), so the `scoped:` protection is two-directional. A missing `jq` silently skips summary/annotations; a one-line `::notice` would make the absence attributable (predictability, P3/50).
- Predictability verified every field the jq programs consume exists in the JSON schema, and called out the deliberate DWIM asymmetry as correct: auto-since is best-effort (falls back to the stricter full scan), an explicit `since:` stays strict (exit 2).
- Convention verified `Progress` matches sibling idiom exactly and that `jq` in the action is a guarded runner-tool, not a gem dependency.
- Experience noted the progress line has no ETA (fine for its purpose).

## Coverage

- Diff: 11 files, both commits, staged to the run dir; untracked `docs/intent-engineering/` out of scope.
- Lens status: predictability clean (4 findings), simplicity clean (1), convention clean (4; its compact return used non-schema confidence words, the disk artifact was authoritative), experience clean (5).
- Gate: 3 findings suppressed at anchor 50 (one adopted as author's choice, two recorded above). Cross-lens promotion: 1 (stale-clear, 75 to 100).
- Apply verification: zero-dep suite 440 runs green, daemon suite 14 runs green, YARD 100.00%, 7-scenario action harness green.

## Verdict

**Ready with fixes** (all applied except #9, which needs the future PR number). No blocking findings remain.

---

*Postscript (post-open): this report and the audit it references were committed
to `docs/intent-engineering/` in `bc4ebe4` as a deliberate audit trail for
PR #86. The Coverage line above ("untracked docs/intent-engineering/ out of
scope") describes the state at the review's run id, before the commit.*
