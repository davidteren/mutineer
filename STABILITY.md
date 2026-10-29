# Stability contract

This file says what a Mutineer release promises not to break.
Mutineer uses Semantic Versioning.
A breaking change waits for the next major version.
This file describes Mutineer 1.8.0.
The latest published version is on [RubyGems](https://rubygems.org/gems/mutineer).

## What SemVer covers

| Contract | Version field today | A minor release keeps |
| --- | --- | --- |
| Commands | `run`, `init`, `triage`, `migrate` | the command and its meaning |
| CLI flags | the flags in `mutineer --help` | the flag and its meaning |
| Exit codes | `0`, `1`, and `2` | which result uses which code |
| JSON schema | `schema_version` `1.9` (1.7.0 reports `1.8`) | existing keys and their meaning |
| Mutant ids | `summary.id_format` `2` | the same id for the same mutant |
| Config keys | the `.mutineer.yml` keys below | the key and what a value means |
| Action inputs | the `action.yml` inputs below | the input and its meaning |

A minor release may add a command, a flag, a key, an input, or a JSON key.
It does not remove one or change what an existing one means.
A fix to how Mutineer names a method can change the ids of mutants in that
method, and of a method with the same name in the same file.
The CHANGELOG names each such fix.
The JSON rules are in [docs/json-schema.md](docs/json-schema.md).
The JSON `schema_version` is not the gem version.
Each number moves on its own.

### Exit codes

<!-- contract:exit-codes -->
| Code | Meaning |
|------|---------|
| `0` | Score ≥ threshold (or no gate) **and** no baseline regression. |
| `1` | Score below `--threshold`, OR nothing could be scored and something broke, or more than one mutant produced no verdict and they exceed 10% of those attempted, OR a `--baseline` regression, OR a runtime error, including a boot, source or `require:` file that raises while loading. |
| `2` | Usage / invalid-flag error, including a mistyped flag, a bad path (such as a missing `--boot` or `require:` file), or an unreadable baseline. |
<!-- /contract:exit-codes -->

Exit code 3 does not exist in 1.x.

### Config keys

These keys are accepted in `.mutineer.yml` in 1.8.0:

`operators`, `jobs`, `threshold`, `only`, `require`, `boot`, `rails`, `since`,
`framework`, `verbose`, `ignore`, `baseline`, `fail_fast`, `matrix`,
`test_command`, `daemon`, `timeout`, `capture_timeout`, `cache_dir`,
`allow_empty`, `shared_databases`.

`shared_databases` is new in 1.8.0.
It is a file key with no flag.
Parallel workers with it need Rails 7.1 or later.
On Rails 7.0, every parallel mutant scores `error`.
Listing the primary database exits 2.

`shared_databases` is new after 1.7.0. It is not in a release yet.

`allow_empty` is new in 1.7.0.
An `ignore:` entry can be a mapping with an `id` and an optional `reason` from 1.7.0.
An older version does not ignore the mutant a mapping names, and it does not warn.

`format`, `strategy`, `output`, `baseline_epsilon`, `dry_run`, and
`coverage_from` are flags only.
They are not config keys.

`--coverage-from FILE` is new in 1.7.0.
It has no `.mutineer.yml` key.
When the capture in FILE cannot be reused, the run exits 2.
That covers a capture that does not fit this run, a malformed file, and a file
that cannot be read.

### Action inputs

These inputs exist on the GitHub Action in 1.8.0:

`sources`, `test`, `since`, `threshold`, `baseline`, `baseline-epsilon`,
`operators`, `framework`, `strategy`, `jobs`, `rails`, `format`, `output`,
`extra-args`, `working-directory`, `use-bundler`, `version`.

## 2.0 changes

Each item below is a planned break.
It is not the behaviour of 1.8.0.
Each item says whether 1.8.0 warns about it.
Where it prints no warning, the item says documented only.

- **Strict operator names and config keys.** 1.8.0 warns.
  Today an unknown operator name warns and is skipped.
  An unknown config key warns and is ignored.
  The warning names the closest valid name.
  A `.mutineer.yml` warning says that 2.0 makes it an error.
  In 2.0 both become errors.
- **Empty full scans fail.** 1.8.0 warns.
  Today a full scan with zero mutants exits 0 and warns on stderr.
  In 2.0 that run fails.
  Pass `--allow-empty` (or `allow_empty: true`) when an empty run is expected.
  It stops the warning in 1.8.0 and keeps the run a success in 2.0.
  A `--since` run whose changes hold no mutants stays a success.
- **Exit code 3.** Documented only.
  1.x has no exit 3.
  It prints no warning about one.
  In 2.0 an untrustworthy run exits 3.
  Exit 1 stays the code for tests that are too weak.
- **Old ids stop matching.** 1.8.0 warns.
  An old `ignore:` entry that matches a mutant warns that it uses the old id format, which did not include the file path.
  An old baseline whose ids match this run warns that the baseline uses the old id format.
  In 2.0 those old ids stop matching.
  Run `mutineer migrate` to rewrite old `ignore:` entries.
  Regenerate a baseline with `--format json`.
- **JSON `schema_version` 2.0.** Documented only.
  No run warns about this bump.
  The schema page already says a breaking change bumps the major version.
  1.8.0 reports `schema_version` `1.9`.
- **Parallel `--rails` by default, with the `reload` strategy.** 1.8.0 warns.
  Today `--rails` without `--daemon` is serial and uses `redefine`.
  A Minitest `--rails` run with no `daemon` value prints a notice.
  Pass `--no-daemon` (or `daemon: false`) to keep the run serial and stop the notice.
  In 2.0, Minitest `--rails` runs in parallel with `reload`.
  RSpec stays serial.
- **Provisioning failure moves from exit 1 to exit 3.** Documented only.
  1.8.0 does not warn about that move.
  Today a daemon that fails to boot exits 1.
  A worker database that cannot be provisioned scores those mutants as `error`.
  With `--threshold`, that run can also exit 1.
  In 2.0 a provisioning failure exits 3.

## Release rhythm

There is no weekly release pull request.
A maintainer opens one by hand when they want a release.
Pushing a tag leaves the gem unpublished until a maintainer approves the publish.

## Release rhythm after 2.0

Patch releases ship when a fix needs them.
At most one minor release ships per month.
The owner still has to confirm that number.
