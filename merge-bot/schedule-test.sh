#!/usr/bin/env bash
# Tests of schedule.py (the merge-bot hands the merge to the forge instead of waiting in its job), against a
# local stub of the Forgejo API.
# Run: bash merge-bot/schedule-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/schedule.py"
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

echo '{}' > "$TMP/routes.json"
python3 "$HERE/../pr-validate-gate/stub_forge.py" "$TMP/routes.json" "$TMP/calls.log" > "$TMP/port" &
STUB=$!
trap 'kill $STUB 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/port" ] && break; sleep 0.2; done

HEAD=2222222222222222222222222222222222222222
R=/api/v1/repos/Vidocq/demo
GOV="pr-validate / governance-checks (pull_request)"
VAL="pr-validate / pr-validate (pull_request)"

GATE_YML=$(cat <<'YML'
name: pr-validate
on:
  pull_request:
jobs:
  pr-state:
    runs-on: vidocq-runner
    steps:
      - id: state
        uses: https://codefloe.com/Vidocq/ci/pr-validate-gate@main
        with:
          mode: state
          token: x
YML
)
OLD_YML=$(cat <<'YML'
name: pr-validate
on:
  pull_request:
jobs:
  pr-validate:
    runs-on: vidocq-runner
    steps:
      - run: echo verdict
YML
)
VERDICT_ONLY_YML=$(cat <<'YML'
name: pr-validate
jobs:
  pr-validate:
    steps:
      - uses: https://codefloe.com/Vidocq/ci/pr-validate-gate@main
        with:
          mode: verdict
YML
)
workflow() { # workflow <yaml>: the base branch's pr.yml, as the contents API answers it
  printf '{"%s/contents/.forgejo/workflows/pr.yml?ref=main": {"encoding": "base64", "content": "%s"}}' \
    "$R" "$(printf '%s' "$1" | base64 | tr -d '\n')"
}
# forge <validate status> [extra route json...]: the base branch requires GOV and VAL; GOV is green.
forge() {
  python3 - "$TMP/routes.json" "$@" <<EOF
import json, sys
path, val, extra = sys.argv[1], sys.argv[2], sys.argv[3:]
routes = {
  "$R/branches/main": {"name": "main", "enable_status_check": True, "status_check_contexts": ["$GOV", "$VAL"]},
  "$R/commits/$HEAD/status": {"state": "pending", "statuses": [{"context": "$GOV", "status": "success"},
                                                                {"context": "$VAL", "status": val}]},
  "$R/pulls/7": {"number": 7, "merged": False, "head": {"sha": "$HEAD"}},
  "POST $R/pulls/7/merge": {"status": 201, "body": {}},
  "DELETE $R/pulls/7/merge": {"status": 204, "body": {}},
  # The base branch's pr.yml runs the gate in state mode: the job that cancels a stale schedule (81-I1).
  "$R/contents/.forgejo/workflows/pr.yml?ref=main": {"encoding": "base64", "content": "$(printf '%s' "$GATE_YML" | base64 | tr -d '\n')"},
}
for e in extra:
    routes.update(json.loads(e))
json.dump(routes, open(path, "w"))
EOF
}
run() { # run -> "<exit status> <result>" ; output in $TMP/out
  : > "$TMP/calls.log"
  python3 "$SCRIPT" --api "http://127.0.0.1:$(cat "$TMP/port")/api/v1" --token t --repo Vidocq/demo --pr 7 \
    --head "$HEAD" --branch main --retry-pause 0 > "$TMP/out" 2>&1
  echo "$? $(sed -n 's/^result=//p' "$TMP/out")"
}
writes() { grep -vE '^GET ' "$TMP/calls.log" | sed -E "s#$R##" | tr '\n' ';'; }

forge pending
check "checks still running: the merge is scheduled with the forge, nothing waits" "0 scheduled" "$(run)"
check "fast-forward-only, the exact head, merge when checks succeed" \
  "POST /pulls/7/merge {\"Do\": \"fast-forward-only\", \"head_commit_id\": \"$HEAD\", \"delete_branch_after_merge\": true, \"merge_when_checks_succeed\": true};" \
  "$(writes)"

forge success '{"POST '"$R"'/pulls/7/merge": {"status": 200, "body": {}}}'
check "checks already green: merged at once (a schedule would wait for a status change that never comes)" "0 merged" "$(run)"
check "a plain fast-forward of the exact head" \
  "POST /pulls/7/merge {\"Do\": \"fast-forward-only\", \"head_commit_id\": \"$HEAD\", \"delete_branch_after_merge\": true};" \
  "$(writes)"

