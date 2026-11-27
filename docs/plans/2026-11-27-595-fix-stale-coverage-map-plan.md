---
title: "Group 11-G: the coverage cache refuses a saved map after a change it cannot scope - Plan"
type: fix
date: 2026-11-27
issues: [595, 548]
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Group 11-G: the coverage cache refuses a saved map after a change it cannot scope - Plan

Planned by: Fable 5.2, effort high, 2026-11-27

Issues the builder filed: N1 is #602, N2 is #603, N3 is #604.

- **What:** Mutineer keeps a saved coverage map after an edit to a view, a fixture, a lock file or any other file that is not a source, a test or a Ruby file the tests load. This plan makes such an edit capture every test again, with one stderr line that names the file.
- **Why:** The saved map says which tests run for each mutant. After such an edit a test can reach other source lines, and the old map does not list that test there. The mutant then runs without a test that covers it, and the report can say `survived` or `no_coverage` with no message.
- **How:** Each run records the git commit that is checked out and a fingerprint of every file that differs from it, before the app loads. The saved map keeps that record. The next run compares its own record with the saved one. If a file changed that no other cache check covers, the run captures every test.

Build settings: Opus 5.5, effort `high`. The worklist says `medium`. This is cache validity code: a mistake gives a wrong map with no message, and the 11-F plan asked for `high` on this unit for the same reason. A prototype exists and its tests are named below, so the build follows a checked path.

Target release: 1.11.0. Issues: #595 (`Closes #595`), and one new issue that the builder files and unit U2 closes. #548 stays open (`Refs #548`). One pull request, two commits.
Planned against `main` at `6c71ccba`.

**Verdict: `go`.** The defect is reproduced on `main` in four cases, a prototype removes all four and gives the planned result in 40 edge cases, and the new check can only turn a reuse into a full capture with a reason line (or, under `--coverage-from`, into a refusal with exit 2).

---

## Goal Capsule

- **Objective:** A run never reuses a saved coverage map, in full or in part, when a project file changed that Mutineer cannot tie to a test. It captures every test and says which file caused it.
- **Means:** One new module that asks git for the changed paths and fingerprints them (`Mutineer::WorkTree`), one new module of private `CoverageMap` methods that decides (`CoverageMap::WorkTreeCheck`), one new key in `coverage.json` (`"work_tree"`), and one call in `CoverageMap#cached_or`.
- **Authority:** `AGENTS.md`, then `.expectation-fit/ways-of-working.yaml` and `.expectation-fit/decisions/coverage-and-test-selection.md`, then this plan, then the issue text.
- **Execution profile:** One branch (`fix/595-stale-coverage-map`), one worktree, one pull request, two commits (U1, then U2).
- **Who ships:** The builder opens the pull request. David merges. No release step.
- **Size:** Medium. Two new `lib/` files (about 320 lines with their YARD comments), about 55 changed lines in 7 `lib/` files, two new test files, four changed test files, three docs files, the CHANGELOG, one decision record, the plan copy.
- **Stop conditions.** Stop and report, do not work around:
  - A test in the zero-dependency suite other than `CliTest#test_empty_full_scan_warns_unless_allow_empty` fails with the change, and the cause is not a path this plan names.
  - `bundle exec rake test:daemon` shows a second run of an unchanged fixture app that captures every test. That means a run writes a file that git does not ignore, and the list in KTD6 misses it.
  - The fix seems to need a change in `Cache#partial_plan`, `Cache#cache_hit?` or `Cache#dependencies_match?`. This plan changes none of them.
  - U2 is not green after one working session. Drop U2, leave its issue open in `backlog`, and ship U1 (rule 4 of `RULES.md`).

---

## Product Contract

### Summary

Today the coverage cache checks the run's sources, the run's tests, the Ruby files the tests loaded, and a few run inputs. Nothing else in the project is checked. After this change a saved map is used only when every other file is as it was when the map's run started. Git gives the list of changed files, so no list of file types is needed.

### Problem Frame

`CoverageMap#cached_or` (`lib/mutineer/coverage_map/capture_reuse.rb`) has three outcomes:

1. `Cache#cache_hit?`: the digest and the loaded Ruby files are equal. The whole map is reused.
2. `Cache#partial_plan`: only method bodies of sources and some tests changed. Part of the map is reused.
3. Neither: every test is captured.

The checks behind outcomes 1 and 2 read these inputs: the sources and the tests (`compute_digest`), the boot file and the `--require` files, the Ruby files under `load_path` directories, the seed, and `"dependencies"`, which holds the project `.rb` files in `$LOADED_FEATURES` after a capture (`Recording#record_loaded`).

A file outside that list can change what a test does:

- A view, a partial, a mailer template.
- A YAML fixture, a factory file that FactoryBot loads with `load`, a JSON or CSV data file.
- `Gemfile.lock`, `package.json`, a `.env` file that git tracks.
- A Ruby file that the app loads with `load`, such as `config/routes.rb` or `db/schema.rb`. These are not in `$LOADED_FEATURES`.
- A new file that the app finds by convention, such as a new initializer or a new view.

### Reproduction (done in planning, 2026-11-27, `main` at `6c71ccba`)

Probe: `reports/11-G-plan-data/probe_stale.rb` in the run folder. It builds a small git project with two sources and three tests. One test reads a view, a fixture and a lock file, and takes another branch of a source when one of them says `strict`. It ran against a clean copy of `lib/` from `origin/main`, and against the prototype.

| Case | Result on `main` | With the prototype |
|---|---|---|
| View edit, nothing else | Cache hit. `lib/card.rb:4` has no test in the reused map. A fresh capture lists `test/page_test.rb`. **Stale.** | Every test captured. One line names the view. |
| Fixture edit | The same. **Stale.** | Every test captured. One line names the fixture. |
| Lock file edit | The same. **Stale.** | Every test captured. One line names the lock file. |
| Method-body edit in another source, plus the view edit (the Fizzy case of the 11-F measurement) | Partial recapture of 1 of 3 test files. The view's test is kept. **Stale.** | Every test captured. One line names the view. |

On `main` no case prints a line about the change. A mutant on `lib/card.rb:4` would score `no_coverage` there. On Fizzy the same defect left one test out of a mutated line (`reports/11-F-measurement.md`, section 1).

A second probe, `probe_edges.rb`, runs 40 more cases against the prototype. All 40 give the planned result. They are the base of the table test in U1.

A third probe, `probe_window.rb`, found a second stale map on `main`, older than #595: a file that is edited while the capture runs. Unit U2 fixes it.

| Case of `probe_window.rb` | Result on `main` | With the prototype |
|---|---|---|
| A view is edited while the capture runs, after the test that reads it ran | The next run is a cache hit. **Stale.** | Every test captured. |
| A method body of a source is edited while the capture runs | The next run captures no test again. **Stale.** | Every test captured. |

### Requirements

- R1. A saved map is reused, in full or in part, only when every changed path is one of these: a source of this run, a test of this run, a Ruby file in the map's `"dependencies"`, or one of Mutineer's own files (KTD6). The other cache checks then decide as they do today.
- R2. When R1 does not hold, the run captures every test and prints one stderr line with the reason. A changed file is named.
- R3. When the saved map has a git commit and git cannot answer now, the run captures every test and prints one stderr line. No git answer is never read as "no change".
- R4. When git gave no answer for the saved map and gives none now (no repository, git not installed, a folder that git ignores or refuses), the run keeps today's rule. Each run that reuses a map then prints one stderr line that says what is not seen and what to do, with a link to the issue that tracks it. This is the one case where the check does not fail closed (D4).
- R5. A file that changes after a run took its record counts as changed for the next run. The record is taken before the app loads. (U1 for a file of R2. U2 for a source, a test and a loaded Ruby file.)
- R6. `--coverage-from` applies the same rule as a refusal with a reason (exit 2), as it does for its other checks. The reason ends with `; capture it again`.
- R7. No verdict, score, exit code or JSON key changes for a run that captures every test. The JSON report gets no new key.

### Acceptance Examples

