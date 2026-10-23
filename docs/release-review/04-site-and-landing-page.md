# Landing page and site: analysis and recommendations

No site page was edited. Each item says what is wrong or missing, why it
matters, and a suggested fix. Priorities as in file 01: **P0** before the tag,
**P1** with the release or right after, **P2** later.

The site was read from the source in `docs/` and from the live site on
2026-10-23. The live home page has the same sections as `docs/index.html`, with
the production-ready section spliced in from the README.

## What works

- **The hero and the specimen teach the idea.** "A passing test is a claim"
  and the `qty >= 10` → `qty > 10` specimen, with its hidden killing test, are
  the clearest explanation in the project.
- **The evidence strip shows the score formula** with real numbers.
- **The operator table matches the code** row for row (checked against
  `mutineer --list-operators`).
- **The Mutant comparison is fair.** It names Mutant's strengths and dates the
  check.
- **The machine-readable side is unusually complete:** Markdown twins,
  `llms.txt`, `llms-full.txt`, `agents.txt`, a sitemap, and the skill card.
- **Accessibility basics are in place:** a skip link, landmarks, labelled
  table regions, and animations that respect `prefers-reduced-motion`.

## 1. The site runs ahead of the gem

**P1. The most important item in this file.**

`pages.yml` deploys on every push to `main`. RubyGems serves the last tag. So
between releases the site documents code nobody can install. Today, with 1.6.0
on RubyGems, the live site and README describe `mutineer init`,
`mutineer triage`, `mutineer migrate`, reasons on `ignore:` entries,
`--allow-empty`, and Postgres and MySQL worker databases. None of these exist
in 1.6.0. A user who follows the Rails rollout guide today fails at its first
command, `mutineer init --rails`. The API reference has the same problem: it is
built from `main` but labelled with `Mutineer::VERSION`.

Tagging 1.7.0 closes the gap. The next feature merge opens it again.

Options, in order of preference:

1. **Deploy Pages when a release is tagged**, not on every push to `main`.
   Add `push: tags: ['v*']` to `pages.yml`, keep `workflow_dispatch` for doc
   fixes that should go out between releases, and drop the push-to-main
   trigger. Docs-only fixes then go out by a manual run.
2. **Show the version on the site.** A small "Docs for 1.7.0" label in the
   header, built from `Mutineer::VERSION` at `site:build`. When `main` is ahead
   of the last tag, say "main (unreleased)" instead. This helps with either
   trigger.
3. **Mark new features with the version that adds them** ("1.7+"), as the
   README already does for `ignore:` mappings. This works without changing the
   deploy, but it is easy to forget.

For 1.7.0 itself: after the tag, check that the live API page and
`llms-full.txt` show 1.7.0 and the new README.

## 2. "Ruby ≥ 3.4 is the only requirement"

**P1.** Install section: "Ruby ≥ 3.4 is the only requirement."

In-process runs fork, so Mutineer also needs Linux or macOS. A Windows user
reads "the only requirement" and finds out later. Suggested text: "Ruby 3.4 or
later on Linux or macOS. Point Mutineer at your source and the tests that cover
it."

## 3. "Parallel by default" and "across all your cores"