forge failure
check "a red required check: refused, nothing scheduled" "1 " "$(run)"
check "nothing written" "" "$(writes)"
contains "naming the check" "failure: $VAL" "$(cat "$TMP/out")"

forge pending '{"POST '"$R"'/pulls/7/merge": {"status": 409, "body": {"message": "already scheduled"}}}'
check "already scheduled (a stale schedule): refused with a clear message" "1 " "$(run)"
contains "and says so" "already scheduled" "$(cat "$TMP/out")"

# Checks turn green between the status read and the schedule: the schedule would wait forever, so it is
# replaced by a direct merge.
forge pending "{\"_on POST $R/pulls/7/merge\": {\"$R/commits/$HEAD/status\": {\"state\": \"success\", \"statuses\": [{\"context\": \"$GOV\", \"status\": \"success\"}, {\"context\": \"$VAL\", \"status\": \"success\"}]}, \"POST $R/pulls/7/merge\": {\"status\": 200, \"body\": {}}}}"
check "checks green right after scheduling: the schedule is replaced by a direct merge" "0 merged" "$(run)"
check "schedule, cancel, merge" \
  "POST /pulls/7/merge {\"Do\": \"fast-forward-only\", \"head_commit_id\": \"$HEAD\", \"delete_branch_after_merge\": true, \"merge_when_checks_succeed\": true};DELETE /pulls/7/merge;POST /pulls/7/merge {\"Do\": \"fast-forward-only\", \"head_commit_id\": \"$HEAD\", \"delete_branch_after_merge\": true};" \
  "$(writes)"

forge pending '{"'"$R"'/branches/main": {"name": "main", "enable_status_check": false}}' '{"POST '"$R"'/pulls/7/merge": {"status": 200, "body": {}}}'
check "no required check on the branch: merged at once" "0 merged" "$(run)"

forge pending '{"POST '"$R"'/pulls/7/merge": {"status": 405, "body": {"message": "not allowed"}}}'
check "the forge refuses the schedule: refused, with its answer" "1 " "$(run)"
contains "and its answer" "HTTP 405" "$(cat "$TMP/out")"

# 81-I1: a repository whose pr.yml does not run the gate in state mode never gets a schedule (nothing would
# cancel it on a push, WIP, blocked or train member): green merges now, pending is refused.
forge pending "$(workflow "$OLD_YML")"
check "no pr-state gate on the base branch, checks pending: refused, nothing scheduled" "1 " "$(run)"
check "nothing written" "" "$(writes)"
contains "with what to do" "checks still running; re-run /merge when pr-validate is green" "$(cat "$TMP/out")"
forge pending "$(workflow "$VERDICT_ONLY_YML")"
check "the gate in verdict mode only is not enough" "1 " "$(run)"
forge pending '{"'"$R"'/contents/.forgejo/workflows/pr.yml?ref=main": {"status": 404, "body": {}}}'
check "no pr.yml at all (ci, GestionProjet): refused" "1 " "$(run)"
forge success "$(workflow "$OLD_YML")" '{"POST '"$R"'/pulls/7/merge": {"status": 200, "body": {}}}'
check "no gate but checks green: merged at once" "0 merged" "$(run)"
: > "$TMP/calls.log"
forge pending
check "--gate prints whether the base branch runs the gate" "gate=true" \
  "$(python3 "$SCRIPT" --api "http://127.0.0.1:$(cat "$TMP/port")/api/v1" --token t --repo Vidocq/demo --pr 7 --head "$HEAD" --branch main --gate)"
forge pending "$(workflow "$OLD_YML")"
check "--gate without the gate" "gate=false" \
  "$(python3 "$SCRIPT" --api "http://127.0.0.1:$(cat "$TMP/port")/api/v1" --token t --repo Vidocq/demo --pr 7 --head "$HEAD" --branch main --gate)"

# 81-I2: the PR head moved between the bot's push and the schedule: the schedule is cancelled, and refused.
forge pending "{\"_on POST $R/pulls/7/merge\": {\"$R/pulls/7\": {\"number\": 7, \"merged\": false, \"head\": {\"sha\": \"3333333333333333333333333333333333333333\"}}}}"
check "the head moved right after scheduling: cancelled and refused" "1 " "$(run)"
check "schedule, then cancel" \
  "POST /pulls/7/merge {\"Do\": \"fast-forward-only\", \"head_commit_id\": \"$HEAD\", \"delete_branch_after_merge\": true, \"merge_when_checks_succeed\": true};DELETE /pulls/7/merge;" \
  "$(writes)"
contains "naming the new head" "3333333333" "$(cat "$TMP/out")"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
