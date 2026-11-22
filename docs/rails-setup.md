# Rails setup

Use `--rails` to boot Rails once. Add `--daemon` (Minitest) for parallel workers with separate databases; an app with more than one database runs one worker.
For Ruby older than 3.4, use `--test-command`.
Start with one model, then follow the [Rails rollout guide](rails.md) to a CI gate.

**Prompt for your coding agent**

```text
Check this Rails app for Mutineer's --daemon backend. Report: the test framework (Minitest or RSpec), the test database adapter and version from config/database.yml (sqlite3 file, :memory:, postgresql, mysql2/trilogy and the MySQL server version), whether there is more than one database, and whether tests commit rows outside a transaction. Using the support matrix at https://github.com/davidteren/mutineer#is-it-production-ready, say whether to run with --rails --daemon or with --rails alone, and give the exact command for app/models.
```

## Set up

Install Mutineer and create `.mutineer.yml` with
[First run to steady state, step 1](getting-started.md#1-install).
Run one model with [step 2](getting-started.md#2-first-run-on-one-file).
Run inside the project bundle (`bundle exec`).
Add `--test PATH` for a file, a directory, or a quoted glob.

`--test test` also selects files under `test/system/`.
To skip system tests, list each test directory you use.
The glob selects only the directories it names.
Add any other directory, such as `test/services`, and each root-level test file:

```sh
RAILS_ENV=test bundle exec mutineer run app/models/order.rb --rails --test 'test/{channels,controllers,helpers,integration,jobs,lib,mailers,middleware,models}/**/*_test.rb' --test test/routes_test.rb
```

| Setting | Behaviour |
| --- | --- |
| `--rails` | Boots `config/environment` once. Each mutant forks from that process and reconnects ActiveRecord for a safe database connection. |
| `--boot FILE` | Boots another entry point. |
| Tests | A real run in boot mode requires a conventionally found test, a matching `tests:` map entry, or `--test`. A dry run needs no `--test`, with or without `--rails` or `--boot`, and its human listing counts mutants in sources with no paired test (`--format json` omits that count). Mutants run only tests covering their line. |
| Coverage | Captured in a fork of the booted app, then cached. |
| Default strategy | `redefine` without `--daemon`; `reload` with `--daemon`. |
| `redefine` | Reloads the mutated method and each directly enclosing method, not the whole file. |
| Methods nested in blocks | A method inside a block such as `define_method` can falsely survive. Use `--strategy reload`. |

A file at `app/<dir>/concerns/<rest>.rb` pairs with a namespace test when the `concerns/` path has no pairable test.
For example, `app/models/concerns/storage/totaled.rb` pairs with `test/models/storage/totaled_test.rb` or an unclaimed split such as `test/models/storage/totaled_bytes_test.rb`; a longer source or an already-paired model can retain that split.
See the [pairing table](ci.md).

A controller concern often has no test at the conventional path.
Map it to the controller and integration tests that exercise it:

```yaml
# .mutineer.yml
tests:
  - sources: app/controllers/concerns/**/*.rb
    tests: [test/controllers/**/*_test.rb, test/integration/**/*_test.rb]
```

See [Extra tests for a source](cli.md#extra-tests-for-a-source) for cost notes.

Both strategies write a hidden `.mutineer_mutant*.rb` beside the source.
Under `--strategy redefine`, a read-only directory falls back to a system temporary file.
The method still resolves `__dir__`, `__FILE__`, and `require_relative` against the original source file, so those mutants are not false kills.
`reload`, in process and on the daemon, does not fall back. It needs a writable source directory, and a read-only directory scores the mutant `error`, which stays out of the score.

Code executed during boot or class loading runs before mutation. Forked tests do not repeat it.
Examples include constant-building calls, `to_prepare` initializers, and source calls from `.mutineer.yml` `require:` files.

| Result | Treatment |
| --- | --- |
| A mutant survives on a line executed during loading | Classified as `ran_at_load`, not `survived` or `no_coverage`. Excluded from the score and `--threshold` failures. A mutant in a `define_method` or `define_singleton_method` whose line ran at load counts too, including the block that call stores (#435). A survivor in another block or lambda, such as a block that a class macro stores, counts too when the call that holds the block ran at load and a probe that can speak saw no return of the mutated expression during a test (#493, after 1.9.0). A probed expression that holds `return`, `next`, `break`, `raise` or a similar exit, or one in a `defined?` operand, keeps its verdict. When it returned during a test, the mutant stays `survived`. An empty `each` that shares the line with `define_method` can still mark that call `ran_at_load` when the call did not run ([#286](https://github.com/davidteren/mutineer/issues/286)). |
| A mutant is killed | The kill counts. |
| Strategy is `reload` | Repeats the mutated file's class body, but not initializers or other files. Survivors on these lines remain untrusted. |
| A class runs a callback twice after a reload | Reload keeps both copies of a callback when it cannot tell which old copy a new one repeats, for example the same `before_save(&:stamp)` in a concern and in the class body. The run then prints one warning that starts with `[mutineer] after a reload,` and gives the number of classes, then one line for each class and file. A test that counts callback runs or errors can kill mutants of that file falsely. The warning changes no score and no exit code. To check those kills, run the file with `--no-daemon --strategy redefine` or with `--test-command`. |
| A verdict is needed | Use `--test-command` to boot a fresh process per mutant. |
| The caller loaded before the mutant | `reload` updates the macro method and does not run the class that already called it. Those mutants stay `ran_at_load`. Re-running that class body is [#389](https://github.com/davidteren/mutineer/issues/389). |
| The macro and the class that calls it are both sources | An in-process `--rails` run with the default `redefine` strategy loads the class of each method in the sources before the mutants, also with eager load off. A class that defines no method still loads after the mutant. The class then keeps the blocks that the macro stored. A survivor that only such a stored block runs is `ran_at_load`. `--daemon` with eager load off loads the class after the mutant and can kill these mutants ([#507](https://github.com/davidteren/mutineer/issues/507)). |
| A `ran_at_load` mutant is in a block | Check that a test runs the block and checks its result. Then confirm with `--daemon` (eager load off) or `--test-command`. |

Mutineer does not read `CI`. In the Rails test environment, `config.eager_load` follows `CI`, so a run with `CI` set loads the class before the mutant and these mutants are `ran_at_load`. With eager load off, the class loads after the mutant and the same mutants are killed. The exception is an in-process `redefine` run where that class is a source too: it loads the class before the mutants.

Continue from the first report to a CI gate with the
[Rails rollout guide](https://davidteren.github.io/mutineer/rails.html).

### Rails parallel tests, Spring, Bootsnap, and Redis

| Setting | Behaviour |
| --- | --- |
| `PARALLEL_WORKERS=1` | Set for every run. Overrides existing values with a message. Each mutant's Rails tests run in one process. |
| `parallelize(workers:)` | Keep it in `test_helper.rb`. It does not start Rails workers during mutation runs. |
| `parallelize_setup` | Hooks do not run. Rails' database hook shares this list and would select `<base>-<n>` instead of Mutineer's database. |
| `DISABLE_SPRING=1` | Set for `--test-command`, preventing Spring from starting. |
| Spring with `--daemon` | Does not start because Mutineer loads `config/environment` directly. |
| Wrapper overrides | A wrapper can reset these variables. Its values win. |

Remove wrapper assignments to `PARALLEL_WORKERS`, or use `PARALLEL_WORKERS=${PARALLEL_WORKERS:-4}` to preserve Mutineer's value of 1:

```sh
# in a wrapper script your --test-command runs
export PARALLEL_WORKERS="${PARALLEL_WORKERS:-4}"
```

Bootsnap checks file paths, sizes, and modification times in whole seconds, without reading matching files.
In-process and `--daemon` runs use a new file per mutant, preventing cache collisions.
`--test-command` rewrites the source. Same-size mutants written within one second can load the previous mutant's cached code.

| Bootsnap setting | Action or effect |
| --- | --- |
| `DISABLE_BOOTSNAP_COMPILE_CACHE=1` | Set by `--test-command`. Recompiles files on every boot, which slows each mutant. |
| `require "bootsnap/setup"` | Uses the variable through Rails' `config/boot.rb`. Requires Bootsnap 1.7.0 or later; upgrade older versions. |
| Direct `Bootsnap.setup` calls | Pass `compile_cache_iseq: ENV["DISABLE_BOOTSNAP_COMPILE_CACHE"].nil?`. Other boots keep the cache. |
| `DISABLE_BOOTSNAP_COMPILE_CACHE=0` | Still disables the cache. Bootsnap checks whether the variable exists. |
| Keep the cache | Run through a wrapper that first runs `unset DISABLE_BOOTSNAP_COMPILE_CACHE`. Boots accelerate, but stale mutant code can load. |
| Stale code | Delete `tmp/cache/bootsnap`, or the directory set by `$BOOTSNAP_CACHE_DIR`, then rerun. |

Call `Bootsnap.setup` directly, disabling the compile cache under `--test-command`:

```ruby
Bootsnap.setup(
  cache_dir: "tmp/cache",
  compile_cache_iseq: ENV["DISABLE_BOOTSNAP_COMPILE_CACHE"].nil?
)
```

| Redis version | Fork behaviour |
| --- | --- |
| `redis-client`, used by `redis` 5 | Reconnects automatically. No Mutineer setup is needed. |
| `redis` 4.x | Raises `Redis::InheritedError`. Open the connection after boot or reconnect in an after-fork hook. |

### Faster, parallel-safe Rails (the `--daemon` backend)

`--rails` runs mutants serially because parallel workers would share a test database and overwrite fixtures.
`--daemon` boots once in a persistent helper, forks per mutant, and gives each worker its own database.
Parallel verdicts are proven identical to serial verdicts.

```sh
RAILS_ENV=test bundle exec mutineer run \
  app/models/order.rb --test test/models/order_test.rb \
  --rails --daemon --jobs 4
```

| Feature | Behaviour |
| --- | --- |
| Shared boot | Boots once, then forks per mutant. |
| Mutant run | Stops at the first failing test, as the in-process run does. |
| Coverage | Runs only covering tests. Uncovered lines receive `no_coverage`, keeping scores comparable with in-process `--rails`. If coverage is unavailable, each mutant runs the full test set and the score is not comparable. |
| Worker databases | Separate databases prevent fixture interference. Only single-database apps run in parallel; more than one database forces one worker, unless `shared_databases` lists the other ones ([More than one database](#more-than-one-database)). Initial copies include rows written during boot by initializers or `require:` files. |
| Load paths | Does not pass `RUBYOPT` or `RUBYLIB` to the app, so a `-I` path set there is missing. To add a path, set `boot:` to a file at the project root that adds it and then boots the app: `$LOAD_PATH.unshift(File.expand_path("test/support", __dir__))`, then `require_relative "config/environment"`. When you set `RUBYLIB`, or a `RUBYOPT` with `-I`, a mutant that errors on a missing file says so in the JSON report's `no_verdict[].details`. The coverage build and the clean check add the same note to their message when they fail that way. A setting for this is open in [#491](https://github.com/davidteren/mutineer/issues/491). |
| Backend choice | Requires `--rails` or `--boot`. Cannot combine with `--test-command`. |

For SQLite, Mutineer compares the copied database with the app's Ruby schema.
It loads an existing schema file if the version or `schema_sha1` differs, or the stored checksum is missing.
This includes empty databases, outdated databases, and databases created with plain `load "db/schema.rb"`.
Loading the schema removes copied rows from tables it defines.

| SQLite schema selection | Result |
| --- | --- |
| `SCHEMA` is set | Uses that file. |
| Otherwise, `schema_dump:` is set in `config/database.yml` | Uses that setting. |
| Neither is set | Uses `db/schema.rb`. |
| Missing file or `structure.sql` | Leaves the copy unchanged. |
| `schema_dump: false` | Leaves the copy unchanged unless `SCHEMA` is set. |

Supported databases are **SQLite**, **PostgreSQL**, and **MySQL 8**, with Minitest.

| Database | Worker provisioning and cleanup |
| --- | --- |
| SQLite | Copies each worker file on first use. For `storage/test.sqlite3`, worker files are `storage/test-<N>.sqlite3` and the run lock is `storage/test.sqlite3-mutineer.lock`. |
| SQLite lock file | The lock file never goes stale. Do not delete it while a run is active. Wait for the other run to finish, or stop it. Add `<base file>-mutineer.lock` to `.gitignore` unless your rules already cover `storage/*`. A `file:` name that opens a disk file takes this lock on that file. A memory URI (`file::memory:` or `mode=memory`) and an empty `file:` name take no lock. Other known gaps are tracked in #416. |
| PostgreSQL | Copies the test database before workers start. Names use `<base>-mutineer-<N>`, shortened to fit 63 bytes. Databases remain after the run. |
| PostgreSQL cleanup | Run `DROP DATABASE "myapp_test-mutineer-0";`, using your test database name and worker slot. |
| MySQL 8 | Creates `<base>-mutineer-<N>`, shortened to fit 64 bytes. Loads `schema.rb` or `structure.sql`, then copies rows before workers start. |
| MySQL recovery | Does not recopy after an error or timeout. Databases remain after the run; the next run drops and rebuilds them. |
| MySQL cleanup | Run ``DROP DATABASE `myapp_test-mutineer-0`;``. MySQL requires backticks around the name. |
| `:memory:` | Not supported by `--daemon`. |
| Concurrent runs | A second run on the same test database stops with `another Mutineer run is using <base>`. This covers PostgreSQL, MySQL, and file-backed SQLite databases, including a `file:` URI that names a disk file. A memory URI takes no lock. |

| MySQL requirement or limit | Detail |
| --- | --- |
| Adapters | Supports `mysql2` and `trilogy`. |
| Triggers | Drops worker triggers before copying rows, then recreates them. Triggers do not fire during copying. |
| Worker permissions | Needs CREATE, DROP, TRIGGER, and schema-load and row-copy privileges, such as ALTER, INDEX, REFERENCES, and INSERT. |
| Test database permissions | Needs SELECT. |
| Another account's trigger DEFINER | Also needs SET_USER_ID. |
| `structure.sql` | Requires the `mysql` client on `PATH`. |
| Worker limit | At most 256 workers. |
| MySQL older than 8.0, including 5.7 | Unsupported. Stops before copying with `could not provision <base>: MySQL <version> is not supported`. |
| Older MySQL fallback | Use `--no-daemon` or `daemon: false`. The run is serial. |
| MariaDB or MySQL 9 or later | Untested. Prints a warning and runs. |
| Unreadable server version | Prints a warning and runs. |

### More than one database

Each worker copies only the primary database, the one `ActiveRecord::Base` uses.
An app with a second test database therefore runs one worker.
A database with `database_tasks: false` counts too. A replica does not.
If your tests never use the other databases, list them in `.mutineer.yml`:

```yaml
shared_databases: [cable, queue]
```

The workers then share those databases, and `--jobs N` runs in parallel.
This needs Rails 7.1 or later. On Rails 7.0, every mutant of a parallel run scores `error`.

After each mutant, a parallel worker checks the shared databases.
The mutant scores `error` when a pool for a shared database is still connected after the tests, or ran SQL during them.
A connected pool counts even when a test did not open it, for example a pool connected at boot or in `setup`.
A replica of a shared database counts as that database.
An `error` is never a false kill or survive, and it leaves the score.
The check does not see a database reached without Active Record, such as a raw driver connection.
One worker shares nothing, so it skips the check.

| Case | Result |
| --- | --- |
| `shared_databases` lists the primary database | The run stops with exit 2. |
| A name matches no test database | A warning. The name lifts nothing. |
| Mutineer cannot list the app's databases | One worker. |
| The first daemon does not boot, with `--rails` | One worker. With `--boot` alone, the run keeps its worker count. |

Transactional tests connect every database that has a connection pool in the test environment.
So if the test environment registers a pool for a shared database, every mutant scores `error`.
A `connects_to` for solid_cable or solid_queue in the test environment does this.
To fix it, register no pool for that database in test.
For Action Cable, use `adapter: test` in `config/cable.yml`.
For the queue database, do not call `connects_to` for it in the test environment.
On Rails 8.1 or later, `skip_transactional_tests_for_database :cable` in `ActiveSupport::TestCase` also works.
Otherwise leave that database out of `shared_databases`, and the run uses one worker.

### Apps on Ruby < 3.4

Mutineer needs Ruby ≥ 3.4 for stdlib Prism.
`--rails` boots your app inside Mutineer's process.
An older Ruby pin, such as `ruby "3.1.6"` in the Gemfile, makes Bundler reject Ruby 3.4.

Use `--test-command` to run tests in the app's runtime while Mutineer runs on Ruby 3.4+.

```sh
RAILS_ENV=test mutineer run app/models/order.rb \
  --test test/models/order_test.rb \
  --test-command "bundle exec rails test %{files}"
```

| Setting | Behaviour |
| --- | --- |
| `%{files}` | Required. Expands `--test` paths into separate arguments. Paths containing spaces remain single arguments. No shell runs. |
| Environment | Inherits variables such as `RAILS_ENV` and `DATABASE_URL`. |
| Removed variables | Unsets `BUNDLE_*`, `GEM_*`, `RUBY*`, `RBENV_VERSION`, `ASDF_RUBY_VERSION`, and `RBENV_DIR` so Mutineer's Ruby cannot pin the suite. |
| `PATH` | Removes version-manager version bins, such as `~/.rbenv/versions/3.4.x/bin`. Prepends rbenv/asdf shims when a pin was removed. |
| App Ruby selection | Use `.ruby-version` or a wrapper. Do not rely on `RBENV_VERSION=…` on the Mutineer command. |
| `KEY=val` inside `--test-command` | Unsupported. Without a shell, it becomes the program name. |
| Forced child settings | Replaces existing values with `PARALLEL_WORKERS=1`, `DISABLE_SPRING=1`, and `DISABLE_BOOTSNAP_COMPILE_CACHE=1`. |
| Test order | Only for `--test-command`. Other runs share one seed; see the [CLI reference](https://github.com/davidteren/mutineer/blob/main/docs/cli.md#test-order). This command must use a fixed order. Mutineer sets no seed, so each run picks its own order. An order-dependent suite can then fail a mutant run for a reason the mutant did not cause, a false kill. For Minitest, put `SEED=1` before the `mutineer` command (`SEED=1 mutineer run ...`), not inside `--test-command`. For RSpec, add `--order defined` to the command, and keep `--order rand` out of `SPEC_OPTS`, which RSpec reads after the command. When the clean run prints a random seed and Mutineer finds no fixed one, it prints one warning. Mutineer only warns: it cannot know the seed flag of an arbitrary command, so it never sets a seed. It reads the seed line of Minitest, minitest-reporters and RSpec, and a seed in `.rspec` or `.rspec-local` in the working directory. It cannot see a seed set in a wrapper script, in `~/.rspec`, with `config.seed = N` in a spec helper or `--require` file, inside an inactive ERB branch of `.rspec` (RSpec renders the file as ERB, Mutineer scans its text), in the file that `--options FILE` names, or a Minitest `test_order` such as `:alpha` (Minitest still prints a seed line then). In those cases the warning can print when the order is already fixed. A seed-like argument meant for a wrapper (`bin/run --seed 7 %{files}`, where the wrapper does not pass it on) hides the warning while the tests still shuffle. For RSpec, Mutineer reads the order options in RSpec's order: `.rspec`, `.rspec-local`, the command, then `SPEC_OPTS`. The last `--seed` or `--order` option decides, so a later `--order rand` gets the warning although `.rspec` has a seed. With `--options FILE` or `-O FILE` in the command or `SPEC_OPTS`, RSpec skips both files, and so does Mutineer ([#522](https://github.com/davidteren/mutineer/issues/522)). Mutineer reads `.rspec` in its own working directory, so a `cd` inside a wrapper can make RSpec read another file than Mutineer does. [#549](https://github.com/davidteren/mutineer/issues/549) tracks these blind spots. |

See [Rails parallel tests, Spring, Bootsnap, and Redis](https://github.com/davidteren/mutineer/blob/main/docs/rails-setup.md#rails-parallel-tests-spring-bootsnap-and-redis) for wrapper behaviour.

#### Under a version manager (rbenv / asdf / chruby)

Mutineer automatically handles **rbenv** and **asdf** shims and version bins.
For **chruby**, it removes `…/rubies/…/bin`, but needs a wrapper to source chruby and select the app's Ruby.

If the smoke check still reports a **Ruby version mismatch**, wrap the suite.
Example rbenv wrapper, saved as `bin/mutineer-test`:

```sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
unset GEM_HOME GEM_PATH RUBYLIB RUBYOPT BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_VERSION
export RBENV_VERSION="$(cat .ruby-version 2>/dev/null || true)"
export RAILS_ENV="${RAILS_ENV:-test}"
export PATH="${HOME}/.rbenv/shims:${PATH}"
exec bundle exec rails test "$@"
```

Make it executable:

```sh
chmod +x bin/mutineer-test
```

```sh
# Mutineer on 3.4+; suite on the app's Ruby via the wrapper
mutineer run app/models/order.rb \
  --test test/models/order_test.rb \
  --test-command "bin/mutineer-test %{files}"
```

When Bundler prints `RubyVersionMismatch`, Mutineer reports that cause instead of only suggesting database or migration problems.

| `--test-command` trade-off | Behaviour |
| --- | --- |
| Speed | Reboots the app for every mutant. No shared boot. |
| Test selection | Runs the full `--test` set for every mutant, without coverage narrowing. |
| Parallelism | Runs serially by default and forces `--jobs` to 1; a wrapper can reset `PARALLEL_WORKERS` to re-enable Rails test workers. |
| Strategy | Supports only `reload`. Rejects `--strategy redefine`. |
| Smoke check | Aborts before mutation if the unmutated suite fails. |
| Score comparison | Uncovered mutants count as survivors. Do not compare with in-process scores. Mutineer prints this warning every run. |

| Subprocess result | Verdict |
| --- | --- |
| Exit code other than 1, or a signal | `error`, except for the SimpleCov case below. |
| RSpec `--failure-exit-code` other than 1 | Test failures become `error`. |
| Clean run prints a recognised summary | Exit 1 requires a reported test failure or a Minitest run stopped during a test. Otherwise, `error`. |
| Recognised summaries | Examples: `3 runs, 3 assertions, 0 failures, 0 errors` and `3 examples, 0 failures`. When a summary of the clean run starts a line, a mutant run's summary and its `# Running:` line count only at the start of a line ([#515](https://github.com/davidteren/mutineer/issues/515)). When no summary of the clean run starts a line (a wrapper that prefixes each line), they count at any position. |
| Exit 1 with a failing summary that does not start a line, when the clean run's summary did | `error`, with the reason "not at the start of a line". A wrapper prefix or a parallel runner moved the summary. Remove that prefix or the parallel runner from `--test-command`. |
| Crash during loading | `error` when summary validation applies. |
| SimpleCov `minimum_coverage` failure with its gate message and a recognised summary | Summary decides: a failing test is a kill. All tests passing means `survived` when the run printed at least as many summary lines as the clean run. |
| SimpleCov gate message, all tests passing, and fewer summary lines than the clean run | `error`, with the reason "printed 1 summary line where the clean run printed 2" ([#516](https://github.com/davidteren/mutineer/issues/516)). The gate stopped a chain of suites, and a suite that did not run could kill the mutant. Turn the coverage gate off for mutation runs. |
| SimpleCov without a recognised summary, or with `print_error_status = false` | The coverage gate's exit scores `error`. |
| Clean run prints no summary | Warns once, then counts every exit 1 as a kill. |

#### Known limits of reading test output ([#549](https://github.com/davidteren/mutineer/issues/549))

Mutineer reads the output of `--test-command` to tell a crash from a kill. #342 listed these 12 limits. [#515](https://github.com/davidteren/mutineer/issues/515) closed most of limit 4, [#516](https://github.com/davidteren/mutineer/issues/516) closed most of limit 9, and the other limits stay. [#549](https://github.com/davidteren/mutineer/issues/549) tracks each open limit, with the reason it is accepted. The `--daemon` path is separate ([#296](https://github.com/davidteren/mutineer/issues/296)).

A verdict that can be wrong is marked.

| # | Limit | Result |
| --- | --- | --- |
| 1 | Code under test calls `exit 1` or `abort` during a test. | `killed` under the default Minitest reporter, as in process. Under RSpec or minitest-reporters it is `error`, because only the default reporter prints `# Running:`. |
| 2 | `SimpleCov.print_error_status = false`. | The gate prints no message, so its exit scores `error`. |
| 3 | An exception escapes `Minitest.run` (a reporter plugin bug). | **False `killed`**, where in process it is `error`. Accepted: the output and exit status are the same as code under test that runs `warn e.full_message; exit 1` in a test, a real kill. |
| 4 | A test prints a whole summary line at the start of a line, or an RSpec top-level group name holds summary-like text in documentation format. Summary-like text in a Minitest `-v` test name, after a progress dot, or in an indented RSpec example name no longer counts, because the clean run's summary starts a line. | **False `killed`** for a crash. When a wrapper prefixes each line, a summary counts at any position, so the whole limit stays. |
| 5 | A custom failure exit code, such as RSpec `--failure-exit-code 3`. | Every kill scores `error`. This matches the in-process rule: only exit 1 kills. |
| 6 | Code under test calls `exit!(1)`. | The output flush is skipped and `# Running:` can be lost, so it scores `error`, where in process it is `killed`. |
| 7 | A reporter with no Minitest or RSpec summary line (JUnit-only, Cucumber). | The crash check is off, with one warning. **Every exit 1 counts as a kill**. Accepted: the output has no sign that a test ran. |
| 8 | Code under test calls `exit` with any status during a Minitest test. | Minitest's `autorun` ends the process with 1, and the output has no summary. Under the default reporter it scores **`killed`** (under minitest-reporters, `error`), where in process `exit 0` is `survived` and `exit 2` is `error`. Accepted: the output is the same for each status. |
| 9 | A wrapper chains two suites (`sh -c 'bin/rails test "$@" && bundle exec rspec' sh %{files}`) and the SimpleCov gate stops the first. | The run printed fewer summary lines than the clean run, so it scores `error`, not `survived`. Mutineer does not run the skipped suite. When the clean run printed no summary line, or when a plain first suite is followed by a prefixed second suite, a passing first summary still scores **`survived`**, although the skipped suite might kill. |
| 10 | SimpleCov older than 0.19 prints a different gate message. | The gate exit scores `error`, not `survived`. |
| 11 | RSpec exits 1 in the middle of an example. | The `error` reason text can name the wrong cause. The verdict is right. |
| 12 | test-unit. | Its summary line matches `MINITEST_SUMMARY`, so the summary check is on, not the exit-code fallback. Scoring is right. |

Each `error` verdict leaves the score's denominator, so the score stays honest, but real kills can drop out of it.

For Ruby ≥ 3.4 with Minitest and a supported database, use [the daemon backend](https://github.com/davidteren/mutineer/blob/main/docs/rails-setup.md#faster-parallel-safe-rails-the---daemon-backend) for safe parallelism. RSpec and other serial-only setups use `--rails` without `--daemon`.