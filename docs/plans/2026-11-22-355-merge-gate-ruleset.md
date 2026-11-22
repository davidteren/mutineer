---
title: Gate merges on validation with a ruleset on main - Proposal
type: chore
date: 2026-11-22
issues: [355]
---

# Gate merges on validation with a ruleset on main

Status: proposed. Nobody has applied it. A maintainer applies it with the
command in "Apply it". Until then, `main` keeps its current branch protection.

## Goal

Anyone can open a pull request. `main` refuses a merge until the agreed checks
pass on the pull request's head commit and every review thread is resolved.
The gate lives on GitHub, so it applies to every contributor, human or agent,
on every machine.

## What `main` requires today

Branch protection on `main` requires four checks: `test (ruby 3.4 on
ubuntu-latest)`, `test (ruby 3.4 on macos-latest)`, `yard strict (ruby 3.4)`
and `rails dogfood (ruby 3.4)`. It requires an up-to-date branch and resolved
conversations. It does not apply to admins (`enforce_admins` is false), so an
admin can merge with red or missing checks.

`AGENTS.md`, "CI gates that block merge", lists more gates than that: Minitest
6, Prism 2, the website tests, Socket and GitGuardian. CI runs those jobs on
every pull request, but nothing on GitHub stops a merge when they fail.

## The proposal

One repository ruleset, `main merge gate`, stored in
`.github/rulesets/main-merge-gate.json`. It targets the default branch and has
no bypass list.

| Rule | Setting | Why |
|---|---|---|
| Required status checks | Every job in `ci.yml` (12 checks), plus `GitGuardian Security Checks` and `Socket Security: Pull Request Alerts` | Each job checks something the gate list in `AGENTS.md` names. A job that is not required can fail and still merge. |
| Check source | Each check is pinned to the app that reports it (GitHub Actions, GitGuardian, Socket) | Another app or a workflow cannot post a fake green status with the same name. |
| Up-to-date branch | On (`strict_required_status_checks_policy`) | The checks must pass on a head commit that already contains current `main`. This is how a run proves it tested the commit that merges. |
| Pull request | Required, 0 approvals, review threads must be resolved | Every change goes through a pull request. Every human or bot review thread is answered and resolved before merge. No approval count, because the only maintainer cannot approve their own pull request. |
| Deletion, force push | Blocked | `main` keeps its history. |
| Bypass | Nobody | An admin merge past the checks is the gap this closes. A maintainer who must merge anyway in an emergency disables the ruleset, merges, and enables it again, so the bypass is visible in the ruleset history. |

Not required, and why:

- **cubic and Qodo.** They are review bots. They can skip a pull request (no
  quota, a bot author). Their findings arrive as review threads, and the
  thread-resolution rule already blocks a merge until each one is answered.
- **The local review skills** (ce-code-review, fit-review, the local cubic
  CLI). They run on one person's machine and report nothing to GitHub, so
  GitHub cannot check them. They stay part of the author's routine in
  `AGENTS.md`, "PR review gate".
- **`Socket Security: Project Report`.** It reports on the whole project, not
  on what the pull request changes.

The old branch protection can stay. GitHub applies both, and the stricter rule
wins. A maintainer can delete it later, once the ruleset has worked for a few
merges.

## Effect on the release pull request

A release pull request opened with the default `GITHUB_TOKEN` needs a
maintainer to approve its parked `pull_request` CI run (issue #234, and
`AGENTS.md`, "CI on the release PR"). While the optional `RELEASE_PR_TOKEN`
secret is unset, that approval is the only way to merge it under this ruleset: the admin merge past red checks no longer works. Socket
and GitGuardian already report on release pull requests (#294 shows both).

## Apply it

A maintainer with admin on the repository runs this from a checkout of `main`
that contains the ruleset file. It creates the ruleset once:

```sh
gh api -X POST 'repos/{owner}/{repo}/rulesets' --input .github/rulesets/main-merge-gate.json
```

Then check it: open a pull request, and confirm that its merge box lists the
14 required checks.

After a change to a job name in `ci.yml` (for example the threshold in
`self-dogfood (threshold 85)`), `test/merge_gate_ruleset_test.rb` fails until
the JSON file matches. That pull request cannot merge while the applied
ruleset still requires the old name, because CI no longer reports it. So,
once its CI runs are green, a maintainer applies the pull request's copy of the
file first, from a checkout of that branch, and then merges:

```sh
id=$(gh api 'repos/{owner}/{repo}/rulesets' --jq '.[] | select(.name == "main merge gate") | .id')
gh api -X PUT "repos/{owner}/{repo}/rulesets/$id" --input .github/rulesets/main-merge-gate.json
```

After the update, other open pull requests report the new name only once
they are rebased on `main`. The up-to-date rule asks for that rebase anyway.

## Out of scope (the local hook part of #355)

The local hook `pre_pr_gate_guard.sh` lives in one maintainer's
`~/.claude/hooks`, outside this repository. Issue #355 also covers it: it
blocks `gh pr create` on one machine, not a merge.
This change does not touch it. Once the ruleset is on, the maintainer can
retire the hook or limit it to a reminder.
