# Mutation testing, explained

Your tests pass. Would they fail if the code were wrong? Mutineer makes small
changes to your Ruby code and runs your tests to find out. It shows you the
changes they missed, so you can decide where a better test would help.

## What is a mutant?

A **mutant** is one changed version of your code. A change might replace `>=`
with `>`, change `+` to `-`, or remove a statement. Mutineer tests one change
at a time with your existing Minitest or RSpec tests.

- **Killed** means a test failed against the changed code. The tests caught it.
- **Survived** means the tests still passed. Read the change: it may reveal a
  missing test, or it may leave the behaviour unchanged.

The changed code is a test of your tests. You do not apply a surviving change
as a fix. Improve the test if the change exposes a gap.

## One missed boundary

An order of 10 or more items should get a 10% discount:

```ruby
return 0.1 if qty >= 10
```

Mutineer changes the rule to:

```ruby
return 0.1 if qty > 10
```

Tests for quantities 1 and 50 still pass. Both versions give the same result
for those inputs. But the changed version gives no discount at exactly 10.
A test for that quantity catches the change.

Line coverage can be 100% here: every line ran. Mutation testing asks a
different question: did the tests notice the wrong result?

## Try the example

Use Ruby 3.4 or later on Linux or macOS, with Bundler installed. Create a new
folder for this example, then create `lib` and `test` folders inside it.
Save this as `Gemfile`:

```ruby
source "https://rubygems.org"
gem "mutineer"
gem "minitest", "~> 5.0"
```

Save this as `lib/discount.rb`:

```ruby
class Discount
  def rate(qty)
    return 0.1 if qty >= 10
    0
  end
end
```

Save this as `test/discount_test.rb`:

```ruby
require "minitest/autorun"
require_relative "../lib/discount"

class DiscountTest < Minitest::Test
  def test_bulk_order_gets_ten_percent
    assert_equal 0.1, Discount.new.rate(50)
  end

  def test_small_order_gets_nothing
    assert_equal 0, Discount.new.rate(1)
  end
end
```

From the example folder, install the gems, check that the tests pass, then
run Mutineer:

```sh
bundle install
bundle exec ruby test/discount_test.rb
bundle exec mutineer run lib/discount.rb --test test/discount_test.rb
```

The report shows a 50% mutation score: one change was caught and one survived.
Under **Surviving Mutants**, look for the change from `>=` to `>`. Add this
method inside `DiscountTest`, before its final `end`:

```ruby
def test_ten_is_the_first_bulk_quantity
  assert_equal 0.1, Discount.new.rate(10)
end
```

Run both checks again:

```sh
bundle exec ruby test/discount_test.rb
bundle exec mutineer run lib/discount.rb --test test/discount_test.rb
```

The tests pass with the original code. Both mutants are now killed and the
score is 100%. You added a test for a case that the original tests missed.

## Read your first report

| Report row | Meaning | What to do |
| --- | --- | --- |
| Killed | A test caught the change. | Keep the test. |
| Survived | The tests still passed. | Read the change and check for a test gap. |
| No coverage | Mutineer could not confirm that tests reached the changed code. | Add a test that reaches it and checks the result. |
| Timeout | The run exceeded the time limit. | Check for a slow test or a change that causes a loop. |
| Errored | The run could not produce a verdict. | Read the error and fix the run before trusting its score. |
| Ignored | You excluded this change. | Keep a clear reason for the exclusion. |
| Skipped | The change did not produce valid Ruby. | No test is needed for this change. |

The **mutation score** is `killed / (killed + survived)`. For example,
24 caught changes and one survivor give `24 / 25 = 96%`. The other rows are
excluded. When nothing can be scored, the score is empty (`null` in JSON).
A high score with many unscored changes can still leave large gaps.

The [report reference](json-schema.html#summary) also explains Uncapturable,
Unplaceable, and Ran at load. The
[timeout rules](https://github.com/davidteren/mutineer/blob/main/docs/ci.md#timeouts-and-the-score)
explain when incomplete results fail a score gate.

## What to do with a survivor

Read the original line and the changed line. Identify an input for which they
should give different results. Add a test for the expected behaviour, then
run your tests and Mutineer again.

Sometimes the change leaves the behaviour unchanged for all inputs your code
supports. This is an **equivalent mutant**. For example, changing `count * 1`
to `count / 1` leaves the value unchanged when `count` is an Integer.
No test can distinguish those results.

If you have checked that a survivor is equivalent, record why you ignore it.
In Mutineer 1.7 or later, `mutineer triage` can print an ignore entry for a
survivor from a JSON report. Select it with `--id ID` and supply its reason with
`--reason TEXT`.
It does not edit your files. See
[Suppressing equivalent mutants](https://github.com/davidteren/mutineer/blob/main/docs/results.md#suppressing-equivalent-mutants).
If you cannot explain a survivor, ask for a review instead of hiding it to raise the score.

## Try your own project

Choose one small file whose tests already pass. In a Bundler project, add
`gem "mutineer", group: :test` to the Gemfile and run `bundle install`.
Then run:

```sh
bundle exec mutineer run lib/discount.rb --test test/discount_test.rb
```

Replace both paths with files in your project. For RSpec, use the spec file
with `--test`. For Rails, follow the [one-model guide](rails.html#one-model).
To list possible changes without running tests, add `--dry-run`.

Each change runs tests again, so mutation testing takes longer than one normal
test run. Start with one file, review its survivors, and expand the scope when
the results are useful. You do not need to reach 100% before the tool has value.

When you are ready, the [CI guide](agentic-coding.html) shows how to check only
changed lines and compare results with an earlier run. The
[support matrix](index.html#production-ready) lists the supported Rails setups.

## Common questions

**Does 100% mean my code has no bugs?** No. It describes the changes that
Mutineer could score. It does not cover every possible bug, and unscored
changes are excluded. Check the survivors and the excluded results too.

**Is this fuzzing?** Fuzzing changes the inputs. Mutation testing changes the
code and runs your tests against it.

**Must I rewrite my test suite first?** No. Start with your existing Minitest
or RSpec tests. Add or improve tests when a survivor reveals a missing check.

**What score should I aim for?** Start by understanding one survivor. Later,
choose a target for code whose results you have reviewed. A number alone does
not show whether the tests cover the behaviour that matters to your users.
