#!/usr/bin/env bash
# Tests of the merge-bot's refusal to merge a WIP pull request, a train member or a blocked one
# (refusal.sh, and merge.sh up to its first git call), against a local stub of the Forgejo API.
# git and gpg are stubs that log and fail: a refused pull request must never reach them.
# Run: bash merge-bot/refusal-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# ----------------------------------------------------------------------------- merge_refusal, alone
. "$HERE/refusal.sh"
why() { printf '%s' "$1" > "$TMP/pr.json"; merge_refusal "$TMP/pr.json"; }

check "a ready pull request may be merged" "" "$(why '{"title": "faster parser", "labels": []}')"
check "a WIP: title is refused" \
  "it is work in progress (the title says wip): remove WIP, let pr-validate go green, then /merge" \
  "$(why '{"title": "WIP: faster parser"}')"
check "a draft is refused" \
  "it is work in progress (the forge reports a draft): remove WIP, let pr-validate go green, then /merge" \
  "$(why '{"title": "faster parser", "draft": true}')"
check "the WIP label is refused" \
  "it is work in progress (label WIP): remove WIP, let pr-validate go green, then /merge" \
  "$(why '{"title": "faster parser", "labels": [{"name": "WIP"}]}')"
check "a train member is refused, naming its top" \
  "it is a member of a PR train (label train-member): it is validated through the train's top PR #12 and merged by the train script after it, never on its own" \
  "$(why '{"title": "faster parser", "body": "Train-top: #12", "labels": [{"name": "train-member"}]}')"
check "the blocked label is refused" \
  "it is blocked (label blocked): remove the blocked label, let pr-validate go green, then /merge" \
  "$(why '{"title": "faster parser", "labels": [{"name": "blocked"}]}')"
# The maintainer's rule (75-I2), the same classification as pr-validate.
check "wip anywhere in the title is refused" \
  "it is work in progress (the title says wip): remove WIP, let pr-validate go green, then /merge" \
  "$(why '{"title": "feat: thing (WIP)"}')"
check "a Draft: prefix is refused" \
  "it is work in progress (the title starts with Draft:): remove WIP, let pr-validate go green, then /merge" \
  "$(why '{"title": "Draft: thing"}')"
check "a label containing wip is refused" \
  "it is work in progress (label wip-do-not-merge): remove WIP, let pr-validate go green, then /merge" \
  "$(why '{"title": "thing", "labels": [{"name": "wip-do-not-merge"}]}')"
check "a label containing blocked is refused" \
  "it is blocked (label status/blocked): remove the blocked label, let pr-validate go green, then /merge" \
  "$(why '{"title": "thing", "labels": [{"name": "status/blocked"}]}')"
check "an unreadable pull request is refused" "its title and labels cannot be read, so it is not known to be ready" \
  "$(why 'not json')"

# ------------------------------------------------------------------------- merge.sh, end to end
echo '{}' > "$TMP/routes.json"
python3 "$HERE/../pr-validate-gate/stub_forge.py" "$TMP/routes.json" "$TMP/calls.log" > "$TMP/port" &
STUB=$!
trap 'kill $STUB 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/port" ] && break; sleep 0.2; done

mkdir -p "$TMP/bin"
for tool in git gpg; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/tools.log"\nexit 1\n' "$tool" "$TMP" > "$TMP/bin/$tool"
  chmod +x "$TMP/bin/$tool"
done

pr() { # pr <title> <labels,csv> [body]
  python3 - "$TMP/routes.json" "$@" <<'EOF'
import json, sys
path, title, csv = sys.argv[1:4]
body = sys.argv[4] if len(sys.argv) > 4 else ""
json.dump({"/api/v1/repos/Vidocq/demo/pulls/7": {
    "number": 7, "title": title, "body": body, "state": "open", "mergeable": True,
    "labels": [{"name": n} for n in csv.split(",") if n],
    "base": {"ref": "main"}, "head": {"ref": "feat/x", "sha": "1" * 40, "repo": {"full_name": "Vidocq/demo"}}}},
    open(path, "w"))
EOF
}
merge() { # merge [MERGE_AFTER_REBASE] -> "<exit status>|<reason file>|<tools called>"
  : > "$TMP/tools.log"; rm -f "$TMP/reason"
  PATH="$TMP/bin:$PATH" PR_NUMBER=7 REPO=Vidocq/demo BASE_URL="http://127.0.0.1:$(cat "$TMP/port")" BOT_TOKEN=t \
    GIT_SIGNING_PRIVATE_KEY=k GIT_SIGNING_PASSPHRASE=p GIT_SIGNING_KEY_ID=i MERGE_AFTER_REBASE="${1:-true}" \
    MERGE_BOT_REASON_FILE="$TMP/reason" bash "$HERE/merge.sh" > /dev/null 2>&1
  local rc=$?
  echo "$rc|$(cat "$TMP/reason" 2>/dev/null)|$(cut -d' ' -f1 "$TMP/tools.log" | sort -u | tr '\n' ' ' | sed 's/ $//')"
}

