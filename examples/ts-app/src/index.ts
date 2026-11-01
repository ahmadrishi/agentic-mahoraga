// index.ts — the app's public surface: construct and describe Money values.

import { Money, toCents } from "./money";
import { formatMoney } from "./format";

/** Build a Money value from a major-unit amount and a currency code. */
export function makeMoney(amount: number, currency: string): Money {
  return { amountCents: toCents(amount), currency };
}

/** A one-line human description of a Money value. */
export function describe(m: Money): string {
  return formatMoney(m);
}
