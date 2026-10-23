#!/usr/bin/env bash
# Tests of companion-branch.sh, against local bare repositories (no network).
# Run: bash build-impacted/companion-branch-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/companion-branch.sh"
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

# A consumer repository with main, feat/naming and other/feat/shared.
git init -q --bare "$TMP/consumer.git"
git clone -q "$TMP/consumer.git" "$TMP/work" 2>/dev/null
git -C "$TMP/work" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$TMP/work" push -q origin HEAD:main HEAD:feat/naming HEAD:other/feat/shared
URL="file://$TMP/consumer.git"

select_for() {
  # select_for <enabled> <head-ref> <head-repo> <repo>
  COMPANION_BRANCHES="$1" HEAD_REF="$2" HEAD_REPO="$3" GITHUB_REPOSITORY="$4" bash "$SCRIPT" select
}

check "a pull request from a branch of the repository names that branch" \
  "feat/naming" "$(select_for true feat/naming Vidocq/vauban Vidocq/vauban)"
check "a pull request from a fork names no branch" \
  "" "$(select_for true feat/naming someone/vauban Vidocq/vauban)"
check "a push, with no pull request, names no branch" \
  "" "$(select_for true '' '' Vidocq/vauban)"
check "companion branches turned off name no branch" \
  "" "$(select_for false feat/naming Vidocq/vauban Vidocq/vauban)"

check "a consumer with the branch is cloned on it" \
  "feat/naming" "$(bash "$SCRIPT" lookup "$URL" feat/naming)"
check "a consumer without the branch is cloned on its default branch" \
  "" "$(bash "$SCRIPT" lookup "$URL" feat/missing)"
check "a branch is matched by its whole name, not by its last segments" \
  "" "$(bash "$SCRIPT" lookup "$URL" feat/shared)"
check "no branch to look for asks nothing of the forge" \
  "" "$(bash "$SCRIPT" lookup "file://$TMP/does-not-exist.git" '')"

LOOKUP_ATTEMPTS=2 LOOKUP_DELAY=0 bash "$SCRIPT" lookup "file://$TMP/does-not-exist.git" feat/naming \
  >/dev/null 2>&1
check "an unreachable consumer fails instead of falling back on its default branch" "1" "$?"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
