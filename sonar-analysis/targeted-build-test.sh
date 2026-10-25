#!/usr/bin/env bash
# Tests of sonar-analysis/targeted-build.sh: the pull-request Sonar build with targeted producer
# tests (prepare, the build command, restore before anything else reads the checkout). Offline:
# producer-tests.sh is a stub that records its modes.
# Run: bash sonar-analysis/targeted-build-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

cat > "$TMP/producer-tests.sh" <<EOF
#!/usr/bin/env bash
echo "producer-tests \$MODE base=\${BASE_REF:-} pr=\${PR_NUMBER:-} args=\$MVN_ARGS dir=\$TARGETED_DIR" >> "$TMP/calls"
[ "\$MODE" = "\${STUB_FAIL:-}" ] && exit 1
exit 0
EOF
run() { # run [VAR=value...] -- <build command...> -> exit status
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  rm -f "$TMP/calls"
  env PRODUCER_TESTS="$TMP/producer-tests.sh" TARGETED_DIR="$TMP/targeted" EVENT_NAME=pull_request \
    BASE_REF=main PR_NUMBER=42 ANALYSIS_ARGS='-B -ntp -Pquality' ${envs[@]+"${envs[@]}"} \
    bash "$HERE/targeted-build.sh" "$@" > "$TMP/out" 2>&1
  echo $?
}
build() { echo "bash -c 'echo build >> $TMP/calls; exit $1'"; }
calls() { sed 's/ base=.*//' "$TMP/calls" 2>/dev/null | paste -sd'|' -; }

check "off: only the build" "0|build" "$(run TARGETED_TESTS=false -- bash -c "echo build >> $TMP/calls")|$(calls)"
check "off: the build's exit status" "3" "$(run TARGETED_TESTS=false -- bash -c 'exit 3')"
check "push to main: never targeted" "0|build" "$(run TARGETED_TESTS=true EVENT_NAME=push -- bash -c "echo build >> $TMP/calls")|$(calls)"
check "pull request: prepare, build, restore, in that order" "0|producer-tests targeted|build|producer-tests restore" \
  "$(run TARGETED_TESTS=true -- bash -c "echo build >> $TMP/calls")|$(calls)"
check "pull request: the analysis profiles for the effective POM, the PR's base and number" "1" \
  "$(grep -c "^producer-tests targeted base=main pr=42 args=-B -ntp -Pquality dir=$TMP/targeted\$" "$TMP/calls")"
check "a failing build is still restored, and keeps its exit status" "2|producer-tests targeted|build|producer-tests restore" \
  "$(run TARGETED_TESTS=true -- bash -c "echo build >> $TMP/calls; exit 2")|$(calls)"
check "a failed restore fails, whatever the build" "1" "$(run TARGETED_TESTS=true STUB_FAIL=restore -- bash -c 'exit 0')"
check "a failed restore says so" "1" "$(grep -c '^::error' "$TMP/out")"
check "a failing prepare (poms cannot be restored) stops before the build" "1|producer-tests targeted" \
  "$(run TARGETED_TESTS=true STUB_FAIL=targeted -- bash -c "echo build >> $TMP/calls")|$(calls)"
check "an unknown value fails" "1" "$(run TARGETED_TESTS=maybe -- true)"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
