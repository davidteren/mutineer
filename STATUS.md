# STATUS

## Last session handoff

- **What this is:** The 13 Fizzy-report plans, one pull request at a time.
- **What we finished:** The Ruby 3.4 image is downloaded. The SQLite lock probe (#404) failed one case as root.
- **What you do next:** Say whether the normal-user rerun, which passed all 17 cases, is enough to continue #404.

## Open for Claude
- (nothing open)

## Open for Codex
- (nothing open)

## Open for Grok
- #404 is stopped. The plan command, as root, failed case J1 (create a lock file in a read-only directory). The same probe as user 1000 passed all 17 cases. Do not write the lock code until David accepts that rerun.
- Next plan after that answer, or in parallel if he says to leave #404: #388 (name the cause of each errored mutant in JSON). It keeps schema `1.10`. Pull request #391 edits the same daemon method, but it is not a blocker. Do not merge #391.
- Do not merge pull request #395 (the Action asks the CLI for the cache folder). The #381 Action summary line still waits on it.
- Do not merge pull request #405 (how to triage a `present?` survivor), #407 (`--test` file, directory, or glob), #409 (pair a concern with its namespace test), or #411 (sources with no paired test).
- Split names from #379 stay on issue #408. Dry runs with Rails or boot and no test file stay on issue #410.
