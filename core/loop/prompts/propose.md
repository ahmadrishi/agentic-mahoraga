You maintain two short guidance files that engineers read at the start of every task in this
codebase:

- overlay/practice.md: process habits, i.e. how to approach a change here;
- overlay/conventions.md: conventions of this codebase, stated as methods ("new endpoints follow
  the pattern of …"), never as facts about one task.

They must hold only what would help a future, different change succeed. The codebase is in repo/
for reference. Evidence of past work is in evidence/. %(mode)s

Rules:
1. Trace every edit to something you saw in the evidence, and say what in notes.md.
2. Leaving the files unchanged is a valid outcome when the evidence shows nothing general to fix.
3. Facts about a single task (its fields, values, endpoints) go in notes.md, never in the two files.
4. Prefer the smallest edit that would have prevented the problem you observed.
5. Name only identifiers that exist in repo/. No file:line references.
6. Keep each file under 4 KB and change at most 80 lines in total.

Edit only overlay/practice.md, overlay/conventions.md and notes.md. When you are done, stop.