pr "WIP: faster parser" ""
check "/merge on a WIP pull request: refused before any git or gpg call, with the reason" \
  "1|PR #7 is not merged: it is work in progress (the title says wip): remove WIP, let pr-validate go green, then /merge.|" \
  "$(merge)"

pr "faster parser" "train-member" "Train-top: #12"
check "/merge on a train member: refused before any git or gpg call" \
  "1|PR #7 is not merged: it is a member of a PR train (label train-member): it is validated through the train's top PR #12 and merged by the train script after it, never on its own.|" \
  "$(merge)"

check "the refusal also cancels a merge scheduled earlier" "DELETE /api/v1/repos/Vidocq/demo/pulls/7/merge" \
  "$(grep -o '^DELETE [^ ]*' "$TMP/calls.log" | head -1)"

pr "WIP: faster parser" ""
result=$(merge false)
check "/rebase on a WIP pull request is still allowed: it goes on to git" "git" "${result##*|}"

pr "faster parser" ""
result=$(merge)
check "/merge on a ready pull request goes on to git" "git" "${result##*|}"

# ------------------------------------------------------------- merge.sh hands the merge to the forge
# git and gpg cooperate: the branch is already rebased and signed (no push). The bot must cancel any old
# schedule, announce the head, re-check the refusals, schedule the merge with the forge and exit: no wait.
H=1111111111111111111111111111111111111111
mkdir -p "$TMP/ok-bin"
printf '#!/bin/sh\necho "git $*" >> "%s/tools.log"\ncase "$1" in rev-parse|rev-list) echo %s ;; esac\nexit 0\n' \
  "$TMP" "$H" > "$TMP/ok-bin/git"
printf '#!/bin/sh\necho "gpg $*" >> "%s/tools.log"\ncase "$*" in *--list-secret-keys*) echo "sec:u:4096" ;; esac\nexit 0\n' \
  "$TMP" > "$TMP/ok-bin/gpg"
chmod +x "$TMP/ok-bin/git" "$TMP/ok-bin/gpg"
pr "faster parser" ""
python3 -c '
import json, sys
p, h = sys.argv[1], sys.argv[2]
r = json.load(open(p))
R = "/api/v1/repos/Vidocq/demo"
r[R + "/branches/main"] = {"name": "main", "enable_status_check": True, "status_check_contexts": ["v"]}
r[R + "/commits/" + h + "/status"] = {"state": "pending", "statuses": [{"context": "v", "status": "pending"}]}
r["POST " + R + "/pulls/7/merge"] = {"status": 201, "body": {}}
r["DELETE " + R + "/pulls/7/merge"] = {"status": 404, "body": {}}
json.dump(r, open(p, "w"))' "$TMP/routes.json" "$H"
: > "$TMP/calls.log"; : > "$TMP/tools.log"; rm -f "$TMP/reason"
start=$SECONDS
PATH="$TMP/ok-bin:$PATH" PR_NUMBER=7 REPO=Vidocq/demo BASE_URL="http://127.0.0.1:$(cat "$TMP/port")" BOT_TOKEN=t \
  GIT_SIGNING_PRIVATE_KEY=k GIT_SIGNING_PASSPHRASE=p GIT_SIGNING_KEY_ID=i MERGE_AFTER_REBASE=true \
  MERGE_BOT_REASON_FILE="$TMP/reason" bash "$HERE/merge.sh" > "$TMP/merge.out" 2>&1
check "/merge with checks pending: the bot schedules the merge and exits 0" "0" "$?"
check "without waiting" "true" "$([ $((SECONDS - start)) -lt 20 ] && echo true || echo false)"
check "cancel the old schedule, announce the head, schedule the exact head" \
  "DELETE /pulls/7/merge;POST /issues/7/comments;POST /pulls/7/merge;" \
  "$(grep -vE '^GET ' "$TMP/calls.log" | cut -d' ' -f1-2 | sed 's#/api/v1/repos/Vidocq/demo##' | tr '\n' ';')"
check "the announcement carries the head for the gate" "1" "$(grep -c "merge-bot-scheduled-head: $H" "$TMP/calls.log")"
check "the merge request names the head and asks the forge to wait for the checks" "1" \
  "$(grep '^POST /api/v1/repos/Vidocq/demo/pulls/7/merge' "$TMP/calls.log" | grep -c "\"head_commit_id\": \"$H\".*\"merge_when_checks_succeed\": true")"
check "nothing was pushed (already rebased and signed)" "0" "$(grep -c '^git push' "$TMP/tools.log")"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
