# py-service — a tiny payments/billing service used as an Agentic Mahoraga fixture.
"""Public surface of the py-service package.

The base tree exposes the money model and the in-memory ledger. The
prorated-refund feature is added by ``setup-fixture.sh`` as the single
unit-of-work commit; like ts-app's ``index.ts``, the base package does not
re-export that feature — callers import it from the refund module once the
feature commit lands. The base tree deliberately names no answer symbol.
"""

from .ledger import Ledger, Money, format_money, make_money, to_cents

__all__ = ["Ledger", "Money", "to_cents", "make_money", "format_money"]
