# Mutineer JSON report — schema reference

`mutineer run --format json` emits a single JSON object (one line, newline-terminated) describing the
whole run. Use it for CI checks, dashboards, and AI coding agents. Arrays have a
fixed sort order, independent of `--jobs` worker completion order. For the same
inputs and results, JSON output is byte-identical. Results can still vary if
the tests or environment change. `survivors[]` sorts by
`(file, line, operator)`; `killed[]`, `no_coverage[]`, `uncapturable[]`, `ignored[]` and `baseline.new_survivors`
add `id`, as does `matrix.mutants`; `baseline.fixed_survivors` sorts by `(file, line, operator)`;
`no_verdict[]` by `(file, line, id, status, details)`; `per_source[]` by `file`;
`unpaired_sources[]` by `file`; `unmutated_subjects[]` by `(file, line, subject)`. One exception:
`details` of an errored mutant can quote run-specific text (see `no_verdict[]`).

## Versioning contract

The top-level `schema_version` (a string, e.g. `"1.10"`) follows these rules:

- **Additive changes** (new keys on existing objects, new top-level keys) bump the **minor** version
  (`1.0` → `1.1`). Existing keys keep their meaning. Consumers MUST ignore unknown keys.
- **Breaking changes** (renaming/removing a key, changing a value's type or meaning) bump the **major**
  version (`1.x` → `2.0`).

A consumer should accept any `1.x` document and read only the keys it knows.
Compare versions as two integers, major then minor, not as decimals: `1.10` comes after `1.9`.

Compare `schema_version` as two integers, major then minor, so `1.10` follows `1.9`.

Mutant `id` values are opaque identifiers. How an id is derived is versioned by
`summary.id_format`, not by `schema_version`: when `id_format` changes, every id
value can change while the key keeps its type and meaning. Compare ids only
between reports with the same `id_format` (a missing key is the old format).

The stability contract lists every versioned surface.
This schema is one of them.
See [STABILITY.md](https://github.com/davidteren/mutineer/blob/main/STABILITY.md).

## Top-level shape

```jsonc
{
  "schema_version": "1.10",
  "summary":      { /* run totals, see below */ },
  "survivors":    [ /* mutants the suite failed to catch; review for test gaps or equivalent behaviour */ ],
  "killed":       [ /* mutants a test caught; lean ids for joining runs (#361) */ ],
  "no_coverage":  [ /* mutants on lines no test exercises, or a continuation whose sentinel the tests did not write (#254, #289, #345) */ ],
  "uncapturable": [ /* mutants whose would-be test errored during coverage capture */ ],
  "unplaceable":  [ /* mutants the strategy cannot load where the tests call them; not run */ ],
  "ran_at_load":  [ /* mutants on a line that ran while the app or class loaded; no verdict */ ],
  "no_verdict":   [ /* mutants that were attempted and produced no verdict */ ],
  "ignored":      [ /* mutants the user suppressed (equivalent mutants) */ ],
  "per_source":   [ /* per-file roll-up */ ],
  "unpaired_sources": [ /* sources with no paired test, sorted by file */ ],
  "unmutated_subjects": [ /* methods the selected operators did not mutate */ ],
  "matrix":       { /* present ONLY with --matrix: which tests kill which mutants */ },
  "baseline":     { /* present ONLY with --baseline: the delta vs a prior run */ }
}
```

### `summary` (object)

| Key | Type | Meaning |
|-----|------|---------|
| `total` | int | Classified results included in this report, across all statuses. With `--fail-fast`, unscheduled candidates are omitted, so this is not the full generated candidate count. Mutants in sources with no paired test are not in `total`. |
| `killed` | int | Mutants a test caught (suite went red). |
| `survived` | int | Mutants no test caught. Review each for a missing test or equivalent behaviour. |
| `no_coverage` | int | Mutants on a line no test exercises (excluded from score). Also a mutant on a later line of a multi-line statement (#254, #289) — the right side of `a &&` on its own line, or a call inside a one-line block — when the tests of that statement did not kill it and the probe did not see the mutated expression return during a test (#345). The probe is a sentinel the child writes the first time that expression returns during a test; a load-time call and a raise inside the expression do not write it. Mutineer ran the tests that ran the statement's other lines (for a one-line block, the first or last line, never the `def` line). A survivor the probe saw return is `survived` and counts in the score. The probe covers a trailing operator, a method chain, a multi-line argument, a hash entry, and a heredoc interpolation. |
| `uncapturable` | int | Mutants whose covering test errored during capture — a broken harness, not a gap (excluded). |
| `unplaceable` | int | Mutants the strategy cannot load where the tests call them, so they were not run (excluded): under `--strategy redefine`, a method whose class or module cannot be named statically, or any method in a concern's `included` or `prepended` block; under `--strategy reload`, some methods in such a block. The causes are listed under `unplaceable[]` below. Not part of `no_verdict`, so they do not fail `--threshold`. Additive key (schema `1.7`). Counted in the unrun share: when `unplaceable + skipped_invalid + unpaired_mutants` is more than 1 and more than 10% of `attempted + unplaceable + skipped_invalid + unpaired_mutants`, stderr warns on every format. `--fail-fast` leaves `unpaired_mutants` out of that sum. The warning does not change the exit code (schema `1.9`, #291). |
| `ran_at_load` | int | Mutants on a method-body line that ran while the app booted or the class loaded, before the mutant was applied (excluded). A test can check a value the original code computed then, so a survivor there is not trusted, and a line that only ran at load is not a coverage gap. A kill stays a kill. Not part of `no_verdict`, so they do not fail `--threshold`. `--test-command` re-runs the load and verifies them. Additive key (schema `1.7`). |
| `skipped_invalid` | int | Mutants that didn't re-parse and were never run (excluded). Counted in the unrun share: when `unplaceable + skipped_invalid + unpaired_mutants` is more than 1 and more than 10% of `attempted + unplaceable + skipped_invalid + unpaired_mutants`, stderr warns on every format. `--fail-fast` leaves `unpaired_mutants` out of that sum. The warning does not change the exit code (schema `1.9`, #291). |
| `declined` | int | Candidates the operators found and did not mutate, so they are not in `total`: a heredoc the edit would split, or an equivalent skip listed on the [equivalent-skips page](equivalent-skips.md). Counted per operator, so a candidate two operators decline counts twice. Counted before `# mutineer:disable-line` and `ignore:` apply. `--only` narrows it; `--since` does not. Additive key (schema `1.9`, #291). |
| `declined_by_operator` | object | The same count per operator name, operator name => int, only operators above zero, keys sorted. `{}` when none. Additive key (schema `1.9`, #291). |
| `subjects` | int \| null | Methods found in the run's sources, each counted once. Methods, not mutants, so not in `total`. `--fail-fast` does not narrow it: it counts every method found, while `total` omits unscheduled mutants, so the two are not one denominator. `--since` keeps methods whose `def` intersects the diff, matching `unmutated_subjects` (#420). `null` only when a program calls the reporter without both method counts (one alone counts as none); the CLI always fills both. Additive key (schema `1.10`, #386). |
| `unmutated_subjects` | int \| null | Methods the selected operators gave no mutant, an empty method included. `unmutated_subjects[]` below lists them. Decided before the run, so `--fail-fast` does not narrow it. `--since` keeps methods whose `def` intersects the diff (#420). `null` when `subjects` is `null`. Additive key (schema `1.10`, #386). |
| `errored` | int | Mutants whose run crashed, or whose first failed Minitest test or RSpec example had a database connection or lock error (excluded). Each one is in `no_verdict[]` with `status` `"error"`. |
| `timeout` | int | Mutants whose run exceeded the per-mutant timeout (excluded). |
| `ignored` | int | Mutants suppressed via `# mutineer:disable-line` or `.mutineer.yml` `ignore:` (excluded). Under `--since`, only those on changed lines. |
| `attempted` | int | Mutants actually run: `killed + survived + no_verdict`. **Not** `total` — no-coverage, skipped and ignored mutants are not counted as attempted (a #254 or #289 no-coverage mutant did run its statement's tests; #345 keeps it no-coverage only when the mutated expression did not return during a test). |
| `no_verdict` | int | Attempted mutants that produced no verdict: `errored + timeout + uncapturable`. The completeness gate is `no_verdict / attempted`. |
| `score` | float \| null | `killed / (killed + survived) * 100`, rounded. **`null`** when the denominator is empty (no covered mutants) — never `0.0`. |
| `scoped` | bool | `true` when the run was diff-scoped (`--since`): the score covers only the changed-line mutants, so it is not comparable to a full-run score. A scoped CURRENT run skips `--baseline`'s score-drop check (new-survivor detection still applies); a scoped report is REFUSED as a baseline (exit 2) because survivors outside its diff would read as new regressions. Additive key (absent in reports from older versions; treat absent as `false`). |
| `id_format` | int | The mutant id format. `2` means ids include the project-relative file path (1.3 and later). **Read this key, not `schema_version`, to learn the id format.** Absent in older reports: treat absent as the old format, whose ids did not include the path and can collide across files. Additive key (schema `1.4`). |
| `legacy_id_matches` | object | `{ ignore, baseline }`, two ints. `ignore` counts `.mutineer.yml` `ignore:` entries in the old id format that matched this run (replace them with the new ids the run prints). `baseline` counts survivors that matched an old-format `--baseline` only through their old id (regenerate the baseline). Both are `0` when nothing old matched. Old-format matching is removed in 2.0. Additive key (schema `1.4`). |
| `unpaired_sources` | int | How many sources had no paired test. `--only` and `--since` can leave a source at 0. The source stays in this count. Additive key (schema `1.10`, #381). |
| `unpaired_mutants` | int | Non-ignored scheduled mutants in those sources. A failed count is left out of the sum. These mutants are excluded from the mutation score and are not in `no_verdict`, so they cannot fail `--threshold`. The human share is this count over `total - ignored + unpaired_mutants`. `--fail-fast` omits that percentage. `0` can mean no mutant, or no changed line under `--since`. Additive key (schema `1.10`, #381). |

### `survivors[]` (array of object)

Each surviving mutant — the records an agent or reviewer acts on:

| Key | Type | Meaning |
|-----|------|---------|
| `subject` | string | Fully-qualified subject, e.g. `Calculator#add`. A method in a `class_methods` block in the body of a module that ran `extend ActiveSupport::Concern` earlier in the same file (or of a `Module.new` block assigned to a constant that did) is named on the module the includer extends, e.g. `Billing::ClassMethods#rate`. Any other `class_methods` method keeps its enclosing name, e.g. `Billing#rate` (`Billing.rate` in `class << self`), and is `unplaceable` under redefine. |
| `file` | string | Source file path, relative to the project root for a file inside the project (`./lib/x.rb` and an absolute path both report `lib/x.rb`); a file outside the project keeps the path as passed. |
| `line` | int | 1-based line of the mutation. |
| `operator` | string | Operator name, e.g. `arithmetic`, `comparison`. |
| `id` | string | **Offset-free id** (12 hex chars). Includes the file path relative to the project root (a source outside the root uses its absolute real path, so its ids differ between machines). Unrelated edits preserve it when the path, qualified method name, mutated token, and repeated-name/mutation order stay the same. File moves, renames, and root changes can change it. See [Mutant ids](https://github.com/davidteren/mutineer/blob/main/docs/results.md#mutant-ids). Paste into `.mutineer.yml` `ignore:`, or diff between runs (this is what `--baseline` matches on). |
| `token` | string | The exact code being mutated (whitespace-collapsed), e.g. `a + b`. |
| `diff` | string | A unified diff with no context lines: `-original` / `+mutant` lines under a hunk header that gives each side's start line and, when it is not 1, its line count (`@@ -3,2 +3 @@`). For a `file` given relative to the project root, `git apply --unidiff-zero` run from that root accepts it. An absolute or `../` path needs `git apply --directory`/`-p` or an edit. Ready to hand to an agent as "write a test that fails under this change." |

### `killed[]` (array of object)

Additive key (schema `1.10`, #361). Every killed mutant as
`{ subject, file, line, operator, token, id }`, sorted by
`(file, line, operator, id)`. Same lean shape as `no_coverage[]` (no `diff`).
`killed.length` equals `summary.killed`. Use this to join two runs by id
(for example Minitest vs RSpec on the same source) without subtracting every
unscored category from a full id list.

### `no_coverage[]`, `uncapturable[]`, `unplaceable[]` and `ran_at_load[]` (array of object)

Each entry is `{ subject, file, line, operator, token, id }`, sorted by
`(file, line, operator, id)`. `no_coverage` is a coverage gap: no test runs the line, or (#254, #289, #345) the tests that run a later line's statement did not kill the mutant and the probe did not see the mutated expression return during a test, so only a return of that expression that survives, or a test that kills it, clears the entry; `uncapturable` means the test that
should cover the line errored while capturing coverage (fix the harness, not the test). `unplaceable` (schema
`1.7`) means a `--strategy redefine` run did not run the mutant because its method's class or module cannot be
named statically (an anonymous `Class.new`, a relative path such as `User::Permission` inside a namespace,
a class or module opened or assigned in `class << self`, a `self::X` opened in a block or assigned in one
that does not build a class, a method in an `included` or `prepended` block, which ActiveSupport runs in each
includer, or a method in a `class_methods` block that is not in the body of a module known as a concern (see
`subject` above), such as one inside Rails' `concerning` or an unassigned `Module.new`); `--strategy reload`
runs these, except some methods in an `included` or `prepended` block.

Under `--strategy reload`, ActiveSupport runs a concern's `included` or `prepended` block only when a class first
includes or prepends the concern, so loading the file again does not reach a class that already has it (#256).
For a method directly in the block, Mutineer loads the mutated method into each host that already has it, and a
host that includes the concern later gets it from the reloaded block (#297). Nothing else in the block runs
again. Two methods in one block can therefore get different verdicts. `unplaceable` under reload means the
mutant's method is one of these:

- a method in a class, module, `Module.new`, `Struct.new`, `Class.new` or `Data.define` block inside the block;
- a method inside another method, or inside a block that does not build a class (such as `[1].each do`);
- a method with an explicit receiver other than `self` (such as `def base.tag` in `included do |base|`),
  because extracting the definition does not keep a receiver bound inside the hook;
- a hook-block method whose name and first line match another definition in the same file, including a
  collision between an instance and a singleton definition. The check reads all parsed `def`s, even when
  they are not selected as subjects, and explicit `define_method`, `define_singleton_method`, `attr_reader`,
  `attr_writer`, `attr_accessor` and `attr` calls. A positional lambda uses its own source line. When a
  callable body comes through a variable or another expression, the check includes possible block and
  lambda source lines in that file, including stored hook blocks. A matching-name or unknown-name
  indirect creator can therefore conservatively exclude a one-line hook. A dynamic name blocks only those
  possible body lines; a dynamic attribute name or writer flag blocks the attribute creation line.
  Ruby's source location cannot distinguish which definition an existing host has;
- every method in a block that uses `alias` or `alias_method`;
- a method the block itself calls outside a method body (a bare call, `self.name`, `method(:name)`,
  `instance_method(:name)` or `send(:name)`, `public_send` and `__send__` too, also inside a nested block or
  lambda); a symbol such as `before_save :name` is fine;
- every method in a block that passes a name computed at runtime to one of those calls (such as `send(pick)`);
- every method in a block whose `included` or `prepended` call is not a plain statement of the module body, for
  example `x = included do`, a call inside `if`, `unless` or `case`, a module under `unless defined?`, or a call
  inside `class << self`, a method or a block;
- every method in a file with a `return` outside any method or block;
- a method that `module_function` makes a module function.

For an otherwise placeable hook-block method, an `alias` made outside the block keeps the original body and
makes the mutant score `error`. This includes a wrapper that replaces the original name and calls the saved
alias, even when no host keeps the original at its current name. The methods listed as `unplaceable` above
keep that verdict and are not run. A live `Method` or `UnboundMethod` for the original definition also makes
an otherwise placeable mutant score `error`: a wrapper can keep and call that handle after the method was
redefined. A discarded reflection result does not trigger this error. `--test-command` runs every kind.
`ran_at_load` (schema `1.7`) means the mutant's
line ran while the app booted or its class loaded (for example a class body that calls the method to build a constant). Neither strategy re-runs that load in full, so a survivor there, or a line that ran
only at load, gets this status instead of `survived` or `no_coverage`, under both strategies (`reload` runs the
file's class body again, but not an initializer or another file's code); run `--test-command` to verify these.
A one-line or endless `def` keeps its body on the `def` line, which counts when the method is defined, so its method call
count at load is used instead. A block on that `def` line is not classified from the line (#389).
A `define_method` or `define_singleton_method` whose line ran at load counts too, including the block that call
stores (#435). Another block on that line stays scored. `each` with an empty array can count the line without running
its block. When that `each` shares the line with `define_method`, the call can still be `ran_at_load` (#286).
Code that runs only sometimes, such as the body of `x if c`, does not.

Several mutants can share a line, so `operator` and `token` name the change and `id` identifies the mutant.
The `id` is the value that `.mutineer.yml` `ignore:` takes. Before schema `1.6` these entries were
`{ subject, file, line }`.

### `no_verdict[]` (array of object)

Every mutant that was attempted and produced no verdict:
`{ subject, file, line, operator, token, id, status, details }`.
`status` is `"error"`, `"timeout"` or `"uncapturable"`, and its length equals `summary.no_verdict`.
Filter on `status` `"error"` for the errored mutants: their count equals `summary.errored`.
`operator` and `token` name the change, as in `no_coverage[]` (additive keys, schema `1.10`, #388).

`details` carries the cause where there is one. For `"error"` that is the failure. For
`"timeout"` and `"uncapturable"` it is `null`, because the status is the whole story.

When the mutant's child raised (under `reload`, `redefine` or the daemon), `details` is one line:
`Class: first non-blank line of the message`, or the class alone when the message is blank, at
most 500 characters (a longer line is cut and ends in `...`). Example:
`"ArgumentError: enum declared twice"` (schema `1.10`, #388). A Minitest database connection or
lock error gives `a test failed with a database error: Class: message`. An RSpec error outside
examples gives
`RSpec reported an error outside its examples, for example a spec file that raised while it loaded`.
A `--matrix` early end after a serial database error gives
`a test failed with a database error, then the child ended before the suite finished`
(schema `1.10`, #417). Other errors keep their fixed text, such as
`child exited with status 2`, `daemon verdict: error` or `worker crashed: Class: message`.
A daemon that died or did not reply in time gives `daemon crashed` or `daemon stopped answering`
(schema `1.10`, #388). `--test-command` and the human/HTML errored lists still lack named causes
(#417 items 5–6).

`details` is redacted. Redaction replaces the password of `DATABASE_URL` from the environment and from
these dotenv files: `.env`, `.env.local`, `.env.development`, `.env.development.local`, `.env.test`,
and `.env.test.local`. A double-quoted value may span lines. A backslash before `$` is a literal
dollar. An invalid byte does not stop that read. A Ruby process that `--test-command` starts
hides a password that process assigns itself. It also replaces the password in any
`scheme://user:password@host` URL.
A one-character password, a password equal to the username, the host, or the database name, and a
common word such as `password` or `test` stay visible outside a URL and outside a `password=` parameter.
Any other form longer than one character is hidden only as a whole token, with no ASCII letter, digit,
or underscore touching either edge, when it has at most three characters or is made only of ASCII
letters, digits, and underscores. A longer form that contains another character is hidden wherever it
appears. A password from another setting stays visible. An exception message can hold
other secrets too, so treat the report like a log. A message
can also hold an object address or a temporary file name, so `details` of an errored mutant can differ
between two runs with the same verdicts.

A failure before the mutant could be forked has no subject or mutation, so `subject`, `file`, `line` and
`id` are `null` on that entry. It still appears, because the counts must reconcile — but that means `id`
is not a reliable join key here, unlike in `survivors[]` and `ignored[]`.

Uncapturable mutants appear both here and in `uncapturable[]`, which stays for consumers that already
read it.

Read this array when the score looks better than you expect: these mutants are excluded from the score's
denominator, so a broken harness raises the score rather than lowering it. That is why `--threshold`
gates on completeness as well (see Exit codes).

### `ignored[]` (array of object)

Suppressed (equivalent) mutants, so you can audit what's silenced: `{ subject, file, line, operator, token, id }`. `reason` (string) is present only when the user wrote one, on an inline `# mutineer:disable-line ... -- reason` marker or on an `ignore:` mapping. Added in schema `1.8`. Under `--since`, only those on changed lines.

### `per_source[]` (array of object)

Per-file roll-up: `{ file, total, killed, survived, no_coverage, score }` (`score` is `float | null` as above).
`total` counts classified results for that file. A `--fail-fast` report is partial:
unscheduled candidates are omitted from these counts and from the top-level totals.

### `unpaired_sources[]` (array of object)

Each source pairing skipped. Sorted by `file`.

| Key | Type | Meaning |
| --- | --- | --- |
| `file` | string | The source path, as the run stored it. |
| `mutants` | int \| null | Scheduled mutants in that file. `null` when the count failed. `0` can mean no mutant, or no changed line under `--since`. |

The human report shows `unpaired_mutants / (total - ignored + unpaired_mutants)`.
Ignored rows are not in that denominator.
`--fail-fast` omits the percentage.
A run with no result rows does not put these mutants in the unrun-share warning.

### `unmutated_subjects[]` (array of object)

The array is `null` when `summary.unmutated_subjects` is `null`. Otherwise each entry is `{ subject, file, line }`: a method the selected operators gave no mutant, and the line of its
`def`. `subject` and `file` read as in `survivors[]`. An empty method is listed too. The list is made before
`# mutineer:disable-line` and `ignore:` apply, so a method whose mutants are all ignored is not listed. A method
whose candidates were all declined is listed, and `summary.declined` counts those candidates. `--only` narrows
the list; `--since` keeps methods whose `def` range intersects a changed line (#420). Without `--test`, a real
run skips a source with no paired test, so its methods are not listed (#381); a dry run does not skip such
sources, so its count can be larger. Additive key (schema `1.10`, #386). `mutineer run --dry-run --verbose`
prints the same list as `no mutants:` lines.

### `matrix` (object, only with `--matrix`)

Which tests kill which mutants. A `--matrix` run runs every test in each mutant's covering files, so a
mutant's row names every test that kills it. Coverage is recorded per test file, and a test that never runs
the mutated line cannot kill the mutant. Added in schema `1.5` and absent without the flag. The block never
changes `summary`, the score or the exit code.

A test has a `file` (relative to the project root: the file that defines the test), a `name`
(`CalculatorTest#test_add` under Minitest, the example's full description under RSpec) and an `id`. The `id`
tells apart tests that share a file and name: under RSpec it is the example id
(`./spec/calc_spec.rb[1:2]`; `--matrix` needs RSpec 3.3 or later, and an older RSpec leaves every row
incomplete), and under Minitest it equals `name`. A test of an anonymous Minitest class is named
`(anonymous)#test_x`, and its `id` adds the line of the method (`(anonymous)#test_x@7`).
A test is identified by its `file` and `id`. An example without a description of its own is worded from its
matcher, so its `name` can change with the mutant; the report keeps the name the first mutant gave it.

| Key | Type | Meaning |
|-----|------|---------|
| `complete` | bool | True when every row is complete. When false, a test in `blind[]` may have killed a mutant whose row is incomplete. |
| `tests[]` | array | Every test that ran against at least one mutant: `{ file, name, id, kills }`, sorted by `file`, `name`, then `id`. `kills` counts the mutants the test killed. Rows refer to a test by its index here. |
| `mutants[]` | array | One row per mutant that ran: `{ subject, file, line, operator, id, status, killed_by, ran, complete }`, sorted by `(file, line, operator, id)`. `killed_by` holds indexes into `tests[]`, and `ran` counts the tests that ran against the mutant. No-coverage, uncapturable, unplaceable, skipped and ignored mutants have no row: they never ran. A `ran_at_load` mutant has a row when it ran (a survivor reclassified after the run), and none when it was classified before. |
| `blind[]` | array | `{ file, name, id }`: tests that ran in at least one complete row and killed no mutant in any row. |
| `redundant[]` | array | `{ file, name, id }`: tests that killed at least one mutant, where each mutant they killed has another killer. |

A row is complete (`complete: true`) only when the mutant's whole covering set ran and the suite returned
normally before the per-mutant timeout, every line the child sent was read and arrived in order, and the row
agrees with the verdict: a killed mutant names a killer and a survivor names none. Under Minitest the
recorder also counts: it must have seen every test its classes run, so an `Interrupt` that Minitest caught and
returned from leaves the row incomplete; under RSpec, every planned example must have reported, so a run that
RSpec stopped early does too. A test that exits the process, a crash, the timeout, a failed write to the
channel, or a test framework Mutineer could not hook each leave the row incomplete too. A row whose lines
arrived out of order names no tests (`killed_by` and `ran` are empty).

`status` is the verdict a run without `--matrix` gives. After the first failing test, that run skips every
later test, test class and example group, so an exit, a crash or the timeout in one of those leaves the status
`"killed"` for an ordinary test failure, or `"error"` for a Minitest or RSpec database connection or lock failure.
A database failure is not a killer and leaves the row incomplete, even when an earlier assertion
already killed the mutant. It still runs the code around the failing test (the rest of its Minitest class `run` wrapper, the
`after(:all)` hooks of its RSpec groups) and the suite's own cleanup (RSpec `after(:suite)`), so an end there
keeps the exit status (or `"timeout"`). A failure in the tests of a Minitest `parallelize_me!` class keeps it
too: those run after every serial class and cannot be stopped once queued, while a failure in a serial class
still stops the run, even in a suite that also has a parallel class. The database-error choice among those
queued tests follows the queue order, not the order the threads finish (#347).

Each redundant test is judged on its own. Two redundant tests can be the only killers of one mutant, so
delete them one at a time and re-run after each. Every answer covers this run's mutants only.

### `baseline` (object, only with `--baseline`)

The delta versus the prior `--format json` report, matched by `id`. A baseline without `summary.id_format` also matches on old-format ids (counted in `summary.legacy_id_matches.baseline`):

| Key | Type | Meaning |
|-----|------|---------|
| `regressed` | bool | True if there are new survivors OR a score drop. **Drives exit 1.** |
| `score_before` | float \| null | Baseline score. |
| `score_after` | float \| null | This run's score. |
| `score_dropped` | bool | True if `score_after < score_before - epsilon`. |
| `score_comparable` | bool | True when the two scores share a denominator (neither side was diff-scoped, both non-null). False means the score-drop check was skipped — do not render the scores as a comparison. Additive key. |
| `new_survivors[]` | array | Survivors present now but absent in the baseline: `{ subject, file, line, operator, token, id }`. |
| `fixed_survivors[]` | array | Baseline survivors no longer present: `{ subject, file, line, operator, id }`. Empty under a diff-scoped side: an out-of-scope survivor was never re-tested, so absence does not mean fixed. |

## Exit codes

<!-- contract:exit-codes -->
| Code | Meaning |
|------|---------|
| `0` | Score ≥ threshold (or no gate) **and** no baseline regression. |
| `1` | Score below `--threshold`, OR nothing could be scored and something broke, or more than one mutant produced no verdict and they exceed 10% of those attempted, OR a `--baseline` regression, OR a runtime error, including a boot, source or `require:` file that raises while loading. |
| `2` | Usage / invalid-flag error, including a mistyped flag, a bad path (such as a missing `--boot` or `require:` file), or an unreadable baseline. |
<!-- /contract:exit-codes -->

Under a positive `--threshold`, a run is gated on being complete as well as on its score. Mutants with no
verdict are excluded from the score's denominator, so a broken harness inflates the score instead of
lowering it. Past 10% of attempted mutants — and never for a single one, however small the run — the
score is treated as covering too little of the run to gate on. The floor applies only when there *is* a
score: a run where nothing could be scored at all fails on a single broken mutant, because there is no
score to weigh it against. Read `no_verdict[]` to see what failed.
A run where *nothing* was scored and something broke already exits 1.

`--threshold` and `--baseline` are independent gates OR'd together (the worse code wins); usage errors (2)
always win. Exit 2 still means "you invoked me wrong". Exit 1 now covers three distinct situations —
tests too weak, the run did not complete, or a baseline regression — and they are not distinguishable
from the exit code alone. Tell them apart from the JSON: compare the exact score against your
threshold. When `summary.killed + summary.survived > 0`, check
`summary.killed * 100 >= threshold * (summary.killed + summary.survived)`, with decimal or rational
arithmetic for a fractional threshold (`summary.score` is rounded, and the gate does not use it). Compare
`summary.no_verdict / summary.attempted` against 10%, and check `baseline.regressed`. A run that failed only on
completeness is the one worth retrying rather than blaming on the tests.

## Dry-run JSON (`--dry-run --format json`)

Additive (schema `1.10`, #362). `mutineer run … --dry-run --format json` prints a candidate list
instead of the human breakdown. `--output` writes that document the same way a completed run's
report does. `--format html` under `--dry-run` stays human and warns that the format is unused.

```jsonc
{
  "schema_version": "1.10",
  "summary": {
    "id_format": 2,
    "total": 0,
    "skipped_invalid": 0,
    "ignored": 0,
    "declined": 0,
    "declined_by_operator": {},
    "by_operator": { /* operator name => valid candidate count */ }
  },
  "mutants": [ /* { subject, file, line, operator, token, id }, sorted like killed[] */ ]
}
```

`mutants[].id` values match a later real run of the same sources, operators, and ignore rules
(both paths use `JobPlan.collect_jobs`). `summary.id_format` is `2`, the same marker a completed
report carries, so a consumer that joins by id does not treat a missing key as the old format.
`summary.total` equals `mutants.length`.
