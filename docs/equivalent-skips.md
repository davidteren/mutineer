# Equivalent skips

Mutineer skips some code changes to reduce results that rarely help improve tests.
These built-in skips cannot be turned off. Chain-call skips and the endless-range
skip use the method name only, so they are not always equivalent.
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
as in `# mutineer:disable-line call_to_receiver -- already a String`, so it
does not hide other mutants on the line. An `ignore:` entry with the
survivor `id` suppresses only that one mutant.

| Name | Why it is skipped |
|------|-------------------|
| `new` | The class takes the place of an instance, so almost any use raises. |
| `dup` | Copy. The mutant shows when code later changes the copy or the original, or compares the result with the original by identity. |
| `clone` | Copy. The mutant shows when code later changes the copy or the original, or compares the result with the original by identity. |
| `freeze` | Returns the receiver, now frozen. A `frozen?` check or a later write shows the difference. |
| `itself` | Returns the receiver. |
| `to_set` | For common uses of `include?` and `empty?`, an array answers as a set does, so the mutant is often equivalent. Membership can differ: an array compares with `==` and a set with `eql?`, so `[1].include?(1.0)` is true and `Set[1].include?(1.0)` is false. The array keeps duplicates, so `size` and `each` can differ. |

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
