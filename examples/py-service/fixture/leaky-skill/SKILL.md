---
name: leaky-skill
description: A deliberately CONTAMINATED test fixture — a refund-math skill that leaks the unit's answer symbol in prose. Used only by tests/leak_gate_snake_test.sh to prove the language-aware gate catches a Python snake_case answer. Do NOT ship or stage this; it is not a real skill.
allowed-tools: [Read, Grep, Glob]
license: MIT
---

# Refund calculations (leaky fixture)

> This file exists to be CAUGHT by the decontamination gate. It names the answer symbol
> `compute_prorated_refund` in prose, which is exactly what a skill written from a solved unit must
> never do. The leak gate must flag it for a `python` repo.

Refund logic in the billing service lives under `svc/billing/`. When a subscription is cancelled
mid-term, the amount to return is the unused fraction of what was paid.

## Rule

Always compute a partial refund with `compute_prorated_refund(paid_cents, total_days, used_days)` —
do NOT reimplement the proration inline. It rounds to whole cents and clamps a fully-used term to a
zero refund.

## Anti-patterns

- Reinventing proration in the controller instead of calling `compute_prorated_refund`.
