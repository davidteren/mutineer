# Contributing

Thank you for your interest in Mutineer. Bug fixes, new mutation operators,
and documentation fixes are all welcome. You do not need permission to start.

## Set up

You need Ruby 3.4 or later, on Linux or macOS.

```sh
bundle install
bundle exec rake test          # the zero-dependency suite, about 6 minutes
bundle exec rake yard:strict   # documentation check, about 5 seconds, writes no files
```

To run one test file, or one test in it:

```sh
bundle exec ruby -Ilib -Itest test/cli_test.rb
bundle exec ruby -Ilib -Itest test/cli_test.rb -n test_dry_run_prints_breakdown
```

The Rake tasks read files as UTF-8 in any shell. Other tools, such as the
website checks, need a UTF-8 locale. Check it with `ruby -e 'p Encoding.default_external'`, which prints
`#<Encoding:UTF-8>` when the shell is set up. If it prints anything else, set a
locale (#484):

- macOS: add `export LANG=en_US.UTF-8` to `~/.zshrc`.
- Linux and containers: `export LANG=C.UTF-8`, or `ENV LANG=C.UTF-8` in a Dockerfile.
- `LC_ALL` overrides `LANG`. If `LC_ALL` is set to another locale, unset it or set it to the same UTF-8 value.

If the suite fails on a clean checkout of `main`, open an issue. Include the
output, your Ruby version, and your operating system.

Work in a fork: make a branch there, push it, and open a pull request
against `main`.

## Choose what to do

- **You reported an issue.** You can fix it yourself. Say so on the issue
  before you start, so two people do not fix the same thing.
- **You want a first change.** An issue with the `good first issue` or
  `help wanted` label is a good start, when one is open.
- **You want to add a mutation operator.** Each operator is one file in
  `lib/mutineer/mutators/`, with its test in `test/mutators/`. It also needs
  a `require_relative` line in `lib/mutineer.rb` and its entries in
  `lib/mutineer/mutator_registry.rb`. An existing operator of similar size is
  the best template: search for its name to find every place.

## What a pull request needs

- A test for each change in behaviour.
- A YARD docstring or `#` comment on every new method and constant, private
  ones too. `rake yard:strict` fails without it.
- A line in `CHANGELOG.md` under "Unreleased" when users can see the change.
- `Closes #N` in the description when it fixes an issue.
- No new runtime gem and no `eval`. The gem uses Prism and the Ruby standard
  library only. Development gems such as Minitest, Rake, and YARD are allowed.

## What you can skip

- **Labels, when you cannot set them.** GitHub lets only people with triage
  access or higher set labels. Without that access, a maintainer adds them.
- **The release rules** at the end of this file and in [AGENTS.md](AGENTS.md).
- **The extra local checks** in AGENTS.md (Minitest 6, Prism 2, the Rails
  daemon tests, the website checks). CI runs all of them when your pull
  request is ready for review.
  Run one locally only when you change that area.

## After you open the pull request

- CI starts when the pull request is ready for review. A draft pull request
  starts no CI job. Mark it ready when you want CI and a review.
- GitHub can hold CI on a pull request from a fork until a maintainer
  approves the run. You do not need to do anything.
- Review bots (cubic and Qodo) comment on the code. Fix a finding that is
  right. Reply on the thread with the reason when a finding is wrong.
- A maintainer merges.

## Working with a coding agent

[AGENTS.md](AGENTS.md) holds the rules for agents that change this gem.
Its longest section is "Releasing". A contributor's agent can skip that
section.

## Releases

Most contributors can skip this section.

A maintainer owns every release. A maintainer is a human collaborator with
maintain or admin permission.
Non-maintainer contributors never push a `v*` tag, merge a release pull
request, run a release workflow, or `gem push`.
An agent may suggest a release, but it never cuts one on its own.
It acts only after a maintainer agrees to that release, and then does only
steps 1 to 4 of the release procedure in AGENTS.md.
Every other release step stays with the maintainer.
Releases also need approval of the `rubygems` GitHub environment.
The steps and the settings a maintainer applies by hand are in [AGENTS.md](AGENTS.md).
