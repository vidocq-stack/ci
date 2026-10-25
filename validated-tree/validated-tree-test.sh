#!/usr/bin/env bash
# Tests of validated_tree.py.
# Run: bash validated-tree/validated-tree-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/validated_tree.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$expected', got '$actual'"
    failures=$((failures + 1))
  fi
}

REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" config user.email ci@example.org
git -C "$REPO" config user.name CI
git -C "$REPO" config commit.gpgsign false
put() { mkdir -p "$(dirname "$REPO/$1")"; printf '%s\n' "$2" > "$REPO/$1"; }
commit() { git -C "$REPO" add -A && git -C "$REPO" commit -q -m "$1"; }
id() { (cd "$REPO" && python3 "$SCRIPT" id); }

put pom.xml '<project/>'
put core/src/main/java/A.java 'class A {}'
put core/src/main/resources/notes.md 'packaged with the jar'
put README.md 'readme'
put docs/en/index.adoc '= Docs'
put .forgejo/workflows/pr.yml 'on: pull_request'
commit initial
base=$(id)

check "the id is a hex digest" "yes" "$(printf '%s' "$base" | grep -Eq '^[0-9a-f]{64}$' && echo yes || echo no)"

put README.md 'readme, reworded'
put BENCH.md 'figures'
put core/README.md 'module readme'
put docs/en/other.adoc '= More'
put docs/diagram.png 'not text'
put LICENSE 'license'
put NOTICE.md 'notice'
commit "docs only"
check "docs, licence and notice files leave the id unchanged" "$base" "$(id)"

git -C "$REPO" commit -q --amend -m "the same tree, another commit"
check "a commit with the same tree has the same id" "$base" "$(id)"

put core/src/main/resources/notes.md 'packaged with the jar, changed'
commit "a .md under src/"
check "a .md under src/ is code" "different" "$([ "$(id)" != "$base" ] && echo different || echo same)"
put core/src/main/resources/notes.md 'packaged with the jar'
commit "back"
check "back to the same code, back to the same id" "$base" "$(id)"

put .forgejo/workflows/pr.yml 'on: [pull_request]'
commit "workflow"
check "a workflow change changes the id" "different" "$([ "$(id)" != "$base" ] && echo different || echo same)"
put .forgejo/workflows/pr.yml 'on: pull_request'
commit "workflow back"

# Workflows a pull request cannot run (no pull_request / pull_request_target trigger, not called by one that
# has) are not code for the pull request: a change there proves nothing a build of the same code has not proved.
same_or_diff() { [ "$(id)" = "$1" ] && echo same || echo different; }
put .forgejo/workflows/ci.yml 'on:
  push:
    branches: [main]
jobs: {}'
commit "a main-only workflow"
wf_base=$(id)
check "adding a push-only workflow leaves the id unchanged" "$base" "$wf_base"
put .forgejo/workflows/ci.yml 'on:
  push:
    branches: [main]
jobs: {build: {runs-on: x}}'
commit "ci.yml changed"
check "changing a push-only workflow (block form) leaves the id unchanged" "same" "$(same_or_diff "$wf_base")"
put .forgejo/workflows/release.yml 'on: workflow_dispatch'
put .forgejo/workflows/sched.yml 'on: [schedule, push]'
commit "more inert workflows"
check "inline and list forms without a pull request trigger are inert" "same" "$(same_or_diff "$wf_base")"
put .forgejo/workflows/sonar.yml 'on:
  push:
  pull_request:
jobs: {}'
commit "a pull-request workflow"
check "a workflow with a pull_request trigger is code" "different" "$(same_or_diff "$wf_base")"
wf_base=$(id)
put .forgejo/workflows/both.yml 'on: [push, pull_request_target]'
commit "pull_request_target"
check "pull_request_target counts as a pull request trigger" "different" "$(same_or_diff "$wf_base")"
wf_base=$(id)
put .forgejo/workflows/reusable.yml 'on: workflow_call
jobs: {}'
put .forgejo/workflows/sonar.yml 'on:
  push:
  pull_request:
jobs:
  call:
    uses: ./.forgejo/workflows/reusable.yml'
commit "a reusable workflow called by a pull-request workflow"
wf_base=$(id)
put .forgejo/workflows/reusable.yml 'on: workflow_call
jobs: {x: {runs-on: y}}'
commit "the called workflow changes"
check "a workflow called by a pull-request workflow is code" "different" "$(same_or_diff "$wf_base")"
wf_base=$(id)
put .forgejo/workflows/odd.yml 'name: no trigger key here'
commit "a workflow whose triggers cannot be read"
check "a workflow whose triggers cannot be read is code" "different" "$(same_or_diff "$wf_base")"
wf_base=$(id)
put .forgejo/workflows/ci.yml 'on:
  pull_request:
jobs: {}'
commit "ci.yml now runs on pull requests"
check "a push-only workflow that gains a pull request trigger is code" "different" "$(same_or_diff "$wf_base")"
wf_base=$(id)
put .forgejo/workflows/after.yml 'on:
  workflow_run:
    workflows: [pr-validate]
jobs: {}'
commit "a workflow_run workflow"
wf_base=$(id)
put .forgejo/workflows/after.yml 'on:
  workflow_run:
    workflows: [pr-validate]
jobs: {x: {runs-on: y}}'
commit "the workflow_run workflow changes"
check "a workflow_run workflow (runs because of a pull request) is code" "different" "$(same_or_diff "$wf_base")"
wf_base=$(id)
put .forgejo/actions/local/action.yml 'runs: {using: composite}'
commit "a local action"
check "other .forgejo files stay code" "different" "$(same_or_diff "$wf_base")"

