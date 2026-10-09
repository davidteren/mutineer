# Stability contract

This file says what a Mutineer release promises not to break.
Mutineer uses Semantic Versioning.
A breaking change waits for the next major version.
The current release is 2.0.0.

## What SemVer covers

| Contract | Version field today | A minor release keeps |
| --- | --- | --- |
| CLI flags | the flags in `mutineer --help` | the flag and its meaning |
| Exit codes | `0`, `1`, `2`, and `3` | which result uses which code |
| JSON schema | `schema_version` `2.0` | existing keys and their meaning |
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
| `1` | The tests are too weak. The score is below `--threshold`, or a `--baseline` regression. |
| `2` | Usage error (mistyped flag, unknown config key, bad path, unreadable baseline, or a baseline with no id_format). |
| `3` | The run could not give a trustworthy result. A red unmutated suite, a daemon boot or provisioning failure, a runtime error, an empty full scan, or more than one mutant with no verdict when they exceed 10% of those attempted. |
<!-- /contract:exit-codes -->

Exit 1 means the tests are too weak.
Exit 3 means the run is not trustworthy.

### Config keys

These keys are accepted in `.mutineer.yml` in 2.0.0:

`operators`, `jobs`, `threshold`, `only`, `require`, `boot`, `rails`, `since`,
`framework`, `verbose`, `ignore`, `baseline`, `fail_fast`, `matrix`,
`test_command`, `daemon`, `timeout`, `capture_timeout`, `cache_dir`,
`allow_empty`.

`format`, `strategy`, `output`, `baseline_epsilon`, and `dry_run` are flags only.
They are not config keys.

### Action inputs

These inputs exist on the GitHub Action in 2.0.0:

`sources`, `test`, `since`, `threshold`, `baseline`, `baseline-epsilon`,
`operators`, `framework`, `strategy`, `jobs`, `rails`, `format`, `output`,
`extra-args`, `working-directory`, `use-bundler`, `version`.

## 2.0 changes

Each item below is the behaviour of 2.0.0, except the last one.
That last item is not in this release.

- **Strict operator names and config keys.** An unknown operator name exits 2.
  An unknown config key exits 2.
  That includes an unknown key inside an `ignore:` mapping.
  The message names the bad name and the closest valid name.
- **Empty full scans fail.** A full scan with zero mutants exits 3.
  Pass `--allow-empty` when an empty run is expected.
  An empty `--since` run stays a success.
- **Exit code 3.** An untrustworthy run exits 3.
  Exit 1 stays the code for tests that are too weak.
- **Old ids stop matching.** An old `ignore:` id does not suppress its mutant.
  A full scan warns once per unmatched id and names `mutineer migrate`.
  A `--since` run does not warn.
  A baseline with no `id_format` exits 2.
  Generate a new baseline with `--format json`.
  `mutineer migrate` still rewrites `ignore:` entries.
- **JSON `schema_version` 2.0.** Reports use `schema_version` `2.0`.
  `summary.legacy_id_matches` is gone.
- **Provisioning failure exits 3.** A daemon that fails to boot exits 3.
  A worker database that cannot be provisioned is the same boot failure.
- **Parallel `--rails` by default, with the `reload` strategy.** Not in this release.
  `--rails` without `--daemon` stays serial and uses `redefine`.
  RSpec stays serial.
  This change waits for a later release.

## Release rhythm after 2.0

Patch releases ship when a fix needs them.
At most one minor release ships per month.
The owner still has to confirm that number.
The weekly release pull request stays.
It opens when `feat:` or `fix:` commits sit on `main` past the latest tag.
