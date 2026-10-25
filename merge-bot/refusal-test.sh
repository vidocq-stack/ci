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
  "it is work in progress (the title starts with WIP:): remove WIP, let pr-validate go green, then /merge" \
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
check "the blocked label is refused" "it carries the label blocked: remove it first" \
  "$(why '{"title": "faster parser", "labels": [{"name": "blocked"}]}')"
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
  "1|PR #7 is not merged: it is work in progress (the title starts with WIP:): remove WIP, let pr-validate go green, then /merge.|" \
  "$(merge)"

pr "faster parser" "train-member" "Train-top: #12"
check "/merge on a train member: refused before any git or gpg call" \
  "1|PR #7 is not merged: it is a member of a PR train (label train-member): it is validated through the train's top PR #12 and merged by the train script after it, never on its own.|" \
  "$(merge)"

pr "WIP: faster parser" ""
result=$(merge false)
check "/rebase on a WIP pull request is still allowed: it goes on to git" "git" "${result##*|}"

pr "faster parser" ""
result=$(merge)
check "/merge on a ready pull request goes on to git" "git" "${result##*|}"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
