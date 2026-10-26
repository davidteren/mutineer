# Contributing

Read [AGENTS.md](AGENTS.md) before you change this gem.
That file is the local gate.
Run the checks there before you commit.

## Zero runtime dependencies

The gem uses Prism and the Ruby standard library only.
Do not add a runtime gem.
Development gems such as Minitest, Rake, and YARD are allowed.
Do not add `eval`.
Ruby 3.4 or later is required.

## Releases

A release is a manual action by David Teren (GitHub `davidteren`).
Contributors and agents must never push a `v*` tag, merge a release pull
request, run a release workflow, or `gem push`.
Releases need his approval, including the `rubygems` GitHub environment.
The steps and the settings he applies by hand are in [AGENTS.md](AGENTS.md).
