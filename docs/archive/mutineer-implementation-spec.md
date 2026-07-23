> → plan: [`docs/plans/INDEX-mutineer.md`](docs/plans/INDEX-mutineer.md) — 6 validated, dependency-ordered milestone plans (M0–M5). Open decisions (§13) resolved in [`docs/plans/_DECISIONS.md`](docs/plans/_DECISIONS.md).

# Mutineer — Implementation Spec

> A lightweight, AST-based mutation-testing gem for Ruby / Minitest.
> Built from scratch, MIT-licensed, no dependency on (and no code copied from) the commercial `mutant` gem.

---

## 0. For the implementing agent — read this first

- **This is an MVP, not a Mutant clone.** The goal is a tool that reliably surfaces *shallow tests* (places where the test suite passes even though the code's behaviour changed) on plain Ruby business-logic classes. Breadth, exhaustive syntax coverage, and raw speed are explicit non-goals for v1.
- **Clean-room requirement (important).** Implement everything from this spec and from public mutation-testing literature (e.g. the classic mutation-operator set, PIT's documented operators from the Java world, academic papers). **Do not read, reference, or copy from the `mutant` gem's source code.** Mutation testing is a published technique and is not copyrightable; Mutant's *code* is. Keep the implementation independent.
- **Stack discipline.** Core runtime depends only on **Prism** (the official Ruby parser; bundled with Ruby ≥ 3.4, otherwise the `prism` gem) and the Ruby **standard library** (`Coverage`, `fork`, `Tempfile`). Test integration targets **Minitest**. Do **not** take a dependency on `unparser` — we mutate source textually, not by regenerating it from the AST.
- **Build in milestones (Section 11).** Each milestone is independently verifiable against the fixtures in Section 12. Don't move on until the current milestone passes.
- **Ask before assuming.** If a design decision is genuinely ambiguous (Section 13), surface it rather than guessing.

---

## 1. What we're building

A CLI tool and library. You point it at some Ruby source files and your Minitest suite; it:

1. Parses the target source with Prism.
2. Generates small, behaviour-changing **mutations** (e.g. flips `>` to `>=`, `+` to `-`, drops a statement).
3. For each mutation, applies it, runs the relevant tests in an isolated process, and records whether any test **caught** the change.
4. Reports a **mutation score** and lists every **surviving mutant** (a mutation no test caught — i.e. a gap in your tests) with a readable diff.

A surviving mutant means one of two things, and both are actionable:
- Your tests don't actually assert the behaviour the mutation removed → **add a test**, or
- The original code did more than the tests require → **the code may be simplifiable**.

### Nomenclature (use these terms consistently in code and output)

| Term | Meaning |
|---|---|
| **Subject** | A method we mutate (identified by namespace + method name + location). |
| **Mutation** | A single edit to a subject (a source byte-range + replacement text + the operator that produced it). |
| **Mutant** | The program with exactly one mutation applied. |
| **Killed** | A test failed/errored when the mutant ran → the suite caught the change. Good. |
| **Survived** | All covering tests still passed → a test gap. The thing we report. |
| **No coverage** | No test exercises the mutated line → can't be killed; flagged separately (uncovered code is itself a useful signal). |
| **Mutation score** | `killed / (killed + survived)`. (No-coverage mutants are reported but excluded from the score denominator; surface the count separately.) |

---

## 2. Architecture / pipeline

```
target files ──▶ Parser (Prism) ──▶ Subjects (def nodes)
                                        │
                                        ▼
                                 Mutators ──▶ Mutations (loc + replacement)
                                        │
        Coverage map (per test file) ───┤
                                        ▼
                              Runner (fork per mutant)
                                        │  child: apply mutation, load covering
                                        │         test file(s), run Minitest
                                        ▼
                              Results ──▶ Reporter (score + surviving diffs)
```

Two distinct phases at runtime:

- **Phase A — Coverage map.** Run each test file once under `Coverage` to learn which source lines it touches. Invert into `(file, line) => [test_files]`. (Cache to disk so reruns are fast.)
- **Phase B — Mutation run.** Parent process loads the application code (so methods exist and are redefinable) but **not** the test files. For each mutation: `fork`; in the child, apply the mutation, load only the test file(s) that cover that line, run them, and report killed/survived back to the parent.

---

## 3. Tech stack & dependencies

- **Ruby:** target ≥ 3.2. Prefer ≥ 3.4 (Prism bundled). For 3.2/3.3 add the `prism` gem.
- **Runtime gems:** `prism` (only if Ruby < 3.4). Nothing else required at core.
- **Test framework integration:** Minitest (the only target for v1).
- **Stdlib used:** `coverage`, `tempfile`, `optparse`, `set`, `json` (for the coverage cache), and `Process.fork`.
- **Platform:** Linux and macOS (fork-based). Windows is out of scope for v1.
- **Dev dependencies:** `rake`, `minitest` (Mutineer tests itself with Minitest).

---

## 4. The mutation operators

Implement as small, single-purpose classes. Each operator is a Prism visitor that walks the AST of one subject and emits zero or more `Mutation`s. **One mutation per mutant** — never combine.

Prism gives every node a precise `location` with `start_offset` / `end_offset`. For operator-style nodes it also exposes the exact token location (`message_loc` on `CallNode`, `operator_loc` on `AndNode`/`OrNode`), which is what we rewrite.

### Tier 1 — build these first (highest signal)

| Operator | From → To | Prism node | Range to rewrite |
|---|---|---|---|
| **Arithmetic** | `+`↔`-`, `*`↔`/`, `%`→`*`, `**`→`*` | `CallNode` with `name` in the set | `message_loc` |
| **Comparison / boundary** | `<`→`<=`, `<=`→`<`, `>`→`>=`, `>=`→`>`, `==`→`!=`, `!=`→`==` | `CallNode` with comparison `name` | `message_loc` |
| **Boolean connector** | `&&`↔`||` | `AndNode` / `OrNode` | `operator_loc` |
| **Boolean / nil literal** | `true`↔`false`, `nil`→`true` | `TrueNode` / `FalseNode` / `NilNode` | whole node `location` |

Boundary mutations (`>` → `>=` etc.) are the single highest-value family — they expose off-by-one and edge-case gaps that line coverage never catches. Prioritise them.

### Tier 2 — add after Tier 1 works end-to-end

| Operator | Behaviour | Notes |
|---|---|---|
| **Statement removal** | Delete one statement from a method body | Replace the statement's range with `nil`. Skip if it's the method's only/last expression and removal would change arity/syntax — keep it syntactically valid. |
| **Return-value nil** | Replace a method's return expression with `nil` | Target explicit `ReturnNode` value and the method body's final expression. |
| **Literal mutation** | integer `n` → `0`, `1`, `n+1`; string → `""` | Lower signal; gate behind a flag. |
| **Condition negation** | wrap an `if`/`unless`/ternary condition in `!( … )` | Optional; validate it round-trips. |

Each operator must be individually toggleable (`--operators arithmetic,comparison` / config). Keep a registry mapping operator name → class.

### Validity rule

Every generated mutation **must** produce parseable Ruby. After building the mutated source string, re-parse it with Prism; if it has parse errors, discard the mutation silently (count it as "skipped: invalid"). This is cheap insurance against malformed mutants.

---

## 5. Subject discovery

Given target paths (files or directories), and optional filters:

1. Read each `.rb` file, parse with Prism.
2. Walk for `DefNode` (instance and singleton methods). Track the enclosing **namespace path** (the chain of `ClassNode` / `ModuleNode` names) so each subject knows its fully-qualified owner — needed later to redefine the method in the right place.
3. A **Subject** records: source file, namespace path (e.g. `["Billing", "Invoice"]`), method name, singleton?, and the `DefNode` location.
4. Apply `--only` filters by fully-qualified name (e.g. `Billing::Invoice#total`, `Billing::Invoice.build`).

Mutations are only generated *inside* subject bodies — never on the `def` signature line itself for v1 (keep arity stable).

---

## 6. Applying a mutation (textual substitution)

This is deliberately simple and is the key insight that keeps the project tractable:

```ruby
def apply(original_source, mutation)
  s = mutation.start_offset
  e = mutation.end_offset
  original_source[0...s] + mutation.replacement + original_source[e..]
end
```

No AST regeneration, no unparser. We only ever change the exact bytes of one token/node.

---

## 7. Getting the mutant to actually run

The parent process loads the application code once. Each mutant runs in a forked child. Two strategies — **build (a) first, upgrade to (b) later**:

**(a) Whole-file reload (Milestone 2 — simplest).**
In the child: write the mutated source of the affected file to a `Tempfile`, then `load` it. Re-`load` re-opens the classes and **redefines** the methods with the mutated versions. Acceptable for POROs / plain business-logic classes. *Limitation:* re-runs any top-level side effects in the file; document this.

**(b) Surgical method redefinition (Milestone 5 — cleaner).**
Extract just the enclosing `DefNode`'s source, apply the mutation to that snippet, resolve the owner via the namespace path (`Object.const_get("Billing::Invoice")`), and `class_eval`/`instance_eval` the mutated `def` to redefine that one method. No file-level side effects re-run. More moving parts (namespace resolution, singleton vs instance), hence the later milestone.

In both cases the original (unmutated) app file was already `require`d by the parent, so Ruby treats further `require`s of it as no-ops — the mutation isn't clobbered by the test file's own `require`s.

---

## 8. Coverage-based test selection

Naive mutation testing runs the whole suite per mutant — unusably slow. We avoid that with Ruby's stdlib `Coverage`.

**Building the map (Phase A):**
- For each test file, run it in a subprocess with `Coverage.start(lines: true)`, then read `Coverage.result`.
- Record the set of `(source_file, line)` pairs that executed.
- Invert to `coverage_map[(file, line)] => [test_files...]`. Persist as JSON in a cache dir (e.g. `.mutineer/coverage.json`), keyed by a digest of the test + source files so it auto-invalidates.

**Using the map (Phase B):**
- For a mutation on `(file, line)`, look up the covering test files.
- **None?** → mark the mutant **no-coverage**, skip execution, report it.
- **Some?** → the child loads and runs only those test files.

v1 granularity is **per-test-file** (simple, already a big win). A later upgrade is per-test-*method* coverage for tighter selection; note it as future work, don't build it now.

---

## 9. The run loop (Phase B detail)

```
parent:
  load application code (target files + their deps) via --require
  build/refresh coverage map
  collect all subjects → all mutations
  for each mutation (optionally across N forked workers):
      fork:
        child:
          apply mutation (strategy 7a/7b)
          covering_tests = coverage_map[mutation.location]
          load each covering test file
          result = run Minitest over just those runnables
          exit_status encodes: killed (a test failed/errored) | survived (all passed) | error
        parent:
          record result for this mutation
  aggregate → Reporter
```

**Minitest control in the child:** disable Minitest autorun/`at_exit`, then invoke the run explicitly so you can read the outcome. Loading only the covering test files means only those `Minitest::Runnable`s exist in the child, so running "everything loaded" runs exactly the intended subset. Map *any* failure or error → **killed**; a clean pass → **survived**. Guard each child with a **timeout** (a mutation can cause an infinite loop) — on timeout, treat as killed (the mutation broke something) but tag it `timeout` in the report.

**Parallelism:** Milestone 4 can be serial. Add a fixed-size worker pool (fork up to `--jobs` children at once, default to processor count) in Milestone 5.

---

## 10. Reporting

Output to stdout, plus an optional machine-readable file.

- **Summary:** total mutations, killed, survived, no-coverage, skipped(invalid), errored; **mutation score** as a percentage.
- **Per surviving mutant:** fully-qualified subject, `file:line`, operator name, and a unified-style diff showing the original token vs the mutation. Group by file.
- **Exit code:** `0` if mutation score ≥ `--threshold` (default off / 0); non-zero otherwise, so it can gate CI. No-coverage and survivors should make the failure obvious.
- **Optional `--format json`** for CI tooling.

Keep the human output scannable — the survivor list *is* the product.

---

## 11. Milestones (build in this order; each is verifiable)

- **M0 — Skeleton.** Gem layout (Section 12), `version.rb`, `bin/mutineer`, CLI stub parsing options with `optparse`. `mutineer --version` works.
- **M1 — Parse & mutate (no execution).** Prism parsing, subject discovery, the **arithmetic** operator. `mutineer run --dry-run fixtures/calculator.rb` prints candidate mutations as diffs. Verify counts/locations against the fixture by hand.
- **M2 — End-to-end, one mutant.** Textual application + **fork isolation** + whole-file reload (7a) + Minitest run over one hardcoded test file. Prove a single arithmetic mutation on the calculator fixture is **killed** by a strong test and **survives** against a weak test.
- **M3 — Coverage map + selection.** Phase A coverage map, persisted + invalidated by digest; Phase B selects covering test files. Verify uncovered code is flagged **no-coverage**.
- **M4 — Full Tier 1 + reporting + CI.** All Tier-1 operators, result aggregation, the Reporter (score + survivor diffs), `--threshold` exit codes, `--operators` toggle. Run against the full fixture set and confirm the *expected* survivors (Section 12) appear and the *expected* kills don't.
- **M5 — Polish.** Parallel worker pool (`--jobs`), config file (`.mutineer.yml`), Tier-2 operators, surgical method redefinition (7b), `--format json`.

---

## 12. Project structure & self-testing

```
mutineer/
  mutineer.gemspec
  Gemfile
  Rakefile
  README.md
  bin/mutineer
  lib/
    mutineer.rb
    mutineer/
      version.rb
      cli.rb
      config.rb
      project.rb            # loads app code, discovers subjects
      parser.rb             # Prism wrapper
      subject.rb
      mutation.rb
      mutators/
        base.rb
        arithmetic.rb
        comparison.rb
        boolean_connector.rb
        boolean_literal.rb
        statement_removal.rb   # Tier 2
        return_nil.rb          # Tier 2
      mutator_registry.rb
      coverage_map.rb
      runner.rb             # orchestrates Phase B
      isolation.rb          # fork worker + timeout
      minitest_integration.rb
      result.rb
      reporter.rb
  test/
    fixtures/
      calculator.rb              # +/-/*//, comparisons
      calculator_strong_test.rb  # kills everything → score 100%
      calculator_weak_test.rb    # leaves known survivors
      pricing.rb                 # boundary logic (>=, discounts)
      pricing_test.rb            # deliberately misses the == boundary
    mutators/                    # unit tests per operator
    runner_test.rb
    coverage_map_test.rb
    integration_test.rb          # run Mutineer on fixtures, assert survivors
```

**Self-testing approach:** the fixtures are the spec for correctness. Write integration tests that run Mutineer against each fixture and assert the *exact* set of surviving mutants. For example, `pricing.rb` uses `total >= 100` for a discount; `pricing_test.rb` only tests `total = 150` and `total = 50` (never the `100` boundary), so Mutineer **must** report the `>=`→`>` mutation as a survivor. If it doesn't, selection or execution is broken. Dogfood: Mutineer should eventually run on its own `lib/`.

---

## 13. Open decisions to confirm with the maintainer

1. **Minimum Ruby version** — 3.2 (needs the `prism` gem) or 3.4+ (Prism bundled, simpler)?
2. **Default operator set** — ship Tier 1 only on first release, or include statement-removal from day one?
3. **Config file format** — `.mutineer.yml` acceptable, or prefer a Ruby DSL config?
4. **Gem name** — `mutineer` is the working namespace; confirm it's free on RubyGems (or pick the rename; it touches only `module Mutineer` and the gemspec).
5. **CI behaviour** — should `--since <git-ref>` (mutate only changed lines) be in scope soon? It's the highest-value "fast path" feature after the MVP, but it's not in v1.

---

## 14. Explicit non-goals for v1 (do not build these)

- RSpec integration (Minitest only).
- Windows support (fork-based).
- Exhaustive Ruby syntax coverage / every mutation operator.
- Equivalent-mutant detection.
- Rails-specific parallel-worker database isolation.
- Incremental/`--since` mode (noted as near-term future work, not v1).
- DSL / metaprogramming mutation (`attr_accessor`, class-level macros).
- Distributed/remote execution or any network calls. Mutineer runs entirely on the local machine.
