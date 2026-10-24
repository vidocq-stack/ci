#!/usr/bin/env bash
# Tests of flakes.py, on a build log written by Maven 3.9.16 with surefire/failsafe 3.5.3 and
# -D{surefire,failsafe}.rerunFailingTestsCount=1 (trimmed, otherwise as printed).
# Run: bash build-impacted/flakes-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/flakes.py"
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

cat > "$TMP/heisenberg.log" <<'LOG'
[INFO] --- surefire:3.5.3:test (default-test) @ heisenberg-core ---
[INFO] Using auto detected provider org.apache.maven.surefire.junitplatform.JUnitPlatformProvider
[INFO] Running demo.FlakyTest
[ERROR] Tests run: 3, Failures: 1, Errors: 1, Skipped: 0, Time elapsed: 0.016 s <<< FAILURE! -- in demo.FlakyTest
[ERROR] demo.FlakyTest.alsoFlaky -- Time elapsed: 0.008 s <<< ERROR!
[INFO] Tests run: 2, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.001 s -- in demo.FlakyTest
[INFO]
[INFO] Results:
[INFO]
[WARNING] Flakes:
[WARNING] demo.FlakyTest.alsoFlaky
[ERROR]   Run 1: FlakyTest.alsoFlaky:19 IllegalState boom
[INFO]   Run 2: PASS
[INFO]
[WARNING] demo.FlakyTest.passesOnSecondRun
[ERROR]   Run 1: FlakyTest.passesOnSecondRun:13 first run fails
with a second line ==> expected: <true> but was: <false>
[INFO]   Run 2: PASS
[INFO]
[INFO]
[WARNING] Tests run: 3, Failures: 0, Errors: 0, Skipped: 0, Flakes: 2
[INFO]
[INFO] --- jar:3.5.0:jar (default-jar) @ heisenberg-core ---
[WARNING] JAR will be empty - no content was marked for inclusion!
[INFO]
[INFO] --- failsafe:3.5.3:integration-test (default) @ heisenberg-it ---
[INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.001 s -- in demo.FlakyIT
[INFO]
[INFO] Results:
[INFO]
[WARNING] Flakes:
[WARNING] demo.FlakyIT.itPassesOnSecondRun
[ERROR]   Run 1: FlakyIT.itPassesOnSecondRun:12 expected: <2> but was: <1>, a|b
[INFO]   Run 2: PASS
[INFO]
[INFO]
[WARNING] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0, Flakes: 1
[INFO]
[INFO] --- failsafe:3.5.3:verify (default) @ heisenberg-it ---
[INFO] BUILD SUCCESS
LOG

cat > "$TMP/foy.log" <<'LOG'
[INFO] --- surefire:3.5.3:test (default-test) @ foy-core ---
[INFO] Tests run: 12, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
LOG

# A colored log (a caller that dropped -B) and an old plugin prefix.
printf '\033[1;34mINFO\033[m] --- maven-surefire-plugin:2.22.2:test (default-test) @ old ---\n' > "$TMP/old.log"
printf '[\033[1;33mWARNING\033[m] Flakes: \n[\033[1;33mWARNING\033[m] a.B.c\n[\033[1;31mERROR\033[m]   Run 1: B.c:1 x\n[\033[1;34mINFO\033[m]   Run 2: PASS\n[\033[1;33mWARNING\033[m] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0, Flakes: 1\n' >> "$TMP/old.log"
sed -i.bak '1s/^/[/' "$TMP/old.log"

summary="$TMP/summary.md"
out=$(GITHUB_STEP_SUMMARY="$summary" python3 "$SCRIPT" \
  Vidocq/foy="$TMP/foy.log" Vidocq/heisenberg="$TMP/heisenberg.log" Vidocq/missing="$TMP/none.log")
check "exit status is 0 even with flakes (report only)" "0" "$?"

warnings=$(echo "$out" | grep '^::warning')
check "one warning per flaky test" "3" "$(echo "$warnings" | wc -l | tr -d ' ')"
check "the warning names the consumer, the module, the plugin and the test" \
  "::warning title=Flaky test in Vidocq/heisenberg::demo.FlakyTest.alsoFlaky (heisenberg-core, surefire) failed, then passed on rerun. First failure: FlakyTest.alsoFlaky:19 IllegalState boom" \
  "$(echo "$warnings" | sed -n 1p)"
check "a failure message on two lines is joined" \
  "first run fails with a second line ==> expected: <true> but was: <false>" \
  "$(echo "$warnings" | sed -n 2p | sed 's/.*First failure: FlakyTest.passesOnSecondRun:13 //')"
check "a failsafe flake is reported with its own module" \
  "demo.FlakyIT.itPassesOnSecondRun (heisenberg-it, failsafe)" \
  "$(echo "$warnings" | sed -n 3p | sed 's/^::warning title=Flaky test in Vidocq\/heisenberg:://; s/ failed, then.*//')"
check "the console ends with a count" "3 flaky test(s) in the downstream consumers: Vidocq/heisenberg" "$(echo "$out" | tail -1)"

check "the job summary has a section title" "### Flaky tests in downstream consumers" "$(grep '^###' "$summary")"
check "the job summary has one row per flaky test" "3" "$(grep -c '^| Vidocq/' "$summary")"
check "the job summary escapes a pipe in a failure message" \
  '| Vidocq/heisenberg | heisenberg-it | failsafe | `demo.FlakyIT.itPassesOnSecondRun` | FlakyIT.itPassesOnSecondRun:12 expected: <2> but was: <1>, a\|b |' \
  "$(grep 'itPassesOnSecondRun' "$summary")"

# Workflow-command escaping: % and newlines in the data.
printf '[WARNING] Flakes: \n[WARNING] a.B.c\n[ERROR]   Run 1: 100%% wrong\n[INFO]   Run 2: PASS\n[WARNING] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0, Flakes: 1\n' > "$TMP/pct.log"
check "a % in a message is escaped for the workflow command" \
  "::warning title=Flaky test in o/p::a.B.c (?, ?) failed, then passed on rerun. First failure: 100%25 wrong" \
  "$(python3 "$SCRIPT" o/p="$TMP/pct.log" | grep '^::warning')"

check "colors and an old plugin prefix are understood" \
  "::warning title=Flaky test in o/old::a.B.c (old, surefire) failed, then passed on rerun. First failure: B.c:1 x" \
  "$(python3 "$SCRIPT" o/old="$TMP/old.log" | grep '^::warning')"

rm -f "$TMP/clean.md"
out=$(GITHUB_STEP_SUMMARY="$TMP/clean.md" python3 "$SCRIPT" Vidocq/foy="$TMP/foy.log")
check "no flake: no warning" "" "$(echo "$out" | grep '^::warning')"
check "no flake: a one-line note" "No flaky test in the downstream consumers." "$out"
check "no flake: the job summary is left alone" "absent" "$([ -e "$TMP/clean.md" ] && echo present || echo absent)"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
