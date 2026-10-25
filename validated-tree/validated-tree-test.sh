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

put core/src/main/java/A.java 'class A { int x; }'
commit "code"
check "a code change changes the id" "different" "$([ "$(id)" != "$base" ] && echo different || echo same)"

chmod +x "$REPO/core/src/main/java/A.java"
before_mode=$(id)
git -C "$REPO" config core.fileMode true
commit "mode"
check "a file mode change changes the id" "different" "$([ "$(id)" != "$before_mode" ] && echo different || echo same)"

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

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
