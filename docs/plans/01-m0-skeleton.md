---
title: M0 Skeleton - Plan
type: feat
date: 2026-06-28
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# M0 Skeleton - Plan

**One-line goal:** Establish the gem skeleton so `mutineer --version` works, `rake test` boots, and `require "mutineer"` loads clean — no mutation logic.

**Depends on:** nothing
**Blocks:** M1 (Parse & mutate)

---

## Goal Capsule

- **Objective:** Create the Mutineer gem layout with version constant, CLI stub, and placeholder test suite. No Prism usage, no mutation operators, no runner.
- **Authority:** Spec §11–12 + locked decisions in `docs/plans/_DECISIONS.md`.
- **Stop condition:** All three acceptance gates pass (see Verification Contract). Do not implement any M1+ logic.
- **Execution profile:** Lightweight — one commit per unit is fine; the whole milestone can land in one sitting.

---

## Product Contract

### Summary

M0 creates the Mutineer gem skeleton. It is not functional as a mutation tool; its sole purpose is establishing the gem identity, namespace, CLI entry-point, and build infrastructure that every later milestone extends.

### Locked Decisions Relevant to M0

| Decision | Locked choice |
|---|---|
| Ruby minimum | `>= 3.4` only — no `prism` gem, no conditional wiring |
| Runtime deps | None — `required_ruby_version >= 3.4` in gemspec; Prism is bundled |
| Dev deps | `rake` + `minitest` only |
| Gem name / module | `mutineer` / `module Mutineer` |
| Stack | Prism + stdlib only (CLI uses `optparse`) |
| Config file | `.mutineer.yml` — lands in M5, not M0 |
| Clean-room | Do not read, reference, or copy the `mutant` gem source |

### Requirements

**Packaging**

- R1. `mutineer.gemspec` declares `required_ruby_version >= "3.4"`, no runtime dependencies, and dev deps `rake` + `minitest`.
- R2. `Gemfile` sources from RubyGems and refers to the gemspec.

**Namespace and version**

- R3. `lib/mutineer/version.rb` defines `Mutineer::VERSION = "0.1.0".freeze`. The value is pinned in the requirement so it and the Verification Contract gate derive from one source.
- R4. `lib/mutineer.rb` requires `version` and `cli`; stub-requires for future namespaces are present as comments so M1+ can uncomment them.

**CLI** (exit codes and output streams are pinned now so scripts can rely on them from M0)

- R5. `lib/mutineer/cli.rb` implements `Mutineer::CLI` using stdlib `optparse`, exposing `Mutineer::CLI.start(argv)`. It handles these states:
  - **`--version`** → prints `Mutineer::VERSION` to stdout, exits 0.
  - **`--help`** → prints usage banner to stdout, exits 0.
  - **no args** → prints usage banner to stdout, exits 0 (convention: `git`, `docker`, `bundler` all print usage bare).
  - **`run`** → prints `run: not yet implemented` to stderr, exits 1. The stub is visible, not silent — distinguishable from a future clean run that found no mutations.
  - **unknown subcommand or invalid flag** → prints a short error to stderr, exits 1. Rescue `OptionParser::InvalidOption` (which otherwise exits 2) and re-exit 1 so flag-errors and subcommand-errors share one exit code.
- R6. `bin/mutineer` is a chmod-executable Ruby script that wires to `Mutineer::CLI.start(ARGV)`.

**Stub files**

- R7. All `lib/mutineer/` files listed in spec §12 exist as empty, non-raising stub modules/classes so M1+ uncomments its require in `lib/mutineer.rb` instead of creating a new file. Their requires stay commented in M0 (R4), so they are not on the M0 load path; the empty body guarantees no `LoadError` once a require is uncommented.

**Build and test**

- R8. `Rakefile` defines a default `rake` task that runs the Minitest test suite via `Rake::TestTask`.
- R9. `test/test_helper.rb` requires `minitest/autorun` and sets `$LOAD_PATH`.
- R10. `test/mutineer_test.rb` contains one passing placeholder test confirming the gem loads and `Mutineer::VERSION` is a non-empty string.

### Scope Boundaries

**In scope (M0 only):**
File layout, version constant, `optparse`-based CLI stub, Rakefile, placeholder test.

**Deferred to M1+:**
Prism usage, subject discovery, mutation operators, coverage map, runner, reporter, fixtures, `.mutineer.yml` config (M5).

**Out of scope entirely (v1 non-goals):**
RSpec integration, Windows support, `--since` mode, distributed execution.

---

