---
name: money-cents-guard
description: Use when adding or changing monetary math in py-service — building, returning, or posting money amounts. Enforces the integer-cents money model and its single-currency rules so arithmetic never drifts and derived amounts stay in the payer's currency. Do NOT use for ledger persistence, reporting, or tax/fee logic (out of scope for this fixture).
allowed-tools: [Read, Grep, Glob]
license: MIT
mahoraga:
  kind: guard
  grounding: none
  provenance: "hand-authored behavioral guard for the py-service fixture; not machine-generated"
---

# Money stays in whole cents, in one currency

`py-service` holds every monetary amount as an integer number of cents inside a `Money` value —
never as a floating-point major-unit number — so repeated arithmetic never drifts. Any new money
math must go through the existing model rather than re-deriving cents or currency at the call site.

## Rule

Build amounts with `make_money(amount, currency)`, convert raw major units with `to_cents(amount)`,
and render for humans with `format_money(value)`. Carry the currency from the input `Money` through
to every result you return — never hard-code a currency or hand-roll `amount_cents / 100` at a call
site. Guard divisions: a zero or negative denominator returns a zero `Money`, never raises or goes
negative.

## Steps

1. Take money in as a `Money` (`amount_cents`, `currency`); read `amount_cents` for the integer math.
2. Do the arithmetic in integer cents; round to a whole cent exactly once at the end.
3. Return a `Money` whose `currency` equals the input's currency.
4. Post settled amounts through `Ledger.post`, which rejects a currency that does not match the ledger.

## Key types & classes

| symbol | file | purpose |
| --- | --- | --- |
| `Money` | `src/ledger.py` | integer-cents amount + currency (frozen dataclass) |
| `to_cents` | `src/ledger.py` | major-unit amount -> whole cents |
| `make_money` | `src/ledger.py` | build a `Money` from a major-unit amount |
| `format_money` | `src/ledger.py` | render a `Money` as `"USD 19.99"` |
| `Ledger` | `src/ledger.py` | single-currency append-only entry store |

## Worked example

Scaling an amount by a fraction: read `paid.amount_cents`, multiply by the integer numerator, divide
by the integer denominator, `round(...)` to a whole cent, then wrap the result back up as
`Money(amount_cents=..., currency=paid.currency)`. The currency rides along from `paid`.

## Anti-patterns

- Storing money as a floating-point major-unit number instead of integer cents.
- Formatting an amount by inlining `(amount_cents / 100)` instead of calling `format_money`.
- Returning a result in a default or hard-coded currency instead of the payer's currency.
- Dividing without first clamping a zero or negative denominator to a zero `Money`.

## Related skills

None in this fixture — this is the only staged skill; the baseline arm stages an empty skills set.
