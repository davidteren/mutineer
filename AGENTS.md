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

- **`yard:strict` requires 100% documentation, including private methods AND
  constants.** Every new method and constant needs a YARD docstring / `#` comment
  or CI fails.
- **Rails-dependent tests run via `bundle exec rake test:daemon`**, never the
  zero-dep default. The gem's own suite stays Rails-free; `test/fixtures/rails_app`
  has its OWN bundle. `rake test:daemon` runs in the rails-integration CI job.
- Subprocesses use plain `bundle exec` — never hardcode `rbenv exec` (breaks CI and
  non-rbenv users).

## CI gates that block merge

`yard:strict` · `test` (×2 OS) · `rails dogfood` + daemon integration · socket/gitguardian.

## Releasing (tag-driven — CI publishes, no manual `gem push`)

Semver: **new feature → minor bump, fix → patch.**

1. On a branch, bump `lib/mutineer/version.rb` and move the `CHANGELOG.md`
   `## [Unreleased]` block into a dated `## [X.Y.Z] - YYYY-MM-DD` section.
2. Merge to `main`.
3. Tag and push — this is the whole release trigger:
   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```
4. `.github/workflows/release.yml` then: guards `tag == Mutineer::VERSION`, runs
   tests, publishes to RubyGems via **Trusted Publishing** (OIDC — no API key, no
   OTP), and cuts the GitHub release from the CHANGELOG section.

Safety nets:
- The **tag must equal `Mutineer::VERSION`** or the release aborts.
- `.github/workflows/release-pr.yml` **auto-opens a release PR** (bumps `version.rb`,
  dates the CHANGELOG + adds its reference-link def) when `feat:`/`fix:` commits sit on
  `main` past the latest tag — so a merge without a release can't slip by. Review + merge
  it, then push the `vX.Y.Z` tag. (To get CI on that auto-PR, add a `RELEASE_PR_TOKEN`
  PAT secret — a PR opened by the default `GITHUB_TOKEN` doesn't trigger other workflows.)

**One-time setup (required for the publish to work):** register a Trusted Publisher
on <https://rubygems.org/gems/mutineer> → owner `davidteren`, repo `mutineer`,
workflow `release.yml`, no environment. Without it, `release.yml`'s `gem push` fails.

## Score-model discipline (don't regress this)

`score = killed / (killed + survived)`. `no_coverage`, `uncapturable`, `ignored`,
`skipped`, `errored` are ALL excluded from the denominator. Empty denominator → `nil`,
never `0.0`. The exact-survivor integration oracle must stay green.

## Repo mechanics

- `docs/plans/` is gitignored by a global rule — plan docs need `git add -f`.
- A git hook auto-branches commits made directly on `main`; commit on a feature branch.
