#!/usr/bin/env python3
# cutoff_label.py — the pretraining-cutoff labeler.
#
# Protects the "decontaminated" claim: a unit is only "cutoff-clean" (could NOT be in public
# pretraining) when it is either private code or was merged AFTER the model's pretraining cutoff.
# Everything else is "cutoff-unverified" and MUST NOT back a headline number (see the honesty rule
# in skills/prove/blind-eval + docs/DECONTAMINATION.md). Consumed by aggregate_scores.py /
# build_report.py via the per-unit score.json fields (cutoff_label / cutoff_reason).
#
#   label(merged_at, repo_visibility, model_cutoff) -> (cutoff_label, cutoff_reason)
#   CLI: python3 core/lib/cutoff_label.py <merged_at> <repo_visibility> <model_cutoff>
#        prints  "<label>\t<reason>"  on stdout.
#
# Inputs are ISO date strings ("" when unknown) + repo_visibility in {private,public,unknown}.
# Dates are compared as ISO strings (lexicographic == chronological for well-formed ISO dates), so
# the labeler is pure, deterministic and stdlib-only (no date parsing, no timezone surprises).
import sys


def label(merged_at, repo_visibility, model_cutoff):
    """Return (cutoff_label, cutoff_reason). Deterministic; ISO string compare; stdlib only."""
    merged = (merged_at or "").strip()
    vis = (repo_visibility or "").strip().lower()
    cutoff = (model_cutoff or "").strip()

    # (1) Private code is not in public pretraining, regardless of dates.
    if vis == "private":
        return ("cutoff-clean", "private repo — not in public pretraining")

    # (2) Public/unknown but merged strictly AFTER the model cutoff => postdates pretraining.
    if cutoff and merged and merged > cutoff:
        return ("cutoff-clean", "merged {} after model cutoff {}".format(merged, cutoff))

    # (3) Otherwise unverified — pick the most specific reason.
    if cutoff and merged and merged <= cutoff:
        reason = "merged {} not after model cutoff {}".format(merged, cutoff)
    elif cutoff and not merged:
        reason = "merged_at unknown"
    elif not cutoff and vis == "public":
        reason = "public repo"
    else:
        reason = "no model_cutoff configured"
    return ("cutoff-unverified", reason)


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: cutoff_label.py <merged_at> <repo_visibility> <model_cutoff>\n")
        return 2
    lab, reason = label(argv[0], argv[1], argv[2])
    sys.stdout.write("{}\t{}\n".format(lab, reason))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
