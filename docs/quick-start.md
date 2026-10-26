# Quick start

Find and fix one survivor in about five minutes. Requires Ruby 3.4+, Linux or macOS, and passing tests.

## Plain Ruby project

Install:

```sh
gem install mutineer
```

Run the `Discount` example from [Mutation testing, explained](https://davidteren.github.io/mutineer/learn.html):

```sh
mutineer run lib/discount.rb --test test/discount_test.rb
```

Without `--test`, Mutineer finds `test/discount_test.rb` or `spec/discount_spec.rb`:

```sh
mutineer run lib/discount.rb
```

## Rails app

Add to your `Gemfile`:

```ruby
gem "mutineer", group: :test, require: false
```

Install:

```sh
bundle install
```

Create `.mutineer.yml`:

```sh
RAILS_ENV=test bundle exec mutineer init --rails
```

Generated config:

```yaml
# Mutineer config. Command-line flags override this file.
# These operators are the default set.
operators:
  - arithmetic
  - comparison
  - boolean_connector
  - boolean_literal
  - statement_removal

# since: origin/main
# Leave this commented so the first run is a full scan.

rails: true

# daemon: true
# Leave this commented until the support matrix says the daemon fits.
# The matrix is on https://davidteren.github.io/mutineer/rails.html#daemon
```

List mutants without running tests. With `--rails`, a dry run needs `--test`, because it skips test pairing:

```sh
RAILS_ENV=test bundle exec mutineer run app/models/order.rb --rails --dry-run \
  --test test/models/order_test.rb
```

Run:

```sh
RAILS_ENV=test bundle exec mutineer run app/models/order.rb --rails
```

## Read the report

```text
Mutation score: 50.0%  (killed / (killed + survived); ...)

Surviving Mutants
-----------------

lib/discount.rb
  Discount#rate (discount.rb:3)
  Operator: comparison  (>= -> >)
  -     return 0.1 if qty >= 10
  +     return 0.1 if qty > 10
```

A survivor is a change no test noticed. Test the missing boundary, exactly 10:

```ruby
def test_ten_is_the_first_bulk_quantity
  assert_equal 0.1, Discount.new.rate(10)
end
```

Run again to kill the mutant.

## Prompt for your coding agent

```text
Run Mutineer on one small file in this repo and explain the result.
1. Pick a small source file with passing tests (Rails: a model in app/models).
2. Run: bundle exec mutineer run <file> --dry-run   (Rails: RAILS_ENV=test, add --rails and --test <its test file>; a Rails dry run needs --test)
3. Run the same command without --dry-run.
4. For each survivor, show the diff and say what behaviour the change breaks.
5. Propose one test per survivor that passes on the original code and fails on the change. Do not change the source.
```

## Next

- [First run to steady state](getting-started.md): add a CI check.
- [Rails setup](rails-setup.md): `--rails`, `--daemon`, databases.
- [CLI reference](cli.md): flags and defaults.

