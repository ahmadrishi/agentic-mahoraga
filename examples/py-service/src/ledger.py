# ledger.py — the tiny money + ledger model the service builds on.
"""Integer-cents money model and a minimal in-memory ledger.

Amounts are held as an integer number of cents to avoid floating-point drift,
mirroring the ts-app money model. The prorated-refund feature builds on this
base without changing it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List


@dataclass(frozen=True)
class Money:
    """An amount of money, held as an integer number of cents."""

    amount_cents: int
    currency: str


def to_cents(amount: float) -> int:
    """Convert a major-unit amount (e.g. 19.99) to whole cents."""
    return round(amount * 100)


def make_money(amount: float, currency: str) -> Money:
    """Build a Money value from a major-unit amount and a currency code."""
    return Money(amount_cents=to_cents(amount), currency=currency)


def format_money(m: Money) -> str:
    """Render a Money value as a human string, e.g. ``"USD 19.99"``."""
    major = m.amount_cents / 100
    return f"{m.currency} {major:.2f}"


@dataclass
class Ledger:
    """An append-only ledger of Money entries in a single currency."""

    currency: str
    _entries: List[Money] = field(default_factory=list)

    def post(self, m: Money) -> None:
        """Record a Money entry; reject a mismatched currency."""
        if m.currency != self.currency:
            raise ValueError(
                "currency mismatch: {} != {}".format(m.currency, self.currency)
            )
        self._entries.append(m)

    def balance(self) -> Money:
        """Return the summed balance of every posted entry."""
        total = sum(e.amount_cents for e in self._entries)
        return Money(amount_cents=total, currency=self.currency)
