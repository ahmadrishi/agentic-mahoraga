---
name: reuse-before-create
description: Use BEFORE writing any new class, helper, service, validator, util, DTO, endpoint, scheduled job, or config parameter. First search the ENTIRE codebase — including unrelated features — for an existing equivalent to reuse, extend, or generalize instead of writing a parallel implementation, and verify what you reuse (its semantics and side-effects). Also fires on restore / revert / re-add / "add X" tasks — grep first and confirm X isn't ALREADY present and wired before re-adding it. Do NOT use for confirming your output reaches its consumer (that is trace-to-consumer) or for proving the change compiles and runs (that is verification-before-advance).
allowed-tools: Read, Grep, Glob
license: MIT
mahoraga:
  kind: guard
  grounding: none
---

# Reuse Before Create

The single most common avoidable defect when implementing a spec is **reinventing something the
codebase already has** — usually because the existing implementation lives in an *unrelated* feature
the implementer never looked at. An engineer with broad familiarity reuses it; a fresh implementer
must go *find* it. This skill makes that search a required step, and makes verifying what you reuse
part of the job.

## When it triggers

Any task whose implementation would add a new production symbol. Especially: validation
(URL / host / IP / signature / format), external-client wiring (an HTTP / SMS / cloud / payment
client), scheduled or background work, notifications / internal notes, config values or feature
flags, per-entity management screens, and "expose a reusable method / add support for X" building-block
tasks. Also every **restore / revert / re-add / "add X"** task (see the pre-flight below).

## The rule

**Before you create ANY new production symbol** (class, interface, service/component, helper/util,
validator, DTO, projection, endpoint, scheduled job, config parameter, exception), first search the
whole codebase for an existing equivalent, and prefer — in this order:

1. **Reuse** it as-is (call the existing function/bean). **Nearest-existing-first:** when more than
   one equivalent turns up, prefer the symbol **already wired in at the exact call-site you are
   touching** over one that lives in another feature. A broad capability search is for *finding*
   candidates, not for *swapping* the locally-established one for a look-alike — that trades a
   reinvention risk for a divergence/regression risk.
2. **Extend** it (add a method/overload to the existing helper that already holds the relevant state
   or wiring).
3. **Generalize** it — if the same logic exists inline in one feature, extract a shared util and
   point **both** the old and new call sites at it (leaves the codebase cleaner than you found it).
4. **Create new** — only when a broad search finds nothing suitable. Say so explicitly, and record
   what you searched for.

## Pre-flight — verify current state FIRST (restore / revert / re-add / "add X")

**The spec's framing may not match the codebase.** A task that says *restore*, *revert*, *re-add*,
*bring back*, or *add X* describes an intended **end-state** — it is **not** proof X is currently
missing. History moves on: the thing may already have been re-added, never fully removed, or
reintroduced by a later commit than the one the task references. Run this **before** implementing:

1. **Grep for the exact thing the task names** — the component, route path, module registration,
   field, DB column, method, endpoint, or config key — **by name** across the codebase.
2. **If it does NOT exist** → implement as specified (still doing the reuse search above).
3. **If it ALREADY EXISTS and is wired** → do **NOT** re-add it. Re-adding something already present
   duplicates it and can **break the build** (duplicate route, duplicate registration, duplicate
   method/column). Instead:
   - **Verify it works end-to-end** (the route resolves, the field is read *and* written, the method
     is actually called).
   - Implement **only** the parts genuinely missing.
   - **Report the spec-vs-codebase mismatch:** *"Spec says restore/add X; X was already present and
     wired at the fork-point — verified working, re-added nothing (or only the missing part Y)."*

A **no-op is a valid, high-quality result** here. Do not manufacture changes to look busy, and do
not follow a "restore" spec into a broken duplicate. **Reconcile and report — don't duplicate.**

## Steps — how to search (by capability, not just by name)

Grep broadly for the *capability*, across the whole codebase, using several concept/synonym terms —
not just the class name you have in mind. For each capability you are about to add, brainstorm 3–5
concept words and grep case-insensitively before writing anything. Generic starting points:

- URL / host / SSRF validation → `grep -rniE "trusted.?hosts?|validateUrl|allow.?list|isLoopback|link.?local"`
- external client / webhook signature → `grep -rniE "signature|validateRequest|RestClient|HttpClient|createMessage"`
- scheduled work → `grep -rniE "@Scheduled|cron|JobDefinition|task|migrationscript"`
- an internal note / status flag → `grep -rniE "internalNote|privateMessage|setStatus|markAs"`
- a config value → `grep -rniE "parameter|featureFlag|getConfig|settings\.get"`
- a management screen / CRUD pattern → find the closest existing sibling and mirror its shape.

Then read the closest existing sibling and mirror it. Also scan this project's **mapping/spec skill
and skills index** (forged by the ADAPT step) for one that already documents the mechanism — the
grounded vocabulary map is your fastest route to "does this already exist here."

## Verify what you reuse (semantics + side-effects)

