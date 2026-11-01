// money.ts — the tiny money model the rest of the app builds on.

/** An amount of money, held as an integer number of cents to avoid float drift. */
export interface Money {
  amountCents: number;
  currency: string;
}

/** Convert a major-unit amount (e.g. 19.99) to whole cents. */
export function toCents(amount: number): number {
  return Math.round(amount * 100);
}
