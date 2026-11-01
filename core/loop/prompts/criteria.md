You are writing the acceptance criteria that implementations of a change will be graded against.

Below are the SPEC, the BUSINESS REQUIREMENT and the REFERENCE DIFF a human shipped for them.
Write the criteria from what the SPEC and the BUSINESS REQUIREMENT ask for. Use the reference diff
only to see which parts of the ask this repository is responsible for: it is one valid solution,
never the definition of a correct one. Each criterion:
- is one atomic, checkable outcome, stated as behaviour the code must have;
- has a `source`: the sentence of the SPEC or BUSINESS REQUIREMENT it comes from, quoted exactly.
  A choice the human made that the ask does not require (a response shape, a field name the ask
  does not give, logging, persistence, a class or method name) is not a criterion;
- belongs to this repository: skip parts of the ask that are clearly another system's job;
- has a weight: 3 = core to the ask, 2 = expected, 1 = minor.

Write 5 to 10 criteria, with ids c1, c2, … in order.
