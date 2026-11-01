# SPEC — Prorated refund helper

## Context

The `ts-app` money module already models amounts as integer cents (`Money`) and can build and
format them (`makeMoney`, `formatMoney`). When a customer cancels a pre-paid term early, support
staff need to know how much of the payment to return.

## Requirement

Add a pure function that returns the refundable amount for the **unused** portion of a paid term.

- Inputs: the amount that was `paid` (a `Money`), the `totalDays` of the term, and the `usedDays`
  already consumed.
- Output: a `Money`, in the **same currency** as the payment, whose value is the paid amount scaled
  by the fraction of the term left unused.
- Edge cases:
  - A term with `totalDays <= 0` yields a zero refund (no division by zero).
  - `usedDays >= totalDays` (fully used, or over-used) yields a zero refund — never negative.
  - The result is rounded to whole cents.

## Out of scope

- Persistence, currency conversion, tax, and fees. This is a single deterministic calculation.

## Acceptance

`tsc --noEmit` passes, and the new function lives in the `src/` tree alongside the money model.
