# AGENTS.md — working on the mutineer gem

Conventions for any agent or contributor changing this repo. (Usage docs for
*consumers* live in `README.md` and `docs/`; this file is about developing the gem.)

## Non-negotiables

- **Zero runtime dependencies — Prism + stdlib only.** Never add a runtime gem.
  Dev-only deps (minitest, rake, yard) are fine. Ruby **≥ 3.4** (Prism ships with it).
- **No `eval`.** Removed in 0.6.1 (supply-chain scanner flag). The redefine strategy
  `load`s a tempfile snippet instead — don't reintroduce `eval`.
- **Least astonishment.** Names match behaviour, no hidden side effects, explicit
  failures over silent ones. Match the surrounding code's idiom.

## Before every commit (local gate)

```sh
bundle exec rake test                          # zero-dep suite
ruby -Ilib -e 'require "mutineer"'             # load smoke
bundle exec rake yard:strict                    # 100% documented — see below
```

The default `Gemfile` pins Minitest 5. For changes to the Minitest
integration, also run the suite on Minitest 6:

```sh
BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/minitest6.gemfile bundle exec rake test
```

- **`yard:strict` requires 100% documentation, including private methods AND
  constants.** Every new method and constant needs a YARD docstring / `#` comment
  or CI fails.
- **Rails-dependent tests run via `bundle exec rake test:daemon`**, never the
  zero-dep default. The gem's own suite stays Rails-free; `test/fixtures/rails_app`
  has its OWN bundle. `rake test:daemon` runs in the rails-integration CI job.
- Subprocesses use plain `bundle exec` — never hardcode `rbenv exec` (breaks CI and
  non-rbenv users).

## Website checks

For changes to the GitHub Pages site or its tests, also run:

```sh
bundle exec rake site:build
node --test test/site_test.js
npm ci --prefix test/browser
npx --prefix test/browser playwright install chromium
npm test --prefix test/browser
```

`rake site:build` writes the published tree to `_site/` — the YARD API docs,
`sitemap.xml`, `llms-full.txt`, and `json-schema.html` are build artifacts, not
committed files under `docs/`. The checks above read `_site/`, so build first.

These development-only checks require Node.js 22+, npm, and Python 3.
Playwright starts a local server on port 8766; keep that port free so the
checks run against this checkout. The gem and its default Rake suite remain
independent of Node and Playwright. CI runs these checks in `website browser tests`.

## CI gates that block merge

`yard:strict` · `test` (×2 OS) · `test (minitest 6)` · `rails dogfood` + daemon integration · `website browser tests` · socket/gitguardian.

## PR review gate (before any merge)

Every pull request must meet this gate on its current head, including stacks, docs-only, and "small" changes.
Only a maintainer may waive a step, in writing on that pull request.

### Before opening a new pull request

On the exact pull request head commit:

1. Run "Before every commit" checks, plus website checks for site changes.
2. Review your diff against the pull request base (`main`, or the lower pull
   request in a stack). Verify every claim and number against its source.
3. Never push or open a pull request with a red suite.

After another commit, repeat these checks on the new head.

### Labels

Label every pull request, except the release pull requests that
`release-pr.yml` opens:

| Category | Required |
|---|---|
| Type | `bug`, `enhancement`, `documentation`, `dependencies`, or `github_actions` |
| Issue and matching labels | Name the issue it closes, if any, with `Closes #N` in the body. Add matching labels, such as `priority: high` (high priority) or `risk: medium` (medium risk). |
| Target release | Use a version label, such as `v1.8.0` or `v2.0`. Tentative targets are acceptable. |

Use existing labels only (`gh label list`). Ask a maintainer before adding a new label.

### After the pull request is open

1. Wait for CI, review bots (cubic and Qodo), and other required checks to finish on the head commit.
2. Read every human and bot review comment. Fix valid findings or explain why they are wrong.
3. Reply before resolving each thread. Name the fix commit, explain a decline, or name the GitHub issue tracking a deferral. Create that issue if needed.
4. After fixes, push and check the new lines again.
5. Require green GitHub checks on the head commit.
6. A person merges. Never merge your own pull request unless a maintainer asks.

Agents use a person's GitHub account. Start every agent comment or reply with its bold name, such as `**Codex:**`.
Post findings on the relevant code line, never in a separate summary comment.

**Stacked pull requests:** start at the bottom. When a lower pull request changes, update those above it and recheck new lines.

## Releasing (tag-driven — CI publishes, no manual `gem push`)

Semver: **new feature → minor bump, fix → patch.** A behavior change to the
GitHub Action's defaults is a **major** bump: consumers pin `@v<major>`, and a
default flip must never reach them without opting in.