## Planning Contract

### Key Technical Decisions

- **KTD1 — `optparse` for CLI.** Stdlib `optparse` handles all flag and subcommand parsing. No third-party CLI library. `Mutineer::CLI.start(argv)` is the single public entry-point called by `bin/mutineer`. `start` (not `run`) is the method name precisely because `run` is a subcommand — naming the entry-point `run` would collide.
- **KTD5 — Pin exit codes and streams now.** Even though M0 has no real run logic, the CLI's exit-code and stdout/stderr contract is fixed in R5 so CI scripts written against M0 stay valid into M1+. Errors and stub notices go to stderr; only requested output (version, help) goes to stdout.
- **KTD2 — Empty stub bodies, not `raise NotImplementedError`.** Stub files define their module/class with an empty body. Raising at load time would break the load gate the moment M1 uncomments a require, so stubs stay inert until a milestone fills them.
- **KTD3 — `bin/mutineer` delegates entirely to CLI.** The executable is a thin shim: shebang, `require`, `Mutineer::CLI.start(ARGV)`. No logic lives there.
- **KTD4 — Rakefile uses `Rake::TestTask`.** Standard Rake integration; `rake` (default task) runs the full `test/**/*_test.rb` glob. Keeps the build conventional and familiar.

### Assumptions

- RubyGems name `mutineer` availability is a pre-publish check, not a code task (noted in `_DECISIONS.md`).
- The single placeholder test in `test/mutineer_test.rb` is sufficient for `rake test` to boot; per-feature tests are added in M1+.

---

## Output Structure

```
mutineer/
  mutineer.gemspec
  Gemfile
  Rakefile
  README.md
  bin/
    mutineer                        # executable shim
  lib/
    mutineer.rb                     # root loader
    mutineer/
      version.rb
      cli.rb
      config.rb                   # stub
      project.rb                  # stub
      parser.rb                   # stub
      subject.rb                  # stub
      mutation.rb                 # stub
      mutator_registry.rb         # stub
      coverage_map.rb             # stub
      runner.rb                   # stub
      isolation.rb                # stub
      minitest_integration.rb     # stub
      result.rb                   # stub
      reporter.rb                 # stub
      mutators/
        base.rb                   # stub
        arithmetic.rb             # stub
        comparison.rb             # stub
        boolean_connector.rb      # stub
        boolean_literal.rb        # stub
        statement_removal.rb      # stub
        return_nil.rb             # stub
  test/
    test_helper.rb
    mutineer_test.rb                # placeholder passing test
```

---

## Implementation Units

### U1. Gem packaging identity

**Goal:** Establish `mutineer.gemspec` and `Gemfile` so `bundle install` succeeds with no runtime deps and the correct Ruby constraint.

**Requirements:** R1, R2

**Dependencies:** none

**Files:**
- `mutineer.gemspec`
- `Gemfile`

**Approach:** `mutineer.gemspec` sets `spec.required_ruby_version = ">= 3.4"`. No `add_dependency` calls for runtime. `add_development_dependency "rake"` and `add_development_dependency "minitest"`. `Gemfile` calls `source "https://rubygems.org"` and `gemspec`.

**Test scenarios:**
- `gem build mutineer.gemspec` exits 0 and produces a `.gem` file.
- `bundle install` exits 0 with no runtime gems installed.

**Verification:** `gem build mutineer.gemspec` exits 0; `bundle exec ruby -e 'puts Gem.loaded_specs.keys'` lists only dev deps.

---

### U2. Version constant and root loader

**Goal:** Define `Mutineer::VERSION` and the root `lib/mutineer.rb` that loads version and CLI, with stub-require comments for future files.

**Requirements:** R3, R4

**Dependencies:** U1

**Files:**
- `lib/mutineer/version.rb`
- `lib/mutineer.rb`

**Approach:** `version.rb` opens `module Mutineer` and assigns `VERSION = "0.1.0".freeze`. `lib/mutineer.rb` does `require_relative "mutineer/version"` and `require_relative "mutineer/cli"`. Future milestone requires are commented inline (`# require_relative "mutineer/parser"` etc.) so M1+ uncomments rather than invents paths.

**Test scenarios:**
- `ruby -Ilib -e 'require "mutineer"; puts Mutineer::VERSION'` prints `0.1.0`.
- `ruby -Ilib -e 'require "mutineer"'` exits 0 with no errors.

**Verification:** Both commands above exit 0.

---

### U3. CLI stub with optparse

