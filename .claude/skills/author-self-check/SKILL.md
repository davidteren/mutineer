---
name: author-self-check
description: Check your own Mutineer branch before the first push, for the defects review bots found most often on earlier pull requests (docs that omit a mode, consumers left out of date, stale doc copies, weak tests, untracked limitations). Use before you push a branch or open a pull request in this repo, and on each commit that fixes a review finding.
---

# Author self-check

Run this before the first push of a branch. It asks the questions that review
asked most often on 259 earlier pull requests, so you answer them first. It
does not replace CI or the review bots.

Base: `origin/main`, or the lower pull request in a stack.

## 1. Run the mechanical checks

```sh
ruby .claude/skills/author-self-check/self_check.rb origin/main
```

In a stack, pass the lower pull request's branch instead of `origin/main`.

It checks committed changes only, so commit first. Deal with each item it
lists before you go on:

- An added line that names a limitation ("not yet", "deferred", "TODO") with
  no issue number. Add the issue, or create one with its labels (AGENTS.md,
  "Labels"). If your own new code gives a silent wrong verdict, fix it in
  this branch and do not file it for later. The script exits 1 until
  every such line has one. It matches keywords only, so also look for
  limits worded as "only", "stays", "ignores" or "same rule as".
- A test file that loses assertions, or gains a skip or a timeout. Give the
  reason for each in the pull request body.
- Doc sync: a sentence you removed or changed that another doc still has, and
  a `docs/X.md` whose `docs/X.html` twin you did not change. Answer every
  line in the receipt: "updated", or "differs because ...". A copy marked
  "named in rake/" may be built by that task: rebuild it, do not edit it.
  Do not dismiss the list as noise. It finds stale copies in files the diff
  does not touch, which a reading of the diff misses.

## 2. Hand the judgment checks to a fresh reviewer

You wrote the code, so you will miss the same things twice. Start a subagent
that has not seen this session. Give it the base and head commits, the issue
the branch closes, and steps 3 to 6 of this file. Ask it to quote the file and
line for every finding, and to list what it could not judge.

With no subagent tool, do steps 3 to 6 yourself, and say so in the receipt.

## 3. Read the decision records

Read `.expectation-fit/ways-of-working.yaml`, and for each area the diff
touches, its file in `.expectation-fit/decisions/` where that folder exists.
Check the diff against each line that applies.

## 4. Check the paths that differ

For each changed behaviour, check two things:

- Every output and exit path: stdout, stderr, the `--output` file, each
  `--format`, `--dry-run`, `--fail-fast`, an empty run, and each early or
  error exit. Does every path write, count and exit the same way? Where the
  same count is printed in two places, is it the same number?
- Every guard and cache that skipped the old behaviour: a check with
  `unless dry_run` or a similar mode test, a coverage cache hit,
  `--coverage-from`, `--since` and `--baseline`. When a mode starts writing
  a file or running a step, each guard that skipped that mode must now hold
  for it. Can an old verdict, map or report hide the new behaviour, or can the
  new code overwrite one of them?

A path that differs needs code and a test, or an issue, and the docs name it.

- Bad: "`--timeout` sets the time limit for each mutant." (Which backend?)
- Good: "`--timeout` sets the time limit for each mutant in in-process runs.
  `--daemon` and `--test-command` ignore it." (pull request 437)

## 5. Trace every consumer

For each new or changed value, option, status, config key or JSON field,
search for its name and for the old sentences that describe it:

```sh
git grep -n -e '<name>' -e '<a phrase from the old sentence>' -- lib docs README.md CHANGELOG.md action.yml '*.md'
```

Check each hit that reads the value or states the behaviour: validation and
allowlists, `case` and `if` chains, each reporter (human, JSON, HTML) and its
summary counts, the flag and config tables, the JSON schema rows and
examples, the Action inputs, the operator descriptions, and rules in
AGENTS.md or STABILITY.md that state the old behaviour.

A new value that falls through to a default is a bug until shown otherwise.
Trace the value to the place that uses it, not to the place that builds it.
Example (pull request 71): a cleaned list of environment variables was applied
to a copy, so Bundler variables still reached the test process.

## 6. Check the tests and the sentences

Tests:

- A regression test asserts the mechanism: the owner, the arity, or the name
  of the test that killed the mutant. "killed", "passes" or an exit code alone
  is not enough.
- A test does not depend on time, locale, platform, file order or `/proc`.
- A loop of cases has no `skip`, `next` or early `return` that hides the
  cases after it.
- Where the change takes a path or option, test the rows that apply: `..` and
  a result outside the project root, a symlink, glob characters, a literal
  `~`, a non-ASCII name, a missing folder, a repeated option, an environment
  variable that overrides the flag.

Sentences the diff adds to docs, the CHANGELOG, help text, error messages and
code comments:

- Run every command and code example the diff adds to the docs. It must work
  as written. If you cannot run it, trace it through the code.
- For each sentence about behaviour, write the case where it is false: a
  mode, an input, an older version, a custom receiver, an error path. If
  such a case exists, name the condition in the sentence or change it. Most
  review findings on this repo were sentences that were true only in the
  common case.
- A new option or input names the first version that has it.
- A code comment gives the reason or the contract, not the history.
- If you cannot make a sentence true, delete it.

## 7. Write the receipt

Write `.mutineer/self-check.md` (git-ignored) with the head commit, the
answer to each doc-sync line, the paths from step 4 that differ, the decision-record lines you could not satisfy, the
reviewer's findings and what you did with each, and the "could not judge"
list. Copy the open items into a "Self-check" section of the pull request
body.

## When you fix a review finding

Run step 1, then steps 4 and 6 on the fix commit only. Change the least text
that fixes the finding, and add no new claims: new text in fix commits caused
most findings in later review rounds. Fix P1 and P2 findings. Reply to a P3
nit with the reason you leave it, unless the fix is one line. Stop after three
rounds and ask the maintainer.
