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
- **Never release without a maintainer's yes.** Do not push a `v*` tag, merge
  a release PR, run a release workflow, or `gem push` on your own. You may
  suggest a release. Cut it only after a maintainer agrees to that release,
  and then do only steps 1 to 4 of the release procedure in "Releasing".

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
6. A person merges. Never merge your own pull request unless a maintainer asks. A maintainer's yes to a release covers that release's pull request (see "Releasing").

Agents use a person's GitHub account. Start every agent comment or reply with its bold name, such as `**Codex:**`.
Post findings on the relevant code line, never in a separate summary comment.

**Stacked pull requests:** start at the bottom. When a lower pull request changes, update those above it and recheck new lines.

## Releasing (manual, a maintainer approves each release)

Nothing in this repo releases, tags, or publishes on a schedule or from a bot
trigger. Pushing a `vX.Y.Z` tag leaves the gem unpublished. v1.7.0 shipped
because that tag push started `release.yml` with no approval gate. Keep a tag
push from starting a publish: do not add a `schedule`, a `workflow_run`, or a
tag-push trigger to either release workflow.

A person may start a release workflow only when GitHub reports them as a
human collaborator with maintain or admin on this repository. The workflow
reads that from the collaborator permission API at runtime. Adding a
maintainer is a GitHub permission change. The workflow file does not name
anyone. Write, triage, and read cannot start a release. Bots cannot either.
The legacy API field `permission` maps the maintain role to `write`, so the
check uses `user.permissions.maintain`, `user.permissions.admin`, and
`role_name` of `admin` or `maintain`.

