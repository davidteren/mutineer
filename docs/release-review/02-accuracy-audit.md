# Accuracy audit: docs against the code

Each row is a claim in the docs, what it was checked against, and the result.
Checks were run with scripts against this checkout, not by reading alone.
Where a check is now a test, the test is named.

Status key: **OK** (matches the code), **Fixed** (fixed in this change),
**Site** (wrong or incomplete on a site page; see file 04), **Not checked**
(an outside fact this review could not verify).

## Contracts

| Claim | Where | Checked against | Status |
| --- | --- | --- | --- |
| Every CLI flag has a row or a mention | README options table | Each `--flag` in `mutineer --help` (37 flags) searched in README | OK |
| Commands are `run`, `init`, `triage`, `migrate` | README usage block | `mutineer --help` | Fixed: the block listed only `run` and `migrate` |
| 20 config keys, including `allow_empty` | README configuration table | `Mutineer::KNOWN_KEYS` | OK |
| Config keys | STABILITY.md | `Mutineer::KNOWN_KEYS` | Fixed: `allow_empty` was missing. Test: `test_stability_lists_every_config_key` |
| 17 Action inputs | STABILITY.md | `action.yml` `inputs` | OK. Test: `test_stability_lists_every_action_input` |
| JSON `schema_version` is `1.8` | STABILITY.md | `Reporter::SCHEMA_VERSION` | Fixed: said `1.7`. Test: `test_stability_names_the_reporter_schema_version` |
| `schema_version` example | `docs/json-schema.md` prose | `Reporter::SCHEMA_VERSION` | Fixed: said `"1.6"` |
| Exit codes 0, 1, 2 | README, STABILITY.md, schema, agent guide, skill | `docs/fragments/contract.yml` | OK. Existing test: `test_every_contract_surface_carries_the_same_exit_codes` |
| 5 default and 15 opt-in operators, by name | README, `docs/index.md`, landing page | `MutatorRegistry::DEFAULT_NAMES`, `TIER2_NAMES`, `mutineer --list-operators` | OK. New test: `test_operator_pages_name_every_registered_operator` |
| Operator rules (for example `% -> *`) | Landing page table | `mutineer --list-operators` text | OK, all 20 rows |
| Score is `killed / (killed + survived)` and `null` when empty | README, landing page, schema | `Result` statuses and the human report's score line | OK |
| Landing page worked score: 24 ÷ (24 + 1) = 96% | Landing page | Arithmetic | OK |
| Self-dogfood badge says at least 85% | README badge | `ci.yml` `--threshold 85` | OK. Existing test |
| Supported Ruby is 3.4 or later | README, site, gemspec | `mutineer.gemspec` `required_ruby_version` | OK |

## Versions named in prose

| Claim | Where | Status |
| --- | --- | --- |
| "The current release is 1.6.0" | STABILITY.md | Fixed: now "describes Mutineer 1.7.0" |
| "1.6.x" supported, "1.6.0 is the current release" | SECURITY.md | Fixed: now "the latest 1.x minor release" |
| "Mutineer 1.7 is the first version that reads a mapping" | README, `docs/equivalent-skips.*` | OK once 1.7.0 ships. Before the tag it describes an unreleased version, which is the site-timing issue in file 04 |
| "1.3 and later" for the new id format | README, schema | OK (CHANGELOG 1.3.0) |

## Links

| Check | Status |
| --- | --- |
| README link text "mutineer.github.io" | Fixed: the link went to `davidteren.github.io/mutineer`, and the text named a site that does not exist |
| Every `github.com/davidteren/mutineer#anchor` link in the README resolves to a README heading (slug rule copied from `test/site_links.py`) | OK, including the new section |
| Site links and anchors | Not run here. `test/site_links.py` checks them in CI on the built `_site/` (the website job) |

## Examples

| Example | Status |
| --- | --- |
| README primer: `Discount#rate` with a `>=` boundary | Run for real with this checkout on 2026-10-23. Before the new test: 2 mutants, 1 killed, 1 survived, score 50.0%, survivor `>= -> >` on line 3. After adding `rate(10)`: 2 killed, score 100.0%. The quoted report lines are copied from that run |
| `mutineer run --dry-run lib/foo.rb` without `--test` | OK: dry run lists mutants without tests |

## Site pages (not edited; see file 04)

| Claim | Where | Status |
| --- | --- | --- |
| "Ruby ≥ 3.4 is the only requirement" | Landing page, Install | Site: in-process runs fork, so Linux or macOS is also required |
| "Every mutant runs your suite in a forked, isolated process — across all your cores", "parallel by default" | Landing page, How it works and Fork isolation card | Site: `--rails` without `--daemon` and `--test-command` run one worker |
| "set `since: origin/main`" for the PR gate | `docs/rails.*`, GitHub Actions | Site: the recipe's checkout is shallow, and `action.yml` says an explicit ref needs `fetch-depth: 0`. On `pull_request` the Action already scopes to the PR base, so the line should say to leave `since` unset |
| GitLab recipe uses `--since origin/main` | `docs/rails.*` | Site, likely: GitLab merge-request pipelines usually fetch only the pipeline ref, so `origin/main` may not exist. Not run on GitLab |
| Equivalent-mutant suppression shows bare ids only | `docs/agentic-coding.*` | Site: incomplete for 1.7. No reasons, no mapping form, no `mutineer triage` |
| "Rails-aware" card | Landing page | Site: incomplete. Says nothing about `--daemon`, per-worker databases, or Postgres and MySQL 8 |

## Outside facts

| Claim | Status |
| --- | --- |
| Mutant 0.17 comparison, "checked on 2026-10-06" | Not checked. Re-check before each minor release, since Mutant's license and features change |
| Stephen Margheim's numbers (17,702 to 8,170 examples, −27% spec lines) | Not checked. The post on X could not be fetched from this environment |

## How to repeat the checks

```sh
# Tests that now hold these contracts
ruby -Ilib -Itest test/docs_contract_test.rb
ruby -Ilib -Itest test/site_build_test.rb

# Flags in --help that the README does not mention
ruby -Ilib bin/mutineer --help | grep -oE -- '--[a-z][a-z-]+' | sort -u |
  while read -r f; do grep -q -- "$f" README.md || echo "missing: $f"; done

# Hard-coded operator counts to update when an operator is added
grep -rn -i "twenty\|20 mutation\|20 (5\|fifteen" README.md docs/*.md docs/*.html docs/llms.txt
```
