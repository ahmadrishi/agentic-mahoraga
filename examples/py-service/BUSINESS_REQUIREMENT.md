# Business requirement — refund the unused part of a cancelled term

**As** a support agent handling an early cancellation,
**I want** the service to tell me the refund owed for the days the customer did not use,
**so that** I can process a fair partial refund without doing the arithmetic by hand.

## Rules the business cares about

- The refund is proportional to the unused days of the paid term.
- Using the whole term (or more) means no refund is owed — we never bill a negative refund.
- Refunds are always in the currency the customer originally paid in.
- Amounts are settled in whole cents.

## Notes

This requirement stands in for the kind of short, PR-body-sized ask a tracker would carry. In a real
run the tracker adapter supplies this text; here it is committed so the example is self-contained.