- AE1. The map is saved at commit A with a clean tree. `app/views/cards/show.html.erb` is edited. The next run captures every test and prints: `[mutineer] coverage cache: app/views/cards/show.html.erb changed since the saved map, and Mutineer cannot tell which tests it affects; capturing every test.`
- AE2. The same for `test/fixtures/cards.yml` and for `Gemfile.lock`. These three are the "done when" of #595.
- AE3. A method body of a source changes and nothing else. The run recaptures only the tests of that source, as today.
- AE4. A view is edited before the first run. Nothing changes after it. The second run reuses the map. The view is then committed. The third run reuses the map.
- AE5. A view is edited before the first run and restored to the committed text after it. The second run captures every test.
- AE6. Five files change. The line reads: `[mutineer] coverage cache: 5 files (a.erb, b.yml, c.lock and 2 more) changed since the saved map, and Mutineer cannot tell which tests they affect; capturing every test.` The paths are sorted. With `--verbose`, one more line for each path follows: `[mutineer] coverage cache:   <path>`.
- AE7. The saved map is from commit A, and A is not in this clone. The run captures every test and prints: `[mutineer] coverage cache: the commit of the saved map is not in this clone (a shallow clone, or a commit that no branch holds now; fetch the full history, in GitHub Actions with fetch-depth: 0); capturing every test.`
- AE8. The project is in no git work tree. A second run reuses the map and prints: `[mutineer] coverage cache: git gives no answer for this project (no repository, git is not installed, or git ignores or refuses the folder), so an edit to a view, a fixture or a lock file is not seen; after such an edit, delete .mutineer/coverage.json (https://github.com/davidteren/mutineer/issues/N1).` `N1` is the issue of limit L1. The path is this run's cache file. A run that captures every test for another reason does not print it.
- AE9. `mutineer run ... --format json --output report.json` runs twice in a git project where `report.json` is not ignored. The second run reuses the map. So does a third run that does not name the report: the saved map keeps the own paths of its run.
- AE10. `.mutineer.yml` in the project root gets a new `ignore:` entry. The next run reuses the map.
- AE11. A `--rails` run with `--coverage-from` reads a capture, and a view changed since that capture. Exit 2: `--coverage-from <file> cannot be reused: app/views/cards/show.html.erb changed since the capture, and Mutineer cannot tell which tests it affects; capture it again`.
- AE12. A file has git's assume-unchanged or skip-worktree flag, and it is edited. The next run captures every test and names it. The same holds for a file that a sparse checkout removes.
- AE13 (U2). A method body of a source is edited while a capture runs. The next run captures every test and prints: `[mutineer] coverage cache: lib/card.rb changed while the last run was in progress; capturing every test.`
- AE14. The project holds an untracked nested repository `vendor/x`. Each run captures every test and prints: `[mutineer] coverage cache: vendor/x/ cannot be fingerprinted (a folder, a nested repository, a changed submodule, an unreadable file or a name that is not UTF-8): add it to .gitignore or remove it; capturing every test.`

### Siblings

| Path | Covered how |
|---|---|
| Standalone run (`CoverageMap#build_or_load`) | `cached_or`. Tested in the new test file. |
| In-process `--rails` or `--boot` run (`build_via_fork`) | The same `cached_or`. `Runner.execute` takes the record before the boot. One test in boot mode. |
| `--daemon` (`DaemonServer#build_coverage_map`) | The same `cached_or`, in the daemon process. `DaemonServer#boot!` takes the record before the boot. One test in `test/daemon_coverage_test.rb`. The report and baseline paths reach it through `DaemonBackend.boot_config`. |
| Full cache hit and partial recapture | One check in front of both. Each has a test that compares the map with a fresh capture. |
| `--coverage-from` (`CaptureReuse#capture_mismatch`) | The same decision, as a refusal. Tested. |
| `--test-command` | Builds no coverage map. No change. |
| `--dry-run` | Runs no test and reads no map. No change. |
| The GitHub Action | It passes flags to the CLI and keeps no cache of its own. No change in `action.yml`. |
| Redefine and reload strategies | The map code does not branch on the strategy. No change. |

### Scope Boundaries