**Release policy for agents (issue #357):**

1. An agent never cuts or publishes a release on its own. Release steps are:
   push a `v*` tag (including the floating major tags `v1`, `v2`, …), merge a
   `release/v*` pull request, run `.github/workflows/release-pr.yml` or
   `.github/workflows/release.yml` (`gh workflow run`, the Actions UI, or
   another workflow), run `gem push`, or create a GitHub Release.
2. An agent may suggest a release now and then. It does steps 1 to 4 of the
   release procedure below only after a maintainer agrees in chat to that
   release. One yes covers one release, not later ones. Step 5 (approve the
   `rubygems` environment) and
   step 6 (move the floating major tag) stay with the maintainer.
   Before step 1, the agent checks that the `rubygems` environment exists,
   has required reviewers, and does not let administrators bypass them. If
   not, the agent stops and tells the maintainer, because `release.yml` would
   refuse to publish and leave the release half done.
   An agent runs `gh` under a maintainer's account, so the actor check above
   passes for it. The chat yes is the control for agents, not that check.
3. For an urgent bug or a security fix, the agent asks a maintainer if the fix
   should go out in a release now, without waiting for the next batch. It does
   not release without that answer.
4. Other work waits for the next batch. Label each pull request with the next
   version label, such as `v1.8.0` (see "Labels" above).
5. A breaking change stays a **draft** pull request. Label it
   `breaking change` and the possible major version, such as `v2.0`.

A schedule is not a substitute: GitHub records a cron run's actor as the
last person who edited the workflow, and that person may be a maintainer, so
a permission check would not stop a cron. The schedule is deleted. Do not add
it back, and do not run `gh workflow enable` to restore a Monday release.

Semver: **new feature → minor bump, fix → patch.** A behavior change to the
GitHub Action's defaults is a **major** bump: consumers pin `@v<major>`, and a
default flip must never reach them without opting in.

The release procedure. A maintainer owns every step. An agent may do steps
1 to 4 after that maintainer agrees to this release:

1. Prepare the pull request when they want a batch, from `main`:
   ```sh
   gh workflow run release-pr.yml --ref main
   ```
   `release-pr.yml` runs only for a `workflow_dispatch` started by a human
   with maintain or admin. It bumps `lib/mutineer/version.rb`, dates the
   CHANGELOG, and opens a PR. It does not tag or publish. It rebuilds
   `release/vX.Y.Z` from current `main` only when `main` has moved. A run
   that finds the branch already based on current `main` leaves that branch
   as it is. It still dispatches `ci.yml` when
   the push used `GITHUB_TOKEN` (issue #234). That dispatch runs tests only.
2. Review and merge that PR. Merging leaves the gem unpublished.
   Leave repository auto-merge off.
3. Tag the merged commit and push the tag:
   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```
   A tag push leaves the gem unpublished. It does not start `release.yml`.
4. Publish from that tag, with the confirm word:
   ```sh
   gh workflow run release.yml --ref vX.Y.Z -f confirm=publish
   ```
   The publish job starts only when the actor is a human with maintain or
   admin, the event is `workflow_dispatch`, the ref is a tag, and `confirm`
   is `publish`. It also refuses when the `rubygems` environment is missing,
   has no required reviewers, or lets administrators bypass them (GitHub
   turns that bypass on by default). Both checks run before the job asks for
   environment approval.
5. Approve the `rubygems` GitHub environment when Actions asks. That approval
   publishes. The job then checks the tag against `Mutineer::VERSION`, runs
   tests, pushes the gem with Trusted Publishing, and creates the GitHub
   Release.
6. Move the floating major tag (`v1`, `v2`, …) so `uses: …@v<major>`
   follows the latest release in that line. Until you do, `@v<major>` users
   stay on the previous release. The run's last step prints the command, with
   the commit it published, in the log and in the run summary. `<commit>` is
   `git rev-parse vX.Y.Z^{commit}`:
   ```sh
   git fetch origin && git tag -f v<major> <commit> && git push -f origin v<major>
   ```
   The job does not move it: the floating-tag ruleset (below) lets only
   maintainers do that. For a patch on an older line (v1.2.4 after v1.3.0),
   the run prints no command and says to leave `v1` where it is. The printed
   command is right only until the next release in that line: do not run an
   old one, or `v1` moves backward.

If the publish job fails after `gem push`, that version is already on
RubyGems and a new dispatch stops at `gem push`. Finish by hand from the
tag: `gh release create vX.Y.Z --verify-tag --notes-file <notes>`, then
step 6.

While one person is the only required reviewer, that person may start the
workflow and approve it. Once a second maintainer is a required reviewer,
turn on the environment's **Prevent self-review** option so the approver is
someone other than the starter. Leave that option off until then: if it is
on while only one reviewer can approve, that reviewer cannot approve their
own run, and the publish cannot finish. The workflow does not enforce the split.

Safety nets:

- The **tag must equal `Mutineer::VERSION`**, and it must be a stable
  `vMAJOR.MINOR.PATCH` tag, or the job aborts before `gem push` and prints
  no command to move the floating major tag.
- **The publish job builds the dispatched commit.** If the tag points at a
  different commit by the time the approval comes, the job aborts before
  `gem push`.
- **`release-pr.yml` opens a PR only when a maintainer runs it.** It never
  replaces a release branch that holds someone else's commits, or that has a
  PR it did not open (it leaves that branch alone with a warning), and it
  never closes a release PR it did not open. A merge commit counts as someone
  else's commit: GitHub's "Update branch" button pauses the next rebuild
  until that PR is merged or its branch is deleted. If `VERSION` on `main`
  differs from the latest tag, the run warns and opens nothing. If the
  computed `vX.Y.Z` tag already exists on origin, it fails and a maintainer
  resolves it by hand.
- **CI on the release PR** still needs a dispatch when the branch was pushed
  with the default `GITHUB_TOKEN`: that push starts no other workflow, so the
  job dispatches `ci.yml` on the release branch and those runs report the
  required checks on the PR's head commit. With an optional `RELEASE_PR_TOKEN`
  PAT secret, the push triggers CI itself and the dispatch is skipped. If the
  checks are missing, run `gh workflow run ci.yml --ref release/vX.Y.Z`. That
  command runs CI only.

**Settings a maintainer applies by hand.** They live in GitHub and on
RubyGems, not in this repo. Apply them in this order. The
workflow checks hold only for the `release.yml` stored in the tag. A dispatch
on a tag runs that tag's copy, so a write collaborator could tag a commit
with an edited copy that skips them. Until these settings exist, nothing
stops that tag. Issue #354 deferred them on 2026-10-26, so they are not
applied today. Item 1 is still needed before the next publish: `release.yml`
refuses to publish while the `rubygems` environment is missing, has no
required reviewers, or lets administrators bypass them.

A `v*.*.*` tag on a commit whose `release.yml` still triggers on tag push
(any commit from before this change) still starts that old workflow. This file
cannot edit those commits. Requiring the `rubygems` environment on the
trusted publisher makes that old `gem push` fail, because the old job omits
`environment:`.

1. Create the GitHub environment `rubygems`. Required reviewers are the
   maintainers, not one named account. On an organization repository, use a
   team such as `release-maintainers` whose members have maintain or admin.
   On a personal repository, teams are unavailable, so list the individual
   users who have maintain or admin. Adding a person later is a team or
   reviewer change, not a workflow change. Turn off "Allow administrators to
   bypass configured protection rules", so an admin cannot skip the approval.
   Leave **Prevent self-review** off until at least two of those reviewers
   exist, then turn it on. Under deployment branches and tags, choose
   "Selected branches and tags" and allow only tags matching `v*.*.*`. An
   unrestricted policy would let a run from a branch, with an edited
   `release.yml`, ask for the same approval. Leave "Protected branches only"
   unset: the publish job runs on a tag, and that policy would block it. Create this environment before any publish run. GitHub
   otherwise creates a missing environment with no required reviewers. The
   authorize job refuses that state, so a publish fails until the reviewers
   exist.
2. On <https://rubygems.org/gems/mutineer>, edit the Trusted Publisher for
   the GitHub account that owns this repository, repo `mutineer`, workflow
   `release.yml`. Set the GitHub Actions environment name to `rubygems`. The
   new workflow's OIDC token carries that environment. Do this after the
   required reviewers are saved. From then on, a workflow whose job omits
   `environment:` cannot `gem push`, and a run of the new workflow waits for
   a reviewer.
3. Add a tag ruleset for `v*.*.*`. Its bypass list is the repository roles
   Maintain and Admin, not a named user. It blocks create, update, and
   delete, so a write collaborator cannot push or move a release tag.
4. Add a second tag ruleset for the floating major tags (`v[0-9]` and
   `v[0-9][0-9]`). Action users pin `@v1`, so a write collaborator who moves
   it changes the code they run, with no release. Block create, update, and
   delete, so nobody plants a `v2` before the first v2.0.0 release. Check
   that the ruleset's target list shows `v1` after you save it.
   Its bypass list is Maintain and Admin only. Do not add the GitHub Actions
   app: any workflow a write collaborator pushes could then move the tag.
   So the publish job does not move the tag. It prints the command, and a
   maintainer runs it (step 6) after the gem is on RubyGems. Leave
   auto-merge disabled (`allow_auto_merge` is false today).

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