Finding the right thing to reuse is only half the job. Once you pick a shared method/DTO to route
through, **read what it actually returns and where else it flows** before you depend on it — reuse
can silently inherit a latent defect or leak your change onto sibling call-sites.

1. **Pagination / count semantics — does the reused query return a *real* total?** A shared search
   can hand back a page object whose total is a placeholder (e.g. constructed with a hard-coded `0`),
   so `hasNext()` / `total` lie and any consumer that paginates by page metadata silently under-fetches
   past page 1. If your consumer needs a true total, pair the search with the real count method (or add
   a count query) — don't trust the page object the shared method hands back.
2. **Shared-path blast radius — what *else* uses what you widened?** Slotting your case into a shared
   filter DTO / guard / query-builder changes **every** existing caller of that path, not just your
   endpoint. Widening a shared filter can be the right DRY call — but only after you confirm the other
   callers still behave, and you record the blast radius. Often the narrower fix (a dedicated query for
   your case) is safer than widening the shared one.
3. **Narrowest scope for a new field.** Put a new request/response field on the **narrowest DTO that
   needs it**, never a broad parent — a parent field is accepted-but-ignored on every sibling endpoint
   that binds the parent.

This complements the reuse/extend/generalize ladder above: that ladder picks **what** to reuse; this
verifies the **semantics and side-effects** of reusing it.

## Record what you did

In your notes / PR description, include a `reuse_search`: the terms you searched, what existing code
you found, and for each new symbol whether you **reused / extended / generalized / created-new** and
why. If you created new, state what you searched for and why nothing fit.

## Worked examples

- **SSRF / URL validation.** A fresh implementer writes a standalone `UrlValidator` — but the
  `payments` module's HTTP client already does HTTPS + a configurable trusted-host allow-list.
  ✅ Correct move: extract a shared `UrlSecurityValidator`, point **both** the new media-fetch guard
  and the existing client at it, and add the private/link-local/metadata-IP blocking the old one
  lacked. One validator, two call sites, the pre-existing path hardened.
- **Webhook signature validator.** Instead of a new service, **extend the existing configured client**
  that already holds the account id / auth token — add the `isValidRequest(...)` method there.
- **Per-tenant templates.** Don't invent a management shape — **mirror the existing template
  service/controller** per-tenant pattern; add the migration to the existing migration mechanism; put
  the deletion guard in the existing delete choke point.
- **Nearest-first, not just any-existing.** The edit site already renders JSON with an inline editor
  component. A broad search *also* finds a read-only JSON tree viewer used in a *different* screen.
  ✅ Correct move: extend the editor **already at the edit site** (add a raw/tree toggle), **not** swap
  in the cross-feature viewer. Both are "reuse," but swapping the locally-established component for a
  look-alike from another feature is a divergence/regression, not a win.
- **Restore a feature that was already present.** The task said "restore the reporting feature —
  re-add the four removed components and re-register the route." At the fork-point **all four
  components, their registrations, and the route were already present and wired** — re-adding them
  would have duplicated the route + registrations and **broken the build**. The correct result was to
  verify the feature works, change nothing, and report the contradiction (the human's own shipped diff
  re-added none of them). **A no-op was the correct implementation.**

## Anti-patterns

- Creating `XxxValidator` / `XxxUtils` / `XxxService` without grepping for an existing one in *other*
  features first.
- Duplicating an inline pattern instead of extracting it and updating both sites.
- Hard-coding a value instead of an existing/added config parameter.
- Adding a parallel external client instead of reusing the module's configured one.
- Swapping the component/helper **already used at the call-site** for an equivalent found in another
  feature (violates nearest-existing-first).
- Blindly following a **restore / revert / re-add / add X** spec without grepping first — then
  re-adding something already present and wired, duplicating it and breaking the build.
- Routing a new paginating endpoint through a shared search whose page object carries a fake total.
- Widening a shared filter DTO / guard / query-builder for one new case without checking the other
  callers of that shared path.

## In a decomposed build

When several sub-agents build one feature in parallel, the reuse search must extend to the **shared
interface contract**: reuse the agreed entity/DTO/param types and their exact field types (do not
re-model a shared entity's field as a different type). Pin field types and relation shapes in the
contract; the merge + compile gate will catch divergences.

## Related skills

- [`trace-to-consumer`](../trace-to-consumer/SKILL.md) — the forward search: this finds an existing
  *producer* to reuse (backward search); that confirms your output reaches its *consumer*. Run both.
- [`small-diff-surgical-change`](../small-diff-surgical-change/SKILL.md) — the blast-radius of
  widening a shared symbol is a surgical-change concern too.
- [`simplicity-first`](../simplicity-first/SKILL.md) — reusing what exists is usually the simplest
  design; creating a parallel implementation is a hidden complexity cost.
- [`surface-assumptions`](../surface-assumptions/SKILL.md) — the verify-current-state-first drill
  above is the reuse-specific case of "don't trust the spec's framing."
- [`verification-before-advance`](../verification-before-advance/SKILL.md) — prove the reused/extended
  path still compiles and runs.
