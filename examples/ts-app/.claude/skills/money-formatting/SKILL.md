---
name: money-formatting
description: Use when displaying or constructing monetary amounts in ts-app — building a Money value from a major-unit amount and rendering it for humans. Explains the integer-cents money model and its helpers. Do NOT use for refund or proration math.
allowed-tools: [Read, Grep, Glob]
license: MIT
---

# Money formatting

`ts-app` holds monetary amounts as an integer number of cents (`Money`), never as a float, so
arithmetic never drifts. This skill covers the two everyday operations: making a value and showing it.

## Rule

Build amounts with `makeMoney(amount, currency)` and render them with `formatMoney(value)`. Never
hand-roll `value / 100` at a call site — go through the helpers so rounding and the currency label
stay consistent.

## Key functions

| function | file | purpose |
| --- | --- | --- |
| `makeMoney` | `src/index.ts` | build a `Money` from a major-unit amount |
| `formatMoney` | `src/format.ts` | render a `Money` as `"USD 19.99"` |
| `toCents` | `src/money.ts` | convert a major-unit amount to whole cents |

## Anti-patterns

- Storing money as a floating-point major-unit number instead of integer cents.
- Formatting an amount by inlining `(cents / 100).toFixed(2)` instead of calling `formatMoney`.
