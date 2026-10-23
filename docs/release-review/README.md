# 1.7.0 release review: docs, README, and site

Reviewed on 2026-10-23 against `main` at `9534dc8`, before the 1.7.0 tag.
The last shipped release is 1.6.0 (2026-10-08).

This folder is for maintainers. It is kept in git but is not published to
GitHub Pages: `rake site:build` skips `docs/release-review/`.

## The files

| File | What it covers |
| --- | --- |
| [01-production-readiness.md](01-production-readiness.md) | Is the documentation ready to ship 1.7.0? The release checklist and the blockers. |
| [02-accuracy-audit.md](02-accuracy-audit.md) | Each claim checked against the code, how it was checked, and what was fixed. |
| [03-explaining-mutation-testing.md](03-explaining-mutation-testing.md) | How well the docs teach a newcomer, and the plan to improve it. |
| [04-site-and-landing-page.md](04-site-and-landing-page.md) | Recommendations for the landing page and the Pages site. No site page was edited. |

## Verdict

The docs are accurate about what the code does. The README, the JSON schema,
and the CLI help agree on flags, config keys, exit codes, operators, and the
score model. The checks for that are scripts and tests, listed in the audit.

Three things stood between the docs and a 1.7.0 release. This change fixes the
first two. The third is a site decision for David.

1. **STABILITY.md described 1.6.0.** It named schema `1.7`, lacked
   `allow_empty`, and said 1.7 features (`migrate`, `--allow-empty`, the 2.0
   warnings) did not exist. It now describes 1.7.0, and new tests fail when a
   config key, an Action input, or the schema version drifts from the code.
2. **Nothing explained mutation testing to a newcomer.** The README used the
   words mutant, killed, and survived without defining them; "killed" first
   appeared on line 402. The README now has a "What is mutation testing?"
   section with a real, checked example.
3. **The live site documents unreleased features.** Pages deploys on every push
   to `main`, so the site has shown 1.7 features (`mutineer init`, `triage`,
   MySQL and Postgres worker databases) for two weeks while RubyGems serves
   1.6.0. Tagging 1.7.0 closes the gap for now, and it reopens with the next
   feature merge. See [04-site-and-landing-page.md](04-site-and-landing-page.md#1-the-site-runs-ahead-of-the-gem).

## What this change edits, and what it leaves alone

The rule used: Markdown with no hand-written HTML twin is edited here. A page
with a hand-written HTML twin is part of the site, so it gets recommendations
only.

Edited:

- `README.md`: a mutation-testing primer, a "try it" block, all four commands
  in the usage block, and the wrong site name in the link text
  (`mutineer.github.io` pointed to `davidteren.github.io/mutineer`).
- `STABILITY.md`: brought to 1.7.0.
- `SECURITY.md`: the supported-versions table no longer names a version that
  goes stale at each release.
- `skills/mutineer/SKILL.md`: what an agent does with a survivor it cannot kill.
- `docs/json-schema.md`: the `schema_version` example says `"1.8"`, not `"1.6"`.
- `CHANGELOG.md`: one Unreleased entry for the primer.
- `rake/site_build.rb`: skips `docs/release-review/` when it builds the site.
- Tests: `test/docs_contract_test.rb` checks STABILITY.md and the operator
  lists against the code; `test/site_build_test.rb` checks the skip.

Not edited (recommendations in file 04): `docs/index.html` and `docs/index.md`
(the landing page), `docs/agentic-coding.*`, `docs/rails.*`,
`docs/equivalent-skips.*`, `docs/sample-report.html`, `docs/llms.txt`, and
the site assets.