**P1.** How it works ("Every mutant runs your suite in a forked, isolated
process — across all your cores") and the Fork isolation card ("parallel by
default").

That is true for plain Ruby projects. Under `--rails` without `--daemon`, and
with `--test-command`, Mutineer runs one worker. A Rails team, the audience of
the Rails guide, reads "parallel by default" and then sees a serial run.
Suggested text for the card: "Each mutant runs in its own forked process on
Linux and macOS, in parallel across your cores. Rails apps run in parallel with
`--daemon`, which gives each worker its own test database."

## 4. Rails guide: `since: origin/main` on a shallow checkout

**P1.** `docs/rails.md` and `rails.html`, "GitHub Actions": "For the pull
request gate, set `since: origin/main` and `baseline: .mutineer/baseline.json`."

The recipe's checkout has no `fetch-depth: 0`. The Action's own description of
`since` says an explicit ref must resolve in the checkout and needs
`fetch-depth: 0`. On `pull_request` events the Action already scopes the run to
the PR's base commit when `since` is unset. So the advice either fails to find
the ref or does more than needed. Suggested text: "For the pull request gate,
set `baseline: .mutineer/baseline.json`. On `pull_request` events the Action
scopes the run to the PR's changed lines by itself; leave `since` unset."

The same page also does not say how to create `baseline.json`. The agent and CI
guide does (`--no-since --format json --output .mutineer/baseline.json` on
`main`). Link to it or copy the one command.

## 5. Rails guide: GitLab and `origin/main`

**P2, verify first.** The GitLab recipe runs
`--since origin/main`. GitLab merge-request pipelines usually fetch only the
pipeline's own ref, so `origin/main` may not exist in the job. This was not run
on GitLab. If it fails, add `git fetch origin "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME"`
before the run and pass `--since "origin/$CI_MERGE_REQUEST_TARGET_BRANCH_NAME"`,
or use `$CI_MERGE_REQUEST_DIFF_BASE_SHA`.

## 6. Agent and CI guide: suppression is from before 1.7

**P1.** `docs/agentic-coding.*`, "Avoiding infinite loops".

It shows only a bare id under `ignore:`. 1.7 adds a reason on the inline marker
(`# mutineer:disable-line comparison -- why`), the `{ id:, reason: }` mapping,
and `mutineer triage`, which prints those entries from a JSON report. For an
agent this is the right tool: it records why a mutant was silenced, so a human
can review it. Suggested addition:

```yaml
ignore:
  - id: 9f2a1c4b7e0d
    reason: Calculator#scale — `* 1` and `/ 1` are equal here
```

and: "`mutineer triage .mutineer/run.json --reason TEXT --id ID` prints the
entry. A mapping needs Mutineer 1.7 or later in every gate that reads the file."

## 7. The landing page does not show what is new in 1.7

**P1.** The features grid and the Rails card predate the daemon's database
support.

- **Rails-aware card:** add `--daemon` and per-worker databases on SQLite,
  PostgreSQL, and MySQL 8, and link the Rails guide.
- **Get started:** `mutineer init` (or `init --rails`) is now the easiest first
  step. Consider making it the first command after `gem install`.
- **Equivalent mutants:** a card or a line under "How it works" for reasons on
  ignored mutants and `mutineer triage`, linking the Skips page.

## 8. Newcomer path

**P1.** See [03-explaining-mutation-testing.md](03-explaining-mutation-testing.md#recommendations-for-the-site)
for the "Mutation testing, explained" page, the "New to mutation testing?" hero
line, and matching the report's words.

## 9. Navigation and footer

**P2.**

- The header nav has eight entries. On a narrow screen that is a lot before
  the content. Consider grouping JSON schema, API, and Sample report under
  "Reference".
- The footer lists "AI & CI recipes", "JSON schema", and "API" but not
  "Rails" or "Skips". Make it match the header, or list every page.
- Add "Changelog" and "Stability" links (to the files on GitHub). People who
  are deciding whether to adopt the tool look for both.

## 10. The production-ready section on the home page

**P2.** The section comes from the README at build time. On the landing page it
is a 40-line block of short sentences under the matrix, and many repeat a table
row ("PostgreSQL with Minitest can use `--daemon`."). It sits between the hero
and "How it works", so a newcomer meets database parallelism before learning
what a mutant is.

Options: move the splice point below "How it works", or shorten the README
prose under the matrix (which shortens both places). The matrix itself is good.

## 11. Assets

**P2.**

- **Explainer video captions.** No `<track>` element. Add WebVTT captions and a
  short transcript (see file 03, item E).
- **OG image size.** `og-image-20260908.png` is 732 KB. Social cards do not need
  that; an optimised PNG or a JPEG around 100 to 200 KB loads faster for
  crawlers that time out.
- **Video weight.** The MP4 is 4.9 MB with `preload="none"`, so it costs
  nothing until played. Fine as it is.

## 12. External claims

**P2.** The hero proof quotes Stephen Margheim's results and links his post on
X. The numbers could not be checked from this environment. If the post is ever
deleted, the claim loses its source; keep a dated note of where the numbers
came from in the repo. Re-check the Mutant comparison before each minor release.

## Summary table

| # | Item | Priority | Pages |
| --- | --- | --- | --- |
| 1 | Site documents unreleased features; deploy on tag and show the version | P1 | `pages.yml`, all |
| 2 | "Ruby ≥ 3.4 is the only requirement" leaves out Linux or macOS | P1 | Landing |
| 3 | "Parallel by default" is not true for `--rails` without `--daemon` | P1 | Landing |
| 4 | `since: origin/main` on a shallow checkout; no baseline step | P1 | Rails |
| 5 | GitLab `origin/main` may not exist | P2, verify | Rails |
| 6 | Suppression guidance predates reasons and `triage` | P1 | Agent and CI |
| 7 | 1.7 features missing from the landing page | P1 | Landing |
| 8 | Newcomer page, hero line, report words | P1 | Landing, new page |
| 9 | Nav grouping, footer links, Changelog and Stability links | P2 | All |
| 10 | Production-ready block placement and length | P2 | Landing, README |
| 11 | Video captions, OG image size | P2 | Landing |
| 12 | Source for the hero claim; re-check the Mutant comparison | P2 | Landing |

When an operator is added, update the badge count, the heading ("Twenty-one
ways"), the Tier-2 count in the lede, the operator table, `docs/index.md`, and
`docs/llms.txt`. #276 did this for `call_to_receiver`. The new contract test
lists any page it finds missing.
