# Rails setup

Use `--rails` to boot Rails once. Add `--daemon` for parallel workers with separate databases.
For Ruby older than 3.4, use `--test-command`.
Start with one model, then follow the [Rails rollout guide](rails.md) to a CI gate.

> **Prompt for your coding agent**
>
> ```text
> Check this Rails app for Mutineer's --daemon backend. Report: the test framework (Minitest or RSpec), the test database adapter and version from config/database.yml (sqlite3 file, :memory:, postgresql, mysql2/trilogy and the MySQL server version), whether there is more than one database, and whether tests commit rows outside a transaction. Using the support matrix at https://github.com/davidteren/mutineer#is-it-production-ready, say whether to run with --rails --daemon or with --rails alone, and give the exact command for app/models.
> ```

## Set up

1. Add Mutineer to your Gemfile's test group. Run `bundle install`.

   ```ruby
   gem "mutineer", group: :test, require: false
   ```

2. Create `.mutineer.yml` and print a first command. Existing files stay unchanged unless you pass `--force`.

   ```sh
   RAILS_ENV=test bundle exec mutineer init --rails
   ```

3. Run one model inside the project's bundle. Add `--test FILE` to select tests.

   ```sh
   RAILS_ENV=test bundle exec mutineer run app/models/order.rb --rails
   ```

| Setting | Behaviour |
| --- | --- |
| `--rails` | Boots `config/environment` once. Each mutant forks from that process and reconnects ActiveRecord for a safe database connection. |
| `--boot FILE` | Boots another entry point. |
| Tests | Boot mode requires a conventionally found test or `--test`. A `--dry-run` skips pairing and requires `--test`. Mutants run only tests covering their line. |
| Coverage | Captured in a fork of the booted app, then cached. |
| Default strategy | `redefine` without `--daemon`; `reload` with `--daemon`. |
| `redefine` | Reloads the mutated method and each directly enclosing method, not the whole file. |
| Methods nested in blocks | A method inside a block such as `define_method` can falsely survive. Use `--strategy reload`. |

Both strategies write a hidden `.mutineer_mutant*.rb` beside the source.
Read-only directories force a system temporary file.
Mutineer warns that `__dir__` or `require_relative` can then cause false kills and an inflated score.
Make the source directory writable to avoid this problem, tracked in issue #339.

Code executed during boot or class loading runs before mutation. Forked tests do not repeat it.
Examples include constant-building calls, `to_prepare` initializers, and source calls from `.mutineer.yml` `require:` files.

| Result | Treatment |
| --- | --- |
| A mutant survives on a line executed during loading | Classified as `ran_at_load`, not `survived` or `no_coverage`. Excluded from the score and `--threshold` failures. |
| A mutant is killed | The kill counts. |
| Strategy is `reload` | Repeats the mutated file's class body, but not initializers or other files. Survivors on these lines remain untrusted. |
| A verdict is needed | Use `--test-command` to boot a fresh process per mutant. |

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
| Coverage | Runs only covering tests. Uncovered lines receive `no_coverage`, keeping scores comparable with in-process `--rails`. |
| Worker databases | Separate databases prevent fixture interference. Initial copies include rows written during boot by initializers or `require:` files. |
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
| PostgreSQL | Copies the test database before workers start. Names use `<base>-mutineer-<N>`, shortened to fit 63 bytes. Databases remain after the run. |
| PostgreSQL cleanup | Run `DROP DATABASE "myapp_test-mutineer-0";`, using your test database name and worker slot. |
| MySQL 8 | Creates `<base>-mutineer-<N>`, shortened to fit 64 bytes. Loads `schema.rb` or `structure.sql`, then copies rows before workers start. |
| MySQL recovery | Does not recopy after an error or timeout. Databases remain after the run; the next run drops and rebuilds them. |
| MySQL cleanup | Run ``DROP DATABASE `myapp_test-mutineer-0`;``. MySQL requires backticks around the name. |
| `:memory:` | Not supported by `--daemon`. |

| MySQL requirement or limit | Detail |
| --- | --- |
| Adapters | Supports `mysql2` and `trilogy`. |
| Triggers | Drops worker triggers before copying rows, then recreates them. Triggers do not fire during copying. |
| Worker permissions | Needs CREATE, DROP, TRIGGER, and schema-load and row-copy privileges, such as ALTER, INDEX, REFERENCES, and INSERT. |
| Test database permissions | Needs SELECT. |
| Another account's trigger DEFINER | Also needs SET_USER_ID. |
| `structure.sql` | Requires the `mysql` client on `PATH`. |
| Concurrent runs | A second run using the same test database stops with `another Mutineer run is using <base>`. |
| Worker limit | At most 256 workers. |
| MySQL older than 8.0, including 5.7 | Unsupported. Stops before copying with `could not provision <base>: MySQL <version> is not supported`. |
| Older MySQL fallback | Use `--no-daemon` or `daemon: false`. The run is serial. |
| MariaDB or MySQL 9 or later | Untested. Prints a warning and runs. |
| Unreadable server version | Prints a warning and runs. |

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
| Parallelism | Runs serially. Forces `--jobs` to 1. |
| Strategy | Supports only `reload`. Rejects `--strategy redefine`. |
| Smoke check | Aborts before mutation if the unmutated suite fails. |
| Score comparison | Uncovered mutants count as survivors. Do not compare with in-process scores. Mutineer prints this warning every run. |

| Subprocess result | Verdict |
| --- | --- |
| Exit code other than 1, or a signal | `error`, except for the SimpleCov case below. |
| RSpec `--failure-exit-code` other than 1 | Test failures become `error`. |
| Clean run prints a recognised summary | Exit 1 requires a reported test failure or a Minitest run stopped during a test. Otherwise, `error`. |
| Recognised summaries | Examples: `3 runs, 3 assertions, 0 failures, 0 errors` and `3 examples, 0 failures`. |
| Crash during loading | `error` when summary validation applies. |
| SimpleCov `minimum_coverage` failure | Summary decides: a failing test is a kill; all tests passing means `survived`. |
| SimpleCov without a recognised summary, or with `print_error_status = false` | The coverage gate's exit scores `error`. |
| Clean run prints no summary | Warns once, then counts every exit 1 as a kill. |

For Ruby ≥ 3.4, use [the daemon backend](https://github.com/davidteren/mutineer/blob/main/docs/rails-setup.md#faster-parallel-safe-rails-the---daemon-backend) for safe parallelism.

Runtime checks were not run for this edit.
MariaDB and MySQL 9 or later remain untested.