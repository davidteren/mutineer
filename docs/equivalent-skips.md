# Equivalent skips

Mutineer skips some code changes to reduce results that rarely help improve tests.
These built-in skips cannot be turned off. Chain-call skips use the method name
only, so they are not always equivalent. Endless-range skips are equivalent.

For an equivalent mutant that does appear, use `# mutineer:disable-line` or an
`ignore:` entry and record a reason. An ignore mapping contains an `id` and an
optional `reason`; it requires Mutineer 1.7 or later everywhere the configuration
is read. Older versions do not apply mappings and do not warn, so the named mutant
is not ignored. `mutineer triage` prints these entries using survivor ids from a
JSON report. Select survivors with `--id ID` (repeat it for more than one), or
use `--all` for every survivor. Supply the reason with the required `--reason TEXT`
argument. The command does not edit files. See
[Suppressing equivalent mutants](https://github.com/davidteren/mutineer#suppressing-equivalent-mutants).

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

The `range` operator swaps `..` and `...`. An endless range (`1..` or `1..nil`) is skipped. `(1..)` and `(1...)` give the same result for slicing, `include?`, `===`, `size`, and patterns, so the mutant is equivalent.
