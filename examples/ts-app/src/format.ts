// format.ts — presentation helpers for the money model.

import { Money } from "./money";

/** Render a Money value as a human string, e.g. "USD 19.99". */
export function formatMoney(m: Money): string {
  const major = (m.amountCents / 100).toFixed(2);
  return `${m.currency} ${major}`;
}
