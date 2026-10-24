#!/usr/bin/env bash
# Tests of merge.sh's CHECKS_TIMEOUT_MINUTES: the budget for the required checks (Vidocq/ci#49).
# A bad value is refused before the bot touches anything; a good one, or none, lets it go on to
# the pull request, which the unreachable BASE_URL below then fails to fetch.
# Run: bash merge-bot/checks-timeout-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failures=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$expected' in '$actual'"
    failures=$((failures + 1))
  fi
}

# run [<CHECKS_TIMEOUT_MINUTES>] -> merge.sh's output and exit status, without network or GPG
run() {
  local out rc
  out=$(env -i PATH="$PATH" HOME="$HOME" \
      PR_NUMBER=1 REPO=Vidocq/none BASE_URL=http://127.0.0.1:9 BOT_TOKEN=t \
      GIT_SIGNING_PRIVATE_KEY=k GIT_SIGNING_PASSPHRASE=p GIT_SIGNING_KEY_ID=i \
      ${1+CHECKS_TIMEOUT_MINUTES="$1"} \
      bash "$HERE/merge.sh" 2>&1); rc=$?
  echo "$out|$rc"
}

check "no value: the default budget, on to the pull request" "could not fetch PR #1" "$(run)"
check "60 minutes: on to the pull request"                   "could not fetch PR #1" "$(run 60)"
check "the job's limit, 80 minutes, is accepted"             "could not fetch PR #1" "$(run 80)"
check "past the job's limit: refused"                        "CHECKS_TIMEOUT_MINUTES must be a whole number of minutes from 1 to 80 (got '81')" "$(run 81)"
check "zero: refused"                                        "from 1 to 80 (got '0')" "$(run 0)"
check "not a number: refused"                                "from 1 to 80 (got '1h')" "$(run 1h)"
check "empty: refused"                                       "from 1 to 80 (got '')" "$(run '')"
check "a refusal fails the run"                              "|1" "$(run 1h)"

if (( failures > 0 )); then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
