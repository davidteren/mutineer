# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [0.6.1] - 2026-06-29

### Changed
- **Removed `eval` entirely** — the redefine strategy now `load`s the wrapped
  method snippet from a tempfile instead of evaluating a string. Behavior is
  identical (top-level load rebuilds the same `Module.nesting`), but the gem no
  longer uses dynamic string execution, clearing supply-chain scanner flags.
  Zero runtime dependencies unchanged.

## [0.6.0] - 2026-06-28

### Added
- **RSpec support** (#6) — `--framework rspec` (or auto-detected when most
  `--test` files end in `_spec.rb`) runs RSpec suites instead of Minitest, via a
  pluggable test-runner abstraction. Both frameworks are loaded lazily, so
  Mutineer keeps zero runtime gem dependencies and works in an rspec-only
  project; coverage selection works for both. `.mutineer.yml` accepts `framework:`.

### Fixed
- **Redefine strategy keeps compact `class A::B` as a single nesting wrapper**
  (#5) — avoids a constant-resolution disagreement with the reload strategy.

## [0.5.0] - 2026-06-28

### Fixed
- **`class << self` methods are now discovered and mutated** (#3) — previously
  they were treated as instance methods, so the redefine strategy mis-targeted
  them. `class << other_obj` blocks are skipped (not representable).
- **Worker pool no longer deadlocks on large results** (#4) — pipes are drained
  with `IO.select` and children reaped on EOF, so a result bigger than the OS
  pipe buffer (~64KB) can't wedge the run.

## [0.4.0] - 2026-06-28

### Added
- **`--since <git-ref>`** (#2) — mutate only the lines changed since a git ref
  (e.g. `--since origin/main`), so CI on a pull request mutation-tests just the
  new/changed code. Composes with coverage selection; `--dry-run --since`
  narrows the preview too. Unknown ref / not-a-git-repo exits 2.

## [0.3.0] - 2026-06-28

### Added
- **Coverage-guided test selection in boot mode** (#1) — `--rails`/`--boot` now
  captures coverage by forking the booted app and runs only the test files that
  cover each mutant's line (uncovered lines report `no_coverage`), instead of
  running every `--test` file for every mutant. Cached like standalone mode.

## [0.2.0] - 2026-06-28

### Added
- **Boot mode for Rails (and any app needing its environment booted)** —
  `--rails` boots `config/environment` once in the parent and forks per mutant
  (children inherit the booted app), defaults the strategy to `redefine`, and
  reconnects ActiveRecord in each fork for DB fork-safety. `--boot FILE` boots a
  custom entry point. Boot mode requires `--test` files and runs them for every
  mutant (coverage-guided selection in boot mode is future work). `.mutineer.yml`
  accepts `boot:` and `rails:`.
- GitHub Actions CI (test suite + gem build on Ruby 3.4, ubuntu + macos).

### Changed
- `--strategy` values are now `reload` / `redefine` (canonical); `7a` / `7b`
  remain accepted as deprecated aliases.

## [0.1.0] - 2026-06-28

### Added
- Initial release of Mutineer — a clean-room, Prism-based mutation-testing tool
  for Ruby with zero runtime dependencies (Ruby ≥ 3.4).
- Mutation operators: arithmetic, comparison, boolean-connector, boolean-literal,
  statement-removal (Tier 1, default); return-nil, literal-mutation,
  condition-negation (Tier 2, opt-in via `--operators`).
- Coverage-guided test selection with a digest-keyed, auto-invalidating cache.
- Fork-isolated, parallel execution (`--jobs`) with per-mutant timeouts.
- Two application strategies: `reload` (whole-file, default) and `redefine`
  (surgical), verified to agree on namespaced multi-statement methods. (`7a`/`7b`
  accepted as deprecated aliases.)
- `run`, `--dry-run`, `--threshold`, `--only`, `--operators`, `--strategy`,
  `--format human|json`, `--output`, `--list-operators`.
- `.mutineer.yml` configuration (CLI > config > default precedence).
- Byte-correct source handling for multibyte (UTF-8) sources.

[0.6.1]: https://github.com/davidteren/mutineer/releases/tag/v0.6.1
[0.6.0]: https://github.com/davidteren/mutineer/releases/tag/v0.6.0
[0.5.0]: https://github.com/davidteren/mutineer/releases/tag/v0.5.0
[0.4.0]: https://github.com/davidteren/mutineer/releases/tag/v0.4.0
[0.3.0]: https://github.com/davidteren/mutineer/releases/tag/v0.3.0
[0.2.0]: https://github.com/davidteren/mutineer/releases/tag/v0.2.0
[0.1.0]: https://github.com/davidteren/mutineer/releases/tag/v0.1.0
