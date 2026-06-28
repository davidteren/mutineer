# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-06-28

### Added
- Initial release of Mutineer — a clean-room, Prism-based mutation-testing tool
  for Ruby with zero runtime dependencies (Ruby ≥ 3.4).
- Mutation operators: arithmetic, comparison, boolean-connector, boolean-literal,
  statement-removal (Tier 1, default); return-nil, literal-mutation,
  condition-negation (Tier 2, opt-in via `--operators`).
- Coverage-guided test selection with a digest-keyed, auto-invalidating cache.
- Fork-isolated, parallel execution (`--jobs`) with per-mutant timeouts.
- Two application strategies: `7a` whole-file reload (default) and `7b` surgical
  redefinition, verified to agree on namespaced multi-statement methods.
- `run`, `--dry-run`, `--threshold`, `--only`, `--operators`, `--strategy`,
  `--format human|json`, `--output`, `--list-operators`.
- `.mutineer.yml` configuration (CLI > config > default precedence).
- Byte-correct source handling for multibyte (UTF-8) sources.

[0.1.0]: https://github.com/davidteren/mutineer/releases/tag/v0.1.0
