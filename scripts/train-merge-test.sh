#!/usr/bin/env bash
# Tests of train-merge.py: a local stub of the Forgejo API and a local bare repository (no network).
# Run: bash scripts/train-merge-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/train-merge.py"
TMP="$(mktemp -d)"

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
contains() {
  case "$3" in
    *"$2"*) echo "ok   $1" ;;
    *) echo "FAIL $1: '$2' not in: $3"; failures=$((failures + 1)) ;;
  esac
}

# The repository: main <- #11 <- #12 <- top #13, and #20 on a side branch. Pull request heads are
# refs/pull/<n>/head, as on the forge.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q -b main "$TMP/work"
commit() { echo "$1" > "$TMP/work/$1"; git -C "$TMP/work" add "$1"; git -C "$TMP/work" -c commit.gpgsign=false commit -q -m "$1"; git -C "$TMP/work" rev-parse HEAD; }
MAIN=$(commit base)
H11=$(commit one)
H12=$(commit two)
H13=$(commit three)
git -C "$TMP/work" checkout -q -b side "$MAIN"
H20=$(commit side)
git init -q --bare "$TMP/remote.git"
git -C "$TMP/work" push -q "$TMP/remote.git" "$MAIN:refs/heads/main" "$H11:refs/pull/11/head" "$H12:refs/pull/12/head" \
  "$H13:refs/pull/13/head" "$H20:refs/pull/20/head"

echo '{}' > "$TMP/routes.json"
python3 "$HERE/../pr-validate-gate/stub_forge.py" "$TMP/routes.json" "$TMP/calls.log" > "$TMP/port" &
STUB=$!
trap 'kill $STUB 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/port" ] && break; sleep 0.2; done

# forge.py <routes> <command> ...: reset (a healthy train), pr <n> <key>=<json value>..., status <context>=<state>...,
# merged-after (main moves to the top and #11 is autodetected as merged after the top's merge)
cat > "$TMP/forge.py" <<'EOF'
import json, sys
path, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
heads = dict(a.split("=") for a in open(path + ".heads").read().split())
R = "/api/v1/repos/Vidocq/demo"
routes = json.load(open(path)) if cmd != "reset" else {}
def pr(n, title="feat", labels=(), body=""):
    return {"number": int(n), "title": title, "body": body, "state": "open", "merged": False,
            "labels": [{"name": l} for l in labels], "base": {"ref": "main"},
            "head": {"sha": heads[n], "ref": f"b{n}", "repo": {"full_name": "Vidocq/demo"}}}
GOV, VAL = "pr-validate / governance-checks (pull_request)", "pr-validate / pr-validate (pull_request)"
if cmd == "reset":
    for n in ("11", "12"):
        routes[f"{R}/pulls/{n}"] = pr(n, labels=["train-member"], body="Part of a train.\n\nTrain-top: #13\n")
    routes[f"{R}/pulls/13"] = pr("13")
    routes[f"{R}/pulls/20"] = pr("20", labels=["train-member"], body="Train-top: #13")
    routes[f"{R}/branches/main"] = {"name": "main", "commit": {"id": heads["main"]}, "enable_status_check": True,
                                    "status_check_contexts": [GOV, VAL]}
    routes[f"{R}/commits/{heads['13']}/status"] = {"state": "success", "statuses": [
        {"context": GOV, "status": "success"}, {"context": VAL, "status": "success"}]}
    routes[f"{R}/labels"] = []
    routes["/api/v1/orgs/Vidocq/labels"] = [{"id": 77, "name": "train-member"}, {"id": 5, "name": "WIP"}]
elif cmd == "pr":
    n = args[0]
    for kv in args[1:]:
        k, v = kv.split("=", 1)
        routes[f"{R}/pulls/{n}"][k] = json.loads(v)
elif cmd == "status":
    routes[f"{R}/commits/{heads['13']}/status"]["statuses"] = [
        {"context": c, "status": s} for c, s in (a.split("=", 1) for a in args)]
elif cmd == "merged-after":
    merged11 = dict(routes[f"{R}/pulls/11"], merged=True, state="closed")
    routes[f"_on POST {R}/pulls/13/merge"] = {
        f"{R}/branches/main": dict(routes[f"{R}/branches/main"], commit={"id": heads["13"]}),
        f"{R}/pulls/11": merged11}
    routes[f"_on POST {R}/pulls/12/merge"] = {f"{R}/pulls/12": dict(routes[f"{R}/pulls/12"], merged=True)}
elif cmd == "raw":
    routes[args[0]] = json.loads(args[1])
