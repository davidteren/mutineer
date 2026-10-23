# Production readiness of the docs for 1.7.0

The question here is narrow: when 1.7.0 ships, will a user who reads the
README, the site, STABILITY.md, and the CHANGELOG get a true picture of what
they installed? The code's own readiness is covered by CI and by the release
validation in the project thread.

Priority labels:

- **P0**: fix before the tag.
- **P1**: fix with the release, or right after it.
- **P2**: worth doing; not tied to this release.

## Release checklist for the docs

Run these in order. Items 1 to 3 are done by this change.

| # | Step | Status |
| --- | --- | --- |
| 1 | STABILITY.md describes 1.7.0: config keys include `allow_empty`, schema `1.8`, commands listed, the 2.0 section says which items 1.7.0 warns about. | Done here |
| 2 | SECURITY.md names no version that goes stale. | Done here |
| 3 | README teaches the terms it uses (mutant, killed, survived, score). | Done here |
| 4 | Decide on the open PRs that change the docs (below), and update STABILITY.md, README, and the landing page for each one that merges. | Done: #271 and #273 merged and are documented |
| 5 | Re-run `release-pr.yml` after the last merge, so the release PR moves the whole `[Unreleased]` block, this entry included. | **P0, open** |
| 6 | After the tag, check the live site: the API page shows 1.7.0, and `llms-full.txt` holds the new README. | **P1, open** |
| 7 | Decide whether Pages deploys from tags (see file 04, item 1). | **P1, open** |
| 8 | Add a short "Highlights" list to the top of the 1.7.0 CHANGELOG section. | **P2, open** |

## PRs that change the docs

| PR | What it changes in the docs |
| --- | --- |
| #273 `--coverage-from FILE` | Merged on 2026-10-23 (it continues contributor PR #247, now closed). #273 added the README options row. This change lists it in STABILITY.md as a flag with no config key that exits 2 when the capture cannot be reused, and adds it to the README's CLI-only list. The landing page's "Key flags" line does not name it; that is fine, since it is a sharding option. |
| #271 `call_to_receiver` operator (contributor) | Merged through #276 on 2026-10-23. The count is now 21 (5 default, 16 opt-in), and #276 updated the README, `docs/index.md`, the landing page, and `docs/llms.txt`. `test_operator_pages_name_every_registered_operator` passes on the merged code, and it will flag the pages to update when the next operator is added. |
| #244, #245 (2.0) | Must stay unmerged for 1.7.0. STABILITY.md's 2.0 section describes them as planned. |

## Findings

### P0: STABILITY.md was out of date (fixed)

The contract file is the promise a release makes, and it was the stalest file
in the repo. It was written after 1.6.0 shipped and said so throughout:

- "The current release is 1.6.0" and "schema_version `1.7`". The code reports
  `1.8` (`lib/mutineer/reporter.rb`, `SCHEMA_VERSION`).
- The config key list had 19 keys. The code accepts 20: `allow_empty` was
  missing (`Mutineer::KNOWN_KEYS`).
- The 2.0 section said "documented only" for three items 1.7.0 now warns about:
  strict names and keys, empty full scans, and parallel `--rails`. It said
  `mutineer migrate` and the `--allow-empty` opt-out were not in the release.
  Both are.
- It did not list the commands (`run`, `init`, `triage`, `migrate`) as part of
  the contract.

STABILITY.md now describes 1.7.0. Three new tests compare it with the code:
every key in `Mutineer::KNOWN_KEYS`, every input in `action.yml`, and
`Reporter::SCHEMA_VERSION`. Run against the old file, two of them fail
(`allow_empty` and schema `1.8`), which is the drift they are meant to catch.

The file still names the release, "This file describes Mutineer 1.7.0". The
release PR bumps `version.rb` and the CHANGELOG but not this line. Either add
STABILITY.md to what `release-pr.yml` updates, or check the line in the
release checklist each time.

### P0: no newcomer explanation (fixed in the README)

See [03-explaining-mutation-testing.md](03-explaining-mutation-testing.md).

### P1: the README is long and front-loads the hard part

The README is 853 lines after this change (715 before). A first-time reader
meets the 40-line Rails support matrix before Install. That order is
deliberate: `test_readme_support_matrix_names_each_database` requires
"Is it production-ready?" to be the first `##` heading, and the site splices
that section into the home page. So the primer sits after it, and the intro
links down to it.

Recommendation: keep the order for 1.7.0. After the release, consider:

- Moving the long `--test-command`, Bootsnap, Redis, and MySQL privilege
  material from the README to the Rails page, and leaving a short summary and
  a link. The README would lose about 150 lines.
- Shortening the prose under the support matrix. It repeats every row of the
  table as a sentence ("PostgreSQL with Minitest can use `--daemon`" and so
  on). The same text appears on the landing page.

### P1: the site runs ahead of the gem

See [04-site-and-landing-page.md](04-site-and-landing-page.md#1-the-site-runs-ahead-of-the-gem).

### P1: two recipe bugs on the Rails page

Both are site pages, so they are recommendations in file 04 (items 4 and 5):
an explicit `since: origin/main` on a shallow checkout, and the GitLab recipe's
`origin/main`.

### P2: CHANGELOG reads as a log, not as release notes

The `[Unreleased]` section is about 220 lines, and the GitHub release body is
cut from it. Each entry is precise, which is right for upgraders. A reader who
wants "what is new" has no short list. Add five or six one-line highlights at
the top of the 1.7.0 section when the release PR is made: `init`, `triage` and
reasons on ignored mutants, `migrate`, Postgres and MySQL worker databases,
`--allow-empty`, and the false-kill and false-survivor fixes.

### P2: a constant in an unexpected place

`KNOWN_KEYS` is defined inside the `Struct.new ... do` block in
`lib/mutineer/config.rb`, so Ruby puts it on `Mutineer`, not on
`Mutineer::Config`. `Mutineer::Config::KNOWN_KEYS` raises `NameError`; the
docs and the comment beside it suggest the latter. It works inside the file
because lookup is lexical. Not a docs issue, but it tripped the new test, so it
is noted here.