1. On a branch, bump `lib/mutineer/version.rb` and move the `CHANGELOG.md`
   `## [Unreleased]` block into a dated `## [X.Y.Z] - YYYY-MM-DD` section.
2. Merge to `main`.
3. Tag and push — this is the whole release trigger:
   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```
4. `.github/workflows/release.yml` then: guards `tag == Mutineer::VERSION`, runs
   tests, publishes to RubyGems via **Trusted Publishing** (OIDC — no API key, no
   OTP), cuts the GitHub release from the CHANGELOG section, and force-moves the
   floating major tag (`v1`, `v2`, …) to the release so `uses: …@v<major>`
   consumers track the latest in that line.

Safety nets:
- The **tag must equal `Mutineer::VERSION`** or the release aborts.
- **Releases are batched, not cut per merge.** `.github/workflows/release-pr.yml` runs
  weekly (Monday 08:00 UTC) and on demand (`gh workflow run release-pr.yml`). When
  `feat:`/`fix:` commits sit on `main` past the latest tag, it opens a release PR (bumps
  `version.rb`, dates the CHANGELOG + adds its reference-link def). Each run rebuilds that
  PR from the current `main`, so it always covers every change since the last tag; a
  newer version supersedes an older open release PR, and when `main` moved the same
  version is re-opened fresh (the old branch is deleted under a lease, never
  force-pushed). The run never replaces a release branch that holds someone else's
  commits, or that has a PR it did not open (it leaves that branch alone with a
  warning), and it never closes a release PR it did not open. A merge commit counts as
  someone else's commit: GitHub's "Update branch" button on the release PR pauses the
  automation until that PR is merged or its branch is deleted. Review + merge it, then push the
  `vX.Y.Z` tag. Every release moves the floating major tag (`v1` today), so Action users get it at once:
  batch changes rather than releasing after each merge. CI runs on that auto-PR with no
  secret: a push by the default `GITHUB_TOKEN` starts no other workflow, so after
  pushing the release branch the job dispatches `ci.yml` on it, and those runs report
  the required checks on the PR's head commit. With an optional `RELEASE_PR_TOKEN` PAT
  secret, the push triggers CI itself and the dispatch is skipped. If the checks are
  missing, run `gh workflow run ci.yml --ref release/vX.Y.Z`.
- **The release-PR run stops (and opens nothing) in two cases.** If `VERSION` on `main`
  differs from the latest tag, a bump is merged but not tagged: it warns you to push
  that tag first. If the computed `vX.Y.Z` tag already exists on origin (for example
  pushed from a branch), it fails and you resolve it by hand.
- **GitHub disables scheduled workflows in a public repo after 60 days without
  activity.** If no release PR appears on a Monday while unreleased `feat:`/`fix:`
  work sits on `main`, check `gh workflow view release-pr.yml` and re-enable it with
  `gh workflow enable release-pr.yml`.

**One-time setup (required for the publish to work):** register a Trusted Publisher
on <https://rubygems.org/gems/mutineer> → owner `davidteren`, repo `mutineer`,
workflow `release.yml`, no environment. Without it, `release.yml`'s `gem push` fails.

## Shift-left rules (from the 2026-10 PR audit)

These rules come from a postmortem of issues #252, #253, and #254 and an
audit of every merged PR. They stop the defect patterns that reached users.
The rule text lives in one place: `.expectation-fit/ways-of-working.yaml`.
Reviewers who use the expectation-fit plugin apply it with `/fit-review`;
every other reviewer, human or bot, applies the same file by hand. Score terms
are defined in "Score-model discipline" below. Issue #282 tracks the remaining
ordering gaps: RSpec random order and Minitest class order across selected files.

The eight rules, by title: **Track every limitation** - **Cover the
siblings** - **Gate on unrounded values** - **Count what you exclude** -
**Estimate exclusion frequency** - **One seed contract** - **Assert the
mechanism** - **Repro becomes fixture**.

## Score-model discipline (don't regress this)

`score = killed / (killed + survived)`. `no_coverage`, `uncapturable`, `unplaceable`, `ran_at_load`, `ignored`,
`skipped`, `errored` are ALL excluded from the denominator. Empty denominator → `nil`,
never `0.0`. The exact-survivor integration oracle must stay green.

A new status for a mutant that exists but could not run ships with a count in the report and a
place in the unrun share (`AggregateResult#unrun_count`, the stderr warning above 10%). A new place
where an operator declines a candidate calls `decline` (`Mutators::Base`), so it is counted in
`summary.declined_by_operator`.