**Goal:** Implement `Mutineer::CLI` covering all the states pinned in R5: `--version`, `--help`, no-args, the `run` stub, and the error path.

**Requirements:** R5

**Dependencies:** U2

**Files:**
- `lib/mutineer/cli.rb`

**Approach:** `Mutineer::CLI` exposes `self.start(argv)`. An `OptionParser` block registers `--version` (prints `Mutineer::VERSION` to stdout, exits 0) and `--help` (prints the banner to stdout, exits 0). Parse is wrapped to rescue `OptionParser::InvalidOption`, printing the error to stderr and exiting 1. After parsing: empty argv prints the banner to stdout and exits 0; `argv.first == "run"` prints `run: not yet implemented` to stderr and exits 1; any other subcommand prints an unknown-command error to stderr and exits 1.

**Test scenarios:**
- `Mutineer::CLI.start(["--version"])` prints the version to stdout, exits 0.
- `Mutineer::CLI.start(["--help"])` prints usage to stdout, exits 0.
- `Mutineer::CLI.start([])` (no args) prints usage to stdout, exits 0.
- `Mutineer::CLI.start(["run"])` prints `run: not yet implemented` to stderr, exits 1.
- `Mutineer::CLI.start(["bogus"])` (unknown subcommand) prints an error to stderr, exits 1.
- `Mutineer::CLI.start(["--unknown"])` (invalid flag) prints an error to stderr, exits 1 (not optparse's default 2).

**Verification:** Each scenario above passes; `ruby -Ilib -e 'require "mutineer/cli"'` exits 0.

---

### U4. Executable binary

**Goal:** Ship `bin/mutineer` as a chmod 0755 Ruby script that delegates to `Mutineer::CLI.start`.

**Requirements:** R6

**Dependencies:** U3

**Files:**
- `bin/mutineer`

**Approach:** Shebang `#!/usr/bin/env ruby`, then `require_relative "../lib/mutineer"`, then `Mutineer::CLI.start(ARGV)`. Three lines total. Add `bin/mutineer` to `gemspec.executables`.

**Test scenarios:**
- `bin/mutineer --version` (run directly, not via bundle) prints the version.
- `file bin/mutineer` reports the file is executable.

**Verification:** `bin/mutineer --version` exits 0 printing the version.

---

### U5. Rakefile and test scaffold

**Goal:** Wire `rake test` and provide a placeholder test that passes.

**Requirements:** R8, R9, R10

**Dependencies:** U2

**Files:**
- `Rakefile`
- `test/test_helper.rb`
- `test/mutineer_test.rb`

**Approach:** `Rakefile` requires `rake/testtask` and defines `Rake::TestTask.new(:test)` with `test_files: FileList["test/**/*_test.rb"]`. Sets `task default: :test`. `test_helper.rb` prepends `lib` to `$LOAD_PATH` and `require "minitest/autorun"`. `mutineer_test.rb` requires `test_helper`, opens `class MutineerTest < Minitest::Test`, and has one test: `assert_kind_of String, Mutineer::VERSION` and `refute_empty Mutineer::VERSION`.

**Test scenarios:**
- `rake test` exits 0.
- `rake test` output shows `1 run, 2 assertions, 0 failures, 0 errors`.

**Verification:** `rake test` exits 0.

---

### U6. Stub namespace files

**Goal:** Create all `lib/mutineer/` files listed in spec §12 that are not implemented in M0, so `require "mutineer"` never raises and later milestones fill rather than create.

**Requirements:** R7

**Dependencies:** U2

**Files (all stubs):**
- `lib/mutineer/config.rb`
- `lib/mutineer/project.rb`
- `lib/mutineer/parser.rb`
- `lib/mutineer/subject.rb`
- `lib/mutineer/mutation.rb`
- `lib/mutineer/mutator_registry.rb`
- `lib/mutineer/coverage_map.rb`
- `lib/mutineer/runner.rb`
- `lib/mutineer/isolation.rb`
- `lib/mutineer/minitest_integration.rb`
- `lib/mutineer/result.rb`
- `lib/mutineer/reporter.rb`
- `lib/mutineer/mutators/base.rb`
- `lib/mutineer/mutators/arithmetic.rb`
- `lib/mutineer/mutators/comparison.rb`
- `lib/mutineer/mutators/boolean_connector.rb`
- `lib/mutineer/mutators/boolean_literal.rb`
- `lib/mutineer/mutators/statement_removal.rb`
- `lib/mutineer/mutators/return_nil.rb`

**Approach:** Each file opens the appropriate `module Mutineer` namespace (and `module Mutators` sub-namespace for files under `mutators/`), defines the class or module name, and leaves the body empty. A `# ponytail: stub — implemented in M1+` comment marks intent. No methods, no `raise`.

These files exist for spec §12 structural completeness and so M1+ uncomments its require in `lib/mutineer.rb` rather than creating a new file. In M0 their requires stay commented (R4), so `require "mutineer"` only loads `version` + `cli` — the load-clean gate does not depend on the stub bodies. Each stub still has an empty (non-raising) body so that an M1 dev who uncomments a require gets a clean load, not a `LoadError`.

**Test scenarios:**
- Test expectation: none — empty stubs with no behavior. The U5 load test (`require "mutineer"`) proves the gate; these files are not on the M0 load path.

**Verification:** Every file in the list exists with a syntactically valid empty namespace body (`ruby -c <file>` exits 0 for each).

---

## Verification Contract

All three gates must pass before M0 is declared done:

| Gate | Command | Expected outcome |
|---|---|---|
| Version print | `bundle exec bin/mutineer --version` | Prints `0.1.0` (or current VERSION), exits 0 |
| Test suite boots | `bundle exec rake test` | Exits 0; at least 1 run, 0 failures |
| Clean load | `bundle exec ruby -Ilib -e 'require "mutineer"'` | Exits 0, no output |

Run all three in sequence. A failure in any gate blocks M1.

---

## Definition of Done

- All three Verification Contract gates pass.
- `mutineer.gemspec` has no runtime `add_dependency` calls.
- `bin/mutineer` is chmod 0755 and listed in `gemspec.executables`.
- Every file listed in spec §12 `lib/` tree exists (stub or implemented).
- `README.md` exists with at minimum the gem name, one-line description, and install placeholder.
- No mutation logic, Prism calls, fork/coverage code, or operator implementations are present.
- Dead-end or experimental code from implementation attempts is removed before declaring done.

---

## Validation

Validator: `intent-engineering:ie-validate-plan` (four lenses — predictability, convention, simplicity, experience; architecture skipped, no supported framework). No `.intense/` config; plugin defaults used.

**Dimensional ratings (lowest first; 0-10):**

| Lens | Dimension | Score |
|---|---|---|
| Experience | Interaction-state coverage | 5 → resolved |
| Simplicity | Essential vs accidental complexity | 6 (explicit-request override) |
| Convention | Repo consistency | 6 (false positives — see below) |
| Experience | Accessibility (exit codes / streams) | 6 → resolved |
| Predictability | Return-contract / failure / representation | 7 → resolved |
| Experience | User-flow completeness | 7 → resolved |
| Convention | Framework idiom | 8 |
| Predictability | Name/behavior fidelity | 8 |
| Simplicity | Abstraction earns its keep | 9 |
| Convention | Configuration restraint | 9 |
| Simplicity | Dependency restraint | 10 |

**Gaps resolved (folded into the plan):**
- **`run` stub exited silently** (flagged by all three of predictability, experience, simplicity). R5 + U3 now make `run` print `run: not yet implemented` to stderr and exit 1 — the stub is visible, not indistinguishable from a clean run.
- **No-args behavior was undefined** (experience, P1). R5 + U3 now print usage and exit 0 on bare `mutineer`, matching `git`/`docker`/`bundler`.
- **`VERSION` value was unpinned in R3 while the gate hardcoded `0.1.0`** (predictability, WYSIWYG, confidence 100). R3 now pins `Mutineer::VERSION = "0.1.0".freeze`.
- **Exit codes and output streams were unspecified** (experience, P2). R5 + KTD5 pin them: errors/stub-notices to stderr, requested output to stdout, invalid-flag rescued from optparse's default exit 2 to a uniform exit 1.

**Gaps assessed and intentionally not changed:**
- Simplicity recommended deleting the 19 stub files (U6) and the `run` subcommand as YAGNI. Both are **explicit user requests** (spec §12 file tree; "stub subcommands: run") — kept, with the load-clean rationale tightened (stubs satisfy spec §12 structural completeness; KTD2 governs their empty bodies once requires are uncommented).
- Convention flagged Ruby `>= 3.4` vs spec's `>= 3.2`, and missing `mutators/` prefixes. Both are false positives from the condensed lens prompt: the 3.4 narrowing is a **locked decision** (documented in the Locked Decisions table), and the written U6/Output Structure already place operator stubs under `lib/mutineer/mutators/`.

**Verdict: Ready to implement.** No blocking gaps remain.