json.dump(routes, open(path, "w"))
EOF
printf 'main=%s 11=%s 12=%s 13=%s 20=%s\n' "$MAIN" "$H11" "$H12" "$H13" "$H20" > "$TMP/routes.json.heads"
forge() { python3 "$TMP/forge.py" "$TMP/routes.json" "$@"; }

train() { # train <args...> -> "<exit status>" ; output in $TMP/out
  : > "$TMP/calls.log"
  FORGE_URL="http://127.0.0.1:$(cat "$TMP/port")" FORGE_TOKEN=t python3 "$SCRIPT" "$@" --remote "$TMP/remote.git" \
    --settle 0 > "$TMP/out" 2>&1
  echo $?
}
writes() { grep -vE '^GET ' "$TMP/calls.log" | sed -E 's#/api/v1/repos/Vidocq/demo##' | tr '\n' ';'; }

# ------------------------------------------------------------------------------------------------ check
forge reset
check "a healthy train passes the check" "0" "$(train check Vidocq/demo 13 11 12)"
contains "and says what lands" "train: #11 -> #12 -> #13, 3 commit(s) on top of main" "$(cat "$TMP/out")"
check "a check writes nothing" "" "$(writes)"
check "merge without --yes is a dry run" "0" "$(train merge Vidocq/demo 13 11 12)"
check "that writes nothing either" "" "$(writes)"

forge reset; forge status "pr-validate / governance-checks (pull_request)=success" "pr-validate / pr-validate (pull_request)=pending"
check "the top still validating: refused" "1" "$(train check Vidocq/demo 13 11 12)"
contains "and says why" "the top's required checks are not green" "$(cat "$TMP/out")"

forge reset; forge status "pr-validate / governance-checks (pull_request)=success" "pr-validate / pr-validate (pull_request)=skipped"
check "a skipped pr-validate on the top: refused" "1" "$(train check Vidocq/demo 13 11 12)"

forge reset; forge raw /api/v1/repos/Vidocq/demo/branches/main \
  "{\"name\": \"main\", \"commit\": {\"id\": \"$MAIN\"}, \"enable_status_check\": false}"
forge status "pr-validate / governance-checks (pull_request)=success"
check "no required check on the branch, and no pr-validate on the top: refused" "1" "$(train check Vidocq/demo 13 11 12)"
contains "naming the missing check" "'pr-validate / pr-validate (pull_request)' is not success" "$(cat "$TMP/out")"

forge reset; forge raw /api/v1/repos/Vidocq/demo/branches/main \
  "{\"name\": \"main\", \"commit\": {\"id\": \"$MAIN\"}, \"enable_status_check\": true, \"status_check_contexts\": [\"gov\"]}"
forge status "gov=success"
check "a repository without pr-validate (ci, GestionProjet): --context '' relies on the required checks" "0" \
  "$(train check Vidocq/demo 13 11 12 --context '')"
check "but never by default" "1" "$(train check Vidocq/demo 13 11 12)"

forge reset; forge pr 13 'title="WIP: three"'
check "a WIP top: refused" "1" "$(train check Vidocq/demo 13 11 12)"
forge reset; forge pr 13 'labels=[{"name": "train-member"}]'
check "a top that is itself a member: refused" "1" "$(train check Vidocq/demo 13 11 12)"

forge reset; forge pr 12 'labels=[]'
check "an unlabelled member: refused" "1" "$(train check Vidocq/demo 13 11 12)"
contains "pointing at mark" "#12 is not labelled train-member: run 'mark' first" "$(cat "$TMP/out")"
forge reset; forge pr 12 'body="Train-top: #99"'
check "a member of another train: refused" "1" "$(train check Vidocq/demo 13 11 12)"
forge reset; forge pr 11 'title="WIP: one"'
check "a WIP member is never merged" "1" "$(train check Vidocq/demo 13 11 12)"
forge reset; forge pr 12 'labels=[{"name": "train-member"}, {"name": "blocked"}]'
check "a blocked member is never merged" "1" "$(train check Vidocq/demo 13 11 12)"

forge reset
check "members in the wrong order: refused" "1" "$(train check Vidocq/demo 13 12 11)"
contains "naming the broken link" "#12's head" "$(cat "$TMP/out")"
check "a member that is not an ancestor of the top: refused" "1" "$(train check Vidocq/demo 13 11 20)"

forge reset; forge pr 12 "head={\"sha\": \"$H11\", \"ref\": \"b12\", \"repo\": {\"full_name\": \"Vidocq/demo\"}}"
check "a head that moved (API and repository disagree): refused" "1" "$(train check Vidocq/demo 13 11 12)"
contains "and says so" "it moved" "$(cat "$TMP/out")"

