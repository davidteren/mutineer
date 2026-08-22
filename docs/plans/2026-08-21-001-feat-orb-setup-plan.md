---
title: Amp Orb Setup - Plan
type: feat
date: 2026-08-21
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Amp Orb Setup

Enable orb-based development for the mutineer gem by creating `.agents/setup` and `.agents/resume` lifecycle files so orb threads can install the Ruby 3.4 toolchain, the gem's zero-dependency bundle, and the Rails fixture app's isolated bundle — then run all CI gates (`rake test`, `rake yard:strict`, load smoke test, `rake test:daemon`) without a local machine.

---

## Goal Capsule

- **Objective:** Create orb lifecycle files that make a fresh Debian 12 orb a fully functional mutineer development environment in one setup pass.
- **Authority:** User request to evaluate and set up orb support for the gem.
- **Stop condition:** An orb thread created against this repo can run `bundle exec rake test`, `bundle exec rake yard:strict`, `ruby -Ilib -e 'require "mutineer"'`, and `bundle exec rake test:daemon` — all passing — after `.agents/setup` runs once.
- **Non-goals:** No changes to the gem's code, Gemfile, CI workflows, or AGENTS.md. No `.agents/setup` logic for non-Ruby toolchains.
- **Tail ownership:** The implementer verifies setup idempotence by running `.agents/setup` twice in an orb and confirming the second run converges.

---

## Product Contract

### Summary

Mutineer is a zero-runtime-dependency mutation testing gem (Prism + stdlib, Ruby ≥ 3.4) with 451 tests in ~27 seconds. The gem's own suite is Rails-free, but daemon integration tests require a separate Rails fixture app bundle at `test/fixtures/rails_app/`. Amp orbs are Debian 12 sandboxes pre-loaded with gh, Node.js, PostgreSQL, Redis, and other tools — but no Ruby. The orb needs lifecycle files to install Ruby 3.4 and both bundles so it can run every CI gate.

### Problem Frame

Without `.agents/setup` and `.agents/resume`, an orb thread starts from a bare Debian 12 environment with no Ruby. Every orb thread would need to manually install Ruby, bundler, and dependencies before doing any work — wasting minutes per thread and breaking the snapshot reuse model. The orb lifecycle files solve this by running once on fresh orb creation (setup) and on each wake (resume), making the orb immediately productive.

### Requirements

