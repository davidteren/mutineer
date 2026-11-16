# Contributing

Thank you for your interest in Mutineer. Bug fixes, new mutation operators,
and documentation fixes are all welcome. You do not need permission to start.

## Set up

You need Ruby 3.4 or later, on Linux or macOS.

```sh
bundle install
bundle exec rake test          # the full suite, about 6 minutes
bundle exec rake yard:strict   # documentation check, about 15 seconds
```

To run one test file, or one test in it:

```sh
bundle exec ruby -Ilib -Itest test/cli_test.rb
bundle exec ruby -Ilib -Itest test/cli_test.rb -n test_dry_run_prints_breakdown
```

## Choose what to do

- **You reported an issue.** You can fix it yourself. Say so on the issue
  before you start, so two people do not fix the same thing.
- **You want a first change.** Look for the `good first issue` and
  `help wanted` labels.
- **You want to add a mutation operator.** Each operator is one file in
  `lib/mutineer/mutators/`, with its test in `test/mutators/`. An existing
  operator of similar size is the best template.

## What a pull request needs

- A test for each change in behaviour.
- A YARD docstring or `#` comment on every new method and constant, private
  ones too. `rake yard:strict` fails without it.
- A line in `CHANGELOG.md` under "Unreleased" when users can see the change.
- `Closes #N` in the description when it fixes an issue.
- No new runtime gem and no `eval`. The gem uses Prism and the Ruby standard
  library only. Development gems such as Minitest, Rake, and YARD are allowed.

## What you can skip

- **Labels.** A maintainer adds them.
- **The release rules** at the end of this file and in [AGENTS.md](AGENTS.md).
- **The extra local checks** in AGENTS.md (Minitest 6, Prism 2, the Rails
  daemon tests, the website checks). CI runs all of them on your pull request.
  Run one locally only when you change that area.

## After you open the pull request

- GitHub holds CI on your first pull request until a maintainer approves the
  run. You do not need to do anything.
- Review bots (cubic and Qodo) comment on the code. Fix a finding that is
  right. Reply on the thread with the reason when a finding is wrong.
- A maintainer merges.

## Working with a coding agent

[AGENTS.md](AGENTS.md) holds the rules for agents that change this gem.
More than half of that file is the "Releasing" section. A contributor's agent
can skip that section.

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
