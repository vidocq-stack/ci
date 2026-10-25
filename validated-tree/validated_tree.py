#!/usr/bin/env python3
"""Whether a pull request's code was already validated, so its build can be reused (Vidocq/ci#57).

  validated_tree.py id
      Prints the code-tree id of HEAD, run from the repository root.
  validated_tree.py check --event EVENT --attempt N --owner OWNER --repo REPO --branch HEAD_REF
                          [--api URL] [--token TOKEN]
      Prints `eligible=true|false` and `reason=...` lines (GITHUB_OUTPUT format): whether the run
      may reuse an earlier validation of the same code-tree id.

The code-tree id is a SHA-256 of HEAD's tree (mode, object id and path of every file) without
the documentation files, the same ones the docs-only change set of pr-validate accepts: *.md,
*.adoc, docs/, LICENSE, LICENSE.*, NOTICE, NOTICE.*, never under a src/ directory (it may be
packaged). Commits do not count, only content: a docs-only commit, a rebase on a main that moved
by documentation only, or the merge-bot's re-signing of an unchanged rebase keep the id. CI
configuration (.forgejo/) is code: a workflow change must run to exercise itself.

A run may reuse a validation only when nothing outside the tree can change the result:
  - a pull_request event (a push to main always builds);
  - the first attempt of the run: a re-run is how one asks for a real build;
  - no companion branch: no other repository of the organisation has a branch named like the
    pull request's head branch, as a consumer's companion branch can change while this tree
    does not. Any doubt (a forge error) counts as a companion.
"""
import fnmatch
import hashlib
import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

DOCS = ("*.md", "*.adoc", "docs/*", "LICENSE", "LICENSE.*", "NOTICE", "NOTICE.*")
ID_VERSION = "validated-tree/1"


def is_doc(path):
    if fnmatch.fnmatchcase(path, "src/*") or fnmatch.fnmatchcase(path, "*/src/*"):
        return False
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in DOCS)


def tree_id(ls_tree):
    """ls_tree: the output of `git ls-tree -r --full-tree HEAD` ("<mode> <type> <object>\\t<path>")."""
    digest = hashlib.sha256(ID_VERSION.encode() + b"\n")
    for line in ls_tree.splitlines():
        meta, _, path = line.partition("\t")
        if not path or is_doc(path):
            continue
        mode, _, obj = meta.split(" ")
        digest.update(("%s %s %s\n" % (mode, obj, path)).encode())
    return digest.hexdigest()


def companion_repos(get, owner, repo, branch):
    """The other repositories of `owner` with a branch named `branch`. `get(path)` returns
    (status, json) for a forge API path; an error raises."""
    names, page = [], 1
    while True:
        status, body = get("/orgs/%s/repos?limit=50&page=%d" % (owner, page))
        if status != 200:
            raise OSError("listing the repositories of %s: HTTP %s" % (owner, status))
        if not body:
            break
        names += [r["name"] for r in body]
        page += 1
    found = []
    for name in names:
        if name == repo:
            continue
        status, _ = get("/repos/%s/%s/branches/%s" % (owner, name, urllib.parse.quote(branch, safe="")))
        if status == 200:
            found.append("%s/%s" % (owner, name))
        elif status != 404:
            raise OSError("branch %s of %s/%s: HTTP %s" % (branch, owner, name, status))
    return found


def eligible(event, attempt, companions):
    if event != "pull_request":
        return False, "event %s: only pull requests reuse a validation" % event
    if attempt not in ("", "1"):
        return False, "re-run (attempt %s): a re-run always builds" % attempt
    if companions:
        return False, "companion branch in " + ", ".join(companions)
    return True, "no companion branch, first attempt"


def forge_get(api, token):
    def get(path):
        headers = {"Authorization": "token " + token} if token else {}
        req = urllib.request.Request(api.rstrip("/") + path, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, json.load(r)
        except urllib.error.HTTPError as e:
            return e.code, None
    return get


def main(argv):
    if argv[:1] == ["id"]:
        out = subprocess.run(["git", "ls-tree", "-r", "--full-tree", "HEAD"],
                             check=True, capture_output=True, text=True).stdout
        print(tree_id(out))
        return 0
    if argv[:1] == ["check"]:
        args = dict(zip(argv[1::2], argv[2::2]))
        try:
            companions = []
            if args.get("--event") == "pull_request" and args.get("--branch"):
                companions = companion_repos(forge_get(args.get("--api", "https://codefloe.com/api/v1"),
                                                       args.get("--token", "")),
                                             args["--owner"], args["--repo"], args["--branch"])
        except (OSError, ValueError, KeyError) as e:
            companions = ["unknown (%s)" % e]
        ok, why = eligible(args.get("--event", ""), args.get("--attempt", ""), companions)
        print("eligible=%s" % ("true" if ok else "false"))
        print("reason=%s" % why)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
