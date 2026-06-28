# Brutus

A clean-room mutation-testing tool for Ruby. Brutus mutates your source one
change at a time, runs your Minitest suite against each mutant, and reports the
ones your tests failed to catch — the gaps where your suite isn't actually
testing anything.

- **Prism + stdlib only** — zero runtime dependencies (Ruby ≥ 3.4).
- **One mutation per mutant**, validity-checked by re-parsing.
- **Fork-isolated** execution (Linux + macOS).

## Status

Early development. Milestone M0 (skeleton) only — no mutation logic yet.

## Install

```sh
gem install brutus   # placeholder — not yet published
```

## Usage

```sh
brutus --version
brutus run <path>    # not yet implemented
```

## License

MIT
