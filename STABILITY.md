# Stability contract

This file says what a Mutineer release promises not to break.
Mutineer uses Semantic Versioning.
A breaking change waits for the next major version.
The current release is 1.6.0.

## What SemVer covers

| Contract | Version field today | A minor release keeps |
| --- | --- | --- |
| CLI flags | the flags in `mutineer --help` | the flag and its meaning |
| Exit codes | `0`, `1`, and `2` | which result uses which code |
| JSON schema | `schema_version` `1.7` | existing keys and their meaning |
| Mutant ids | `summary.id_format` `2` | the same id for the same mutant |
| Config keys | the `.mutineer.yml` keys below | the key and what a value means |
| Action inputs | the `action.yml` inputs below | the input and its meaning |

A minor release may add a flag, a key, an input, or a JSON key.
It does not remove one or change what an existing one means.
The JSON rules are in [docs/json-schema.md](docs/json-schema.md).

### Exit codes

<!-- contract:exit-codes -->
| Code | Meaning |
|------|---------|
| `0` | Score ≥ threshold (or no gate) **and** no baseline regression. |
| `1` | Score below `--threshold`, OR nothing could be scored and something broke, or more than one mutant produced no verdict and they exceed 10% of those attempted, OR a `--baseline` regression, OR a runtime error. |
| `2` | Usage / invalid-flag error (mistyped flag, bad path, unreadable baseline). |
<!-- /contract:exit-codes -->

Exit code 3 does not exist in 1.6.0.

### Config keys

These keys are accepted in `.mutineer.yml` in 1.6.0:

`operators`, `jobs`, `threshold`, `only`, `require`, `boot`, `rails`, `since`,
`framework`, `verbose`, `ignore`, `baseline`, `fail_fast`, `matrix`,
`test_command`, `daemon`, `timeout`, `capture_timeout`, `cache_dir`.

`format`, `strategy`, `output`, `baseline_epsilon`, and `dry_run` are flags only.
They are not config keys.

### Action inputs

These inputs exist on the GitHub Action in 1.6.0:

`sources`, `test`, `since`, `threshold`, `baseline`, `baseline-epsilon`,
`operators`, `framework`, `strategy`, `jobs`, `rails`, `format`, `output`,
`extra-args`, `working-directory`, `use-bundler`, `version`.

## 2.0 changes

Each item below is a planned break.
It is not the behaviour of 1.6.0.
Where this release prints no warning, the item says documented only.

- **Strict operator names and config keys.** Documented only.
  This release does not warn that 2.0 will reject them.
  Today an unknown operator name warns and is skipped.
  An unknown config key warns and is ignored.
  In 2.0 both become errors.
- **Empty full scans fail.** Documented only.
  This release does not warn.
  Today a full scan with zero mutants exits 0.
  In 2.0 that run fails.
  An empty `--since` run stays a success.
  The opt-out flag is not in this release.
- **Exit code 3.** Documented only.
  This release has no exit 3.
  It prints no warning about one.
  In 2.0 an untrustworthy run exits 3.
  Exit 1 stays the code for tests that are too weak.
- **Old ids stop matching.** The 1.x warning exists today.
  An old `ignore:` entry warns that it uses the old id format, which did not include the file path.
  An old baseline warns that the baseline uses the old id format.
  In 2.0 those old ids stop matching.
  Use `mutineer migrate` for `ignore:` entries.
  That command is not in 1.6.0.
  Until it ships, copy the new ids from the warning.
  Regenerate a baseline with `--format json`.
- **JSON `schema_version` 2.0.** Documented only.
  No run warns about this bump.
  The schema page already says a breaking change bumps the major version.
  1.6.0 reports `schema_version` `1.7`.
- **Parallel `--rails` by default, with the `reload` strategy.** Documented only.
  This release does not print that notice.
  Today `--rails` without `--daemon` is serial and uses `redefine`.
  In 2.0, Minitest `--rails` runs in parallel with `reload`.
  RSpec stays serial.
- **Provisioning failure moves from exit 1 to exit 3.** Documented only.
  This release does not warn about that move.
  Today a daemon that fails to boot exits 1.
  A worker database that cannot be provisioned scores those mutants as `error`.
  With `--threshold`, that run can also exit 1.
  In 2.0 a provisioning failure exits 3.

## Release rhythm after 2.0

Patch releases ship when a fix needs them.
At most one minor release ships per month.
The owner still has to confirm that number.
The weekly release pull request stays.
It opens when `feat:` or `fix:` commits sit on `main` past the latest tag.
