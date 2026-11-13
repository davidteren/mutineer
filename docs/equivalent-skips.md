# Equivalent skips

Mutineer skips some code changes to reduce results that rarely help improve tests.
These built-in skips cannot be turned off. Chain-call skips and the endless-range
skip use the method name only, so they are not always equivalent.
Mutineer counts every skip on this page when its operator runs. The collection-method,
chain-link, call-to-receiver and range operators are not in the default set, so their skips
are counted only when `--operators` selects them. The dry run prints the count,
and the JSON report gives it in `summary.declined_by_operator`.

For an equivalent mutant that does appear, use `# mutineer:disable-line` or an
`ignore:` entry and record a reason. An ignore mapping contains an `id` and an
optional `reason`; it requires Mutineer 1.7 or later everywhere the configuration
is read. Older versions do not apply mappings and do not warn, so the named mutant
is not ignored. `mutineer triage` prints these entries using survivor ids from a
JSON report. Select survivors with `--id ID` (repeat it for more than one), or
use `--all` for every survivor. Supply the reason with the required `--reason TEXT`
argument. The command does not edit files. See
[Suppressing equivalent mutants](https://github.com/davidteren/mutineer/blob/main/docs/results.md#suppressing-equivalent-mutants).

## Chain link

The `chain_link` operator removes a call from the middle of a chain. It skips
the names below without checking the receiver or next call. Conversions and
copies often leave the result unchanged. Removing a middle `new` sends the next
call to the class. That can raise an error or reach a class method that builds
the instance itself. The `call_to_receiver` operator has its own, shorter list:
see [Call to receiver](#call-to-receiver).

| Name | Why it is skipped |
|------|-------------------|
| `to_s` | Conversion. On a string, the call changes nothing. |
| `to_str` | Conversion. On a string, the call changes nothing. |
| `to_sym` | Conversion. On a symbol, the call changes nothing. |
| `to_i` | Conversion. On an integer, the call changes nothing. |
| `to_int` | Conversion. On an integer, the call changes nothing. |
| `to_f` | Conversion. On a float, the call changes nothing. |
| `to_r` | Conversion. On a rational, the call changes nothing. |
| `to_c` | Conversion. On a complex number, the call changes nothing. |
| `to_a` | Conversion. On an array, the call changes nothing. |
| `to_ary` | Conversion. On an array, the call changes nothing. |
| `to_h` | Conversion. On a hash, the call changes nothing. |
| `to_hash` | Conversion. On a hash, the call changes nothing. |
| `to_proc` | Conversion. On a proc, the call changes nothing. |
| `to_set` | Conversion. On a set, the call changes nothing. |
| `dup` | Copy. Dropping it is a no-op when the next call does not mutate the receiver. |
| `clone` | Copy. Dropping it is a no-op when the next call does not mutate the receiver. |
| `freeze` | A freeze that nothing later mutates changes nothing a test can see. |
| `itself` | Returns the receiver. Dropping it changes nothing. |
| `new` | The next call goes to the class. That raises, or it is a class method. |

## Call to receiver

The `call_to_receiver` operator replaces the last call of a chain with its
receiver. It does not use the `chain_link` list. It skips only the names below,
by name only. It replaces the other conversions, such as `to_s` and `to_i`. On
the last call, a conversion decides the type of the value that the expression
returns, so a test can check it. Some of those mutants are equivalent, for
example `to_s` on a value that is already a string, or inside string
interpolation. Suppress them with `# mutineer:disable-line call_to_receiver` or an `ignore:`
entry, as the top of the page says. Scope the marker to the operator,
as in `# mutineer:disable-line call_to_receiver -- already a String`.
A scoped marker keeps mutants from other operators.
It hides every `call_to_receiver` mutant on that line.
An `ignore:` entry with the survivor `id` suppresses only that one mutant.

| Name | Why it is skipped |
|------|-------------------|
| `new` | The class takes the place of an instance, so almost any use raises. |
| `dup` | Copy. The mutant shows when code later changes the copy or the original, or compares the result with the original by identity. |
| `clone` | Copy. The mutant shows when code later changes the copy or the original, or compares the result with the original by identity. |
| `freeze` | Returns the receiver, now frozen. A `frozen?` check or a later write shows the difference. |
| `itself` | Returns the receiver. |
| `to_set` | For common uses of `include?` and `empty?`, an array answers as a set does, so the mutant is often equivalent. Membership can differ: an array compares with `==` and a set with `eql?`, so `[1].include?(1.0)` is true and `Set[1].include?(1.0)` is false. The array keeps duplicates, so `size` and `each` can differ. |

### Triage a `present?` survivor

`call_to_receiver` is not a default operator.
This mutant appears only when you select that operator.
Select it with the CLI flag `--operators`.
Select it with the `.mutineer.yml` key `operators:`.
Select it with the Action input `operators`.
The Action passes that input to the CLI as `--operators`.
The `--operators` list replaces the default set.
See [Endless range](#endless-range).

The mutant is equivalent in one case.
The receiver is always a non-blank object, or it is `nil` or `false`.
A record is one example.
A non-blank string is another, when the call is only a condition.
The code uses the result only as a condition.

These cases are real gaps:

- A blank string or a blank param, such as `""` or `" "`.
- An empty array.
- An empty hash.
- An empty relation.
- A method that returns the `present?` result.

Pass a blank value to kill a gap in a condition.
Assert the exact value `true` or `false` when a method returns the result.

`if params[:day].present?` survives a test that sends only a valid date.
Pass `day: ""` and expect the fallback.
That test kills the mutant.

`def has_tags?(tags) = tags.present?` survives `assert has_tags?(["x"])`.
`assert_equal true, has_tags?(["x"])` kills that mutant.

Suppress one mutant with an `ignore:` mapping.
Use the survivor `id` from the JSON report.
Record a reason.

```yaml
# .mutineer.yml
ignore:
  - id: ID_FROM_THE_JSON_REPORT
    reason: the receiver is a record or nil, and the result is only a condition
```

`mutineer triage REPORT.json --id ID --reason TEXT` prints one mapping.
Repeat `--id` for each site you judge equivalent.
Do not use `--all`.
`--all` also maps survivors that are real gaps.

An `ignore:` id changes after a file move.
It also changes after a method rename or a class rename.
The survivor then returns.
See [Mutant ids](https://github.com/davidteren/mutineer/blob/main/docs/results.md#mutant-ids).

Do not use a line marker for this site.
The marker hides every `call_to_receiver` mutant on that line.
It also hides `account.name` becoming `account`.
That second mutant is not equivalent.
Use the `ignore:` id above for the `present?` mutant only.

```ruby
account.name if account.present? # mutineer:disable-line call_to_receiver
```

A disable marker moves with its line.

`present?` stays off the skip list.
The operator checks the method name only.
It cannot inspect the receiver, so a name skip would also hide real gaps.

## Endless range

The `range` operator is not in the default set. Add it to the `operators:` list in `.mutineer.yml`, or pass `--operators`. The `--operators` list replaces the default set, so name the default operators too.

```yaml
# .mutineer.yml
operators:
  - arithmetic
  - comparison
  - boolean_connector
  - boolean_literal
  - statement_removal
  - range
```

```sh
mutineer run lib --operators arithmetic,comparison,boolean_connector,boolean_literal,statement_removal,range
```

The `range` operator swaps `..` and `...`. It skips an endless range (`1..` or `1..nil`) only when the range is a direct argument of `[]`, `[]=`, `slice`, `slice!`, `byteslice`, `bytesplice` or `values_at`, as in `argv[1..]` or `text.byteslice(offset..)`. Index writes such as `list[1..] += x` are skipped too.

For a slice of an Array or String, `(1..)` and `(1...)` select the same elements, so the mutant is equivalent. The check uses the method name and the receiver. A call on a class, such as `Array[1..]` or `Set[1..]`, builds a value, so it is not skipped. A constant in capitals only, such as `ARGV[1..]`, is skipped. A Hash with range keys tells `h[1..]` from `h[1...]`, a Proc called with `fn[1..]` gets the range itself, and a class of your own can define `[]` or `slice` to treat the two ranges differently. In those cases the skip hides a mutant a test can kill.

Every other endless range is swapped. This includes the assigned value in `h[:k] = 1..nil` and a range in parentheses, as in `list[(1..)]`. `(1..)` and `(1...)` differ on `==`, `eql?`, `hash`, `exclude_end?`, `to_s`, `inspect` and `cover?(1..)`, so a test that compares, stores or prints the range can kill the mutant.

Some of these mutants are equivalent: a range in parentheses inside a slice, or a range used only with `include?`, `===`, `case`/`when`, a `case`/`in` pattern or `clamp`. In a Rails app, a range in an Active Record query, as in `where(created_at: time..)`, also gives an equivalent mutant, because both ranges become the same `>=` SQL condition. So does `validates :age, inclusion: { in: 18.. }`. Suppress such a mutant with `# mutineer:disable-line` or an `ignore:` entry, as described at the top of the page.

## Collection method

The `collection_method` operator is not in the default set. Select it with `--operators` or with `operators:` in `.mutineer.yml`. The `--operators` list replaces the default set, so name the default operators too.

The operator swaps `each` with `map`, `all?` with `any?`, `first` with `last`, `min` with `max`, and `select` with `reject`. It skips `each` and `map` when the call's result is discarded. For `Enumerable`, `each` returns the receiver and `map` returns a new array, so a discarded value is the same. A method of either name on another class can still differ, and the check does not see the class, so the skip can hide that difference. Each skipped call counts as declined.

The check uses the syntax tree only. It does not know the receiver's class. A method named `each` that is not `Enumerable#each` follows the same rule. One receiver is visible in the tree: a chain that calls `lazy`, as in `xs.lazy.each` or `xs.lazy.map { }.each`. `Enumerator::Lazy#each` runs the block and `Lazy#map` does not, so that chain is still swapped. A lazy enumerator stored in a variable has no `lazy` call left in the chain, so a discarded statement on that variable is still skipped.

The result is discarded, and the swap is skipped, when the call is a statement and nothing keeps that statement's value:

- It is not the last expression of the method.
- It is not the last expression of a block or a lambda. The method that takes the block may use the block's result. The operator does not guess which methods do. A loop that is the last line of a block is still swapped.
- It is not the last expression of a branch whose value is kept. A branch is an `if`, `unless`, `case`, `rescue`, `else`, ternary, or modifier.
- A `while`, `until`, or `for` body discards its value, including the last line. `for` returns the collection, not the body. An `ensure` body discards its value too. `defined?` does not read the call's result.
- A `begin`, parentheses, an array, a hash value, a range, or `and` / `or` / `&&` / `||` keeps the value only when the outer expression keeps it. A hash key is always kept: insertion calls `hash` and `eql?`.
- String interpolation, symbol interpolation, a backtick or `%x` command, and an interpolated regexp (`/.../` or `%r{}`) always keep the swap. Interpolation calls `to_s`. The command runs. The regexp is compiled. That happens even when the expression's result is thrown away.

The result is kept, and the swap still runs, when the call is any of these:

- The last expression of the method, a block, or a lambda.
- Assigned, including `+=`, `||=`, multiple assignment, and a pattern match (`=>`).
- Passed as an argument, a splat, a keyword value, or a block argument.
- The receiver of another call, as in `users.each { }.size` or `!users.each`. The next call may use the object. The swap stays even when that next call's own result is discarded.
- Returned with `return`, `break`, or `next`.
- The object of `class << obj`.
- A condition of `if`, `unless`, `while`, `until`, or `case`, or a `when` value. Both results are true for an ordinary receiver, so some of these mutants are equivalent. The syntax reads the value, so the operator still emits them.

`all?`, `any?`, `first`, `last`, `min`, `max`, `select`, and `reject` are swapped even when the result is discarded. `all?` and `any?` can stop on different elements. A block can show that change.

The report that opened this skip found the `each` to `map` mutant in 4 of 23 ignore entries.
