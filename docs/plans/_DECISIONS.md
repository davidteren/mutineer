# Mutineer — Locked planning decisions (read before planning any milestone)

Source spec: `../../mutineer-implementation-spec.md` (read it in full first).

These resolve Section 13 "open decisions". They are LOCKED — plan around them, do not re-litigate:

| # | Decision | Locked choice | Implication for plans |
|---|---|---|---|
| 1 | Minimum Ruby | **3.4+ only** | Prism is bundled with Ruby ≥ 3.4. **No runtime gem dependency.** `require "prism"` directly. gemspec: `required_ruby_version = ">= 3.4"`. No conditional/`prism` gem wiring. |
| 2 | Default operators (v1) | **Tier 1 + statement-removal** | All four Tier-1 operators PLUS statement-removal are ON by default. ⇒ statement-removal moves from M5 into **M4** (full default operator set). M5 keeps the *remaining* Tier-2 ops (return-nil, literal, condition-negation) behind flags. |
| 3 | Config format | **`.mutineer.yml` (YAML)** | Parse with stdlib `yaml`. No Ruby DSL config. Lands in M5. |
| 4 | Gem name | **`mutineer`** | `module Mutineer`, `mutineer.gemspec`. (Maintainer to confirm RubyGems availability — note as a pre-publish check, not a code task.) |
| 5 | `--since <git-ref>` | **Out of v1** | Noted as near-term future work only. Do NOT plan it. |

## Standing constraints (from spec §0, §3, §14) — apply to every plan
- **Clean-room.** Do not read/reference/copy the `mutant` gem's source. Implement from this spec + public mutation-testing literature only. Call this out in each plan's constraints.
- **Stack discipline.** Core runtime: **Prism + stdlib only** (`coverage`, `tempfile`, `optparse`, `set`, `json`, `yaml`, `Process.fork`). **No `unparser`** — mutate source *textually* (byte-range substitution), never regenerate from AST.
- **Platform:** Linux + macOS (fork-based). Windows out of scope.
- **One mutation per mutant.** Never combine mutations.
- **Validity rule.** Every mutated source string is re-parsed with Prism; parse errors ⇒ discard silently, count as "skipped: invalid".
- **Non-goals (do not plan):** RSpec, Windows, equivalent-mutant detection, `--since`, DSL/metaprogramming mutation, distributed/network execution.

## Convention note
This is a plain-Ruby gem (no Rails). The org "interactors-not-services" rule is largely N/A here; keep operators/runner as small single-purpose classes per the spec's own structure (§12). Don't invent service objects.

## Per-milestone gate (the verifiable signal — every plan must state its own)
Each milestone is verified against the fixtures in spec §12. The gate for a milestone is: its fixtures/tests pass AND the milestone's stated acceptance check holds (e.g. M1 = `mutineer run --dry-run fixtures/calculator.rb` emits the expected mutation diffs; M4 = the *exact expected survivor set* for the fixtures appears and expected kills don't). Project-wide gate once a Rakefile exists: `rake test` + `ruby -Ilib -e 'require "mutineer"'` (load check).
