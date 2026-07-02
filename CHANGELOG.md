# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.11.0] - 2026-07-02

### Added
- **`--daemon` backend — fast, parallel-safe Rails mutation testing** (#26/#27
  Phase 2). Boots the app **once** in a persistent daemon and forks per mutant
  (restoring shared-boot speed), and gives **each parallel worker its own
  database** so `--jobs N` is safe under Rails for the first time — parallel
  verdicts are proven identical to serial (no fixture cross-talk). Coverage
  narrowing is restored on this path (each mutant runs only its covering tests;
  a mutant on an uncovered line is `no_coverage`), so the daemon score is
  comparable to the in-process `--rails` score. Opt in with `--rails --daemon`
  (also `daemon: true` in `.mutineer.yml`); `--daemon` can't be combined with
  `--test-command`. **SQLite** today (hermetic, CI-proven); **Postgres**
  per-worker provisioning is in progress (#34/#35). The gem core stays Prism +
  stdlib, zero runtime dependencies — worker-DB routing uses the app's own
  ActiveRecord.

## [0.10.0] - 2026-07-02

### Added
- **`--test-command` external backend** (#27) — mutation-test apps pinned to Ruby
  < 3.4. Mutineer stays on ≥ 3.4 but runs your suite as a subprocess in the app's
  own runtime via `--test-command "bundle exec rails test %{files}"` (`%{files}`
  expands to the `--test` paths; env is inherited). The mutant is applied on disk
  with crash-safe backup/restore (self-heals a hard-killed run on next startup); a
  smoke check aborts before scoring if the unmutated suite isn't green. This path
  is reload-only, serial (`--jobs` forced to 1), and does no coverage narrowing —
  so its score is an upper bound, not comparable to an in-process `--rails` score
  (Mutineer prints this caveat). Also settable as `test_command:` in `.mutineer.yml`.
  Safe parallelism for this path is tracked in #26.

## [0.9.1] - 2026-07-01

### Fixed
- **Per-method uncapturable granularity** (#25) — the `:uncapturable` taint was
  whole-file, so a method reachable only by a *failed* capture in an otherwise-
  covered file was mislabeled `no_coverage`. It's now attributed per method (by
  the method's body coverage), so only the affected method is tainted. Fully-
  failed files are unchanged.

## [0.9.0] - 2026-06-30

### Added
- **`--fail-fast`** (#21) — stop at the first surviving mutant; in-flight workers
  drain, the rest are skipped. Fast red signal for PR gates.
- **`--format html`** (#23) — a single self-contained HTML report (inline CSS, no
  external assets) with the score, per-source table, and a card per survivor
  (subject, file:line, operator, stable id, diff).
- **String, regex, and collection-method operators** (#24, Tier-2, opt-in via
  `--operators`): `string_literal`, `regex`, `collection_method`
  (`map`↔`each`, `all?`↔`any?`, `first`↔`last`, `min`↔`max`, `select`↔`reject`).

### Changed
- **`--dry-run` now honors suppression** (#22) — inline `# mutineer:disable-line`
  and `.mutineer.yml` `ignore:` entries are omitted from the preview and counted
  as "ignored (suppressed)", matching a real run.

## [0.8.0] - 2026-06-30

### Fixed
- **Singleton methods are now mutated** (#20) — `class << self` and
  `module_function` methods were discovered but applied to the instance scope, so
  the mutant never ran on the singleton the caller dispatches to; every such
  mutant falsely survived and the file read a false 0%. `module_function` methods
  are now discovered as singletons, and the redefine strategy re-opens
  `class << self` so the mutation lands on the called method. (Scores for
  singleton-heavy files will rise to their true values.)
- **Write-heavy Rails tests are capturable again** (#19) — capture/worker pipes
  are `binmode`: a binary Marshal payload over a text-mode pipe could raise an
  encoding error the child then swallowed → empty pipe → false `:uncapturable`.
  That was the root cause of the residual write-heavy failures too. A child that
  dies without writing now also reports how it died (exit status / signal), and
  `--verbose` always surfaces a real reason. Verified on a real Rails app: all 6
  previously-uncapturable interactors (incl. caxlsx + Google-client) now capture
  with real scores, 0 uncapturable.

## [0.7.1] - 2026-06-30

### Added
- **GitHub Action** (`action.yml`, composite) wrapping the CLI for CI — gate a PR
  on new survivors / score drop with `sources`, `since`, `baseline`, `threshold`,
  etc. Inputs are passed via `env` (no `${{ }}` interpolation into the run script)
  for command-injection safety.
- Docs site (GitHub Pages) with Open Graph / Twitter Card share image; YARD doc
  comments across the library.

## [0.7.0] - 2026-06-30

Rails hardening + CI batch (issues #8–#13), all verified Rails-free.

### Added
- **Equivalent-mutant suppression** (#10) — inline `# mutineer:disable-line [ops]`
  and a `.mutineer.yml` `ignore:` list keyed on a stable, offset-free mutant id;
  suppressed mutants are excluded from the score (100% reachable). The stable id
  (and readable token) is emitted per survivor in JSON.
- **Source→test auto-pairing + multi-source runs** (#11) — pass a directory or
  several sources with `--test` omitted; tests are inferred by convention
  (`app/`,`lib/` → `test/…_test.rb` / `spec/…_spec.rb`) and run under one boot,
  with per-source results (human + JSON `per_source`).
- **`--baseline <file.json>` CI gating** (#13) — diff against a prior run by stable
  id; exit 1 on new survivors or a score drop (with `--baseline-epsilon`), naming
  what regressed. Combines with `--threshold` via max exit code.
- **`--verbose`/`--debug`** (#8) — surface the real error when a fork capture fails.
- **`:uncapturable` status** (#9) — distinct from `no_coverage`; reported separately
  ("tests failed to run" vs "genuinely uncovered"). Both excluded from the score.

### Fixed
- **Fork capture no longer drops fixture transactions** (#8) — `reconnect` skips
  `clear_all_connections!` when a fixture transaction is open, and stops swallowing
  the child error; write-heavy Rails tests are mutation-testable again.

### Changed
- JSON `schema_version` → `1.1` (additive: survivor `id`/`token`, `ignored`,
  `uncapturable`, `per_source`).

## [0.6.2] - 2026-06-29

### Fixed
- **`--rails` defaults `RAILS_ENV` to `test`** (#7) — an unset `RAILS_ENV` booted
  development, where the suite isn't loaded, so every mutant was falsely reported
  `no_coverage` (score N/A, exit 0). An explicit `RAILS_ENV` is respected.
- **`--rails` defaults to `--jobs 1`** (#12) — parallel mutant forks share one
  database and deadlock on transactional fixtures; explicit `--jobs N` opts back
  into parallelism.

### Added
- **Tier-2 operator discoverability** (#14) — the human-format run summary now
  lists the available opt-in tier-2 operators and how to enable them.

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

[0.11.0]: https://github.com/davidteren/mutineer/releases/tag/v0.11.0
[0.10.0]: https://github.com/davidteren/mutineer/releases/tag/v0.10.0
[0.9.1]: https://github.com/davidteren/mutineer/releases/tag/v0.9.1
[0.9.0]: https://github.com/davidteren/mutineer/releases/tag/v0.9.0
[0.8.0]: https://github.com/davidteren/mutineer/releases/tag/v0.8.0
[0.7.1]: https://github.com/davidteren/mutineer/releases/tag/v0.7.1
[0.7.0]: https://github.com/davidteren/mutineer/releases/tag/v0.7.0
[0.6.2]: https://github.com/davidteren/mutineer/releases/tag/v0.6.2
[0.6.1]: https://github.com/davidteren/mutineer/releases/tag/v0.6.1
[0.6.0]: https://github.com/davidteren/mutineer/releases/tag/v0.6.0
[0.5.0]: https://github.com/davidteren/mutineer/releases/tag/v0.5.0
[0.4.0]: https://github.com/davidteren/mutineer/releases/tag/v0.4.0
[0.3.0]: https://github.com/davidteren/mutineer/releases/tag/v0.3.0
[0.2.0]: https://github.com/davidteren/mutineer/releases/tag/v0.2.0
[0.1.0]: https://github.com/davidteren/mutineer/releases/tag/v0.1.0
