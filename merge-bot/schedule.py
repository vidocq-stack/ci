#!/usr/bin/env python3
"""Hand a pull request's fast-forward merge to the forge instead of waiting for its checks in the job.

Usage: schedule.py --api URL --token T --repo OWNER/NAME --pr N --head SHA --branch BASE [--retry-pause S]

The merge-bot used to poll the required checks for up to an hour, one runner held per /merge. Seventeen
/merge comments at once held 14 of the organisation's 20 slots and starved the very checks they waited for
(2026-10-25). Now, once the head is rebased, re-signed and pushed:

  - the base branch requires no status check, or the required checks are already green on the head:
    fast-forward now (Do: fast-forward-only, head_commit_id). A schedule would wait for a status change
    that never comes when everything is already green (seen on Codefloe);
  - a required check failed: refuse, nothing scheduled;
  - otherwise, ONLY when the base branch's .forgejo/workflows/pr.yml runs pr-validate-gate in mode state
    (the job that cancels a stale schedule), schedule Forgejo's "merge when checks succeed"
    (merge_when_checks_succeed) and exit. Without that job (ci, GestionProjet, a producer before the
    template rollout), nothing would cancel the schedule on a push or a WIP label: refuse, "checks still
    running; re-run /merge when pr-validate is green" (review 81-I1). If the checks turn green between the
    read and the schedule, the schedule is replaced by a direct merge; if the head moved, it is cancelled
    and refused (81-I2).

--gate only prints "gate=true" or "gate=false".

Forgejo's scheduled merge does NOT pin the head (head_commit_id only applies to an immediate merge): the
pr-validate gate cancels a schedule on a push that the merge-bot did not announce, and on a pull request
that becomes WIP, blocked or a train member.

Prints "result=merged" or "result=scheduled" and exits 0, or explains the refusal and exits 1.
"""
import argparse
import base64
import importlib.util
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("required_checks", os.path.join(HERE, "required-checks.py"))
required_checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(required_checks)


class Refused(Exception):
    pass


class Forge:
    def __init__(self, api, token, repo):
        self.base = f"{api.rstrip('/')}/repos/{repo}"
        self.token = token

    def call(self, method, path, payload=None):
        data = json.dumps(payload).encode() if payload is not None else None
        headers = {"Accept": "application/json", "Authorization": "token " + self.token}
        if data is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                status, body = resp.status, resp.read().decode()
        except urllib.error.HTTPError as err:
            status, body = err.code, err.read().decode(errors="replace")
        except (urllib.error.URLError, OSError) as err:
            raise Refused(f"{method} {path}: {err}")
        try:
            doc = json.loads(body) if body.strip() else {}
        except ValueError:
            doc = {"raw": body[:200]}
        return status, doc

    def get(self, path):
        status, doc = self.call("GET", path)
        if status != 200 or not isinstance(doc, dict):
            raise Refused(f"GET {path}: HTTP {status}")
        return doc


def gate_present(forge, branch):
    """Does the base branch's pr.yml run pr-validate-gate with mode: state? Any doubt answers no."""
    status, doc = forge.call("GET", f"/contents/.forgejo/workflows/pr.yml?ref={branch}")
    if status != 200 or not isinstance(doc, dict) or doc.get("encoding") != "base64":
        return False
    try:
        text = base64.b64decode(doc.get("content") or "").decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return False
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if "pr-validate-gate@" not in line or "uses:" not in line:
            continue
        indent = len(line) - len(line.lstrip(" "))
        for nxt in lines[i + 1:]:
            if not nxt.strip() or nxt.lstrip().startswith("#"):
                continue
            nind = len(nxt) - len(nxt.lstrip(" "))
            if nind < indent or (nind == indent and nxt.lstrip().startswith("- ")):
                break
            key, _, value = nxt.strip().partition(":")
            if key == "mode" and value.strip().strip("'\"") == "state":
                return True
    return False


def merge_now(forge, pr, head, pause):
    body = {"Do": "fast-forward-only", "head_commit_id": head, "delete_branch_after_merge": True}
    for _ in range(3):
        status, doc = forge.call("POST", f"/pulls/{pr}/merge", body)
        if status in (200, 201, 204):
            return
        if status != 405:
            break
        time.sleep(pause)   # the forge may still be settling the statuses
    raise Refused(f"the fast-forward of {head[:10]} was refused: HTTP {status} {json.dumps(doc)[:200]}")


def run(a):
    forge = Forge(a.api, a.token, a.repo)
    branch = forge.get(f"/branches/{a.branch}")
    verdict = "success"
    if branch.get("enable_status_check", True):
        verdict = required_checks.verdict(branch, forge.get(f"/commits/{a.head}/status"))
    if verdict.startswith("failure"):
        raise Refused(f"a required check failed on {a.head[:10]} ({verdict}): fix it, then /merge again")
    if verdict == "success":
        merge_now(forge, a.pr, a.head, a.retry_pause)
        return "merged"
    if not gate_present(forge, a.branch):
        raise Refused("checks still running; re-run /merge when pr-validate is green")

    status, doc = forge.call("POST", f"/pulls/{a.pr}/merge", {
        "Do": "fast-forward-only", "head_commit_id": a.head, "delete_branch_after_merge": True,
        "merge_when_checks_succeed": True})
    if status == 409:
        raise Refused("a merge is already scheduled for this pull request and could not be replaced")
    if status == 200:
        return "merged"
    if status != 201:
        raise Refused(f"the forge refused to schedule the merge: HTTP {status} {json.dumps(doc)[:200]}")

    # A push that landed between the bot's push and the schedule ran its pr-state before the schedule existed:
    # nothing would cancel it later.
    now = (forge.get(f"/pulls/{a.pr}").get("head") or {}).get("sha")
    if now != a.head:
        forge.call("DELETE", f"/pulls/{a.pr}/merge")
        raise Refused(f"the head moved to {str(now)[:10]} right after scheduling the merge of {a.head[:10]}: "
                      "schedule cancelled; re-run /merge")
    # Green in the meantime: the schedule would wait for a status change that may never come.
    if required_checks.verdict(branch, forge.get(f"/commits/{a.head}/status")) == "success":
        if forge.get(f"/pulls/{a.pr}").get("merged"):
            return "merged"
        forge.call("DELETE", f"/pulls/{a.pr}/merge")
        merge_now(forge, a.pr, a.head, a.retry_pause)
        return "merged"
    return "scheduled"


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    for name in ("--api", "--token", "--repo", "--pr", "--head", "--branch"):
        p.add_argument(name, required=True)
    p.add_argument("--retry-pause", type=float, default=3.0)
    p.add_argument("--gate", action="store_true", help="only print whether the base branch runs the gate")
    a = p.parse_args(argv)
    if a.gate:
        try:
            present = gate_present(Forge(a.api, a.token, a.repo), a.branch)
        except Refused:
            present = False
        print(f"gate={str(present).lower()}")
        return 0
    try:
        result = run(a)
    except Refused as err:
        print(f"refused: {err}")
        return 1
    print(f"result={result}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
