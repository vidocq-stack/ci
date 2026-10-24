#!/usr/bin/env python3
"""Tell whether the checks a branch requires are green on a commit.

Usage: required-checks.py BRANCH_JSON STATUS_JSON

BRANCH_JSON is the base branch (GET /repos/{repo}/branches/{branch}): its
"enable_status_check" and "status_check_contexts". STATUS_JSON is the commit's
combined status (GET /repos/{repo}/commits/{sha}/status).

Prints one line: "success", "pending: <what is missing>" or "failure: <context>",
and exits 0. Exits 2 when a file cannot be read.

The combined state covers every status of the commit, checks the branch does not
require included: waiting for it made /merge give up on a green pull request while
a SonarQube analysis, in report mode, was still running (Vidocq/ci#47). Only the
required contexts count here, matched as the forge matches them (glob patterns),
and with no context listed every status counts, as on the forge.
"""
import json
import sys
from fnmatch import fnmatchcase

FAILED = ("failure", "error")


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) else None


def verdict(branch, status):
    if not branch.get("enable_status_check", True):
        return "success"
    required = branch.get("status_check_contexts") or []
    if not required:
        state = status.get("state")
        if state == "success":
            return "success"
        return f"{'failure' if state in FAILED else 'pending'}: combined state is {state}"
    statuses = status.get("statuses") or []
    pending = []
    for pattern in required:
        hits = [s for s in statuses if fnmatchcase(s.get("context", ""), pattern)]
        failed = next((s.get("context") for s in hits if s.get("status") in FAILED), None)
        if failed:
            return f"failure: {failed}"
        if not hits or any(s.get("status") != "success" for s in hits):
            pending.append(pattern)
    return f"pending: {', '.join(pending)}" if pending else "success"


def main(argv):
    if len(argv) != 2:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    branch, status = load(argv[0]), load(argv[1])
    if branch is None or status is None:
        print("cannot read the branch or the commit status", file=sys.stderr)
        return 2
    print(verdict(branch, status))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