- R1. `.agents/setup` installs Ruby 3.4.x on a clean Debian 12 orb using mise (the toolchain manager the Amp team uses for their own orbs).
- R2. `.agents/setup` installs the gem's zero-dependency bundle via `bundle install` from the repo root.
- R3. `.agents/setup` installs the Rails fixture app's isolated bundle via `bundle install` in `test/fixtures/rails_app/` so daemon tests (`rake test:daemon`) are available.
- R4. `.agents/setup` is idempotent — running it twice converges without errors, duplicate installs, or corrupted state.
- R5. `.agents/setup` finishes within the 20-minute orb timeout (target: under 10 minutes on a fresh orb — mise's Ruby build alone takes 3-8 minutes — under 30 seconds on a warm snapshot).
- R6. `.agents/resume` is a fast no-op (the project has no databases, services, or tunnels to repair) that exits within 10 seconds.
- R7. `.gitignore` ignores `.amp/portals/*` per the orb-setup skill's requirement.
- R8. Both scripts are committed with the executable bit set (`chmod +x`).

### Scope Boundaries

**In scope:**
- `.agents/setup` — Ruby 3.4 installation + both bundle installs
- `.agents/resume` — minimal idempotent no-op
- `.gitignore` — add `.amp/portals/*` rule

**Deferred to follow-up work:**
- Adding a `.ruby-version` or `mise.toml` to pin the exact Ruby version project-wide (the setup script hardcodes `3.4` for now; a version pin file is a separate decision)
- Writing orb-specific guidance to `~/.config/amp/AGENTS.md` (the repo's root `AGENTS.md` already covers all conventions)

**Outside this product's identity:**
- Modifying the gem's Gemfile, gemspec, CI workflows, or any Ruby source code
- Setting up `.amp/services.yaml` (no long-lived services needed)

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Use mise for Ruby version management.** The Amp team's own orb setup uses `mise install --locked` (per their blog post "Putting an Agent in an Orb"). mise is a single-binary tool manager that can install Ruby on Debian 12. Alternative: rbenv + ruby-build (the developer's local setup). Chose mise because it's the orb-ecosystem standard, simpler to install (one curl pipe vs. cloning two repos), and the Amp base image doesn't include rbenv. The developer's local rbenv setup is unaffected — mise is orb-only.

- **KTD2. Include the Rails fixture app bundle in setup.** The gem's suite is Rails-free, but `rake test:daemon` and `bin/dogfood` require the fixture app's isolated bundle. Including it in setup means the orb can run every CI gate, not just the zero-dep subset. The cost is ~30-60 seconds of additional `bundle install` time for Rails + sqlite3. Worth it for a complete development environment.

- **KTD3. Resume is a no-op.** The project has no databases, background services, tunnels, or long-lived processes. The orb snapshot preserves installed Ruby and gems. There is nothing to repair on wake — mise activation is persisted in `~/.bash_profile` during setup (per U1 phase 1, with a marker-guarded idempotent block), so fresh post-wake login shells can resolve `ruby` and `bundle` without re-sourcing. The resume script exists only because the orb lifecycle expects the file; it does nothing beyond the bash preamble.

- **KTD4. Pin Ruby to `3.4` (latest patch) via mise, not a specific patch version.** The gemspec requires `>= 3.4` and CI uses `3.4`. Pinning to the `3.4` major-minor lets mise pick the latest patch, matching CI behavior. A `.ruby-version` file would be more explicit but is a separate project-wide decision (deferred).

### Assumptions

- The orb base image's `apt-get` has the build dependencies Ruby needs (`build-essential`, `libssl-dev`, `libyaml-dev`, `libreadline-dev`, `zlib1g-dev`, `libffi-dev`). If any are missing, the setup script installs them via `apt-get`.
- mise's Ruby build on Debian 12 takes 3-8 minutes. This is within the 20-minute orb timeout and only happens once (cached in the snapshot).
- The Rails fixture app's dependencies (Rails ~> 7.1, sqlite3 ~> 1.7) are compatible with Ruby 3.4. Since `Gemfile.lock` is gitignored, the orb resolves fresh versions via `bundle install` (not frozen).

---

## Implementation Units

### U1. Create `.agents/setup`

**Goal:** Install Ruby 3.4 via mise and both gem bundles on a fresh Debian 12 orb.

**Dependencies:** none

**Files:**
- `.agents/setup` (create)

**Approach:** The script starts with `#!/usr/bin/env bash` and `set -euo pipefail`. It proceeds in four phases:

1. **Ruby toolchain.** Check if `ruby` is already at `3.4.x` (warm snapshot — match the minor, not just `3.4+`, so Ruby 3.5+ doesn't silently satisfy the check). If not, install mise via `curl https://mise.run | sh`, add it to PATH, install Ruby build dependencies via `apt-get`, then `mise install ruby@3.4` and `mise use --global ruby@3.4`. Source mise's shell integration so subsequent commands see the new Ruby. Persist mise activation with a single idempotent, marker-guarded block in `~/.bash_profile` (the profile Bash reads for login shells, which is what `/bin/bash -lc` and post-wake shells use) — not `~/.bashrc` or `~/.profile`, which may be skipped depending on shell invocation mode. Verify from a clean shell: `/bin/bash -lc 'ruby -v'` must show 3.4.x.

2. **Bundler.** After Ruby is available, install Bundler if not already present: `command -v bundle >/dev/null 2>&1 || gem install bundler --no-document`. This ensures `bundle` is on PATH and compatible with the Ruby version without redundant reinstalls on warm snapshots. A mise-installed Ruby may not include a default Bundler.

3. **Gem bundle.** Run `bundle install` from the repo root. The gem has zero runtime dependencies, so this is fast.

4. **Rails fixture app bundle.** Run `bundle install` in `test/fixtures/rails_app/`. This is the heavier install (Rails, sqlite3 native extension). A failure here exits non-zero with a clear phase-specific error so the orb snapshot is not published in an incomplete state.

Each phase prints a timestamped marker so the setup log shows which step is slow. The warm-snapshot path (Ruby already installed) runs `bundle check || bundle install` for both bundles — letting Bundler cheaply validate that installed gems still satisfy the current Gemfile — and exits fast if everything is current.

**Patterns to follow:** The orb-setup skill's lifecycle file contract (bash preamble, idempotent, non-interactive, no foreground servers, per-step timing). The Amp team's own `.agents/setup` pattern from "Putting an Agent in an Orb" (mise for toolchain). Note: both `Gemfile.lock` files are gitignored, so the orb resolves fresh dependency versions via `bundle install` (not frozen).

**Test scenarios:**
- **Happy path (fresh orb):** `.agents/setup` runs on a clean Debian 12 orb, installs mise + Ruby 3.4 + Bundler + both bundles, exits 0. After setup, `ruby -v` shows 3.4.x, `bundle exec rake test` passes, `bundle exec rake yard:strict` passes.
- **Clean-shell activation:** After setup, `/bin/bash -lc 'ruby -v'` shows 3.4.x (mise activation persisted in `~/.bash_profile`, not just setup's process).
- **Idempotence (warm snapshot):** Running `.agents/setup` a second time detects Ruby already installed, `bundle check` confirms both bundles are satisfied, skips all installation, exits 0 quickly.
- **Load smoke test:** After setup, `ruby -Ilib -e 'require "mutineer"'` succeeds (the gem loads with zero runtime deps).
- **Daemon tests pass:** After setup, `bundle exec rake test:daemon` passes (the Rails fixture bundle is installed and the daemon test suite runs green).

**Verification:** In an orb thread, run `.agents/setup` once, confirm `ruby -v` is 3.4.x, run `bundle exec rake test` and `bundle exec rake yard:strict`. Run `.agents/setup` a second time and confirm it converges (no errors, fast exit).

---

### U2. Create `.agents/resume`

**Goal:** Provide a fast idempotent no-op that satisfies the orb lifecycle's wake expectation.

**Dependencies:** U1

**Files:**
- `.agents/resume` (create)

**Approach:** The script is `#!/usr/bin/env bash` + `set -euo pipefail` + a comment explaining there is nothing to repair. The project has no databases, services, tunnels, or long-lived processes. The orb snapshot preserves installed Ruby and gems. The script exits 0 immediately.

**Test scenarios:**
- **Happy path:** `.agents/resume` exits 0 within 10 seconds (effectively instant).

**Verification:** In an orb thread, run `.agents/resume` and confirm it exits 0 immediately.

---

### U3. Update `.gitignore` and make scripts executable

**Goal:** Ensure `.amp/portals/*` is gitignored and both lifecycle scripts have the executable bit.

**Dependencies:** U1, U2

**Files:**
- `.gitignore` (modify — add `.amp/portals/*` rule)
- `.agents/setup` (modify — set executable bit via `chmod +x`)
- `.agents/resume` (modify — set executable bit via `chmod +x`)

**Approach:** Add a commented entry for `.amp/portals/*` to `.gitignore` (preserving existing rules). Run `chmod +x .agents/setup .agents/resume` so the scripts are executable when committed.

**Test expectation:** none — this is a config/packaging unit. The `.gitignore` change is verified by confirming the rule appears exactly once and doesn't duplicate an existing pattern.

**Verification:** `ls -la .agents/setup .agents/resume` shows executable bits. `grep -c '.amp/portals' .gitignore` returns 1.

---

## Verification Contract

| Gate | Command | Applicability |
|------|---------|---------------|
| Gem test suite | `bundle exec rake test` | After U1 — 451 runs, 0 failures |
| YARD strict docs | `bundle exec rake yard:strict` | After U1 — 100% documented |
| Load smoke test | `ruby -Ilib -e 'require "mutineer"'` | After U1 — exits 0 |
| Clean-shell activation | `/bin/bash -lc 'ruby -v'` | After U1 — shows 3.4.x (mise persisted in `~/.bash_profile`) |
| Daemon tests | `bundle exec rake test:daemon` | After U1 — passes (requires Rails fixture bundle) |
| Setup idempotence | Run `.agents/setup` twice in an orb | After U1 — second run converges |
| Resume speed | Run `.agents/resume` in an orb | After U2 — exits 0 within 10s |
| Executable bit | `ls -la .agents/setup .agents/resume` | After U3 — both show `x` bits |
| Gitignore rule | `grep -c '.amp/portals' .gitignore` | After U3 — returns 1 |

The ultimate verification is creating an orb thread against this repo and confirming all gates pass. Local verification (macOS) is limited to syntax checking (`bash -n .agents/setup`) and the `.gitignore`/chmod checks — the Ruby installation logic can only be exercised in a Debian 12 orb.

---

## Definition of Done

- `.agents/setup` and `.agents/resume` exist, are executable, and follow the orb-setup skill's lifecycle contract
- An orb thread created against this repo can run `bundle exec rake test`, `bundle exec rake yard:strict`, `ruby -Ilib -e 'require "mutineer"'`, and `bundle exec rake test:daemon` — all passing — after `.agents/setup` runs
- `.agents/setup` is idempotent (second run converges)
- `.agents/resume` exits 0 within 10 seconds
- `.gitignore` includes `.amp/portals/*` exactly once
- No changes to gem source code, Gemfile, gemspec, CI workflows, or AGENTS.md