forge reset; forge pr 12 'head={"sha": "x", "ref": "b12", "repo": {"full_name": "someone/demo"}}'
check "a member from a fork: refused" "1" "$(train check Vidocq/demo 13 11 12)"
forge reset; forge pr 11 'state="closed"'
check "a closed member: refused" "1" "$(train check Vidocq/demo 13 11 12)"
forge reset; forge pr 12 'base={"ref": "release"}'
check "a member on another base branch: refused" "1" "$(train check Vidocq/demo 13 11 12)"
forge reset
check "a train without members: refused" "1" "$(train check Vidocq/demo 13)"

# main moved past a member: the top no longer fast-forwards it.
git -C "$TMP/remote.git" update-ref refs/heads/main "$H20"
forge reset; forge raw /api/v1/repos/Vidocq/demo/branches/main \
  "{\"name\": \"main\", \"commit\": {\"id\": \"$H20\"}, \"enable_status_check\": true, \"status_check_contexts\": []}"
check "main is not an ancestor of the top: refused" "1" "$(train check Vidocq/demo 13 11 12)"
contains "and asks for a rebase" "rebase the train first" "$(cat "$TMP/out")"
git -C "$TMP/remote.git" update-ref refs/heads/main "$H11"
forge reset; forge raw /api/v1/repos/Vidocq/demo/branches/main \
  "{\"name\": \"main\", \"commit\": {\"id\": \"$H11\"}, \"enable_status_check\": true, \"status_check_contexts\": []}"
check "a member already in main: refused" "1" "$(train check Vidocq/demo 13 11 12)"
git -C "$TMP/remote.git" update-ref refs/heads/main "$MAIN"

# ------------------------------------------------------------------------------------------------ merge
forge reset; forge merged-after
check "merge --yes lands the train" "0" "$(train merge Vidocq/demo 13 11 12 --yes)"
check "the top fast-forwarded by its exact head, then #12 marked manually merged by its own head, comments" \
  "POST /pulls/13/merge {\"Do\": \"fast-forward-only\", \"head_commit_id\": \"$H13\", \"delete_branch_after_merge\": true};POST /pulls/12/merge {\"Do\": \"manually-merged\", \"MergeCommitID\": \"$H12\"};POST /issues/13/comments {\"body\": \"PR train landed: \`main\` fast-forwarded to \`${H13:0:10}\`, with #11, #12.\"};" \
  "$(writes)"
contains "#11 was detected by the forge" "#11: marked merged by the forge" "$(cat "$TMP/out")"

forge reset
check "the base branch did not move after the merge: stop, members untouched" "1" "$(train merge Vidocq/demo 13 11 12 --yes)"
check "only the top's merge was attempted" "POST /pulls/13/merge {\"Do\": \"fast-forward-only\", \"head_commit_id\": \"$H13\", \"delete_branch_after_merge\": true};" "$(writes)"

forge reset; forge merged-after
forge raw "POST /api/v1/repos/Vidocq/demo/pulls/12/merge" '{"status": 405, "body": {"message": "manual merge not allowed"}}'
check "no manual-merge mark on the repository: comment and close instead" "0" "$(train merge Vidocq/demo 13 11 12 --yes)"
contains "the member is closed" "PATCH /pulls/12 {\"state\": \"closed\"}" "$(writes)"

forge reset; forge status "pr-validate / governance-checks (pull_request)=success" "pr-validate / pr-validate (pull_request)=failure"
check "merge --yes re-checks first: a red top merges nothing" "1" "$(train merge Vidocq/demo 13 11 12 --yes)"
check "nothing written" "" "$(writes)"

# ------------------------------------------------------------------------------------------- mark/unmark
forge reset; forge pr 11 'labels=[]' 'body="Faster parser."'
check "mark labels the members and names the top" "0" "$(train mark Vidocq/demo 13 11)"
check "description first, then the label (org label id)" \
  'PATCH /pulls/11 {"body": "Faster parser.\n\nTrain-top: #13\n"};POST /issues/11/labels {"labels": [77]};' "$(writes)"
forge reset; forge pr 11 'body="Faster parser.\n\nTrain-top: #9\n"'
train mark Vidocq/demo 13 11 > /dev/null
contains "mark replaces an older top" 'PATCH /pulls/11 {"body": "Faster parser.\n\nTrain-top: #13\n"}' "$(writes)"
forge reset; forge raw /api/v1/orgs/Vidocq/labels '[]'
check "mark without a train-member label anywhere: refused" "1" "$(train mark Vidocq/demo 13 11)"
forge reset; forge pr 11 'body="Faster parser.\n\nTrain-top: #13\n"'
check "unmark removes the label by name and the top line" "0" "$(train unmark Vidocq/demo 11)"
check "by name, then the description" \
  'DELETE /issues/11/labels/train-member;PATCH /pulls/11 {"body": "Faster parser.\n"};' "$(writes)"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
