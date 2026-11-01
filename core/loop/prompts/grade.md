You are grading a CANDIDATE diff against frozen acceptance criteria. The candidate was written by an
implementer who saw only the SPEC and the BUSINESS REQUIREMENT. The REFERENCE diff is what a human
shipped: use it to understand the codebase and the intended behaviour, never as a target to match.
A different solution that delivers a criterion's behaviour meets it.

For each criterion, give its id, a status (full, partial or none) and evidence: a line quoted from
the candidate's added code, or "absent". Then:
- hallucination: present = true if the candidate relies on a symbol, API or file that does not exist;
- overeng: present = true if the candidate built scope the ask did not need;
- lost_context: present = true if the candidate produces a value that nothing reads, or reads one
  that nothing produces.
For each of these three, `note` names the specific instance when present is true, and is empty
when it is false.
- code_quality: overall better, equal, worse or mixed against the reference, with a one-line rationale;
- security: verdict "none — parity/better", or "net-new: <a reachable threat the reference does not have>".

Judge only from the text below. Do not assume code that is not shown.
