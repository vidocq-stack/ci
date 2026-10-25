#!/usr/bin/env python3
"""Land a PR train: its members are validated through the train's top pull request (Vidocq/vidocq#285).

A train is a chain of pull requests on one repository, each one's head a descendant of the previous one's.
Validating every member costs a full producer + downstream run each; the top's run already validates the
code of all of them. So the members carry the label train-member and a line "Train-top: #N" in their
description, and their pr-validate check FAILS on purpose (pr-validate-gate): none of them can be merged on
its own, by hand or by the merge-bot. This script lands the whole train at once.

  train-merge.py mark   <owner/repo> <top> <member>...  label the members and name the top in their description
  train-merge.py unmark <owner/repo> <member>...        make them standalone pull requests again (full validation)
  train-merge.py check  <owner/repo> <top> <member>...  every verification below, and nothing else
  train-merge.py merge  <owner/repo> <top> <member>... [--yes]
                                                        the same verifications, then (only with --yes)
                                                        fast-forwards the base branch to the top's head and
                                                        marks each member merged

Members are listed in merge order, bottom first. The merge refuses on any doubt:
  - every pull request is open, from the repository itself (no fork), on the same base branch;
  - the top is ready (not WIP, not blocked, not itself a member) and its required checks, and its
    pr-validate check by name, are green on its exact head commit;
  - every member is labelled train-member with "Train-top: #<top>", and is neither WIP nor blocked;
  - with git, from the repository: the heads the API reports are the heads fetched, the base branch is an
    ancestor of the top (fast-forward possible), each member's head is an ancestor of the next one and of the
    top, and no member is already in the base branch.
Then it fast-forwards through the API (Do: fast-forward-only, head_commit_id = the top's head), checks that
the base branch now points at that head, and for each member: merged already (the forge's manual-merge
autodetection), else marked "manually merged" by its own head commit, else, when the repository does not
allow that mark, a comment and a close.

Environment: CODEFLOE_BOT_TOKEN (or FORGE_TOKEN), FORGE_URL (default https://codefloe.com). --remote
overrides the git remote (default <FORGE_URL>/<owner/repo>.git, read anonymously). Needs git and python3.
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
TRAIN_LABEL = "train-member"
VALIDATE_CONTEXT = "pr-validate / pr-validate (pull_request)"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate = load("gate", os.path.join(HERE, "..", "pr-validate-gate", "gate.py"))
required_checks = load("required_checks", os.path.join(HERE, "..", "merge-bot", "required-checks.py"))


class Refused(Exception):
    pass


class Forge:
    def __init__(self, url, token, repo):
        self.api = url.rstrip("/") + "/api/v1"
        self.token = token
        self.repo = repo

    def call(self, method, path, payload=None, ok=(200, 201, 204), root=False):
        data = json.dumps(payload).encode() if payload is not None else None
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = "token " + self.token
        if data is not None:
            headers["Content-Type"] = "application/json"
        url = self.api + path if root else f"{self.api}/repos/{self.repo}{path}"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
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
            doc = {"raw": body[:300]}
        if status not in ok:
            raise Refused(f"{method} {path}: HTTP {status} {json.dumps(doc)[:300]}")
        return status, doc

    def get(self, path):
        return self.call("GET", path)[1]


def git(*args, cwd):
    proc = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def classify(pr):
    return gate.classify(pr, gate.DEFAULT_WIP_LABELS, TRAIN_LABEL)


# ------------------------------------------------------------------------------------------------ check

def verify(forge, top_n, members, remote, say, context=VALIDATE_CONTEXT):
    """Every verification; returns the plan (dict) or raises Refused."""
    if not members:
        raise Refused("a train has at least one member besides its top")
    numbers = [top_n, *members]
    if len(set(numbers)) != len(numbers):
        raise Refused("a pull request appears twice")
    prs = {n: forge.get(f"/pulls/{n}") for n in numbers}

    base = prs[top_n].get("base", {}).get("ref")
    for n, pr in prs.items():
        if pr.get("state") != "open" or pr.get("merged"):
            raise Refused(f"#{n} is not open (state {pr.get('state')}, merged {pr.get('merged')})")
        if (pr.get("head", {}).get("repo") or {}).get("full_name") != forge.repo:
            raise Refused(f"#{n} comes from a fork: a train lands from the repository's own branches")
        if pr.get("base", {}).get("ref") != base:
            raise Refused(f"#{n} targets {pr.get('base', {}).get('ref')}, the top targets {base}")

    top = classify(prs[top_n])
    if top["mode"] != "ready" or top["blocked"]:
        why = top["wip-reason"] or ("it is itself a train member" if top["train"] else "label blocked")
        raise Refused(f"the top #{top_n} is not ready: {why}")
    for n in members:
        c = classify(prs[n])
        if not c["train"]:
            raise Refused(f"#{n} is not labelled {TRAIN_LABEL}: run 'mark' first")
        if c["train-top"] != str(top_n):
            raise Refused(f"#{n} names the top #{c['train-top'] or '?'}, not #{top_n}: run 'mark' again")
        if c["wip"] or c["blocked"]:
            raise Refused(f"#{n} is {'WIP (' + c['wip-reason'] + ')' if c['wip'] else 'blocked'}: never merged")

    heads = {n: prs[n]["head"]["sha"] for n in numbers}
    top_head = heads[top_n]
    branch = forge.get(f"/branches/{base}")
    status = forge.get(f"/commits/{top_head}/status")
    verdict = required_checks.verdict(branch, status)
    if verdict != "success":
        raise Refused(f"the top's required checks are not green on {top_head[:10]}: {verdict}")
    if context:
        own = [s for s in status.get("statuses") or [] if s.get("context") == context]
        if not own or own[0].get("status") != "success":
            raise Refused(f"the top's '{context}' is not success on {top_head[:10]}: "
                          f"{own[0].get('status') if own else 'not reported'}")
    say(f"top #{top_n}: ready, required checks{' and ' + repr(context) if context else ''} green on {top_head[:10]}")

    with tempfile.TemporaryDirectory() as tmp:
        git("init", "-q", "--bare", tmp, cwd=tmp)
        specs = [f"+refs/heads/{base}:refs/train/base"] + [f"+refs/pull/{n}/head:refs/train/{n}" for n in numbers]
        rc, _, err = git("fetch", "-q", "--no-tags", "--filter=blob:none", remote, *specs, cwd=tmp)
        if rc != 0:
            rc, _, err = git("fetch", "-q", "--no-tags", remote, *specs, cwd=tmp)
        if rc != 0:
            raise Refused(f"cannot fetch the train from {remote}: {err[-300:]}")
        base_sha = git("rev-parse", "refs/train/base", cwd=tmp)[1]
        if base_sha != branch.get("commit", {}).get("id", base_sha):
            raise Refused(f"{base} moved while checking ({base_sha[:10]} fetched)")
        for n in numbers:
            fetched = git("rev-parse", f"refs/train/{n}", cwd=tmp)[1]
            if fetched != heads[n]:
                raise Refused(f"#{n}: the API says head {heads[n][:10]}, the repository {fetched[:10]}: it moved")

        def ancestor(a, b):
            return git("merge-base", "--is-ancestor", a, b, cwd=tmp)[0] == 0

        if not ancestor(base_sha, top_head):
            raise Refused(f"{base} ({base_sha[:10]}) is not an ancestor of the top's head: rebase the train first")
        chain = [*members, top_n]
        for lower, upper in zip(chain, chain[1:]):
            if not ancestor(heads[lower], heads[upper]):
                raise Refused(f"#{lower}'s head {heads[lower][:10]} is not an ancestor of #{upper}'s head "
                              f"{heads[upper][:10]}: not a train in this order")
        for n in members:
            if ancestor(heads[n], base_sha):
                raise Refused(f"#{n} is already in {base}: leave it out of the train")
        commits = git("rev-list", "--count", f"{base_sha}..{top_head}", cwd=tmp)[1]
    say(f"train: {' -> '.join('#' + str(n) for n in chain)}, {commits} commit(s) on top of {base} {base_sha[:10]}")
    return {"base": base, "base-sha": base_sha, "heads": heads, "top": top_n, "members": members}


# ------------------------------------------------------------------------------------------------ merge

def land(forge, plan, say, settle=5.0):
    top, base, heads = plan["top"], plan["base"], plan["heads"]
    top_head = heads[top]
    pr = forge.get(f"/pulls/{top}")
    if pr["head"]["sha"] != top_head:
        raise Refused(f"the top #{top} moved to {pr['head']['sha'][:10]}: nothing merged")
    forge.call("POST", f"/pulls/{top}/merge",
               {"Do": "fast-forward-only", "head_commit_id": top_head, "delete_branch_after_merge": True})
    now = forge.get(f"/branches/{base}").get("commit", {}).get("id")
    if now != top_head:
        raise Refused(f"#{top} merge answered, but {base} is at {str(now)[:10]}, not {top_head[:10]}: "
                      "members left untouched, look at the repository")
    say(f"#{top} fast-forwarded: {base} {plan['base-sha'][:10]} -> {top_head[:10]}")

    problems = []
    if settle:
        time.sleep(settle)   # the forge's manual-merge autodetection runs after the push
    for n in plan["members"]:
        head = heads[n]
        if forge.get(f"/pulls/{n}").get("merged"):
            say(f"#{n}: marked merged by the forge (head {head[:10]} is in {base})")
            continue
        status, doc = forge.call("POST", f"/pulls/{n}/merge", {"Do": "manually-merged", "MergeCommitID": head},
                                 ok=(200, 201, 204, 403, 405, 409, 422))
        if status in (200, 201, 204) and forge.get(f"/pulls/{n}").get("merged"):
            say(f"#{n}: marked manually merged by {head[:10]}")
            continue
        note = (f"Landed in `{base}` with the PR train topped by #{top}: this pull request's head `{head[:10]}` "
                f"is part of `{base}` at `{top_head[:10]}`. Closed as merged: the repository does not allow "
                f"the \"manually merged\" mark (HTTP {status}).")
        try:
            forge.call("POST", f"/issues/{n}/comments", {"body": note})
            forge.call("PATCH", f"/pulls/{n}", {"state": "closed"})
            say(f"#{n}: the manual-merge mark was refused (HTTP {status}); commented and closed")
        except Refused as err:
            problems.append(f"#{n}: {err}")
    names = ", ".join(f"#{n}" for n in plan["members"])
    try:
        forge.call("POST", f"/issues/{top}/comments",
                   {"body": f"PR train landed: `{base}` fast-forwarded to `{top_head[:10]}`, with {names}."})
    except Refused as err:
        problems.append(f"#{top} comment: {err}")
    if problems:
        raise Refused("the train landed, but: " + "; ".join(problems))


# ------------------------------------------------------------------------------------------- mark/unmark

def with_top(body, top):
    body = body or ""
    if top is None:
        return gate.TRAIN_TOP.sub("", body).rstrip() + "\n"
    if gate.TRAIN_TOP.search(body):
        return gate.TRAIN_TOP.sub(f"Train-top: #{top}", body, count=1)
    return body.rstrip() + f"\n\nTrain-top: #{top}\n"


def mark(forge, top_n, members, say):
    labels = forge.get("/labels?limit=100")
    owner = forge.repo.split("/")[0]
    try:
        _, org = forge.call("GET", f"/orgs/{owner}/labels?limit=100", root=True)
    except Refused:
        org = []
    known = [label for label in (labels if isinstance(labels, list) else []) + (org if isinstance(org, list) else [])
             if label.get("name") == TRAIN_LABEL]
    if not known:
        raise Refused(f"no label {TRAIN_LABEL} on the repository or its organisation: create it first")
    for n in members:
        pr = forge.get(f"/pulls/{n}")
        forge.call("PATCH", f"/pulls/{n}", {"body": with_top(pr.get("body"), top_n)})
        forge.call("POST", f"/issues/{n}/labels", {"labels": [known[0]["id"]]})
        say(f"#{n}: labelled {TRAIN_LABEL}, Train-top: #{top_n}")


def unmark(forge, members, say):
    for n in members:
        pr = forge.get(f"/pulls/{n}")
        # By name: Forgejo 16 answers 422 when an organisation label is removed by its id.
        forge.call("DELETE", f"/issues/{n}/labels/{TRAIN_LABEL}", ok=(200, 204, 404))
        forge.call("PATCH", f"/pulls/{n}", {"body": with_top(pr.get("body"), None)})
        say(f"#{n}: no longer a train member (it validates in full)")


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("command", choices=("mark", "unmark", "check", "merge"))
    p.add_argument("repo")
    p.add_argument("prs", nargs="+", type=int)
    p.add_argument("--yes", action="store_true", help="merge: really merge (otherwise a dry run)")
    p.add_argument("--remote", default="")
    p.add_argument("--context", default=VALIDATE_CONTEXT,
                   help="a status the top must have green by name, on top of the required checks; '' for a "
                        "repository without pr-validate (ci, GestionProjet)")
    p.add_argument("--settle", type=float, default=5.0, help=argparse.SUPPRESS)
    a = p.parse_args(argv)
    url = os.environ.get("FORGE_URL", "https://codefloe.com")
    token = os.environ.get("FORGE_TOKEN") or os.environ.get("CODEFLOE_BOT_TOKEN", "")
    forge = Forge(url, token, a.repo)
    say = lambda line: print(line, flush=True)
    try:
        if a.command == "unmark":
            unmark(forge, a.prs, say)
            return 0
        top, members = a.prs[0], a.prs[1:]
        if a.command == "mark":
            mark(forge, top, members, say)
            return 0
        plan = verify(forge, top, members, a.remote or f"{url.rstrip('/')}/{a.repo}.git", say, a.context)
        if a.command == "check" or not a.yes:
            say("OK: the train can land" + ("" if a.command == "check" else "; nothing merged without --yes"))
            return 0
        land(forge, plan, say, settle=a.settle)
        say("TRAIN LANDED")
        return 0
    except Refused as err:
        print(f"REFUSED: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
