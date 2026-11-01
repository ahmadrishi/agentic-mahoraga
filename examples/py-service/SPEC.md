# SPEC — Prorated refund helper

## Context

The `py-service` billing package already models amounts as integer cents (`Money`) and can build,
render, and post them to a `Ledger` (`make_money`, `format_money`, `to_cents`, `Ledger.post`).
When a customer cancels a pre-paid term early, support staff need to know how much of the payment
to return.

## Requirement

Add a pure function that returns the refundable amount for the **unused** portion of a paid term.

- Inputs: the amount that was `paid` (a `Money`), the `total_days` of the term, and the `used_days`
  already consumed.
- Output: a `Money`, in the **same currency** as the payment, whose value is the paid amount scaled
  by the fraction of the term left unused.
- Edge cases:
  - A term with `total_days <= 0` yields a zero refund (no division by zero).
  - `used_days >= total_days` (fully used, or over-used) yields a zero refund — never negative.
  - The result is rounded to whole cents.

## Out of scope

- Persistence, currency conversion, tax, and fees. This is a single deterministic calculation that
  reuses the existing `Money` model.

## Acceptance

`python3 -m py_compile src/*.py` passes, and the new function lives in the `src/` tree alongside the
money model and ledger.
