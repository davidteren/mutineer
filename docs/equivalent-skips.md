# Equivalent skips

Mutineer skips some code changes to reduce results that rarely help improve tests.
These built-in skips cannot be turned off. Chain-call skips use the method
name only, so they are not always equivalent. The endless-range skip applies
only when the receiver is an array or string literal, where `(1..)` and
`(1...)` select the same elements.
Mutineer counts every skip on this page when its operator runs. The chain-link,
call-to-receiver and range operators are not in the default set, so their skips
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

The `range` operator swaps `..` and `...`. It skips an endless range (`1..` or `1..nil`) only when that range is a direct index argument of `[]`, `[]=`, `slice`, `slice!`, `byteslice`, `bytesplice` or `values_at` and the receiver is an array or string literal, as in `"abcd"[1..]` or `%w[a b c].values_at(1..)`. Parentheses and `begin` around that literal count, as in `("abcd")[1..]`. Index writes such as `"abcd"[1..] = "x"` skip the index too.

An array or a string selects the same elements for `(1..)` and `(1...)`, so that mutant is equivalent. The literal is what fixes the class. A variable, a call, or a constant does not: `list[1..]`, `ARGV[1..]`, `text.byteslice(1..)` and `HASH[1..]` are swapped. A Hash tells `{(1..) => :a}[1..]` from `[1...]`, a Proc called as `fn[1..]` receives the range, and a class of your own can define `[]` or `slice` to treat the two ranges differently. A test can kill those mutants. An earlier assignment is not followed, so `list = [1, 2]; list[1..]` is swapped too.

Every other endless range is swapped. This includes the assigned value in `h[:k] = 1..nil` and a range in parentheses, as in `list[(1..)]`. `(1..)` and `(1...)` differ on `==`, `eql?`, `hash`, `exclude_end?`, `to_s`, `inspect` and `cover?(1..)`, so a test that compares, stores or prints the range can kill the mutant.

Some of these mutants are equivalent. A variable that holds an Array or a String, such as `argv[1..]`, selects the same elements for both ranges. So does a range in parentheses inside a slice, or a range used only with `include?`, `===`, `case`/`when`, a `case`/`in` pattern or `clamp`. In a Rails app, a range in an Active Record query also gives an equivalent mutant, because both ranges become the same `>=` SQL condition. That includes `where(created_at: time..)`, `where.not`, `find_by` and `exists?`. So does `validates :age, inclusion: { in: 18.. }`. Suppress such a mutant with `# mutineer:disable-line` or an `ignore:` entry, as described at the top of the page.
