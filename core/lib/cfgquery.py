#!/usr/bin/env python3
# cfgquery.py <op> [args] — read the project config at $PROJECT_CONFIG (a PROJECT.yaml,
# see core/schema/PROJECT.schema.yaml). The module-agnostic core reads every value through here so
# there is ONE place that knows the config shape and ONE dependency (PyYAML).
# ops:
#   get <dotted.key>            -> one scalar (nothing if absent or non-scalar)
#   list <dotted.key>           -> newline list of scalar items
#   repos                       -> each repos[].name, one per line
#   repofield <name> <field>    -> repos[i].<field> where repos[i].name == name; <field> may be dotted
#                                  (e.g. "verify.build_cmd") to reach the per-repo verify block
#   tokens <unit>               -> decontamination.answer_tokens[<unit>] items, one per line
#   interp <string>             -> replace {{project.id}} {{run_id}}(=$RUN_ID) {{key}}(=$KEY) and the
#                                  shell-style ${TMPDIR:-/tmp} / ${TMPDIR} used by the sandbox_root default
# Pure PyYAML + stdlib. No vendor hostnames, keys, or credentials live here — everything comes from
# the config file, which is the only place project-specific values may appear.
import os, re, sys, yaml

PC = os.environ.get("PROJECT_CONFIG")
if not PC or not os.path.isfile(PC):
    sys.stderr.write("cfgquery: PROJECT_CONFIG unset or missing: %r\n" % PC)
    sys.exit(2)
D = yaml.safe_load(open(PC)) or {}


def dig(dotted, root=None):
    cur = D if root is None else root
    for k in dotted.split("."):
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return None
    return cur


def scalar(v):
    # print bools lowercase so bash can test [ "$x" = "true" ]
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


def _tmpdir():
    # resolve ONLY $TMPDIR here (the single variable the schema's sandbox_root default uses); we never
    # eval arbitrary shell out of the config. Falls back to /tmp — the OS-portable default (NOT a
    # macOS-specific /private/tmp).
    t = (os.environ.get("TMPDIR") or "/tmp").rstrip("/")
    return t or "/tmp"


def main(argv):
    if not argv:
        sys.exit("cfgquery: need an op")
    op = argv[0]
    if op == "get":
        v = dig(argv[1])
        if v is not None and not isinstance(v, (dict, list)):
            print(scalar(v))
    elif op == "list":
        v = dig(argv[1]) or []
        if isinstance(v, list):
            for it in v:
                if not isinstance(it, (dict, list)):
                    print(scalar(it))
    elif op == "repos":
        for r in (D.get("repos") or []):
            print(r.get("name", ""))
    elif op == "repofield":
        name, field = argv[1], argv[2]
        for r in (D.get("repos") or []):
            if r.get("name") == name:
                v = dig(field, root=r)   # dotted so callers can read "verify.build_cmd" etc.
                if v is not None and not isinstance(v, (dict, list)):
                    print(scalar(v))
                break
    elif op == "tokens":
        at = (D.get("decontamination") or {}).get("answer_tokens") or {}
        for t in (at.get(argv[1]) or []):
            print(t)
    elif op == "interp":
        s = argv[1]
        reps = {
            "{{project.id}}": str((D.get("project") or {}).get("id", "")),
            "{{run_id}}": os.environ.get("RUN_ID", ""),
            "{{key}}": os.environ.get("KEY", ""),
        }
        for k, v in reps.items():
            s = s.replace(k, v)
        # shell-style ${TMPDIR:-/tmp} / ${TMPDIR} / $TMPDIR — the schema's portable sandbox_root default
        s = re.sub(r"\$\{TMPDIR:-[^}]*\}", _tmpdir(), s)
        s = re.sub(r"\$\{TMPDIR\}", _tmpdir(), s)
        s = s.replace("$TMPDIR", _tmpdir())
        print(s)
    else:
        sys.exit("cfgquery: unknown op %r" % op)


if __name__ == "__main__":
    main(sys.argv[1:])
