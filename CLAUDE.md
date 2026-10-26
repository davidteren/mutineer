<!--
AGENTS.md is the source of truth for working on this repo: conventions,
the local gate, CI gates, and the manual release flow. Claude Code does not
follow a Markdown link, so the `@AGENTS.md` import below loads it. The
never-release rule is repeated here so it applies even if that import is skipped.
-->
@AGENTS.md

## Never release

Agents must never push a `v*` tag, merge a release pull request, run
`.github/workflows/release-pr.yml` or `.github/workflows/release.yml`, or
`gem push`. Do not create a GitHub Release. A release needs David's manual
approval (GitHub `davidteren`), including approval of the `rubygems`
environment. Pushing a tag leaves the gem unpublished. When a task needs a
release, tell David the steps in the Releasing section of AGENTS.md. Do not
perform them.