put core/src/main/java/A.java 'class A { int x; }'
commit "code"
check "a code change changes the id" "different" "$([ "$(id)" != "$base" ] && echo different || echo same)"

chmod +x "$REPO/core/src/main/java/A.java"
before_mode=$(id)
git -C "$REPO" config core.fileMode true
commit "mode"
check "a file mode change changes the id" "different" "$([ "$(id)" != "$before_mode" ] && echo different || echo same)"

# The id of another revision: a docs-only pull request has the code tree of its merge base.
docs_base=$(git -C "$REPO" rev-parse HEAD)
put docs/en/new.adoc '= New page'
commit "docs on top"
check "id of a revision" "$(id)" "$(cd "$REPO" && python3 "$SCRIPT" id --rev "$docs_base")"
put core/src/main/java/B.java 'class B {}'
commit "code on top"
check "a code commit differs from the revision before it" "different" \
  "$([ "$(id)" != "$(cd "$REPO" && python3 "$SCRIPT" id --rev "$docs_base")" ] && echo different || echo same)"

# Companion branches: a branch named like the pull request's head branch in another repository of the
# organisation. The forge is a dict of path -> (status, JSON) pairs.
companions() {
  python3 - "$SCRIPT" "$@" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("validated_tree", sys.argv[1])
vt = importlib.util.module_from_spec(spec); spec.loader.exec_module(vt)
pages = {
    "/orgs/Vidocq/repos?limit=50&page=1": (200, [{"name": "vidocq"}, {"name": "vauban"}, {"name": "foy"}]),
    "/orgs/Vidocq/repos?limit=50&page=2": (200, []),
    "/repos/Vidocq/vauban/branches/feat%2Fshared": (200, {"name": "feat/shared"}),
}
broken = sys.argv[3] == "broken"
def get(path):
    if broken and "/branches/" in path:
        raise OSError("forge down")
    return pages.get(path, (404, None))
try:
    print(",".join(vt.companion_repos(get, "Vidocq", "vidocq", sys.argv[2])) or "none")
except OSError:
    print("error")
PY
}
check "a branch of the same name elsewhere is a companion" "Vidocq/vauban" "$(companions feat/shared ok)"
check "no other repository has the branch" "none" "$(companions feat/alone ok)"
check "a forge error is reported, not taken as no companion" "error" "$(companions feat/shared broken)"

# Whether a run may reuse an earlier validation.
eligible() {
  python3 - "$SCRIPT" "$@" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("validated_tree", sys.argv[1])
vt = importlib.util.module_from_spec(spec); spec.loader.exec_module(vt)
ok, why = vt.eligible(event=sys.argv[2], attempt=sys.argv[3], companions=sys.argv[4].split(",") if sys.argv[4] else [])
print("yes" if ok else "no: " + why)
PY
}
check "a first attempt of a pull request may reuse" "yes" "$(eligible pull_request 1 '')"
check "an unknown attempt counts as the first" "yes" "$(eligible pull_request '' '')"
check "a re-run builds" "no: re-run (attempt 2): a re-run always builds" "$(eligible pull_request 2 '')"
check "a push builds" "no: event push: only pull requests reuse a validation" "$(eligible push 1 '')"
check "a companion branch builds" "no: companion branch in Vidocq/vauban" "$(eligible pull_request 1 'Vidocq/vauban')"

# Records are refs of the repository itself (refs/validated/<scope>/<id>[-<suffix>]), shared by every runner. A bare
# repository stands for the forge.
FORGE="$TMP/forge.git"
git init -q --bare "$FORGE"
vt() { (cd "$TMP" && python3 "$SCRIPT" "$@"); }
check "a ref name per scope and id" "refs/validated/pr-validate/abc" "$(vt ref --scope pr-validate --tree-id abc)"
check "a suffix is made safe for a ref name" "refs/validated/sonar-pr7/abc-2026-10-25T14-57-29-0000" \
  "$(vt ref --scope sonar-pr7 --tree-id abc --suffix '2026-10-25T14:57:29+0000')"
check "nothing recorded, nothing found" "found=false" "$(vt lookup --remote "$FORGE" --ref refs/validated/pr-validate/abc | head -1)"
vt record --remote "$FORGE" --ref refs/validated/pr-validate/abc --commit 1111111 --run run-1 --note 'analysis=x' >/dev/null
found=$(vt lookup --remote "$FORGE" --ref refs/validated/pr-validate/abc)
check "a record is found" "found=true" "$(printf '%s\n' "$found" | head -1)"
check "the record gives the commit" "recorded-commit=1111111" "$(printf '%s\n' "$found" | grep '^recorded-commit=')"
check "the record gives the note" "recorded-note=analysis=x" "$(printf '%s\n' "$found" | grep '^recorded-note=')"
vt record --remote "$FORGE" --ref refs/validated/pr-validate/abc --commit 2222222 --run run-2 --note '' >/dev/null
check "a later record of the same ref replaces it" "recorded-commit=2222222" \
  "$(vt lookup --remote "$FORGE" --ref refs/validated/pr-validate/abc | grep '^recorded-commit=')"
check "another scope is not found" "found=false" "$(vt lookup --remote "$FORGE" --ref refs/validated/sonar-pr7/abc | head -1)"
check "an unreachable forge is not a record" "found=false" "$(vt lookup --remote "$TMP/nowhere.git" --ref refs/validated/pr-validate/abc 2>/dev/null | head -1)"
check "the record holds no file" "0" "$(git --git-dir="$FORGE" ls-tree -r refs/validated/pr-validate/abc | wc -l | tr -d ' ')"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
