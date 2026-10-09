# Equivalent skips

Mutineer does not emit some mutants. The change is often noise. A normal test usually cannot kill it. There is no switch to turn these skips off. A chain-link skip matches the method name only. That match does not prove the two mutants are equivalent. An endless range skip is equivalent.

A team still silences an equivalent mutant that Mutineer does emit. Use `# mutineer:disable-line` or an `ignore:` entry, and put a reason on it. `mutineer triage` prints those entries from a JSON report.

## Chain link

The `chain_link` operator drops one dotted call from a chain. It never drops the names below. The skip uses the name only. It does not check the receiver or the next call. The dropped call is often equivalent, not always. On a value that already has the target type, or that needs no copy, the call changes nothing. Dropping `new` sends the next call to the class. That raises, or it reaches a class method. Neither result says anything about the tests.

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
