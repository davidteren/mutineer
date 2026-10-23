# Equivalent skips

Mutineer skips some code changes to reduce results that rarely help improve tests.
These built-in skips cannot be turned off. Chain-call skips use the method name
only, so they are not always equivalent. Endless-range skips are equivalent.

For an equivalent mutant that does appear, use `# mutineer:disable-line` or an
`ignore:` entry and record a reason. An ignore mapping contains an `id` and an
optional `reason`; it requires Mutineer 1.7 or later everywhere the configuration
is read. Older versions silently skip mappings. `mutineer triage` prepares these
entries from a JSON report. See
[Suppressing equivalent mutants](https://github.com/davidteren/mutineer#suppressing-equivalent-mutants).

## Chain link

The `chain_link` operator removes a call from the middle of a chain.
The `call_to_receiver` operator removes the last call. Both skip the names below
without checking the receiver or next call. Conversions and copies often leave
the result unchanged. Removing `new` leaves the class in place of an instance,
which usually raises an error or calls an unrelated class method.

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

## Endless range

The `range` operator swaps `..` and `...`. An endless range (`1..` or `1..nil`) is skipped. `(1..)` and `(1...)` give the same result for slicing, `include?`, `===`, `size`, and patterns, so the mutant is equivalent.
