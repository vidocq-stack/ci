#!/usr/bin/env bash
# Tests of required-checks.py.
# Run: bash merge-bot/required-checks-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/required-checks.py"
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

# branch <enable_status_check> <context>... -> the base branch, as GET /repos/{repo}/branches/{branch} returns it
branch() {
  local enabled="$1"; shift
  python3 -c 'import json,sys; print(json.dumps({"name": "main", "enable_status_check": sys.argv[1] == "true", "status_check_contexts": sys.argv[2:]}))' \
    "$enabled" "$@" > "$TMP/branch.json"
}
# status <combined state> <context>=<status>... -> GET /repos/{repo}/commits/{sha}/status
status() {
  local state="$1"; shift
  python3 -c '
import json, sys
statuses = [dict(zip(("context", "status"), s.split("=", 1))) for s in sys.argv[2:]]
print(json.dumps({"state": sys.argv[1], "statuses": statuses}))' "$state" "$@" > "$TMP/status.json"
}
run() { # run -> "<output>|<exit status>"
  local out rc
  out=$(python3 "$SCRIPT" "$TMP/branch.json" "$TMP/status.json" 2>/dev/null); rc=$?
  echo "$out|$rc"
}

GOV="pr-validate / governance-checks (pull_request)"
VAL="pr-validate / pr-validate (pull_request)"
SONAR="sonar / sonar (pull_request)"

branch true "$GOV" "$VAL"

status pending "$GOV=success" "$VAL=success" "$SONAR=pending"
check "a check the branch does not require is not waited for (Vidocq/ci#47)" "success|0" "$(run)"

status failure "$GOV=success" "$VAL=success" "$SONAR=failure"
check "a failed check the branch does not require does not block" "success|0" "$(run)"

status pending "$GOV=success" "$VAL=pending" "$SONAR=success"
check "a required check still running is pending" "pending: $VAL|0" "$(run)"

status pending "$GOV=success"
check "a required check not reported yet is pending" "pending: $VAL|0" "$(run)"

status failure "$GOV=success" "$VAL=failure" "$SONAR=pending"
check "a failed required check is a failure" "failure: $VAL|0" "$(run)"

status error "$GOV=error" "$VAL=success"
check "a required check in error is a failure" "failure: $GOV|0" "$(run)"

branch true "pr-validate / *"
status pending "$GOV=success" "$VAL=success" "$SONAR=pending"
check "a required context is a glob pattern" "success|0" "$(run)"

status pending "$GOV=success" "$VAL=pending"
check "every status a pattern matches must succeed" "pending: pr-validate / *|0" "$(run)"

branch true
status pending "$GOV=success" "$SONAR=pending"
check "no required context listed: every status counts, as on the forge" "pending: combined state is pending|0" "$(run)"

status success "$GOV=success" "$SONAR=success"
check "no required context listed and all green" "success|0" "$(run)"

branch false "$GOV"
status pending "$SONAR=pending"
check "status checks off: nothing to wait for" "success|0" "$(run)"

echo '<html>error</html>' > "$TMP/branch.json"
status pending "$GOV=success"
check "an unreadable branch is an error, not a verdict" "|2" "$(run)"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