- Not in this plan: a setting where the user lists files to leave out of the check, or files to add to it (limit L4).
- Not in this plan: a change to what `"dependencies"` holds, or to the digests.
- Not in this plan: files that git ignores, projects with no git, and files outside the project root (limits L1 to L3).
- Not in this plan: a smaller clean check (#594) or any other unit of the 11-F plan.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Git lists the changed files. Mutineer keeps no list of file types.** A list of Rails folders would miss the next case, such as a factory file or a data file in `lib/`. This is KTD4 of the 11-F plan, checked against `main`: it holds.
- KTD2. **The record is a commit and the files that differed from it.** `coverage.json` gets `"work_tree" => { "commit" => "<id>" or null, "dirty" => { "<path>" => "<fingerprint>" or null }, "own" => ["<path>"] }`. The name is `work_tree`, not `tree`, because `tree` reads as a syntax tree in this gem. `"commit"` is `HEAD`. `"own"` is in KTD6. `"dirty"` holds every path below the project root that one of three git commands lists: `git diff --name-only <commit>` (tracked files that differ, staged or not), `git ls-files --others --exclude-standard` (untracked files that git does not ignore), and `git ls-files -v` for every file that git was told not to look at (the assume-unchanged and skip-worktree flags), on disk or not. Git reports no edit to a flagged file, and no removal by a sparse checkout, so Mutineer fingerprints each one itself. A flagged file that is not on disk has the fingerprint `absent`. The first text of this plan listed only flagged files on disk; the simplicity lens showed with a probe that a fixture which a sparse checkout removes was then not seen.
- KTD3. **The candidate set is a union, and a candidate is unchanged only on an equal fingerprint.** On a later run the candidates are the saved `"dirty"` paths plus the paths that differ from the saved commit now. A candidate is unchanged only when it is in the saved `"dirty"` with a fingerprint, and that fingerprint equals the one of this run's record. This covers a file that was edited at capture time and is restored now, and an untracked file that is deleted now (Codex found both cases on the 11-F plan).
- KTD4. **One record for each run, taken before the app loads, and used for both the check and the save.** `Runner.execute` takes it before the boot file and the sources load. `DaemonServer#boot!` takes it before the app boots. `CoverageMap.new` gets it as `work_tree:`, and a `CoverageMap` built with no record takes its own at the start of `cached_or`. `work_tree_refusal` compares the saved record with this one, and `save` writes this one. So the state the check accepts is the state the cache then holds. A file that changes after the record was taken is a changed file for the next run (R5). The first prototype took the record in `save`. The probe `probe_window.rb` then showed a stale map for a view that is edited during the capture.
- KTD5. **A missing git answer is decided by the saved record, and never means "no change".** This is KTD5 of the 11-F plan with more states. The states and their lines are in U1, step 5. Each line says what happened and what the user can do.
- KTD6. **Mutineer's own files are never changed files.** The list is short and exact:
  - this run's cache file and its temporary file (`coverage.json` and `coverage.json.tmp` in the cache folder), and not the rest of that folder, so `--cache-dir .` and `--cache-dir config` work;
  - any path below `.mutineer/` in the project root (the documented state folder: caches, `baseline.json`, the report of the agent recipe);
  - `.mutineer.yml` in the project root;
  - a path with `.mutineer/file-swap-locks/` in it (`FileSwap.lock_file` writes these beside each source);
  - the `--coverage-from` file, the `--output` report and the baseline file;
  - each path in the saved record's `"own"` list: the cache file, the `--coverage-from` file, the report and the baseline of the run that saved the map. Without it, a report that the last run wrote is a changed project file for a run that does not name it, and a `--coverage-from` run refuses a capture because of the capture run's own report.

  Without this list the second run of `mutineer run --output report.json` would capture every test, on every run. The settings in `.mutineer.yml` that can change a map (sources, tests, `require`, `boot`, `load_path`, the framework) are already in the cache digest. A `.mutineer.yml` in another folder, and a file in another folder named `.mutineer`, are normal project files and count as changes. A project whose own tests read its root `.mutineer.yml`, its baseline or a file below its root `.mutineer/` keeps the gap for those files. The docs say so (D5).
- KTD7. **Nothing is left out by file type.** A docs file, such as `README.md`, counts as a change. A test can read it, and this repository's own tests do. The 11-F count shows that this costs no reuse on Fizzy (see "Cost").
- KTD8. **The check looks below the project root only.** Every git command runs with `-C <project_root>` and prints paths relative to it. `"dependencies"` holds only files below the project root too (`Recording#loaded_relative`), so the two checks have one scope. A change elsewhere in a larger repository is limit L3.
- KTD9. **The fingerprint is the file mode and the content.** It is another value than `Cache#file_fingerprint` of the same file, and the two are never compared with each other. A path that Mutineer cannot fingerprint never matches: a folder (a changed submodule, or an untracked nested repository, which git lists as `name/`), a file that cannot be read, and a path that is not valid UTF-8 (JSON cannot hold it) are saved with `null`. Such a path captures every test for as long as it is listed. A symlink is fingerprinted by its target text, and a missing file by the word `absent`.
- KTD10. **`WorkTree` is a new module and does not reuse `ChangedLines.git_diff`.** That helper returns line hunks for one file and an empty string when git fails. The new module returns `nil` on any failure, reads paths with `-z`, passes `--no-renames` so both ends of a rename are listed, and passes `--ignore-submodules=none`. It runs git without `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and four more such variables, so an inherited variable cannot make git answer for another repository. It needs only the standard library, because the daemon loads it before the app.
- KTD11. **Only this run's sources and tests, and the saved loaded files, are left to the other checks.** A source or a test that is in the saved map and not in this run counts as a changed file when it changed. A kept test can `load` it, and no other check then sees it.
- KTD12. **The other cache checks are not touched.** The new check runs first and can only turn a reuse into a full capture, or, under `--coverage-from`, into a refusal with exit 2. It cannot turn a full capture into a reuse. So the worst result of a mistake in the new code is a slower run with a line that says why, or a `--coverage-from` run that stops with a reason, except for a path that the check wrongly leaves out (R1 and KTD6 are the two lists to review).
- KTD13 (U2). **A scoped file is left to its own check only when that check can see the change.** The cache saves its fingerprints of sources, tests and loaded files after the tests ran. The record is from before. When the record says a file changed and the cache's own fingerprint equals the file now, the file changed during the last run, and the cache check is blind to it. The run then captures every test.

### Design that was compared (finding 9 of the 11-F plan review)

Other design: save a list of every tracked path with its blob id (`git ls-files -s`), plus a hash of each changed or untracked path, and compare the two lists.

| | Commit and changed files (chosen) | Path and blob list |
|---|---|---|
| Works in a shallow clone that lacks the capture commit | No. The run captures every test and says so (AE7). | Yes. |
| Size of the record | A few entries: only the files that differ from the commit. | One entry for each tracked file: megabytes in a large repository. |
| Git commands | `rev-parse`, `diff --name-only`, two `ls-files` calls. | `ls-files -s`, a status call that must refresh the index, and `hash-object` for each changed file so that an edited file compares equal after it is committed. |
| A change that git's filters hide (line endings, a clean filter) | Not seen (limit L1). | Not seen either, because blob ids are after the filter. |

The chosen design needs the capture commit in the clone. `docs/ci.md` already asks for `fetch-depth: 0` for an explicit `--since` ref. Decision D1 gives David the other option.

### Assumptions

- `git` 2.x is on `PATH` wherever `--since` already works. The suite already runs git in temporary repositories (`test/changed_lines_test.rb`, `test/since_test_scope_test.rb`), and `test/test_helper.rb` turns git's background maintenance off for them.
- A Rails app ignores the files its tests write (`log/`, `tmp/`, `storage/`). The fixture app does (`test/fixtures/rails_app/.gitignore`).

### Sources

- Issue #595 with no comments, and #548 with one comment, read 2026-11-27 (current).
- `plans/11-F-coverage-cache-plan.md`, unit U2, KTD4 and KTD5, and `reports/11-F-measurement.md` with `reports/11-F-measurement-data/` (current, same day).
- `reports/11-F-plan-codex.md` and `reports/11-F-plan-fit-validate-round1.md` (current): the findings on U2 that this plan carries over.
- Code read on `origin/main` at `6c71ccba` (current): `lib/mutineer/coverage_map.rb`, `coverage_map/cache.rb`, `capture_reuse.rb`, `skeleton_digest.rb`, `recording.rb`; `changed_lines.rb`, `runner.rb`, `daemon_backend.rb`, `daemon_server.rb`, `job_plan.rb`, `file_swap.rb`, `reporter.rb`, `fs_path.rb`, `project_path.rb`.
- Pull request #601 (group 11-E), head `71fbd603`, read for the overlap (current).
- Git documentation for `update-index` (assume-unchanged, skip-worktree) and for the environment variables, as cited by the Codex review (durable).

---

## Implementation Units

**Prototype for both units:** `plans/11-G-stale-coverage-map-prototype.patch` in the run folder. It applies to `main` at `6c71ccba` with `git apply`. It holds the `lib/` changes of U1 and U2 as this plan describes them, and it passes all three probes. It has no tests and no docs. It is a base to check against, not a finished patch: review each line. Three things differ from the plan on purpose:

- `NNN` in `NO_GIT_NOTE` stands for the number of issue N1.
- It holds `cache_sees_change?` and the `:during_run` cause. For the U1 commit, leave both out: a scoped path is then always left to its own check. U2 adds them.
- It does not print the `--verbose` path list of step 4.

### U1. A saved coverage map is refused after a change that no cache check covers (#595)

Commit: `fix: the coverage cache captures every test after a change to a file it cannot scope (#595)`.

Do the steps in this order.

**Step 0. File the three follow-up issues** (texts in "Limits left open"). The code and the docs need the numbers of N1 and N2. U2 closes N3. (Filed as #602, #603 and #604.)

**Step 1. New file `lib/mutineer/work_tree.rb`: module `Mutineer::WorkTree`** (`module_function`, as `ChangedLines`). It requires `open3`, `digest` and `fs_path` only.

| Member | Does |
|---|---|
| `GIT_ENV` | A frozen Hash that maps `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES` and `GIT_NAMESPACE` to `nil`. Do not add `GIT_CONFIG_COUNT` or `GIT_CONFIG_PARAMETERS`: CI containers pass `safe.directory` in them. |
| `git(root, *args)` | `Open3.capture3(GIT_ENV, "git", "-C", root, *args, binmode: true)`. Returns stdout and the status. Returns `["", nil]` when git cannot start (`SystemCallError`). An argument list, never a shell string. |
| `inside?(root)` | True when `rev-parse --is-inside-work-tree` prints `true` and `check-ignore --quiet -- .` does not succeed. A project folder that an outer repository ignores is "no work tree": git would list none of its files. |
| `head(root)` | The id of `HEAD` (`rev-parse --verify --quiet HEAD^{commit}`), or `nil`: when `inside?(root)` is false, when the work tree has no commit yet, or when git fails. |
| `commit?(commit, root)` | True when `cat-file -e <commit>^{commit}` succeeds. |
| `changed_since(commit, root)` | The union of three lists (KTD2). `diff --name-only --no-renames --ignore-submodules=none --relative -z <commit> --`. `ls-files --others --exclude-standard -z`. `ls-files -v -z`, of which it keeps each row whose tag is `S` or a lower-case letter. `nil` when one command fails. Each path goes through `FsPath.read`. |
| `fingerprint(root, rel)` | KTD9: `"<octal mode>\0<SHA-256>"`. Reads the file in blocks (`Digest::SHA256.file`), because an untracked file can be large. `"link\0<target>"` for a symlink, `"absent"` for a missing path, `nil` for a folder or on `SystemCallError`. |
| `record(root)` | `{ "commit" => ..., "dirty" => ... }`. `{ "commit" => nil, "dirty" => {} }` when `head` is nil or `changed_since` is nil. A path that is not valid UTF-8 is saved under `rel.dup.force_encoding(Encoding::UTF_8).scrub("?")` with `nil`, after the other paths, so that `nil` wins a name clash. (`rel.b.scrub` does nothing: every byte is valid in a binary string. Codex found this in the first prototype.) |

**Step 2. New file `lib/mutineer/coverage_map/work_tree_check.rb`: module `CoverageMap::WorkTreeCheck`**, private methods, included in `CoverageMap` beside `Cache`. `require_relative "work_tree"` and the new file go in `lib/mutineer/coverage_map.rb`. No method here prints.

| Method | Does |
|---|---|
| `well_formed_work_tree?(record)` | True for a Hash with `"commit"` nil or String, `"dirty"` a Hash of String to String or nil, and `"own"` absent or an Array of String. |
| `work_tree_refusal(cached, saved_name = "the saved map")` | Returns a pair: the reason or nil, then the note or nil. The states are in step 5. `saved_name` is `"the capture"` for `--coverage-from`. |
| `unscoped_changes(cached, now)` | A Hash of path to cause, sorted by path, for `(now | saved_dirty.keys)` without three kinds of path. First, a path whose saved fingerprint is not nil and equals this run's: `@work_tree["dirty"][rel]` when that Hash has the key, else `WorkTree.fingerprint`. Second, an own path: `own_rels`, the saved `"own"` list, `own_path?`. Third, a scoped path: `source_rels`, the keys of `test_fingerprints`, the keys of `cached["dependencies"]` (KTD11). The cause is `:no_print` when this run's fingerprint is nil, or the saved record has the path with nil. Else it is `:changed`. |
| `own_rels` | This run's own files, relative to the project root: `cache_path`, `"#{cache_path}.tmp"`, `@coverage_from` and `@own_paths`. `save` writes this list as `"own"`. |
| `own_path?(rel)` | The three fixed places of KTD6: `.mutineer.yml` in the root, a path below `.mutineer/` in the root, a path with `.mutineer/file-swap-locks/` in it. The literals stay, with a comment that names `Config::CONFIG_FILE` and `FileSwap::LOCK_DIR_NAME`, so `coverage_map.rb` does not load those two files. |
| `changed_files_reason(changes, saved_name)` | The text of state 1. `nil` for an empty Hash. It prints each control character of a path as `?`: a file name can hold a newline or an escape character. |

**Step 3. `lib/mutineer/coverage_map.rb`.** `CoverageMap#initialize` takes `own_paths: []` and `work_tree: nil`, and keeps them in `@own_paths` and `@work_tree`. Add one clause to the class comment: a later run also captures every test when another project file changed that git lists.

**Step 4. `cached_or`, `save` and the printing.**

`lib/mutineer/coverage_map/capture_reuse.rb`, `cached_or`:

```ruby
@digest = compute_digest
# The record of this run (#595). A caller that boots an app passes one it
# took before the boot.
@work_tree ||= WorkTree.record(@project_root)
return reuse_capture(after_fork) if @coverage_from

cached = read_cache
# A cache from before the work-tree record (#595) rebuilds once.
cached = nil unless cached.is_a?(Hash) && well_formed_work_tree?(cached["work_tree"])
reason, note = cached ? work_tree_refusal(cached) : nil
if reason
  warn "[mutineer] coverage cache: #{reason}; capturing every test."
  cached = nil
end
```

- With `@verbose` and more than three paths, print one line for each path after the reason line: `[mutineer] coverage cache:   <path>`. Give `work_tree_refusal` a way to hand the full list to `cached_or`, for example a third element of the pair.
- `cache_hit?(nil)` is false and `partial_plan(nil)` is nil, so the run captures every test. `cache_hit?` and `partial_plan` stay queries that print nothing.
- Print the note (`warn "[mutineer] coverage cache: #{note}."`) only where a reuse happens: in the cache-hit branch, and after `apply_partial` returned true. A run that captures every test for another reason prints no note.
- The reason line comes before the `warn_unchecked` line of the same run.

`lib/mutineer/coverage_map/skeleton_digest.rb`, `save`: add `"work_tree" => @work_tree&.merge("own" => own_rels)` to `data`. No fallback record: every `save` call comes after `cached_or` set `@work_tree`. A `save` with no record writes `null`, and the next run then captures every test.

**Step 5. The states of `work_tree_refusal`**, in the order to check them. `saved` is `cached["work_tree"]`, `mine` is `@work_tree`. Lines 1 to 4 end with `; capturing every test.` Line 5 is the note, and the reuse goes on.

| # | State | Text after `[mutineer] coverage cache: ` |
|---|---|---|
| 4a | `saved` has no commit, `mine` has one | `the saved map records no git commit, and the project has one now` |
| 5 | Neither has a commit, and `WorkTree.inside?(root)` is false | `git gives no answer for this project (no repository, git is not installed, or git ignores or refuses the folder), so an edit to a view, a fixture or a lock file is not seen; after such an edit, delete <cache file> (https://github.com/davidteren/mutineer/issues/N1)` |
| 4b | Neither has a commit, and `inside?` is true | `git gives no commit for this project (it has no commit yet, or git failed), so the changed files cannot be listed` |
| 2 | `saved` has a commit and `mine` has none. Or both have one, `changed_since` is nil, and `WorkTree.commit?` says the saved commit is in the clone. | `git could not list the changed files (run git status in the project to see why)` |
| 3 | Both have a commit, `changed_since` is nil, and the saved commit is not in the clone | `the commit of the saved map is not in this clone (a shallow clone, or a commit that no branch holds now; fetch the full history, in GitHub Actions with fetch-depth: 0)` |
| 1 | Both have a commit, and `unscoped_changes` is not empty. The path list is `mine["dirty"].keys` when the two commits are equal, else `WorkTree.changed_since(saved commit)`. | See below |

The three texts of state 1. `<what>` is one path, or `<n> files (<a>, <b>, <c> and <m> more)`.

| Causes of the listed paths | Text |
|---|---|
| All `:no_print` | `<what> cannot be fingerprinted (a folder, a nested repository, a changed submodule, an unreadable file or a name that is not UTF-8): add it to .gitignore or remove it` (`them` for more than one) |
| All `:during_run` (U2) | `<what> changed while the last run was in progress` |
| Any other mix | `<what> changed since the saved map, and Mutineer cannot tell which tests it affects` (`they affect` for more than one) |

State 4b makes a work tree with no commit capture every test on each run until the first commit.

**Step 6. `--coverage-from`: `CaptureReuse#capture_mismatch`, `well_formed_capture?` and `reuse_capture`.**

- `well_formed_capture?` also needs `!cached.key?("work_tree") || well_formed_work_tree?(cached["work_tree"])`, so a hand-edited record gets the "not the shape" reason (decisions file, "Validate Reused Coverage Captures").
- After the `dependencies_match?` line of `capture_mismatch`:
  - no `"work_tree"` key: `"it records no git state: an older Mutineer made it; capture it again with this version"`.
  - `reason, @work_tree_note = work_tree_refusal(cached, "the capture")`. With a reason, return `"#{reason}; capture it again"` (AE11). For a path that cannot be fingerprinted, a new capture does not help: the reason text already says to ignore or remove the path.
- `reuse_capture` prints the note after `accepted_capture` accepted the capture: `warn "[mutineer] --coverage-from: <note>."`.

**Step 7. The record and the own paths reach the map.**

- `lib/mutineer/job_plan.rb`: new `JobPlan.own_paths(config)`, which returns `[config.output, config.baseline].compact.map { |path| File.expand_path(path) }`: absolute paths, as the other `*_paths` values. Both resolve against the working directory, as `Reporter` and `Baseline` read them.
- `lib/mutineer/runner.rb`, `Runner.execute`, in-process path: after the line that sets `boot_started`, take `work_tree = WorkTree.record(config.project_root)`. This is after the returns for `--test-command`, `--daemon` and an empty `--since` scope, and after the orphan sweep, so only a run that builds a map pays for it. It is before the boot file, the sources and the `--require` files load. Pass `own_paths: JobPlan.own_paths(config), work_tree: work_tree` to both `CoverageMap.new` calls.
- `lib/mutineer/daemon_backend.rb`, `DaemonBackend.boot_config`: new key `own_paths: JobPlan.own_paths(config)`.
- `lib/mutineer/daemon_server.rb`: document `"own_paths"` in the `Protocol` comment at the top, beside `"extra_load_paths"`. In `DaemonServer#boot!`, when `cfg["coverage"]` is set, after `sweep_temps` and `install_zeitwerk_ignore!` and before the boot file is required: `require_relative "work_tree"` and `@work_tree = WorkTree.record(Dir.pwd)`. `DaemonServer#build_coverage_map` passes `own_paths: Array(@cfg["own_paths"]), work_tree: @work_tree`.

**Step 8. Tests.** Each test asserts the mechanism: which test files were captured (the sentinel helpers `with_sentinel` and `captured_files` of `test/coverage_map_test.rb`, or `phase_a_ran`), and the exact stderr line. A test that claims a correct map compares `tests_for` with a fresh capture in another cache folder.

New `test/work_tree_test.rb` (real git in a temporary repository, as `test/changed_lines_test.rb`):

- `inside?`: true in a repository, false in a plain folder, false in a folder that an outer repository ignores. `head`: a commit id in a repository, `nil` in a repository with no commit and in a plain folder.
- `changed_since`: an edit, a staged edit, a delete, a rename (both names), a mode change, an untracked file, an ignored file (not listed), a file with a space and a non-ASCII name, a subfolder as root (paths relative to it, nothing from outside it), an edited file with the assume-unchanged flag, an edited file with the skip-worktree flag, a flagged file that is not on disk (listed), a file that `git sparse-checkout set --no-cone '/*' '!/data/'` removes (listed).
- `changed_since` with an unknown commit id returns `nil`. `commit?` is false for it.
- With `GIT_DIR` set to another repository, `head` and `changed_since` still answer for the project root. In a linked worktree (`git worktree add`), they answer for that worktree.
- With git not on `PATH` (stub `Open3.capture3` to raise `Errno::ENOENT`): `inside?` is false, `head` is nil, `changed_since` is `nil`, `record` has a nil commit.
- `fingerprint`: differs after a content edit and after a mode change, `absent` for a missing path, a `link` value for a symlink, `nil` for a folder.
- `record` with a path that is not valid UTF-8 (stub `changed_since` to return one, so the test also runs on macOS): `JSON.generate` of the record does not raise, and the entry is `nil`.
- `require "mutineer/work_tree"` in a new Ruby process loads no other Mutineer constant than `FsPath` (the daemon rule).

New `test/coverage_map_work_tree_test.rb` (a standalone `CoverageMap` in a temporary git project, built from the probe `probe_stale.rb`, where one test reads the view, the fixture and the lock file):

- AE1 and AE2: three tests, one for each file kind of #595, each for the full hit. Each compares the gated line with a fresh capture.
- The partial path: a body edit beside a view edit captures every test, and the map equals a fresh capture.
- AE3, AE4, AE5, AE6 (with and without `--verbose`), AE7, AE8, AE9 (three runs), AE10, AE12, AE14.
- One test for each state of step 5 with its exact text: state 2 (a saved commit, and `Open3.capture3` stubbed to raise `Errno::ENOENT`), state 3, state 4a (a map saved with no git, then `git init` and one commit), state 4b (a repository with no commit), state 5.
- State 5 does not print when the run captures every test for another reason: a project with no git whose source gets a new line prints no `not seen` line.
- The reason line comes before the `warn_unchecked` line.
- A file edited while the capture runs (the first case of `probe_window.rb`): the next run captures every test.
- The record that the check accepts is the record that is saved: pass a `work_tree:` record that says the view is `strict`, with the view `plain` on disk and a saved map from `plain`. The run must capture every test (Codex finding 9).
- A cache with no `"work_tree"` key captures every test and prints no `coverage cache:` line. A record whose `"dirty"` is not a Hash does the same.
- A source and a test that are in the saved map and not in this run: an edit to one captures every test (KTD11).
- Three runs of an unchanged project with `--cache-dir .` (the cache folder is the project root): the second and third reuse the map.
- KTD6, one test for each row, with a project whose test reads the file: a `.mutineer.yml` in a subfolder and a file below `test/.mutineer/` each capture every test when they change. The root `.mutineer.yml`, a file below the root `.mutineer/`, a file-swap lock and the two own paths do not.
- A path with a newline in its name prints with `?` in the line.
- **Table test** ("Test the rule, not the example"). Each row is written out with its expected result, not computed from the rule under test. Path kinds, at least: a view, a fixture, a lock file, a dotfile, a docs file, a Ruby file that no test loads, a file with a space in its name, a nested path, a run source, a run test, a loaded helper, an ignored file. Change kinds, at least: edit, delete, new untracked file, rename, stage, commit after the edit, edit before the first run and no change after, edit before the first run and restore after, mode change. Each row that expects "every test" also asserts that the line names the path. The 40 rows of `probe_edges.rb` are the base.

`test/coverage_map_test.rb` or `test/boot_mode_test.rb`: one boot-mode test (`build_via_fork`) for AE1. AE11 beside the existing `test_coverage_from_rejects_a_capture_that_does_not_fit_the_run`, with three more cases: a capture that has no `"work_tree"` key, a capture whose `"work_tree"` is a String (the "not the shape" reason), and a project with an untracked nested repository (exit 2 with the "cannot be fingerprinted" reason). One more: a capture run with `--output capture-report.json`, then a `--coverage-from` run, is accepted.

`test/runner_test.rb` or `test/boot_mode_test.rb`: `Runner.execute` passes a record to `CoverageMap.new` that it took before the boot file loads. Use a boot file that edits a data file when it loads: the next run captures every test.

`test/daemon_coverage_test.rb` (runs in `rake test:daemon`): build the cache as `test_cache_hit_skips_a_red_test_that_covers_no_source_on_the_daemon_path` does. Then write a new file `config/probe_595.yml` in the fixture app, set `MUTINEER_FLUNK_PRICE_LIST`, and build again. `failed_clean_tests` must hold `test/models/price_list_test.rb`: a fresh capture ran it, a cache hit would have skipped it. Remove the file in `ensure`. The fixture app is a subfolder of this repository, so the test also covers a project root below the git root.

`test/daemon_backend_contract_test.rb`: `boot_config` holds `own_paths` with the expanded `--output` and baseline paths, and `[]` when neither is set.

`test/cli_test.rb`, `test_empty_full_scan_warns_unless_allow_empty`: its project has no git, and its second run reuses the map. It asserts an empty stderr. Assert the line of state 5 there in place of `assert_empty`. This is the only test of the 2,551 that failed with the prototype (see "Suite runs").

**Step 9. Docs** (the author self-check skill looks for doc copies that are left stale: this is the list of copies).

- `docs/cli.md`, the cache text that starts "Coverage uses a digest-keyed cache". Give it its own heading, `### Coverage cache: what captures every test again`, with three parts:
  1. A list of the triggers: the ones of today, plus "any other changed file in the project that git lists (tracked, or untracked and not ignored), such as a view, a fixture or a lock file". Add one sentence: an edit that was already in the saved map does not capture again when it is committed.
  2. A table `Line you see | What it means | What to do`, with the exact stderr text of each row of step 5 and of the `--coverage-from` refusal. The "what to do" for a file that a test or a tool writes on every run: add it to `.gitignore` (#N2). Say that `--verbose` lists every path.
  3. A "Not seen" list: a file that git ignores, a file outside the project root, a project where git gives no answer, and Mutineer's own files (the list of KTD6), with the one remedy (delete `coverage.json` in the cache directory) and #N1. Replace the two sentences about data files and other files that are not Ruby with this list. The second of those sentences comes from pull request #601 and names #595.
- `docs/cli.md`, the `--coverage-from` bullet of the clean-check list: one sentence. A capture from an earlier version, or one whose project files changed since, is refused with a reason.
- `docs/cli.md`, the `load_path` row: the last sentence says other files there are not part of the key (#548). Reword: a file there that git lists is seen; a `load_path` directory outside the project root is not (#N1).
- `docs/ci.md`, beside the `fetch-depth: 0` row: a cache of `.mutineer/` that CI restores needs the commit of its run in the clone; a map that a `pull_request` run saved at a merge commit is not reused by a later run.
- `README.md`, step 3 of "How it works" ("or a project file the tests load recaptures every test"): add the changed-file rule in one clause.
- `CHANGELOG.md`, under `## [Unreleased]`: one entry under `### Fixed` (what was wrong, the three file kinds, the new line), and one entry under `### Changed` that lists the behaviour changes, one sentence each: a cache from an earlier version rebuilds once; a run in a project with no git prints a line on each reuse; a file that changes on every run stops every reuse; `--coverage-from` refuses a capture from an earlier version, and refuses every capture while the project holds a path that cannot be fingerprinted.
- `.expectation-fit/decisions/coverage-and-test-selection.md`: update "Coverage Map Rebuild Triggers" to name the fourth trigger, and add three lines of one check each:
  - "**Work-tree check fails closed.** When the saved map has a git commit and git cannot list the changed files now, the run captures every test and says why (#595)."
  - "**No-git limit line.** A reuse with no git answer at all prints the limit line with its remedy. Not when: the run captures every test for another reason (#595)."
  - "**Own files of the coverage check.** A new file that Mutineer writes into a project goes on the list of `WorkTreeCheck#own_path?` or `#own_rels`, or every second run captures every test (#595)."
- `docs/plans/2026-11-27-595-fix-stale-coverage-map-plan.md`: the copy of this plan (rule 14 of `RULES.md`).

**Step 10. Comment on #548:** what this pull request fixes for it (a data file that git lists, below the project root, is now seen), what is left (N1), and that David can close it.

### U2. A file that is edited while a run is in progress is seen by the next run (new issue N3)

Commit: `fix: a source or test edited while a capture runs is captured again (#N3)`. `Closes #N3`.

**Files:**

- `lib/mutineer/coverage_map/work_tree_check.rb`: new private `cache_sees_change?(cached, rel)`. It collects the saved fingerprints of `rel` in `cached["sources"]`, `cached["tests"]` and `cached["dependencies"]`. It returns true when there is none, when the file is missing, when one of them differs from `file_fingerprint` of the file now, or on `SystemCallError`. In `unscoped_changes`, a scoped path is now left out only when `cache_sees_change?` is true. Else its cause is `:during_run`.
- `changed_files_reason`: the `:during_run` text of step 5.
- `docs/cli.md`: one more row in the table of lines. `CHANGELOG.md`: one more entry under `### Fixed`.

**Why this is enough:** the first kind of `unscoped_changes` already drops a path that is unchanged since the record. A scoped path that is left has changed since the record. If the cache's own fingerprint differs from the file, the digest, `partial_plan` or `dependencies_match?` handles it, as today. If it is equal, the cache saved the new text after the tests ran, and only the record knows about the change.

**Tests** (`test/coverage_map_work_tree_test.rb`):

- AE13, from the second case of `probe_window.rb`: a test file rewrites a method body of a source while it loads. The next run captures every test, the line is the `:during_run` text, and the map equals a fresh capture.
- The same for a test file that another test rewrites, and for a loaded helper.
- A body edit between two runs still gives a partial recapture (AE3 again, now with U2 in place). A test edit between two runs recaptures that test only.
- A source that is edited before the first run and committed after it gives a reuse.
- A run under `--strategy reload` writes each mutant into the source file and restores it. A second run of an unchanged project reuses the map (one test through `Runner.execute`).

### Commit order

U1, then U2. A fix from review goes in a new commit that names its issue.

---

## Decisions for David

The run takes the recommended option. David can change each one before the merge.

| # | Choice | Recommended | Why | Other option |
|---|---|---|---|---|
| D1 | How to know what changed | The commit of the run plus the files that differed from it (KTD2) | The record stays small, and plain git commands give the list. | A list of every tracked path and blob id. It works in a shallow clone, and it costs a larger record and more git rules (see "Design that was compared"). |
| D2 | How far the check looks | Below the project root (KTD8) | It matches the scope of the loaded-file check, and a change in another part of a large repository does not stop every reuse. | The whole repository. Safer for an app that loads code from a sibling folder, and it would stop most reuses in a monorepo. |
| D3 | When the record is taken | Before the app loads (KTD4) | A file edited during a boot or a capture is then seen. The probe showed a stale map with the other option. | At save time. It keeps the reuse when a test writes a new file on each run, and it misses an edit made during the capture. |
| D4 | A project with no git | Keep the reuse and print one line on each reuse (R4) | A full capture on every run would remove the cache for such a project. The line makes the gap visible, and the gap is older than this change. | Capture every test on every run. Or print the line only with `--verbose`. |
| D5 | Which of Mutineer's own files are left out | The list of KTD6, with the root `.mutineer.yml` and the baseline | An edit to `ignore:` or a new baseline is a normal step between two runs. A test that reads those files is very rare, and the docs name the rule. | Only the files Mutineer writes (the cache file, the locks, the report). Then each edit to `.mutineer.yml` captures every test once. This is the stricter option that Codex asked for. |
| D6 | Files that "cannot matter", such as docs | No such list (KTD7) | A test can read any file. On Fizzy the rule costs no reuse. | Leave out `*.md`. Or add a `cache_ignore:` setting now (limit L4). |
| D7 | #548 | `Refs #548`, with a comment that says what is left. It stays open and in `backlog`. | Its case is fixed only for files that git lists below the project root. | Close it, because N1 tracks what is left. |
| D8 | The older gap for a file edited during a run (U2) | Fix it in this pull request, as a second commit that closes N3 | With the record in place the fix is one method and one condition, and the probe shows a stale map on `main`. | File N3 and leave it for later. The builder takes this option alone if U2 is not green in one session. |
| D9 | When to build | After pull request #601 (11-E) merges | Both edit the same paragraph of `docs/cli.md` and the same part of `CHANGELOG.md`. | Build now and merge `main` into the branch after #601 merges. |
| D10 | Build effort | Opus 5.5, `high` | Cache validity code: a mistake gives a wrong map with no message. | `medium`, as the worklist says. |
| D11 | Labels of the pull request | `bug`, `priority: high`, `risk: medium`, `v1.11.0` | They are the labels of #595. | None. |
| D12 | A file with git's assume-unchanged or skip-worktree flag | Mutineer fingerprints each one itself, on disk or not (KTD2) | Git reports no edit to such a file and no removal by a sparse checkout, and developers use the flags for local config files. One more git command. In a sparse checkout the record gets one entry for each left-out file below the project root. | Name it as a limit in N1. |
| D13 | A report or baseline that an earlier run wrote | The saved map keeps the own paths of its run (KTD6) | Else a run that does not name the old report captures every test once, and a `--coverage-from` run refuses a capture because of the capture run's report. | Only this run's paths. The docs then say to write reports below `.mutineer/`. |

---

## Cost: how often a full capture now happens

From `reports/11-F-measurement.md`, section 4 (133 merged Fizzy pull requests that change a source, map from `main`):

| | Pull requests | Share of 133 |
|---|---|---|
| Reuse the map today, as the script counted | 17 | 12.8% |
| Reuse the map after this change | 11 | 8.3% |
| Lose a reuse | 6 | 4.5% (35% of the 17) |

- Each of the 6 is a case where the reused map could be wrong: a view, an asset or a lock file changed too.
- The script counted a pull request with a fixture or a config Ruby file as "no reuse" already. Today's cache does not see some of those files. So the true number before is 17 or more, and the number that lose a reuse is 6 or more. The row data of the script was not kept, so the exact number is not known. The number after the change, 11, is exact for these 133.
- A docs file counts as a change (KTD7). The 11-F plan checked this: the 11 stay 11.
- Time for each lost reuse on Fizzy: 43 s of 315 s and 49 s of 367 s, which is 13% of the run. The reuse saves that little today because the clean check takes most of it back.
- A pull request that changes no source has no mutant under `--since`. It builds no map and pays nothing.

Not in the data (one developer's computer):

- Each edit to a view, a fixture, a data file, a docs file or a config file between two runs now captures every test once. That is the fix.
- A file that changes on every run and that git does not ignore stops every reuse until it is ignored (L4).
- A test or a source that is edited while a run is in progress captures every test on the next run (U2).
- The check itself: six git commands for each run that builds a map, and three more when `HEAD` moved since the saved map. Measured in this repository (669 tracked files, 9 changed paths): 0.12 s for one record. A work tree with many changed or untracked files adds one file hash for each.

---

## Risks

| Risk | Effect | Guard |
|---|---|---|
| `unscoped_changes` or `own_path?` leaves out a path that a test reads | A stale map, as today, for that path | The table test has a written result for each path kind. KTD6 is a short, exact list, and each row of it has a test with a test file that reads the path. |
| A project's tests write a file that git does not ignore | Every run captures every test | The line names the file. The docs say to ignore it. Limit L4. |
| A test of this repository reuses a map in the repository's own work tree (`project_root: ROOT`) while a developer edits a file | That test fails once | With the prototype no such test failed in four full runs. A rerun passes. |
| Git prints a path in another form than Ruby's real path (Unicode forms on macOS) | A changed source is not known as a source: every test is captured | The safe side, and the line names the path. |
| The daemon cannot run git (no `PATH`, another owner of the folder) while the tool can | State 2 when the saved map has a commit, else state 5: a line on each run | `rake test:daemon` and the new daemon test. |
| A very large untracked file | It is hashed on each run | It is read in blocks. The remedy is `.gitignore`. |
| U2 refuses a reuse that is safe | A slower run with a line | The tests of U2 for a body edit, a test edit, a commit, and a reload run. |
| Pull request #601 merges after the branch is cut | Conflicts in `docs/cli.md` and `CHANGELOG.md` | D9. |

---

## Limits left open

The builder files N1, N2 and N3 in step 0, with all four labels, and puts the numbers in the code, the docs and the pull request body.

| # | Limit | Issue |
|---|---|---|
| L1 | A change that git does not list is not seen: a file that git ignores (`.env`, built assets, `node_modules`, an ignored `Gemfile.lock`), a change that a git filter hides (line endings, a clean filter), a rename that changes only letter case on a file system that ignores case, and a submodule that is emptied with `git submodule deinit`. A mode change with `core.fileMode` off is seen only for a file that git already lists. | N1 |
| L2 | A project in no git work tree keeps today's gap. So does a project where git is not installed, or where git refuses the folder. A line says so on each reuse. | N1 |
| L3 | A change outside the project root is not seen: another folder of a larger repository, or a `load_path` directory outside the root (its `.rb` files are in the digest, its data files are not). | N1, and the comment on #548 |
| L4 | These capture every test on every run, with a line: a file that changes on every run and is not ignored, an untracked nested repository, a changed submodule, a changed path that is not valid UTF-8, a work tree with no commit, and a clone that lacks the saved commit. Under `--coverage-from` each of them is a refusal with exit 2 on every run, and a new capture does not help: the remedy is to ignore or remove the path. | N2 |
| L5 | A changed Ruby file that the tests load captures every test with no line, as before this change. | N2 (one sentence) |
| L6 | A project whose own tests read its root `.mutineer.yml`, its baseline file or a file below its root `.mutineer/` keeps the gap for those files (KTD6, D5). | N1 (one sentence) |
| L7 | The cost numbers are from one app. The Fizzy run of the measurement was not repeated with the fix. | No issue: this is not left-over work. `rake fizzy:sample` is the release gate and runs with the fix. |
| L9 | State 2 does not print git's own error text. The line says to run `git status`. | N2 (one sentence) |
| L10 | `--since` (`ChangedLines`, `CLI.validate_since!`) still runs git with inherited `GIT_DIR` and `GIT_INDEX_FILE`. `WorkTree` does not. | N2 (one sentence) |
| L8 | If U2 is dropped: a source, a test or a loaded file that is edited while a capture runs is saved as current. | N3 stays open, `backlog` |

### N1: The coverage cache does not see a change that git does not list, a change outside the project root, or any such change in a project with no git

Labels: `bug`, `priority: low`, `risk: low`, `backlog`.

```text
**Claude:** Left open by the fix for #595. Related: #548.

## What

Since the fix for #595, a run captures every test when a project file changed that git lists. These changes are still not seen:

- a file that git ignores;
- a file outside the project root;
- any file that is not a source, a test or a loaded Ruby file, in a project with no git work tree;
- a change that git itself does not report: line endings or a clean filter, a rename that changes only letter case, a submodule that is emptied.

## Why

A test can read such a file, for example a `.env` file, a built asset, or a data file in a `load_path` directory outside the project. After an edit, the next run keeps the old coverage map. A mutant can then run without a test that covers it. Estimate: rare. It needs a file of these kinds that changes which source lines a test reaches, an edit to it, and a saved map.

## How (ideas, not decided)

A setting where the user lists more files or globs that the cache must check. For a project with no git: a fingerprint of every file below the project root, if that is fast enough.

---

- A project where git gives no answer gets one stderr line on each reuse of a map. That line links to this issue.
- Mutineer's own files (the root `.mutineer.yml`, the baseline, the `.mutineer/` folder in the project root) are left out of the check. A project whose tests read them has this gap for them.
- The remedy today: delete `coverage.json` in the cache directory once.
```

### N2: A file that changes on every run makes every run capture every test

Labels: `enhancement`, `priority: low`, `risk: low`, `backlog`.

```text
**Claude:** A cost of the fix for #595.

## What

A run captures every test when a project file changed that Mutineer cannot tie to a test. A file that a test or a tool writes on every run, and that git does not ignore, then stops every reuse of the coverage map.

## Why

The run is correct, and it is slow each time. The stderr line names the file, and the remedy is `.gitignore`. Some files cannot be ignored: a tracked file that a tool rewrites, a submodule with local changes, an untracked nested repository. A clone that lacks the commit of the saved map (a shallow clone in CI) and a work tree with no commit also capture every test each time.

Estimate: not measured. Mutineer's own suite (2,551 tests) and its Rails fixture app write no such file. A known case is RSpec's `spec/examples.txt` in a project that does not ignore it.

## How (ideas, not decided)

A `cache_ignore:` setting with paths or globs that the user declares safe. A record that needs no commit in the clone (a list of paths and blob ids). A reason line when a loaded Ruby file changed: that case captures every test with no line today.

---

- With `--coverage-from`, each of these cases is a refusal with exit 2, and a new capture does not help.
- When git cannot list the changed files, the line does not show git's own error. It says to run `git status`.
- `--since` still runs git with an inherited `GIT_DIR` or `GIT_INDEX_FILE`. The coverage check does not.
- Done when: a user can keep a reuse with such a file in the project, and the docs say how.
```

### N3: A file that is edited while the coverage capture runs is saved as current

Labels: `bug`, `priority: medium`, `risk: low`, `v1.11.0` (unit U2 of this plan closes it; `backlog` if U2 is dropped).

```text
**Claude:** Found while we planned the fix for #595 (2026-11-27, main at 6c71ccba).

## What

The coverage cache takes the fingerprints of the sources, the tests and the loaded Ruby files when it saves the map, after the tests ran. An edit to one of them while the capture runs is saved as the current state.

## Why

A test that ran before the edit built its part of the map from the old text. The next run sees no change and reuses the map. Probe: two tests, and the second one rewrites a method body of the source while it loads. On the second run no test is captured again, and one source line has no test where a fresh capture lists one. A capture of a large app takes minutes, so an edit in that time is likely for a person or an agent at work.

## How

The fix for #595 records the state of the work tree before the app loads. When that record says a file changed and the cache's own fingerprint says it did not, the file changed during the run. The next run then captures every test.

---

- Done when: the probe captures every test on the second run, and a body edit between two runs still recaptures only its tests.
```

---

## Suite runs with the prototype (planning, 2026-11-27)

| Prototype | `bundle exec rake test` |
|---|---|
| First: the record taken in `save` | 2,551 runs, 3 failures. Two were tests in `test/since_test_scope_test.rb` whose test files write marker files into the project and delete them between runs. |
| Second: the record taken at the start of `cached_or` | 2,551 runs, 1 failure: `CliTest#test_empty_full_scan_warns_unless_allow_empty` (step 8). |
| Third: the record before the boot, the exact own-file list, U2 | 2,551 runs, 1 failure, the same test. |
| Final: this plan (U1 and U2, after both reviews) | 2,551 runs, 26,859 assertions, 1 failure, the same test, 6 skips as on `main`. 8 min 54 s. |

`bundle exec rake yard:strict` on the second prototype: 100%. Not run again on the final prototype.

`bundle exec rake test:daemon` on the final prototype: 88 runs, 0 failures, 26 skips (the PostgreSQL and MySQL tests need a server). No second run of the unchanged fixture app captured every test. The new daemon test of step 8 does not exist yet.

### Not run in planning

- The Minitest 6 and Prism 2 suites. The change touches neither area.
- The Fizzy run of the 11-F measurement with the fix (L7).

---

## Verification Contract

| Check | Expect |
|---|---|
| `ruby -Ilib <copy>/probe_stale.rb` from the worktree. Copy the three probes from `reports/11-G-plan-data/` to a scratch folder first. Do not commit them. | `stale maps: 0 of 4`. On `main` it prints `4 of 4`. |
| `ruby -Ilib <copy>/probe_edges.rb` | `40 of 40 as expected` |
| `ruby -Ilib <copy>/probe_window.rb` | Both cases `ok` after U2. After U1 alone the second case is `STALE`. |
| `bundle exec rake test` | Green, with the changed `cli_test.rb` test |
| `bundle exec rake test:daemon` | Green, with the new daemon test. No second run of an unchanged fixture app captures every test. |
| `ruby -Ilib -e 'require "mutineer"'` | Loads |
| `ruby -e 'require "./lib/mutineer/work_tree"'` | Loads with no other Mutineer file but `fs_path` (the daemon rule). Ran in planning: it loads. |
| `bundle exec rake yard:strict` | 100%. The constants and every private method of the new files have a comment. |
| `bundle exec rake site:build` and `node --test test/site_test.js` | Green: `docs/cli.md` and `README.md` change. |
| The author self-check skill, then `/ce-code-review`, `/fit-review`, `/cubic-loop` in local mode | Rule 6 of `RULES.md` |

## Definition of Done

- The four cases of the reproduction capture every test and print the line.
- Every row of the table test passes.
- The three "done when" cases of #595 (a view, a fixture, a lock file) each have a test that asserts the captured files, the line, and a map equal to a fresh capture.
- N1, N2 and N3 are filed with four labels each, and their numbers are in the code, the docs, the CHANGELOG and the pull request body.
- The pull request body has What, Why, How, "Decisions for David" (D1 to D13 as taken), the cost table, "Planned by" and "Built by".

---

## Files this group changes

| Kind | Files |
|---|---|
| New code | `lib/mutineer/work_tree.rb`, `lib/mutineer/coverage_map/work_tree_check.rb` |
| Changed code | `lib/mutineer/coverage_map.rb`, `lib/mutineer/coverage_map/capture_reuse.rb`, `lib/mutineer/coverage_map/skeleton_digest.rb`, `lib/mutineer/job_plan.rb`, `lib/mutineer/runner.rb`, `lib/mutineer/daemon_backend.rb`, `lib/mutineer/daemon_server.rb` |
| New tests | `test/work_tree_test.rb`, `test/coverage_map_work_tree_test.rb` |
| Changed tests | `test/cli_test.rb`, `test/daemon_coverage_test.rb`, `test/daemon_backend_contract_test.rb`, and `test/coverage_map_test.rb` or `test/boot_mode_test.rb` (and `test/runner_test.rb` if the boot test goes there) |
| Docs | `docs/cli.md`, `docs/ci.md`, `README.md`, `CHANGELOG.md`, `.expectation-fit/decisions/coverage-and-test-selection.md`, `docs/plans/2026-11-27-595-fix-stale-coverage-map-plan.md` |
| Not changed | `lib/mutineer/coverage_map/cache.rb`, `lib/mutineer/changed_lines.rb`, `lib/mutineer/cli.rb`, `action.yml`, the JSON schema |

---

## Overlap with pull request #601 (group 11-E)

| File | #601 | This plan | Conflict |
|---|---|---|---|
| `docs/cli.md` | Adds one sentence to the cache paragraph. It names #595 and says to delete `coverage.json`. | Rewrites that paragraph. The #601 sentence goes away. | Yes, in the same lines. |
| `docs/ci.md` | Rewords one paragraph about pack source folders. | Adds one sentence beside the `fetch-depth: 0` row. | No. Other lines. |
| `CHANGELOG.md` | Adds entries under `Added`, `Changed` and `Fixed`. | Adds two entries under `Fixed` and one under `Changed`. | Likely, in the same lists. |
| `lib/mutineer/runner.rb` | 3 lines near `narrow_tests_for_since`. | 3 lines near the boot, and the two `CoverageMap.new` calls. | No. Other hunks. |
| `lib/mutineer/daemon_backend.rb` | 1 line in the run setup. | 1 key in `boot_config`. | No. Other hunks. |
| `test/cli_test.rb`, `test/daemon_backend_contract_test.rb` | New tests. | One changed test and one new test. | No. Other hunks. |
| `lib/mutineer/cli.rb`, `reporter.rb`, `pairing.rb` | Changed. | Not touched. | No. |

Build after #601 merges (D9). Then the branch starts from a `main` that has the #601 sentence, and the builder rewrites it.

---

## Open Questions

1. D5: is it right to leave the root `.mutineer.yml` and the baseline out of the check, or does David want the stricter list?
2. D4: is one stderr line on each reuse right for a project with no git, or is it too loud?
3. D7: does David want #548 closed when this merges?

---

## Second opinions

- **Codex second opinion** (`gpt-6-astra`, effort high, read only) on the first full text and the first prototype. 13 findings, and it disagreed with `go` on that text. Full text: `reports/11-G-plan-codex.md`. Ten are applied, three are named limits:
  - 1 (the assume-unchanged and skip-worktree flags hide edits): applied. `changed_since` lists each flagged file, and Mutineer fingerprints it (KTD2, D12).
  - 2 (line endings and clean filters), 5 (a rename that changes only letter case), 6 (an emptied submodule): limits, in L1 and issue N1. Each needs a record of every tracked file, which is the other design of D1.
  - 3 (file modes): applied. The fingerprint holds the mode (KTD9).
  - 4 (inherited `GIT_DIR` and other variables): applied. `WorkTree` runs git without them (KTD10).
  - 7 (the own-file list was too wide) and 12 (`--cache-dir .`): applied. The list is exact now (KTD6). The root `.mutineer.yml` and the baseline stay on it: D5 gives David the stricter option.
  - 8 (a source of the saved map that this run leaves out): applied (KTD11).
  - 9 (the check and the save used two snapshots): applied. One record for each run (KTD4).
  - 10 (the record was taken after the app boot): applied. `Runner.execute` and `DaemonServer#boot!` take it before the boot (KTD4).
  - 11 (`scrub` on a binary string does nothing, and `save` then raises): applied, with a test that runs on macOS too.
  - 13 (the edge probe proves a class, not a map): applied in step 8. Each row of #595 compares the map with a fresh capture, the table test has written results, and each row of KTD6 has a test whose test file reads the path.
- **`/fit-validate-plan`**, round 1, on the text after the Codex fixes. Verdict "Ready to implement", no blocking finding, lowest score 5 of 10. 27 findings in 24 rows (12 P2, 15 P3): 20 rows are fixed, 3 are fixed in part and 1 is fixed with one part declined. Table: `reports/11-G-plan-fit-validate-round1.md`. The main changes from it:
  - The simplicity lens showed with a probe that a file which a sparse checkout removes was not seen. Every flagged file is listed now.
  - The predictability lens showed that a report of the last run was a changed file for the next run, and that `--coverage-from` refused a capture because of the capture run's own report. The record keeps its own paths now (D13).
  - Each stderr line has its own text and a next step (step 5). The check prints in one place, and the no-git note prints only on a reuse.
  - Names: `work_tree` for the key, `own_paths` for the keyword, and `head` returns a commit id or nil.
  - Declined: git's own error text in the state 2 line (L9), a record of repeat refusals, and a line for the one rebuild after an upgrade.
- No second round of either review ran. The prototype and the three probes were run again after the changes: 4 of 4, 40 of 40, and both window cases.

---

## Verdict

**`go`.** The defect is reproduced on `main` in four cases, the prototype removes all four and gives the planned result in 40 edge cases, and the new check can only turn a reuse into a full capture with a reason line (or, under `--coverage-from`, into a refusal with exit 2).
